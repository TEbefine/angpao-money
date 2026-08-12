-- ============================================================
--  RAP SALAD — Supabase schema
--  วางทั้งไฟล์นี้ใน Supabase > SQL Editor > Run
--  หลักการ: append-only ledger, เงินเก็บเป็นสตางค์ (integer)
-- ============================================================

create schema if not exists rap;

-- ---------- 1. คนใช้งาน (PIN) ----------
create table if not exists rap.staff (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  pin_hash    text not null,              -- sha256(pin + salt)
  is_test     boolean not null default false,
  created_at  timestamptz not null default now()
);

-- ---------- 2. หมวด + ของ ----------
-- bucket: 'shared'   = ของกลาง หารทุกม้วน (ผัก แป้ง น้ำจิ้ม ถ้วย ถุงมือ)
--         'topping'  = หน้าโรล ผูกกับไส้ (แซลมอน กุ้ง ไก่ ...)
--         'equipment'= ซื้อครั้งเดียว ไม่หารเข้าม้วน (เตา ถาด)
create table if not exists rap.categories (
  id      uuid primary key default gen_random_uuid(),
  name    text not null,
  bucket  text not null check (bucket in ('shared','topping','equipment')),
  sort    int  not null default 0
);

-- เมนูที่ขาย (ไส้)
create table if not exists rap.items (
  id      uuid primary key default gen_random_uuid(),
  name    text not null,
  price   integer not null,              -- สตางค์ (ราคาตั้งต้น)
  photo   text,
  sort    int not null default 0,
  active  boolean not null default true
);

-- วัตถุดิบ / ของใช้ / อุปกรณ์
create table if not exists rap.goods (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  category_id   uuid references rap.categories(id),
  item_id       uuid references rap.items(id),   -- ตั้งเฉพาะ bucket=topping
  unit          text not null default 'g',       -- g | pcs | sheet
  pack_size     numeric not null default 1,      -- กรัม/ชิ้น ต่อ 1 แพ็ค
  last_price    integer,                         -- สตางค์ ต่อ 1 แพ็ค (ไม่นับราคาโปรฯ)
  last_store    text,
  low_stock     boolean not null default false,
  archived      boolean not null default false
);

-- ---------- 3. รอบขาย ----------
create table if not exists rap.shifts (
  id           uuid primary key,
  opened_at    timestamptz not null,
  closed_at    timestamptz,
  float_start  integer not null default 0,   -- เงินทอนตั้งต้น (สตางค์)
  cash_counted integer,                      -- นับได้ตอนปิด
  transfer_in  integer,                      -- ยอดโอนที่กรอกเอง
  menu         jsonb not null default '{}',  -- { item_id: {on:bool, price:int} }
  is_test      boolean not null default false,
  device       text
);

