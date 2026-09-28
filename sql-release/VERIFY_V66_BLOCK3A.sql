-- WISSA V66.3 - verificación Bloque 3A Realtime

with expected(tablename) as (
  values
    ('bookings'),
    ('booking_professional_assignments'),
    ('payment_orders'),
    ('provider_payouts'),
    ('booking_tips'),
    ('booking_tip_allocations'),
    ('withdrawal_requests'),
    ('payout_requests'),
    ('platform_commission_withdrawals'),
    ('booking_refunds'),
    ('company_payments'),
    ('company_payouts'),
    ('company_plan_orders'),
    ('company_booking_approvals'),
    ('services'),
    ('profiles'),
    ('availability')
)
select
  e.tablename,
  case
    when to_regclass(format('public.%I', e.tablename)) is null then 'TABLE_NOT_PRESENT'
    when p.tablename is not null then 'REALTIME_OK'
    else 'NOT_IN_REALTIME'
  end as realtime_status
from expected e
left join pg_publication_tables p
  on p.pubname = 'supabase_realtime'
 and p.schemaname = 'public'
 and p.tablename = e.tablename
order by e.tablename;

select key, value, updated_at
from public.app_settings
where key = 'wissa_release_realtime';
