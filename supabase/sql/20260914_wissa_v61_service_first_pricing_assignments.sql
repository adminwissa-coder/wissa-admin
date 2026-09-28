-- ============================================================================
-- WISSA V61.0 - SERVICE FIRST + MOTOR PARAMETRICO + MULTI PROFESIONAL
-- Fecha: 2026-09-14
-- Incremental e idempotente. No elimina usuarios, reservas, pagos ni historicos.
-- Mantiene traslado por carretera; valor inicial USD 0.60/km, administrable.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Pricing V61: defaults administrables, no valores quemados.
-- --------------------------------------------------------------------------
create or replace function public.yt_v60_apply_pricing_rules(p_key text, p_value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_key text := lower(trim(coalesce(p_key, '')));
  v_value jsonb := coalesce(p_value, '{}'::jsonb);
  v_default_commission numeric := case when v_key='plumbing_pricing' then 0.35 else 0.20 end;
  v_commission numeric;
  v_travel numeric;
  v_platform numeric;
  v_tax numeric;
  v_inspection numeric;
  v_engine jsonb;
begin
  if jsonb_typeof(v_value) <> 'object' then v_value := '{}'::jsonb; end if;

  v_commission := greatest(0, least(1, coalesce(nullif(v_value->>'platform_commission_rate','')::numeric, v_default_commission)));
  v_travel := greatest(0, coalesce(nullif(v_value->>'travel_rate_per_km','')::numeric, 0.60));
  v_platform := greatest(0, coalesce(nullif(v_value->>'platform_usage_fee','')::numeric, 2.00));
  v_tax := greatest(0, least(1, coalesce(nullif(v_value->>'itbms_rate','')::numeric, nullif(v_value->>'tax_rate','')::numeric, 0.07)));

  v_value := jsonb_set(v_value, '{pricing_version}', '61'::jsonb, true);
  v_value := jsonb_set(v_value, '{travel_mode}', '"road_distance"'::jsonb, true);
  v_value := jsonb_set(v_value, '{travel_flat_fee}', '0'::jsonb, true);
  v_value := jsonb_set(v_value, '{travel_rate_per_km}', to_jsonb(v_travel), true);
  v_value := jsonb_set(v_value, '{platform_usage_fee}', to_jsonb(v_platform), true);
  v_value := jsonb_set(v_value, '{itbms_rate}', to_jsonb(v_tax), true);
  v_value := jsonb_set(v_value, '{tax_rate}', to_jsonb(v_tax), true);
  v_value := jsonb_set(v_value, '{platform_commission_rate}', to_jsonb(v_commission), true);

  if v_key = 'cleaning_pricing' then
    v_engine := jsonb_build_object(
      'minimum_price', 35,
      'minimum_included_sqm', 70,
      'tier1_end_sqm', 130,
      'tier1_rate_per_sqm', 0.2815,
      'tier2_end_sqm', 249,
      'tier2_rate_per_sqm', 0.38,
      'team_threshold_sqm', 250,
      'team_base_price', 250,
      'team_rate_per_sqm', 0.70,
      'quote_threshold_sqm', 400,
      'deep_cleaning_rate_per_sqm', 0.15,
      'professionals_at_team_threshold', 2,
      'max_professionals', 15
    ) || coalesce(v_value->'parametric_engine', '{}'::jsonb);
    v_value := jsonb_set(v_value, '{parametric_engine}', v_engine, true);
    v_value := jsonb_set(v_value, '{pricing_mode}', '"parametric_cleaning_v61"'::jsonb, true);
    v_value := jsonb_set(v_value, '{fixed_service_price}', to_jsonb(greatest(0, coalesce(nullif(v_engine->>'minimum_price','')::numeric,35))), true);
    v_value := jsonb_set(v_value, '{fixed_service_prices,basica}', to_jsonb(greatest(0, coalesce(nullif(v_engine->>'minimum_price','')::numeric,35))), true);
    v_value := jsonb_set(v_value, '{fixed_service_prices,premium}', to_jsonb(greatest(0, coalesce(nullif(v_engine->>'minimum_price','')::numeric,35))), true);
    return v_value;
  end if;

  if v_key = 'plumbing_pricing' then
    v_inspection := greatest(coalesce(
      nullif(v_value->>'inspection_fee','')::numeric,
      nullif(v_value #>> '{job_base,revision}','')::numeric,
      25
    ), 0);
    v_value := jsonb_set(v_value, '{pricing_mode}', '"inspection_road_v61"'::jsonb, true);
    v_value := jsonb_set(v_value, '{inspection_fee}', to_jsonb(v_inspection), true);
    v_value := jsonb_set(v_value, '{job_base,revision}', to_jsonb(v_inspection), true);
    v_value := jsonb_set(v_value, '{quote_after_inspection}', 'false'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,enabled}', 'false'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,basic,price}', '0'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,premium,price}', '0'::jsonb, true);
    v_value := jsonb_set(v_value, '{plumbing_mode}', '"diagnosis_only"'::jsonb, true);
    return v_value;
  end if;

  if v_key = 'exterior_cleaning_pricing' then
    v_value := jsonb_set(v_value, '{pricing_mode}', '"fixed_service_road_v61"'::jsonb, true);
    return v_value;
  end if;

  return v_value;
exception when others then
  return coalesce(p_value, '{}'::jsonb);
end;
$$;

grant execute on function public.yt_v60_apply_pricing_rules(text,jsonb) to anon, authenticated, service_role;

update public.app_settings a
set value = public.yt_v60_apply_pricing_rules(a.key, a.value), updated_at=now()
where a.key in ('cleaning_pricing','exterior_cleaning_pricing','plumbing_pricing');

insert into public.app_settings(key,value,updated_at)
values (
  'cleaning_pricing',
  public.yt_v60_apply_pricing_rules('cleaning_pricing', jsonb_build_object('currency','USD')),
  now()
)
on conflict(key) do nothing;

-- Actualiza la configuración visible de Limpieza sin borrar otros campos dinámicos.
update public.service_category_fields
set label='Tipo de limpieza',
    label_en='Cleaning type',
    options='["Limpieza estándar","Limpieza profunda"]'::jsonb,
    options_en='["Standard cleaning","Deep cleaning"]'::jsonb,
    is_active=true,
    updated_at=now()
where lower(coalesce(category_name,''))='limpieza'
  and lower(coalesce(field_key,''))='cleaning_plan';

update public.service_category_fields
set label='Área aproximada en m²',
    label_en='Approximate area in m²',
    is_active=true,
    updated_at=now()
where lower(coalesce(category_name,''))='limpieza'
  and lower(coalesce(field_key,''))='square_meters';

-- --------------------------------------------------------------------------
-- 2. Una reserva, múltiples asignaciones profesionales (máximo 15).
-- --------------------------------------------------------------------------
create table if not exists public.booking_professional_assignments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  provider_id uuid not null references public.profiles(id),
  service_id uuid references public.services(id),
  slot_number integer not null check (slot_number between 1 and 15),
  status text not null default 'pending' check (status in ('pending','accepted','rejected','completed','cancelled')),
  service_share numeric not null default 0,
  travel_distance_km numeric not null default 0,
  travel_fee numeric not null default 0,
  payout_amount numeric not null default 0,
  accepted_at timestamptz,
  rejected_at timestamptz,
  completed_at timestamptz,
  rejection_reason text,
  replacement_count integer not null default 0,
  last_rejected_provider_id uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(booking_id,slot_number)
);

