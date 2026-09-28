-- Wissa Empresas: personal con acceso app, servicios empresariales separados y liquidación a empresa
-- Ejecutar en Supabase SQL Editor y desplegar Edge Function company-create-staff-account.
-- No elimina datos existentes.

alter table public.services
  add column if not exists company_id uuid references public.companies(id),
  add column if not exists company_member_id uuid references public.company_members(id),
  add column if not exists source_type text not null default 'marketplace',
  add column if not exists created_by uuid references public.profiles(id);

create index if not exists idx_services_company_id on public.services(company_id);
create index if not exists idx_services_company_member_id on public.services(company_member_id);
create index if not exists idx_services_source_type on public.services(source_type);

create table if not exists public.company_payouts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  booking_id uuid references public.bookings(id),
  payment_order_id uuid references public.payment_orders(id),
  amount numeric not null default 0,
  currency text not null default 'USD',
  status text not null default 'paid' check (status in ('pending','paid','cancelled')),
  method text not null default 'manual_admin',
  reference text,
  note text,
  admin_id uuid references public.profiles(id),
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists idx_company_payouts_company_id on public.company_payouts(company_id);
create index if not exists idx_company_payouts_booking_id on public.company_payouts(booking_id);

create or replace function public.yt_is_company_admin(p_company_id uuid, p_user_id uuid default auth.uid())
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
      and coalesce(cm.internal_role, cm.role) in ('company_admin', 'admin_empresa', 'supervisor', 'finanzas')
  );
$$;

grant execute on function public.yt_is_company_admin(uuid, uuid) to authenticated, service_role;

