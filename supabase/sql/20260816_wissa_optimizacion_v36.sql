-- ============================================================================
-- WISSA v36 - OPTIMIZACION DE RENDIMIENTO / CACHE / MARKETPLACE / ADMIN
-- Fecha: 2026-08-16
--
-- MIGRACION INCREMENTAL para la base actual de Wissa.
-- No elimina datos, no cambia estados de reservas/pagos y no reemplaza los RPC
-- administrativos existentes. Puede ejecutarse sobre la base actual.
-- ============================================================================

-- --------------------------------------------------------------------------
-- 1. INDICES PARA LOS FLUJOS MAS CONSULTADOS EN MOBILE / ADMIN
-- --------------------------------------------------------------------------

create index if not exists idx_reviews_reviewed_id_created_at
  on public.reviews (reviewed_id, created_at desc);

create index if not exists idx_services_active_created_at
  on public.services (is_active, created_at desc);

create index if not exists idx_services_provider_active
  on public.services (provider_id, is_active);

create index if not exists idx_services_category_active
  on public.services (category, is_active);

create index if not exists idx_bookings_provider_status_date
  on public.bookings (provider_id, status, booking_date, booking_time);

create index if not exists idx_bookings_buyer_status_date
  on public.bookings (buyer_id, status, booking_date, booking_time);

create index if not exists idx_bookings_payment_status
  on public.bookings (payment_status, status, created_at desc);

create index if not exists idx_chat_rooms_provider_open
  on public.chat_rooms (provider_id, is_closed, last_message_at desc);

create index if not exists idx_chat_rooms_buyer_open
  on public.chat_rooms (buyer_id, is_closed, last_message_at desc);

create index if not exists idx_notifications_user_read_created
  on public.notifications (user_id, is_read, created_at desc);

create index if not exists idx_service_categories_active_sort
  on public.service_categories (is_active, sort_order);

create index if not exists idx_profiles_marketplace_visibility
  on public.profiles (provider_status, status, is_suspended, is_available)
  where coalesce(is_admin, false) = false;

create index if not exists idx_company_members_company_status_user
  on public.company_members (company_id, status, user_id);

create index if not exists idx_companies_status_subscription_created
  on public.companies (status, subscription_status, created_at desc);

create index if not exists idx_booking_admin_cases_status_created
  on public.booking_admin_cases (status, created_at desc);

create index if not exists idx_push_notification_logs_status_created
  on public.push_notification_logs (status, created_at desc);

-- --------------------------------------------------------------------------
-- 2. RESEÑAS AGREGADAS
-- Home/Explorar llaman a este RPC para obtener promedio + cantidad por proveedor
-- sin descargar miles de filas de public.reviews al dispositivo.
-- --------------------------------------------------------------------------

create or replace function public.yt_provider_review_stats(p_provider_ids uuid[])
returns table (
  reviewed_id uuid,
  rating_avg numeric,
  reviews_count bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    r.reviewed_id,
    round(avg(r.rating)::numeric, 2) as rating_avg,
    count(*)::bigint as reviews_count
  from public.reviews r
  where r.reviewed_id = any(coalesce(p_provider_ids, '{}'::uuid[]))
  group by r.reviewed_id;
$$;

revoke execute on function public.yt_provider_review_stats(uuid[]) from public;
grant execute on function public.yt_provider_review_stats(uuid[]) to anon, authenticated, service_role;

-- --------------------------------------------------------------------------
-- 3. REFRESCAR METADATOS POSTGREST
-- --------------------------------------------------------------------------

notify pgrst, 'reload schema';
