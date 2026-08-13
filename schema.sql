-- ============================================================
--  ราพสลัด — Supabase schema  (project: rapsalad, ap-southeast-1)
--  https://mqteglbrvtrlaxwlokap.supabase.co
--
--  ไฟล์นี้ = ของจริงที่รันอยู่บน production แล้ว
--  ถ้าจะสร้าง project ใหม่: SQL Editor → วางทั้งไฟล์ → Run (ไม่ต้องตั้ง Exposed schemas)
--
--  หลักการ: append-only ledger · เงินเก็บเป็นสตางค์ (integer)
--           id สร้างฝั่ง client (text) → ส่งซ้ำไม่เกิดรายการซ้ำ
--           วันใช้เวลา Asia/Bangkok เสมอ ไม่ใช่ UTC
-- ============================================================

-- ── helper: แตะ updated_at ───────────────────────────────────
create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at = now(); return new; end $$;

-- ============================================================
--  1 · แคตตาล็อกที่ทุกเครื่องเห็นตรงกัน
-- ============================================================
create table if not exists public.cats (
  id          text primary key,
  name        text not null,
  bucket      text not null default 'shared'
                check (bucket in ('shared','topping','equipment')),
  sort        int  not null default 0,
  updated_at  timestamptz not null default now()
);

create table if not exists public.items (
  id          text primary key,
  name        text not null,
  price       int  not null default 0,          -- สตางค์
  sort        int  not null default 0,
  photo       text not null default '',
  active      boolean not null default true,
  updated_at  timestamptz not null default now()
);

create table if not exists public.goods (
  id           text primary key,
  name         text not null,
  category_id  text,
  item_id      text,                            -- ตั้งเฉพาะ bucket=topping
  unit         text not null default 'pcs',     -- g | pcs | sheet
  pack_size    numeric,
  last_price   int,                             -- สตางค์ ต่อ 1 แพ็ค
  last_store   text not null default '',
  archived     boolean not null default false,
  updated_at   timestamptz not null default now()
);

create table if not exists public.stores (
  name        text primary key,
  sort        int not null default 0,
  updated_at  timestamptz not null default now()
);

create table if not exists public.staff (
  pin         text primary key,
  name        text not null,
  test        boolean not null default false,
  updated_at  timestamptz not null default now()
);

-- ============================================================
--  2 · หน้าร้าน
-- ============================================================
create table if not exists public.shifts (
  id            text primary key,
  opened_at     timestamptz not null,
  closed_at     timestamptz,
  open_day      date,                            -- Asia/Bangkok · trigger ใส่ให้
  float_start   bigint not null default 0,
  cash_counted  bigint,
  transfer_in   bigint,
  menu          jsonb  not null default '{}'::jsonb,
  is_test       boolean not null default false,
  device        text,
  updated_at    timestamptz not null default now()
);

