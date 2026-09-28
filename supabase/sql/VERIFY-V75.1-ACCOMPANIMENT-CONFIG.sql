select key, value->>'hourly_rate' as hourly_rate, value->>'minimum_hours' as minimum_hours,
       value->>'maximum_hours' as maximum_hours, value->>'detail_max_length' as detail_max_length,
       jsonb_array_length(coalesce(value->'activities','[]'::jsonb)) as activities
from public.app_settings
where key='accompaniment_pricing';

select public.yt_public_accompaniment_config_v751();
