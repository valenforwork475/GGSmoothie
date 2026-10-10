begin;

create or replace function public.list_pos_shift_reprints(p_pin text)
returns json
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_result json;
begin
  if p_pin is distinct from '1111' then raise exception 'invalid reprint pin'; end if;
  if not public.staff_has_permission('shifts.own') then raise exception 'permission denied'; end if;
  select coalesce(json_agg(x order by x.closed_at desc),'[]'::json) into v_result
  from (
    select id,opened_at,closed_at,opening_cash,expected_cash,closing_cash,difference,close_note,status
    from public.pos_shifts
    where opened_by=auth.uid() and status='closed' and closed_at is not null
    order by closed_at desc limit 30
  ) x;
  return v_result;
end $$;

create or replace function public.get_pos_shift_reprint(p_shift_id uuid,p_pin text)
returns json
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_shift public.pos_shifts; v_orders json;
begin
  if p_pin is distinct from '1111' then raise exception 'invalid reprint pin'; end if;
  if not public.staff_has_permission('shifts.own') then raise exception 'permission denied'; end if;
  select * into v_shift from public.pos_shifts
  where id=p_shift_id and opened_by=auth.uid() and status='closed';
  if not found then raise exception 'closed shift not found'; end if;
  select coalesce(json_agg(o order by o.created_at),'[]'::json) into v_orders
  from (
    select id,total,pay_method,payment_parts,status,source,created_at,note
    from public.orders
    where created_at>=v_shift.opened_at and created_at<=coalesce(v_shift.closed_at,now())
  ) o;
  return json_build_object('shift',row_to_json(v_shift),'orders',v_orders);
end $$;

revoke all on function public.list_pos_shift_reprints(text),public.get_pos_shift_reprint(uuid,text) from public;
grant execute on function public.list_pos_shift_reprints(text),public.get_pos_shift_reprint(uuid,text) to authenticated;

commit;
