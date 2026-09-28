-- WISSA V66.2 · VERIFICACIÓN BLOQUE 2B
-- Ejecutar DESPUÉS de WISSA-V66.2-BLOCK2B-FINANZAS-COMISIONES-APPLY.sql

select key, value
from public.app_settings
where key = 'release_v66_block2b';

select table_name
from information_schema.views
where table_schema='public'
  and table_name in (
    'v_provider_earnings',
    'v_provider_earnings_summary',
    'v_provider_payouts',
    'v_provider_tips'
  )
order by table_name;

select p.proname,
       pg_get_function_identity_arguments(p.oid) as arguments
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in (
    'yt_v66_request_provider_withdrawal',
    'wissa_finance_summary_v66',
    'yt_admin_wissa_finance_v66_json',
    'yt_admin_bookings_v66_json',
    'yt_admin_booking_distribution_v66',
    'yt_admin_wissa_marketplace_revenue_v66_json',
    'yt_admin_withdrawals_v66_json'
  )
order by p.proname;

-- Debe seguir existiendo la policy directa del Bloque 2A, sin recursión.
select policyname, cmd, qual
from pg_policies
where schemaname='public'
  and tablename='booking_tip_allocations';

-- Estado general de datos financieros, sin modificar nada.
select
  (select count(*) from public.bookings where payment_status='paid') as paid_bookings,
  (select count(*) from public.booking_professional_assignments where status in ('accepted','completed')) as active_team_assignments,
  (select count(*) from public.provider_payouts) as provider_payouts,
  (select count(*) from public.payout_requests) as payout_requests,
  (select count(*) from public.booking_tip_allocations) as tip_allocations;
