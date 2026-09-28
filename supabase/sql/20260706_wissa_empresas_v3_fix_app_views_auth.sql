-- Wissa Empresas v3
-- Corrige:
-- 1) Error app: Could not find the table public.v_company_bookings in schema cache.
-- 2) Error al crear personal: Database error creating new user por trigger de auth/profiles.
-- 3) Refresca schema cache de PostgREST.

create extension if not exists pgcrypto;

-- =========================================================
-- Trigger auth seguro para que Supabase Auth pueda crear usuarios
-- aunque existan columnas/constraints antiguos en profiles.
-- =========================================================

alter table if exists public.profiles
  drop constraint if exists profiles_role_check;

alter table if exists public.profiles
  add constraint profiles_role_check
  check (
    role = any (
      array[
        'client'::text, 'vendor'::text,
        'buyer'::text, 'provider'::text, 'both'::text,
        'contratar'::text, 'ofrecer'::text, 'ambos'::text,
        'company'::text, 'empresa'::text,
        'company_staff'::text, 'personal_empresa'::text,
        'admin'::text, 'super_admin'::text
      ]
    )
  );

alter table if exists public.profiles
  add column if not exists email text,
  add column if not exists full_name text,
  add column if not exists display_name text,
  add column if not exists phone text,
  add column if not exists city text,
  add column if not exists role text default 'buyer',
  add column if not exists provider_status text default 'approved',
  add column if not exists status text default 'active',
  add column if not exists is_verified boolean default false,
  add column if not exists is_available boolean default false,
  add column if not exists mode_preference text default 'buyer',
  add column if not exists theme_preference text default 'system',
  add column if not exists account_type text,
  add column if not exists company_enabled boolean default false,
  add column if not exists active_company_id uuid,
  add column if not exists company_role text,
  add column if not exists is_company_owner boolean default false,
  add column if not exists provider_enabled boolean default false,
  add column if not exists is_active boolean default true,
  add column if not exists updated_at timestamptz default now(),
  add column if not exists created_at timestamptz default now();

create or replace function public.normalize_profile_role(raw_role text)
returns text
language plpgsql
as $$
begin
  case lower(coalesce(raw_role, 'buyer'))
    when 'client' then return 'buyer';
    when 'buyer' then return 'buyer';
    when 'contract' then return 'buyer';
    when 'contratar' then return 'buyer';
    when 'vendor' then return 'provider';
    when 'provider' then return 'provider';
    when 'offer' then return 'provider';
    when 'ofrecer' then return 'provider';
    when 'both' then return 'both';
    when 'ambos' then return 'both';
    when 'company' then return 'company';
    when 'empresa' then return 'company';
    when 'company_staff' then return 'company_staff';
    when 'personal_empresa' then return 'company_staff';
    when 'admin' then return 'admin';
    when 'super_admin' then return 'admin';
    else return 'buyer';
  end case;
end;
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  raw_meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  desired_role text := public.normalize_profile_role(coalesce(raw_meta->>'app_role', raw_meta->>'role', 'buyer'));
  preferred_mode text := case
    when desired_role in ('company', 'company_staff') then 'company'
    when desired_role = 'provider' then 'provider'
    else 'buyer'
  end;
