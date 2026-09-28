-- ============================================================================
-- WISSA V62.2 - RESET DATA (CONSERVA USUARIOS Y CONFIGURACION)
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
select pg_advisory_xact_lock(hashtext('wissa_v62_2_reset_keep_users'));

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
  raise notice 'WISSA V62.2 RESET: auth.users=% profiles=%',v_auth,v_profiles;
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
      raise notice 'WISSA V62.2 RESET: limpiada public.%',t;
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
  raise notice 'RESET V62.2 OK: auth.users=% public.profiles=%',v_auth_after,v_profiles_after;
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
