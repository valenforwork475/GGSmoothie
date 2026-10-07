create or replace function public.upsert_pos_table_order(
  p_table_no text,
  p_guest_count int,
  p_cart jsonb,
  p_note text default '',
  p_co_phone text default '',
  p_expected_version bigint default 0,
  p_kitchen_pending boolean default true
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_current public.pos_table_orders;
  v_saved public.pos_table_orders;
begin
  if not public.is_staff() then raise exception 'staff access required'; end if;
  if coalesce(trim(p_table_no), '') = '' then raise exception 'table required'; end if;
  if jsonb_typeof(p_cart) is distinct from 'array' then
    raise exception 'cart must be an array';
  end if;

  select * into v_current from public.pos_table_orders where table_no = trim(p_table_no) for update;
  if found and v_current.version <> coalesce(p_expected_version, 0) then
    raise exception 'table order changed on another device';
  end if;

  -- If cart is empty, user canceled all items -> clear table
  if jsonb_array_length(p_cart) = 0 then
    delete from public.pos_table_orders where table_no = trim(p_table_no);
    return null;
  end if;

  insert into public.pos_table_orders (
    table_no, guest_count, cart, note, co_phone, version, kitchen_pending, opened_at, updated_at, updated_by
  ) values (
    trim(p_table_no), greatest(0, least(coalesce(p_guest_count, 1), 99)), p_cart,
    coalesce(p_note, ''), coalesce(p_co_phone, ''), 1, coalesce(p_kitchen_pending, true), now(), now(), auth.uid()
  )
  on conflict (table_no) do update set
    guest_count = excluded.guest_count,
    cart = excluded.cart,
    note = excluded.note,
    co_phone = excluded.co_phone,
    version = public.pos_table_orders.version + 1,
    kitchen_pending = excluded.kitchen_pending,
    updated_at = now(),
    updated_by = auth.uid()
  returning * into v_saved;

  return to_jsonb(v_saved);
end $$;