begin
  insert into public.profiles (
    id, email, full_name, display_name, phone, city, role, provider_status, status,
    is_verified, is_available, mode_preference, theme_preference,
    account_type, company_enabled, active_company_id, company_role, is_company_owner,
    provider_enabled, is_active, created_at, updated_at
  )
  values (
    new.id,
    lower(coalesce(new.email, raw_meta->>'email', '')),
    nullif(trim(coalesce(raw_meta->>'full_name', raw_meta->>'name', '')), ''),
    nullif(trim(coalesce(raw_meta->>'full_name', raw_meta->>'name', '')), ''),
    nullif(trim(coalesce(raw_meta->>'phone', '')), ''),
    nullif(trim(coalesce(raw_meta->>'city', '')), ''),
    desired_role,
    'approved',
    'active',
    false,
    false,
    preferred_mode,
    coalesce(nullif(raw_meta->>'theme_preference', ''), 'system'),
    desired_role,
    desired_role in ('company', 'company_staff'),
    nullif(raw_meta->>'company_id', '')::uuid,
    case when desired_role = 'company_staff' then 'company_staff' when desired_role = 'company' then 'company_admin' else null end,
    desired_role = 'company',
    desired_role = 'provider',
    true,
    now(),
    now()
  )
  on conflict (id) do update
  set email = coalesce(nullif(excluded.email, ''), public.profiles.email),
      full_name = coalesce(excluded.full_name, public.profiles.full_name),
      display_name = coalesce(excluded.display_name, public.profiles.display_name, public.profiles.full_name),
      phone = coalesce(excluded.phone, public.profiles.phone),
      city = coalesce(excluded.city, public.profiles.city),
      role = coalesce(excluded.role, public.profiles.role, 'buyer'),
      provider_status = coalesce(public.profiles.provider_status, excluded.provider_status, 'approved'),
      status = coalesce(public.profiles.status, excluded.status, 'active'),
      mode_preference = coalesce(excluded.mode_preference, public.profiles.mode_preference, 'buyer'),
      theme_preference = coalesce(excluded.theme_preference, public.profiles.theme_preference, 'system'),
      account_type = coalesce(excluded.account_type, public.profiles.account_type),
      company_enabled = coalesce(public.profiles.company_enabled, excluded.company_enabled, false),
      active_company_id = coalesce(public.profiles.active_company_id, excluded.active_company_id),
      company_role = coalesce(public.profiles.company_role, excluded.company_role),
      is_active = coalesce(public.profiles.is_active, true),
      updated_at = now();

  return new;
exception when others then
  -- Muy importante: no bloquear la creación del usuario en Auth.
  raise log 'handle_new_user safe failed for %: %', new.id, sqlerrm;
  return new;
end;
$$;

-- Desactivar triggers legacy conocidos y dejar uno seguro.
drop trigger if exists on_auth_user_created on auth.users;
drop trigger if exists handle_new_user on auth.users;
drop trigger if exists on_auth_user_created_profile on auth.users;

create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- =========================================================
-- Columnas necesarias para servicios empresa
-- =========================================================

alter table if exists public.services
  add column if not exists company_id uuid,
  add column if not exists company_member_id uuid,
  add column if not exists source_type text not null default 'marketplace',
  add column if not exists created_by uuid;

create index if not exists idx_services_company_id on public.services(company_id);
create index if not exists idx_services_company_member_id on public.services(company_member_id);
create index if not exists idx_services_source_type on public.services(source_type);

-- Función helper usada por las views.
create or replace function public.yt_is_company_member(p_company_id uuid, p_user_id uuid default auth.uid())
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.companies c
    where c.id = p_company_id
      and c.owner_id = p_user_id
  ) or exists (
    select 1
    from public.company_members cm
    where cm.company_id = p_company_id
      and cm.user_id = p_user_id
      and coalesce(cm.status, 'active') = 'active'
  );
$$;

grant execute on function public.yt_is_company_member(uuid, uuid) to authenticated, service_role;

-- =========================================================
-- Views para app empresa/personal empresa
-- =========================================================

create or replace view public.v_my_company_access
with (security_invoker = true) as
select
  cm.user_id,
  cm.company_id,
  c.name as company_name,
  c.logo_url,
  c.status as company_status,
  coalesce(cm.internal_role, case when cm.role in ('admin_empresa', 'supervisor', 'finanzas') then 'company_admin' else 'company_staff' end) as internal_role,
  cm.status as member_status
from public.company_members cm
join public.companies c on c.id = cm.company_id
where cm.user_id is not null
  and cm.user_id = auth.uid()
  and coalesce(cm.status, 'active') = 'active';

grant select on public.v_my_company_access to authenticated, service_role;

create or replace view public.v_company_subscription_status
with (security_invoker = true) as
select
  c.id as company_id,
  c.name as company_name,
  c.owner_id,
  c.status,
  c.subscription_status,
  c.plan_status,
  c.subscription_price,
  c.subscription_days,
  c.subscription_started_at,
  c.subscription_last_paid_at,
  c.subscription_expires_at,
  case
    when c.subscription_expires_at is null then null
    else greatest(ceil(extract(epoch from (c.subscription_expires_at - now())) / 86400.0)::integer, 0)
  end as days_left,
  (
    coalesce(c.status, 'active') = 'active'
    and coalesce(c.subscription_status, 'active') = 'active'
    and coalesce(c.subscription_expires_at, now() + interval '1 day') >= now()
  ) as is_access_active,
  cps.price as current_plan_price,
  cps.duration_days as current_plan_days
