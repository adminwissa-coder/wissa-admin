-- ==========================================================================
-- WISSA V64.1 - HYBRID PRICING / LARGE JOB TIME BLOCKS
-- 0..250 m2: formula aprobada por metraje.
-- >250 m2: bloques configurables por equipo + tiempo + precio cerrado.
-- Movilidad: un solo monto fijo por reserva; nunca USD/km.
-- Idempotente. No elimina usuarios ni reservas.
-- ==========================================================================
begin;
select pg_advisory_xact_lock(hashtext('wissa_v64_1_hybrid_pricing'));

-- --------------------------------------------------------------------------
-- 1. Snapshot operativo de cada reserva.
-- --------------------------------------------------------------------------
alter table public.bookings
  add column if not exists mobility_fee_per_booking numeric not null default 5,
  add column if not exists pricing_strategy text not null default 'metered',
  add column if not exists pricing_block_key text,
  add column if not exists estimated_service_minutes integer,
  add column if not exists service_started_at timestamptz,
  add column if not exists actual_service_minutes integer;

-- Reservas V64 existentes: la movilidad ya era total interno. Conservar el dato.
update public.bookings
set mobility_fee_per_booking = greatest(0, coalesce(nullif(mobility_fee_total,0), mobility_fee_per_professional, 5))
where mobility_fee_per_booking is null or mobility_fee_per_booking = 5;

-- Captura duración real para poder calibrar los bloques con datos operativos.
-- Funciona con cualquier RPC/UI que actualice service_stage.
create or replace function public.wissa_v64_capture_service_duration()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if new.service_stage is distinct from old.service_stage then
    if new.service_stage='in_service' and new.service_started_at is null then
      new.service_started_at:=now();
    end if;
    if new.service_stage='finished' and new.service_started_at is not null then
      new.actual_service_minutes:=greatest(1,round(extract(epoch from (now()-new.service_started_at))/60.0)::int);
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists trg_wissa_v64_capture_service_duration on public.bookings;
create trigger trg_wissa_v64_capture_service_duration
before update of service_stage on public.bookings
for each row execute function public.wissa_v64_capture_service_duration();

-- --------------------------------------------------------------------------
-- 2. Fuente de verdad de Limpieza.
--    Hasta 250 m2 se replica exactamente la especificacion aprobada:
--      1..60   = 35
--      61..120 = 35 + (m2-60)*0.28
--      121..220= 51.80 + (m2-120)*0.38
--      221..250= 89.80 + (m2-220)*1.00
-- --------------------------------------------------------------------------
update public.app_settings
set value = coalesce(value,'{}'::jsonb)
  || jsonb_build_object(
    'pricing_version',64,
    'pricing_revision','64.1-hybrid',
    'travel_mode','fixed_per_booking_internal',
    'travel_rate_per_km',0,
    'mobility_fee_per_booking',coalesce(nullif(value->>'mobility_fee_per_booking','')::numeric,nullif(value->>'mobility_fee_per_professional','')::numeric,5),
    -- Campo legacy sincronizado para clientes anteriores. Ya no se multiplica por equipo.
    'mobility_fee_per_professional',coalesce(nullif(value->>'mobility_fee_per_booking','')::numeric,nullif(value->>'mobility_fee_per_professional','')::numeric,5),
    'hide_mobility_from_customer_breakdown',true,
    'pricing_strategy','metered_to_250_then_time_blocks',
    'parametric_engine',jsonb_build_object(
      'minimum_price',35,
      'minimum_included_sqm',60,
      'tier1_end_sqm',120,
      'tier1_rate_per_sqm',0.28,
      'tier2_end_sqm',220,
      'tier2_rate_per_sqm',0.38,
      'team_threshold_sqm',250,
      'team_base_price',89.80,
      'team_rate_per_sqm',1.00,
      'continuous_team_pricing',true,
      'quote_threshold_sqm',700,
      'deep_cleaning_rate_per_sqm',0.15,
      'professionals_at_team_threshold',2,
      'max_professionals',5
    ),
    -- Los precios de trabajos >250 m2 quedan en 0 deliberadamente: la arquitectura
    -- esta lista, pero Wissa no debe inventar un precio hasta que negocio lo defina.
    'large_job_blocks',jsonb_build_array(
      jsonb_build_object(
        'key','251_350','label','Más de 250 a 350 m²','min_sqm',250,'max_sqm',350,
        'professionals',2,'estimated_hours',4,'standard_price',0,'deep_price',0,'active',true
      ),
      jsonb_build_object(
        'key','351_500','label','Más de 350 a 500 m²','min_sqm',350,'max_sqm',500,
        'professionals',2,'estimated_hours',6,'standard_price',0,'deep_price',0,'active',true
      ),
      jsonb_build_object(
        'key','501_700','label','Más de 500 a 700 m²','min_sqm',500,'max_sqm',700,
        'professionals',3,'estimated_hours',6,'standard_price',0,'deep_price',0,'active',true
      )
    )
  ),
  updated_at=now()
