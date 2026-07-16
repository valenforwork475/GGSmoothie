begin;

create table if not exists public.pos_payment_settings(
  singleton boolean primary key default true check(singleton),
  promptpay_id text not null default '',
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);
insert into public.pos_payment_settings(singleton) values(true) on conflict(singleton) do nothing;
alter table public.pos_payment_settings enable row level security;
revoke all on table public.pos_payment_settings from anon,authenticated;

create or replace function public.get_pos_payment_settings()
returns json language plpgsql security definer set search_path=public as $$
declare v_id text;
begin
 if not public.is_staff() then raise exception 'staff access required'; end if;
 select promptpay_id into v_id from public.pos_payment_settings where singleton=true;
 return json_build_object('promptpay_id',coalesce(v_id,''));
end $$;

create or replace function public.set_pos_promptpay_id(p_promptpay_id text)
returns void language plpgsql security definer set search_path=public as $$
declare v_id text:=regexp_replace(coalesce(p_promptpay_id,''),'\D','','g');
begin
 if not public.staff_has_permission('menu.create_pos') then raise exception 'manager permission required'; end if;
 if length(v_id) not in (10,13) then raise exception 'invalid PromptPay identifier'; end if;
 insert into public.pos_payment_settings(singleton,promptpay_id,updated_at,updated_by)
 values(true,v_id,now(),auth.uid()) on conflict(singleton) do update
 set promptpay_id=excluded.promptpay_id,updated_at=now(),updated_by=auth.uid();
 insert into public.audit_log(actor_uid,action,entity_type,entity_id,detail)
 values(auth.uid(),'pos.promptpay.update','pos_settings','payment',jsonb_build_object('identifier_length',length(v_id)));
end $$;

create or replace function public.place_pos_order_secure(
 p_name text,p_phone text,p_items jsonb,p_pay_method text,
 p_promo_code text default null,p_manual_discount numeric default 0
) returns json language plpgsql security definer set search_path=public as $$
declare
 v_line jsonb; v_menu public.menu_items; v_items jsonb:='[]'::jsonb;
 v_qty numeric; v_price numeric; v_subtotal numeric:=0; v_discount numeric:=0;
 v_promo public.promotions; v_result json; v_label text;
begin
 if not public.is_staff() then raise exception 'staff access required'; end if;
 if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items)=0 then raise exception 'items required'; end if;
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
   v_discount:=p_manual_discount; v_label:='ส่วนลดโดยผู้จัดการ';
 end if;
 v_discount:=least(v_subtotal-0.01,greatest(0,v_discount));
 if v_discount>0 then v_items:=v_items||jsonb_build_array(jsonb_build_object('kind','discount','menu_id',null,'name',v_label,'qty',1,'price',-v_discount,'desc','ส่วนลด')); end if;
 v_result:=public.place_order(coalesce(nullif(trim(p_name),''),'หน้าร้าน'),coalesce(p_phone,''),v_items,round(v_subtotal-v_discount,2),p_pay_method,'pos');
 if v_promo.id is not null then update public.promotions set used_count=used_count+1 where id=v_promo.id; end if;
 insert into public.audit_log(actor_uid,action,entity_type,entity_id,detail) values(auth.uid(),'pos.checkout','order',v_result->>'id',jsonb_build_object('subtotal',v_subtotal,'discount',v_discount,'promotion',v_promo.code,'pay_method',p_pay_method));
 return v_result;
end $$;

revoke all on function public.get_pos_payment_settings() from public;
revoke all on function public.set_pos_promptpay_id(text) from public;
revoke all on function public.place_pos_order_secure(text,text,jsonb,text,text,numeric) from public;
grant execute on function public.get_pos_payment_settings() to authenticated;
grant execute on function public.set_pos_promptpay_id(text) to authenticated;
grant execute on function public.place_pos_order_secure(text,text,jsonb,text,text,numeric) to authenticated;

commit;
