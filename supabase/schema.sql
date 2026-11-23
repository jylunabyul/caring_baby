-- Baby Feed Assistant schema. Run in the Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.children (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  date_of_birth date not null,
  weight_kg numeric(5,2) check (weight_kg is null or weight_kg between 0.3 and 80),
  feeds_per_day integer not null default 8 check (feeds_per_day between 1 and 20),
  feeding_interval_minutes integer not null default 180 check (feeding_interval_minutes between 30 and 1440),
  telegram_chat_id text,
  last_reminded_at timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, name)
);

create table if not exists public.feedings (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  amount_ml integer not null check (amount_ml between 1 and 1000),
  fed_at timestamptz not null default now(),
  note text,
  created_at timestamptz not null default now()
);

create index if not exists feedings_child_fed_at_idx on public.feedings(child_id, fed_at desc);

create table if not exists public.formula_inventory (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  child_id uuid not null unique references public.children(id) on delete cascade,
  product_name text not null,
  stock_ml_equivalent integer not null default 0 check (stock_ml_equivalent >= 0),
  reorder_threshold_ml integer not null default 1500 check (reorder_threshold_ml >= 0),
  package_yield_ml integer not null check (package_yield_ml > 0),
  delivery_lead_days integer not null default 3 check (delivery_lead_days between 0 and 60),
  updated_at timestamptz not null default now()
);

alter table public.children enable row level security;
alter table public.feedings enable row level security;
alter table public.formula_inventory enable row level security;

drop policy if exists children_owner_all on public.children;
create policy children_owner_all on public.children for all to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
drop policy if exists feedings_owner_all on public.feedings;
create policy feedings_owner_all on public.feedings for all to authenticated
  using (owner_id = (select auth.uid())) with check (
    owner_id = (select auth.uid()) and exists (
      select 1 from public.children c where c.id = child_id and c.owner_id = (select auth.uid())
    )
  );
drop policy if exists inventory_owner_all on public.formula_inventory;
create policy inventory_owner_all on public.formula_inventory for all to authenticated
  using (owner_id = (select auth.uid())) with check (
    owner_id = (select auth.uid()) and exists (
      select 1 from public.children c where c.id = child_id and c.owner_id = (select auth.uid())
    )
  );

-- A single transaction records a feed and updates estimated remaining stock.
create or replace function public.log_feeding(p_child_id uuid, p_amount_ml integer, p_fed_at timestamptz default now())
returns public.feedings
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_child public.children;
  v_feed public.feedings;
  v_uid uuid := auth.uid();
  v_role text := auth.role();
begin
  select * into v_child from public.children where id = p_child_id and active = true;
  if not found then raise exception 'Child not found or inactive'; end if;
  if v_role <> 'service_role' and (v_uid is null or v_child.owner_id <> v_uid) then
    raise exception 'Not authorized';
  end if;
  if p_amount_ml < 1 or p_amount_ml > 1000 then raise exception 'Invalid amount'; end if;
  insert into public.feedings(owner_id, child_id, amount_ml, fed_at)
  values (v_child.owner_id, v_child.id, p_amount_ml, coalesce(p_fed_at, now())) returning * into v_feed;
  update public.formula_inventory
     set stock_ml_equivalent = greatest(0, stock_ml_equivalent - p_amount_ml), updated_at = now()
   where child_id = v_child.id;
  return v_feed;
end;
$$;

-- Telegram command function: resolves a child's exact name only within the chat owner's profiles.
create or replace function public.log_feeding_by_telegram(p_chat_id text, p_child_name text, p_amount_ml integer)
returns table(child_name text, amount_ml integer, fed_at timestamptz, next_due_at timestamptz)
language plpgsql security definer set search_path = public, auth
as $$
declare v_child public.children;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;
  select * into v_child from public.children
   where telegram_chat_id = p_chat_id and lower(trim(name)) = lower(trim(p_child_name)) and active = true;
  if not found then raise exception 'No active child matches this name for this Telegram chat'; end if;
  perform public.log_feeding(v_child.id, p_amount_ml, now());
  return query select v_child.name, p_amount_ml, now(), now() + make_interval(mins => v_child.feeding_interval_minutes);
