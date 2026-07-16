-- Automatic cost/margin alerts plus manual payment monitoring support.
begin;

create or replace function public.create_cost_snapshot_alerts() returns trigger
language plpgsql security definer set search_path=public as $$
declare
 v_order public.orders;
 v_item jsonb;
 v_menu_id text;
 v_name text;
 v_qty numeric;
 v_current numeric;
 v_previous numeric;
 v_samples integer;
 v_change numeric;
begin
 if new.source <> 'sale_time' then return new; end if;
 select * into v_order from public.orders where id=new.order_id;

 -- Alert once per order when discounts or cost changes push COGS to 45% of revenue.
 if v_order.total > 0 and new.total_cogs / v_order.total >= 0.45
    and not exists(select 1 from public.backoffice_alerts where entity_type='order_margin' and entity_id=new.order_id::text) then
  insert into public.backoffice_alerts(severity,title,message,entity_type,entity_id)
  values(
   case when new.total_cogs / v_order.total >= 0.60 then 'critical' else 'warning' end,
   'กำไรต่อบิลต่ำกว่าปกติ',
   'บิล #'||coalesce(v_order.queue_no::text,'-')||' มีต้นทุน ฿'||round(new.total_cogs,2)||
   ' จากยอดขาย ฿'||round(v_order.total,2)||' ('||round(new.total_cogs*100/v_order.total,1)||'% ของยอดขาย)',
   'order_margin',new.order_id::text
  );
 end if;

 -- Compare the current per-cup recipe cost with the prior 10 sales of that menu.
 for v_item in select value from jsonb_array_elements(new.item_costs) loop
  v_menu_id:=nullif(v_item->>'menu_id','');
  v_name:=coalesce(nullif(v_item->>'name',''),'เมนู');
  v_qty:=coalesce((v_item->>'qty')::numeric,0);
  if v_menu_id is null or v_qty<=0 then continue; end if;
  v_current:=coalesce((v_item->>'cost')::numeric,0)/v_qty;

  select avg(x.unit_cost),count(*) into v_previous,v_samples
  from (
   select ((old_item->>'cost')::numeric/nullif((old_item->>'qty')::numeric,0)) unit_cost
   from public.order_cost_snapshots s
   cross join lateral jsonb_array_elements(s.item_costs) old_item
   where s.source='sale_time' and s.order_id<>new.order_id
     and old_item->>'menu_id'=v_menu_id and (old_item->>'qty')::numeric>0
   order by s.captured_at desc limit 10
  ) x;

  if v_samples>=3 and v_previous>0 then
   v_change:=(v_current-v_previous)*100/v_previous;
   if v_change>=15 and not exists(
    select 1 from public.backoffice_alerts
    where entity_type='menu_cost' and entity_id=v_menu_id and read_at is null
      and created_at>now()-interval '24 hours'
   ) then
    insert into public.backoffice_alerts(severity,title,message,entity_type,entity_id)
    values(
     case when v_change>=30 then 'critical' else 'warning' end,
     'ต้นทุนเมนูเพิ่มขึ้น: '||v_name,
     'ต้นทุนล่าสุด ฿'||round(v_current,2)||'/แก้ว สูงกว่าค่าเฉลี่ย 10 บิลก่อนหน้า '||round(v_change,1)||'%',
     'menu_cost',v_menu_id
    );
   end if;
  end if;
 end loop;
 return new;
end $$;

drop trigger if exists cost_snapshot_create_alerts on public.order_cost_snapshots;
create trigger cost_snapshot_create_alerts after insert on public.order_cost_snapshots
for each row execute function public.create_cost_snapshot_alerts();

revoke all on function public.create_cost_snapshot_alerts() from public,anon,authenticated;

commit;
