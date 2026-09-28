-- ============================================================================
-- WISSA V64.2 - PROVIDER READY HOTFIX
-- Fecha: 2026-09-15
-- Objetivos:
-- 1) Permitir crear una reserva V64 híbrida sin provider_id antes del pago/selección.
-- 2) Sincronizar ubicación de trabajo cuando ya existe en perfil o servicio.
-- 3) Evitar que el Marketplace ofrezca profesionales que no estén realmente listos.
-- 4) Validar en servidor que toda invitación vaya a un profesional elegible.
-- ============================================================================

begin;
select pg_advisory_xact_lock(hashtext('wissa_v64_2_provider_ready_hotfix'));

-- --------------------------------------------------------------------------
-- A. CORRECCIÓN CRÍTICA: una reserva híbrida nace SIN profesional asignado.
-- El trigger legado V25 interpretaba provider_id=NULL como proveedor inválido.
-- --------------------------------------------------------------------------
create or replace function public.yt_guard_new_booking_provider_v25()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_verified boolean;
  v_status text;
  v_suspended boolean;
begin
  -- Reservas empresariales conservan su flujo propio.
  if coalesce(new.is_company_booking,false) then
    return new;
  end if;

  -- V64: primero se crea/paga una única reserva y después se seleccionan candidatos.
  if new.provider_id is null then
    if coalesce(new.assignment_mode,'') in ('hybrid_post_payment','team_post_payment') then
      return new;
    end if;
    raise exception 'La reserva todavía no tiene un profesional válido asignado';
  end if;

  select coalesce(is_verified,false), coalesce(provider_status,'pending'), coalesce(is_suspended,false)
    into v_verified, v_status, v_suspended
  from public.profiles
  where id = new.provider_id;

  if not coalesce(v_verified,false)
     or coalesce(v_status,'pending') <> 'approved'
     or coalesce(v_suspended,false) then
    raise exception 'Este profesional no está disponible para recibir nuevas solicitudes';
  end if;

  return new;
end;
$$;

-- --------------------------------------------------------------------------
-- B. BACKFILL SEGURO DE UBICACIÓN.
-- No inventa coordenadas en producción: usa perfil <-> último servicio activo.
-- --------------------------------------------------------------------------
with service_location as (
  select distinct on (s.provider_id)
    s.provider_id,
    s.offer_latitude,
    s.offer_longitude,
    nullif(trim(s.offer_location_address),'') as offer_location_address
  from public.services s
  where s.provider_id is not null
    and coalesce(s.is_active,true)=true
    and s.offer_latitude is not null
    and s.offer_longitude is not null
  order by s.provider_id, s.updated_at desc nulls last, s.created_at desc nulls last
)
update public.profiles p
set
  latitude = coalesce(p.latitude,p.lat,sl.offer_latitude),
  longitude = coalesce(p.longitude,p.lng,sl.offer_longitude),
  lat = coalesce(p.lat,p.latitude,sl.offer_latitude),
  lng = coalesce(p.lng,p.longitude,sl.offer_longitude),
  location_label = coalesce(nullif(trim(p.location_label),''),sl.offer_location_address,p.city,'Ubicación de trabajo'),
  updated_at = now()
from service_location sl
where p.id=sl.provider_id
  and (
    coalesce(p.latitude,p.lat) is null
    or coalesce(p.longitude,p.lng) is null
    or nullif(trim(p.location_label),'') is null
  );

-- Si el perfil sí tiene ubicación, sincronizarla al servicio cuando el servicio no la tenga.
update public.services s
set
  offer_latitude = coalesce(s.offer_latitude,p.latitude,p.lat),
  offer_longitude = coalesce(s.offer_longitude,p.longitude,p.lng),
  offer_location_address = coalesce(nullif(trim(s.offer_location_address),''),nullif(trim(p.location_label),''),p.city,'Ubicación de trabajo'),
  updated_at = now()
from public.profiles p
where p.id=s.provider_id
  and coalesce(s.is_active,true)=true
  and coalesce(p.latitude,p.lat) is not null
  and coalesce(p.longitude,p.lng) is not null
  and (
    s.offer_latitude is null
    or s.offer_longitude is null
    or nullif(trim(s.offer_location_address),'') is null
  );

-- Solo activar flags de exposición para perfiles YA aprobados y verificados.
update public.profiles p
set
  provider_enabled=true,
  show_on_map=true,
  updated_at=now()
where (
    coalesce(p.role,'')='provider'
    or coalesce(p.account_type,'')='provider'
    or coalesce(p.mode_preference,'')='provider'
    or exists(select 1 from public.services s where s.provider_id=p.id)
  )
  and coalesce(p.is_verified,false)=true
  and coalesce(p.provider_status,'')='approved'
  and coalesce(p.is_suspended,false)=false
  and coalesce(p.is_active,true)=true
  and coalesce(p.latitude,p.lat) is not null
  and coalesce(p.longitude,p.lng) is not null;

