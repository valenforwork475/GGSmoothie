begin;

-- Immutable cost history captured when inventory is first applied to an order.
create table if not exists public.order_cost_snapshots(
 order_id uuid primary key references public.orders(id) on delete cascade,
 total_cogs numeric(14,4) not null default 0 check(total_cogs>=0),
 item_costs jsonb not null default '[]'::jsonb,
 source text not null default 'sale_time' check(source in ('sale_time','backfill_latest')),
 captured_at timestamptz not null default now()
);
alter table public.order_cost_snapshots enable row level security;
create policy "reports read cost snapshots" on public.order_cost_snapshots for select to authenticated using(public.staff_has_permission('reports.view'));
revoke all on table public.order_cost_snapshots from anon,authenticated;
grant select on table public.order_cost_snapshots to authenticated;

create or replace function public.capture_order_cost_snapshot() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_line jsonb; v_recipe record; v_qty numeric; v_line_cost numeric; v_total numeric:=0; v_items jsonb:='[]'::jsonb; v_components jsonb;
begin
 if new.inventory_applied_at is null or exists(select 1 from public.order_cost_snapshots where order_id=new.id) then return new; end if;
 for v_line in select value from jsonb_array_elements(new.items) loop
  if coalesce(v_line->>'kind','')='discount' or nullif(v_line->>'menu_id','') is null then continue; end if;
  v_qty:=greatest(coalesce((v_line->>'qty')::numeric,0),0); v_line_cost:=0; v_components:='[]'::jsonb;
  for v_recipe in select r.ingredient_id,r.quantity,i.name,i.unit,i.unit_cost from public.menu_recipes r join public.ingredients i on i.id=r.ingredient_id where r.menu_item_id=v_line->>'menu_id' loop
   v_line_cost:=v_line_cost+(v_recipe.quantity*v_recipe.unit_cost*v_qty);
   v_components:=v_components||jsonb_build_array(jsonb_build_object('ingredient_id',v_recipe.ingredient_id,'name',v_recipe.name,'unit',v_recipe.unit,'quantity',v_recipe.quantity*v_qty,'unit_cost',v_recipe.unit_cost,'cost',round(v_recipe.quantity*v_recipe.unit_cost*v_qty,4)));
  end loop;
  v_total:=v_total+v_line_cost;
  v_items:=v_items||jsonb_build_array(jsonb_build_object('menu_id',v_line->>'menu_id','name',v_line->>'name','qty',v_qty,'cost',round(v_line_cost,4),'components',v_components));
 end loop;
 insert into public.order_cost_snapshots(order_id,total_cogs,item_costs,source,captured_at) values(new.id,round(v_total,4),v_items,'sale_time',coalesce(new.inventory_applied_at,now())) on conflict(order_id) do nothing;
 return new;
end $$;
drop trigger if exists orders_capture_cost on public.orders;
create trigger orders_capture_cost after insert or update of inventory_applied_at on public.orders for each row execute function public.capture_order_cost_snapshot();

insert into public.order_cost_snapshots(order_id,total_cogs,item_costs,source,captured_at)
select o.id,coalesce(sum(coalesce((line->>'qty')::numeric,0)*r.quantity*i.unit_cost),0),'[]'::jsonb,'backfill_latest',coalesce(o.inventory_applied_at,o.created_at)
from public.orders o cross join lateral jsonb_array_elements(o.items) line
left join public.menu_recipes r on r.menu_item_id=line->>'menu_id' left join public.ingredients i on i.id=r.ingredient_id
where o.status<>'cancelled' and coalesce(line->>'kind','')<>'discount' and not exists(select 1 from public.order_cost_snapshots c where c.order_id=o.id)
group by o.id;

