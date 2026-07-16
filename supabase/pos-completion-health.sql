begin;

create or replace function public.auto_complete_pos_order() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.source='pos' then update public.orders set status='done' where id=new.id and status='pending'; end if;
 return new;
end $$;
drop trigger if exists orders_auto_complete_pos on public.orders;
create trigger orders_auto_complete_pos after insert on public.orders for each row execute function public.auto_complete_pos_order();

create or replace function public.set_pos_order_note(p_order_id uuid,p_note text) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.staff_has_permission('pos.sell') then raise exception 'permission denied'; end if;
 update public.orders set note=nullif(trim(coalesce(p_note,'')),'') where id=p_order_id and source='pos' and created_by=auth.uid() and status<>'cancelled';
 if not found then raise exception 'order not owned by staff'; end if;
end $$;

create or replace function public.system_health_check() returns json language plpgsql stable security definer set search_path=public as $$
begin
 if not public.staff_has_permission('reports.view') then raise exception 'permission denied'; end if;
 return json_build_object(
  'completed_orders_without_cost_snapshot',(select count(*) from public.orders o where o.status='done' and not exists(select 1 from public.order_cost_snapshots c where c.order_id=o.id)),
  'pos_orders_without_payment',(select count(*) from public.orders o where o.source='pos' and not exists(select 1 from public.payment_transactions p where p.order_id=o.id)),
  'active_menus_without_recipe',(select count(*) from public.menu_items m where m.active and not exists(select 1 from public.menu_recipes r where r.menu_item_id=m.id)),
  'negative_inventory',(select count(*) from public.ingredients where on_hand<0),
  'old_open_shifts',(select count(*) from public.pos_shifts where status='open' and opened_at<now()-interval '16 hours'),
  'direct_order_update_granted',has_table_privilege('authenticated','public.orders','UPDATE')
 );
end $$;

revoke all on function public.set_pos_order_note(uuid,text),public.system_health_check() from public;
grant execute on function public.set_pos_order_note(uuid,text),public.system_health_check() to authenticated;

do $$ begin if has_table_privilege('authenticated','public.orders','UPDATE') then raise exception 'UAT security failure: authenticated still has direct orders UPDATE'; end if; end $$;

commit;