end;
$$;

-- n8n calls this every 15 minutes. Return due children, and only after sending, mark them reminded.
create or replace function public.get_due_reminders()
returns table(child_id uuid, child_name text, chat_id text, last_fed_at timestamptz,
              next_due_at timestamptz, interval_minutes integer, suggested_ml integer)
language sql security definer set search_path = public, auth
as $$
  select c.id, c.name, c.telegram_chat_id, f.fed_at,
         f.fed_at + make_interval(mins => c.feeding_interval_minutes),
         c.feeding_interval_minutes,
         case when c.weight_kg is null or current_date - c.date_of_birth < 7 or current_date - c.date_of_birth >= 183 then null
              else greatest(30, round(c.weight_kg * 150 / c.feeds_per_day)::integer) end
    from public.children c
    join lateral (select x.fed_at from public.feedings x where x.child_id = c.id order by x.fed_at desc limit 1) f on true
   where c.active and c.telegram_chat_id is not null
     and f.fed_at + make_interval(mins => c.feeding_interval_minutes) <= now()
     and (c.last_reminded_at is null or c.last_reminded_at < now() - interval '60 minutes');
$$;

drop function if exists public.mark_reminded(uuid);
create function public.mark_reminded(p_child_id uuid)
returns table(child_id uuid) language plpgsql security definer set search_path = public, auth
as $$
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;
  return query update public.children set last_reminded_at = now(), updated_at = now()
    where id = p_child_id returning id;
end;
$$;

create or replace function public.get_inventory_alerts()
returns table(child_id uuid, child_name text, chat_id text, product_name text,
              stock_ml integer, threshold_ml integer, daily_avg_ml numeric,
              days_left numeric, reorder_now boolean)
language sql security definer set search_path = public, auth
as $$
  select c.id, c.name, c.telegram_chat_id, i.product_name, i.stock_ml_equivalent,
         i.reorder_threshold_ml, coalesce(avg7.daily_ml, 0),
         case when coalesce(avg7.daily_ml, 0) > 0 then round(i.stock_ml_equivalent / avg7.daily_ml, 1) else null end,
         (i.stock_ml_equivalent <= i.reorder_threshold_ml or
          (coalesce(avg7.daily_ml, 0) > 0 and i.stock_ml_equivalent / avg7.daily_ml <= i.delivery_lead_days))
    from public.formula_inventory i join public.children c on c.id = i.child_id
    left join lateral (
      select sum(f.amount_ml)::numeric / 7 as daily_ml from public.feedings f
       where f.child_id = c.id and f.fed_at >= now() - interval '7 days'
    ) avg7 on true
   where c.active and c.telegram_chat_id is not null
     and (i.stock_ml_equivalent <= i.reorder_threshold_ml or
          (coalesce(avg7.daily_ml, 0) > 0 and i.stock_ml_equivalent / avg7.daily_ml <= i.delivery_lead_days));
$$;

revoke all on function public.log_feeding(uuid, integer, timestamptz) from public, anon;
revoke all on function public.log_feeding_by_telegram(text, text, integer) from public, anon, authenticated;
revoke all on function public.get_due_reminders() from public, anon, authenticated;
revoke all on function public.mark_reminded(uuid) from public, anon, authenticated;
revoke all on function public.get_inventory_alerts() from public, anon, authenticated;
grant execute on function public.log_feeding(uuid, integer, timestamptz) to authenticated, service_role;
grant execute on function public.log_feeding_by_telegram(text, text, integer) to service_role;
grant execute on function public.get_due_reminders() to service_role;
grant execute on function public.mark_reminded(uuid) to service_role;
grant execute on function public.get_inventory_alerts() to service_role;

