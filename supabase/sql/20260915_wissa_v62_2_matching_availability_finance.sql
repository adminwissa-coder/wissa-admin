-- ============================================================================
-- WISSA V62.2 - MATCHING + DISPONIBILIDAD + PAGO TRAS ACEPTACION + FINANZAS
-- Fecha: 2026-09-14
-- Incremental sobre V62.0. Idempotente. NO elimina usuarios ni reservas.
-- ============================================================================
begin;
select pg_advisory_xact_lock(hashtext('wissa_v62_2_matching_availability_finance'));

-- --------------------------------------------------------------------------
-- 1. Pricing autoritativo V62.2. Mantiene decimales administrables y evita
--    el salto 249 -> 250: desde el rango de equipo el precio es CONTINUO.
-- --------------------------------------------------------------------------
create or replace function public.yt_v60_apply_pricing_rules(p_key text, p_value jsonb)
returns jsonb
language plpgsql
immutable
set search_path=public
as $$
declare
  v_key text:=lower(trim(coalesce(p_key,'')));
  v_value jsonb:=coalesce(p_value,'{}'::jsonb);
  v_commission numeric;
  v_travel numeric;
  v_platform numeric;
  v_tax numeric;
  v_inspection numeric;
  v_engine jsonb;
begin
  if jsonb_typeof(v_value)<>'object' then v_value:='{}'::jsonb; end if;
  v_commission:=greatest(0,least(1,coalesce(nullif(v_value->>'platform_commission_rate','')::numeric,case when v_key='plumbing_pricing' then 0.35 else 0.20 end)));
  v_travel:=greatest(0,coalesce(nullif(v_value->>'travel_rate_per_km','')::numeric,0.60));
  v_platform:=greatest(0,coalesce(nullif(v_value->>'platform_usage_fee','')::numeric,2));
  v_tax:=greatest(0,least(1,coalesce(nullif(v_value->>'itbms_rate','')::numeric,nullif(v_value->>'tax_rate','')::numeric,0.07)));

  v_value:=jsonb_set(v_value,'{pricing_version}','62'::jsonb,true);
  v_value:=jsonb_set(v_value,'{pricing_revision}','"62.2"'::jsonb,true);
  v_value:=jsonb_set(v_value,'{travel_mode}','"road_distance"'::jsonb,true);
  v_value:=jsonb_set(v_value,'{travel_flat_fee}','0'::jsonb,true);
  v_value:=jsonb_set(v_value,'{travel_rate_per_km}',to_jsonb(v_travel),true);
  v_value:=jsonb_set(v_value,'{platform_usage_fee}',to_jsonb(v_platform),true);
  v_value:=jsonb_set(v_value,'{itbms_rate}',to_jsonb(v_tax),true);
  v_value:=jsonb_set(v_value,'{tax_rate}',to_jsonb(v_tax),true);
  v_value:=jsonb_set(v_value,'{platform_commission_rate}',to_jsonb(v_commission),true);

  if v_key='cleaning_pricing' then
    v_engine:=jsonb_build_object(
      'minimum_price',35,'minimum_included_sqm',70,
      'tier1_end_sqm',130,'tier1_rate_per_sqm',0.2815,
      'tier2_end_sqm',249,'tier2_rate_per_sqm',0.38,
      'team_threshold_sqm',250,'team_base_price',250,
      'team_rate_per_sqm',0.70,'continuous_team_pricing',true,
      'quote_threshold_sqm',400,'deep_cleaning_rate_per_sqm',0.15,
      'professionals_at_team_threshold',2,'max_professionals',15
    ) || coalesce(v_value->'parametric_engine','{}'::jsonb);
    v_engine:=jsonb_set(v_engine,'{continuous_team_pricing}','true'::jsonb,true);
    v_value:=jsonb_set(v_value,'{parametric_engine}',v_engine,true);
    v_value:=jsonb_set(v_value,'{pricing_mode}','"parametric_cleaning_v62_continuous"'::jsonb,true);
    v_value:=jsonb_set(v_value,'{fixed_service_price}',to_jsonb(greatest(0,coalesce(nullif(v_engine->>'minimum_price','')::numeric,35))),true);
    v_value:=jsonb_set(v_value,'{fixed_service_prices,basica}',to_jsonb(greatest(0,coalesce(nullif(v_engine->>'minimum_price','')::numeric,35))),true);
    v_value:=jsonb_set(v_value,'{fixed_service_prices,premium}',to_jsonb(greatest(0,coalesce(nullif(v_engine->>'minimum_price','')::numeric,35))),true);
  elsif v_key='plumbing_pricing' then
    v_inspection:=greatest(coalesce(nullif(v_value->>'inspection_fee','')::numeric,nullif(v_value#>>'{job_base,revision}','')::numeric,25),0);
    v_value:=jsonb_set(v_value,'{pricing_mode}','"inspection_road_v62"'::jsonb,true);
    v_value:=jsonb_set(v_value,'{inspection_fee}',to_jsonb(v_inspection),true);
    v_value:=jsonb_set(v_value,'{job_base,revision}',to_jsonb(v_inspection),true);
    v_value:=jsonb_set(v_value,'{plumbing_mode}','"diagnosis_only"'::jsonb,true);
  elsif v_key='exterior_cleaning_pricing' then
    v_value:=jsonb_set(v_value,'{pricing_mode}','"fixed_service_road_v62"'::jsonb,true);
  end if;
  return v_value;
exception when others then return coalesce(p_value,'{}'::jsonb);
end; $$;
grant execute on function public.yt_v60_apply_pricing_rules(text,jsonb) to anon,authenticated,service_role;

-- La normalización vieja eliminaba parametric_engine y forzaba valores legacy.
create or replace function public.yt_normalize_service_pricing_value(p_key text,p_value jsonb)
returns jsonb language sql immutable set search_path=public as $$
  select public.yt_v60_apply_pricing_rules(p_key,p_value);
$$;
grant execute on function public.yt_normalize_service_pricing_value(text,jsonb) to authenticated,service_role;

update public.app_settings
set value=public.yt_v60_apply_pricing_rules(key,value),updated_at=now()
where key in ('cleaning_pricing','exterior_cleaning_pricing','plumbing_pricing');

-- --------------------------------------------------------------------------
-- 2. Reglas de equipo: 1 y 2 siempre seleccionables; 3..5 según regla.
--    La cantidad de personas NO agrega un cargo artificial por defecto.
-- --------------------------------------------------------------------------
alter table public.service_team_rules alter column additional_professional_fee set default 0;
update public.service_team_rules set additional_professional_fee=0,updated_at=now()
where metadata->>'seed'='wissa_v62_default';

create or replace function public.yt_v62_resolve_team_requirement(
  p_category text,p_cleaning_mode text default 'standard',p_property_type text default 'any',p_square_meters integer default 1
) returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  r public.service_team_rules%rowtype;
  v_category text:=public.yt_v62_normalize_team_text(p_category);
  v_mode text:=case when public.yt_v62_normalize_team_text(p_cleaning_mode) in ('deep','profunda','limpieza_profunda','premium') then 'deep' else 'standard' end;
  v_property text:=public.yt_v62_normalize_team_text(p_property_type);
  v_sqm int:=greatest(1,least(400,coalesce(p_square_meters,1)));
  v_recommended int:=1;
  v_max int:=2;
begin
  select * into r from public.service_team_rules x
  where x.is_active=true
    and public.yt_v62_normalize_team_text(x.category) in (v_category,'limpieza','cleaning')
    and x.cleaning_mode in (v_mode,'any')
    and public.yt_v62_normalize_team_text(x.property_type) in (v_property,'any')
    and v_sqm between x.sqm_min and x.sqm_max
  order by case when x.cleaning_mode=v_mode then 0 else 1 end,
           case when public.yt_v62_normalize_team_text(x.property_type)=v_property then 0 else 1 end,
           x.priority,(x.sqm_max-x.sqm_min) limit 1;
  if found then
    v_recommended:=greatest(1,least(5,r.recommended_professionals));
    v_max:=greatest(2,v_recommended,least(5,r.max_professionals));
  end if;
  return jsonb_build_object(
    'min',1,'recommended',v_recommended,'max',v_max,
    'rule_min',case when found then r.min_professionals else 1 end,
    'additional_professional_fee',case when found then r.additional_professional_fee else 0 end,
    'rule_id',case when found then r.id else null end,'source',case when found then 'service_team_rules' else 'fallback' end,
    'category',case when found then r.category else p_category end,'mode',v_mode,'property_type',v_property,
    'sqm_min',case when found then r.sqm_min else 1 end,'sqm_max',case when found then r.sqm_max else 400 end
  );
end; $$;
grant execute on function public.yt_v62_resolve_team_requirement(text,text,text,integer) to anon,authenticated,service_role;

-- Reglas nuevas no generan recargo por cantidad de personas a menos que Admin lo configure explícitamente.
create or replace function public.yt_admin_upsert_team_rule_v62(p_rule jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_id uuid; v_min int; v_rec int; v_max int; begin
  if not public.yt_admin_is_current_admin() then raise exception 'Solo Admin Wissa puede editar reglas de equipo.'; end if;
  v_id:=nullif(p_rule->>'id','')::uuid;
  v_min:=greatest(1,least(5,coalesce((p_rule->>'min_professionals')::int,1)));
  v_rec:=greatest(v_min,least(5,coalesce((p_rule->>'recommended_professionals')::int,v_min)));
  v_max:=greatest(v_rec,least(5,coalesce((p_rule->>'max_professionals')::int,greatest(2,v_rec))));
  if v_id is null then
    insert into public.service_team_rules(category,cleaning_mode,property_type,sqm_min,sqm_max,min_professionals,recommended_professionals,max_professionals,additional_professional_fee,is_active,priority,metadata)
    values(coalesce(nullif(trim(p_rule->>'category'),''),'Limpieza'),case when p_rule->>'cleaning_mode' in ('standard','deep','any') then p_rule->>'cleaning_mode' else 'any' end,
      coalesce(nullif(trim(p_rule->>'property_type'),''),'any'),greatest(1,coalesce((p_rule->>'sqm_min')::int,1)),greatest(1,coalesce((p_rule->>'sqm_max')::int,400)),
      v_min,v_rec,v_max,greatest(0,coalesce((p_rule->>'additional_professional_fee')::numeric,0)),coalesce((p_rule->>'is_active')::boolean,true),
      coalesce((p_rule->>'priority')::int,100),coalesce(p_rule->'metadata','{}'::jsonb)-'seed') returning id into v_id;
  else
    update public.service_team_rules set category=coalesce(nullif(trim(p_rule->>'category'),''),category),
      cleaning_mode=case when p_rule->>'cleaning_mode' in ('standard','deep','any') then p_rule->>'cleaning_mode' else cleaning_mode end,
      property_type=coalesce(nullif(trim(p_rule->>'property_type'),''),property_type),sqm_min=greatest(1,coalesce((p_rule->>'sqm_min')::int,sqm_min)),
      sqm_max=greatest(greatest(1,coalesce((p_rule->>'sqm_min')::int,sqm_min)),coalesce((p_rule->>'sqm_max')::int,sqm_max)),
      min_professionals=v_min,recommended_professionals=v_rec,max_professionals=v_max,
      additional_professional_fee=greatest(0,coalesce((p_rule->>'additional_professional_fee')::numeric,additional_professional_fee,0)),
      is_active=coalesce((p_rule->>'is_active')::boolean,is_active),priority=coalesce((p_rule->>'priority')::int,priority),
      metadata=(coalesce(metadata,'{}'::jsonb)||coalesce(p_rule->'metadata','{}'::jsonb))-'seed',updated_at=now() where id=v_id;
  end if;
  return to_jsonb((select x from public.service_team_rules x where x.id=v_id));
end; $$;
grant execute on function public.yt_admin_upsert_team_rule_v62(jsonb) to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 3. Estado de disponibilidad actual del Ofrecer. Domingo/horario/bloqueos
--    afectan matching sin apagar de forma permanente el switch global.
-- --------------------------------------------------------------------------
create or replace function public.yt_v62_provider_schedule_status(
  p_provider_id uuid default null,p_at timestamptz default now()
) returns jsonb
language plpgsql stable security definer set search_path=public,pg_temp as $$
declare
  v_provider uuid:=coalesce(p_provider_id,auth.uid());
  v_local timestamp:=timezone('America/Panama',coalesce(p_at,now()));
  v_date date:=v_local::date; v_time time:=v_local::time; v_dow int:=extract(dow from v_local)::int;
  v_global boolean:=false; v_today boolean:=false; v_now boolean:=false; v_reason text:='Sin horario configurado';
  v_start time; v_end time; v_exception record; v_weekly record; v_timeoff boolean:=false; v_has_exception boolean:=false;
begin
  if v_provider is null then raise exception 'Proveedor requerido'; end if;
  if auth.uid() is not null and auth.uid()<>v_provider and not public.yt_admin_is_current_admin() then raise exception 'No autorizado'; end if;
  select coalesce(is_available,false) into v_global from public.profiles where id=v_provider;
  select exists(select 1 from public.provider_time_off where provider_id=v_provider and v_date between start_date and end_date) into v_timeoff;
  select * into v_exception from public.provider_availability_exceptions where provider_id=v_provider and exception_date=v_date order by updated_at desc limit 1;
  v_has_exception:=found;
  select * into v_weekly from public.availability where provider_id=v_provider and day_of_week=v_dow order by updated_at desc limit 1;
  if not v_global then v_reason:='Disponibilidad global apagada';
  elsif v_timeoff then v_reason:='Día bloqueado o vacaciones';
  elsif v_has_exception and v_exception.id is not null then
    if coalesce(v_exception.is_available,false)=false then v_reason:=coalesce(v_exception.reason,'Día no disponible');
    else
      v_start:=coalesce(v_exception.start_time,'00:00'::time); v_end:=coalesce(v_exception.end_time,'23:59:59'::time); v_today:=true;
      v_now:=v_time between v_start and v_end; v_reason:=case when v_now then 'Disponible ahora' else 'Fuera del horario excepcional' end;
    end if;
  elsif v_weekly.id is null or coalesce(v_weekly.is_active,false)=false then v_reason:='No trabaja este día';
  else
    v_start:=nullif(v_weekly.start_time,'')::time; v_end:=nullif(v_weekly.end_time,'')::time; v_today:=true;
    v_now:=v_start is not null and v_end is not null and v_time between v_start and v_end;
    v_reason:=case when v_now then 'Disponible ahora' else 'Fuera de horario' end;
  end if;
  return jsonb_build_object('provider_id',v_provider,'global_available',v_global,'available_today',v_global and v_today and not v_timeoff,
    'available_now',v_global and v_now and not v_timeoff,'reason',v_reason,'local_date',v_date,'local_time',to_char(v_time,'HH24:MI'),
    'day_of_week',v_dow,'start_time',case when v_start is null then null else to_char(v_start,'HH24:MI') end,
    'end_time',case when v_end is null then null else to_char(v_end,'HH24:MI') end);
end; $$;
grant execute on function public.yt_v62_provider_schedule_status(uuid,timestamptz) to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 4. Un único flujo 1..5: solicitud -> N/N aceptan -> pago.
-- --------------------------------------------------------------------------
create or replace function public.yt_v62_set_booking_assignments(p_booking_id uuid,p_provider_ids uuid[])
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.bookings%rowtype; v_provider uuid; v_service uuid; v_category text; v_count int; v_slot int:=0;
begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  if auth.uid() is not null and auth.uid()<>b.buyer_id and not public.yt_admin_is_current_admin() then raise exception 'No autorizado.'; end if;
  v_count:=coalesce(array_length(p_provider_ids,1),0);
  if v_count<1 or v_count>5 then raise exception 'La reserva debe tener entre 1 y 5 profesionales.'; end if;
  select category into v_category from public.services where id=b.service_id;
  delete from public.booking_professional_assignments where booking_id=p_booking_id;
  foreach v_provider in array p_provider_ids loop
    v_slot:=v_slot+1;
    select id into v_service from public.services where provider_id=v_provider and is_active=true
      and (v_category is null or lower(coalesce(category,''))=lower(coalesce(v_category,'')))
      order by case when id=b.service_id then 0 else 1 end,updated_at desc nulls last limit 1;
    if v_service is null then raise exception 'El profesional % no tiene un servicio activo compatible.',v_provider; end if;
    insert into public.booking_professional_assignments(booking_id,provider_id,service_id,slot_number,status)
    values(p_booking_id,v_provider,v_service,v_slot,'pending');
  end loop;
  update public.bookings set required_professionals=v_count,selected_professionals=v_count,accepted_professionals=0,
    status='pending',payment_status='not_started',payment_unlocked_at=null,team_ready_at=null,provider_acceptance_at=null,updated_at=now()
  where id=p_booking_id;
  perform public.yt_v62_assignment_recalculate(p_booking_id);
  return jsonb_build_object('ok',true,'booking_id',p_booking_id,'professionals',v_count,'payment_unlocked',false);
end; $$;
grant execute on function public.yt_v62_set_booking_assignments(uuid,uuid[]) to authenticated,service_role;
create or replace function public.yt_v61_set_booking_assignments(p_booking_id uuid,p_provider_ids uuid[])
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin return public.yt_v62_set_booking_assignments(p_booking_id,p_provider_ids); end; $$;

-- Sincroniza el traslado definitivo del equipo aceptado antes de habilitar pago.
create or replace function public.yt_v62_finalize_team_travel(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.bookings%rowtype; v_distance numeric:=0; v_travel numeric:=0; v_old numeric:=0; v_delta numeric:=0; v_tax_delta numeric:=0;
begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then return jsonb_build_object('ok',false,'reason','booking_not_found'); end if;
  perform public.yt_v62_assignment_recalculate(p_booking_id);
  select coalesce(sum(travel_distance_km),0),coalesce(sum(travel_fee),0) into v_distance,v_travel
  from public.booking_professional_assignments where booking_id=p_booking_id and status in ('accepted','completed');
  v_old:=coalesce(b.travel_fee,0); v_delta:=round(v_travel-v_old,2); v_tax_delta:=round(v_delta*coalesce(b.tax_rate,0.07),2);
  update public.bookings set
    travel_distance_km=round(v_distance,2),travel_fee=round(v_travel,2),seller_payout=round(greatest(coalesce(seller_payout,0)+v_delta,0),2),
    subtotal_amount=round(greatest(coalesce(subtotal_amount,0)+v_delta,0),2),tax_amount=round(greatest(coalesce(tax_amount,0)+v_tax_delta,0),2),
    total_amount=round(greatest(coalesce(total_amount,0)+v_delta+v_tax_delta,0),2),price_snapshot=round(greatest(coalesce(price_snapshot,0)+v_delta+v_tax_delta,0),2),
    gross_total_amount=round(greatest(coalesce(gross_total_amount,total_amount,0)+v_delta+v_tax_delta,0),2),
    service_details=jsonb_set(jsonb_set(coalesce(service_details,'{}'::jsonb),'{distance_km}',to_jsonb(round(v_distance,2)),true),'{travel_fee}',to_jsonb(round(v_travel,2)),true),updated_at=now()
  where id=p_booking_id;
  perform public.yt_v62_assignment_recalculate(p_booking_id);
  return jsonb_build_object('ok',true,'distance_km',round(v_distance,2),'travel_fee',round(v_travel,2),'delta',v_delta);
end; $$;
grant execute on function public.yt_v62_finalize_team_travel(uuid) to authenticated,service_role;

create or replace function public.yt_v62_accept_booking_assignment(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.bookings%rowtype; a public.booking_professional_assignments%rowtype; v_required int; v_accepted int; v_all boolean;
begin
  select * into b from public.bookings where id=p_booking_id for update; if not found then raise exception 'Reserva no encontrada.'; end if;
  select * into a from public.booking_professional_assignments where booking_id=p_booking_id and provider_id=auth.uid() and status in ('pending','accepted') order by slot_number limit 1 for update;
  if not found then raise exception 'No tienes una asignación activa en esta reserva.'; end if;
  if coalesce(b.payment_status,'')='paid' then raise exception 'Esta solicitud ya fue pagada; la aceptación debe ocurrir antes del pago en V62.2.'; end if;
  v_required:=greatest(1,least(5,coalesce(b.required_professionals,(b.service_details->>'professionals_required')::int,1)));
  update public.booking_professional_assignments set status='accepted',accepted_at=coalesce(accepted_at,now()),rejected_at=null,rejection_reason=null,updated_at=now() where id=a.id;
  select count(*) into v_accepted from public.booking_professional_assignments where booking_id=p_booking_id and status in ('accepted','completed'); v_all:=v_accepted>=v_required;
  update public.bookings set accepted_professionals=v_accepted,team_ready_at=case when v_all then coalesce(team_ready_at,now()) else null end,
    payment_unlocked_at=case when v_all then coalesce(payment_unlocked_at,now()) else null end,
    payment_status=case when v_all then 'pending_payment' else 'not_started' end,status=case when v_all then 'pending_payment' else 'pending' end,
    provider_acceptance_at=case when v_all then coalesce(provider_acceptance_at,now()) else provider_acceptance_at end,updated_at=now() where id=p_booking_id;
  if v_all then perform public.yt_v62_finalize_team_travel(p_booking_id); else perform public.yt_v62_assignment_recalculate(p_booking_id); end if;
  return jsonb_build_object('ok',true,'slot_number',a.slot_number,'accepted',v_accepted,'required',v_required,'all_accepted',v_all,'payment_unlocked',v_all,
    'payout_amount',(select payout_amount from public.booking_professional_assignments where id=a.id));
end; $$;
grant execute on function public.yt_v62_accept_booking_assignment(uuid) to authenticated,service_role;
create or replace function public.yt_v61_accept_booking_assignment(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin return public.yt_v62_accept_booking_assignment(p_booking_id); end; $$;

-- Rechazo: reemplaza solo ese cupo usando primero el pool de hasta 15 candidatos
-- calculado por carretera y guardado en service_details.matching_candidates.
create or replace function public.yt_v62_reject_booking_assignment(p_booking_id uuid,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  b public.bookings%rowtype; a public.booking_professional_assignments%rowtype; v_required int; v_accepted int;
  v_candidate jsonb; v_provider uuid; v_service uuid; v_distance numeric:=0; v_day int; v_start time; v_end time; v_service_details jsonb;
begin
  select * into b from public.bookings where id=p_booking_id for update; if not found then raise exception 'Reserva no encontrada.'; end if;
  select * into a from public.booking_professional_assignments where booking_id=p_booking_id and provider_id=auth.uid() and status in ('pending','accepted') order by slot_number limit 1 for update;
  if not found then raise exception 'No tienes una asignación activa en esta reserva.'; end if;
  if coalesce(b.payment_status,'')='paid' then raise exception 'No se puede reemplazar un cupo después del pago por este flujo.'; end if;
  v_required:=greatest(1,least(5,coalesce(b.required_professionals,1))); v_day:=extract(dow from b.booking_date)::int;
  v_start:=coalesce(nullif(b.booking_time,'')::time,'00:00'); v_end:=v_start+make_interval(mins=>greatest(coalesce(b.duration_minutes,60),15));

  select c into v_candidate from jsonb_array_elements(coalesce(b.service_details->'matching_candidates','[]'::jsonb)) c
  join public.profiles p on p.id=(c->>'provider_id')::uuid
  where (c->>'provider_id') is not null and (c->>'provider_id')::uuid<>auth.uid()
    and coalesce(p.is_active,true)=true and coalesce(p.is_suspended,false)=false and coalesce(p.is_available,false)=true and coalesce(p.provider_status,'approved')='approved'
    and not exists(select 1 from public.booking_professional_assignments x where x.booking_id=p_booking_id and x.provider_id=(c->>'provider_id')::uuid and x.status<>'cancelled')
    and not exists(select 1 from public.provider_time_off t where t.provider_id=(c->>'provider_id')::uuid and b.booking_date between t.start_date and t.end_date)
    and (
      exists(select 1 from public.provider_availability_exceptions e where e.provider_id=(c->>'provider_id')::uuid and e.exception_date=b.booking_date and e.is_available=true and (e.start_time is null or e.start_time<=v_start) and (e.end_time is null or e.end_time>=v_end))
      or (
        not exists(select 1 from public.provider_availability_exceptions e where e.provider_id=(c->>'provider_id')::uuid and e.exception_date=b.booking_date)
        and exists(select 1 from public.availability av where av.provider_id=(c->>'provider_id')::uuid and av.day_of_week=v_day and av.is_active=true and nullif(av.start_time,'')::time<=v_start and nullif(av.end_time,'')::time>=v_end)
      )
    )
  order by coalesce((c->>'rank')::int,999),coalesce((c->>'distance_km')::numeric,999999) limit 1;

  if v_candidate is null then
    update public.booking_professional_assignments set status='rejected',rejected_at=now(),rejection_reason=coalesce(nullif(trim(p_reason),''),'Rechazada por profesional'),updated_at=now() where id=a.id;
  else
    v_provider:=(v_candidate->>'provider_id')::uuid; v_service:=nullif(v_candidate->>'service_id','')::uuid; v_distance:=coalesce((v_candidate->>'distance_km')::numeric,0);
    update public.booking_professional_assignments set provider_id=v_provider,service_id=coalesce(v_service,service_id),status='pending',accepted_at=null,rejected_at=null,rejection_reason=null,
      last_rejected_provider_id=auth.uid(),replacement_count=replacement_count+1,payout_status='pending',payout_id=null,updated_at=now() where id=a.id;
    v_service_details:=coalesce(b.service_details,'{}'::jsonb);
    v_service_details:=jsonb_set(v_service_details,array['travel_distance_by_provider',v_provider::text],to_jsonb(v_distance),true);
    v_service_details:=jsonb_set(
      v_service_details,'{travel_matches}',
      coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(v_service_details->'travel_matches','[]'::jsonb)) x where x->>'provider_id'<>auth.uid()::text),'[]'::jsonb)
      || jsonb_build_array(v_candidate),true
    );
    update public.bookings set
      provider_id=case when a.slot_number=1 then v_provider else provider_id end,
      service_id=case when a.slot_number=1 and v_service is not null then v_service else service_id end,
      service_details=v_service_details,updated_at=now()
    where id=p_booking_id;
  end if;
  select count(*) into v_accepted from public.booking_professional_assignments where booking_id=p_booking_id and status in ('accepted','completed');
  update public.bookings set accepted_professionals=v_accepted,status='pending',payment_status='not_started',payment_unlocked_at=null,team_ready_at=null,updated_at=now() where id=p_booking_id;
  perform public.yt_v62_assignment_recalculate(p_booking_id);
  return jsonb_build_object('ok',true,'replacement_found',v_provider is not null,'replacement_provider_id',v_provider,'replacement_service_id',v_service,'slot_number',a.slot_number,'accepted',v_accepted,'required',v_required);
end; $$;
grant execute on function public.yt_v62_reject_booking_assignment(uuid,text) to authenticated,service_role;
create or replace function public.yt_v61_reject_booking_assignment(p_booking_id uuid,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin return public.yt_v62_reject_booking_assignment(p_booking_id,p_reason); end; $$;

-- El checkout se bloquea también para una sola persona hasta 1/1.
create or replace function public.yt_v62_payment_order_gate()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.bookings%rowtype; v_required int; v_accepted int;
begin
  if new.booking_id is null or coalesce(new.kind,'booking')<>'booking' then return new; end if;
  select * into b from public.bookings where id=new.booking_id; if not found then return new; end if;
  v_required:=greatest(1,least(5,coalesce(b.required_professionals,1)));
  select count(*) into v_accepted from public.booking_professional_assignments where booking_id=b.id and status in ('accepted','completed');
  if v_accepted<v_required or coalesce(b.payment_status,'') not in ('pending_payment','processing','paid') then
    raise exception 'Pago bloqueado: Wissa debe confirmar %/% profesionales antes de iniciar el pago.',v_accepted,v_required;
  end if; return new;
end; $$;
drop trigger if exists trg_v62_payment_order_gate on public.payment_orders;
create trigger trg_v62_payment_order_gate before insert or update of status on public.payment_orders for each row execute function public.yt_v62_payment_order_gate();

create or replace function public.yt_v62_sync_paid_booking_team_state()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_required int; v_accepted int; begin
  if coalesce(new.payment_status,'')='paid' and coalesce(old.payment_status,'') is distinct from 'paid' then
    v_required:=greatest(1,least(5,coalesce(new.required_professionals,(new.service_details->>'professionals_required')::int,1)));
    select count(*) into v_accepted from public.booking_professional_assignments where booking_id=new.id and status in ('accepted','completed');
    if v_accepted<v_required then raise exception 'No se puede marcar pagada una reserva sin aceptación completa (%/%).',v_accepted,v_required; end if;
    update public.bookings set accepted_professionals=v_accepted,status='accepted',provider_acceptance_at=coalesce(provider_acceptance_at,now()),updated_at=now() where id=new.id;
  end if; return new;
end; $$;
drop trigger if exists trg_v62_sync_paid_team_state on public.bookings;
create trigger trg_v62_sync_paid_team_state after update of payment_status on public.bookings
for each row when (new.payment_status='paid' and old.payment_status is distinct from new.payment_status) execute function public.yt_v62_sync_paid_booking_team_state();

-- Release metadata.
insert into public.app_settings(key,value,updated_at)
values('wissa_v62_release',jsonb_build_object(
  'version','62.2','client_tabs',4,'explore_removed',true,'max_professionals_per_booking',5,'matching_pool',15,
  'all_accept_before_payment',true,'single_provider_normal_payment_flow',false,'matching_strategy','nearest_available_pool_then_slot_replacement',
  'category_commission',jsonb_build_object('cleaning',0.20,'exterior',0.20,'plumbing',0.35),
  'travel_rate_default',0.60,'travel_finalized_after_acceptance',true,'continuous_team_pricing',true,
  'loyalty_rule','every_10_completed_get_50_percent_next_service','invoice_pdf',true,'finance_snapshot',true
),now())
on conflict(key) do update set value=excluded.value,updated_at=now();

commit;
