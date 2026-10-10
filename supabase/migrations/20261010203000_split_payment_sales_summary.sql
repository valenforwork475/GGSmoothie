begin;

create or replace function public.sales_summary(p_from timestamptz,p_to timestamptz)
returns json
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_result json;
begin
  if not public.staff_has_permission('reports.view') then raise exception 'permission denied'; end if;
  if p_from is null or p_to is null or p_to<=p_from or p_to-p_from>interval '370 days' then raise exception 'invalid report range'; end if;

  with filtered as (
    select * from public.orders
    where created_at>=p_from and created_at<p_to and status<>'cancelled'
  ), lines as (
    select o.id,o.created_at,o.pay_method,x.value item,
      coalesce((x.value->>'qty')::numeric,0) qty,
      coalesce((x.value->>'price')::numeric,0) price
    from filtered o cross join lateral jsonb_array_elements(o.items)x
    where coalesce(x.value->>'kind','') not in ('discount','coupon','rounding')
  ), payment_lines as (
    select f.id,
      coalesce(nullif(trim(part->>'methodId'),''),f.pay_method) pay_method,
      coalesce((part->>'amount')::numeric,f.total) amount
    from filtered f
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(f.payment_parts)='array' and jsonb_array_length(f.payment_parts)>0
        then f.payment_parts
        else jsonb_build_array(jsonb_build_object('methodId',f.pay_method,'amount',f.total))
      end
    ) part
  )
  select json_build_object(
    'revenue',coalesce((select sum(total) from filtered),0),
    'orders',coalesce((select count(*) from filtered),0),
    'cups',coalesce((select sum(qty) from lines),0),
    'cogs',coalesce((select sum(c.total_cogs) from filtered f left join public.order_cost_snapshots c on c.order_id=f.id),0),
    'by_day',coalesce((select json_agg(d order by report_day) from (select (created_at at time zone 'Asia/Bangkok')::date report_day,sum(total) revenue,count(*) orders from filtered group by 1)d),'[]'::json),
    'payments',coalesce((select json_agg(p order by revenue desc) from (select pay_method,sum(amount) revenue,count(distinct id) orders from payment_lines group by 1)p),'[]'::json),
    'top_items',coalesce((select json_agg(t order by quantity desc,name) from (select coalesce(nullif(item->>'name',''),'ไม่ระบุ') name,sum(qty) quantity,sum(qty*price) revenue from lines group by 1)t),'[]'::json)
  ) into v_result;
  return v_result;
end $$;

commit;
