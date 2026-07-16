begin;
insert into public.role_permissions(role,permission,allowed) values ('cashier','menu.create_pos',false),('manager','menu.create_pos',true),('owner','menu.create_pos',true) on conflict(role,permission) do nothing;

create or replace function public.receive_purchase(p_supplier_id uuid,p_invoice_no text,p_ingredient_id uuid,p_quantity numeric,p_unit_cost numeric) returns uuid
language plpgsql security definer set search_path=public as $$ declare v_id uuid; v_total numeric; v_ing public.ingredients; v_avg numeric; begin
 if not public.staff_has_permission('purchasing.edit') then raise exception 'permission denied'; end if;
 if p_quantity<=0 or p_unit_cost<0 then raise exception 'invalid purchase values'; end if;
 select * into v_ing from public.ingredients where id=p_ingredient_id for update; if not found then raise exception 'ingredient not found'; end if;
 v_total:=round(p_quantity*p_unit_cost,2); v_avg:=case when v_ing.on_hand+p_quantity=0 then 0 else ((v_ing.on_hand*v_ing.unit_cost)+(p_quantity*p_unit_cost))/(v_ing.on_hand+p_quantity) end;
 insert into public.purchase_receipts(supplier_id,invoice_no,total,status,received_at,created_by) values(p_supplier_id,nullif(trim(p_invoice_no),''),v_total,'received',now(),auth.uid()) returning id into v_id;
 insert into public.purchase_receipt_items(receipt_id,ingredient_id,quantity,unit_cost) values(v_id,p_ingredient_id,p_quantity,p_unit_cost);
 update public.ingredients set on_hand=on_hand+p_quantity,unit_cost=round(v_avg,4) where id=p_ingredient_id;
 insert into public.stock_movements(ingredient_id,kind,quantity,unit_cost,note,actor_uid) values(p_ingredient_id,'purchase',p_quantity,p_unit_cost,'รับสินค้า '||coalesce(p_invoice_no,'-'),auth.uid());
 insert into public.audit_log(actor_uid,action,entity_type,entity_id,detail) values(auth.uid(),'purchase.receive','purchase_receipt',v_id::text,jsonb_build_object('total',v_total,'purchase_unit_cost',p_unit_cost,'average_unit_cost',round(v_avg,4)));
 return v_id; end $$;

create or replace function public.create_pos_menu(p_name text,p_description text,p_price numeric) returns json language plpgsql security definer set search_path=public as $$ declare v_id text; begin
 if not public.staff_has_permission('menu.create_pos') then raise exception 'permission denied'; end if;
 if length(trim(coalesce(p_name,'')))<2 or p_price<0 then raise exception 'invalid menu'; end if;
 v_id:='p_'||substr(replace(gen_random_uuid()::text,'-',''),1,12);
 insert into public.menu_items(id,name,description,price,active,sort_order) values(v_id,trim(p_name),trim(coalesce(p_description,'')),p_price,false,(select coalesce(max(sort_order),0)+1 from public.menu_items));
 insert into public.audit_log(actor_uid,action,entity_type,entity_id,detail) values(auth.uid(),'menu.create_pos','menu_item',v_id,jsonb_build_object('name',trim(p_name),'price',p_price,'active',false));
 return json_build_object('id',v_id,'name',trim(p_name),'description',trim(coalesce(p_description,'')),'price',p_price,'active',false); end $$;
revoke all on function public.create_pos_menu(text,text,numeric) from public; grant execute on function public.create_pos_menu(text,text,numeric) to authenticated;
commit;
