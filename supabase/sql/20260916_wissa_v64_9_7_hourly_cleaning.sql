-- WISSA V64.9.7 - HOURLY CLEANING PRICING
-- APPLY idempotente. No borra usuarios ni reservas.
-- Limpieza interior: el metraje define horas/equipo; no existe cobro por m².

begin;

insert into public.app_settings(key,value,updated_at)
values(
  'cleaning_pricing',
  jsonb_build_object(
    'pricing_version',65,
    'pricing_revision','64.9.7-hourly-cleaning',
    'pricing_strategy','hourly_by_area',
    'currency','USD',
    'max_auto_sqm',500,
    'platform_commission_rate',0.20,
    'platform_usage_fee',2,
    'itbms_rate',0.07,
    'mobility_fee_per_booking',5,
    'mobility_fee_per_professional',5,
    'travel_rate_per_km',0,
    'fixed_service_price',48,
    'fixed_service_prices',jsonb_build_object('basica',48,'premium',48),
    'hourly_service_blocks','[
      {"key":"1_60","label":"1 a 60 m²","min_sqm":1,"max_sqm":60,"professionals":1,"hours":4,"standard_hourly_rate":12,"deep_hourly_rate":12,"active":true},
      {"key":"61_120","label":"61 a 120 m²","min_sqm":61,"max_sqm":120,"professionals":1,"hours":5,"standard_hourly_rate":12,"deep_hourly_rate":12,"active":true},
      {"key":"121_180","label":"121 a 180 m²","min_sqm":121,"max_sqm":180,"professionals":1,"hours":6,"standard_hourly_rate":12,"deep_hourly_rate":12,"active":true},
      {"key":"181_240","label":"181 a 240 m²","min_sqm":181,"max_sqm":240,"professionals":1,"hours":7,"standard_hourly_rate":12,"deep_hourly_rate":12,"active":true},
      {"key":"241_249","label":"241 a 249 m²","min_sqm":241,"max_sqm":249,"professionals":1,"hours":8,"standard_hourly_rate":12,"deep_hourly_rate":12,"active":true},
      {"key":"250_350","label":"250 a 350 m²","min_sqm":250,"max_sqm":350,"professionals":2,"hours":8,"standard_hourly_rate":12,"deep_hourly_rate":12,"active":true},
      {"key":"351_500","label":"351 a 500 m²","min_sqm":351,"max_sqm":500,"professionals":2,"hours":8,"standard_hourly_rate":15,"deep_hourly_rate":15,"active":true}
    ]'::jsonb,
    -- Compatibilidad para clientes anteriores. El motor actual NO lee estas tarifas por m².
    'parametric_engine',jsonb_build_object(
      'minimum_price',48,
      'minimum_included_sqm',60,
      'tier1_end_sqm',120,
      'tier1_rate_per_sqm',0,
      'tier2_end_sqm',249,
      'tier2_rate_per_sqm',0,
      'team_threshold_sqm',250,
      'team_base_price',192,
      'team_rate_per_sqm',0,
      'continuous_team_pricing',false,
      'quote_threshold_sqm',500,
      'deep_cleaning_rate_per_sqm',0,
      'professionals_at_team_threshold',2,
      'max_professionals',2
    ),
    'large_job_blocks','[
      {"key":"250_350","label":"250 a 350 m²","min_sqm":250,"max_sqm":350,"professionals":2,"estimated_hours":8,"standard_price":192,"deep_price":192,"active":true},
      {"key":"351_500","label":"351 a 500 m²","min_sqm":351,"max_sqm":500,"professionals":2,"estimated_hours":8,"standard_price":240,"deep_price":240,"active":true}
    ]'::jsonb
  ),
  now()
)
on conflict(key) do update
set value = coalesce(public.app_settings.value,'{}'::jsonb) || excluded.value,
    updated_at = excluded.updated_at;

-- Mantener el precio inicial del catálogo global alineado con el primer bloque ($48).
-- No modifica servicios empresariales ni categorías de exteriores.
do $$
begin
  if to_regclass('public.services') is not null then
    update public.services
       set price = 48,
           updated_at = now()
     where company_id is null
       and lower(coalesce(category,'')) like '%limpieza%'
       and lower(coalesce(category,'')) not like '%exterior%';
  end if;
exception when undefined_column then
  -- Instalaciones históricas pueden no tener company_id/updated_at. El app_settings sigue siendo la fuente de verdad.
  null;
end $$;

insert into public.app_settings(key,value,updated_at)
values(
  'wissa_release',
  jsonb_build_object(
    'version','64.9.7',
    'cleaning_pricing_model','hourly_by_area',
    'cleaning_max_auto_sqm',500,
    'cleaning_max_hours_per_professional',8,
    'updated_at',now()
  ),
  now()
)
on conflict(key) do update
set value = coalesce(public.app_settings.value,'{}'::jsonb) || excluded.value,
    updated_at = excluded.updated_at;

notify pgrst,'reload schema';
select pg_notify('pgrst','reload schema');
commit;

select
  'WISSA V64.9.7 LISTO' as resultado,
  value->>'pricing_strategy' as pricing_strategy,
  value->>'max_auto_sqm' as max_auto_sqm,
  jsonb_array_length(coalesce(value->'hourly_service_blocks','[]'::jsonb)) as hourly_blocks
from public.app_settings
where key='cleaning_pricing';
