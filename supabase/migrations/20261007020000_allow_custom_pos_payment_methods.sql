begin;

create or replace function public.place_order(
  p_name text, p_phone text, p_items jsonb, p_total numeric,
  p_pay_method text default 'promptpay', p_source text default 'web'
) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_order public.orders;
  v_payment_method text := lower(trim(coalesce(p_pay_method, 'promptpay')));
begin
  if coalesce(trim(p_name), '') = '' then
    raise exception 'name required';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'items required';
  end if;
  if p_total is null or p_total < 0 or p_total > 500000 then
    raise exception 'bad total';
  end if;
  if p_source not in ('web','pos') then
    raise exception 'bad source';
  end if;

  -- สำหรับสั่งผ่านเว็บยังคงจำกัดตามช่องทางที่เปิดรับ แต่หน้าร้าน POS อนุญาตทุกช่องทางที่ร้านตั้งขึ้น (เช่น 60/40, โอน, บัตร ฯลฯ)
  if p_source = 'web' and v_payment_method not in ('promptpay','cash','card','wechat','alipay') then
    raise exception 'bad payment method';
  end if;
  if length(v_payment_method) = 0 or length(v_payment_method) > 64 then
    raise exception 'bad payment method';
  end if;

  perform pg_advisory_xact_lock(920316);

  insert into public.orders (queue_no, customer_name, phone, items, total, pay_method, source)
  values (
    public.next_queue_no(),
    trim(p_name),
    nullif(trim(coalesce(p_phone, '')), ''),
    p_items,
    p_total,
    v_payment_method,
    p_source
  )
  returning * into v_order;

  return json_build_object('id', v_order.id, 'queue_no', v_order.queue_no, 'status', v_order.status);
end $$;

revoke all on function public.place_order(text,text,jsonb,numeric,text,text) from authenticated;
grant execute on function public.place_order(text,text,jsonb,numeric,text,text) to anon;

commit;
