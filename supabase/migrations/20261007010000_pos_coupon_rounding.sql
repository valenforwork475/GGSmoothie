begin;

-- POS checkout v2: คูปองส่วนลด (฿100/ใบ) + ปัดเศษยอดชำระ (≥ .50 ปัดขึ้น / < .50 ปัดลง)
create or replace function public.place_pos_order_v2(
 p_name text,p_phone text,p_items jsonb,p_pay_method text,
 p_promo_code text default null,p_manual_discount numeric default 0,
 p_coupon_count integer default 0
) returns json language plpgsql security definer set search_path=public as $$
declare
 v_line jsonb; v_menu public.menu_items; v_items jsonb:='[]'::jsonb;
 v_qty numeric; v_price numeric; v_subtotal numeric:=0; v_discount numeric:=0;
 v_coupon numeric:=0; v_net numeric; v_total numeric; v_rounding numeric;
 v_coupons integer:=greatest(0,coalesce(p_coupon_count,0));
 v_promo public.promotions; v_result json; v_label text;
begin
 if not public.is_staff() then raise exception 'staff access required'; end if;
 if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items)=0 then raise exception 'items required'; end if;
 if v_coupons>50 then raise exception 'too many coupons'; end if;
 for v_line in select value from jsonb_array_elements(p_items) loop
   begin
     select * into v_menu from public.menu_items where id=(v_line->>'menu_id') and active=true;
     v_qty:=(v_line->>'qty')::numeric; v_price:=(v_line->>'price')::numeric;
   exception when others then raise exception 'invalid order item'; end;
   if not found or v_qty<=0 or v_qty<>trunc(v_qty) or v_qty>99 then raise exception 'invalid menu or quantity'; end if;
   if v_price<v_menu.price or v_price>v_menu.price+500 then raise exception 'invalid item price'; end if;
   v_subtotal:=v_subtotal+(v_qty*v_price);
   v_items:=v_items||jsonb_build_array(jsonb_build_object(
     'kind','pos','menu_id',v_menu.id,'name',v_menu.name,'qty',v_qty,'price',v_price,
     'desc',coalesce(v_line->>'desc',''),'cal',v_menu.cal,'p',v_menu.p,'f',v_menu.f,'sug',v_menu.sug));
 end loop;
 if nullif(trim(coalesce(p_promo_code,'')),'') is not null and coalesce(p_manual_discount,0)>0 then raise exception 'choose one discount type'; end if;
 if nullif(trim(coalesce(p_promo_code,'')),'') is not null then
   select * into v_promo from public.promotions where upper(code)=upper(trim(p_promo_code)) and active=true and starts_at<=now() and ends_at>=now() for update;
   if not found or v_subtotal<v_promo.min_spend then raise exception 'promotion unavailable'; end if;
   v_discount:=case when v_promo.discount_type='percent' then round(v_subtotal*v_promo.discount_value/100,2) else v_promo.discount_value end;
   v_label:=v_promo.name;
 elsif coalesce(p_manual_discount,0)>0 then
   if not public.staff_has_permission('refunds.approve') then raise exception 'manager permission required for discount'; end if;
   v_discount:=p_manual_discount; v_label:='ส่วนลด';
 end if;
 v_discount:=least(v_subtotal,greatest(0,round(v_discount,2)));
 if v_discount>0 then v_items:=v_items||jsonb_build_array(jsonb_build_object('kind','discount','menu_id',null,'name',v_label,'qty',1,'price',-v_discount,'desc','ส่วนลด')); end if;
 if v_coupons>0 then
   v_coupon:=least(v_subtotal-v_discount,v_coupons*100);
   if v_coupon>0 then v_items:=v_items||jsonb_build_array(jsonb_build_object('kind','coupon','menu_id',null,'name','คูปองส่วนลด ฿100 × '||v_coupons,'qty',1,'price',-v_coupon,'desc','คูปอง')); end if;
 end if;
 v_net:=greatest(0,v_subtotal-v_discount-v_coupon);
 v_total:=round(v_net,0);
 v_rounding:=v_total-v_net;
 if v_rounding<>0 then v_items:=v_items||jsonb_build_array(jsonb_build_object('kind','rounding','menu_id',null,'name','ปัดเศษ','qty',1,'price',v_rounding,'desc','ปัดเศษ')); end if;
 v_result:=public.place_order(coalesce(nullif(trim(p_name),''),'หน้าร้าน'),coalesce(p_phone,''),v_items,v_total,p_pay_method,'pos');
 if v_promo.id is not null then update public.promotions set used_count=used_count+1 where id=v_promo.id; end if;
 insert into public.audit_log(actor_uid,action,entity_type,entity_id,detail) values(auth.uid(),'pos.checkout','order',v_result->>'id',jsonb_build_object('subtotal',v_subtotal,'discount',v_discount,'coupon_count',v_coupons,'coupon',v_coupon,'rounding',v_rounding,'promotion',v_promo.code,'pay_method',p_pay_method));
 return (v_result::jsonb||jsonb_build_object('total',v_total,'rounding',v_rounding))::json;
end $$;
revoke all on function public.place_pos_order_v2(text,text,jsonb,text,text,numeric,integer) from public;
revoke all on function public.place_pos_order_v2(text,text,jsonb,text,text,numeric,integer) from anon;
grant execute on function public.place_pos_order_v2(text,text,jsonb,text,text,numeric,integer) to authenticated;
commit;
