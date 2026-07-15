-- POS order cancellation and automatic refund/stock restoration
begin;

create or replace function public.cancel_pos_order(p_order_id uuid,p_reason text) returns json
language plpgsql security definer set search_path=public as $$
declare v_order public.orders; v_refund_id uuid; v_line jsonb; v_recipe record; v_qty numeric; v_restore numeric;
begin
  if not public.staff_has_permission('pos.sell') then raise exception 'permission denied'; end if;
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'reason required'; end if;
  select * into v_order from public.orders where id=p_order_id for update;
  if not found then raise exception 'order not found'; end if;
  if v_order.status not in ('pending','confirmed') then raise exception 'order can no longer be cancelled'; end if;

  -- Confirmed orders are treated as paid and require refund approval.
  if v_order.status='confirmed' then
    if not public.staff_has_permission('refunds.approve') then raise exception 'manager approval required'; end if;
    if exists(select 1 from public.refunds where order_id=p_order_id and status='approved') then raise exception 'order already refunded'; end if;
    insert into public.refunds(order_id,amount,reason,status,requested_by,approved_by)
      values(p_order_id,v_order.total,trim(p_reason),'approved',auth.uid(),auth.uid()) returning id into v_refund_id;
    if v_order.pay_method='cash' and v_order.shift_id is not null then
      insert into public.cash_movements(shift_id,kind,amount,reason,order_id,created_by)
        values(v_order.shift_id,'refund',v_order.total,trim(p_reason),p_order_id,auth.uid());
    end if;
  end if;

  -- Inventory was deducted when the order became confirmed. Restore it once.
  if v_order.inventory_applied_at is not null then
    for v_line in select value from jsonb_array_elements(v_order.items) loop
      v_qty:=greatest(coalesce((v_line->>'qty')::numeric,0),0);
      for v_recipe in select ingredient_id,quantity from public.menu_recipes where menu_item_id=nullif(v_line->>'menu_id','') loop
        v_restore:=v_recipe.quantity*v_qty;
        update public.ingredients set on_hand=on_hand+v_restore where id=v_recipe.ingredient_id;
        insert into public.stock_movements(ingredient_id,kind,quantity,note,order_id,actor_uid)
          values(v_recipe.ingredient_id,'restore',v_restore,'คืนสต๊อกจากออเดอร์ยกเลิก',p_order_id,auth.uid());
      end loop;
    end loop;
  end if;

  update public.orders set status='cancelled',note=concat_ws(E'\n',nullif(note,''),'ยกเลิก: '||trim(p_reason)) where id=p_order_id;
  insert into public.audit_log(actor_uid,action,entity_type,entity_id,detail)
    values(auth.uid(),case when v_refund_id is null then 'order.cancel' else 'order.cancel_refund' end,'order',p_order_id::text,
      jsonb_build_object('reason',trim(p_reason),'amount',case when v_refund_id is null then 0 else v_order.total end,'refund_id',v_refund_id));
  return json_build_object('order_id',p_order_id,'cancelled',true,'refunded',v_refund_id is not null,'refund_id',v_refund_id,'amount',case when v_refund_id is null then 0 else v_order.total end);
end $$;

revoke all on function public.cancel_pos_order(uuid,text) from public;
grant execute on function public.cancel_pos_order(uuid,text) to authenticated;
commit;
