begin;
create or replace function public.cancel_purchase_receipt(p_receipt_id uuid,p_reason text default 'บันทึกผิด') returns json
language plpgsql security definer set search_path=public as $$
declare v_receipt public.purchase_receipts; v_item record; v_on_hand numeric; v_previous_cost numeric;
begin
 if not public.staff_has_role(array['owner']) then raise exception 'owner only'; end if;
 if length(trim(coalesce(p_reason,'')))<3 then raise exception 'reason required'; end if;
 select * into v_receipt from public.purchase_receipts where id=p_receipt_id and status='received' for update;
 if not found then raise exception 'active purchase receipt not found'; end if;
 for v_item in select * from public.purchase_receipt_items where receipt_id=p_receipt_id loop
   select on_hand into v_on_hand from public.ingredients where id=v_item.ingredient_id for update;
   if v_on_hand<v_item.quantity then raise exception 'cannot cancel: stock already used'; end if;
   select pri.unit_cost into v_previous_cost from public.purchase_receipt_items pri join public.purchase_receipts pr on pr.id=pri.receipt_id
    where pri.ingredient_id=v_item.ingredient_id and pr.status='received' and pr.id<>p_receipt_id order by pr.received_at desc nulls last limit 1;
   update public.ingredients set on_hand=on_hand-v_item.quantity,unit_cost=coalesce(v_previous_cost,unit_cost) where id=v_item.ingredient_id;
   insert into public.stock_movements(ingredient_id,kind,quantity,unit_cost,note,actor_uid)
    values(v_item.ingredient_id,'adjustment',-v_item.quantity,v_item.unit_cost,'ย้อนรายการรับเข้า '||p_receipt_id::text,auth.uid());
 end loop;
 update public.purchase_receipts set status='cancelled' where id=p_receipt_id;
 insert into public.audit_log(actor_uid,action,entity_type,entity_id,detail) values(auth.uid(),'purchase.cancel','purchase_receipt',p_receipt_id::text,jsonb_build_object('reason',trim(p_reason),'total',v_receipt.total));
 return json_build_object('id',p_receipt_id,'status','cancelled');
end $$;
revoke all on function public.cancel_purchase_receipt(uuid,text) from public;
grant execute on function public.cancel_purchase_receipt(uuid,text) to authenticated;
commit;
