-- GG Back Office Phase 2
-- Granular permissions, inventory/recipes, automatic stock usage, and profit reports.

begin;

create table if not exists public.role_permissions (
  role text not null check (role in ('cashier','manager','owner')),
  permission text not null,
  allowed boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (role, permission)
);

insert into public.role_permissions (role, permission, allowed) values
  ('cashier','pos.sell',true), ('cashier','shifts.own',true),
  ('manager','pos.sell',true), ('manager','shifts.own',true),
  ('manager','shifts.review',true), ('manager','reports.view',true),
  ('manager','inventory.view',true), ('manager','inventory.edit',true),
  ('manager','menu.edit',true), ('manager','staff.manage',true),
  ('manager','refunds.approve',true),
  ('owner','pos.sell',true), ('owner','shifts.own',true),
  ('owner','shifts.review',true), ('owner','reports.view',true),
  ('owner','inventory.view',true), ('owner','inventory.edit',true),
  ('owner','menu.edit',true), ('owner','staff.manage',true),
  ('owner','refunds.approve',true), ('owner','permissions.manage',true)
on conflict (role, permission) do nothing;

create or replace function public.staff_has_permission(p_permission text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.staff s
    join public.role_permissions rp on rp.role = s.role
    where s.uid = auth.uid() and s.active = true
      and rp.permission = p_permission and rp.allowed = true
  )
$$;

create table if not exists public.ingredients (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  unit text not null check (unit in ('g','ml','ชิ้น','ขวด','ถุง','กก.','ลิตร')),
  on_hand numeric(14,3) not null default 0,
  reorder_level numeric(14,3) not null default 0,
  unit_cost numeric(14,4) not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (on_hand >= 0), check (reorder_level >= 0), check (unit_cost >= 0)
);

create table if not exists public.menu_recipes (
  menu_item_id text not null references public.menu_items(id) on delete cascade,
  ingredient_id uuid not null references public.ingredients(id) on delete restrict,
  quantity numeric(14,3) not null check (quantity > 0),
  updated_at timestamptz not null default now(),
  primary key (menu_item_id, ingredient_id)
);

create table if not exists public.stock_movements (
  id bigint generated always as identity primary key,
  ingredient_id uuid not null references public.ingredients(id),
  kind text not null check (kind in ('purchase','use','waste','adjustment','restore')),
  quantity numeric(14,3) not null,
  unit_cost numeric(14,4),
  note text,
  order_id uuid references public.orders(id),
  actor_uid uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check (quantity <> 0)
);

create index if not exists stock_movements_ingredient_idx
  on public.stock_movements (ingredient_id, created_at desc);
create index if not exists recipes_menu_idx on public.menu_recipes (menu_item_id);
alter table public.orders add column if not exists inventory_applied_at timestamptz;

drop trigger if exists ingredients_touch on public.ingredients;
create trigger ingredients_touch before update on public.ingredients
for each row execute function public.tg_touch_updated_at();

alter table public.role_permissions enable row level security;
alter table public.ingredients enable row level security;
alter table public.menu_recipes enable row level security;
alter table public.stock_movements enable row level security;

drop policy if exists "management read role permissions" on public.role_permissions;
drop policy if exists "owner update role permissions" on public.role_permissions;
create policy "management read role permissions" on public.role_permissions
  for select to authenticated using (public.staff_has_role(array['manager','owner']));
create policy "owner update role permissions" on public.role_permissions
  for update to authenticated using (public.staff_has_role(array['owner']))
  with check (public.staff_has_role(array['owner']) and not (role = 'owner' and permission = 'permissions.manage' and allowed = false));

drop policy if exists "permitted read ingredients" on public.ingredients;
drop policy if exists "permitted write ingredients" on public.ingredients;
create policy "permitted read ingredients" on public.ingredients
  for select to authenticated using (public.staff_has_permission('inventory.view'));
