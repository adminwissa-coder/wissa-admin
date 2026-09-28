-- WISSA V67.6 · verificación manual
-- Solo lectura.

select p.proname as function_name
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='yt_v671_accompaniment_notification_copy';

select tgname as trigger_name, tgenabled
from pg_trigger
where tgrelid='public.notifications'::regclass
  and tgname='trg_zy_accompaniment_notification_copy'
  and not tgisinternal;

select type,title,body,delivery_status,created_at
from public.notifications
where coalesce(metadata->>'category','')='Acompañamiento'
order by created_at desc
limit 30;

select type,status,transport,created_at,error_message
from public.push_notification_logs
where booking_id in (
  select b.id
  from public.bookings b
  left join public.services s on s.id=b.service_id
  where lower(translate(coalesce(nullif(b.service_details->>'category',''),s.category,''),'ÁÉÍÓÚÜÑáéíóúüñ','AEIOUUNaeiouun')) like '%acompanamiento%'
)
order by created_at desc
limit 30;
