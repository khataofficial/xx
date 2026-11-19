-- =====================================================================
-- My Khata: complete Supabase setup (run ONCE in Supabase > SQL Editor)
-- Safe to run again: everything uses "if not exists" / "create or replace".
-- Covers: profiles & plans, cloud data sync, devices, ads, admin,
--         online store, store orders.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. PROFILES (one row per user: plan, shop name, admin flag)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  email            text,
  shop_name        text default '',
  customer_count   int  default 0,
  plan             text,
  plan_expires_at  timestamptz,
  is_admin         boolean not null default false,
  created_at       timestamptz not null default now()
);
alter table public.profiles enable row level security;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select
  using (id = auth.uid() or public.is_admin());
-- no insert/update/delete policies: users cannot change plan or admin flag

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- profiles for users that already exist
insert into public.profiles (id, email)
select id, email from auth.users on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 2. CLOUD DATA (the khata itself, synced between devices)
-- ---------------------------------------------------------------------
create table if not exists public.khata_data (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  data        jsonb not null default '{}'::jsonb,
  version     int   not null default 1,
  updated_at  timestamptz not null default now()
);
alter table public.khata_data enable row level security;

drop policy if exists khata_select on public.khata_data;
create policy khata_select on public.khata_data for select using (user_id = auth.uid());
drop policy if exists khata_delete on public.khata_data;
create policy khata_delete on public.khata_data for delete using (user_id = auth.uid());
-- writes only through push_data()

