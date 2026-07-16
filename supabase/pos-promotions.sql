-- POS promotion validation and auditable usage. Source of truth is the promotions table.
create or replace function public.validate_pos_promotion(p_code text,p_subtotal numeric)
returns json language plpgsql security definer set search_path=public as $$
declare v public.promotions; v_discount numeric;
begin
 if not public.is_staff() then raise exception 'staff access required'; end if;
 select * into v from public.promotions where upper(code)=upper(trim(p_code)) and active=true and starts_at<=now() and ends_at>=now() limit 1;
 if not found then raise exception 'promotion not found or expired'; end if;
 if p_subtotal<v.min_spend then raise exception 'minimum spend is %',v.min_spend; end if;
 v_discount:=case when v.discount_type='percent' then round(p_subtotal*v.discount_value/100,2) else v.discount_value end;
 return json_build_object('code',v.code,'label',v.name,'discount_amount',least(p_subtotal,greatest(0,v_discount)));
end $$;

create or replace function public.record_pos_promotion_use(p_code text,p_order_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v public.promotions;
begin
 if not public.is_staff() or not exists(select 1 from public.orders where id=p_order_id and created_by=auth.uid() and source='pos') then raise exception 'access denied'; end if;
 if exists(select 1 from public.audit_log where action='promotion.use' and entity_id=p_order_id::text) then return; end if;
 select * into v from public.promotions where upper(code)=upper(trim(p_code)) for update;
 if not found then raise exception 'promotion not found'; end if;
 update public.promotions set used_count=used_count+1 where id=v.id;
 insert into public.audit_log(actor_uid,action,entity_type,entity_id,detail) values(auth.uid(),'promotion.use','order',p_order_id::text,jsonb_build_object('code',v.code));
end $$;

revoke all on function public.validate_pos_promotion(text,numeric),public.record_pos_promotion_use(text,uuid) from public;
grant execute on function public.validate_pos_promotion(text,numeric),public.record_pos_promotion_use(text,uuid) to authenticated;
