-- Race-safe automatic employee codes: GG001, GG002, ...
begin;

create sequence if not exists public.staff_code_seq;
do $$
declare v_max bigint;
begin
 select max(substring(staff_code from '^GG([0-9]+)$')::bigint) into v_max
 from public.staff where staff_code ~ '^GG[0-9]+$';
 if coalesce(v_max,0)=0 then
  perform setval('public.staff_code_seq',1,false);
 else
  perform setval('public.staff_code_seq',v_max,true);
 end if;
end $$;

create or replace function public.next_staff_code() returns text
language plpgsql security definer set search_path=public as $$
declare v_number bigint; v_code text;
begin
 loop
  v_number:=nextval('public.staff_code_seq');
  v_code:='GG'||to_char(v_number,'FM000');
  exit when not exists(select 1 from public.staff where lower(staff_code)=lower(v_code));
 end loop;
 return v_code;
end $$;

revoke all on function public.next_staff_code() from public,anon,authenticated;
grant execute on function public.next_staff_code() to service_role;

commit;