create or replace function public.push_data(p_data jsonb, p_base int, p_shop text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  cur public.khata_data%rowtype;
  cnt int;
begin
  if uid is null then raise exception 'not logged in'; end if;
  select * into cur from public.khata_data where user_id = uid for update;
  cnt := case when jsonb_typeof(p_data->'customers') = 'array'
              then jsonb_array_length(p_data->'customers') else 0 end;
  if not found then
    insert into public.khata_data (user_id, data, version) values (uid, p_data, 1);
    update public.profiles set shop_name = left(coalesce(p_shop,''), 80), customer_count = cnt where id = uid;
    return jsonb_build_object('ok', true, 'version', 1);
  end if;
  if cur.version <> coalesce(p_base, 0) then       -- another device saved first
    return jsonb_build_object('ok', false, 'version', cur.version, 'data', cur.data);
  end if;
  update public.khata_data
     set data = p_data, version = cur.version + 1, updated_at = now()
   where user_id = uid;
  update public.profiles set shop_name = left(coalesce(p_shop,''), 80), customer_count = cnt where id = uid;
  return jsonb_build_object('ok', true, 'version', cur.version + 1);
end $$;

-- ---------------------------------------------------------------------
-- 3. DEVICES (which phones / PCs are logged in)
-- ---------------------------------------------------------------------
create table if not exists public.devices (
  user_id     uuid not null references auth.users(id) on delete cascade,
  device_key  text not null,
  name        text,
  city        text,
  country     text,
  created_at  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  primary key (user_id, device_key)
);
alter table public.devices enable row level security;
-- no policies: only the functions below can touch it

-- returns false when this device was removed from another device
create or replace function public.device_ping(p_key text, p_name text, p_city text, p_country text, p_new boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return true; end if;
  update public.devices
     set last_seen = now(), name = left(coalesce(p_name,''),80),
         city = left(coalesce(p_city,''),60), country = left(coalesce(p_country,''),60)
   where user_id = uid and device_key = p_key;
  if found then return true; end if;
  if p_new then
    insert into public.devices (user_id, device_key, name, city, country)
    values (uid, p_key, left(coalesce(p_name,''),80), left(coalesce(p_city,''),60), left(coalesce(p_country,''),60));
    return true;
  end if;
  return false;
end $$;

create or replace function public.list_devices()
returns table (device_key text, name text, city text, country text, last_seen timestamptz)
language sql stable security definer set search_path = public as $$
  select d.device_key, d.name, d.city, d.country, d.last_seen
    from public.devices d where d.user_id = auth.uid() order by d.last_seen desc;
$$;

create or replace function public.remove_device(p_key text) returns void
language sql security definer set search_path = public as $$
  delete from public.devices where user_id = auth.uid() and device_key = p_key;
$$;

create or replace function public.remove_other_devices(p_key text) returns void
language sql security definer set search_path = public as $$
  delete from public.devices where user_id = auth.uid() and device_key <> p_key;
$$;

-- ---------------------------------------------------------------------
-- 4. ADS (public, admin approves, likes / reports, auto-delete at 30 reports)
-- ---------------------------------------------------------------------
create table if not exists public.ads (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null references auth.users(id) on delete cascade,
  title       text not null,
  detail      text default '',
  link        text not null,
  comment     text default '',
  status      text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at  timestamptz not null default now()
);
create table if not exists public.ad_votes (
  ad_id    uuid not null references public.ads(id) on delete cascade,
  user_id  uuid not null references auth.users(id) on delete cascade,
  kind     text not null check (kind in ('like','report')),
  primary key (ad_id, user_id, kind)
);
alter table public.ads enable row level security;
alter table public.ad_votes enable row level security;

create or replace function public.ad_row(a public.ads)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', a.id, 'title', a.title, 'detail', a.detail, 'link', a.link, 'comment', a.comment,
    'status', a.status, 'created_at', a.created_at,
    'likes',   (select count(*) from public.ad_votes v where v.ad_id = a.id and v.kind = 'like'),
    'reports', (select count(*) from public.ad_votes v where v.ad_id = a.id and v.kind = 'report'),
    'my_like',   exists (select 1 from public.ad_votes v where v.ad_id = a.id and v.kind = 'like'   and v.user_id = auth.uid()),
    'my_report', exists (select 1 from public.ad_votes v where v.ad_id = a.id and v.kind = 'report' and v.user_id = auth.uid()),
    'mine', a.owner = auth.uid());
$$;

-- approved ads: liked ads first, reported ads last
create or replace function public.list_ads() returns setof jsonb
language sql stable security definer set search_path = public as $$
  select public.ad_row(a) from public.ads a where a.status = 'approved'
  order by ((select count(*) from public.ad_votes v where v.ad_id = a.id and v.kind='like')
          - 3 * (select count(*) from public.ad_votes v where v.ad_id = a.id and v.kind='report')) desc,
           a.created_at desc
  limit 200;
$$;

create or replace function public.my_ads() returns setof jsonb
language sql stable security definer set search_path = public as $$
  select public.ad_row(a) from public.ads a where a.owner = auth.uid() order by a.created_at desc;
$$;

create or replace function public.submit_ad(p_title text, p_detail text, p_link text, p_comment text)
returns uuid language plpgsql security definer set search_path = public as $$
declare id uuid;
begin
  if auth.uid() is null then raise exception 'not logged in'; end if;
  if length(trim(coalesce(p_title,''))) < 2 or length(trim(coalesce(p_link,''))) < 4 then
    raise exception 'title and link are required';
  end if;
  insert into public.ads (owner, title, detail, link, comment)
  values (auth.uid(), left(trim(p_title),60), left(coalesce(p_detail,''),400), left(trim(p_link),500), left(coalesce(p_comment,''),50))
  returning ads.id into id;
  return id;
end $$;

create or replace function public.delete_my_ad(p_id uuid) returns void
language sql security definer set search_path = public as $$
  delete from public.ads where id = p_id and owner = auth.uid();
$$;

create or replace function public.vote_ad(p_ad uuid, p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); a public.ads; rep int;
begin
  if uid is null then raise exception 'not logged in'; end if;
  if p_kind not in ('like','report') then raise exception 'bad vote'; end if;
  select * into a from public.ads where id = p_ad and status = 'approved';
  if not found then raise exception 'ad not found'; end if;
  if exists (select 1 from public.ad_votes where ad_id = p_ad and user_id = uid and kind = p_kind) then
    delete from public.ad_votes where ad_id = p_ad and user_id = uid and kind = p_kind;
  else
    insert into public.ad_votes (ad_id, user_id, kind) values (p_ad, uid, p_kind);
  end if;
  select count(*) into rep from public.ad_votes where ad_id = p_ad and kind = 'report';
  if rep >= 30 then
    delete from public.ads where id = p_ad;
    return jsonb_build_object('deleted', true);
  end if;
  return jsonb_build_object(
    'likes',   (select count(*) from public.ad_votes where ad_id = p_ad and kind = 'like'),
    'reports', rep,
    'my_like',   exists (select 1 from public.ad_votes where ad_id = p_ad and user_id = uid and kind = 'like'),
    'my_report', exists (select 1 from public.ad_votes where ad_id = p_ad and user_id = uid and kind = 'report'));
end $$;

-- ---------------------------------------------------------------------
-- 5. ADMIN (admin.html)
-- ---------------------------------------------------------------------
create or replace function public.admin_set_plan(p_uid uuid, p_plan text) returns void
language plpgsql security definer set search_path = public as $$
declare base timestamptz;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  select greatest(now(), coalesce(plan_expires_at, now())) into base from public.profiles where id = p_uid;
  if p_plan = 'monthly' then
    update public.profiles set plan = 'monthly', plan_expires_at = base + interval '30 days' where id = p_uid;
  elsif p_plan = 'yearly' then
    update public.profiles set plan = 'yearly', plan_expires_at = base + interval '365 days' where id = p_uid;
  elsif p_plan = 'none' then
    update public.profiles set plan = null, plan_expires_at = null where id = p_uid;
  else
    raise exception 'unknown plan';
  end if;
end $$;

create or replace function public.admin_list_ads(p_status text) returns setof jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return query
    select public.ad_row(a) || jsonb_build_object('email', (select email from public.profiles where id = a.owner))
      from public.ads a where a.status = p_status order by a.created_at desc limit 300;
end $$;

create or replace function public.admin_review_ad(p_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  update public.ads set status = case when p_approve then 'approved' else 'rejected' end where id = p_id;
end $$;

create or replace function public.admin_delete_ad(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  delete from public.ads where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- 6. ONLINE STORE (shop.html, owner.html)
-- ---------------------------------------------------------------------
create table if not exists public.stores (
  slug        text primary key check (slug ~ '^[a-z0-9-]{3,40}$'),
  owner       uuid not null unique references auth.users(id) on delete cascade,
  name        text not null default '',
  data        jsonb not null default '{}'::jsonb,   -- {name, city, wa, description, x:{...}, products:[...]}
  enabled     boolean not null default false,
  updated_at  timestamptz not null default now()
);
create table if not exists public.store_orders (
  id             uuid primary key default gen_random_uuid(),
  store_slug     text not null references public.stores(slug) on delete cascade,
  owner          uuid not null references auth.users(id) on delete cascade,
  customer_name  text not null,
  phone          text not null,
  address        text not null default '',
  items          jsonb not null,                    -- [{id,name,qty,price}]
  total          numeric not null default 0,
  status         text not null default 'new' check (status in ('new','done','cancelled')),
  created_at     timestamptz not null default now()
);
create index if not exists store_orders_owner_idx on public.store_orders (owner, created_at desc);
alter table public.stores enable row level security;
alter table public.store_orders enable row level security;
-- no policies: everything goes through the functions below

-- owner saves / updates the store
create or replace function public.store_publish(p_slug text, p_data jsonb, p_enabled boolean) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s text := lower(coalesce(p_slug,''));
begin
  if uid is null then raise exception 'not logged in'; end if;
  if s !~ '^[a-z0-9-]{3,40}$' then raise exception 'bad link name'; end if;
  if exists (select 1 from public.stores where slug = s and owner <> uid) then
    raise exception 'duplicate: link name is taken';
  end if;
  insert into public.stores (slug, owner, name, data, enabled, updated_at)
  values (s, uid, left(coalesce(p_data->>'name',''),80), coalesce(p_data,'{}'::jsonb), coalesce(p_enabled,false), now())
  on conflict (owner) do update
    set slug = excluded.slug, name = excluded.name, data = excluded.data,
        enabled = excluded.enabled, updated_at = now();
end $$;

-- owner's own store row(s) + every public store
create or replace function public.store_list()
returns table (slug text, name text, owner uuid, enabled boolean)
language sql stable security definer set search_path = public as $$
  select s.slug, s.name, s.owner, s.enabled from public.stores s
   where s.enabled or s.owner = auth.uid() order by s.name;
$$;

-- public: customers load a store (owner can also see it while it is OFF)
create or replace function public.store_get(p_slug text) returns jsonb
language sql stable security definer set search_path = public as $$
  select s.data from public.stores s
   where s.slug = lower(coalesce(p_slug,'')) and (s.enabled or s.owner = auth.uid());
$$;

-- public: customer sends an order (stock is checked and reserved here)
create or replace function public.store_order(p_slug text, p_name text, p_phone text, p_address text, p_items jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  st public.stores%rowtype; x jsonb; prods jsonb; it jsonb; pr jsonb;
  sub numeric := 0; fee numeric := 0; disc numeric := 0; oid uuid;
  lines jsonb := '[]'::jsonb; q int; n int := 0;
begin
  select * into st from public.stores where slug = lower(coalesce(p_slug,'')) and enabled for update;
  if not found then raise exception 'store not available'; end if;
  x := coalesce(st.data->'x','{}'::jsonb);
  if (x->>'acc') = '0' then raise exception 'orders are paused'; end if;
  if length(trim(coalesce(p_name,''))) < 2 or length(regexp_replace(coalesce(p_phone,''),'\D','','g')) < 10 then
    raise exception 'name and phone are required';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 60 then
    raise exception 'nothing available';
  end if;
  prods := coalesce(st.data->'products','[]'::jsonb);

  for it in select * from jsonb_array_elements(p_items) loop
    q := greatest(0, coalesce((it->>'qty')::int, 0));
    select e into pr from jsonb_array_elements(prods) e where e->>'id' = it->>'id' limit 1;
    if pr is null or q < 1 or coalesce((pr->>'qty')::int,0) < q then
      raise exception 'nothing available: not enough stock';
    end if;
    sub := sub + q * coalesce((pr->>'price')::numeric,0);
    lines := lines || jsonb_build_array(jsonb_build_object(
      'id', pr->>'id', 'name', pr->>'name', 'qty', q, 'price', coalesce((pr->>'price')::numeric,0)));
    n := n + 1;
  end loop;

  if coalesce((x->>'min')::numeric,0) > 0 and sub < (x->>'min')::numeric then
    raise exception 'minimum order not reached';
  end if;
  if p_address like '%Type: Home delivery%' and coalesce((x->>'dv'),'1') <> '0' then
    fee := coalesce((x->>'fee')::numeric,0);
    if coalesce((x->>'free')::numeric,0) > 0 and sub >= (x->>'free')::numeric then fee := 0; end if;
  end if;
  if coalesce(x->>'cc','') <> '' and p_address like '%Code: '||(x->>'cc')||'%' then
    disc := round(sub * coalesce((x->>'cp')::numeric,0) / 100);
  end if;

  -- reserve stock
  update public.stores set data = jsonb_set(data, '{products}', (
      select coalesce(jsonb_agg(
        case when exists (select 1 from jsonb_array_elements(lines) l where l->>'id' = e->>'id')
             then jsonb_set(e, '{qty}', to_jsonb(greatest(0,
                    coalesce((e->>'qty')::int,0) - (select sum((l->>'qty')::int) from jsonb_array_elements(lines) l where l->>'id' = e->>'id'))))
             else e end order by ord), '[]'::jsonb)
      from jsonb_array_elements(prods) with ordinality t(e, ord)))
   where slug = st.slug;

  insert into public.store_orders (store_slug, owner, customer_name, phone, address, items, total)
  values (st.slug, st.owner, left(trim(p_name),60), left(trim(p_phone),20), left(coalesce(p_address,''),400), lines, sub - disc + fee)
  returning id into oid;
  return oid;
end $$;

-- owner: list orders
create or replace function public.store_orders_list()
returns table (id uuid, customer_name text, phone text, address text, items jsonb, total numeric, status text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select o.id, o.customer_name, o.phone, o.address, o.items, o.total, o.status, o.created_at
    from public.store_orders o where o.owner = auth.uid() order by o.created_at desc limit 300;
$$;

-- owner: mark done / cancelled (cancelling a new order puts the stock back)
create or replace function public.store_order_status(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.store_orders%rowtype;
begin
  if p_status not in ('new','done','cancelled') then raise exception 'bad status'; end if;
  select * into o from public.store_orders where id = p_id and owner = auth.uid() for update;
  if not found then raise exception 'order not found'; end if;
  if o.status = 'new' and p_status = 'cancelled' then
    update public.stores set data = jsonb_set(data, '{products}', (
        select coalesce(jsonb_agg(
          case when exists (select 1 from jsonb_array_elements(o.items) l where l->>'id' = e->>'id')
               then jsonb_set(e, '{qty}', to_jsonb(coalesce((e->>'qty')::int,0) +
                      (select sum((l->>'qty')::int) from jsonb_array_elements(o.items) l where l->>'id' = e->>'id')))
               else e end order by ord), '[]'::jsonb)
        from jsonb_array_elements(coalesce(data->'products','[]'::jsonb)) with ordinality t(e, ord)))
     where slug = o.store_slug;
  end if;
  update public.store_orders set status = p_status where id = o.id;
end $$;

-- ---------------------------------------------------------------------
-- 7. PERMISSIONS
-- ---------------------------------------------------------------------
revoke all on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant execute on function public.store_get(text)  to anon;
grant execute on function public.store_order(text, text, text, text, jsonb) to anon;
-- (is_admin / ad_row are helpers: harmless for logged-in users)

-- ---------------------------------------------------------------------
-- 8. MAKE YOURSELF ADMIN (replace the email, then run this one line)
-- ---------------------------------------------------------------------
-- update public.profiles set is_admin = true where email = 'your-email@gmail.com';
