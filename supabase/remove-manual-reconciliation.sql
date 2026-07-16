-- Manual reference entry was removed from the product flow. Keep the ledger and
-- service-role webhook for a future automatic provider integration.
begin;

delete from public.role_permissions where permission='payments.reconcile';
drop function if exists public.reconcile_payment(uuid,text,text);

commit;
