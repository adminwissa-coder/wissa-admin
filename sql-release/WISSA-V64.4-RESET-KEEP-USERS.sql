-- ============================================================================
-- WISSA V64.3 - RESET DATA + PROVIDERS READY (CONSERVA USUARIOS Y CONFIGURACION)
-- Fecha: 2026-09-14
-- Objetivo: limpiar datos operativos de pruebas sin borrar auth.users,
-- public.profiles, servicios, catalogos, precios, reglas de equipo ni empresas.
--
-- CONSERVA:
--   auth.users, public.profiles
--   services, service_categories, service_category_fields, booking_catalog
--   app_settings, service_team_rules, banners
--   companies, company_members, company_locations
--   availability/provider_availability_*, provider_payout_methods
--   configuracion Yappy/PagueloFacil y demas configuracion persistente
--
-- LIMPIA:
--   reservas, asignaciones de equipo, pagos de reserva, chat, notificaciones,
--   devoluciones, reseñas, liquidaciones, retiros, fidelidad, bonos/redenciones,
--   cotizaciones de traslado, facturas/finanzas operativas de empresa.
--
-- IMPORTANTE: usar SOLO en ambiente de desarrollo/pruebas.
-- ============================================================================

begin;
select pg_advisory_xact_lock(hashtext('wissa_v64_3_reset_keep_users'));

-- Guard de seguridad: los usuarios y perfiles deben quedar exactamente iguales.
do $$
declare
  v_auth bigint;
  v_profiles bigint;
begin
  select count(*) into v_auth from auth.users;
  select count(*) into v_profiles from public.profiles;
  create temp table if not exists _wissa_v62_reset_guard(
    auth_before bigint,
    profiles_before bigint
  ) on commit drop;
  truncate table _wissa_v62_reset_guard;
  insert into _wissa_v62_reset_guard values(v_auth,v_profiles);
  raise notice 'WISSA V64.3 RESET: auth.users=% profiles=%',v_auth,v_profiles;
end $$;

-- La reserva es el padre principal; CASCADE limpia hijos FK cuando aplica.
truncate table public.bookings restart identity cascade;

-- Tablas operativas que pueden conservar filas no enlazadas a una reserva.
do $$
declare
  t text;
  v_tables text[] := array[
    'booking_professional_assignments',
    'payment_events',
    'payment_orders',
    'chat_messages',
    'chat_rooms',
    'booking_refunds',
    'booking_admin_cases',
    'reviews',
    'reports',
    'notifications',
    'internal_notifications',
    'push_notification_logs',
    'payout_requests',
    'provider_payouts',
    'company_payouts',
    'withdrawal_requests',
    'platform_commission_withdrawals',
    'promotion_redemptions',
    'customer_bonuses',
    'provider_completion_bonuses',
    'loyalty_rewards',
    'travel_quotes',
    'account_deletion_requests',
    'company_booking_approvals',
    'company_financial_history',
    'company_payments',
    'company_invoice_items',
    'company_invoices',
    'company_notifications',
    'company_subscription_events',
    'company_bookings',
    'company_plan_orders',
    'plan_orders'
  ];
begin
  foreach t in array v_tables loop
    if to_regclass(format('public.%I',t)) is not null then
      execute format('truncate table public.%I restart identity cascade',t);
      raise notice 'WISSA V64.3 RESET: limpiada public.%',t;
    end if;
  end loop;
end $$;

-- Acumulados financieros: se ponen en cero sin borrar las cuentas.
do $$
begin
  if to_regclass('public.provider_balances') is not null then
    update public.provider_balances
       set available_balance=0,
           pending_balance=0,
           paid_balance=0,
           updated_at=now();
  end if;
end $$;

do $$
begin
  if to_regclass('public.companies') is not null then
    update public.companies
       set current_balance=0,
           credit_used=0,
           updated_at=now()
     where coalesce(current_balance,0)<>0
        or coalesce(credit_used,0)<>0;
  end if;
end $$;

-- Métricas derivadas de operaciones/reseñas.
update public.profiles
   set rating_avg=0,
       response_time_avg=0,
       updated_at=now()
 where coalesce(rating_avg,0)<>0
    or coalesce(response_time_avg,0)<>0;