where key='cleaning_pricing';

-- Movilidad fija por reserva para las demás categorías. No se cambia su motor de precio.
update public.app_settings
set value = coalesce(value,'{}'::jsonb)
  || jsonb_build_object(
    'pricing_version',64,
    'pricing_revision','64.1-fixed-mobility',
    'travel_mode','fixed_per_booking_internal',
    'travel_rate_per_km',0,
    'mobility_fee_per_booking',coalesce(nullif(value->>'mobility_fee_per_booking','')::numeric,nullif(value->>'mobility_fee_per_professional','')::numeric,5),
    'mobility_fee_per_professional',coalesce(nullif(value->>'mobility_fee_per_booking','')::numeric,nullif(value->>'mobility_fee_per_professional','')::numeric,5),
    'hide_mobility_from_customer_breakdown',true
  ),
  updated_at=now()
where key in ('exterior_cleaning_pricing','plumbing_pricing');

-- --------------------------------------------------------------------------
-- 3. Metadata de negocio. No contiene texto QA visible al usuario.
-- --------------------------------------------------------------------------
insert into public.app_settings(key,value,updated_at)
values(
  'wissa_hybrid_pricing',
  jsonb_build_object(
    'revision','64.1',
    'metered_max_sqm',250,
    'large_job_mode','team_time_blocks',
    'large_job_team_is_system_defined',true,
    'candidate_count_is_separate_from_worker_count',true,
    'mobility_mode','fixed_per_booking',
    'mobility_default',5,
    'collect_estimated_duration',true,
    'collect_actual_duration_when_available',true
  ),
  now()
)
on conflict(key) do update set value=excluded.value,updated_at=now();

-- --------------------------------------------------------------------------
-- 4. Reasignación automática para reservas normales (1 profesional final).
--    La primera ronda sigue siendo elegida por el cliente. Si la ronda vence
--    sin aceptación, Wissa usa el resto del pool guardado al crear la reserva.
-- --------------------------------------------------------------------------
alter table public.bookings
  add column if not exists candidate_attempted_provider_ids uuid[] not null default '{}'::uuid[];

-- Recupera historial de intentos existente antes de instalar esta revisión.
update public.bookings b
set candidate_attempted_provider_ids = x.provider_ids
from (
  select booking_id, array_agg(distinct provider_id) filter (where provider_id is not null) as provider_ids
  from public.booking_professional_assignments
  group by booking_id
) x
where x.booking_id=b.id
  and coalesce(cardinality(b.candidate_attempted_provider_ids),0)=0
  and coalesce(cardinality(x.provider_ids),0)>0;

create or replace function public.wissa_v64_track_candidate_attempt()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  update public.bookings b
  set candidate_attempted_provider_ids = array(
        select distinct candidate_id
        from unnest(coalesce(b.candidate_attempted_provider_ids,'{}'::uuid[]) || array[new.provider_id]) candidate_id
        where candidate_id is not null
      ),
      updated_at=now()
  where b.id=new.booking_id;
  return new;
end; $$;

drop trigger if exists trg_wissa_v64_track_candidate_attempt on public.booking_professional_assignments;
create trigger trg_wissa_v64_track_candidate_attempt
after insert on public.booking_professional_assignments
for each row execute function public.wissa_v64_track_candidate_attempt();

-- El tiempo de respuesta se administra desde wissa_matching. Así no queda
-- hardcodeado en Mobile ni en la función de selección inicial.
create or replace function public.wissa_v64_set_invitation_expiry()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_minutes integer:=5; begin
  select greatest(1,least(60,coalesce((value->>'response_timeout_minutes')::integer,5)))
  into v_minutes
  from public.app_settings where key='wissa_matching';
  v_minutes:=coalesce(v_minutes,5);
  new.invitation_expires_at:=now()+make_interval(mins=>v_minutes);
  return new;