-- Payment reconciliation ledger. Gateway webhooks write through a service-role-only RPC.
create table if not exists public.payment_transactions(
 id uuid primary key default gen_random_uuid(),order_id uuid not null unique references public.orders(id),method text not null,
 expected_amount numeric(12,2) not null check(expected_amount>0),status text not null check(status in ('cash_recorded','staff_confirmed','reconciled','failed','refunded')),
 provider text,provider_reference text,staff_confirmed_at timestamptz,reconciled_at timestamptz,reconciled_by uuid references auth.users(id),note text,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.payment_webhook_events(id text primary key,provider text not null,order_id uuid references public.orders(id),payload jsonb,received_at timestamptz not null default now());
alter table public.payment_transactions enable row level security; alter table public.payment_webhook_events enable row level security;
create policy "reports read payments" on public.payment_transactions for select to authenticated using(public.staff_has_permission('reports.view'));
revoke all on table public.payment_transactions,public.payment_webhook_events from anon,authenticated;
grant select on table public.payment_transactions to authenticated;
insert into public.role_permissions(role,permission,allowed) values('cashier','payments.reconcile',false),('manager','payments.reconcile',true),('owner','payments.reconcile',true) on conflict(role,permission) do nothing;

create or replace function public.capture_order_payment() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.source='pos' then insert into public.payment_transactions(order_id,method,expected_amount,status,staff_confirmed_at) values(new.id,new.pay_method,new.total,case when new.pay_method='cash' then 'cash_recorded' else 'staff_confirmed' end,case when new.pay_method='cash' then null else now() end) on conflict(order_id) do nothing; end if;
 return new;
end $$;
drop trigger if exists orders_capture_payment on public.orders; create trigger orders_capture_payment after insert on public.orders for each row execute function public.capture_order_payment();

create or replace function public.sync_cancelled_payment() returns trigger language plpgsql security definer set search_path=public as $$ begin if new.status='cancelled' and old.status is distinct from new.status then update public.payment_transactions set status='refunded',updated_at=now() where order_id=new.id; end if; return new; end $$;
drop trigger if exists orders_sync_cancelled_payment on public.orders; create trigger orders_sync_cancelled_payment after update of status on public.orders for each row execute function public.sync_cancelled_payment();

create or replace function public.reconcile_payment(p_order_id uuid,p_reference text,p_note text default null) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.staff_has_permission('payments.reconcile') then raise exception 'permission denied'; end if;
 if coalesce(trim(p_reference),'')='' then raise exception 'reference required'; end if;
 update public.payment_transactions set status='reconciled',provider_reference=trim(p_reference),note=nullif(trim(coalesce(p_note,'')),''),reconciled_at=now(),reconciled_by=auth.uid(),updated_at=now() where order_id=p_order_id and status='staff_confirmed';
 if not found then raise exception 'payment not waiting for reconciliation'; end if;
 insert into public.audit_log(actor_uid,action,entity_type,entity_id,detail) values(auth.uid(),'payment.reconcile','order',p_order_id::text,jsonb_build_object('reference',trim(p_reference)));
end $$;

create or replace function public.confirm_payment_webhook(p_event_id text,p_provider text,p_order_id uuid,p_amount numeric,p_reference text,p_payload jsonb default '{}'::jsonb) returns void language plpgsql security definer set search_path=public as $$
begin
 if coalesce(trim(p_event_id),'')='' or coalesce(trim(p_provider),'')='' then raise exception 'invalid event'; end if;
 insert into public.payment_webhook_events(id,provider,order_id,payload) values(p_event_id,p_provider,p_order_id,p_payload) on conflict(id) do nothing;
 if not found then return; end if;
 update public.payment_transactions set status='reconciled',provider=p_provider,provider_reference=p_reference,reconciled_at=now(),updated_at=now() where order_id=p_order_id and expected_amount=p_amount and status not in ('refunded','failed');
 if not found then raise exception 'payment mismatch'; end if;
end $$;

-- Order state changes are RPC-only to prevent bypassing refund/inventory flows.
create or replace function public.advance_order_status(p_order_id uuid,p_status text,p_note text default null) returns void language plpgsql security definer set search_path=public as $$
declare v public.orders;
begin
 if not public.staff_has_permission('pos.sell') then raise exception 'permission denied'; end if;
 select * into v from public.orders where id=p_order_id for update; if not found then raise exception 'order not found'; end if;
 if p_status='cancelled' then raise exception 'use cancellation flow'; end if;
 if not ((v.source='pos' and v.created_by=auth.uid() and v.status='pending' and p_status='done') or (v.status='pending' and p_status='confirmed') or (v.status='confirmed' and p_status='making') or (v.status='making' and p_status='ready') or (v.status='ready' and p_status='done')) then raise exception 'invalid status transition'; end if;
 update public.orders set status=p_status,note=coalesce(nullif(trim(coalesce(p_note,'')),''),note) where id=p_order_id;
end $$;
create or replace function public.mark_order_printed(p_order_id uuid) returns void language plpgsql security definer set search_path=public as $$ begin if not public.staff_has_permission('pos.sell') then raise exception 'permission denied'; end if; update public.orders set printed=true where id=p_order_id; end $$;

revoke update on table public.orders from authenticated;
revoke all on function public.place_order(text,text,jsonb,numeric,text,text) from authenticated;
grant execute on function public.place_order(text,text,jsonb,numeric,text,text) to anon;
revoke all on function public.advance_order_status(uuid,text,text),public.mark_order_printed(uuid),public.reconcile_payment(uuid,text,text),public.confirm_payment_webhook(text,text,uuid,numeric,text,jsonb) from public;
grant execute on function public.advance_order_status(uuid,text,text),public.mark_order_printed(uuid),public.reconcile_payment(uuid,text,text) to authenticated;
grant execute on function public.confirm_payment_webhook(text,text,uuid,numeric,text,jsonb) to service_role;

create or replace function public.sales_summary(p_from timestamptz,p_to timestamptz) returns json language plpgsql stable security definer set search_path=public as $$
declare v_result json;
begin
 if not public.staff_has_permission('reports.view') then raise exception 'permission denied'; end if;
 if p_from is null or p_to is null or p_to<=p_from or p_to-p_from>interval '370 days' then raise exception 'invalid report range'; end if;
 with filtered as(select * from public.orders where created_at>=p_from and created_at<p_to and status<>'cancelled'),lines as(select o.id,o.created_at,o.pay_method,x.value item,coalesce((x.value->>'qty')::numeric,0) qty,coalesce((x.value->>'price')::numeric,0) price from filtered o cross join lateral jsonb_array_elements(o.items)x where coalesce(x.value->>'kind','')<>'discount')
 select json_build_object('revenue',coalesce((select sum(total) from filtered),0),'orders',coalesce((select count(*) from filtered),0),'cups',coalesce((select sum(qty) from lines),0),'cogs',coalesce((select sum(c.total_cogs) from filtered f left join public.order_cost_snapshots c on c.order_id=f.id),0),'by_day',coalesce((select json_agg(d order by report_day) from(select(created_at at time zone 'Asia/Bangkok')::date report_day,sum(total) revenue,count(*) orders from filtered group by 1)d),'[]'::json),'payments',coalesce((select json_agg(p order by revenue desc) from(select pay_method,sum(total) revenue,count(*) orders from filtered group by 1)p),'[]'::json),'top_items',coalesce((select json_agg(t order by quantity desc) from(select item->>'name' name,sum(qty) quantity,sum(qty*price) revenue from lines group by 1 order by 2 desc limit 10)t),'[]'::json)) into v_result;
 return v_result;
end $$;

commit;