-- NO se toca service_team_rules ni app_settings.
-- NO se toca la suscripcion empresarial.

-- --------------------------------------------------------------------------
-- ENTORNO DE PRUEBA - todos los perfiles Ofrecer existentes quedan
-- listos para probar reservas: ubicación, verificación, disponibilidad,
-- servicio activo y agenda. No usar esta sección para aprobar usuarios reales
-- sin validación previa en producción.
-- --------------------------------------------------------------------------
with provider_seed as (
  select
    p.id,
    ((hashtext(coalesce(p.email,p.id::text))::bigint % 8 + 8) % 8)::int as slot,
    sl.offer_latitude,
    sl.offer_longitude,
    sl.offer_location_address
  from public.profiles p
  left join lateral (
    select s.offer_latitude,s.offer_longitude,s.offer_location_address
    from public.services s
    where s.provider_id=p.id and coalesce(s.is_active,true)=true
    order by s.updated_at desc nulls last,s.created_at desc nulls last
    limit 1
  ) sl on true
  where coalesce(p.role,'')='provider'
     or coalesce(p.account_type,'')='provider'
     or coalesce(p.mode_preference,'')='provider'
     or exists(select 1 from public.services s where s.provider_id=p.id)
), normalized as (
  select
    ps.*,
    coalesce(ps.offer_latitude,
      case ps.slot
        when 0 then 8.9981 when 1 then 8.9872 when 2 then 9.0040 when 3 then 8.9720
        when 4 then 9.0110 when 5 then 9.0215 when 6 then 9.0340 else 8.9838 end
    ) as fallback_lat,
    coalesce(ps.offer_longitude,
      case ps.slot
        when 0 then -79.5367 when 1 then -79.5280 when 2 then -79.5200 when 3 then -79.5320
        when 4 then -79.5470 when 5 then -79.5160 when 6 then -79.5065 else -79.5580 end
    ) as fallback_lng,
    coalesce(nullif(trim(ps.offer_location_address),''),
      case ps.slot
        when 0 then 'Betania, Panamá' when 1 then 'El Ingenio, Panamá' when 2 then 'San Francisco, Panamá'
        when 3 then 'Bella Vista, Panamá' when 4 then 'Condado del Rey, Panamá' when 5 then 'Pueblo Nuevo, Panamá'
        when 6 then 'Río Abajo, Panamá' else 'El Dorado, Panamá' end
    ) as fallback_label
  from provider_seed ps
)
update public.profiles p
set
  status='active',
  is_active=true,
  is_suspended=false,
  is_verified=true,
  provider_status='approved',
  provider_enabled=true,
  is_available=true,
  show_on_map=true,
  latitude=coalesce(p.latitude,p.lat,n.fallback_lat),
  longitude=coalesce(p.longitude,p.lng,n.fallback_lng),
  lat=coalesce(p.lat,p.latitude,n.fallback_lat),
  lng=coalesce(p.lng,p.longitude,n.fallback_lng),
  location_label=coalesce(nullif(trim(p.location_label),''),n.fallback_label),
  city=coalesce(nullif(trim(p.city),''),'Panamá'),
  account_type=coalesce(nullif(p.account_type,''),'provider'),
  mode_preference=coalesce(nullif(p.mode_preference,''),'provider'),
  updated_at=now()
from normalized n
where p.id=n.id;

-- Crear un servicio de Limpieza únicamente cuando un Ofrecer no tenga ninguno activo.
insert into public.services(
  provider_id,title,description,category,price,duration_minutes,is_active,
  offer_location_address,offer_latitude,offer_longitude,source_type,created_by,updated_at
)
select
  p.id,
  'Limpieza para tu hogar, oficinas u otros.',
  'Servicio de limpieza disponible en Wissa.',
  'Limpieza',35,60,true,
  p.location_label,coalesce(p.latitude,p.lat),coalesce(p.longitude,p.lng),
  'marketplace',p.id,now()
from public.profiles p
where (coalesce(p.role,'')='provider' or coalesce(p.account_type,'')='provider' or coalesce(p.mode_preference,'')='provider')
  and not exists(
    select 1 from public.services s
    where s.provider_id=p.id and coalesce(s.is_active,true)=true
  );

