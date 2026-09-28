-- WISSA V66.4 / BLOQUE 3B - verificación segura (solo lectura)

select 'user_push_tokens' as check_name,
       to_regclass('public.user_push_tokens') is not null as ok;

select 'notifications_columns' as check_name,
       count(*) = 5 as ok,
       array_agg(column_name order by column_name) as columns
from information_schema.columns
where table_schema='public' and table_name='notifications'
  and column_name in ('notification_key','delivery_status','push_attempted_at','push_sent_at','push_last_error');

select 'core_functions' as check_name,
       count(*) >= 5 as ok,
       array_agg(proname order by proname) as functions
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and proname in (
    'yt_notification_key_v664',
    'yt_notification_upsert_v664',
    'wissa_notification_guard_v664',
    'yt_notify_assignment_flow_v664',
    'yt_notify_booking_participants_v664',
    'yt_notify_tip_allocation_v664'
  );

select 'core_triggers' as check_name,
       count(*) >= 4 as ok,
       array_agg(tgname order by tgname) as triggers
from pg_trigger
where not tgisinternal
  and tgname in (
    'trg_zz_wissa_notification_guard_v664',
    'trg_notification_push_v664',
    'trg_notify_assignment_flow_v664',
    'trg_notify_booking_participants_v664',
    'trg_notify_tip_allocation_v664'
  );

select 'push_token_rls' as check_name,
       relrowsecurity as ok
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname='user_push_tokens';

-- Las dos rutas históricas de pago deben converger en la misma clave.
select 'payment_dedupe_family' as check_name,
       public.yt_notification_key_v664(
         '11111111-1111-1111-1111-111111111111'::uuid,
         'payment_approved','A','B','{}'::jsonb,null
       ) = public.yt_notification_key_v664(
         '11111111-1111-1111-1111-111111111111'::uuid,
         'booking_paid','A','B','{}'::jsonb,null
       ) as ok;

-- La RPC histórica y el trigger nuevo de invitación deben converger por ronda.
select 'booking_request_round_dedupe' as check_name,
       public.yt_notification_key_v664(
         '11111111-1111-1111-1111-111111111111'::uuid,
         'booking_request','A','B','{"round":"3"}'::jsonb,null
       ) = public.yt_notification_key_v664(
         '11111111-1111-1111-1111-111111111111'::uuid,
         'booking_request','A','B','{"round":"3","assignment_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'::jsonb,null
       ) as ok;

-- La misma aceptación descrita por dos caminos debe converger por contador accepted.
select 'booking_accept_dedupe' as check_name,
       public.yt_notification_key_v664(
         '11111111-1111-1111-1111-111111111111'::uuid,
         'booking_accepted','A','B','{"accepted":"1","required":"2"}'::jsonb,null
       ) = public.yt_notification_key_v664(
         '11111111-1111-1111-1111-111111111111'::uuid,
         'booking_accepted','A','B','{"accepted":"1","required":"2","assignment_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'::jsonb,null
       ) as ok;

select key, value
from public.app_settings
where key='wissa_v66_block3b_notifications';
