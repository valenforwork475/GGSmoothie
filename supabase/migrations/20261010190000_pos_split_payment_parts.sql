begin;

alter table public.orders
  add column if not exists payment_parts jsonb not null default '[]'::jsonb;

create or replace function public.set_pos_order_payment_parts(p_order_id uuid,p_payment_parts jsonb)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.staff_has_permission('pos.sell') then raise exception 'permission denied'; end if;
  if jsonb_typeof(coalesce(p_payment_parts,'[]'::jsonb)) <> 'array' then raise exception 'payment parts must be an array'; end if;
  if exists (
    select 1 from jsonb_array_elements(coalesce(p_payment_parts,'[]'::jsonb)) part
    where coalesce((part->>'amount')::numeric,0) < 0
      or nullif(trim(coalesce(part->>'methodId','')),'') is null
  ) then raise exception 'invalid payment part'; end if;

  update public.orders
  set payment_parts=coalesce(p_payment_parts,'[]'::jsonb)
  where id=p_order_id and source='pos' and created_by=auth.uid() and status<>'cancelled';
  if not found then raise exception 'order not owned by staff'; end if;
end $$;

revoke all on function public.set_pos_order_payment_parts(uuid,jsonb) from public;
grant execute on function public.set_pos_order_payment_parts(uuid,jsonb) to authenticated;

commit;
