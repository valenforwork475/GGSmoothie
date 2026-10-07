begin;

-- Allow 'none' (ไม่ออกเครื่องปริ้น) in menu_items printer_route check constraint
alter table public.menu_items drop constraint if exists menu_items_printer_route_check;
alter table public.menu_items add constraint menu_items_printer_route_check check (printer_route in ('main','kitchen','none','skip','no_print'));

commit;