from public.companies c
left join lateral (
  select price, duration_days
  from public.company_plan_settings
  where code = 'company_basic' or coalesce(is_active, true) = true
  order by case when code = 'company_basic' then 0 else 1 end, updated_at desc nulls last
  limit 1
) cps on true
where public.yt_is_company_member(c.id);

grant select on public.v_company_subscription_status to authenticated, service_role;

create or replace view public.v_company_bookings
with (security_invoker = true) as
select
  b.id,
  coalesce(b.company_id, s.company_id) as company_id,
  b.company_location_id,
  coalesce(cl.name, b.location, 'Sin sede') as company_location_name,
  b.company_member_id,
  cm.full_name as company_member_name,
  b.company_requested_by,
  req.full_name as requested_by_name,
  b.provider_id,
  prov.full_name as provider_name,
  b.service_id,
  coalesce(b.service_title, s.title, 'Servicio') as service_title,
  s.category as service_category,
  b.booking_date,
  b.booking_time,
  b.status,
  b.payment_status,
  b.company_approval_status,
  b.company_request_status,
  coalesce(b.total_amount, b.price_snapshot, 0) as total_amount,
  coalesce(b.platform_fee, 0) as platform_fee,
  coalesce(b.seller_payout, greatest(coalesce(b.total_amount, b.price_snapshot, 0) - coalesce(b.platform_fee, 0), 0)) as seller_payout,
  b.payment_method,
  b.payment_provider,
  b.created_at,
  b.updated_at
from public.bookings b
left join public.services s on s.id = b.service_id
left join public.company_locations cl on cl.id = b.company_location_id
left join public.company_members cm on cm.id = b.company_member_id
left join public.profiles req on req.id = b.company_requested_by
left join public.profiles prov on prov.id = b.provider_id
where coalesce(b.company_id, s.company_id) is not null
  and (
    public.yt_is_company_member(coalesce(b.company_id, s.company_id))
    or b.provider_id = auth.uid()
  );

grant select on public.v_company_bookings to authenticated, service_role;

create or replace view public.v_company_staff_services
with (security_invoker = true) as
select
  s.id,
  s.provider_id as staff_user_id,
  s.company_id,
  c.name as company_name,
  s.company_member_id,
  cm.full_name as staff_name,
  cm.email as staff_email,
  s.title,
  s.description,
  s.category,
  s.price,
  s.duration_minutes,
  s.is_active,
  s.created_at,
  s.updated_at
from public.services s
join public.companies c on c.id = s.company_id
left join public.company_members cm on cm.id = s.company_member_id
where coalesce(s.source_type, '') = 'company_service'
  and (s.provider_id = auth.uid() or public.yt_is_company_member(s.company_id));

grant select on public.v_company_staff_services to authenticated, service_role;

create or replace view public.v_company_staff_bookings
with (security_invoker = true) as
select
  b.id,
  b.provider_id as staff_user_id,
  coalesce(b.company_id, s.company_id) as company_id,
  c.name as company_name,
  b.service_id,
  coalesce(b.service_title, s.title, 'Servicio empresa') as service_title,
  buyer.full_name as client_name,
  b.booking_date,
  b.booking_time,
  b.status,
  b.payment_status,
  b.payout_release_status,
  b.company_request_status,
  b.company_approval_status,
  coalesce(b.total_amount, b.price_snapshot, 0) as total_amount,
  coalesce(b.platform_fee, 0) as platform_fee,
  greatest(coalesce(b.total_amount, b.price_snapshot, 0) - coalesce(b.platform_fee, 0), 0) as company_net,
  b.created_at,
  b.updated_at
from public.bookings b
join public.services s on s.id = b.service_id and coalesce(s.source_type, '') = 'company_service'
left join public.companies c on c.id = coalesce(b.company_id, s.company_id)
left join public.profiles buyer on buyer.id = b.buyer_id
where b.provider_id = auth.uid()
   or public.yt_is_company_member(coalesce(b.company_id, s.company_id));

grant select on public.v_company_staff_bookings to authenticated, service_role;

-- Refrescar cache de Supabase/PostgREST para que las views aparezcan en el app.
notify pgrst, 'reload schema';