-- Sincronizar la ubicación del servicio con la ubicación de trabajo del Ofrecer.
update public.services s
set
  is_active=true,
  offer_location_address=coalesce(nullif(trim(s.offer_location_address),''),p.location_label),
  offer_latitude=coalesce(s.offer_latitude,p.latitude,p.lat),
  offer_longitude=coalesce(s.offer_longitude,p.longitude,p.lng),
  source_type=coalesce(nullif(s.source_type,''),'marketplace'),
  updated_at=now()
from public.profiles p
where p.id=s.provider_id
  and (coalesce(p.role,'')='provider' or coalesce(p.account_type,'')='provider' or coalesce(p.mode_preference,'')='provider');

-- Agenda uniforme para pruebas: lunes-sábado 08:00-18:00, domingo inactivo.
delete from public.availability a
using public.profiles p
where a.provider_id=p.id
  and (coalesce(p.role,'')='provider' or coalesce(p.account_type,'')='provider' or coalesce(p.mode_preference,'')='provider');

insert into public.availability(provider_id,day_of_week,start_time,end_time,is_active)
select p.id,d,
       case when d=0 then '00:00' else '08:00' end,
       case when d=0 then '00:00' else '18:00' end,
       (d<>0)
from public.profiles p
cross join generate_series(0,6) d
where coalesce(p.role,'')='provider'
   or coalesce(p.account_type,'')='provider'
   or coalesce(p.mode_preference,'')='provider';

insert into public.provider_availability_settings(
  provider_id,slot_minutes,default_duration_minutes,buffer_minutes,
  booking_window_days,allow_recurring,external_calendar_enabled,updated_at
)
select p.id,60,60,0,60,false,false,now()
from public.profiles p
where coalesce(p.role,'')='provider'
   or coalesce(p.account_type,'')='provider'
   or coalesce(p.mode_preference,'')='provider'
on conflict(provider_id) do update set
  slot_minutes=excluded.slot_minutes,
  default_duration_minutes=excluded.default_duration_minutes,
  buffer_minutes=excluded.buffer_minutes,
  booking_window_days=excluded.booking_window_days,
  allow_recurring=excluded.allow_recurring,
  external_calendar_enabled=excluded.external_calendar_enabled,
  updated_at=now();

-- Verificacion final de protección de usuarios.
do $$
declare
  v_auth_before bigint;
  v_profiles_before bigint;
  v_auth_after bigint;
  v_profiles_after bigint;
begin
  select auth_before,profiles_before
    into v_auth_before,v_profiles_before
    from _wissa_v62_reset_guard limit 1;
  select count(*) into v_auth_after from auth.users;
  select count(*) into v_profiles_after from public.profiles;

  if v_auth_after<>v_auth_before then
    raise exception 'RESET ABORTADO: auth.users cambio de % a %',v_auth_before,v_auth_after;
  end if;
  if v_profiles_after<>v_profiles_before then
    raise exception 'RESET ABORTADO: public.profiles cambio de % a %',v_profiles_before,v_profiles_after;
  end if;
  raise notice 'RESET V64.3 OK: auth.users=% public.profiles=%',v_auth_after,v_profiles_after;
end $$;

commit;

-- Resumen post-reset. Las tablas operativas deben quedar en 0.
select
  (select count(*) from auth.users) as usuarios_auth,
  (select count(*) from public.profiles) as perfiles,
  (select count(*) from public.bookings) as reservas,
  case when to_regclass('public.booking_professional_assignments') is null then 0 else (select count(*) from public.booking_professional_assignments) end as asignaciones,
  case when to_regclass('public.payment_orders') is null then 0 else (select count(*) from public.payment_orders) end as ordenes_pago,
  case when to_regclass('public.provider_payouts') is null then 0 else (select count(*) from public.provider_payouts) end as liquidaciones,
  case when to_regclass('public.loyalty_rewards') is null then 0 else (select count(*) from public.loyalty_rewards) end as fidelidad;


-- V64.4: después del reset conservar el esquema/API sincronizados.
notify pgrst, 'reload schema';
select pg_notify('pgrst','reload schema');

select 'WISSA V64.4 RESET COMPLETADO - USUARIOS CONSERVADOS' as resultado;