-- ---------- 4. การขาย (append-only) ----------
-- ยกเลิกรายการ = insert แถวใหม่ที่มี void_of ชี้ไปแถวเดิม  ห้าม UPDATE/DELETE
create table if not exists rap.sales (
  id         uuid primary key,              -- client-generated → idempotent
  shift_id   uuid not null references rap.shifts(id),
  item_id    uuid,
  item_name  text not null,                 -- snapshot ชื่อ
  price      integer not null,              -- snapshot ราคา ณ วินาทีที่ขาย
  pay        text not null default 'unknown' check (pay in ('cash','transfer','unknown')),
  void_of    uuid references rap.sales(id),
  device     text,
  is_test    boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists sales_shift_idx on rap.sales(shift_id);

-- แก้วิธีจ่ายทีหลัง = append แถวใหม่ ไม่แก้ของเดิม
create table if not exists rap.pay_changes (
  id         uuid primary key,
  sale_id    uuid not null references rap.sales(id),
  pay        text not null check (pay in ('cash','transfer','unknown')),
  created_at timestamptz not null default now()
);

-- ---------- 5. ซื้อของ ----------
create table if not exists rap.purchases (
  id           uuid primary key,
  bought_at    date not null,
  store        text not null,
  total_actual integer,                    -- ยอดบิลจริง (สตางค์)
  is_test      boolean not null default false,
  created_at   timestamptz not null default now()
);

create table if not exists rap.purchase_lines (
  id          uuid primary key,
  purchase_id uuid not null references rap.purchases(id) on delete cascade,
  goods_id    uuid references rap.goods(id),
  goods_name  text not null,               -- snapshot
  bucket      text not null,               -- snapshot
  item_id     uuid,                        -- snapshot (topping)
  packs       numeric not null default 1,
  pack_size   numeric not null default 1,
  unit        text not null default 'g',
  price       integer not null,            -- สตางค์ ต่อ 1 แพ็ค
  is_promo    boolean not null default false
);
create index if not exists lines_purchase_idx on rap.purchase_lines(purchase_id);

-- ---------- 6. มุมมองสรุป ----------
-- ม้วนที่ขายจริง = แถวที่ไม่ใช่ void และไม่ถูก void
create or replace view rap.v_sales_net as
select s.*
from rap.sales s
where s.void_of is null
  and not exists (select 1 from rap.sales v where v.void_of = s.id);

-- ---------- 7. RLS ----------
alter table rap.staff          enable row level security;
alter table rap.categories     enable row level security;
alter table rap.items          enable row level security;
alter table rap.goods          enable row level security;
alter table rap.shifts         enable row level security;
alter table rap.sales          enable row level security;
alter table rap.pay_changes    enable row level security;
alter table rap.purchases      enable row level security;
alter table rap.purchase_lines enable row level security;

-- ร้านเดียว ทีมเดียว: อนุญาต anon อ่าน/เขียน แต่ห้ามลบและห้ามแก้ ledger
-- (ถ้าอยากแน่นกว่านี้ ค่อยเปลี่ยนเป็น Supabase Auth ทีหลัง)
do $$
declare t text;
begin
  foreach t in array array['categories','items','goods','shifts','purchases','purchase_lines']
  loop
    execute format('drop policy if exists rw on rap.%I', t);
    execute format('create policy rw on rap.%I for all to anon using (true) with check (true)', t);
  end loop;
end $$;

-- ledger: insert + select เท่านั้น  ห้าม update/delete
drop policy if exists ins on rap.sales;
drop policy if exists sel on rap.sales;
create policy ins on rap.sales for insert to anon with check (true);
create policy sel on rap.sales for select to anon using (true);

drop policy if exists ins on rap.pay_changes;
drop policy if exists sel on rap.pay_changes;
create policy ins on rap.pay_changes for insert to anon with check (true);
create policy sel on rap.pay_changes for select to anon using (true);

-- staff: ห้าม anon อ่าน pin_hash ตรง ๆ — เช็คผ่าน RPC เท่านั้น
drop policy if exists nope on rap.staff;
create policy nope on rap.staff for select to anon using (false);

-- ---------- 8. เช็ค PIN ฝั่ง server ----------
create or replace function rap.check_pin(p_pin text)
returns table (id uuid, name text, is_test boolean)
language sql security definer set search_path = rap, public as $$
  select s.id, s.name, s.is_test
  from rap.staff s
  where s.pin_hash = encode(digest(p_pin || 'rapsalad.v1', 'sha256'), 'hex')
  limit 1;
$$;
grant execute on function rap.check_pin(text) to anon;

create extension if not exists pgcrypto;

-- ---------- 9. ข้อมูลตั้งต้น ----------
insert into rap.staff (name, pin_hash, is_test) values
  ('เต๋',      encode(digest('1111' || 'rapsalad.v1','sha256'),'hex'), false),
  ('เพื่อน',   encode(digest('2222' || 'rapsalad.v1','sha256'),'hex'), false),
  ('ทดสอบ 1',  encode(digest('3333' || 'rapsalad.v1','sha256'),'hex'), true),
  ('ทดสอบ 2',  encode(digest('4444' || 'rapsalad.v1','sha256'),'hex'), true)
on conflict do nothing;

insert into rap.items (name, price, sort) values
  ('แซลมอน',    5900, 1),
  ('กุ้ง',       4900, 2),
  ('คาริยากิ',   4500, 3),
  ('สไปซี่',     4500, 4),
  ('หม่าล่า',    4500, 5),
  ('อะโวคาโด',  4500, 6),
  ('ไส้กรอกไก่', 3900, 7),
  ('ปูอัด',      3900, 8)
on conflict do nothing;

insert into rap.categories (name, bucket, sort) values
  ('ผัก',          'shared',    1),
  ('แป้ง · น้ำจิ้ม','shared',    2),
  ('หน้าโรล',      'topping',   3),
  ('ของใช้',       'shared',    4),
  ('อุปกรณ์',      'equipment', 5)
on conflict do nothing;
