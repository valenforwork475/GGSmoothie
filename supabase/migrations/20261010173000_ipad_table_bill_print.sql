alter table public.pos_table_orders
  add column if not exists bill_print_payload jsonb,
  add column if not exists bill_print_requested_at timestamptz,
  add column if not exists bill_printed_at timestamptz;

create or replace function public.request_pos_table_bill_print(p_table_no text, p_payload jsonb)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff() then raise exception 'staff access required'; end if;
  update public.pos_table_orders
  set bill_print_payload = coalesce(p_payload, '{}'::jsonb),
      bill_print_requested_at = clock_timestamp()
  where table_no = trim(p_table_no);
  return found;
end $$;

create or replace function public.mark_pos_table_bill_printed(p_table_no text, p_requested_at timestamptz)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff() then raise exception 'staff access required'; end if;
  update public.pos_table_orders
  set bill_printed_at = clock_timestamp()
  where table_no = trim(p_table_no)
    and bill_print_requested_at = p_requested_at;
  return found;
end $$;

grant execute on function public.request_pos_table_bill_print(text,jsonb) to authenticated;
grant execute on function public.mark_pos_table_bill_printed(text,timestamptz) to authenticated;