exception when others then
  new.invitation_expires_at:=now()+interval '5 minutes';
  return new;
end; $$;

drop trigger if exists trg_wissa_v64_set_invitation_expiry on public.booking_professional_assignments;
create trigger trg_wissa_v64_set_invitation_expiry
before insert on public.booking_professional_assignments
for each row when (new.status='pending')
execute function public.wissa_v64_set_invitation_expiry();

create or replace function public.yt_v64_auto_reassign_booking(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  b public.bookings%rowtype;
  v_required integer;
  v_accepted integer:=0;
  v_pending integer:=0;
  v_round integer:=0;
  v_inserted integer:=0;
  v_provider uuid;
  v_service uuid;
  v_candidate jsonb;
  v_attempted uuid[]:='{}'::uuid[];
  v_buyer_name text:='Cliente Wissa';
  v_title text:='Servicio Wissa';
begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then return jsonb_build_object('ok',false,'reason','not_found'); end if;
  if coalesce(b.payment_status,'')<>'paid' then return jsonb_build_object('ok',false,'reason','payment_pending'); end if;

  v_required:=greatest(1,least(5,coalesce(b.required_professionals,1)));
  -- El fallback automático solicitado aplica al flujo normal: dos candidatos,
  -- un solo profesional final. Los equipos reales conservan el motor 2..5.
  if v_required<>1 then return jsonb_build_object('ok',true,'reassigned',false,'reason','team_flow'); end if;
  if coalesce(b.status,'') in ('completed','completed_pending_release','cancelled','rejected') then
    return jsonb_build_object('ok',true,'reassigned',false,'reason','closed');
  end if;

  select count(*) into v_accepted
  from public.booking_professional_assignments
  where booking_id=p_booking_id and status in ('accepted','completed');
  if v_accepted>0 then return jsonb_build_object('ok',true,'reassigned',false,'reason','already_confirmed'); end if;

  -- Si todavía hay una invitación vigente, no iniciar otra ronda.
  select count(*) into v_pending
  from public.booking_professional_assignments
  where booking_id=p_booking_id and status='pending'
    and coalesce(invitation_expires_at,now()+interval '1 minute')>now();
  if v_pending>0 then return jsonb_build_object('ok',true,'reassigned',false,'reason','waiting_response'); end if;

  -- Cierra la ronda vencida y libera los slots 1..5 para la siguiente.
  update public.booking_professional_assignments
  set status='cancelled',rejected_at=coalesce(rejected_at,now()),
      rejection_reason=coalesce(nullif(rejection_reason,''),'Tiempo de respuesta agotado'),updated_at=now()
  where booking_id=p_booking_id and status='pending';

  delete from public.booking_professional_assignments
  where booking_id=p_booking_id and status in ('cancelled','rejected');

  v_attempted:=coalesce(b.candidate_attempted_provider_ids,'{}'::uuid[]);
  v_round:=greatest(coalesce(b.candidate_round,0)+1,1);

  for v_candidate in
    select c.item
    from jsonb_array_elements(coalesce(b.service_details->'matching_candidates','[]'::jsonb)) with ordinality c(item,ord)
    where coalesce(c.item->>'provider_id','') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    order by coalesce(nullif(c.item->>'rank','')::integer,c.ord::integer),c.ord
  loop
    exit when v_inserted>=2;
    v_provider:=(v_candidate->>'provider_id')::uuid;
    continue when v_provider=any(v_attempted);

    if not exists(
      select 1 from public.profiles p
      where p.id=v_provider
        and coalesce(p.is_active,true)=true
        and coalesce(p.is_suspended,false)=false
        and coalesce(p.provider_status,'approved')='approved'
        and coalesce(p.is_available,false)=true
        and coalesce(p.latitude,p.lat) is not null
        and coalesce(p.longitude,p.lng) is not null
    ) then continue; end if;

    v_service:=null;
    begin
      v_service:=nullif(v_candidate->>'service_id','')::uuid;
    exception when others then
      v_service:=null;
    end;
    if v_service is null or not exists(
      select 1 from public.services s where s.id=v_service and s.provider_id=v_provider and coalesce(s.is_active,true)=true
    ) then
      select s.id into v_service from public.services s
      where s.provider_id=v_provider and coalesce(s.is_active,true)=true
        and (coalesce(b.service_details->>'category','')='' or lower(coalesce(s.category,''))=lower(coalesce(b.service_details->>'category','')))
      order by case when s.id=b.service_id then 0 else 1 end,s.updated_at desc nulls last limit 1;
    end if;
    continue when v_service is null;

    v_inserted:=v_inserted+1;
    insert into public.booking_professional_assignments(
      booking_id,provider_id,service_id,slot_number,status,invitation_round,invitation_source
    ) values(
      p_booking_id,v_provider,v_service,v_inserted,'pending',v_round,'automatic_reassignment'
    );
    v_attempted:=array_append(v_attempted,v_provider);
  end loop;

  if v_inserted>0 then
    update public.bookings
    set candidate_round=v_round,
        selected_professionals=v_inserted,
        candidate_selection_status='waiting_acceptance',
        candidate_selected_at=now(),
        candidate_attempted_provider_ids=v_attempted,
        updated_at=now()
    where id=p_booking_id;

    select coalesce(p.full_name,p.display_name,'Cliente Wissa') into v_buyer_name from public.profiles p where p.id=b.buyer_id;
    select coalesce(s.title,b.service_title,'Servicio Wissa') into v_title from public.services s where s.id=b.service_id;

    insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read,created_at)
    select a.provider_id,'Nueva solicitud de '||v_buyer_name,
           coalesce(v_title,'Servicio Wissa')||' · Reserva pagada. Confirma si puedes realizarla.',
           'booking_request','/main/booking/'||p_booking_id::text,p_booking_id,
           jsonb_build_object('booking_id',p_booking_id,'buyer_name',v_buyer_name,'round',v_round,'automatic',true),false,now()
    from public.booking_professional_assignments a
    where a.booking_id=p_booking_id and a.status='pending' and a.invitation_round=v_round;

    insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read,created_at)
    values(
      b.buyer_id,'Seguimos buscando',
      'Enviamos tu solicitud a nuevas opciones disponibles. Te avisaremos cuando un profesional confirme.',
      'booking_reassign','/main/booking/'||p_booking_id::text,p_booking_id,
      jsonb_build_object('booking_id',p_booking_id,'round',v_round),false,now()
    );

    return jsonb_build_object('ok',true,'reassigned',true,'round',v_round,'invited',v_inserted);
  end if;

  update public.bookings
  set candidate_selection_status='needs_reassignment',updated_at=now()
  where id=p_booking_id;

  return jsonb_build_object('ok',true,'reassigned',false,'reason','candidate_pool_exhausted');
