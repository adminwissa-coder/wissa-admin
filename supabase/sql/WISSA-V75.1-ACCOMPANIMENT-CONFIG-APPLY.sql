-- WISSA V75.1 · Acompañamiento configurable desde Admin
-- No crea un sistema paralelo: usa public.app_settings y el snapshot JSONB de bookings.service_details.

begin;

-- 1) Completa la configuración existente sin borrar tarifas ya definidas.
do $$
declare
  v_default_activities jsonb := jsonb_build_array(
    jsonb_build_object('key','appointment','label_es','Cita / encuentro','label_en','Appointment / meetup','active',true,'requires_detail',false),
    jsonb_build_object('key','coffee_meal','label_es','Café / comida','label_en','Coffee / meal','active',true,'requires_detail',false),
    jsonb_build_object('key','shopping','label_es','Compras','label_en','Shopping','active',true,'requires_detail',false),
    jsonb_build_object('key','errands','label_es','Diligencias','label_en','Errands','active',true,'requires_detail',false),
    jsonb_build_object('key','event','label_es','Evento / actividad','label_en','Event / activity','active',true,'requires_detail',false),
    jsonb_build_object('key','walk_talk','label_es','Paseo / conversación','label_en','Walk / conversation','active',true,'requires_detail',false),
    jsonb_build_object('key','other','label_es','Otro','label_en','Other','active',true,'requires_detail',true)
  );
begin
  insert into public.app_settings(key, value, updated_at)
  values(
    'accompaniment_pricing',
    jsonb_build_object(
      'hourly_rate', 15,
      'minimum_hours', 2,
      'maximum_hours', 12,
      'platform_commission_rate', 0.20,
      'platform_usage_fee', 2,
      'itbms_rate', 0.07,
      'currency', 'USD',
      'presentation_mode', 'single_rate',
      'detail_max_length', 400,
      'activities', v_default_activities
    ),
    now()
  )
  on conflict(key) do update
  set value = coalesce(public.app_settings.value, '{}'::jsonb)
    || jsonb_build_object(
      'detail_max_length', coalesce(nullif(public.app_settings.value->>'detail_max_length','')::integer, 400),
      'activities', case
        when jsonb_typeof(public.app_settings.value->'activities')='array'
          and jsonb_array_length(public.app_settings.value->'activities') > 0
          then public.app_settings.value->'activities'
        else v_default_activities
      end
    ),
    updated_at = now();
end $$;

-- 2) Guardado seguro desde Admin. Mantiene 80/20 y sanea las actividades.
create or replace function public.yt_admin_update_accompaniment_config_v751(p_value jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_value jsonb := coalesce(p_value, '{}'::jsonb);
  v_rate numeric;
  v_min integer;
  v_max integer;
  v_detail_max integer;
  v_activities jsonb;
  v_active_count integer := 0;
  v_updated_at timestamptz := now();
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  v_rate := greatest(coalesce(nullif(v_value->>'hourly_rate','')::numeric, 15), 0.01);
  v_min := greatest(coalesce(nullif(v_value->>'minimum_hours','')::integer, 2), 2);
  v_max := greatest(coalesce(nullif(v_value->>'maximum_hours','')::integer, 12), v_min);
  v_detail_max := greatest(100, least(600, coalesce(nullif(v_value->>'detail_max_length','')::integer, 400)));
  v_activities := coalesce(v_value->'activities', '[]'::jsonb);

  if jsonb_typeof(v_activities) <> 'array' or jsonb_array_length(v_activities) = 0 then
    raise exception 'Acompañamiento requiere al menos una actividad';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(v_activities) item
    where nullif(btrim(item->>'key'),'') is null
       or nullif(btrim(item->>'label_es'),'') is null
  ) then
    raise exception 'Cada actividad requiere key y label_es';
  end if;

  select count(*) into v_active_count
  from jsonb_array_elements(v_activities) item
  where coalesce((item->>'active')::boolean, true) = true;

  if v_active_count < 1 then
    raise exception 'Debe existir al menos una actividad activa';
  end if;

  v_value := v_value || jsonb_build_object(
    'hourly_rate', round(v_rate, 2),
    'minimum_hours', v_min,
    'maximum_hours', v_max,
    'detail_max_length', v_detail_max,
    'platform_commission_rate', 0.20,
    'currency', 'USD',
    'presentation_mode', 'single_rate',
    'activities', v_activities
  );

  insert into public.app_settings(key, value, updated_by, updated_at)
  values('accompaniment_pricing', v_value, auth.uid(), v_updated_at)
  on conflict(key) do update
  set value = excluded.value,
      updated_by = excluded.updated_by,
      updated_at = excluded.updated_at;

  return jsonb_build_object('ok', true, 'value', v_value, 'updated_at', v_updated_at);
end;
$$;

revoke execute on function public.yt_admin_update_accompaniment_config_v751(jsonb) from public, anon;
grant execute on function public.yt_admin_update_accompaniment_config_v751(jsonb) to authenticated, service_role;

-- 3) Configuración pública segura para el wizard Mobile.
create or replace function public.yt_public_accompaniment_config_v751()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'hourly_rate', coalesce(nullif(value->>'hourly_rate','')::numeric, 15),
    'minimum_hours', greatest(coalesce(nullif(value->>'minimum_hours','')::integer, 2), 2),
    'maximum_hours', greatest(coalesce(nullif(value->>'maximum_hours','')::integer, 12), 2),
    'detail_max_length', greatest(100, least(600, coalesce(nullif(value->>'detail_max_length','')::integer, 400))),
    'activities', coalesce(value->'activities', '[]'::jsonb)
  )
  from public.app_settings
  where key='accompaniment_pricing'
  limit 1;
$$;

revoke execute on function public.yt_public_accompaniment_config_v751() from public;
grant execute on function public.yt_public_accompaniment_config_v751() to anon, authenticated, service_role;

commit;