create policy "permitted write ingredients" on public.ingredients
  for all to authenticated using (public.staff_has_permission('inventory.edit'))
  with check (public.staff_has_permission('inventory.edit'));

drop policy if exists "permitted read recipes" on public.menu_recipes;
drop policy if exists "permitted write recipes" on public.menu_recipes;
create policy "permitted read recipes" on public.menu_recipes
  for select to authenticated using (public.staff_has_permission('inventory.view'));
create policy "permitted write recipes" on public.menu_recipes
  for all to authenticated using (public.staff_has_permission('inventory.edit'))
  with check (public.staff_has_permission('inventory.edit'));

drop policy if exists "permitted read stock movements" on public.stock_movements;
create policy "permitted read stock movements" on public.stock_movements
  for select to authenticated using (public.staff_has_permission('inventory.view'));

revoke all on table public.role_permissions, public.ingredients, public.menu_recipes, public.stock_movements from anon, authenticated;
grant select on table public.role_permissions, public.ingredients, public.menu_recipes, public.stock_movements to authenticated;
grant update (allowed) on table public.role_permissions to authenticated;
grant insert (name, unit, reorder_level, unit_cost, active) on table public.ingredients to authenticated;
grant update (name, unit, reorder_level, unit_cost, active) on table public.ingredients to authenticated;
grant insert, update, delete on table public.menu_recipes to authenticated;

create or replace function public.adjust_stock(
  p_ingredient_id uuid, p_kind text, p_quantity numeric,
  p_unit_cost numeric default null, p_note text default null
) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_item public.ingredients;
  v_delta numeric(14,3);
begin
  if not public.staff_has_permission('inventory.edit') then raise exception 'permission denied'; end if;
  if p_kind not in ('purchase','use','waste','adjustment') then raise exception 'invalid movement kind'; end if;
  if p_quantity is null or p_quantity = 0 or abs(p_quantity) > 10000000 then raise exception 'invalid quantity'; end if;
  if p_kind in ('purchase','use','waste') and p_quantity < 0 then raise exception 'quantity must be positive'; end if;
  v_delta := case when p_kind in ('use','waste') then -p_quantity else p_quantity end;
  select * into v_item from public.ingredients where id = p_ingredient_id for update;
  if not found then raise exception 'ingredient not found'; end if;
  if v_item.on_hand + v_delta < 0 then raise exception 'insufficient stock'; end if;
  update public.ingredients set
    on_hand = on_hand + v_delta,
    unit_cost = case when p_kind = 'purchase' and p_unit_cost is not null then p_unit_cost else unit_cost end
  where id = p_ingredient_id returning * into v_item;
  insert into public.stock_movements (ingredient_id, kind, quantity, unit_cost, note, actor_uid)
  values (p_ingredient_id, p_kind, v_delta, p_unit_cost, nullif(trim(coalesce(p_note,'')),''), auth.uid());
  insert into public.audit_log (actor_uid, action, entity_type, entity_id, detail)
  values (auth.uid(), 'inventory.'||p_kind, 'ingredient', p_ingredient_id::text,
    jsonb_build_object('quantity',v_delta,'on_hand',v_item.on_hand,'unit_cost',v_item.unit_cost));
  return json_build_object('id',v_item.id,'on_hand',v_item.on_hand,'unit_cost',v_item.unit_cost);
end $$;

create or replace function public.apply_order_inventory() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_line jsonb;
  v_qty numeric;
  v_menu_id text;
  v_recipe record;
  v_used numeric;