-- --------------------------------------------------------------------------
-- C. MARKETPLACE: solo mostrar opciones que pueden recibir la solicitud.
-- Mantiene exactamente la misma forma/columnas de la vista existente.
-- --------------------------------------------------------------------------
create or replace view public.v_client_marketplace_services as
select
  s.id,
  s.id as service_id,
  s.provider_id,
  s.company_id,
  s.company_member_id,
  s.source_type,
  case
    when s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null
      then 'company_service'
    else 'independent_service'
  end as marketplace_type,
  case
    when s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null
      then 'Personal empresa'
    else 'Independiente'
  end as provider_kind,
  s.title,
  s.description,
  s.category,
  s.price,
  s.duration_minutes,
  s.is_active,
  s.is_featured,
  s.featured_order,
  s.featured_until,
  coalesce(
    nullif(s.offer_location_address, ''),
    case
      when s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null then 'A domicilio'
    end,
    p.location_label,
    c.address,
    c.city,
    p.city
  ) as location_label,
  coalesce(s.offer_latitude, p.latitude, p.lat) as latitude,
  coalesce(s.offer_longitude, p.longitude, p.lng) as longitude,
  p.full_name as staff_name,
  p.avatar_url as staff_avatar_url,
  coalesce(p.rating_avg, 0) as rating_avg,
  coalesce(p.is_verified, false) as staff_verified,
  case
    when s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null
      then coalesce(cm.is_available, true)
    else coalesce(p.is_available, false)
  end as staff_available,
  p.city as staff_city,
  c.name as company_name,
  c.logo_url as company_logo_url,
  c.status as company_status,
  c.subscription_status,
  c.plan_status,
  cm.full_name as company_member_name,
  cm.email as company_member_email,
  cm.status as company_member_status,
  s.created_at,
  s.updated_at
from public.services s
left join public.profiles p on p.id = s.provider_id
left join public.companies c on c.id = s.company_id
left join public.company_members cm on cm.id = s.company_member_id
where s.is_active = true
  and coalesce(p.status, 'active') <> 'suspended'
  and coalesce(p.is_suspended, false) = false
  and coalesce(s.offer_latitude,p.latitude,p.lat) is not null
  and coalesce(s.offer_longitude,p.longitude,p.lng) is not null
  and (
    (
      coalesce(s.source_type, 'normal') <> 'company_service'
      and s.company_id is null
      and s.company_member_id is null
      and coalesce(p.provider_status, '') = 'approved'
      and coalesce(p.is_verified,false)=true
      and coalesce(p.is_available,false)=true
      and coalesce(p.provider_enabled,true)=true
    )
    or
    (
      (s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null)
      and s.provider_id is not null
      and coalesce(cm.status, 'active') = 'active'
      and coalesce(cm.is_available,true)=true
      and coalesce(c.subscription_status, c.plan_status, 'active') = 'active'
    )
  );

grant select on public.v_client_marketplace_services to anon, authenticated, service_role;

-- --------------------------------------------------------------------------
-- D. GUARD ÚNICO PARA INVITACIONES/ASIGNACIONES.
-- Evita que caché o clientes antiguos inviten a un profesional no listo.
-- --------------------------------------------------------------------------
create or replace function public.yt_v64_2_guard_assignment_provider_ready()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_company boolean:=false;
  v_ready boolean:=false;
begin
  if new.provider_id is null then
    raise exception 'La solicitud necesita un profesional válido';
  end if;

  select coalesce(b.is_company_booking,false)
    into v_company
  from public.bookings b
  where b.id=new.booking_id;

  if coalesce(v_company,false) then
    select exists(
      select 1
      from public.profiles p
      where p.id=new.provider_id
        and coalesce(p.is_active,true)=true
        and coalesce(p.is_suspended,false)=false
        and coalesce(p.latitude,p.lat) is not null
        and coalesce(p.longitude,p.lng) is not null
    ) into v_ready;
  else
    select exists(
      select 1
      from public.profiles p
      where p.id=new.provider_id
        and coalesce(p.is_active,true)=true
        and coalesce(p.is_suspended,false)=false
        and coalesce(p.is_verified,false)=true
        and coalesce(p.provider_status,'')='approved'
        and coalesce(p.provider_enabled,true)=true
        and coalesce(p.is_available,false)=true
        and coalesce(p.latitude,p.lat) is not null
        and coalesce(p.longitude,p.lng) is not null
        and exists(
          select 1 from public.services s
          where s.provider_id=p.id and coalesce(s.is_active,true)=true
        )
    ) into v_ready;
  end if;

  if not coalesce(v_ready,false) then
    raise exception 'Este profesional ya no está disponible. Wissa buscará otra opción.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_v64_2_assignment_provider_ready_insert on public.booking_professional_assignments;
drop trigger if exists trg_v64_2_assignment_provider_ready_update on public.booking_professional_assignments;

create trigger trg_v64_2_assignment_provider_ready_insert
before insert on public.booking_professional_assignments
for each row
when (new.status in ('pending','accepted'))
execute function public.yt_v64_2_guard_assignment_provider_ready();

create trigger trg_v64_2_assignment_provider_ready_update
before update of provider_id,status on public.booking_professional_assignments
for each row
when (new.status in ('pending','accepted'))
execute function public.yt_v64_2_guard_assignment_provider_ready();

commit;

-- Diagnóstico: todo lo que aparece aquí requiere completar ubicación/estado antes de entrar al Marketplace.
select
  p.id,
  p.full_name,
  p.email,
  p.provider_status,
  p.is_verified,
  p.is_available,
  coalesce(p.latitude,p.lat) as latitude,
  coalesce(p.longitude,p.lng) as longitude,
  p.location_label
from public.profiles p
where (
    coalesce(p.role,'')='provider'
    or coalesce(p.account_type,'')='provider'
    or coalesce(p.mode_preference,'')='provider'
    or exists(select 1 from public.services s where s.provider_id=p.id)
  )
  and (
    coalesce(p.provider_status,'')<>'approved'
    or coalesce(p.is_verified,false)=false
    or coalesce(p.is_available,false)=false
    or coalesce(p.latitude,p.lat) is null
    or coalesce(p.longitude,p.lng) is null
  )
order by p.full_name nulls last, p.email nulls last;
