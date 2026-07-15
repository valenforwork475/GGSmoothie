-- GG Back Office Phase 3: purchasing, shift review/refunds, expenses, CRM/promotions and alerts
begin;

insert into public.role_permissions(role,permission,allowed) values
 ('manager','purchasing.view',true),('manager','purchasing.edit',true),('manager','expenses.view',true),('manager','expenses.edit',true),('manager','crm.view',true),('manager','crm.edit',true),('manager','alerts.view',true),
 ('owner','purchasing.view',true),('owner','purchasing.edit',true),('owner','expenses.view',true),('owner','expenses.edit',true),('owner','crm.view',true),('owner','crm.edit',true),('owner','alerts.view',true)
on conflict(role,permission) do nothing;

create table if not exists public.suppliers(
 id uuid primary key default gen_random_uuid(), name text not null unique, contact_name text,
 phone text, email text, note text, active boolean not null default true,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.purchase_receipts(
 id uuid primary key default gen_random_uuid(), supplier_id uuid references public.suppliers(id),
 invoice_no text, total numeric(14,2) not null default 0 check(total>=0), status text not null default 'received' check(status in ('draft','received','cancelled')),
 received_at timestamptz, created_by uuid references auth.users(id), created_at timestamptz not null default now()
);
create table if not exists public.purchase_receipt_items(
 id bigint generated always as identity primary key, receipt_id uuid not null references public.purchase_receipts(id) on delete cascade,
 ingredient_id uuid not null references public.ingredients(id), quantity numeric(14,3) not null check(quantity>0),
 unit_cost numeric(14,4) not null check(unit_cost>=0), line_total numeric(14,2) generated always as (round(quantity*unit_cost,2)) stored
);
create table if not exists public.expenses(
 id uuid primary key default gen_random_uuid(), expense_date date not null default current_date,
 category text not null, description text not null, amount numeric(14,2) not null check(amount>0),
 payment_method text not null default 'transfer', created_by uuid references auth.users(id), created_at timestamptz not null default now()
);
create table if not exists public.promotions(
 id uuid primary key default gen_random_uuid(), code text not null unique, name text not null,
 discount_type text not null check(discount_type in ('percent','fixed')), discount_value numeric(12,2) not null check(discount_value>0),
 min_spend numeric(12,2) not null default 0, starts_at timestamptz not null, ends_at timestamptz not null,
 usage_limit int, used_count int not null default 0, active boolean not null default true,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), check(ends_at>starts_at)
);
create table if not exists public.refunds(
 id uuid primary key default gen_random_uuid(), order_id uuid not null references public.orders(id),
 amount numeric(12,2) not null check(amount>0), reason text not null,
 status text not null default 'approved' check(status in ('pending','approved','rejected')),
 requested_by uuid references auth.users(id), approved_by uuid references auth.users(id), created_at timestamptz not null default now()
);
create table if not exists public.backoffice_alerts(
 id uuid primary key default gen_random_uuid(), severity text not null default 'info' check(severity in ('info','warning','critical')),
 title text not null, message text not null, entity_type text, entity_id text, read_at timestamptz,
 created_at timestamptz not null default now()
);

do $$ begin
 create trigger suppliers_touch before update on public.suppliers for each row execute function public.tg_touch_updated_at();
exception when duplicate_object then null; end $$;
do $$ begin
 create trigger promotions_touch before update on public.promotions for each row execute function public.tg_touch_updated_at();
exception when duplicate_object then null; end $$;

alter table public.suppliers enable row level security; alter table public.purchase_receipts enable row level security;
alter table public.purchase_receipt_items enable row level security; alter table public.expenses enable row level security;
alter table public.promotions enable row level security; alter table public.refunds enable row level security; alter table public.backoffice_alerts enable row level security;

