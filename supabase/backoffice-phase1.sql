-- GG Back Office Phase 1
-- Employee directory fields used by the secure admin-staff Edge Function.
begin;

alter table public.staff add column if not exists email text;
alter table public.staff add column if not exists updated_at timestamptz not null default now();

create unique index if not exists staff_email_unique_idx
  on public.staff (lower(email)) where email is not null;

create or replace function public.tg_touch_staff_updated_at() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists staff_touch on public.staff;
create trigger staff_touch before update on public.staff
  for each row execute function public.tg_touch_staff_updated_at();

-- The browser may only read rows allowed by RLS. Staff writes are intentionally
-- performed by the admin-staff Edge Function after it verifies manager/owner.
revoke insert, update, delete on table public.staff from authenticated;
grant select on table public.staff to authenticated;

commit;