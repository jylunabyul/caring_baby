-- Apply AFTER daddy_bob_jooseyo.sql. Telegram-only migration for EMPTY app tables.
-- No changes to auth.users, shared Auth settings, or other applications' objects.
begin;
lock table public.daddy_bob_jooseyo_children,
  public.daddy_bob_jooseyo_feedings,
  public.daddy_bob_jooseyo_formula_inventory in access exclusive mode;

do $guard$
begin
  if exists (select 1 from public.daddy_bob_jooseyo_children)
     or exists (select 1 from public.daddy_bob_jooseyo_feedings)
     or exists (select 1 from public.daddy_bob_jooseyo_formula_inventory) then
    raise exception 'App tables contain data. Stop: a data-preserving migration is required.';
  end if;
end;
$guard$;

-- Remove only this app's browser policies. RLS stays enabled.
drop policy if exists daddy_bob_jooseyo_children_owner_all on public.daddy_bob_jooseyo_children;
drop policy if exists daddy_bob_jooseyo_feedings_owner_all on public.daddy_bob_jooseyo_feedings;
drop policy if exists daddy_bob_jooseyo_inventory_owner_all on public.daddy_bob_jooseyo_formula_inventory;

-- No CASCADE: unexpected dependent objects cause a rollback instead of being removed.
alter table public.daddy_bob_jooseyo_children drop column owner_id;
alter table public.daddy_bob_jooseyo_feedings drop column owner_id;
alter table public.daddy_bob_jooseyo_formula_inventory drop column owner_id;
alter table public.daddy_bob_jooseyo_children
  alter column telegram_chat_id set not null,
  add constraint daddy_bob_jooseyo_private_chat_check check (telegram_chat_id = '9114513581'),
  add constraint daddy_bob_jooseyo_chat_name_key unique (telegram_chat_id, name);

revoke all on table public.daddy_bob_jooseyo_children,
  public.daddy_bob_jooseyo_feedings,
  public.daddy_bob_jooseyo_formula_inventory from public, anon, authenticated;
grant select, insert, update, delete on table public.daddy_bob_jooseyo_children,
  public.daddy_bob_jooseyo_feedings,
  public.daddy_bob_jooseyo_formula_inventory to service_role;

create or replace function public.daddy_bob_jooseyo_log_feeding(p_child_id uuid, p_amount_ml integer, p_fed_at timestamptz default now())
returns public.daddy_bob_jooseyo_feedings
language plpgsql security definer set search_path = public, auth
as $$
declare
  v_child public.daddy_bob_jooseyo_children;
  v_feed public.daddy_bob_jooseyo_feedings;
begin
  select * into v_child from public.daddy_bob_jooseyo_children where id = p_child_id and active = true;
  if not found then raise exception 'Child not found or inactive'; end if;
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role required';
  end if;
  if p_amount_ml < 1 or p_amount_ml > 1000 then raise exception 'Invalid amount'; end if;
  insert into public.daddy_bob_jooseyo_feedings(child_id, amount_ml, fed_at)
  values (v_child.id, p_amount_ml, coalesce(p_fed_at, now())) returning * into v_feed;
  update public.daddy_bob_jooseyo_formula_inventory
     set stock_ml_equivalent = greatest(0, stock_ml_equivalent - p_amount_ml), updated_at = now()
   where child_id = v_child.id;
  return v_feed;
end;
$$;

-- Telegram command function: resolves a child's exact name only within the chat owner's profiles.
create or replace function public.daddy_bob_jooseyo_log_feeding_by_telegram(p_chat_id text, p_child_name text, p_amount_ml integer)
returns table(child_name text, amount_ml integer, fed_at timestamptz, next_due_at timestamptz)
language plpgsql security definer set search_path = public, auth
as $$
declare v_child public.daddy_bob_jooseyo_children;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'Service role required'; end if;
  select * into v_child from public.daddy_bob_jooseyo_children
   where telegram_chat_id = p_chat_id and lower(trim(name)) = lower(trim(p_child_name)) and active = true;
  if not found then raise exception 'No active child matches this name for this Telegram chat'; end if;
  perform public.daddy_bob_jooseyo_log_feeding(v_child.id, p_amount_ml, now());
  return query select v_child.name, p_amount_ml, now(), now() + make_interval(mins => v_child.feeding_interval_minutes);
end;
$$;


revoke all on function public.daddy_bob_jooseyo_log_feeding(uuid, integer, timestamptz) from public, anon, authenticated;
revoke all on function public.daddy_bob_jooseyo_log_feeding_by_telegram(text, text, integer) from public, anon, authenticated;
grant execute on function public.daddy_bob_jooseyo_log_feeding(uuid, integer, timestamptz) to service_role;
grant execute on function public.daddy_bob_jooseyo_log_feeding_by_telegram(text, text, integer) to service_role;
commit;

-- Expected: 3 rows; rowsecurity=true and browser_can_read=false on each.
select c.relname as tablename, c.relrowsecurity as rowsecurity,
  has_table_privilege('authenticated', c.oid, 'SELECT') as browser_can_read
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname in
('daddy_bob_jooseyo_children', 'daddy_bob_jooseyo_feedings', 'daddy_bob_jooseyo_formula_inventory')
order by c.relname;