create policy "purchase read suppliers" on public.suppliers for select to authenticated using(public.staff_has_permission('purchasing.view'));
create policy "purchase edit suppliers" on public.suppliers for all to authenticated using(public.staff_has_permission('purchasing.edit')) with check(public.staff_has_permission('purchasing.edit'));
create policy "purchase read receipts" on public.purchase_receipts for select to authenticated using(public.staff_has_permission('purchasing.view'));
create policy "purchase read receipt items" on public.purchase_receipt_items for select to authenticated using(public.staff_has_permission('purchasing.view'));
create policy "expense read" on public.expenses for select to authenticated using(public.staff_has_permission('expenses.view'));
create policy "expense edit" on public.expenses for all to authenticated using(public.staff_has_permission('expenses.edit')) with check(public.staff_has_permission('expenses.edit'));
create policy "crm read promotions" on public.promotions for select to authenticated using(public.staff_has_permission('crm.view'));
create policy "crm edit promotions" on public.promotions for all to authenticated using(public.staff_has_permission('crm.edit')) with check(public.staff_has_permission('crm.edit'));
create policy "shift read refunds" on public.refunds for select to authenticated using(public.staff_has_permission('shifts.review'));
create policy "alerts read" on public.backoffice_alerts for select to authenticated using(public.staff_has_permission('alerts.view'));
create policy "alerts update" on public.backoffice_alerts for update to authenticated using(public.staff_has_permission('alerts.view')) with check(public.staff_has_permission('alerts.view'));

grant select,insert,update on public.suppliers,public.expenses,public.promotions to authenticated;
grant select on public.purchase_receipts,public.purchase_receipt_items,public.refunds,public.backoffice_alerts to authenticated;
grant update(read_at) on public.backoffice_alerts to authenticated;

create or replace function public.receive_purchase(p_supplier_id uuid,p_invoice_no text,p_ingredient_id uuid,p_quantity numeric,p_unit_cost numeric) returns uuid
language plpgsql security definer set search_path=public as $$ declare v_id uuid; v_total numeric; begin
 if not public.staff_has_permission('purchasing.edit') then raise exception 'permission denied'; end if;
 if p_quantity<=0 or p_unit_cost<0 then raise exception 'invalid purchase values'; end if; v_total:=round(p_quantity*p_unit_cost,2);
 insert into public.purchase_receipts(supplier_id,invoice_no,total,status,received_at,created_by) values(p_supplier_id,nullif(trim(p_invoice_no),''),v_total,'received',now(),auth.uid()) returning id into v_id;
 insert into public.purchase_receipt_items(receipt_id,ingredient_id,quantity,unit_cost) values(v_id,p_ingredient_id,p_quantity,p_unit_cost);
 perform public.adjust_stock(p_ingredient_id,'purchase',p_quantity,p_unit_cost,'รับสินค้าเอกสาร '||coalesce(p_invoice_no,'-'));
 insert into public.audit_log(actor_uid,action,entity_type,entity_id,detail) values(auth.uid(),'purchase.receive','purchase_receipt',v_id::text,jsonb_build_object('total',v_total)); return v_id; end $$;

create or replace function public.approve_refund(p_order_id uuid,p_amount numeric,p_reason text) returns uuid
language plpgsql security definer set search_path=public as $$ declare v_order public.orders; v_id uuid; begin
 if not public.staff_has_permission('refunds.approve') then raise exception 'permission denied'; end if;
 select * into v_order from public.orders where id=p_order_id for update; if not found then raise exception 'order not found'; end if;
 if p_amount<=0 or p_amount>v_order.total then raise exception 'invalid refund amount'; end if;
 if exists(select 1 from public.refunds where order_id=p_order_id and status='approved') then raise exception 'order already refunded'; end if;
 insert into public.refunds(order_id,amount,reason,status,requested_by,approved_by) values(p_order_id,p_amount,trim(p_reason),'approved',auth.uid(),auth.uid()) returning id into v_id;
 if v_order.pay_method='cash' and v_order.shift_id is not null then insert into public.cash_movements(shift_id,kind,amount,reason,order_id,created_by) values(v_order.shift_id,'refund',p_amount,trim(p_reason),p_order_id,auth.uid()); end if;
 insert into public.audit_log(actor_uid,action,entity_type,entity_id,detail) values(auth.uid(),'refund.approve','order',p_order_id::text,jsonb_build_object('refund_id',v_id,'amount',p_amount,'reason',trim(p_reason))); return v_id; end $$;

revoke all on function public.receive_purchase(uuid,text,uuid,numeric,numeric) from public;
revoke all on function public.approve_refund(uuid,numeric,text) from public;
grant execute on function public.receive_purchase(uuid,text,uuid,numeric,numeric) to authenticated;
grant execute on function public.approve_refund(uuid,numeric,text) to authenticated;
commit;