begin
  if new.inventory_applied_at is not null or new.status not in ('confirmed','making','ready','done') then return new; end if;
  for v_line in select value from jsonb_array_elements(new.items) loop
    v_menu_id := nullif(v_line->>'menu_id','');
    v_qty := greatest(coalesce((v_line->>'qty')::numeric,0),0);
    if v_menu_id is null or v_qty = 0 then continue; end if;
    for v_recipe in select ingredient_id, quantity from public.menu_recipes where menu_item_id = v_menu_id loop
      v_used := v_recipe.quantity * v_qty;
      update public.ingredients set on_hand = greatest(on_hand - v_used, 0) where id = v_recipe.ingredient_id;
      insert into public.stock_movements (ingredient_id,kind,quantity,note,order_id,actor_uid)
      values (v_recipe.ingredient_id,'use',-v_used,'ตัดอัตโนมัติจากออเดอร์',new.id,coalesce(new.created_by,auth.uid()));
    end loop;
  end loop;
  new.inventory_applied_at := now();
  return new;
end $$;

drop trigger if exists orders_apply_inventory on public.orders;
create trigger orders_apply_inventory before insert or update of status on public.orders
for each row execute function public.apply_order_inventory();

create or replace function public.sales_summary(p_from timestamptz, p_to timestamptz) returns json
language plpgsql stable security definer set search_path = public as $$
declare v_result json;
begin
  if not public.staff_has_permission('reports.view') then raise exception 'permission denied'; end if;
  if p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '370 days' then
    raise exception 'invalid report range';
  end if;
  with filtered as (
    select * from public.orders
    where created_at >= p_from and created_at < p_to and status <> 'cancelled'
  ), lines as (
    select o.id, o.created_at, o.pay_method, x.value as item,
      coalesce((x.value->>'qty')::numeric,0) qty,
      coalesce((x.value->>'price')::numeric,0) price
    from filtered o cross join lateral jsonb_array_elements(o.items) x
  ), costs as (
    select l.id, coalesce(sum(r.quantity*i.unit_cost*l.qty),0) cogs
    from lines l left join public.menu_recipes r on r.menu_item_id=l.item->>'menu_id'
    left join public.ingredients i on i.id=r.ingredient_id group by l.id
  )
  select json_build_object(
    'revenue',coalesce((select sum(total) from filtered),0),
    'orders',coalesce((select count(*) from filtered),0),
    'cups',coalesce((select sum(qty) from lines),0),
    'cogs',coalesce((select sum(cogs) from costs),0),
    'by_day',coalesce((select json_agg(d order by report_day) from (
      select (created_at at time zone 'Asia/Bangkok')::date as report_day, sum(total) revenue, count(*) orders
      from filtered group by 1
    ) d),'[]'::json),
    'payments',coalesce((select json_agg(p order by revenue desc) from (
      select pay_method, sum(total) revenue, count(*) orders from filtered group by 1
    ) p),'[]'::json),
    'top_items',coalesce((select json_agg(t order by quantity desc) from (
      select item->>'name' name, sum(qty) quantity, sum(qty*price) revenue
      from lines group by 1 order by 2 desc limit 10
    ) t),'[]'::json)
  ) into v_result;
  return v_result;
end $$;

drop policy if exists "management insert menu" on public.menu_items;
drop policy if exists "management update menu" on public.menu_items;
drop policy if exists "management delete menu" on public.menu_items;
create policy "management insert menu" on public.menu_items
  for insert to authenticated with check (public.staff_has_permission('menu.edit'));
create policy "management update menu" on public.menu_items
  for update to authenticated using (public.staff_has_permission('menu.edit'))
  with check (public.staff_has_permission('menu.edit'));
create policy "management delete menu" on public.menu_items
  for delete to authenticated using (public.staff_has_permission('menu.edit'));

revoke all on function public.staff_has_permission(text) from public;
revoke all on function public.adjust_stock(uuid,text,numeric,numeric,text) from public;
revoke all on function public.sales_summary(timestamptz,timestamptz) from public;
grant execute on function public.staff_has_permission(text) to authenticated;
grant execute on function public.adjust_stock(uuid,text,numeric,numeric,text) to authenticated;
grant execute on function public.sales_summary(timestamptz,timestamptz) to authenticated;

commit;