create index if not exists booking_professional_assignments_provider_idx
  on public.booking_professional_assignments(provider_id,status,created_at desc);
create index if not exists booking_professional_assignments_booking_idx
  on public.booking_professional_assignments(booking_id,slot_number);

alter table public.booking_professional_assignments enable row level security;

drop policy if exists "v61_assignment_select" on public.booking_professional_assignments;
create policy "v61_assignment_select"
on public.booking_professional_assignments for select
to authenticated
using (
  provider_id=auth.uid()
  or exists(select 1 from public.bookings b where b.id=booking_id and b.buyer_id=auth.uid())
  or public.yt_admin_is_current_admin()
);

-- Lectura de la reserva para profesionales secundarios asignados.
drop policy if exists "v61_assigned_provider_booking_select" on public.bookings;
create policy "v61_assigned_provider_booking_select"
on public.bookings for select
to authenticated
using (
  exists (
    select 1 from public.booking_professional_assignments a
    where a.booking_id=bookings.id and a.provider_id=auth.uid() and a.status <> 'cancelled'
  )
);

create or replace function public.yt_v61_assignment_recalculate(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_booking public.bookings%rowtype;
  v_count integer;
  v_service_pool numeric;
  v_default_service_share numeric;
  v_travel_map jsonb;
  v_distance numeric;
  v_rate numeric;
  r record;
begin
  select * into v_booking from public.bookings where id=p_booking_id;
  if not found then return; end if;

  select count(*) into v_count
  from public.booking_professional_assignments
  where booking_id=p_booking_id and status <> 'cancelled';
  if v_count <= 0 then return; end if;

  v_service_pool := greatest(coalesce(v_booking.seller_payout,0) - coalesce(v_booking.travel_fee,0),0);
  v_default_service_share := round(v_service_pool / v_count, 2);
  v_travel_map := coalesce(v_booking.service_details->'travel_distance_by_provider','{}'::jsonb);
  v_rate := greatest(coalesce(v_booking.travel_rate_per_km,0.60),0);

  for r in
    select id, provider_id from public.booking_professional_assignments
    where booking_id=p_booking_id and status <> 'cancelled'
  loop
    v_distance := greatest(coalesce(nullif(v_travel_map->>r.provider_id::text,'')::numeric,0),0);
    update public.booking_professional_assignments
    set service_share=v_default_service_share,
        travel_distance_km=v_distance,
        travel_fee=round(v_distance*v_rate,2),
        payout_amount=round(v_default_service_share + (v_distance*v_rate),2),
        updated_at=now()
    where id=r.id;
  end loop;
end;
$$;

revoke execute on function public.yt_v61_assignment_recalculate(uuid) from public, anon;
grant execute on function public.yt_v61_assignment_recalculate(uuid) to authenticated, service_role;

create or replace function public.yt_v61_set_booking_assignments(p_booking_id uuid, p_provider_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_booking public.bookings%rowtype;
  v_provider uuid;
  v_service_id uuid;
  v_category text;
  v_count integer;
  v_slot integer := 0;
begin
  select * into v_booking from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  if auth.uid() is null or (auth.uid() <> v_booking.buyer_id and not public.yt_admin_is_current_admin()) then
    raise exception 'No autorizado para asignar profesionales.';
  end if;

  v_count := coalesce(array_length(p_provider_ids,1),0);
  if v_count < 1 or v_count > 15 then raise exception 'La reserva debe tener entre 1 y 15 profesionales.'; end if;

  select s.category into v_category from public.services s where s.id=v_booking.service_id;
  delete from public.booking_professional_assignments where booking_id=p_booking_id;

  foreach v_provider in array p_provider_ids loop
    v_slot := v_slot + 1;
    if v_provider is null then raise exception 'Proveedor inválido.'; end if;

    select s.id into v_service_id
    from public.services s
    where s.provider_id=v_provider
      and s.is_active=true
      and (
        v_category is null
        or lower(coalesce(s.category,''))=lower(coalesce(v_category,''))
      )
    order by case when s.id=v_booking.service_id then 0 else 1 end, s.updated_at desc nulls last
    limit 1;

    if v_service_id is null then
      raise exception 'El profesional % no tiene un servicio activo compatible.', v_provider;
    end if;

    insert into public.booking_professional_assignments(booking_id,provider_id,service_id,slot_number,status)
    values(p_booking_id,v_provider,v_service_id,v_slot,'pending');
  end loop;

  perform public.yt_v61_assignment_recalculate(p_booking_id);

  return jsonb_build_object(
    'ok',true,
    'booking_id',p_booking_id,
    'professionals',v_count,
    'provider_ids',to_jsonb(p_provider_ids)
  );
end;
$$;

revoke execute on function public.yt_v61_set_booking_assignments(uuid,uuid[]) from public, anon;
grant execute on function public.yt_v61_set_booking_assignments(uuid,uuid[]) to authenticated, service_role;

create or replace function public.yt_v61_accept_booking_assignment(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_booking public.bookings%rowtype;
  v_assignment public.booking_professional_assignments%rowtype;
  v_pending integer;
begin
  select * into v_booking from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  if coalesce(v_booking.payment_status,'') <> 'paid' then raise exception 'La reserva aún no tiene pago aprobado.'; end if;

  select * into v_assignment
  from public.booking_professional_assignments
  where booking_id=p_booking_id and provider_id=auth.uid() and status in ('pending','accepted')
  order by slot_number limit 1 for update;
  if not found then raise exception 'No tienes una asignación activa en esta reserva.'; end if;

  update public.booking_professional_assignments
  set status='accepted', accepted_at=coalesce(accepted_at,now()), rejected_at=null, rejection_reason=null, updated_at=now()
  where id=v_assignment.id;

  select count(*) into v_pending
  from public.booking_professional_assignments
  where booking_id=p_booking_id and status not in ('accepted','completed','cancelled');

  if v_pending=0 then
    update public.bookings
    set status='accepted', provider_acceptance_at=coalesce(provider_acceptance_at,now()), updated_at=now()
    where id=p_booking_id and status in ('paid_pending_acceptance','pending','pending_payment','accepted');
  end if;

  return jsonb_build_object('ok',true,'all_accepted',v_pending=0,'slot_number',v_assignment.slot_number,'payout_amount',v_assignment.payout_amount);
end;
$$;

revoke execute on function public.yt_v61_accept_booking_assignment(uuid) from public, anon;
grant execute on function public.yt_v61_accept_booking_assignment(uuid) to authenticated, service_role;

create or replace function public.yt_v61_reject_booking_assignment(p_booking_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_booking public.bookings%rowtype;
  v_assignment public.booking_professional_assignments%rowtype;
  v_category text;
  v_replacement_provider uuid;
  v_replacement_service uuid;
  v_day integer;
  v_start time;
  v_end time;
begin
  select * into v_booking from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;

  select * into v_assignment
  from public.booking_professional_assignments
  where booking_id=p_booking_id and provider_id=auth.uid() and status in ('pending','accepted')
  order by slot_number limit 1 for update;
  if not found then raise exception 'No tienes una asignación activa en esta reserva.'; end if;

  select s.category into v_category from public.services s where s.id=coalesce(v_assignment.service_id,v_booking.service_id);
  v_day := extract(dow from v_booking.booking_date)::integer;
  v_start := coalesce(nullif(v_booking.booking_time,'')::time,'00:00'::time);
  v_end := v_start + make_interval(mins => greatest(coalesce(v_booking.duration_minutes,60),15));

  -- Busca solo el cupo rechazado. No cancela ni duplica la reserva.
  select s.provider_id, s.id
  into v_replacement_provider, v_replacement_service
  from public.services s
  join public.profiles p on p.id=s.provider_id
  where s.is_active=true
    and coalesce(s.source_type,'marketplace')='marketplace'
    and lower(coalesce(s.category,''))=lower(coalesce(v_category,''))
    and coalesce(p.is_active,true)=true
    and coalesce(p.is_suspended,false)=false
    and coalesce(p.is_available,false)=true
    and s.provider_id <> auth.uid()
    and not exists (
      select 1 from public.booking_professional_assignments x
      where x.booking_id=p_booking_id and x.provider_id=s.provider_id and x.status <> 'cancelled'
    )
    and exists (
      select 1 from public.availability av
      where av.provider_id=s.provider_id and av.is_active=true and av.day_of_week=v_day
        and nullif(av.start_time,'')::time <= v_start
        and nullif(av.end_time,'')::time >= v_end
    )
    and not exists (
      select 1 from public.provider_time_off t
      where t.provider_id=s.provider_id and v_booking.booking_date between t.start_date and t.end_date
    )
  order by coalesce(p.rating_avg,0) desc, s.updated_at desc nulls last
  limit 1;

  if v_replacement_provider is null then
    update public.booking_professional_assignments
    set status='rejected', rejected_at=now(), rejection_reason=coalesce(nullif(trim(p_reason),''),'Rechazada por profesional'), updated_at=now()
    where id=v_assignment.id;

    return jsonb_build_object('ok',true,'replacement_found',false,'slot_number',v_assignment.slot_number);
  end if;

  update public.booking_professional_assignments
  set provider_id=v_replacement_provider,
      service_id=v_replacement_service,
      status='pending',
      accepted_at=null,
      rejected_at=null,
      rejection_reason=null,
      last_rejected_provider_id=auth.uid(),
      replacement_count=replacement_count+1,
      updated_at=now()
  where id=v_assignment.id;

  -- Slot 1 sigue alimentando columnas legacy para compatibilidad con pantallas/pagos existentes.
  if v_assignment.slot_number=1 then
    update public.bookings
    set provider_id=v_replacement_provider, service_id=v_replacement_service, status='paid_pending_acceptance', updated_at=now()
    where id=p_booking_id;
  else
    update public.bookings set status='paid_pending_acceptance', updated_at=now() where id=p_booking_id;
  end if;

  perform public.yt_v61_assignment_recalculate(p_booking_id);

  return jsonb_build_object(
    'ok',true,
    'replacement_found',true,
    'slot_number',v_assignment.slot_number,
    'replacement_provider_id',v_replacement_provider,
    'replacement_service_id',v_replacement_service
  );
end;
$$;

revoke execute on function public.yt_v61_reject_booking_assignment(uuid,text) from public, anon;
grant execute on function public.yt_v61_reject_booking_assignment(uuid,text) to authenticated, service_role;

create or replace function public.yt_v61_verify_booking_confirmation_code(p_booking_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_booking public.bookings%rowtype;
  v_assignment public.booking_professional_assignments%rowtype;
  v_remaining integer;
begin
  select * into v_booking from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'No se encontró la reserva.'; end if;
  if coalesce(v_booking.payment_status,'') <> 'paid' then raise exception 'La reserva aún no tiene pago aprobado.'; end if;
  if v_booking.status <> 'accepted' then raise exception 'La reserva debe estar aceptada antes de validar el cierre.'; end if;
  if not coalesce(v_booking.buyer_confirmed,false) then raise exception 'El cliente todavía no inició el cierre del servicio.'; end if;
  if coalesce(v_booking.confirmation_code,'')='' then raise exception 'El código de cierre todavía no está disponible.'; end if;
  if coalesce(v_booking.confirmation_code,'') <> trim(coalesce(p_code,'')) then raise exception 'El código no coincide.'; end if;

  select * into v_assignment
  from public.booking_professional_assignments
  where booking_id=p_booking_id and provider_id=auth.uid() and status in ('accepted','completed')
  order by slot_number limit 1 for update;
  if not found then raise exception 'No tienes una asignación aceptada en esta reserva.'; end if;

  update public.booking_professional_assignments
  set status='completed', completed_at=coalesce(completed_at,now()), updated_at=now()
  where id=v_assignment.id;

  select count(*) into v_remaining
  from public.booking_professional_assignments
  where booking_id=p_booking_id and status not in ('completed','cancelled');

  if v_remaining=0 then
    update public.bookings
    set provider_confirmed=true,
        confirmation_code_verified_at=now(),
        confirmation_code_verified_by=auth.uid(),
        status='completed_pending_release',
        completed_at=coalesce(completed_at,now()),
        updated_at=now()
    where id=p_booking_id;
  end if;

  return jsonb_build_object('ok',true,'all_completed',v_remaining=0,'remaining',v_remaining,'slot_number',v_assignment.slot_number);
end;
$$;

revoke execute on function public.yt_v61_verify_booking_confirmation_code(uuid,text) from public, anon;
grant execute on function public.yt_v61_verify_booking_confirmation_code(uuid,text) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- 3. Divide la liquidación existente entre asignaciones sin cambiar 1 pago / 1 factura.
--    El pool profesional se reparte por las cifras calculadas en cada asignación.
-- --------------------------------------------------------------------------
create or replace function public.yt_v61_split_provider_payout()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_count integer;
  r record;
  v_total_assignment numeric;
  v_amount numeric;
begin
  if pg_trigger_depth() > 1 then return new; end if;

  select count(*), coalesce(sum(greatest(payout_amount,0)),0)
  into v_count, v_total_assignment
  from public.booking_professional_assignments
  where booking_id=new.booking_id and status in ('accepted','completed');

  if v_count <= 1 then return new; end if;

  for r in
    select provider_id, payout_amount, slot_number
    from public.booking_professional_assignments
    where booking_id=new.booking_id and status in ('accepted','completed')
    order by slot_number
  loop
    v_amount := case
      when v_total_assignment > 0 then round(new.amount * (greatest(r.payout_amount,0)/v_total_assignment),2)
      else round(new.amount/v_count,2)
    end;

    if r.provider_id=new.provider_id then
      update public.provider_payouts set amount=v_amount, updated_at=now() where id=new.id;
    else
      insert into public.provider_payouts(provider_id,booking_id,amount,status,method,reference,admin_id,paid_at,notes,created_at,updated_at)
      select r.provider_id,new.booking_id,v_amount,new.status,new.method,coalesce(new.reference,'')||'-P'||r.slot_number,new.admin_id,new.paid_at,coalesce(new.notes,'')||' · Asignación profesional '||r.slot_number,now(),now()
      where not exists (
        select 1 from public.provider_payouts existing
        where existing.booking_id=new.booking_id and existing.provider_id=r.provider_id
      );

      update public.provider_payouts
      set amount=v_amount,
          status=new.status,
          method=new.method,
          admin_id=coalesce(admin_id,new.admin_id),
          paid_at=coalesce(paid_at,new.paid_at),
          updated_at=now()
      where booking_id=new.booking_id and provider_id=r.provider_id;
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_v61_split_provider_payout on public.provider_payouts;
create trigger trg_v61_split_provider_payout
after insert or update of amount,status on public.provider_payouts
for each row execute function public.yt_v61_split_provider_payout();

-- --------------------------------------------------------------------------
-- 4. Versionado visible solo para diagnóstico técnico.
-- --------------------------------------------------------------------------
insert into public.app_settings(key,value,updated_at)
values('wissa_v61_release', jsonb_build_object(
  'version','61.0',
  'service_first',true,
  'max_matching_pool',15,
  'multi_professional_assignments',true,
  'travel_mode','road_distance',
  'default_travel_rate_per_km',0.60,
  'pricing_admin_editable',true
), now())
on conflict(key) do update set value=excluded.value, updated_at=now();

commit;
