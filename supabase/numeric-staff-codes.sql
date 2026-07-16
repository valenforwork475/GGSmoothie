-- New employee codes are numeric-only, beginning at 001.
begin;

do $$
declare v_max bigint;
begin
 select max(staff_code::bigint) into v_max from public.staff where staff_code ~ '^[0-9]+$';
 if coalesce(v_max,0)<1 then
  perform setval('public.staff_code_seq',1,false);
 else
  perform setval('public.staff_code_seq',v_max,true);
 end if;
end $$;

create or replace function public.next_staff_code() returns text
language plpgsql security definer set search_path=public as $$
declare v_code text;
begin
 loop
  v_code:=to_char(nextval('public.staff_code_seq'),'FM000');
  exit when not exists(select 1 from public.staff where staff_code=v_code);
 end loop;
 return v_code;
end $$;

revoke all on function public.next_staff_code() from public,anon,authenticated;
grant execute on function public.next_staff_code() to service_role;

commit;
