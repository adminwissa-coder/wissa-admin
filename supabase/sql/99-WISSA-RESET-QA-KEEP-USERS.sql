-- ============================================================================
-- WISSA - RESET QA / FLUJO COMPLETO (CONSERVA USUARIOS Y CONFIGURACION)
-- Fecha: 2026-09-11
-- Objetivo:
--   Dejar el ambiente de PRUEBAS sin reservas, cobros, devoluciones, chats,
--   notificaciones, bonos, liquidaciones ni historiales financieros, pero
--   CONSERVANDO auth.users, public.profiles y la configuracion/catalago.
--
-- CONSERVA, entre otros:
--   auth.users, public.profiles (cuentas), services, service_categories,
--   service_category_fields, booking_catalog, app_settings, banners,
--   companies, company_members, company_locations, availability,
--   provider_availability_*, provider_payout_methods, fotos/documentos,
--   promotion_campaigns (definiciones), configuracion de precios.
--
-- BORRA/RESETEA:
--   bookings y flujo de reserva, pagos PF/Yappy, eventos de pago, chats,
--   notificaciones, reviews/reportes, devoluciones, casos admin, bonos,
--   redenciones, payouts/retiros, finanzas empresa, facturas de prueba,
--   ordenes de plan, cotizaciones de traslado y balances acumulados.
--
-- IMPORTANTE:
--   1) Ejecutar SOLO en ambiente de PRUEBAS / copia de BD.
--   2) Este script NO borra auth.users ni public.profiles.
--   3) No elimina archivos fisicos de Supabase Storage (avatars, fotos,
--      documentos o imagenes de chat). Solo elimina referencias DB de chat.
--   4) Es idempotente: se puede volver a ejecutar.
-- ============================================================================

begin;

-- Evita que dos resets corran al mismo tiempo.
select pg_advisory_xact_lock(hashtext('wissa_qa_reset_keep_users'));

-- --------------------------------------------------------------------------
-- PROTECCION: capturamos cantidad de usuarios/perfiles antes del reset.
-- --------------------------------------------------------------------------
do $$
declare
  v_auth_users_before bigint;
  v_profiles_before bigint;
begin
  select count(*) into v_auth_users_before from auth.users;
  select count(*) into v_profiles_before from public.profiles;

  create temp table if not exists _wissa_reset_guard (
    auth_users_before bigint,
    profiles_before bigint
  ) on commit drop;

  truncate table _wissa_reset_guard;
  insert into _wissa_reset_guard values (v_auth_users_before, v_profiles_before);

  raise notice 'WISSA RESET: usuarios auth antes = %, perfiles antes = %',
    v_auth_users_before, v_profiles_before;
end $$;

-- --------------------------------------------------------------------------
-- 1. FLUJO CENTRAL DE RESERVAS Y TODOS SUS HIJOS
--    CASCADE limpia payment_orders/payment_events, chats, refunds,
--    reviews, bonus/redemptions vinculados, payouts vinculados, etc.
-- --------------------------------------------------------------------------
truncate table public.bookings restart identity cascade;

-- --------------------------------------------------------------------------
-- 2. TABLAS OPERATIVAS QUE PUEDEN EXISTIR SIN UNA RESERVA ACTUAL
--    Se ejecutan solo si existen, para tolerar pequeñas diferencias de versión.
-- --------------------------------------------------------------------------
do $$
declare
  t text;
  v_tables text[] := array[
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
    if to_regclass(format('public.%I', t)) is not null then
      execute format('truncate table public.%I restart identity cascade', t);
      raise notice 'WISSA RESET: limpiada public.%', t;
    end if;
  end loop;
end $$;

-- --------------------------------------------------------------------------
-- 3. BALANCES / ACUMULADOS: quedan en cero, sin borrar la cuenta proveedor.
-- --------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.provider_balances') is not null then
    update public.provider_balances
       set available_balance = 0,
           pending_balance   = 0,
           paid_balance      = 0,
           updated_at        = now();
  end if;
end $$;

-- Empresas se conservan, pero sin deuda/credito consumido de pruebas.
do $$
begin
  if to_regclass('public.companies') is not null then
    update public.companies
       set current_balance = 0,
           credit_used     = 0,
           updated_at      = now()
     where coalesce(current_balance, 0) <> 0
        or coalesce(credit_used, 0) <> 0;
  end if;
end $$;

-- Como se borran las reviews y el historial operativo, reseteamos metricas
-- derivadas sin borrar ni desactivar perfiles/proveedores.
update public.profiles
   set rating_avg        = 0,
       response_time_avg = 0,
       updated_at        = now()
 where coalesce(rating_avg, 0) <> 0
    or coalesce(response_time_avg, 0) <> 0;

-- --------------------------------------------------------------------------
-- 4. OPCIONAL: RESET DE SUSCRIPCION DE EMPRESA
--    NO se ejecuta por defecto para no bloquear el acceso de empresas mientras
--    pruebas reservas. Si quieres probar tambien la compra del plan desde cero,
--    descomenta este bloque.
-- --------------------------------------------------------------------------
/*
update public.companies
   set subscription_status           = 'inactive',
       subscription_started_at       = null,
       subscription_expires_at       = null,
       subscription_last_paid_at     = null,
       subscription_last_reminder_at = null,
       subscription_grace_until      = null,
       subscription_auto_blocked     = false,
       plan_expires_at                = null,
       updated_at                     = now();
*/

-- --------------------------------------------------------------------------
-- 5. VALIDACION FINAL: la cantidad de usuarios/perfiles NO puede cambiar.
-- --------------------------------------------------------------------------
do $$
declare
  v_auth_before bigint;
  v_profiles_before bigint;
  v_auth_after bigint;
  v_profiles_after bigint;
begin
  select auth_users_before, profiles_before
    into v_auth_before, v_profiles_before
    from _wissa_reset_guard
    limit 1;

  select count(*) into v_auth_after from auth.users;
  select count(*) into v_profiles_after from public.profiles;

  if v_auth_after <> v_auth_before then
    raise exception 'RESET ABORTADO: auth.users cambio de % a %', v_auth_before, v_auth_after;
  end if;

  if v_profiles_after <> v_profiles_before then
    raise exception 'RESET ABORTADO: public.profiles cambio de % a %', v_profiles_before, v_profiles_after;
  end if;

  raise notice 'RESET OK: auth.users = %, public.profiles = % (sin borrar usuarios)',
    v_auth_after, v_profiles_after;
end $$;

commit;

-- --------------------------------------------------------------------------
-- 6. COMPROBACION VISUAL POST-RESET
-- --------------------------------------------------------------------------
select
  (select count(*) from auth.users)                         as usuarios_auth,
  (select count(*) from public.profiles)                    as perfiles,
  (select count(*) from public.bookings)                    as reservas,
  (select count(*) from public.payment_orders)              as ordenes_pago,
  (select count(*) from public.notifications)               as notificaciones,
  (select count(*) from public.chat_rooms)                  as chats,
  (select count(*) from public.booking_refunds)             as devoluciones,
  (select count(*) from public.provider_payouts)            as pagos_proveedor,
  (select count(*) from public.promotion_redemptions)       as promociones_usadas,
  (select count(*) from public.customer_bonuses)            as bonos_cliente,
  (select count(*) from public.provider_completion_bonuses) as bonos_proveedor,
  (select count(*) from public.loyalty_rewards)              as fidelidad_v60;

-- Resultado esperado de las columnas operativas: 0.
-- usuarios_auth y perfiles deben mantener exactamente sus cantidades previas.