-- shift_id / void_of ตั้งใจไม่ทำ FK: เครื่องที่ออฟไลน์อาจส่ง sale
-- ขึ้นก่อน shift ความถูกต้องไปเช็คตอน rollup แทน ไม่บล็อกตอนเขียน
create table if not exists public.sales (
  id          text primary key,
  shift_id    text,
  item_id     text,
  item_name   text,
  price       int  not null default 0,           -- สตางค์
  pay         text,                              -- cash | transfer | unknown
  void_of     text,                              -- ลบ = insert แถวทับ
  device      text,
  is_test     boolean not null default false,
  sale_day    date,                              -- Asia/Bangkok · trigger ใส่ให้
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.pay_changes (
  id          text primary key,
  sale_id     text not null,
  pay         text not null,
  created_at  timestamptz not null default now()
);

create table if not exists public.purchases (
  id            text primary key,
  bought_at     date not null,
  store         text,
  total_actual  bigint,
  is_test       boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table if not exists public.purchase_lines (
  id           text primary key,
  purchase_id  text not null,
  goods_id     text,
  goods_name   text,
  bucket       text,
  item_id      text,
  packs        numeric not null default 1,
  pack_size    numeric,
  unit         text,
  price        bigint  not null default 0,       -- สตางค์ ต่อ 1 แพ็ค
  is_promo     boolean not null default false,
  created_at   timestamptz not null default now()
);

-- ============================================================
--  3 · รายการซื้อของ — ลิสต์เดียว ทุกเครื่องแก้ร่วมกัน
--      id = 'sl_l_<goods_id>' (ใช้จริง) / 'sl_t_<goods_id>' (ทดสอบ)
--      → upsert merge-duplicates ได้เลย ไม่ต้องส่ง on_conflict
-- ============================================================
create table if not exists public.shopping_list (
  id                text primary key,
  goods_id          text,
  goods_name        text not null,
  bucket            text,
  item_id           text,
  store             text,
  unit              text,
  pack_size         numeric,
  packs             numeric not null default 1,
  qty               numeric,
  price             bigint,
  checked           boolean not null default false,
  note              text,
  source            text not null default 'manual'
                      check (source in ('manual','lowstock')),
  is_test           boolean not null default false,
  done_purchase_id  text,                        -- ตั้งเมื่อกลายเป็นบิลซื้อแล้ว
  updated_by        text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- ============================================================
--  4 · ประทับ "วัน" แบบกรุงเทพฯ
--      AT TIME ZONE เป็นแค่ STABLE → index ตรง ๆ ไม่ได้
--      เลยเก็บเป็นคอลัมน์จริง แล้ว index ได้เต็มที่
-- ============================================================
create or replace function public.stamp_sale_day()
returns trigger language plpgsql set search_path = public as $$
begin
  new.sale_day   := (new.created_at at time zone 'Asia/Bangkok')::date;
  new.updated_at := now();
  return new;
end $$;

create or replace function public.stamp_shift_day()
returns trigger language plpgsql set search_path = public as $$
begin
  new.open_day   := (new.opened_at at time zone 'Asia/Bangkok')::date;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists t_sales_day on public.sales;
create trigger t_sales_day  before insert or update on public.sales
  for each row execute function public.stamp_sale_day();

drop trigger if exists t_shifts_day on public.shifts;
create trigger t_shifts_day before insert or update on public.shifts
  for each row execute function public.stamp_shift_day();

do $$
declare t text;
begin
  foreach t in array array['cats','items','goods','stores','staff',
                           'purchases','shopping_list']
  loop
    execute format(
      'drop trigger if exists t_touch on public.%I;
       create trigger t_touch before update on public.%I
         for each row execute function public.touch_updated_at();', t, t);
  end loop;
end $$;

-- ============================================================
--  5 · index — ทุกเส้นทางที่แอปใช้จริง
-- ============================================================
create index if not exists ix_sales_day     on public.sales (is_test, sale_day desc);
create index if not exists ix_sales_shift   on public.sales (shift_id);
create index if not exists ix_sales_void    on public.sales (void_of) where void_of is not null;
create index if not exists ix_sales_sync    on public.sales (updated_at);
create index if not exists ix_sales_item    on public.sales (item_id) where void_of is null;

create index if not exists ix_shifts_day    on public.shifts (is_test, open_day desc);
create index if not exists ix_shifts_open   on public.shifts (is_test) where closed_at is null;
create index if not exists ix_shifts_sync   on public.shifts (updated_at);

create index if not exists ix_pay_sale      on public.pay_changes (sale_id, created_at desc);
create index if not exists ix_pay_sync      on public.pay_changes (created_at);

create index if not exists ix_pur_day       on public.purchases (is_test, bought_at desc);
create index if not exists ix_pur_sync      on public.purchases (updated_at);
create index if not exists ix_pl_purchase   on public.purchase_lines (purchase_id);
create index if not exists ix_pl_goods      on public.purchase_lines (goods_id);

create index if not exists ix_sl_open       on public.shopping_list (is_test, checked)
  where done_purchase_id is null;
create index if not exists ix_sl_sync       on public.shopping_list (updated_at);

create index if not exists ix_goods_sync    on public.goods (updated_at);
create index if not exists ix_items_sync    on public.items (updated_at);

-- ============================================================
--  6 · RLS
--      ร้านล็อกด้วย PIN ในแอป ไม่ได้ล็อกด้วย Supabase auth
--      → anon อ่าน/เพิ่ม/แก้ ได้  แต่ "ลบไม่ได้"
--      คนแปลกหน้าที่อ่าน key จาก source ก็ยังลบยอดขายทั้งวันไม่ได้
--      แก้ผิดยังทำแบบเดิม: insert แถว void / insert pay_changes
-- ============================================================
do $$
declare t text;
begin
  foreach t in array array['cats','items','goods','stores','staff','shifts',
                           'sales','pay_changes','purchases','purchase_lines',
                           'shopping_list']
  loop
    execute format('alter table public.%I enable row level security;', t);
    execute format('drop policy if exists p_read   on public.%I;', t);
    execute format('drop policy if exists p_insert on public.%I;', t);
    execute format('drop policy if exists p_update on public.%I;', t);
    execute format('create policy p_read   on public.%I for select
                      to anon, authenticated using (true);', t);
    execute format('create policy p_insert on public.%I for insert
                      to anon, authenticated with check (true);', t);
    execute format('create policy p_update on public.%I for update
                      to anon, authenticated using (true) with check (true);', t);
    execute format('grant select, insert, update on public.%I to anon, authenticated;', t);
    execute format('revoke delete on public.%I from anon, authenticated;', t);
  end loop;
end $$;

-- ============================================================
--  7 · ประวัติรายวัน — คิดบน Postgres ไม่ใช่บนมือถือ
-- ============================================================

-- ขายที่นับจริง (ไม่ใช่แถว void และไม่ถูก void)
create or replace view public.v_live_sales as
select s.*
from public.sales s
where s.void_of is null
  and not exists (
    select 1 from public.sales v
    where v.void_of = s.id and v.is_test = s.is_test
  );

-- วิธีจ่ายล่าสุดของแต่ละบิล
create or replace view public.v_sale_pay as
select s.id as sale_id,
       coalesce(
         (select pc.pay from public.pay_changes pc
          where pc.sale_id = s.id
          order by pc.created_at desc, pc.id desc limit 1),
         s.pay, 'unknown') as pay
from public.sales s;

alter view public.v_live_sales set (security_invoker = on);
alter view public.v_sale_pay  set (security_invoker = on);

-- ต้นทุนเฉลี่ยสะสม (ตรงกับ cost engine ในแอปทุกบรรทัด)
create or replace function public.cost_rates(p_is_test boolean default false)
returns table (rolls bigint, shared bigint, shared_per numeric,
               equip bigint, top_per jsonb)
language sql stable security invoker set search_path = public as $$
with ls as (
  select * from public.v_live_sales where is_test = p_is_test
),
by_item as (
  select item_id, count(*)::bigint n from ls where item_id is not null group by item_id
),
lines as (
  select l.* from public.purchase_lines l
  join public.purchases p on p.id = l.purchase_id
  where p.is_test = p_is_test
),
agg as (
  select
    coalesce(sum(round(price*packs)) filter (
      where bucket = 'equipment'), 0)::bigint as equip,
    coalesce(sum(round(price*packs)) filter (
      where bucket is distinct from 'equipment'
        and not (bucket = 'topping' and item_id is not null)), 0)::bigint as shared
  from lines
),
top as (
  select l.item_id, sum(round(l.price*l.packs))::bigint spend
  from lines l where l.bucket = 'topping' and l.item_id is not null
  group by l.item_id
)
select
  (select count(*) from ls)::bigint,
  agg.shared,
  case when (select count(*) from ls) > 0
       then agg.shared::numeric / (select count(*) from ls) else 0 end,
  agg.equip,
  coalesce((select jsonb_object_agg(top.item_id,
              case when bi.n > 0 then top.spend::numeric / bi.n else 0 end)
            from top join by_item bi on bi.item_id = top.item_id), '{}'::jsonb)
from agg;
$$;

-- ฟีดประวัติ: 1 แถว = 1 วันที่ขายได้
-- p_before = "โหลดเพิ่ม" ส่งวันที่เก่าสุดที่มีอยู่แล้วมา (keyset ไม่ใช่ offset)
create or replace function public.day_history(
  p_is_test boolean default false,
  p_limit   int     default 14,
  p_before  date    default null)
returns table (
  day date, rolls bigint, revenue bigint,
  cash bigint, transfer bigint, unknown bigint,
  cost bigint, profit bigint, shifts bigint,
  first_sale timestamptz, last_sale timestamptz,
  top_item text, top_item_n bigint)
language sql stable security invoker set search_path = public as $$
with r as (select * from public.cost_rates(p_is_test)),
ls as (
  select s.*, sp.pay as final_pay
  from public.v_live_sales s
  join public.v_sale_pay sp on sp.sale_id = s.id
  where s.is_test = p_is_test
    and (p_before is null or s.sale_day < p_before)
),
days as (
  select sale_day as day,
         count(*)::bigint                                          as rolls,
         sum(price)::bigint                                        as revenue,
         coalesce(sum(price) filter (where final_pay='cash'),0)::bigint     as cash,
         coalesce(sum(price) filter (where final_pay='transfer'),0)::bigint as transfer,
         coalesce(sum(price) filter (
           where final_pay not in ('cash','transfer')),0)::bigint   as unknown,
         count(distinct shift_id)::bigint                          as shifts,
         min(created_at) as first_sale,
         max(created_at) as last_sale,
         round(sum((select shared_per from r)
                 + coalesce(((select top_per from r) ->> item_id)::numeric, 0)
              ))::bigint                                           as cost
  from ls group by sale_day
  order by sale_day desc
  limit greatest(p_limit, 1)
),
tally as (
  select l.sale_day, l.item_name, count(*)::bigint n
  from ls l
  where l.sale_day in (select day from days)
  group by l.sale_day, l.item_name
),
best as (
  select distinct on (sale_day) sale_day, item_name, n
  from tally order by sale_day, n desc, item_name
)
select d.day, d.rolls, d.revenue, d.cash, d.transfer, d.unknown,
       d.cost, (d.revenue - d.cost)::bigint, d.shifts,
       d.first_sale, d.last_sale, b.item_name, b.n
from days d left join best b on b.sale_day = d.day
order by d.day desc;
$$;

-- กดที่วันไหน → รายการของวันนั้น
create or replace function public.day_detail(
  p_day date, p_is_test boolean default false)
returns table (
  id text, shift_id text, item_id text, item_name text,
  price int, pay text, device text, created_at timestamptz)
language sql stable security invoker set search_path = public as $$
  select s.id, s.shift_id, s.item_id, s.item_name, s.price,
         sp.pay, s.device, s.created_at
  from public.v_live_sales s
  join public.v_sale_pay sp on sp.sale_id = s.id
  where s.is_test = p_is_test and s.sale_day = p_day
  order by s.created_at desc;
$$;

grant execute on function public.cost_rates(boolean)           to anon, authenticated;
grant execute on function public.day_history(boolean,int,date) to anon, authenticated;
grant execute on function public.day_detail(date,boolean)      to anon, authenticated;
grant select on public.v_live_sales, public.v_sale_pay         to anon, authenticated;

-- ============================================================
--  8 · ข้อมูลตั้งต้น — ไม่มี (ตั้งใจ)
--      แคตตาล็อกเป็นของ "เครื่อง" ไม่ใช่ของ server
--      เครื่องแรกที่ซิงก์จะ push cats/items/goods/stores/staff ขึ้นมาเอง
--      (pushCatalog() ใน index.html) เครื่องที่สองค่อย pull ลงไป
--      → ไม่มีเมนูซ้ำ และของเก่าที่ขายไปแล้วไม่หลุด reference
-- ============================================================
