begin;

-- La tarifa progresiva necesita el metraje exacto. Los rangos anteriores quedan fuera del formulario.
update public.service_category_fields
set is_active = false,
    updated_at = now()
where lower(field_key) in ('cleaning_size_band', 'area_range')
  and is_active is distinct from false;

-- Se recrea una sola pregunta oficial de metraje para cada categoría activa de limpieza.
delete from public.service_category_fields
where lower(coalesce(field_key, '')) = 'square_meters'
  and (
    lower(coalesce(category_name, '')) like '%limpieza%'
    or lower(coalesce(category_name, '')) like '%aseo%'
    or lower(coalesce(category_name, '')) like '%cleaning%'
  );

with cleaning_categories as (
  select distinct category_name
  from public.service_category_fields
  where applies_to = 'booking'
    and is_active = true
    and lower(coalesce(field_key, '')) not in ('square_meters', 'cleaning_size_band', 'area_range')
    and (
      lower(coalesce(category_name, '')) like '%limpieza%'
      or lower(coalesce(category_name, '')) like '%aseo%'
      or lower(coalesce(category_name, '')) like '%cleaning%'
    )
  union
  select 'Limpieza'
  union
  select 'Limpieza de exteriores'
)
insert into public.service_category_fields (
  category_name, field_key, label, field_type, options,
  is_required, sort_order, applies_to, is_active, created_at, updated_at
)
select
  category_name,
  'square_meters',
  'Área aproximada en m²',
  'number',
  '[]'::jsonb,
  true,
  case when lower(category_name) like '%exterior%' then 20 else 30 end,
  'booking',
  true,
  now(),
  now()
from cleaning_categories;

-- Las opciones sin precio fijo no se ofrecen en la reserva.
update public.service_category_fields
set options = '["Revisión o diagnóstico","Reparación de fuga","Destape de tubería","Instalación de grifo","Instalación sanitaria","Calentador","Trabajo exterior"]'::jsonb,
    updated_at = now()
where lower(field_key) = 'plumbing_job_type'
  and lower(coalesce(category_name, '')) like '%plomer%';

update public.service_category_fields
set options = '["Sin repuestos","Repuestos básicos"]'::jsonb,
    updated_at = now()
where lower(field_key) = 'plumbing_parts'
  and lower(coalesce(category_name, '')) like '%plomer%';

commit;
