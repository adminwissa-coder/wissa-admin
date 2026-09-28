-- ==========================================================================
-- WISSA V64.3 - COMMERCIAL PRICING + PUBLIC COPY CLEANUP
-- Objetivos:
--   * Eliminar textos internos/QA de datos visibles.
--   * Evitar servicios de Ofrecer con precio 0.
--   * Definir precios comerciales para todos los bloques de limpieza >250 m2.
--   * Dar precio individual al 2.o, 3.o, 4.o y 5.o profesional.
--   * Mantener ubicacion de trabajo y precio administrados por Wissa.
-- Idempotente. No elimina usuarios ni reservas.
-- ==========================================================================
begin;
select pg_advisory_xact_lock(hashtext('wissa_v64_3_commercial_pricing_copy_cleanup'));

-- --------------------------------------------------------------------------
-- 1. Limpieza defensiva de textos que vienen de datos historicos.
-- --------------------------------------------------------------------------
create or replace function public.wissa_v643_public_text(p_text text)
returns text
language plpgsql
immutable
set search_path=public,pg_temp
as $$
declare v text:=coalesce(p_text,'');
begin
  v:=regexp_replace(v,'\[(QA|DEV|TEST|DEBUG|STAGE|STAGING)[^]]*\][[:space:]]*','','gi');
  v:=regexp_replace(v,'(^|[[:space:]])(QA|DEV|TEST|DEBUG)([: -]+|$)',' ','gi');
  v:=regexp_replace(v,'(^|[[:space:]])V[0-9]+(\.[0-9]+){0,3}([[:space:]]|$)',' ','gi');
  v:=regexp_replace(v,'[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}',' ','gi');
  v:=regexp_replace(v,'provider_id','profesional','gi');
  v:=regexp_replace(v,'booking_id','reserva','gi');
  v:=regexp_replace(v,'pending_payment','Pendiente de pago','gi');
  v:=regexp_replace(v,'paid_pending_acceptance','Esperando confirmación','gi');
  v:=regexp_replace(v,'accepted','Aceptado','gi');
  v:=regexp_replace(v,'matching','búsqueda','gi');
  v:=regexp_replace(v,'pool','grupo','gi');
  v:=regexp_replace(v,'snapshot','registro','gi');
  v:=regexp_replace(v,'not_started','Sin iniciar','gi');
  v:=regexp_replace(v,'Supabase','la plataforma','gi');
  v:=regexp_replace(v,'SQL','el sistema','gi');
  v:=regexp_replace(v,'cupos','asignaciones','gi');
  v:=regexp_replace(v,'cupo','asignación','gi');
  v:=regexp_replace(v,'UUID','referencia','gi');
  v:=regexp_replace(v,'[[:space:]]+',' ','g');
  return btrim(v,' -–—:|');
end $$;

-- Servicios existentes: nunca dejar una etiqueta QA visible y nunca precio 0.
update public.services
set title = case
      when lower(public.wissa_v643_public_text(title)) in ('limpieza wissa','limpieza') then 'Limpieza'
      when lower(public.wissa_v643_public_text(title)) in ('plomeria wissa','plomería wissa','plomeria','plomería') then 'Plomería'
      when nullif(public.wissa_v643_public_text(title),'') is null then coalesce(nullif(trim(category),''),'Servicio Wissa')
      else public.wissa_v643_public_text(title)
    end,
    description = case
      when coalesce(description,'') ~* '(\[qa|(^|[^a-z])qa([^a-z]|$)|(^|[^a-z])v[0-9]+|uuid|provider_id|booking_id|pending_payment|matching|snapshot|servicio ficticio|probar equipos|prueba de equipo)'
        then case
          when lower(coalesce(category,'')) like '%plomer%' then 'Servicio profesional de plomería disponible a través de Wissa.'
          when lower(coalesce(category,'')) like '%exterior%' then 'Servicio profesional de limpieza exterior disponible a través de Wissa.'
          when lower(coalesce(category,'')) like '%limpieza%' then 'Servicio profesional de limpieza disponible a través de Wissa.'
          else 'Servicio profesional disponible a través de Wissa.'
        end
      else nullif(public.wissa_v643_public_text(description),'')
    end,
    price = case
      when coalesce(price,0)>0 then price
      when lower(coalesce(category,'')) like '%plomer%' then 25
      when lower(coalesce(category,'')) like '%exterior%' then 40
      when lower(coalesce(category,'')) like '%limpieza%' then 35
      else 35
    end;

