begin;
alter table public.purchase_receipts add column if not exists document_type text not null default 'receipt' check(document_type in ('receipt','cash_note','tax_invoice'));
alter table public.purchase_receipts add column if not exists tax_mode text not null default 'non_vat' check(tax_mode in ('non_vat','vat_inclusive'));
alter table public.suppliers add column if not exists tax_id text;

create table if not exists public.shift_reopen_requests(
 id uuid primary key default gen_random_uuid(), shift_id uuid not null references public.pos_shifts(id),
 requested_by uuid not null references auth.users(id), reason text not null,
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 reviewed_by uuid references auth.users(id), reviewed_at timestamptz, created_at timestamptz not null default now()
);
create unique index if not exists shift_reopen_one_pending on public.shift_reopen_requests(shift_id) where status='pending';
alter table public.shift_reopen_requests enable row level security;
create policy "staff read own reopen requests" on public.shift_reopen_requests for select to authenticated using(requested_by=auth.uid() or public.staff_has_permission('shifts.review'));
grant select on public.shift_reopen_requests to authenticated;

create or replace function public.request_last_shift_reopen(p_reason text) returns json language plpgsql security definer set search_path=public as $$
declare v_shift public.pos_shifts; v_req public.shift_reopen_requests; begin
 if not public.staff_has_permission('shifts.own') then raise exception 'permission denied'; end if;
 if length(trim(coalesce(p_reason,'')))<3 then raise exception 'reason required'; end if;
 if exists(select 1 from public.pos_shifts where opened_by=auth.uid() and status='open') then raise exception 'shift already open'; end if;
 select * into v_shift from public.pos_shifts where opened_by=auth.uid() and status='closed' order by closed_at desc limit 1;
 if not found then raise exception 'closed shift not found'; end if;
 insert into public.shift_reopen_requests(shift_id,requested_by,reason) values(v_shift.id,auth.uid(),trim(p_reason))
 on conflict(shift_id) where status='pending' do update set reason=excluded.reason,created_at=now() returning * into v_req;
 insert into public.audit_log(actor_uid,action,entity_type,entity_id,detail) values(auth.uid(),'shift.reopen_request','pos_shift',v_shift.id::text,jsonb_build_object('request_id',v_req.id,'reason',v_req.reason));
 return json_build_object('id',v_req.id,'status',v_req.status,'shift_id',v_shift.id); end $$;

create or replace function public.approve_shift_reopen(p_request_id uuid) returns json language plpgsql security definer set search_path=public as $$
declare v_req public.shift_reopen_requests; v_shift public.pos_shifts; begin
 if not public.staff_has_permission('shifts.review') then raise exception 'permission denied'; end if;
 select * into v_req from public.shift_reopen_requests where id=p_request_id and status='pending' for update; if not found then raise exception 'pending request not found'; end if;
 select * into v_shift from public.pos_shifts where id=v_req.shift_id and status='closed' for update; if not found then raise exception 'closed shift not found'; end if;
 if exists(select 1 from public.pos_shifts where opened_by=v_shift.opened_by and status='open') then raise exception 'staff already has open shift'; end if;
 update public.pos_shifts set status='open',closed_by=null,closed_at=null,closing_cash=null,expected_cash=null,difference=null,close_note=null where id=v_shift.id;
 update public.shift_reopen_requests set status='approved',reviewed_by=auth.uid(),reviewed_at=now() where id=v_req.id;
 insert into public.audit_log(actor_uid,action,entity_type,entity_id,detail) values(auth.uid(),'shift.reopen_approve','pos_shift',v_shift.id::text,jsonb_build_object('request_id',v_req.id,'reason',v_req.reason,'original_opened_at',v_shift.opened_at));
 return json_build_object('shift_id',v_shift.id,'status','open'); end $$;
revoke all on function public.request_last_shift_reopen(text) from public; revoke all on function public.approve_shift_reopen(uuid) from public;
grant execute on function public.request_last_shift_reopen(text) to authenticated; grant execute on function public.approve_shift_reopen(uuid) to authenticated;
commit;
