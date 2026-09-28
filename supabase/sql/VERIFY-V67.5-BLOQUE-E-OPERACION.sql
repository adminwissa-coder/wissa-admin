-- WISSA V67.5 · Verificación Bloque E
select 'accompaniment_category' as check_name, count(*) as rows_found
from public.service_categories
where lower(name) in ('acompañamiento','acompanamiento') and is_active=true;

select 'preselect_rpc' as check_name, count(*) as rows_found
from pg_proc
where proname='yt_v671_preselect_accompaniment_candidate';

select 'finalize_rpc' as check_name, count(*) as rows_found
from pg_proc
where proname='yt_v675_finalize_accompaniment_selection';

select 'accompaniment_pricing' as check_name,
       value->>'hourly_rate' as hourly_rate,
       value->>'minimum_hours' as minimum_hours,
       value->>'platform_commission_rate' as platform_commission_rate
from public.app_settings
where key='accompaniment_pricing';

select 'plumbing_hidden' as check_name, count(*) as active_rows
from public.service_categories
where lower(coalesce(name,'')) like '%plomer%' and is_active=true;