-- Snapshots de reservas y notificaciones historicas tambien quedan limpios.
do $$ begin
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='bookings' and column_name='service_title') then
    execute $q$update public.bookings set service_title=case when lower(public.wissa_v643_public_text(service_title))='limpieza wissa' then 'Limpieza' when lower(public.wissa_v643_public_text(service_title)) in ('plomeria wissa','plomería wissa') then 'Plomería' else public.wissa_v643_public_text(service_title) end where service_title is not null$q$;
  end if;
  if to_regclass('public.notifications') is not null then
    execute $q$update public.notifications set title=public.wissa_v643_public_text(title), body=public.wissa_v643_public_text(body) where title is not null or body is not null$q$;
  end if;
end $$;

-- Reservas y notificaciones nuevas también pasan por la misma capa de texto público.
create or replace function public.wissa_v643_prepare_booking_copy()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if new.service_title is not null then
    new.service_title:=public.wissa_v643_public_text(new.service_title);
    if lower(new.service_title)='limpieza wissa' then new.service_title:='Limpieza'; end if;
    if lower(new.service_title) in ('plomeria wissa','plomería wissa') then new.service_title:='Plomería'; end if;
  end if;
  return new;
end $$;

do $$ begin
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='bookings' and column_name='service_title') then
    execute 'drop trigger if exists trg_wissa_v643_prepare_booking_copy on public.bookings';
    execute 'create trigger trg_wissa_v643_prepare_booking_copy before insert or update of service_title on public.bookings for each row execute function public.wissa_v643_prepare_booking_copy()';
  end if;
end $$;

create or replace function public.wissa_v643_prepare_notification_copy()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if new.title is not null then new.title:=public.wissa_v643_public_text(new.title); end if;
  if new.body is not null then new.body:=public.wissa_v643_public_text(new.body); end if;
  return new;
end $$;

do $$ begin
  if to_regclass('public.notifications') is not null
     and exists(select 1 from information_schema.columns where table_schema='public' and table_name='notifications' and column_name='title')
     and exists(select 1 from information_schema.columns where table_schema='public' and table_name='notifications' and column_name='body') then
    execute 'drop trigger if exists trg_wissa_v643_prepare_notification_copy on public.notifications';
    execute 'create trigger trg_wissa_v643_prepare_notification_copy before insert or update of title,body on public.notifications for each row execute function public.wissa_v643_prepare_notification_copy()';
  end if;
end $$;

-- Liquidaciones históricas y futuras tampoco exponen versiones/cupos internos.
do $$ begin
  if to_regclass('public.provider_payouts') is not null then
    begin
      update public.provider_payouts set notes=public.wissa_v643_public_text(notes) where notes is not null;
    exception when undefined_column then null;
    end;
  end if;
end $$;

create or replace function public.wissa_v643_prepare_payout_copy()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if new.notes is not null then new.notes:=public.wissa_v643_public_text(new.notes); end if;
  return new;
end $$;

do $$ begin
  if to_regclass('public.provider_payouts') is not null then
    execute 'drop trigger if exists trg_wissa_v643_prepare_payout_copy on public.provider_payouts';
    execute 'create trigger trg_wissa_v643_prepare_payout_copy before insert or update of notes on public.provider_payouts for each row execute function public.wissa_v643_prepare_payout_copy()';
  end if;
end $$;

-- Cualquier servicio nuevo se limpia y toma el precio comercial vigente.
create or replace function public.wissa_v643_prepare_service()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare
  v_pricing jsonb;
  v_price numeric;
  v_category text:=lower(coalesce(new.category,''));