end; $$;
revoke all on function public.yt_v64_auto_reassign_booking(uuid) from public,anon,authenticated;
grant execute on function public.yt_v64_auto_reassign_booking(uuid) to service_role;

-- Endpoint seguro para que el cliente refresque su propia reserva. El motor solo
-- actúa si la ronda realmente venció; abrir la pantalla no salta el temporizador.
create or replace function public.yt_v64_refresh_candidate_round(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.bookings%rowtype; begin
  select * into b from public.bookings where id=p_booking_id;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  if auth.uid() is null or (auth.uid()<>b.buyer_id and not public.yt_admin_is_current_admin()) then
    return jsonb_build_object('ok',false,'reason','not_applicable');
  end if;
  return public.yt_v64_auto_reassign_booking(p_booking_id);
end; $$;
grant execute on function public.yt_v64_refresh_candidate_round(uuid) to authenticated,service_role;

-- Procesador para Supabase Cron. Si pg_cron ya está habilitado se programa cada
-- minuto; si no está habilitado, el RPC seguro de arriba mantiene el fallback al
-- abrir/refrescar el detalle y la función queda lista para activarla desde Cron.
create or replace function public.yt_v64_process_expired_candidate_rounds()
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare r record; v_count integer:=0; v_result jsonb; begin
  for r in
    select b.id
    from public.bookings b
    where coalesce(b.payment_status,'')='paid'
      and greatest(1,least(5,coalesce(b.required_professionals,1)))=1
      and coalesce(b.status,'')='paid_pending_acceptance'
      and coalesce(b.candidate_selection_status,'') in ('waiting_acceptance','needs_reassignment')
      and not exists(
        select 1 from public.booking_professional_assignments a
        where a.booking_id=b.id and a.status in ('accepted','completed')
      )
      and (
        coalesce(b.candidate_selection_status,'')='needs_reassignment'
        or not exists(
          select 1 from public.booking_professional_assignments a
          where a.booking_id=b.id and a.status='pending'
            and coalesce(a.invitation_expires_at,now()+interval '1 minute')>now()
        )
      )
    order by b.updated_at
    limit 100
  loop
    v_result:=public.yt_v64_auto_reassign_booking(r.id);
    if coalesce((v_result->>'reassigned')::boolean,false) then v_count:=v_count+1; end if;
  end loop;
  return v_count;
end; $$;
revoke all on function public.yt_v64_process_expired_candidate_rounds() from public,anon,authenticated;
grant execute on function public.yt_v64_process_expired_candidate_rounds() to service_role;

-- Actualiza parámetros de negocio sin exponer nombres técnicos en Admin.
update public.app_settings
set value=coalesce(value,'{}'::jsonb)||jsonb_build_object(
  'automatic_reassignment',true,
  'fallback_source','booking_candidate_pool'
),updated_at=now()
where key='wissa_matching';

-- Programa el worker solo cuando pg_cron ya existe en el proyecto. No intenta
-- instalar extensiones ni falla la migración si Cron no está habilitado.
do $$
declare v_job bigint; begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    begin
      execute 'select jobid from cron.job where jobname=''wissa-v64-candidate-fallback'' limit 1' into v_job;
      if v_job is not null then execute format('select cron.unschedule(%s)',v_job); end if;
      execute $cron$select cron.schedule('wissa-v64-candidate-fallback','* * * * *','select public.yt_v64_process_expired_candidate_rounds();')$cron$;
    exception when others then
      null;
    end;
  end if;
end $$;

-- --------------------------------------------------------------------------
-- 5. Administración de cobertura y tiempo de respuesta.
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_matching_settings_json()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v jsonb; begin
  if not public.yt_admin_is_current_admin() then raise exception 'No autorizado.'; end if;
  select coalesce(value,'{}'::jsonb) into v from public.app_settings where key='wissa_matching';
  return coalesce(v,'{}'::jsonb);
end; $$;
grant execute on function public.yt_admin_matching_settings_json() to authenticated,service_role;

create or replace function public.yt_admin_update_matching_settings(
  p_primary_radius_km numeric,
  p_extended_radius_km numeric,
  p_response_timeout_minutes integer,
  p_max_candidates_to_evaluate integer default 15
)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v jsonb; begin
  if not public.yt_admin_is_current_admin() then raise exception 'No autorizado.'; end if;
  if coalesce(p_primary_radius_km,0)<=0 then raise exception 'La cobertura inicial debe ser mayor que cero.'; end if;
  if coalesce(p_extended_radius_km,0)<p_primary_radius_km then raise exception 'La cobertura ampliada no puede ser menor que la inicial.'; end if;

  update public.app_settings
  set value=coalesce(value,'{}'::jsonb)||jsonb_build_object(
      'primary_radius_km',round(greatest(1,least(200,p_primary_radius_km)),2),
      'extended_radius_km',round(greatest(p_primary_radius_km,least(300,p_extended_radius_km)),2),
      'response_timeout_minutes',greatest(1,least(60,coalesce(p_response_timeout_minutes,5))),
      'max_candidates_to_evaluate',greatest(3,least(30,coalesce(p_max_candidates_to_evaluate,15))),
      'candidate_display_count',3,
      'candidate_select_count',2,
      'provider_location_required',true,
      'automatic_reassignment',true
    ),updated_at=now()
  where key='wissa_matching'
  returning value into v;

  if v is null then
    insert into public.app_settings(key,value,updated_at)
    values('wissa_matching',jsonb_build_object(
      'primary_radius_km',round(greatest(1,least(200,p_primary_radius_km)),2),
      'extended_radius_km',round(greatest(p_primary_radius_km,least(300,p_extended_radius_km)),2),
      'response_timeout_minutes',greatest(1,least(60,coalesce(p_response_timeout_minutes,5))),
      'max_candidates_to_evaluate',greatest(3,least(30,coalesce(p_max_candidates_to_evaluate,15))),
      'candidate_display_count',3,'candidate_select_count',2,
      'provider_location_required',true,'automatic_reassignment',true
    ),now()) returning value into v;
  end if;
  return v;
end; $$;
grant execute on function public.yt_admin_update_matching_settings(numeric,numeric,integer,integer) to authenticated,service_role;

commit;
