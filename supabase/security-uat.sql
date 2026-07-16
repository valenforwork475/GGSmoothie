begin;

create or replace function public.require_menu_recipe_before_activation() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.active and (tg_op='INSERT' or old.active is distinct from new.active) and not exists(select 1 from public.menu_recipes r where r.menu_item_id=new.id) then raise exception 'recipe required before activation'; end if;
 return new;
end $$;
revoke all on function public.place_pos_order_secure(text,text,jsonb,text,text,numeric) from anon;
revoke all on function public.get_pos_payment_settings(),public.set_pos_promptpay_id(text) from anon;
revoke all on function public.advance_order_status(uuid,text,text),public.mark_order_printed(uuid),public.set_pos_order_note(uuid,text) from anon;

drop trigger if exists menu_require_recipe on public.menu_items;
create trigger menu_require_recipe before insert or update of active on public.menu_items for each row execute function public.require_menu_recipe_before_activation();

do $$
begin
 if has_table_privilege('authenticated','public.orders','UPDATE') then raise exception 'UAT failed: direct order UPDATE granted'; end if;
 if has_function_privilege('authenticated','public.place_order(text,text,jsonb,numeric,text,text)','EXECUTE') then raise exception 'UAT failed: authenticated can bypass secure checkout'; end if;
 if has_function_privilege('anon','public.place_pos_order_secure(text,text,jsonb,text,text,numeric)','EXECUTE') then raise exception 'UAT failed: anon can call POS checkout'; end if;
 if not has_function_privilege('authenticated','public.place_pos_order_secure(text,text,jsonb,text,text,numeric)','EXECUTE') then raise exception 'UAT failed: staff checkout unavailable'; end if;
 if not has_function_privilege('service_role','public.confirm_payment_webhook(text,text,uuid,numeric,text,jsonb)','EXECUTE') then raise exception 'UAT failed: webhook unavailable'; end if;
 if coalesce((select allowed from public.role_permissions where role='cashier' and permission='payments.reconcile'),true) then raise exception 'UAT failed: cashier payment reconciliation'; end if;
 if not coalesce((select allowed from public.role_permissions where role='manager' and permission='payments.reconcile'),false) then raise exception 'UAT failed: manager cannot reconcile'; end if;
 if not coalesce((select allowed from public.role_permissions where role='owner' and permission='payments.reconcile'),false) then raise exception 'UAT failed: owner cannot reconcile'; end if;
end $$;

commit;