begin
  new.title:=public.wissa_v643_public_text(new.title);
  if nullif(trim(new.title),'') is null then new.title:=coalesce(nullif(trim(new.category),''),'Servicio Wissa'); end if;
  if lower(new.title)='limpieza wissa' then new.title:='Limpieza'; end if;
  if lower(new.title) in ('plomeria wissa','plomería wissa') then new.title:='Plomería'; end if;

  if coalesce(new.description,'') ~* '(\[qa|(^|[^a-z])qa([^a-z]|$)|(^|[^a-z])v[0-9]+|uuid|provider_id|booking_id|pending_payment|matching|snapshot|servicio ficticio|probar equipos)' then
    new.description:=case when v_category like '%plomer%' then 'Servicio profesional de plomería disponible a través de Wissa.'
      when v_category like '%exterior%' then 'Servicio profesional de limpieza exterior disponible a través de Wissa.'
      when v_category like '%limpieza%' then 'Servicio profesional de limpieza disponible a través de Wissa.'
      else 'Servicio profesional disponible a través de Wissa.' end;
  else
    new.description:=nullif(public.wissa_v643_public_text(new.description),'');
  end if;

  select value into v_pricing from public.app_settings where key=case
    when v_category like '%plomer%' then 'plumbing_pricing'
    when v_category like '%exterior%' then 'exterior_cleaning_pricing'
    when v_category like '%limpieza%' then 'cleaning_pricing'
    else null end;

  if v_category like '%plomer%' then
    v_price:=coalesce(nullif(v_pricing->>'inspection_fee','')::numeric,25);
  elsif v_category like '%exterior%' then
    v_price:=coalesce(nullif(v_pricing#>>'{fixed_service_prices,basica}','')::numeric,nullif(v_pricing->>'fixed_service_price','')::numeric,40);
  elsif v_category like '%limpieza%' then
    v_price:=coalesce(nullif(v_pricing#>>'{parametric_engine,minimum_price}','')::numeric,35);
  else
    v_price:=greatest(35,coalesce(new.price,35));
  end if;
  new.price:=greatest(1,coalesce(v_price,35));
  return new;
end $$;

drop trigger if exists trg_wissa_v643_prepare_service on public.services;
create trigger trg_wissa_v643_prepare_service
before insert or update of title,description,category,price on public.services
for each row execute function public.wissa_v643_prepare_service();

-- --------------------------------------------------------------------------
-- 2. Formula comercial de Limpieza.
--    0..250 m2 conserva formula aprobada.
--    >250 m2 usa capacidad de equipo + horas: estándar USD 17/hora-persona,
--    profunda USD 20.50/hora-persona, redondeada al precio cerrado del bloque.
-- --------------------------------------------------------------------------
update public.app_settings
set value=coalesce(value,'{}'::jsonb) || jsonb_build_object(
  'pricing_version',64,
  'pricing_revision','64.3-commercial-blocks',
  'platform_commission_rate',0.20,
  'mobility_fee_per_booking',5,
  'platform_usage_fee',2,
  'itbms_rate',0.07,
  'additional_professional_fees','{"2":35,"3":35,"4":35,"5":35}'::jsonb,
  'parametric_engine',coalesce(value->'parametric_engine','{}'::jsonb) || jsonb_build_object(
    'minimum_price',35,
    'minimum_included_sqm',60,
    'tier1_end_sqm',120,
    'tier1_rate_per_sqm',0.28,
    'tier2_end_sqm',220,
    'tier2_rate_per_sqm',0.38,
    'team_threshold_sqm',250,
    'team_base_price',89.80,
    'team_rate_per_sqm',1.00,
    'quote_threshold_sqm',2000,
    'deep_cleaning_rate_per_sqm',0.15,
    'professionals_at_team_threshold',2,
    'max_professionals',5
  ),
  'large_job_blocks','[
    {"key":"251_350","label":"Más de 250 a 350 m²","min_sqm":250,"max_sqm":350,"professionals":2,"estimated_hours":4,"standard_price":136,"deep_price":164,"active":true},
    {"key":"351_500","label":"Más de 350 a 500 m²","min_sqm":350,"max_sqm":500,"professionals":2,"estimated_hours":6,"standard_price":204,"deep_price":246,"active":true},
    {"key":"501_700","label":"Más de 500 a 700 m²","min_sqm":500,"max_sqm":700,"professionals":3,"estimated_hours":6,"standard_price":306,"deep_price":369,"active":true},
    {"key":"701_900","label":"Más de 700 a 900 m²","min_sqm":700,"max_sqm":900,"professionals":4,"estimated_hours":6,"standard_price":408,"deep_price":492,"active":true},
    {"key":"901_1200","label":"Más de 900 a 1,200 m²","min_sqm":900,"max_sqm":1200,"professionals":5,"estimated_hours":6,"standard_price":510,"deep_price":615,"active":true},
    {"key":"1201_1500","label":"Más de 1,200 a 1,500 m²","min_sqm":1200,"max_sqm":1500,"professionals":5,"estimated_hours":8,"standard_price":680,"deep_price":820,"active":true},
    {"key":"1501_2000","label":"Más de 1,500 a 2,000 m²","min_sqm":1500,"max_sqm":2000,"professionals":5,"estimated_hours":10,"standard_price":850,"deep_price":1025,"active":true}
  ]'::jsonb,
  'kits',coalesce(value->'kits','{}'::jsonb) || jsonb_build_object(
    'enabled',true,
    'basic',jsonb_build_object('title','Kit básico','description','Jabón, escoba, trapeador, bolsas de basura y paños de limpieza.','price',15),
    'premium',jsonb_build_object('title','Personalizar materiales','description','El cliente paga únicamente los productos que seleccione.','price',15)
  )
), updated_at=now()
where key='cleaning_pricing';

-- Exterior y Plomeria: todos los cargos de equipo tienen precio inicial.
update public.app_settings
set value=coalesce(value,'{}'::jsonb) || jsonb_build_object(
  'pricing_version',64,'pricing_revision','64.3-commercial',
  'platform_commission_rate',0.20,'mobility_fee_per_booking',5,'platform_usage_fee',2,'itbms_rate',0.07,
  'fixed_service_price',greatest(1,coalesce(nullif((value->>'fixed_service_price')::numeric,0),40)),
  'fixed_service_prices',jsonb_build_object('basica',greatest(1,coalesce(nullif((value#>>'{fixed_service_prices,basica}')::numeric,0),40)),'premium',greatest(1,coalesce(nullif((value#>>'{fixed_service_prices,premium}')::numeric,0),40))),
  'additional_professional_fees','{"2":30,"3":30,"4":30,"5":30}'::jsonb
), updated_at=now()
where key='exterior_cleaning_pricing';

update public.app_settings
set value=coalesce(value,'{}'::jsonb) || jsonb_build_object(
  'pricing_version',64,'pricing_revision','64.3-commercial',
  'platform_commission_rate',0.35,'mobility_fee_per_booking',5,'platform_usage_fee',2,'itbms_rate',0.07,
  'inspection_fee',greatest(1,coalesce(nullif((value->>'inspection_fee')::numeric,0),25)),
  'additional_professional_fees','{"2":40,"3":40,"4":40,"5":40}'::jsonb
), updated_at=now()
where key='plumbing_pricing';

-- Si una instalacion no tenia las llaves, crearlas con valores completos.
insert into public.app_settings(key,value,updated_at)
select 'cleaning_pricing',jsonb_build_object(
  'pricing_version',64,'currency','USD','platform_commission_rate',0.20,'platform_usage_fee',2,'itbms_rate',0.07,'mobility_fee_per_booking',5,
  'additional_professional_fees','{"2":35,"3":35,"4":35,"5":35}'::jsonb,
  'parametric_engine',jsonb_build_object('minimum_price',35,'minimum_included_sqm',60,'tier1_end_sqm',120,'tier1_rate_per_sqm',0.28,'tier2_end_sqm',220,'tier2_rate_per_sqm',0.38,'team_threshold_sqm',250,'team_base_price',89.80,'team_rate_per_sqm',1.00,'quote_threshold_sqm',2000,'deep_cleaning_rate_per_sqm',0.15,'professionals_at_team_threshold',2,'max_professionals',5),
  'large_job_blocks','[{"key":"251_350","label":"Más de 250 a 350 m²","min_sqm":250,"max_sqm":350,"professionals":2,"estimated_hours":4,"standard_price":136,"deep_price":164,"active":true},{"key":"351_500","label":"Más de 350 a 500 m²","min_sqm":350,"max_sqm":500,"professionals":2,"estimated_hours":6,"standard_price":204,"deep_price":246,"active":true},{"key":"501_700","label":"Más de 500 a 700 m²","min_sqm":500,"max_sqm":700,"professionals":3,"estimated_hours":6,"standard_price":306,"deep_price":369,"active":true},{"key":"701_900","label":"Más de 700 a 900 m²","min_sqm":700,"max_sqm":900,"professionals":4,"estimated_hours":6,"standard_price":408,"deep_price":492,"active":true},{"key":"901_1200","label":"Más de 900 a 1,200 m²","min_sqm":900,"max_sqm":1200,"professionals":5,"estimated_hours":6,"standard_price":510,"deep_price":615,"active":true},{"key":"1201_1500","label":"Más de 1,200 a 1,500 m²","min_sqm":1200,"max_sqm":1500,"professionals":5,"estimated_hours":8,"standard_price":680,"deep_price":820,"active":true},{"key":"1501_2000","label":"Más de 1,500 a 2,000 m²","min_sqm":1500,"max_sqm":2000,"professionals":5,"estimated_hours":10,"standard_price":850,"deep_price":1025,"active":true}]'::jsonb,
  'kits',jsonb_build_object('enabled',true,'basic',jsonb_build_object('title','Kit básico','description','Jabón, escoba, trapeador, bolsas de basura y paños de limpieza.','price',15),'premium',jsonb_build_object('title','Personalizar materiales','description','El cliente paga únicamente los productos que seleccione.','price',15))
),now()
where not exists(select 1 from public.app_settings where key='cleaning_pricing');

insert into public.app_settings(key,value,updated_at)
select 'exterior_cleaning_pricing',jsonb_build_object(
  'pricing_version',64,'currency','USD','platform_commission_rate',0.20,'platform_usage_fee',2,'itbms_rate',0.07,
  'mobility_fee_per_booking',5,'fixed_service_price',40,'fixed_service_prices',jsonb_build_object('basica',40,'premium',40),
  'additional_professional_fees','{"2":30,"3":30,"4":30,"5":30}'::jsonb
),now()
where not exists(select 1 from public.app_settings where key='exterior_cleaning_pricing');

insert into public.app_settings(key,value,updated_at)
select 'plumbing_pricing',jsonb_build_object(
  'pricing_version',64,'currency','USD','platform_commission_rate',0.35,'platform_usage_fee',2,'itbms_rate',0.07,
  'mobility_fee_per_booking',5,'inspection_fee',25,
  'additional_professional_fees','{"2":40,"3":40,"4":40,"5":40}'::jsonb
),now()
where not exists(select 1 from public.app_settings where key='plumbing_pricing');

-- --------------------------------------------------------------------------
-- 3. Reglas de equipo: precio separado para cada posicion 2..5.
-- --------------------------------------------------------------------------
alter table public.service_team_rules
  add column if not exists additional_professional_fees jsonb not null default '{"2":35,"3":35,"4":35,"5":35}'::jsonb;

update public.service_team_rules
set additional_professional_fee=greatest(1,coalesce(nullif(additional_professional_fee,0),35)),
    additional_professional_fees=jsonb_build_object(
      '2',greatest(1,coalesce(nullif((additional_professional_fees->>'2')::numeric,0),nullif(additional_professional_fee,0),35)),
      '3',greatest(1,coalesce(nullif((additional_professional_fees->>'3')::numeric,0),nullif(additional_professional_fee,0),35)),
      '4',greatest(1,coalesce(nullif((additional_professional_fees->>'4')::numeric,0),nullif(additional_professional_fee,0),35)),
      '5',greatest(1,coalesce(nullif((additional_professional_fees->>'5')::numeric,0),nullif(additional_professional_fee,0),35))
    ), updated_at=now();

create or replace function public.yt_admin_upsert_team_rule_v62(p_rule jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_id uuid;
  v_min int; v_rec int; v_max int;
  v_fees jsonb;
begin
  if not public.yt_admin_is_current_admin() then raise exception 'Solo Admin Wissa puede editar reglas de equipo.'; end if;
  v_id:=nullif(p_rule->>'id','')::uuid;
  v_min:=greatest(1,least(5,coalesce((p_rule->>'min_professionals')::int,1)));
  v_rec:=greatest(v_min,least(5,coalesce((p_rule->>'recommended_professionals')::int,v_min)));
  v_max:=greatest(v_rec,least(5,coalesce((p_rule->>'max_professionals')::int,v_rec)));
  v_fees:=jsonb_build_object(
    '2',greatest(1,coalesce(nullif((p_rule#>>'{additional_professional_fees,2}')::numeric,0),nullif((p_rule->>'additional_professional_fee')::numeric,0),35)),
    '3',greatest(1,coalesce(nullif((p_rule#>>'{additional_professional_fees,3}')::numeric,0),nullif((p_rule->>'additional_professional_fee')::numeric,0),35)),
    '4',greatest(1,coalesce(nullif((p_rule#>>'{additional_professional_fees,4}')::numeric,0),nullif((p_rule->>'additional_professional_fee')::numeric,0),35)),
    '5',greatest(1,coalesce(nullif((p_rule#>>'{additional_professional_fees,5}')::numeric,0),nullif((p_rule->>'additional_professional_fee')::numeric,0),35))
  );
  if v_id is null then
    insert into public.service_team_rules(category,cleaning_mode,property_type,sqm_min,sqm_max,min_professionals,recommended_professionals,max_professionals,additional_professional_fee,additional_professional_fees,is_active,priority,metadata)
    values(coalesce(nullif(trim(p_rule->>'category'),''),'Limpieza'),case when p_rule->>'cleaning_mode' in ('standard','deep','any') then p_rule->>'cleaning_mode' else 'any' end,coalesce(nullif(trim(p_rule->>'property_type'),''),'any'),greatest(0,coalesce((p_rule->>'sqm_min')::int,1)),greatest(1,coalesce((p_rule->>'sqm_max')::int,400)),v_min,v_rec,v_max,(v_fees->>'2')::numeric,v_fees,coalesce((p_rule->>'is_active')::boolean,true),coalesce((p_rule->>'priority')::int,100),coalesce(p_rule->'metadata','{}'::jsonb)-'seed') returning id into v_id;
  else
    update public.service_team_rules set category=coalesce(nullif(trim(p_rule->>'category'),''),category),cleaning_mode=case when p_rule->>'cleaning_mode' in ('standard','deep','any') then p_rule->>'cleaning_mode' else cleaning_mode end,property_type=coalesce(nullif(trim(p_rule->>'property_type'),''),property_type),sqm_min=greatest(0,coalesce((p_rule->>'sqm_min')::int,sqm_min)),sqm_max=greatest(greatest(0,coalesce((p_rule->>'sqm_min')::int,sqm_min)),coalesce((p_rule->>'sqm_max')::int,sqm_max)),min_professionals=v_min,recommended_professionals=v_rec,max_professionals=v_max,additional_professional_fee=(v_fees->>'2')::numeric,additional_professional_fees=v_fees,is_active=coalesce((p_rule->>'is_active')::boolean,is_active),priority=coalesce((p_rule->>'priority')::int,priority),metadata=(coalesce(metadata,'{}'::jsonb)||coalesce(p_rule->'metadata','{}'::jsonb))-'seed',updated_at=now() where id=v_id;
  end if;
  return to_jsonb((select x from public.service_team_rules x where x.id=v_id));
end $$;
grant execute on function public.yt_admin_upsert_team_rule_v62(jsonb) to authenticated,service_role;

-- Reglas base para el motor comercial. No duplican reglas existentes con el mismo rango.
insert into public.service_team_rules(category,cleaning_mode,property_type,sqm_min,sqm_max,min_professionals,recommended_professionals,max_professionals,additional_professional_fee,additional_professional_fees,is_active,priority,metadata)
select x.category,x.cleaning_mode,x.property_type,x.sqm_min,x.sqm_max,x.min_professionals,x.recommended_professionals,x.max_professionals,35,'{"2":35,"3":35,"4":35,"5":35}'::jsonb,true,50,'{"commercial_model":"hybrid_time_block"}'::jsonb
from (values
  ('Limpieza','any','any',1,250,1,1,1),
  ('Limpieza','any','any',251,350,2,2,2),
  ('Limpieza','any','any',351,500,2,2,2),
  ('Limpieza','any','any',501,700,3,3,3),
  ('Limpieza','any','any',701,900,4,4,4),
  ('Limpieza','any','any',901,1200,5,5,5),
  ('Limpieza','any','any',1201,1500,5,5,5),
  ('Limpieza','any','any',1501,2000,5,5,5)
) as x(category,cleaning_mode,property_type,sqm_min,sqm_max,min_professionals,recommended_professionals,max_professionals)
where not exists (
  select 1 from public.service_team_rules r
  where lower(r.category)=lower(x.category)
    and r.cleaning_mode=x.cleaning_mode
    and lower(r.property_type)=lower(x.property_type)
    and r.sqm_min=x.sqm_min and r.sqm_max=x.sqm_max
);

-- Los productos/extras activos del catalogo no deben quedar con precio 0.
do $$ begin
  if to_regclass('public.booking_catalog') is not null then
    begin
      update public.booking_catalog
      set price=case when lower(coalesce(kind,''))='product' then 5 when lower(coalesce(kind,''))='extra' then 10 else 5 end
      where coalesce(active,true)=true and lower(coalesce(kind,'')) in ('product','extra') and coalesce(price,0)<=0;
    exception when undefined_column then null;
    end;
  end if;
end $$;

commit;

-- Verificacion util tras ejecutar:
select key,value->'additional_professional_fees' as team_prices,value->'large_job_blocks' as large_job_blocks
from public.app_settings where key in ('cleaning_pricing','exterior_cleaning_pricing','plumbing_pricing') order by key;
