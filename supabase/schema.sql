-- ============================================================
--  GG Smoothie — Supabase schema
--  วิธีใช้: เปิด Supabase Dashboard > SQL Editor > วางทั้งไฟล์นี้ > Run
--  รันซ้ำได้ (idempotent) — ไม่ทำข้อมูลเดิมพัง
-- ============================================================

create extension if not exists pgcrypto;

-- ===================== MENU =====================
-- เมนูกลาง: เว็บอ่านตอนโหลดหน้า / POS แก้ราคา-เปิดปิดเมนูได้โดยไม่ต้อง deploy เว็บใหม่
create table if not exists public.menu_items (
  id          text primary key,
  name        text not null,
  description text not null default '',
  price       numeric not null,
  cal         int not null default 0,
  p           int not null default 0,   -- โปรตีน (g)
  f           int not null default 0,   -- ไฟเบอร์ (g)
  sug         int not null default 0,   -- น้ำตาล (g)
  active      boolean not null default true,
  sort_order  int not null default 0,
  updated_at  timestamptz not null default now()
);

alter table public.menu_items enable row level security;

drop policy if exists "anon read active menu" on public.menu_items;
create policy "anon read active menu" on public.menu_items
  for select using (active);

insert into public.menu_items (id, name, description, price, cal, p, f, sug, sort_order) values
  ('g', 'กรีนโปรตีน',      'ผักโขม · กล้วย · โปรตีนถั่ว · อัลมอนด์',   129, 310, 24, 7,  9, 1),
  ('b', 'เบอร์รี่ฟื้นพลัง',  'บลูเบอร์รี่ · บีทรูท · เชอร์รี่ · โยเกิร์ต', 129, 280, 18, 8, 14, 2),
  ('t', 'ทรอปิคอลรีเซ็ต',   'มะม่วง · สับปะรด · ขิง · มะพร้าว',        119, 240,  5, 6, 19, 3),
  ('c', 'คาเคาชาร์จ',       'กล้วย · คาเคา · ข้าวโอ๊ต · โคลด์บรูว์',    139, 330, 22, 6, 12, 4),
  ('m', 'มัทฉะรีชาร์จ',     'มัทฉะ · กล้วย · โปรตีนถั่ว · อัลมอนด์',    139, 250, 16, 5,  8, 5),
  ('s', 'ซิตรัสดีท็อกซ์',    'ส้ม · เกรปฟรุต · ขิง · น้ำมะพร้าว',       119, 190,  3, 5, 16, 6)
on conflict (id) do nothing;

-- ===================== ORDERS =====================
-- เว็บสร้างออเดอร์ผ่าน RPC place_order เท่านั้น (ไม่มี policy ให้ anon อ่าน/เขียนตรง
-- เพื่อไม่ให้ใครดึงชื่อ-เบอร์ลูกค้าทั้งหมดได้) — POS ใช้ secret/service_role key
create table if not exists public.orders (
  id            uuid primary key default gen_random_uuid(),
  queue_no      int not null,                    -- เลขคิว รีเซ็ตรายวัน (เวลาไทย)
  customer_name text not null,
  phone         text,
  items         jsonb not null,                  -- [{name, qty, price, desc, cal, p, f, sug, kind}]
  total         numeric not null,
  pay_method    text not null default 'promptpay',
  status        text not null default 'pending'
                check (status in ('pending','confirmed','making','ready','done','cancelled')),
  source        text not null default 'web' check (source in ('web','pos')),
  note          text,
  printed       boolean not null default false,  -- โปรแกรมปริ้นสติกเกอร์ตั้ง true หลังปริ้นแล้ว
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

alter table public.orders enable row level security;

create index if not exists orders_created_at_idx on public.orders (created_at desc);
create index if not exists orders_status_idx     on public.orders (status);

create or replace function public.tg_touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists orders_touch on public.orders;
create trigger orders_touch before update on public.orders
  for each row execute function public.tg_touch_updated_at();

-- ===================== MEMBERS =====================
-- แต้มสะสม: POS เป็นคนให้/ตัดแต้ม (secret key) — เว็บอ่านผ่าน RPC เท่านั้น
create table if not exists public.members (
  phone      text primary key,
  name       text not null,
  stamps     int not null default 0,
  redeemed   int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.members enable row level security;

drop trigger if exists members_touch on public.members;
create trigger members_touch before update on public.members
  for each row execute function public.tg_touch_updated_at();

-- ===================== RPC (เว็บเรียกด้วย publishable key) =====================

-- เลขคิวรายวันตามเวลาไทย
create or replace function public.next_queue_no() returns int
language sql security definer set search_path = public as $$
  select coalesce(max(queue_no), 0) + 1
  from orders
  where (created_at at time zone 'Asia/Bangkok')::date
      = (now()       at time zone 'Asia/Bangkok')::date
$$;

-- สร้างออเดอร์จากเว็บ/POS แล้วคืน {id, queue_no, status}
create or replace function public.place_order(
  p_name text, p_phone text, p_items jsonb, p_total numeric,
  p_pay_method text default 'promptpay', p_source text default 'web'
) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_order orders;
begin
  if coalesce(trim(p_name), '') = '' then
    raise exception 'name required';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'items required';
  end if;
  if p_total is null or p_total < 0 or p_total > 20000 then
    raise exception 'bad total';
  end if;
  if p_source not in ('web','pos') then
    raise exception 'bad source';
  end if;

  -- กันเลขคิวชนกันเมื่อมีออเดอร์เข้าพร้อมกัน
  perform pg_advisory_xact_lock(920316);

  insert into orders (queue_no, customer_name, phone, items, total, pay_method, source)
  values (
    next_queue_no(),
    trim(p_name),
    nullif(trim(coalesce(p_phone, '')), ''),
    p_items,
    p_total,
    coalesce(p_pay_method, 'promptpay'),
    p_source
  )
  returning * into v_order;

  return json_build_object('id', v_order.id, 'queue_no', v_order.queue_no, 'status', v_order.status);
end $$;

-- เว็บใช้ติดตามสถานะออเดอร์ตัวเอง (ต้องรู้ uuid ของออเดอร์เท่านั้น)
create or replace function public.order_status(p_id uuid) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('queue_no', queue_no, 'status', status)
  from orders where id = p_id
$$;

-- สมัคร/อัปเดตสมาชิกจากเว็บ — แต้มเดิมใน localStorage จะถูก seed เฉพาะตอนสร้างครั้งแรก
create or replace function public.register_member(
  p_name text, p_phone text, p_stamps int default 0
) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_m members;
begin
  if coalesce(trim(p_name), '') = '' or length(trim(coalesce(p_phone,''))) < 9 then
    raise exception 'bad member';
  end if;

  insert into members (phone, name, stamps)
  values (trim(p_phone), trim(p_name), greatest(0, least(coalesce(p_stamps,0), 100)))
  on conflict (phone) do update set name = excluded.name
  returning * into v_m;

  return json_build_object('stamps', v_m.stamps, 'redeemed', v_m.redeemed);
end $$;

-- เว็บอ่านแต้มปัจจุบันของสมาชิก (คืน null ถ้าไม่พบ)
create or replace function public.member_stamps(p_phone text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('stamps', stamps, 'redeemed', redeemed)
  from members where phone = trim(p_phone)
$$;

-- ===================== REALTIME =====================
-- ให้ POS subscribe ออเดอร์ใหม่แบบเรียลไทม์ (insert/update)
do $$
begin
  alter publication supabase_realtime add table public.orders;
exception when duplicate_object then
  null; -- เพิ่มไว้แล้ว ข้ามได้
end $$;