create or replace function public.yt_company_web_create_member(
  p_company_id uuid,
  p_full_name text,
  p_email text,
  p_phone text default null,
  p_department text default null,
  p_position text default null,
  p_internal_role text default 'company_staff',
  p_location_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := lower(trim(coalesce(p_email, '')));
  v_member_id uuid;
  v_existing_user uuid;
  v_role text := case when p_internal_role = 'company_admin' then 'company_admin' else 'company_staff' end;
begin
  if v_user_id is null then
    raise exception 'Debes iniciar sesion.';
  end if;

  if not public.yt_is_company_admin(p_company_id, v_user_id) then
    raise exception 'Solo el Admin Empresa puede agregar personal.';
  end if;

  if nullif(trim(coalesce(p_full_name, '')), '') is null then
    raise exception 'El nombre es obligatorio.';
  end if;

  if v_email = '' then
    raise exception 'El correo es obligatorio.';
  end if;

  select id into v_existing_user
  from public.profiles
  where lower(coalesce(email, '')) = v_email
  limit 1;

  select id into v_member_id
  from public.company_members
  where company_id = p_company_id
    and lower(email) = v_email
  limit 1;

  if v_member_id is not null then
    update public.company_members
    set user_id = coalesce(v_existing_user, user_id),
        full_name = trim(p_full_name),
        phone = nullif(trim(coalesce(p_phone, '')), ''),
        department = null,
        position = nullif(trim(coalesce(p_position, '')), ''),
        location_id = null,
        role = case when v_role = 'company_admin' then 'admin_empresa' else 'operador' end,
        internal_role = v_role,
        status = case when coalesce(v_existing_user, user_id) is null then 'invited' else 'active' end,
        can_create_bookings = true,
        can_approve_bookings = (v_role = 'company_admin'),
        can_view_finance = (v_role = 'company_admin'),
        can_manage_staff = (v_role = 'company_admin'),
        accepted_at = case when coalesce(v_existing_user, user_id) is null then accepted_at else coalesce(accepted_at, now()) end,
        joined_at = case when coalesce(v_existing_user, user_id) is null then joined_at else coalesce(joined_at, now()) end,
        updated_at = now()
    where id = v_member_id;
  else
    insert into public.company_members (
      company_id, location_id, user_id, full_name, email, phone, department, position,
      role, internal_role, status, can_create_bookings, can_approve_bookings,
      can_view_finance, can_manage_staff, invited_by, invited_at, accepted_at, joined_at, metadata
    ) values (
      p_company_id, null, v_existing_user, trim(p_full_name), v_email,
      nullif(trim(coalesce(p_phone, '')), ''), null, nullif(trim(coalesce(p_position, '')), ''),
      case when v_role = 'company_admin' then 'admin_empresa' else 'operador' end,
      v_role,
      case when v_existing_user is null then 'invited' else 'active' end,
      true, (v_role = 'company_admin'), (v_role = 'company_admin'), (v_role = 'company_admin'),
      v_user_id, now(), case when v_existing_user is null then null else now() end,
      case when v_existing_user is null then null else now() end,
      jsonb_build_object('source', 'company_web', 'password_managed_by', 'company_admin')
    ) returning id into v_member_id;
  end if;

  if v_existing_user is not null then
    update public.profiles
    set company_enabled = true,
        active_company_id = p_company_id,
        company_role = v_role,
        role = 'company_staff',
        account_type = 'company_staff',
        mode_preference = 'company',
        updated_at = now()
    where id = v_existing_user;
  end if;

  return v_member_id;
end;
$$;

grant execute on function public.yt_company_web_create_member(uuid, text, text, text, text, text, text, uuid) to authenticated, service_role;

create or replace function public.yt_company_web_create_service(
  p_company_id uuid,
  p_company_member_id uuid,
  p_title text,
  p_description text default null,
  p_category text default 'Limpieza',
  p_price numeric default 0,
  p_duration_minutes integer default 60
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_provider_id uuid;
  v_service_id uuid;
  v_category text := trim(coalesce(p_category, ''));
  v_price numeric := coalesce(p_price, 0);
begin
  if v_user_id is null then
    raise exception 'Debes iniciar sesion.';
  end if;

  if not public.yt_is_company_admin(p_company_id, v_user_id) then
    raise exception 'Solo el Admin Empresa puede crear servicios.';
  end if;

  select cm.user_id
  into v_provider_id
  from public.company_members cm
  where cm.id = p_company_member_id
    and cm.company_id = p_company_id
    and coalesce(cm.status, 'active') = 'active';

  if v_provider_id is null then
    raise exception 'Primero crea el acceso app del personal desde Empresa > Personal.';
  end if;

  if nullif(trim(coalesce(p_title, '')), '') is null then
    raise exception 'El titulo del servicio es obligatorio.';
  end if;

  if v_category not in ('Limpieza', 'Plomería', 'Limpieza de exteriores') then
    raise exception 'Selecciona una categoria base: Limpieza, Plomería o Limpieza de exteriores.';
  end if;

  if v_price <= 0 then
    raise exception 'El precio del servicio debe ser mayor a 0.';
  end if;

  insert into public.services (
    provider_id, title, description, category, price, duration_minutes, is_active,
    company_id, company_member_id, source_type, created_by
  ) values (
    v_provider_id, trim(p_title), nullif(trim(coalesce(p_description, '')), ''), v_category,
    v_price, greatest(coalesce(p_duration_minutes, 60), 15), true,
    p_company_id, p_company_member_id, 'company_service', v_user_id
  ) returning id into v_service_id;

  return v_service_id;
end;
$$;

grant execute on function public.yt_company_web_create_service(uuid, uuid, text, text, text, numeric, integer) to authenticated, service_role;

create or replace view public.v_company_staff_services as
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
where coalesce(s.source_type, '') = 'company_service';

grant select on public.v_company_staff_services to authenticated, service_role;

create or replace view public.v_company_staff_bookings as
select
  b.id,
  b.provider_id as staff_user_id,
  coalesce(b.company_id, s.company_id) as company_id,
  c.name as company_name,
  b.service_id,
  coalesce(b.service_title, s.title) as service_title,
  buyer.full_name as client_name,
  b.booking_date,
  b.booking_time,
  b.status,
  b.payment_status,
  b.payout_release_status,
  b.total_amount,
  b.platform_fee,
  greatest(coalesce(b.total_amount, 0) - coalesce(b.platform_fee, 0), 0) as company_net,
  b.created_at,
  b.updated_at
from public.bookings b
join public.services s on s.id = b.service_id and coalesce(s.source_type, '') = 'company_service'
left join public.companies c on c.id = coalesce(b.company_id, s.company_id)
left join public.profiles buyer on buyer.id = b.buyer_id;

grant select on public.v_company_staff_bookings to authenticated, service_role;

create or replace function public.yt_admin_company_services_finance_json(
  p_search text default '',
  p_status text default 'all',
  p_limit integer default 500,
  p_date_from date default null,
  p_date_to date default null
)
returns jsonb
language sql
security definer
set search_path = public
as $$
  with rows as (
    select
      b.id,
      b.id as booking_id,
      c.id as company_id,
      c.name as company_name,
      coalesce(b.service_title, s.title) as service_title,
      staff.full_name as staff_name,
      buyer.full_name as buyer_name,
      b.status,
      b.payment_status,
      coalesce(b.payout_release_status, 'not_released') as release_status,
      case
        when b.payment_status = 'paid' and coalesce(b.payout_release_status, 'not_released') = 'released' then 'Liquidado'
        when b.payment_status = 'paid' then 'Por liquidar'
        when b.payment_status = 'failed' then 'Fallido'
        else b.status
      end as status_label,
      coalesce(b.total_amount, 0) as amount,
      coalesce(b.platform_fee, 0) as platform_fee,
      greatest(coalesce(b.total_amount, 0) - coalesce(b.platform_fee, 0), 0) as company_net,
      b.booking_date,
      b.booking_time,
      b.created_at,
      b.updated_at
    from public.bookings b
    join public.services s on s.id = b.service_id and coalesce(s.source_type, '') = 'company_service'
    join public.companies c on c.id = coalesce(b.company_id, s.company_id)
    left join public.profiles staff on staff.id = b.provider_id
    left join public.profiles buyer on buyer.id = b.buyer_id
    where (
      coalesce(p_search, '') = ''
      or c.name ilike '%' || p_search || '%'
      or coalesce(b.service_title, s.title) ilike '%' || p_search || '%'
      or staff.full_name ilike '%' || p_search || '%'
      or buyer.full_name ilike '%' || p_search || '%'
      or b.id::text ilike '%' || p_search || '%'
    )
    and (
      coalesce(p_status, 'all') = 'all'
      or p_status = b.status
      or p_status = b.payment_status
      or p_status = coalesce(b.payout_release_status, 'not_released')
    )
    and (p_date_from is null or b.created_at::date >= p_date_from)
    and (p_date_to is null or b.created_at::date <= p_date_to)
    order by b.created_at desc
    limit greatest(coalesce(p_limit, 500), 1)
  )
  select coalesce(jsonb_agg(to_jsonb(rows)), '[]'::jsonb) from rows;
$$;

grant execute on function public.yt_admin_company_services_finance_json(text, text, integer, date, date) to authenticated, service_role;

create or replace function public.yt_admin_liquidate_company_booking(
  p_booking_id uuid,
  p_note text default null,
  p_method text default 'manual_admin'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_booking public.bookings%rowtype;
  v_service public.services%rowtype;
  v_company_id uuid;
  v_amount numeric;
  v_payout_id uuid;
begin
  if v_admin is null then
    raise exception 'Debes iniciar sesión.';
  end if;

  if not exists (select 1 from public.profiles where id = v_admin and (is_admin = true or role in ('admin','super_admin'))) then
    raise exception 'Solo Admin Wissa puede liquidar empresas.';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id;
  if not found then raise exception 'Reserva no encontrada.'; end if;

  select * into v_service from public.services where id = v_booking.service_id;
  if coalesce(v_service.source_type, '') <> 'company_service' then
    raise exception 'Esta reserva no pertenece a servicios empresariales.';
  end if;

  if v_booking.payment_status <> 'paid' then
    raise exception 'Solo se puede liquidar una reserva pagada.';
  end if;

  v_company_id := coalesce(v_booking.company_id, v_service.company_id);
  if v_company_id is null then raise exception 'Reserva sin empresa asociada.'; end if;

  v_amount := greatest(coalesce(v_booking.total_amount, 0) - coalesce(v_booking.platform_fee, 0), 0);
  if v_amount <= 0 then raise exception 'No hay neto para liquidar.'; end if;

  if coalesce(v_booking.payout_release_status, 'not_released') = 'released' then
    raise exception 'Esta reserva ya fue liquidada.';
  end if;

  insert into public.company_payouts (
    company_id, booking_id, amount, currency, status, method, note, admin_id, paid_at, metadata
  ) values (
    v_company_id, p_booking_id, v_amount, 'USD', 'paid', coalesce(p_method, 'manual_admin'), nullif(trim(coalesce(p_note, '')), ''), v_admin, now(),
    jsonb_build_object('source', 'admin_web', 'total_amount', v_booking.total_amount, 'platform_fee', v_booking.platform_fee)
  ) returning id into v_payout_id;

  update public.bookings
  set payout_release_status = 'released',
      finance_status = 'released',
      provider_payout_note = coalesce(p_note, provider_payout_note),
      provider_paid_out_at = now(),
      payout_released_at = now(),
      updated_at = now()
  where id = p_booking_id;

  return jsonb_build_object('ok', true, 'payout_id', v_payout_id, 'company_id', v_company_id, 'amount', v_amount);
end;
$$;

grant execute on function public.yt_admin_liquidate_company_booking(uuid, text, text) to authenticated, service_role;




-- =========================================================
-- Wissa Empresas v2: Dashboard limpio, edición, eliminación lógica y acceso app
-- Ejecutar este archivo después de reemplazar el código del ZIP.
-- =========================================================

create extension if not exists pgcrypto;

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
  add column if not exists display_name text,
  add column if not exists account_type text,
  add column if not exists company_enabled boolean default false,
  add column if not exists active_company_id uuid,
  add column if not exists company_role text,
  add column if not exists is_company_owner boolean default false,
  add column if not exists provider_enabled boolean default false,
  add column if not exists is_active boolean default true,
  add column if not exists status text default 'active',
  add column if not exists mode_preference text default 'buyer',
  add column if not exists theme_preference text default 'system';

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
    when desired_role = 'company' then 'company'
    when desired_role = 'company_staff' then 'company'
    when desired_role = 'provider' then 'provider'
    when lower(coalesce(raw_meta->>'mode_preference', '')) in ('provider', 'ofrecer') then 'provider'
    else 'buyer'
  end;
begin
  insert into public.profiles (
    id, email, full_name, display_name, phone, city, role, provider_status, status,
    is_verified, is_available, mode_preference, theme_preference,
    account_type, company_enabled, active_company_id, company_role, is_company_owner
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
    case when desired_role = 'company_staff' then 'company_staff' when desired_role = 'company' then 'company' else desired_role end,
    desired_role in ('company', 'company_staff'),
    nullif(raw_meta->>'company_id', '')::uuid,
    case when desired_role = 'company_staff' then 'company_staff' when desired_role = 'company' then 'company_admin' else null end,
    desired_role = 'company'
  )
  on conflict (id) do update
  set
    email = coalesce(nullif(excluded.email, ''), public.profiles.email),
    full_name = coalesce(excluded.full_name, public.profiles.full_name),
    display_name = coalesce(excluded.display_name, public.profiles.display_name, public.profiles.full_name),
    phone = coalesce(excluded.phone, public.profiles.phone),
    city = coalesce(excluded.city, public.profiles.city),
    role = coalesce(excluded.role, public.profiles.role),
    provider_status = coalesce(public.profiles.provider_status, 'approved'),
    status = coalesce(public.profiles.status, 'active'),
    mode_preference = coalesce(excluded.mode_preference, public.profiles.mode_preference, 'buyer'),
    theme_preference = coalesce(excluded.theme_preference, public.profiles.theme_preference, 'system'),
    account_type = coalesce(excluded.account_type, public.profiles.account_type),
    company_enabled = coalesce(public.profiles.company_enabled, excluded.company_enabled, false),
    active_company_id = coalesce(public.profiles.active_company_id, excluded.active_company_id),
    company_role = coalesce(public.profiles.company_role, excluded.company_role),
    updated_at = now();

  return new;
exception when others then
  raise log 'handle_new_user failed for %: %', new.id, sqlerrm;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

alter table if exists public.services
  add column if not exists company_id uuid,
  add column if not exists company_member_id uuid,
  add column if not exists source_type text not null default 'marketplace',
  add column if not exists created_by uuid;

create index if not exists idx_services_company_id on public.services(company_id);
create index if not exists idx_services_company_member_id on public.services(company_member_id);
create index if not exists idx_services_source_type on public.services(source_type);

create table if not exists public.company_payouts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  booking_id uuid references public.bookings(id),
  payment_order_id uuid references public.payment_orders(id),
  amount numeric not null default 0,
  currency text not null default 'USD',
  status text not null default 'paid',
  method text not null default 'manual_admin',
  reference text,
  note text,
  admin_id uuid references public.profiles(id),
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create or replace function public.yt_is_company_admin(p_company_id uuid, p_user_id uuid default auth.uid())
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.companies c where c.id = p_company_id and c.owner_id = p_user_id
  ) or exists (
    select 1 from public.company_members cm
    where cm.company_id = p_company_id
      and cm.user_id = p_user_id
      and coalesce(cm.status, 'active') = 'active'
      and coalesce(cm.internal_role, cm.role) in ('company_admin', 'admin_empresa', 'supervisor', 'finanzas')
  );
$$;

grant execute on function public.yt_is_company_admin(uuid, uuid) to authenticated, service_role;

create or replace function public.yt_company_web_update_member(
  p_member_id uuid,
  p_full_name text,
  p_email text,
  p_phone text default null,
  p_position text default null,
  p_internal_role text default 'company_staff',
  p_password text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_member public.company_members%rowtype;
  v_role text := case when p_internal_role = 'company_admin' then 'company_admin' else 'company_staff' end;
begin
  if v_user_id is null then raise exception 'Debes iniciar sesión.'; end if;
  select * into v_member from public.company_members where id = p_member_id;
  if not found then raise exception 'Personal no encontrado.'; end if;
  if not public.yt_is_company_admin(v_member.company_id, v_user_id) then raise exception 'Solo el Admin Empresa puede editar personal.'; end if;

  update public.company_members
  set full_name = trim(coalesce(p_full_name, full_name)),
      email = lower(trim(coalesce(p_email, email))),
      phone = nullif(trim(coalesce(p_phone, '')), ''),
      position = nullif(trim(coalesce(p_position, '')), ''),
      department = null,
      location_id = null,
      role = case when v_role = 'company_admin' then 'admin_empresa' else 'operador' end,
      internal_role = v_role,
      can_approve_bookings = (v_role = 'company_admin'),
      can_view_finance = (v_role = 'company_admin'),
      can_manage_staff = (v_role = 'company_admin'),
      updated_at = now()
  where id = p_member_id;

  if v_member.user_id is not null then
    update public.profiles
    set full_name = trim(coalesce(p_full_name, full_name)),
        display_name = trim(coalesce(p_full_name, display_name, full_name)),
        email = lower(trim(coalesce(p_email, email))),
        phone = nullif(trim(coalesce(p_phone, '')), ''),
        role = 'company_staff',
        account_type = 'company_staff',
        mode_preference = 'company',
        company_enabled = true,
        active_company_id = v_member.company_id,
        company_role = v_role,
        updated_at = now()
    where id = v_member.user_id;
  end if;

  return p_member_id;
end;
$$;

grant execute on function public.yt_company_web_update_member(uuid, text, text, text, text, text, text) to authenticated, service_role;

create or replace function public.yt_company_web_set_member_status(p_member_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_member public.company_members%rowtype;
  v_status text := lower(trim(coalesce(p_status, '')));
begin
  if v_user_id is null then raise exception 'Debes iniciar sesión.'; end if;
  select * into v_member from public.company_members where id = p_member_id;
  if not found then raise exception 'Personal no encontrado.'; end if;
  if not public.yt_is_company_admin(v_member.company_id, v_user_id) then raise exception 'Solo el Admin Empresa puede actualizar personal.'; end if;
  if v_status not in ('active','inactive','removed') then raise exception 'Estado inválido.'; end if;

  update public.company_members set status = v_status, updated_at = now() where id = p_member_id;

  if v_status in ('inactive','removed') then
    update public.services
    set is_active = false, updated_at = now()
    where company_member_id = p_member_id and coalesce(source_type, '') = 'company_service';
  end if;
end;
$$;

grant execute on function public.yt_company_web_set_member_status(uuid, text) to authenticated, service_role;

create or replace function public.yt_company_web_update_service(
  p_service_id uuid,
  p_company_member_id uuid,
  p_title text,
  p_description text default null,
  p_category text default 'Limpieza',
  p_price numeric default 0,
  p_duration_minutes integer default 60
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_service public.services%rowtype;
  v_member public.company_members%rowtype;
  v_category text := trim(coalesce(p_category, ''));
  v_price numeric := coalesce(p_price, 0);
begin
  if v_user_id is null then raise exception 'Debes iniciar sesión.'; end if;
  select * into v_service from public.services where id = p_service_id and coalesce(source_type, '') = 'company_service';
  if not found then raise exception 'Servicio empresarial no encontrado.'; end if;
  if not public.yt_is_company_admin(v_service.company_id, v_user_id) then raise exception 'Solo el Admin Empresa puede editar servicios.'; end if;
  if v_category not in ('Limpieza', 'Plomería', 'Limpieza de exteriores') then raise exception 'Categoría base inválida.'; end if;
  if v_price <= 0 then raise exception 'El precio del servicio debe ser mayor a 0.'; end if;

  select * into v_member from public.company_members where id = p_company_member_id and company_id = v_service.company_id and coalesce(status, 'active') = 'active';
  if not found or v_member.user_id is null then raise exception 'Selecciona un personal activo con cuenta app.'; end if;

  update public.services
  set company_member_id = p_company_member_id,
      provider_id = v_member.user_id,
      title = trim(p_title),
      description = nullif(trim(coalesce(p_description, '')), ''),
      category = v_category,
      price = v_price,
      duration_minutes = greatest(coalesce(p_duration_minutes, 60), 15),
      updated_at = now()
  where id = p_service_id;

  return p_service_id;
end;
$$;

grant execute on function public.yt_company_web_update_service(uuid, uuid, text, text, text, numeric, integer) to authenticated, service_role;

create or replace function public.yt_company_web_remove_service(p_service_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_service public.services%rowtype;
begin
  if v_user_id is null then raise exception 'Debes iniciar sesión.'; end if;
  select * into v_service from public.services where id = p_service_id and coalesce(source_type, '') = 'company_service';
  if not found then raise exception 'Servicio no encontrado.'; end if;
  if not public.yt_is_company_admin(v_service.company_id, v_user_id) then raise exception 'Solo el Admin Empresa puede eliminar servicios.'; end if;
  update public.services set is_active = false, source_type = 'company_service_removed', updated_at = now() where id = p_service_id;
end;
$$;

grant execute on function public.yt_company_web_remove_service(uuid) to authenticated, service_role;


create or replace function public.yt_company_web_portal_json(
  p_search text default '',
  p_status text default 'all',
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_company_id uuid;
  v_company public.companies%rowtype;
  v_role text := 'company_staff';
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 500));
  v_search text := lower(trim(coalesce(p_search, '')));
  v_status text := lower(trim(coalesce(p_status, 'all')));
  v_current_plan_price numeric := 0;
  v_current_plan_days integer := 30;
  v_days_left integer := null;
  v_is_active boolean := false;
  v_subscription jsonb := '{}'::jsonb;
  v_dashboard jsonb := '{}'::jsonb;
  v_locations jsonb := '[]'::jsonb;
  v_members jsonb := '[]'::jsonb;
  v_bookings jsonb := '[]'::jsonb;
  v_finance jsonb := '[]'::jsonb;
  v_plan_orders jsonb := '[]'::jsonb;
  v_services jsonb := '[]'::jsonb;
begin
  if v_user_id is null then
    raise exception 'Debes iniciar sesion.';
  end if;

  select c.*
  into v_company
  from public.companies c
  where c.owner_id = v_user_id
  order by c.created_at desc nulls last
  limit 1;

  if v_company.id is not null then
    v_company_id := v_company.id;
    v_role := 'company_admin';
  else
    select
      cm.company_id,
      case
        when coalesce(cm.internal_role, cm.role, '') in ('company_admin', 'admin_empresa', 'supervisor', 'finanzas') then 'company_admin'
        else 'company_staff'
      end
    into v_company_id, v_role
    from public.company_members cm
    where cm.user_id = v_user_id
      and coalesce(cm.status, 'active') = 'active'
    order by cm.created_at desc nulls last
    limit 1;

    if v_company_id is not null then
      select c.*
      into v_company
      from public.companies c
      where c.id = v_company_id;
    end if;
  end if;

  if v_company_id is null then
    raise exception 'No encontramos una empresa asociada a este usuario.';
  end if;

  select
    coalesce(cps.price, 10.99),
    coalesce(cps.duration_days, 30)
  into v_current_plan_price, v_current_plan_days
  from public.company_plan_settings cps
  where coalesce(cps.is_active, true) = true
  order by cps.updated_at desc nulls last, cps.created_at desc nulls last
  limit 1;

  v_days_left := case
    when v_company.subscription_expires_at is null then null
    else greatest(ceil(extract(epoch from (v_company.subscription_expires_at - now())) / 86400)::integer, 0)
  end;

  v_is_active :=
    coalesce(v_company.status, 'pending') = 'active'
    and coalesce(v_company.subscription_status, 'inactive') = 'active'
    and (
      v_company.subscription_expires_at is null
      or v_company.subscription_expires_at > now()
    );

  v_subscription := jsonb_build_object(
    'company_id', v_company_id,
    'company_name', coalesce(v_company.name, 'Empresa YourTime'),
    'status', coalesce(v_company.status, 'pending'),
    'subscription_status', coalesce(v_company.subscription_status, 'inactive'),
    'subscription_price', coalesce(v_company.subscription_price, v_current_plan_price),
    'subscription_days', coalesce(v_company.subscription_days, v_current_plan_days),
    'subscription_started_at', v_company.subscription_started_at,
    'subscription_last_paid_at', v_company.subscription_last_paid_at,
    'subscription_expires_at', v_company.subscription_expires_at,
    'days_left', v_days_left,
    'is_access_active', v_is_active,
    'current_plan_price', v_current_plan_price,
    'current_plan_days', v_current_plan_days
  );

  select jsonb_build_object(
    'active_locations', 0,
    'active_members', coalesce((select count(*) from public.company_members cm where cm.company_id = v_company_id and coalesce(cm.status, 'active') = 'active'), 0),
    'inactive_members', coalesce((select count(*) from public.company_members cm where cm.company_id = v_company_id and coalesce(cm.status, '') = 'inactive'), 0),
    'invited_members', coalesce((select count(*) from public.company_members cm where cm.company_id = v_company_id and coalesce(cm.status, '') = 'invited'), 0),
    'active_services', coalesce((select count(*) from public.services s where s.company_id = v_company_id and coalesce(s.source_type, '') = 'company_service' and coalesce(s.is_active, true)), 0),
    'inactive_services', coalesce((select count(*) from public.services s where s.company_id = v_company_id and coalesce(s.source_type, '') = 'company_service' and not coalesce(s.is_active, true)), 0),
    'pending_requests', coalesce((select count(*) from public.bookings b left join public.services s on s.id = b.service_id where coalesce(b.company_id, s.company_id) = v_company_id and coalesce(b.company_request_status, 'none') in ('pending_admin', 'draft')), 0),
    'active_bookings', coalesce((select count(*) from public.bookings b left join public.services s on s.id = b.service_id where coalesce(b.company_id, s.company_id) = v_company_id and b.status in ('pending','pending_payment','paid_pending_acceptance','accepted','completed_pending_release')), 0),
    'paid_bookings', coalesce((select count(*) from public.bookings b left join public.services s on s.id = b.service_id where coalesce(b.company_id, s.company_id) = v_company_id and b.payment_status = 'paid'), 0),
    'completed_bookings', coalesce((select count(*) from public.bookings b left join public.services s on s.id = b.service_id where coalesce(b.company_id, s.company_id) = v_company_id and b.status in ('completed','completed_pending_release')), 0),
    'total_spent', coalesce((select sum(coalesce(b.total_amount, b.price_snapshot, 0)) from public.bookings b left join public.services s on s.id = b.service_id where coalesce(b.company_id, s.company_id) = v_company_id and b.payment_status = 'paid'), 0),
    'total_charged', coalesce((select sum(coalesce(b.total_amount, b.price_snapshot, 0)) from public.bookings b left join public.services s on s.id = b.service_id where coalesce(b.company_id, s.company_id) = v_company_id and b.payment_status = 'paid'), 0),
    'wissa_commission', coalesce((select sum(coalesce(b.platform_fee, 0)) from public.bookings b left join public.services s on s.id = b.service_id where coalesce(b.company_id, s.company_id) = v_company_id and b.payment_status = 'paid'), 0),
    'company_net', coalesce((select sum(greatest(coalesce(b.total_amount, b.price_snapshot, 0) - coalesce(b.platform_fee, 0), 0)) from public.bookings b left join public.services s on s.id = b.service_id where coalesce(b.company_id, s.company_id) = v_company_id and b.payment_status = 'paid'), 0),
    'company_paid_out', coalesce((select sum(coalesce(cp.amount, 0)) from public.company_payouts cp where cp.company_id = v_company_id and cp.status = 'paid'), 0),
    'company_pending_payout', greatest(
      coalesce((select sum(greatest(coalesce(b.total_amount, b.price_snapshot, 0) - coalesce(b.platform_fee, 0), 0)) from public.bookings b left join public.services s on s.id = b.service_id where coalesce(b.company_id, s.company_id) = v_company_id and b.payment_status = 'paid' and coalesce(b.payout_release_status, 'not_released') <> 'released'), 0),
      0
    ),
    'plan_payments', coalesce((select sum(coalesce(cpo.amount, 0)) from public.company_plan_orders cpo where cpo.company_id = v_company_id and cpo.status in ('approved','paid')), 0)
  )
  into v_dashboard;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
  into v_locations
  from (
    select
      cl.id,
      cl.name,
      cl.address,
      cl.city,
      cl.phone,
      coalesce(cl.manager_name, cl.contact_name) as manager_name,
      cl.contact_name,
      cl.contact_phone,
      cl.notes,
      coalesce(cl.is_active, true) as is_active,
      cl.created_at
    from public.company_locations cl
    where cl.company_id = v_company_id
      and (
        v_search = ''
        or coalesce(cl.name, '') ilike '%' || p_search || '%'
        or coalesce(cl.address, '') ilike '%' || p_search || '%'
        or coalesce(cl.city, '') ilike '%' || p_search || '%'
      )
    order by coalesce(cl.is_main, false) desc, cl.created_at desc nulls last
    limit v_limit
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
  into v_members
  from (
    select
      cm.id,
      cm.user_id,
      cm.location_id,
      coalesce(cm.full_name, p.full_name, p.display_name, cm.email, 'Personal empresa') as full_name,
      coalesce(cm.email, p.email) as email,
      coalesce(cm.phone, p.phone) as phone,
      coalesce(cm.position, '') as position,
      coalesce(cm.department, '') as department,
      coalesce(cm.internal_role, cm.role, 'company_staff') as internal_role,
      coalesce(cm.status, 'active') as status,
      cm.created_at
    from public.company_members cm
    left join public.profiles p on p.id = cm.user_id
    where cm.company_id = v_company_id
      and (v_status = 'all' or lower(coalesce(cm.status, 'active')) = v_status or lower(coalesce(cm.internal_role, cm.role, 'company_staff')) = v_status)
      and (
        v_search = ''
        or coalesce(cm.full_name, p.full_name, p.display_name, '') ilike '%' || p_search || '%'
        or coalesce(cm.email, p.email, '') ilike '%' || p_search || '%'
        or coalesce(cm.department, '') ilike '%' || p_search || '%'
      )
    order by cm.created_at desc nulls last
    limit v_limit
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
  into v_bookings
  from (
    select
      b.id,
      coalesce(b.service_title, s.title, 'Servicio') as service_title,
      coalesce(provider.full_name, provider.display_name, 'Proveedor') as provider_name,
      coalesce(requester.full_name, requester.display_name, 'Solicitante') as requested_by_name,
      coalesce(cl.name, b.location, 'Sede') as location_name,
      b.booking_date,
      b.booking_time,
      b.status,
      b.payment_status,
      coalesce(b.company_request_status, 'none') as company_request_status,
      coalesce(b.company_approval_status, 'not_required') as company_approval_status,
      coalesce(b.total_amount, b.price_snapshot, 0) as total_amount,
      b.created_at
    from public.bookings b
    left join public.services s on s.id = b.service_id
    left join public.profiles provider on provider.id = b.provider_id
    left join public.profiles requester on requester.id = b.company_requested_by
    left join public.company_locations cl on cl.id = b.company_location_id
    where coalesce(b.company_id, s.company_id) = v_company_id
      and (v_status = 'all' or lower(b.status) = v_status or lower(b.payment_status) = v_status or lower(coalesce(b.company_request_status, 'none')) = v_status)
      and (
        v_search = ''
        or coalesce(b.service_title, s.title, '') ilike '%' || p_search || '%'
        or coalesce(provider.full_name, provider.display_name, '') ilike '%' || p_search || '%'
        or coalesce(requester.full_name, requester.display_name, '') ilike '%' || p_search || '%'
        or coalesce(cl.name, b.location, '') ilike '%' || p_search || '%'
        or b.id::text ilike '%' || p_search || '%'
      )
    order by b.created_at desc nulls last
    limit v_limit
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
  into v_finance
  from (
    select
      po.id,
      'booking_payment'::text as source,
      coalesce(b.service_title, s.title, 'Reserva') as concept,
      coalesce(po.status, 'pending') as status,
      coalesce(po.provider, po.method, po.payment_method, 'manual') as method,
      coalesce(po.amount_total, po.amount, b.total_amount, 0) as amount,
      coalesce(po.currency, 'USD') as currency,
      coalesce(po.paid_at, po.approved_at, po.created_at) as created_at
    from public.payment_orders po
    left join public.bookings b on b.id = po.booking_id
    left join public.services s on s.id = b.service_id
    where coalesce(b.company_id, s.company_id) = v_company_id
      and (v_status = 'all' or lower(coalesce(po.status, 'pending')) = v_status)
      and (
        v_search = ''
        or coalesce(b.service_title, s.title, '') ilike '%' || p_search || '%'
        or coalesce(po.provider, po.method, po.payment_method, '') ilike '%' || p_search || '%'
        or po.id::text ilike '%' || p_search || '%'
      )

    union all

    select
      cpo.id,
      'company_plan'::text as source,
      'Plan empresarial'::text as concept,
      coalesce(cpo.status, 'pending') as status,
      coalesce(cpo.provider, cpo.payment_method, 'manual') as method,
      coalesce(cpo.amount, 0) as amount,
      coalesce(cpo.currency, 'USD') as currency,
      coalesce(cpo.paid_at, cpo.created_at) as created_at
    from public.company_plan_orders cpo
    where cpo.company_id = v_company_id
      and (v_status = 'all' or lower(coalesce(cpo.status, 'pending')) = v_status)
      and (
        v_search = ''
        or coalesce(cpo.provider, cpo.payment_method, '') ilike '%' || p_search || '%'
        or cpo.id::text ilike '%' || p_search || '%'
      )
    order by created_at desc nulls last
    limit v_limit
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
  into v_plan_orders
  from (
    select
      cpo.id,
      cpo.provider,
      cpo.payment_method,
      cpo.amount,
      cpo.currency,
      cpo.duration_days,
      cpo.status,
      cpo.checkout_url,
      cpo.paid_at,
      cpo.created_at
    from public.company_plan_orders cpo
    where cpo.company_id = v_company_id
    order by cpo.created_at desc nulls last
    limit 12
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
  into v_services
  from (
    select
      s.id,
      coalesce(s.company_id, cm.company_id) as company_id,
      coalesce(s.company_member_id, cm.id) as company_member_id,
      s.provider_id,
      coalesce(cm.full_name, p.full_name, p.display_name, p.email, 'Personal empresa') as staff_name,
      coalesce(cm.email, p.email) as staff_email,
      s.title,
      s.description,
      s.category,
      coalesce(s.price, 0) as price,
      coalesce(s.duration_minutes, 60) as duration_minutes,
      coalesce(s.is_active, true) as is_active,
      s.created_at
    from public.services s
    left join public.company_members cm on (
      cm.id = s.company_member_id
      or (s.company_member_id is null and cm.user_id = s.provider_id and cm.company_id = v_company_id)
    )
    left join public.profiles p on p.id = s.provider_id
    where coalesce(s.company_id, cm.company_id) = v_company_id
      and (v_status = 'all' or lower(case when coalesce(s.is_active, true) then 'active' else 'inactive' end) = v_status)
      and (
        v_search = ''
        or coalesce(s.title, '') ilike '%' || p_search || '%'
        or coalesce(s.category, '') ilike '%' || p_search || '%'
        or coalesce(s.description, '') ilike '%' || p_search || '%'
        or coalesce(cm.full_name, p.full_name, p.display_name, cm.email, p.email, '') ilike '%' || p_search || '%'
      )
    order by s.created_at desc nulls last
    limit v_limit
  ) x;


  return jsonb_build_object(
    'ok', true,
    'role', v_role,
    'is_company_admin', v_role = 'company_admin',
    'company', jsonb_build_object(
      'id', v_company.id,
      'name', coalesce(v_company.name, 'Empresa YourTime'),
      'legal_name', v_company.legal_name,
      'email', v_company.email,
      'phone', v_company.phone,
      'status', v_company.status,
      'logo_url', v_company.logo_url,
      'city', v_company.city,
      'country', v_company.country,
      'subscription_status', v_company.subscription_status,
      'subscription_expires_at', v_company.subscription_expires_at
    ),
    'subscription', v_subscription,
    'dashboard', v_dashboard,
    'locations', v_locations,
    'members', v_members,
    'bookings', v_bookings,
    'finance', v_finance,
    'plan_orders', v_plan_orders,
    'services', v_services
  );
end;
$$;



grant execute on function public.yt_company_web_portal_json(text, text, integer) to authenticated, service_role;
revoke execute on function public.yt_company_web_portal_json(text, text, integer) from public, anon;
