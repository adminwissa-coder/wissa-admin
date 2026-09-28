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
