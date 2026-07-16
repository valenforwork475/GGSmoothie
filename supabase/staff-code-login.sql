-- Employee-code login for POS and auditable/rate-limited staff authentication.
begin;

alter table public.staff add column if not exists staff_code text;
alter table public.staff drop constraint if exists staff_code_format;
alter table public.staff add constraint staff_code_format check(
 staff_code is null or staff_code ~ '^[A-Z0-9][A-Z0-9_-]{2,19}$'
);
create unique index if not exists staff_code_unique on public.staff(lower(staff_code)) where staff_code is not null;

create table if not exists public.staff_login_events(
 id bigint generated always as identity primary key,
 uid uuid references auth.users(id) on delete set null,
 identifier text not null,
 surface text not null check(surface in ('pos','backoffice')),
 success boolean not null,
 user_agent text,
 created_at timestamptz not null default now()
);
create index if not exists staff_login_events_identifier_time on public.staff_login_events(identifier,created_at desc);
create index if not exists staff_login_events_uid_time on public.staff_login_events(uid,created_at desc);

alter table public.staff_login_events enable row level security;
drop policy if exists "staff managers read login events" on public.staff_login_events;
create policy "staff managers read login events" on public.staff_login_events
for select to authenticated using(public.staff_has_permission('staff.manage'));
revoke all on table public.staff_login_events from anon,authenticated;
grant select on table public.staff_login_events to authenticated;

commit;
