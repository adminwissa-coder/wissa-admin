-- ============================================================================
-- WISSA V62.0 - TEAM FIRST + ACCEPTANCE GATE + FINANCIAL SPLIT + LOYALTY
-- Fecha: 2026-09-14
-- Idempotente e incremental. NO elimina usuarios ni historicos.
-- Requiere tener aplicada V61.x.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 0. La promo de "primeros 10 clientes" deja de estar vigente.
--    El bono de Ofrecer de lanzamiento NO se toca aquí.
-- --------------------------------------------------------------------------
update public.promotion_campaigns
set is_active=false,
    ends_at=coalesce(ends_at, now()),
    updated_at=now(),
    metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
      'disabled_by','wissa_v62',
      'replacement_rule','loyalty_every_10_completed_services_50_next_service'
    )
where code='launch_first10_50' and is_active=true;

update public.customer_bonuses
set status='cancelled',
    metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object('cancelled_by','wissa_v62','reason','legacy_launch_client_bonus_disabled'),
    updated_at=now()
where bonus_type='welcome_cleaning_50' and status='available';

-- --------------------------------------------------------------------------
-- 1. Reglas de equipo configurables: categoría + modalidad + inmueble + m².
--    El pool de matching puede seguir siendo 15; el equipo de la reserva es 1..5.
-- --------------------------------------------------------------------------
create table if not exists public.service_team_rules (
  id uuid primary key default gen_random_uuid(),
  category text not null,
  cleaning_mode text not null default 'any' check (cleaning_mode in ('any','standard','deep')),
  property_type text not null default 'any',
  sqm_min integer not null default 1 check (sqm_min >= 0),
  sqm_max integer not null default 400 check (sqm_max >= sqm_min),
  min_professionals integer not null default 1 check (min_professionals between 1 and 5),
  recommended_professionals integer not null default 1 check (recommended_professionals between 1 and 5),
  max_professionals integer not null default 1 check (max_professionals between 1 and 5),
  additional_professional_fee numeric not null default 35 check (additional_professional_fee >= 0),
  is_active boolean not null default true,
  priority integer not null default 100,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (min_professionals <= recommended_professionals and recommended_professionals <= max_professionals)
);

create index if not exists service_team_rules_lookup_idx
  on public.service_team_rules(lower(category), cleaning_mode, lower(property_type), sqm_min, sqm_max, priority)
  where is_active=true;

alter table public.service_team_rules enable row level security;
drop policy if exists "v62_team_rules_read" on public.service_team_rules;
create policy "v62_team_rules_read" on public.service_team_rules for select to authenticated using (true);
drop policy if exists "v62_team_rules_admin" on public.service_team_rules;
create policy "v62_team_rules_admin" on public.service_team_rules for all to authenticated
using (public.yt_admin_is_current_admin()) with check (public.yt_admin_is_current_admin());

grant select on public.service_team_rules to authenticated;
grant insert,update,delete on public.service_team_rules to authenticated;

-- Limpia solo reglas default previas de V62, no reglas personalizadas del admin.
delete from public.service_team_rules where metadata->>'seed'='wissa_v62_default';

-- Estándar: hogar.
insert into public.service_team_rules(category,cleaning_mode,property_type,sqm_min,sqm_max,min_professionals,recommended_professionals,max_professionals,additional_professional_fee,priority,metadata)
values
('Limpieza','standard','casa',1,149,1,1,1,35,10,'{"seed":"wissa_v62_default"}'),
('Limpieza','standard','apartamento',1,149,1,1,1,35,10,'{"seed":"wissa_v62_default"}'),
('Limpieza','standard','casa',150,249,1,1,2,35,10,'{"seed":"wissa_v62_default"}'),
('Limpieza','standard','apartamento',150,249,1,1,2,35,10,'{"seed":"wissa_v62_default"}'),
('Limpieza','standard','casa',250,349,2,2,3,35,10,'{"seed":"wissa_v62_default"}'),
('Limpieza','standard','apartamento',250,349,2,2,3,35,10,'{"seed":"wissa_v62_default"}'),
('Limpieza','standard','casa',350,400,2,3,4,35,10,'{"seed":"wissa_v62_default"}'),
('Limpieza','standard','apartamento',350,400,2,3,4,35,10,'{"seed":"wissa_v62_default"}');

-- Estándar: espacios comerciales / institucionales.
insert into public.service_team_rules(category,cleaning_mode,property_type,sqm_min,sqm_max,min_professionals,recommended_professionals,max_professionals,additional_professional_fee,priority,metadata)
select 'Limpieza','standard',p,1,129,1,1,1,35,10,'{"seed":"wissa_v62_default"}'::jsonb
from unnest(array['oficina','local_comercial','edificio','consultorio_clinica']) p
union all
select 'Limpieza','standard',p,130,249,1,2,3,35,10,'{"seed":"wissa_v62_default"}'::jsonb
from unnest(array['oficina','local_comercial','edificio','consultorio_clinica']) p
union all
select 'Limpieza','standard',p,250,349,2,3,4,35,10,'{"seed":"wissa_v62_default"}'::jsonb
from unnest(array['oficina','local_comercial','edificio','consultorio_clinica']) p
union all
select 'Limpieza','standard',p,350,400,3,4,5,35,10,'{"seed":"wissa_v62_default"}'::jsonb
from unnest(array['oficina','local_comercial','edificio','consultorio_clinica']) p;

-- Profunda: más carga de trabajo; la regla sigue siendo editable.
insert into public.service_team_rules(category,cleaning_mode,property_type,sqm_min,sqm_max,min_professionals,recommended_professionals,max_professionals,additional_professional_fee,priority,metadata)
select 'Limpieza','deep',p,1,129,1,1,2,35,10,'{"seed":"wissa_v62_default"}'::jsonb
from unnest(array['casa','apartamento','oficina','local_comercial','edificio','consultorio_clinica']) p
union all
select 'Limpieza','deep',p,130,249,2,2,3,35,10,'{"seed":"wissa_v62_default"}'::jsonb
from unnest(array['casa','apartamento','oficina','local_comercial','edificio','consultorio_clinica']) p
union all
select 'Limpieza','deep',p,250,349,2,3,4,35,10,'{"seed":"wissa_v62_default"}'::jsonb
from unnest(array['casa','apartamento','oficina','local_comercial','edificio','consultorio_clinica']) p
union all
select 'Limpieza','deep',p,350,400,3,4,5,35,10,'{"seed":"wissa_v62_default"}'::jsonb
from unnest(array['casa','apartamento','oficina','local_comercial','edificio','consultorio_clinica']) p;

-- Fallbacks.
insert into public.service_team_rules(category,cleaning_mode,property_type,sqm_min,sqm_max,min_professionals,recommended_professionals,max_professionals,additional_professional_fee,priority,metadata)
values
('Limpieza','standard','any',1,249,1,1,2,35,900,'{"seed":"wissa_v62_default"}'),
('Limpieza','standard','any',250,400,2,2,3,35,900,'{"seed":"wissa_v62_default"}'),
('Limpieza','deep','any',1,129,1,1,2,35,900,'{"seed":"wissa_v62_default"}'),
('Limpieza','deep','any',130,249,2,2,3,35,900,'{"seed":"wissa_v62_default"}'),
('Limpieza','deep','any',250,400,2,3,5,35,900,'{"seed":"wissa_v62_default"}'),
('Limpieza','any','any',1,400,1,1,5,35,999,'{"seed":"wissa_v62_default"}');

create or replace function public.yt_v62_normalize_team_text(p_value text)
returns text language sql immutable set search_path=public as $$
  select trim(both '_' from regexp_replace(
    translate(lower(coalesce(p_value,'')), 'áéíóúüñÁÉÍÓÚÜÑ/ ', 'aeiouunAEIOUUN__'),
    '[^a-z0-9_]+','_','g'
  ));
$$;

grant execute on function public.yt_v62_normalize_team_text(text) to anon,authenticated,service_role;

create or replace function public.yt_v62_resolve_team_requirement(
  p_category text,
  p_cleaning_mode text default 'standard',
  p_property_type text default 'any',
  p_square_meters integer default 1
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
declare
  r public.service_team_rules%rowtype;
  v_category text := public.yt_v62_normalize_team_text(p_category);
  v_mode text := case when public.yt_v62_normalize_team_text(p_cleaning_mode) in ('deep','profunda','limpieza_profunda','premium') then 'deep' else 'standard' end;
  v_property text := public.yt_v62_normalize_team_text(p_property_type);
  v_sqm integer := greatest(1, least(400, coalesce(p_square_meters,1)));
begin
  select * into r
  from public.service_team_rules x
  where x.is_active=true
    and public.yt_v62_normalize_team_text(x.category) in (v_category, 'limpieza', 'cleaning')
    and x.cleaning_mode in (v_mode,'any')
    and public.yt_v62_normalize_team_text(x.property_type) in (v_property,'any')
    and v_sqm between x.sqm_min and x.sqm_max
  order by
    case when x.cleaning_mode=v_mode then 0 else 1 end,
    case when public.yt_v62_normalize_team_text(x.property_type)=v_property then 0 else 1 end,
    x.priority asc,
    (x.sqm_max-x.sqm_min) asc
  limit 1;

  if not found then
    return jsonb_build_object('min',1,'recommended',1,'max',1,'additional_professional_fee',0,'rule_id',null,'source','fallback');
  end if;

  return jsonb_build_object(
    'min',r.min_professionals,
    'recommended',r.recommended_professionals,
    'max',r.max_professionals,
    'additional_professional_fee',r.additional_professional_fee,
    'rule_id',r.id,
    'source','service_team_rules',
    'category',r.category,
    'mode',r.cleaning_mode,
    'property_type',r.property_type,
    'sqm_min',r.sqm_min,
    'sqm_max',r.sqm_max
  );
end;
$$;

grant execute on function public.yt_v62_resolve_team_requirement(text,text,text,integer) to anon,authenticated,service_role;

-- Admin CRUD de reglas sin exponer escrituras directas desde Mobile.
create or replace function public.yt_admin_team_rules_v62()
returns jsonb
language sql
stable
security definer
set search_path=public,pg_temp
as $$
  select case when public.yt_admin_is_current_admin() then
    coalesce(jsonb_agg(to_jsonb(x) order by x.priority,x.category,x.cleaning_mode,x.property_type,x.sqm_min),'[]'::jsonb)
  else '[]'::jsonb end
  from public.service_team_rules x;
$$;

grant execute on function public.yt_admin_team_rules_v62() to authenticated,service_role;

create or replace function public.yt_admin_upsert_team_rule_v62(p_rule jsonb)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare v_id uuid; begin
  if not public.yt_admin_is_current_admin() then raise exception 'Solo Admin Wissa puede editar reglas de equipo.'; end if;
  v_id := nullif(p_rule->>'id','')::uuid;
  if v_id is null then
    insert into public.service_team_rules(category,cleaning_mode,property_type,sqm_min,sqm_max,min_professionals,recommended_professionals,max_professionals,additional_professional_fee,is_active,priority,metadata)
    values(
      coalesce(nullif(trim(p_rule->>'category'),''),'Limpieza'),
      case when p_rule->>'cleaning_mode' in ('standard','deep','any') then p_rule->>'cleaning_mode' else 'any' end,
      coalesce(nullif(trim(p_rule->>'property_type'),''),'any'),
      greatest(0,coalesce((p_rule->>'sqm_min')::int,1)),
      greatest(1,coalesce((p_rule->>'sqm_max')::int,400)),
      greatest(1,least(5,coalesce((p_rule->>'min_professionals')::int,1))),
      greatest(1,least(5,coalesce((p_rule->>'recommended_professionals')::int,1))),
      greatest(1,least(5,coalesce((p_rule->>'max_professionals')::int,1))),
      greatest(0,coalesce((p_rule->>'additional_professional_fee')::numeric,35)),
      coalesce((p_rule->>'is_active')::boolean,true),
      coalesce((p_rule->>'priority')::int,100),
      coalesce(p_rule->'metadata','{}'::jsonb) - 'seed'
    ) returning id into v_id;
  else
    update public.service_team_rules set
      category=coalesce(nullif(trim(p_rule->>'category'),''),category),
      cleaning_mode=case when p_rule->>'cleaning_mode' in ('standard','deep','any') then p_rule->>'cleaning_mode' else cleaning_mode end,
      property_type=coalesce(nullif(trim(p_rule->>'property_type'),''),property_type),
      sqm_min=greatest(0,coalesce((p_rule->>'sqm_min')::int,sqm_min)),
      sqm_max=greatest(sqm_min,coalesce((p_rule->>'sqm_max')::int,sqm_max)),
      min_professionals=greatest(1,least(5,coalesce((p_rule->>'min_professionals')::int,min_professionals))),
      recommended_professionals=greatest(1,least(5,coalesce((p_rule->>'recommended_professionals')::int,recommended_professionals))),
      max_professionals=greatest(1,least(5,coalesce((p_rule->>'max_professionals')::int,max_professionals))),
      additional_professional_fee=greatest(0,coalesce((p_rule->>'additional_professional_fee')::numeric,additional_professional_fee)),
      is_active=coalesce((p_rule->>'is_active')::boolean,is_active),
      priority=coalesce((p_rule->>'priority')::int,priority),
      metadata=(coalesce(metadata,'{}'::jsonb) || coalesce(p_rule->'metadata','{}'::jsonb)) - 'seed',
      updated_at=now()
    where id=v_id;
  end if;
  return to_jsonb((select x from public.service_team_rules x where x.id=v_id));
end;
$$;

grant execute on function public.yt_admin_upsert_team_rule_v62(jsonb) to authenticated,service_role;

create or replace function public.yt_admin_delete_team_rule_v62(p_rule_id uuid)
returns boolean language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if not public.yt_admin_is_current_admin() then raise exception 'Solo Admin Wissa puede eliminar reglas de equipo.'; end if;
  delete from public.service_team_rules where id=p_rule_id;
  return found;
end; $$;
grant execute on function public.yt_admin_delete_team_rule_v62(uuid) to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 2. Snapshots operativos y financieros de la reserva.
-- --------------------------------------------------------------------------
alter table public.bookings add column if not exists required_professionals integer not null default 1;
alter table public.bookings add column if not exists selected_professionals integer not null default 1;
alter table public.bookings add column if not exists accepted_professionals integer not null default 0;
alter table public.bookings add column if not exists team_min_professionals integer not null default 1;
alter table public.bookings add column if not exists team_recommended_professionals integer not null default 1;
alter table public.bookings add column if not exists team_max_professionals integer not null default 1;
alter table public.bookings add column if not exists team_rule_id uuid references public.service_team_rules(id);
alter table public.bookings add column if not exists team_ready_at timestamptz;
alter table public.bookings add column if not exists payment_unlocked_at timestamptz;
alter table public.bookings add column if not exists commission_rate_snapshot numeric not null default 0.20;
alter table public.bookings add column if not exists provider_pool_amount numeric not null default 0;
alter table public.bookings add column if not exists loyalty_subsidy_amount numeric not null default 0;
alter table public.bookings add column if not exists financial_snapshot jsonb not null default '{}'::jsonb;

alter table public.booking_professional_assignments add column if not exists extras_share numeric not null default 0;
alter table public.booking_professional_assignments add column if not exists travel_rate_per_km numeric not null default 0.60;
alter table public.booking_professional_assignments add column if not exists gross_provider_amount numeric not null default 0;
alter table public.booking_professional_assignments add column if not exists commission_amount numeric not null default 0;
alter table public.booking_professional_assignments add column if not exists net_provider_amount numeric not null default 0;
alter table public.booking_professional_assignments add column if not exists payout_status text not null default 'pending';
alter table public.booking_professional_assignments add column if not exists payout_id uuid references public.provider_payouts(id);
alter table public.booking_professional_assignments add column if not exists commission_rate_snapshot numeric not null default 0.20;
alter table public.booking_professional_assignments add column if not exists origin_label text;
alter table public.booking_professional_assignments add column if not exists route_polyline text;

-- V62: el máximo operativo real por reserva es 5.
do $$ begin
  if exists (
    select 1 from pg_constraint where conname='booking_professional_assignments_slot_number_check'
  ) then
    alter table public.booking_professional_assignments drop constraint booking_professional_assignments_slot_number_check;
  end if;
exception when others then null; end $$;

do $$ begin
  if exists (select 1 from pg_constraint where conname='booking_professional_assignments_slot_v62_check') then
    alter table public.booking_professional_assignments drop constraint booking_professional_assignments_slot_v62_check;
  end if;
exception when others then null; end $$;

alter table public.booking_professional_assignments
  add constraint booking_professional_assignments_slot_v62_check check (slot_number between 1 and 5) not valid;

-- --------------------------------------------------------------------------
-- 3. Recalculo exacto de la distribución N-profesional.
--    - servicio/extras: comisión por categoría primero; neto se divide N
--    - kits/productos y uso plataforma: no se dividen
--    - traslado: individual por profesional
--    - residual de centavos: se asigna al último cupo para cuadrar exacto
-- --------------------------------------------------------------------------
create or replace function public.yt_v62_assignment_recalculate(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  b public.bookings%rowtype;
  v_count int;
  v_gross_cents bigint;
  v_commission_cents bigint;
  v_net_cents bigint;
  v_gross_base bigint;
  v_gross_rem bigint;
  v_comm_base bigint;
  v_comm_rem bigint;
  v_net_base bigint;
  v_net_rem bigint;
  v_extra_total numeric := 0;
  v_extra_cents bigint := 0;
  v_extra_base bigint := 0;
  v_extra_rem bigint := 0;
  v_rate numeric;
  v_map jsonb;
  v_matches jsonb;
  r record;
  v_idx int := 0;
  v_distance numeric;
  v_travel numeric;
  v_gross_share numeric;
  v_comm_share numeric;
  v_net_share numeric;
  v_extra_share numeric;
  v_provider_total numeric;
  v_provider_bonus numeric := 0;
  v_sum_provider numeric := 0;
  v_snapshot jsonb := '[]'::jsonb;
begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then return jsonb_build_object('ok',false,'reason','booking_not_found'); end if;

  select count(*) into v_count from public.booking_professional_assignments
  where booking_id=p_booking_id and status <> 'cancelled';
  if v_count<=0 then return jsonb_build_object('ok',false,'reason','no_assignments'); end if;
  if v_count>5 then raise exception 'V62 permite máximo 5 profesionales por reserva.'; end if;

  v_rate := greatest(coalesce(b.travel_rate_per_km,0.60),0);
  v_map := coalesce(b.service_details->'travel_distance_by_provider','{}'::jsonb);
  v_matches := coalesce(b.service_details->'travel_matches','[]'::jsonb);

  -- Extras de trabajo forman parte del servicio comisionable.
  select coalesce(sum(c.price),0) into v_extra_total
  from public.booking_catalog c
  where c.kind='extra'
    and c.id::text = any(string_to_array(coalesce(b.service_details->>'extra_ids',''),','));

  v_gross_cents := round(greatest(coalesce(b.service_subtotal,0),0)*100)::bigint;
  v_commission_cents := round(greatest(coalesce(b.platform_fee,0),0)*100)::bigint;
  if v_commission_cents>v_gross_cents then v_commission_cents:=v_gross_cents; end if;
  v_net_cents := v_gross_cents-v_commission_cents;
  v_extra_cents := least(v_gross_cents,round(greatest(v_extra_total,0)*100)::bigint);

  v_gross_base := v_gross_cents / v_count; v_gross_rem := v_gross_cents % v_count;
  v_comm_base := v_commission_cents / v_count; v_comm_rem := v_commission_cents % v_count;
  v_net_base := v_net_cents / v_count; v_net_rem := v_net_cents % v_count;
  v_extra_base := v_extra_cents / v_count; v_extra_rem := v_extra_cents % v_count;

  for r in
    select a.id,a.provider_id,a.slot_number
    from public.booking_professional_assignments a
    where a.booking_id=p_booking_id and a.status<>'cancelled'
    order by a.slot_number
  loop
    v_idx:=v_idx+1;
    v_gross_share := (v_gross_base + case when v_idx=v_count then v_gross_rem else 0 end)::numeric/100;
    v_comm_share := (v_comm_base + case when v_idx=v_count then v_comm_rem else 0 end)::numeric/100;
    v_net_share := (v_net_base + case when v_idx=v_count then v_net_rem else 0 end)::numeric/100;
    v_extra_share := (v_extra_base + case when v_idx=v_count then v_extra_rem else 0 end)::numeric/100;
    v_distance := greatest(coalesce(nullif(v_map->>r.provider_id::text,'')::numeric,0),0);
    v_travel := round(v_distance*v_rate,2);
    select coalesce(sum(pcb.amount),0) into v_provider_bonus
    from public.provider_completion_bonuses pcb
    where pcb.source_booking_id=p_booking_id and pcb.provider_id=r.provider_id and pcb.status in ('earned','paid');
    v_provider_total := round(v_net_share+v_travel+v_provider_bonus,2);
    v_sum_provider := round(v_sum_provider+v_provider_total,2);

    update public.booking_professional_assignments a set
      service_share=v_net_share,
      extras_share=v_extra_share,
      travel_distance_km=v_distance,
      travel_rate_per_km=v_rate,
      travel_fee=v_travel,
      gross_provider_amount=round(v_gross_share+v_travel,2),
      commission_amount=v_comm_share,
      net_provider_amount=v_provider_total,
      payout_amount=v_provider_total,
      commission_rate_snapshot=case when coalesce(b.service_subtotal,0)>0 then round(coalesce(b.platform_fee,0)/b.service_subtotal,6) else coalesce(b.commission_rate_snapshot,0.20) end,
      origin_label=coalesce((select m->>'origin_label' from jsonb_array_elements(v_matches) m where m->>'provider_id'=r.provider_id::text limit 1),a.origin_label),
      route_polyline=coalesce((select m->>'polyline' from jsonb_array_elements(v_matches) m where m->>'provider_id'=r.provider_id::text limit 1),a.route_polyline),
      updated_at=now()
    where a.id=r.id;

    v_snapshot := v_snapshot || jsonb_build_array(jsonb_build_object(
      'slot',r.slot_number,'provider_id',r.provider_id,'gross_labor_share',v_gross_share,
      'commission_share',v_comm_share,'net_labor_share',v_net_share,'extras_gross_share',v_extra_share,
      'travel_distance_km',v_distance,'travel_rate_per_km',v_rate,'travel_amount',v_travel,'provider_bonus',v_provider_bonus,'net_provider_amount',v_provider_total
    ));
  end loop;

  update public.bookings set
    required_professionals=v_count,
    selected_professionals=v_count,
    accepted_professionals=(select count(*) from public.booking_professional_assignments a where a.booking_id=p_booking_id and a.status in ('accepted','completed')),
    commission_rate_snapshot=case when coalesce(service_subtotal,0)>0 then round(coalesce(platform_fee,0)/service_subtotal,6) else commission_rate_snapshot end,
    provider_pool_amount=v_sum_provider,
    financial_snapshot=jsonb_build_object(
      'version',62,
      'currency','USD',
      'service_gross',coalesce(service_subtotal,0),
      'wissa_service_commission',coalesce(platform_fee,0),
      'platform_usage_fee',coalesce(platform_usage_fee,0),
      'kits_materials',coalesce(kit_amount,0),
      'travel_total',coalesce(travel_fee,0),
      'itbms',coalesce(tax_amount,0),
      'client_total',coalesce(total_amount,0),
      'provider_pool',v_sum_provider,
      'assignments',v_snapshot,
      'rounding','residual_to_last_slot'
    ),
    finance_version=62,
    updated_at=now()
  where id=p_booking_id;

  return jsonb_build_object('ok',true,'booking_id',p_booking_id,'professionals',v_count,'provider_pool',v_sum_provider,'assignments',v_snapshot);
end;
$$;

revoke all on function public.yt_v62_assignment_recalculate(uuid) from public,anon;
grant execute on function public.yt_v62_assignment_recalculate(uuid) to authenticated,service_role;

create or replace function public.yt_v62_set_booking_assignments(p_booking_id uuid,p_provider_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  b public.bookings%rowtype;
  v_provider uuid;
  v_service_id uuid;
  v_category text;
  v_count int;
  v_slot int:=0;
begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  if auth.uid() is not null and auth.uid()<>b.buyer_id and not public.yt_admin_is_current_admin() then raise exception 'No autorizado.'; end if;

  v_count:=coalesce(array_length(p_provider_ids,1),0);
  if v_count<1 or v_count>5 then raise exception 'La reserva debe tener entre 1 y 5 profesionales.'; end if;
  select s.category into v_category from public.services s where s.id=b.service_id;

  delete from public.booking_professional_assignments where booking_id=p_booking_id;
  foreach v_provider in array p_provider_ids loop
    v_slot:=v_slot+1;
    select s.id into v_service_id from public.services s
    where s.provider_id=v_provider and s.is_active=true
      and (v_category is null or lower(coalesce(s.category,''))=lower(coalesce(v_category,'')))
    order by case when s.id=b.service_id then 0 else 1 end,s.updated_at desc nulls last limit 1;
    if v_service_id is null then raise exception 'El profesional % no tiene un servicio activo compatible.',v_provider; end if;
    insert into public.booking_professional_assignments(booking_id,provider_id,service_id,slot_number,status)
    values(p_booking_id,v_provider,v_service_id,v_slot,'pending');
  end loop;

  update public.bookings set
    required_professionals=v_count,selected_professionals=v_count,accepted_professionals=0,
    -- 1 profesional conserva flujo normal: el pago puede iniciarse de inmediato.
    status=case when v_count=1 then 'pending_payment' else 'pending' end,
    payment_status=case when v_count=1 then 'pending_payment' else 'not_started' end,
    payment_unlocked_at=case when v_count=1 then coalesce(payment_unlocked_at,now()) else null end,
    team_ready_at=case when v_count=1 then null else team_ready_at end,
    updated_at=now()
  where id=p_booking_id;

  perform public.yt_v62_assignment_recalculate(p_booking_id);
  return jsonb_build_object('ok',true,'booking_id',p_booking_id,'professionals',v_count,'payment_unlocked',v_count=1);
end;
$$;

grant execute on function public.yt_v62_set_booking_assignments(uuid,uuid[]) to authenticated,service_role;

-- Compatibilidad: Mobile V61 que invoque el RPC antiguo entra al motor V62.
create or replace function public.yt_v61_set_booking_assignments(p_booking_id uuid,p_provider_ids uuid[])
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin return public.yt_v62_set_booking_assignments(p_booking_id,p_provider_ids); end; $$;
grant execute on function public.yt_v61_set_booking_assignments(uuid,uuid[]) to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 4. Aceptación: 1 profesional conserva flujo pago -> aceptación.
--    2..5: aceptación del equipo -> habilita pago cuando N/N aceptan.
-- --------------------------------------------------------------------------
create or replace function public.yt_v62_accept_booking_assignment(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  b public.bookings%rowtype;
  a public.booking_professional_assignments%rowtype;
  v_required int;
  v_accepted int;
  v_all boolean;
begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  select * into a from public.booking_professional_assignments
    where booking_id=p_booking_id and provider_id=auth.uid() and status in ('pending','accepted')
    order by slot_number limit 1 for update;
  if not found then raise exception 'No tienes una asignación activa en esta reserva.'; end if;

  v_required:=greatest(1,least(5,coalesce(b.required_professionals,(b.service_details->>'professionals_required')::int,1)));
  if v_required=1 and coalesce(b.payment_status,'')<>'paid' then
    raise exception 'En reservas de un profesional, el cliente completa el pago antes de la aceptación.';
  end if;

  update public.booking_professional_assignments set status='accepted',accepted_at=coalesce(accepted_at,now()),rejected_at=null,rejection_reason=null,updated_at=now() where id=a.id;
  select count(*) into v_accepted from public.booking_professional_assignments where booking_id=p_booking_id and status in ('accepted','completed');
  v_all:=v_accepted>=v_required;

  update public.bookings set
    accepted_professionals=v_accepted,
    team_ready_at=case when v_all then coalesce(team_ready_at,now()) else team_ready_at end,
    payment_unlocked_at=case when v_all and coalesce(payment_status,'')<>'paid' then coalesce(payment_unlocked_at,now()) else payment_unlocked_at end,
    payment_status=case when v_all and coalesce(payment_status,'') not in ('paid','processing') then 'pending_payment' else payment_status end,
    status=case
      when v_all and coalesce(payment_status,'')='paid' then 'accepted'
      when v_all then 'pending_payment'
      else 'pending'
    end,
    provider_acceptance_at=case when v_all then coalesce(provider_acceptance_at,now()) else provider_acceptance_at end,
    updated_at=now()
  where id=p_booking_id;

  return jsonb_build_object(
    'ok',true,'slot_number',a.slot_number,'accepted',v_accepted,'required',v_required,
    'all_accepted',v_all,'payment_unlocked',v_all and coalesce(b.payment_status,'')<>'paid',
    'payout_amount',(select payout_amount from public.booking_professional_assignments where id=a.id)
  );
end;
$$;

grant execute on function public.yt_v62_accept_booking_assignment(uuid) to authenticated,service_role;

create or replace function public.yt_v61_accept_booking_assignment(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin return public.yt_v62_accept_booking_assignment(p_booking_id); end; $$;
grant execute on function public.yt_v61_accept_booking_assignment(uuid) to authenticated,service_role;

create or replace function public.yt_v62_reject_booking_assignment(p_booking_id uuid,p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  b public.bookings%rowtype;
  a public.booking_professional_assignments%rowtype;
  v_category text;
  v_replacement_provider uuid;
  v_replacement_service uuid;
  v_day int;
  v_start time;
  v_end time;
  v_lat numeric;
  v_lng numeric;
  v_required int;
  v_accepted int;
begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  select * into a from public.booking_professional_assignments
    where booking_id=p_booking_id and provider_id=auth.uid() and status in ('pending','accepted')
    order by slot_number limit 1 for update;
  if not found then raise exception 'No tienes una asignación activa en esta reserva.'; end if;

  select s.category into v_category from public.services s where s.id=coalesce(a.service_id,b.service_id);
  v_day:=extract(dow from b.booking_date)::int;
  v_start:=coalesce(nullif(b.booking_time,'')::time,'00:00'::time);
  v_end:=v_start+make_interval(mins=>greatest(coalesce(b.duration_minutes,60),15));
  v_lat:=nullif(b.service_details#>>'{location,latitude}','')::numeric;
  v_lng:=nullif(b.service_details#>>'{location,longitude}','')::numeric;
  v_required:=greatest(1,least(5,coalesce(b.required_professionals,1)));

  select s.provider_id,s.id into v_replacement_provider,v_replacement_service
  from public.services s join public.profiles p on p.id=s.provider_id
  where s.is_active=true
    and lower(coalesce(s.category,''))=lower(coalesce(v_category,''))
    and coalesce(p.is_active,true)=true and coalesce(p.is_suspended,false)=false and coalesce(p.is_available,false)=true
    and s.provider_id<>auth.uid()
    and not exists(select 1 from public.booking_professional_assignments x where x.booking_id=p_booking_id and x.provider_id=s.provider_id and x.status<>'cancelled')
    and exists(select 1 from public.availability av where av.provider_id=s.provider_id and av.is_active=true and av.day_of_week=v_day and nullif(av.start_time,'')::time<=v_start and nullif(av.end_time,'')::time>=v_end)
    and not exists(select 1 from public.provider_time_off t where t.provider_id=s.provider_id and b.booking_date between t.start_date and t.end_date)
  order by
    case when v_lat is not null and v_lng is not null and coalesce(p.latitude,p.lat) is not null and coalesce(p.longitude,p.lng) is not null then
      power(coalesce(p.latitude,p.lat)-v_lat,2)+power(coalesce(p.longitude,p.lng)-v_lng,2)
    else 999999 end asc,
    coalesce(p.rating_avg,0) desc,
    s.updated_at desc nulls last
  limit 1;

  if v_replacement_provider is null then
    update public.booking_professional_assignments set status='rejected',rejected_at=now(),rejection_reason=coalesce(nullif(trim(p_reason),''),'Rechazada por profesional'),updated_at=now() where id=a.id;
  else
    update public.booking_professional_assignments set
      provider_id=v_replacement_provider,service_id=v_replacement_service,status='pending',accepted_at=null,rejected_at=null,rejection_reason=null,
      last_rejected_provider_id=auth.uid(),replacement_count=replacement_count+1,payout_status='pending',payout_id=null,updated_at=now()
    where id=a.id;
    if a.slot_number=1 then update public.bookings set provider_id=v_replacement_provider,service_id=v_replacement_service where id=p_booking_id; end if;
  end if;

  select count(*) into v_accepted from public.booking_professional_assignments where booking_id=p_booking_id and status in ('accepted','completed');
  update public.bookings set
    accepted_professionals=v_accepted,
    status=case when payment_status='paid' then 'paid_pending_acceptance' else 'pending' end,
    payment_status=case when payment_status='paid' then payment_status when v_required=1 then 'pending_payment' else 'not_started' end,
    payment_unlocked_at=case when v_required=1 then payment_unlocked_at else null end,
    team_ready_at=null,
    updated_at=now()
  where id=p_booking_id;

  perform public.yt_v62_assignment_recalculate(p_booking_id);
  return jsonb_build_object('ok',true,'replacement_found',v_replacement_provider is not null,'replacement_provider_id',v_replacement_provider,'replacement_service_id',v_replacement_service,'slot_number',a.slot_number,'accepted',v_accepted,'required',v_required);
end;
$$;

grant execute on function public.yt_v62_reject_booking_assignment(uuid,text) to authenticated,service_role;

create or replace function public.yt_v61_reject_booking_assignment(p_booking_id uuid,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin return public.yt_v62_reject_booking_assignment(p_booking_id,p_reason); end; $$;
grant execute on function public.yt_v61_reject_booking_assignment(uuid,text) to authenticated,service_role;

-- Pago aprobado: si el equipo multi ya estaba N/N, pasa directo a accepted.
-- Con 1 profesional mantiene el flujo normal paid_pending_acceptance.
create or replace function public.yt_v62_sync_paid_booking_team_state()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_required int; v_accepted int; begin
  if coalesce(new.payment_status,'')='paid' and coalesce(old.payment_status,'') is distinct from 'paid' then
    v_required:=greatest(1,least(5,coalesce(new.required_professionals,(new.service_details->>'professionals_required')::int,1)));
    select count(*) into v_accepted from public.booking_professional_assignments where booking_id=new.id and status in ('accepted','completed');
    update public.bookings set
      accepted_professionals=v_accepted,
      status=case when v_required>1 and v_accepted>=v_required then 'accepted' else 'paid_pending_acceptance' end,
      provider_acceptance_at=case when v_required>1 and v_accepted>=v_required then coalesce(provider_acceptance_at,now()) else provider_acceptance_at end,
      updated_at=now()
    where id=new.id;
  end if;
  return new;
end; $$;

drop trigger if exists trg_v62_sync_paid_team_state on public.bookings;
create trigger trg_v62_sync_paid_team_state after update of payment_status on public.bookings
for each row when (new.payment_status='paid' and old.payment_status is distinct from new.payment_status)
execute function public.yt_v62_sync_paid_booking_team_state();

-- Recalcular distribución si cambian montos relevantes.
create or replace function public.yt_v62_booking_finance_recalculate_trigger()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if pg_trigger_depth()>1 then return new; end if;
  if exists(select 1 from public.booking_professional_assignments where booking_id=new.id) then
    perform public.yt_v62_assignment_recalculate(new.id);
  end if;
  return new;
end; $$;

drop trigger if exists trg_v62_booking_finance_recalculate on public.bookings;
create trigger trg_v62_booking_finance_recalculate
after update of service_subtotal,platform_fee,travel_fee,travel_rate_per_km,seller_payout,provider_bonus_amount,total_amount on public.bookings
for each row execute function public.yt_v62_booking_finance_recalculate_trigger();

-- --------------------------------------------------------------------------
-- 5. Liquidación exacta: un payout por asignación, no por reserva completa.
--    Reemplaza el trigger proporcional V61.
-- --------------------------------------------------------------------------
drop trigger if exists trg_v61_split_provider_payout on public.provider_payouts;

create or replace function public.yt_v62_split_provider_payout()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  b public.bookings%rowtype;
  r record;
  v_total_target numeric;
  v_running numeric:=0;
  v_rows int;
  v_idx int:=0;
  v_amount numeric;
  v_payout_id uuid;
begin
  if pg_trigger_depth()>1 then return new; end if;
  select * into b from public.bookings where id=new.booking_id;
  if not found then return new; end if;
  select count(*) into v_rows from public.booking_professional_assignments where booking_id=new.booking_id and status in ('accepted','completed');
  if v_rows<=1 then
    update public.booking_professional_assignments set payout_id=new.id,payout_status=new.status,updated_at=now()
    where booking_id=new.booking_id and provider_id=new.provider_id and status in ('accepted','completed');
    return new;
  end if;

  perform public.yt_v62_assignment_recalculate(new.booking_id);
  v_total_target:=round(greatest(coalesce(new.amount,b.seller_payout,0),0),2);

  for r in
    select * from public.booking_professional_assignments
    where booking_id=new.booking_id and status in ('accepted','completed') order by slot_number
  loop
    v_idx:=v_idx+1;
    v_amount:=case when v_idx=v_rows then round(v_total_target-v_running,2) else round(greatest(r.net_provider_amount,0),2) end;
    v_running:=round(v_running+v_amount,2);

    if r.provider_id=new.provider_id then
      update public.provider_payouts set amount=v_amount,status=new.status,updated_at=now() where id=new.id;
      v_payout_id:=new.id;
    else
      select id into v_payout_id from public.provider_payouts where booking_id=new.booking_id and provider_id=r.provider_id order by created_at desc limit 1;
      if v_payout_id is null then
        insert into public.provider_payouts(provider_id,booking_id,amount,status,method,reference,admin_id,paid_at,notes,created_at,updated_at)
        values(r.provider_id,new.booking_id,v_amount,new.status,coalesce(new.method,'manual_admin'),coalesce(new.reference,'ADMIN')||'-P'||r.slot_number,new.admin_id,new.paid_at,coalesce(new.notes,'')||' · Wissa V62 cupo '||r.slot_number,now(),now())
        returning id into v_payout_id;
      else
        update public.provider_payouts set amount=v_amount,status=new.status,method=coalesce(method,new.method,'manual_admin'),admin_id=coalesce(admin_id,new.admin_id),paid_at=coalesce(paid_at,new.paid_at),updated_at=now() where id=v_payout_id;
      end if;
    end if;

    update public.booking_professional_assignments set payout_id=v_payout_id,payout_status=new.status,payout_amount=v_amount,net_provider_amount=v_amount,updated_at=now() where id=r.id;
    perform public.yt_recalculate_provider_balance(r.provider_id);

    if new.status='paid' and not exists(select 1 from public.notifications n where n.user_id=r.provider_id and n.related_booking_id=new.booking_id and n.type='payout_released_admin') then
      insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read,created_at)
      values(r.provider_id,'Pago liquidado','Wissa registró la liquidación de tu cupo por '||to_char(v_amount,'FM999999990.00')||' USD.','payout_released_admin','/(provider-tabs)/earnings',new.booking_id,jsonb_build_object('assignment_slot',r.slot_number,'amount',v_amount,'payout_id',v_payout_id),false,now());
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_v62_split_provider_payout on public.provider_payouts;
create trigger trg_v62_split_provider_payout after insert or update of amount,status on public.provider_payouts
for each row execute function public.yt_v62_split_provider_payout();

-- --------------------------------------------------------------------------
-- 5B. V62: gate de pago y liquidación N-profesional autoritativa.
-- --------------------------------------------------------------------------
-- El trigger proporcional de V61/V62 no debe repartir a partir de un payout parcial.
drop trigger if exists trg_v61_split_provider_payout on public.provider_payouts;
drop trigger if exists trg_v62_split_provider_payout on public.provider_payouts;

-- Bloquea la creación del checkout multi-profesional hasta que N/N hayan aceptado.
-- Las reservas de 1 profesional conservan el flujo normal y pueden pagar de inmediato.
create or replace function public.yt_v62_payment_order_gate()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  b public.bookings%rowtype;
  v_required int;
  v_accepted int;
begin
  if new.booking_id is null then return new; end if;
  if coalesce(new.kind,'booking') <> 'booking' then return new; end if;

  select * into b from public.bookings where id=new.booking_id;
  if not found then return new; end if;
  v_required:=greatest(1,least(5,coalesce(b.required_professionals,1)));
  if v_required<=1 then return new; end if;

  select count(*) into v_accepted
  from public.booking_professional_assignments a
  where a.booking_id=b.id and a.status in ('accepted','completed');

  if v_accepted < v_required or coalesce(b.payment_status,'') not in ('pending_payment','processing','paid') then
    raise exception 'Pago bloqueado: Wissa debe confirmar el equipo completo (%/% profesionales) antes de iniciar el pago.',v_accepted,v_required;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_v62_payment_order_gate on public.payment_orders;
create trigger trg_v62_payment_order_gate
before insert or update of status on public.payment_orders
for each row execute function public.yt_v62_payment_order_gate();

-- Crea/actualiza una liquidación por cada asignación. El monto de cada cupo viene
-- del snapshot calculado en booking_professional_assignments y cuadra al centavo.
create or replace function public.yt_v62_release_booking_payouts(
  p_booking_id uuid,
  p_admin_id uuid default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  b public.bookings%rowtype;
  r record;
  v_payout_id uuid;
  v_total numeric:=0;
  v_count int:=0;
  v_payouts jsonb:='[]'::jsonb;
  v_now timestamptz:=now();
begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  if coalesce(b.payment_status,'')<>'paid' then raise exception 'La reserva no está pagada.'; end if;
  if coalesce(b.status,'') not in ('completed','completed_pending_release') then raise exception 'La reserva debe estar completada para liquidar.'; end if;

  if exists(select 1 from public.booking_professional_assignments where booking_id=p_booking_id and status in ('accepted','completed')) then
    perform public.yt_v62_assignment_recalculate(p_booking_id);
  end if;

  for r in
    select a.*,coalesce(p.full_name,p.display_name,p.email,'Profesional') provider_name
    from public.booking_professional_assignments a
    left join public.profiles p on p.id=a.provider_id
    where a.booking_id=p_booking_id and a.status in ('accepted','completed')
    order by a.slot_number
  loop
    v_count:=v_count+1;
    v_total:=round(v_total+greatest(coalesce(r.net_provider_amount,r.payout_amount,0),0),2);
    select pp.id into v_payout_id
    from public.provider_payouts pp
    where pp.booking_id=p_booking_id and pp.provider_id=r.provider_id
    order by pp.created_at desc limit 1;

    if v_payout_id is null then
      insert into public.provider_payouts(provider_id,booking_id,amount,status,method,reference,admin_id,paid_at,notes,created_at,updated_at)
      values(r.provider_id,p_booking_id,round(greatest(coalesce(r.net_provider_amount,r.payout_amount,0),0),2),'paid','manual_admin',
             'ADMIN-'||upper(left(replace(p_booking_id::text,'-',''),10))||'-P'||r.slot_number,
             p_admin_id,v_now,coalesce(nullif(p_note,''),'Liquidación Wissa V62')||' · Cupo '||r.slot_number,v_now,v_now)
      returning id into v_payout_id;
    else
      update public.provider_payouts
      set amount=round(greatest(coalesce(r.net_provider_amount,r.payout_amount,0),0),2),status='paid',method='manual_admin',
          admin_id=coalesce(p_admin_id,admin_id),paid_at=coalesce(paid_at,v_now),
          reference=coalesce(nullif(reference,''),'ADMIN-'||upper(left(replace(p_booking_id::text,'-',''),10))||'-P'||r.slot_number),
          notes=coalesce(nullif(p_note,''),notes,'Liquidación Wissa V62')||' · Cupo '||r.slot_number,updated_at=v_now
      where id=v_payout_id;
    end if;

    update public.booking_professional_assignments
    set payout_id=v_payout_id,payout_status='paid',payout_amount=round(greatest(coalesce(r.net_provider_amount,r.payout_amount,0),0),2),updated_at=v_now
    where id=r.id;

    perform public.yt_recalculate_provider_balance(r.provider_id);

    if not exists(select 1 from public.notifications n where n.user_id=r.provider_id and n.related_booking_id=p_booking_id and n.type='payout_released_admin' and n.metadata->>'assignment_slot'=r.slot_number::text) then
      insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read,created_at)
      values(r.provider_id,'Pago liquidado','Wissa liquidó tu cupo por USD '||to_char(round(greatest(coalesce(r.net_provider_amount,r.payout_amount,0),0),2),'FM999999990.00')||'.',
             'payout_released_admin','/(provider-tabs)/earnings',p_booking_id,
             jsonb_build_object('assignment_slot',r.slot_number,'amount',round(greatest(coalesce(r.net_provider_amount,r.payout_amount,0),0),2),'payout_id',v_payout_id),false,v_now);
    end if;

    v_payouts:=v_payouts||jsonb_build_array(jsonb_build_object('slot',r.slot_number,'provider_id',r.provider_id,'provider_name',r.provider_name,'amount',round(greatest(coalesce(r.net_provider_amount,r.payout_amount,0),0),2),'payout_id',v_payout_id));
  end loop;

  -- Compatibilidad para reservas históricas/single sin tabla de asignaciones.
  if v_count=0 then
    v_total:=round(greatest(coalesce(b.seller_payout,0),0),2);
    if v_total<=0 then raise exception 'No existe una liquidación profesional válida.'; end if;
    select pp.id into v_payout_id from public.provider_payouts pp where pp.booking_id=p_booking_id and pp.provider_id=b.provider_id order by pp.created_at desc limit 1;
    if v_payout_id is null then
      insert into public.provider_payouts(provider_id,booking_id,amount,status,method,reference,admin_id,paid_at,notes,created_at,updated_at)
      values(b.provider_id,p_booking_id,v_total,'paid','manual_admin','ADMIN-'||upper(left(replace(p_booking_id::text,'-',''),10)),p_admin_id,v_now,coalesce(nullif(p_note,''),'Liquidación Wissa V62'),v_now,v_now)
      returning id into v_payout_id;
    else
      update public.provider_payouts set amount=v_total,status='paid',admin_id=coalesce(p_admin_id,admin_id),paid_at=coalesce(paid_at,v_now),updated_at=v_now where id=v_payout_id;
    end if;
    perform public.yt_recalculate_provider_balance(b.provider_id);
    v_payouts:=jsonb_build_array(jsonb_build_object('slot',1,'provider_id',b.provider_id,'amount',v_total,'payout_id',v_payout_id));
    v_count:=1;
  end if;

  return jsonb_build_object('ok',true,'booking_id',p_booking_id,'count',v_count,'provider_total',v_total,'payouts',v_payouts,
    'primary_provider_id',coalesce((v_payouts->0->>'provider_id')::uuid,b.provider_id),'primary_payout_id',(v_payouts->0->>'payout_id')::uuid);
end;
$$;

revoke all on function public.yt_v62_release_booking_payouts(uuid,uuid,text) from public,anon;
grant execute on function public.yt_v62_release_booking_payouts(uuid,uuid,text) to authenticated,service_role;

-- Override del RPC usado por Admin Web: mantiene la firma histórica pero liquida N cupos.
create or replace function public.yt_admin_release_booking_payment(p_booking_id uuid,p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  b public.bookings%rowtype;
  v_result jsonb;
  v_total numeric;
  v_now timestamptz:=now();
  v_primary_provider uuid;
  v_primary_payout uuid;
begin
  if not public.yt_admin_is_current_admin() then raise exception 'No autorizado. Solo administradores.'; end if;
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  if coalesce(b.payment_status,'')<>'paid' then raise exception 'La reserva no está pagada.'; end if;
  if coalesce(b.status,'') not in ('completed','completed_pending_release') then raise exception 'La reserva debe estar completada para liberar.'; end if;

  v_result:=public.yt_v62_release_booking_payouts(p_booking_id,auth.uid(),p_note);
  v_total:=coalesce((v_result->>'provider_total')::numeric,0);
  v_primary_provider:=nullif(v_result->>'primary_provider_id','')::uuid;
  v_primary_payout:=nullif(v_result->>'primary_payout_id','')::uuid;

  update public.bookings
  set status=case when status='completed_pending_release' then 'completed' else status end,
      seller_payout=v_total,payout_release_status='released',finance_status='released',
      released_at=coalesce(released_at,v_now),payout_released_at=coalesce(payout_released_at,v_now),provider_paid_out_at=coalesce(provider_paid_out_at,v_now),
      admin_release_note=coalesce(nullif(p_note,''),admin_release_note,'Liquidación Wissa V62'),updated_at=v_now
  where id=p_booking_id;

  update public.payment_orders
  set release_status='released',provider_net=v_total,updated_at=v_now
  where booking_id=p_booking_id and status='approved';

  return v_result || jsonb_build_object(
    'provider_id',v_primary_provider,'payout_id',v_primary_payout,
    'title','Liquidación registrada','body','Wissa registró la liquidación individual de cada profesional del equipo.',
    'screen','/(provider-tabs)/earnings','released_at',v_now
  );
end;
$$;

grant execute on function public.yt_admin_release_booking_payment(uuid,text) to authenticated,service_role;
revoke execute on function public.yt_admin_release_booking_payment(uuid,text) from public,anon;

-- --------------------------------------------------------------------------
-- 6. Fidelidad: cada 10 servicios completados -> 50% en el siguiente elegible.
--    El descuento es financiado por Wissa y NO reduce el payout del profesional.
-- --------------------------------------------------------------------------
create or replace function public.yt_v62_issue_loyalty_reward_for_buyer(p_buyer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_completed int;
  v_cycles int;
  v_cycle int;
  v_created int:=0;
  v_source uuid;
begin
  select count(*) into v_completed from public.bookings b
  where b.buyer_id=p_buyer_id and b.payment_status='paid' and b.status in ('completed','completed_pending_release')
    and coalesce(b.refund_status,'not_requested') not in ('refunded','refund_processing');
  v_cycles:=floor(v_completed/10.0)::int;
  if v_cycles<=0 then return jsonb_build_object('completed',v_completed,'cycles',0,'created',0); end if;

  for v_cycle in 1..v_cycles loop
    if not exists(select 1 from public.loyalty_rewards r where r.user_id=p_buyer_id and r.role='client' and r.reward_type='client_50_discount' and r.cycle_number=v_cycle and r.status<>'cancelled') then
      select b.id into v_source from public.bookings b
      where b.buyer_id=p_buyer_id and b.payment_status='paid' and b.status in ('completed','completed_pending_release')
      order by coalesce(b.completed_at,b.updated_at,b.created_at),b.id offset (v_cycle*10-1) limit 1;
      insert into public.loyalty_rewards(user_id,role,booking_id,cycle_number,reward_type,percentage,amount,status,created_at,updated_at)
      values(p_buyer_id,'client',v_source,v_cycle,'client_50_discount',50,0,'earned',now(),now());
      v_created:=v_created+1;
      insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read,created_at)
      values(p_buyer_id,'Beneficio fidelidad desbloqueado','Completaste 10 servicios. Tu próximo servicio elegible tendrá 50% de descuento en el valor del servicio.','loyalty_reward','/(client-tabs)/home',v_source,jsonb_build_object('cycle',v_cycle,'percentage',50,'funded_by','wissa'),false,now());
    end if;
  end loop;
  return jsonb_build_object('completed',v_completed,'cycles',v_cycles,'created',v_created);
end;
$$;

grant execute on function public.yt_v62_issue_loyalty_reward_for_buyer(uuid) to authenticated,service_role;

create or replace function public.yt_v62_loyalty_status(p_user_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
declare v_user uuid:=coalesce(p_user_id,auth.uid()); v_completed int; v_available int; begin
  if v_user is null then return jsonb_build_object('completed',0,'progress',0,'available_rewards',0); end if;
  if auth.uid() is not null and auth.uid()<>v_user and not public.yt_admin_is_current_admin() then raise exception 'No autorizado.'; end if;
  select count(*) into v_completed from public.bookings where buyer_id=v_user and payment_status='paid' and status in ('completed','completed_pending_release') and coalesce(refund_status,'not_requested') not in ('refunded','refund_processing');
  select count(*) into v_available from public.loyalty_rewards where user_id=v_user and role='client' and reward_type='client_50_discount' and status='earned';
  return jsonb_build_object('completed',v_completed,'progress',v_completed%10,'remaining',case when v_completed%10=0 then 10 else 10-(v_completed%10) end,'available_rewards',v_available,'next_percentage',50);
end;
$$;

grant execute on function public.yt_v62_loyalty_status(uuid) to authenticated,service_role;

create or replace function public.yt_v62_loyalty_completion_trigger()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if new.status in ('completed','completed_pending_release') and (old.status is distinct from new.status) and new.payment_status='paid' then
    perform public.yt_v62_issue_loyalty_reward_for_buyer(new.buyer_id);
  end if;
  return new;
end; $$;

drop trigger if exists trg_v62_loyalty_completion on public.bookings;
create trigger trg_v62_loyalty_completion after update of status on public.bookings
for each row execute function public.yt_v62_loyalty_completion_trigger();

-- Sustituye la promo de primeros 10 por fidelidad; conserva bono cancelación USD 7.
create or replace function public.yt_apply_booking_benefits_v60(p_booking_id uuid,p_apply_cancel_bonus boolean default false)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  b public.bookings%rowtype;
  r public.loyalty_rewards%rowtype;
  cb public.customer_bonuses%rowtype;
  v_loyalty numeric:=0;
  v_cancel numeric:=0;
  v_pre_tax numeric:=0;
  v_taxable numeric:=0;
  v_tax_rate numeric:=0.07;
  v_tax numeric:=0;
  v_total numeric:=0;
  v_label text;
  v_code text;
  v_details jsonb;
begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  if auth.uid() is not null and auth.uid()<>b.buyer_id and not public.yt_admin_is_current_admin() then raise exception 'No autorizado.'; end if;
  if b.benefit_applied_at is not null then return jsonb_build_object('ok',true,'already_applied',true,'booking_id',b.id,'benefit_code',b.benefit_code,'benefit_label',b.benefit_label,'promotion_discount',b.promotion_discount_amount,'bonus_discount',b.bonus_discount_amount,'total',b.total_amount); end if;

  perform public.yt_v62_issue_loyalty_reward_for_buyer(b.buyer_id);
  select * into r from public.loyalty_rewards where user_id=b.buyer_id and role='client' and reward_type='client_50_discount' and status='earned' order by cycle_number for update skip locked limit 1;
  if found then
    v_loyalty:=round(greatest(coalesce(b.service_subtotal,0),0)*0.50,2);
    if v_loyalty>0 then
      update public.loyalty_rewards set status='applied',amount=v_loyalty,updated_at=now() where id=r.id;
      v_code:='loyalty_10_services_50'; v_label:='Beneficio fidelidad Wissa · 50%';
    end if;
  end if;

  if v_code is null and coalesce(p_apply_cancel_bonus,false) then
    select * into cb from public.customer_bonuses where buyer_id=b.buyer_id and status='available' and bonus_type='provider_cancel_7' and (expires_at is null or expires_at>=now()) order by issued_at for update skip locked limit 1;
    if found then
      v_cancel:=least(greatest(cb.amount,0),greatest(coalesce(b.subtotal_amount,0),0));
      update public.customer_bonuses set status='used',used_amount=v_cancel,used_booking_id=b.id,used_at=now(),updated_at=now() where id=cb.id;
      v_code:='provider_cancel_7'; v_label:='Bono por cancelación de quien ofrece · USD 7';
    end if;
  end if;

  v_pre_tax:=greatest(coalesce(b.subtotal_amount,0),0);
  v_tax_rate:=greatest(0,coalesce(b.tax_rate,0.07));
  v_taxable:=round(greatest(v_pre_tax-v_loyalty-v_cancel,0),2);
  v_tax:=round(v_taxable*v_tax_rate,2);
  v_total:=round(v_taxable+v_tax,2);
  v_details:=coalesce(b.service_details,'{}'::jsonb);
  v_details:=jsonb_set(v_details,'{benefits}',jsonb_build_object('code',v_code,'label',v_label,'promotion_discount',v_loyalty,'bonus_discount',v_cancel,'funded_by','wissa','provider_payout_protected',true,'subtotal_before_tax',v_pre_tax,'tax_rate',v_tax_rate,'tax_amount',v_tax,'final_total',v_total),true);
  v_details:=jsonb_set(v_details,'{pricing,tax_rate}',to_jsonb(v_tax_rate),true);
  v_details:=jsonb_set(v_details,'{pricing,tax_amount}',to_jsonb(v_tax),true);
  v_details:=jsonb_set(v_details,'{pricing,total_amount}',to_jsonb(v_total),true);

  update public.bookings set
    gross_total_amount=round(v_pre_tax+round(v_pre_tax*v_tax_rate,2),2),
    promotion_discount_amount=v_loyalty,
    bonus_discount_amount=v_cancel,
    loyalty_subsidy_amount=v_loyalty,
    benefit_code=v_code,benefit_label=v_label,benefit_applied_at=now(),applied_bonus_id=case when cb.id is not null then cb.id else null end,
    tax_amount=v_tax,total_amount=v_total,service_details=v_details,finance_version=62,updated_at=now()
  where id=b.id;

  return jsonb_build_object('ok',true,'booking_id',b.id,'benefit_code',v_code,'benefit_label',v_label,'promotion_discount',v_loyalty,'bonus_discount',v_cancel,'tax_amount',v_tax,'total',v_total,'provider_payout_protected',true);
end;
$$;

grant execute on function public.yt_apply_booking_benefits_v60(uuid,boolean) to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 7. Vista/RPC para auditoría financiera del Admin.
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_booking_distribution_v62(p_booking_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $$
declare b public.bookings%rowtype; v_team jsonb; begin
  if not public.yt_admin_is_current_admin() then raise exception 'Solo Admin Wissa.'; end if;
  select * into b from public.bookings where id=p_booking_id;
  if not found then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'slot',a.slot_number,'provider_id',a.provider_id,'provider_name',coalesce(p.full_name,p.display_name,p.email,'Profesional '||a.slot_number),
    'status',a.status,'gross_provider_amount',a.gross_provider_amount,'commission_amount',a.commission_amount,
    'service_share',a.service_share,'extras_share',a.extras_share,'travel_distance_km',a.travel_distance_km,
    'travel_rate_per_km',a.travel_rate_per_km,'travel_fee',a.travel_fee,'net_provider_amount',a.net_provider_amount,
    'payout_status',a.payout_status,'payout_id',a.payout_id
  ) order by a.slot_number),'[]'::jsonb) into v_team
  from public.booking_professional_assignments a left join public.profiles p on p.id=a.provider_id where a.booking_id=p_booking_id;

  return jsonb_build_object(
    'booking_id',b.id,'reservation_code',coalesce(b.reservation_code,'WISSA-'||upper(left(replace(b.id::text,'-',''),8))),
    'status',b.status,'payment_status',b.payment_status,'payout_release_status',b.payout_release_status,
    'required_professionals',b.required_professionals,'accepted_professionals',b.accepted_professionals,
    'client_total',b.total_amount,'gross_total',b.gross_total_amount,'service_subtotal',b.service_subtotal,
    'wissa_commission',b.platform_fee,'platform_usage_fee',b.platform_usage_fee,'kits_materials',b.kit_amount,
    'travel_total',b.travel_fee,'itbms',b.tax_amount,'loyalty_subsidy',b.loyalty_subsidy_amount,
    'provider_pool',b.provider_pool_amount,'commission_rate',b.commission_rate_snapshot,'team',v_team,'snapshot',b.financial_snapshot
  );
end;
$$;

grant execute on function public.yt_admin_booking_distribution_v62(uuid) to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 8. Defaults de comisión/costos por categoría y versión.
-- --------------------------------------------------------------------------
update public.app_settings set value=public.yt_v60_apply_pricing_rules(key,value),updated_at=now()
where key in ('cleaning_pricing','exterior_cleaning_pricing','plumbing_pricing');

update public.app_settings
set value=jsonb_set(jsonb_set(coalesce(value,'{}'::jsonb),'{platform_commission_rate}','0.20'::jsonb,true),'{pricing_version}','62'::jsonb,true),updated_at=now()
where key in ('cleaning_pricing','exterior_cleaning_pricing');

update public.app_settings
set value=jsonb_set(jsonb_set(coalesce(value,'{}'::jsonb),'{platform_commission_rate}','0.35'::jsonb,true),'{pricing_version}','62'::jsonb,true),updated_at=now()
where key='plumbing_pricing';

insert into public.app_settings(key,value,updated_at)
values('wissa_v62_release',jsonb_build_object(
  'version','62.0','client_tabs',4,'explore_removed',true,'max_professionals_per_booking',5,'matching_pool',15,
  'multi_accept_before_payment',true,'single_provider_normal_payment_flow',true,'category_commission',jsonb_build_object('cleaning',0.20,'exterior',0.20,'plumbing',0.35),
  'travel_rate_default',0.60,'loyalty_rule','every_10_completed_get_50_percent_next_service','invoice_pdf',true,'finance_snapshot',true
),now())
on conflict(key) do update set value=excluded.value,updated_at=now();


-- --------------------------------------------------------------------------
-- 9. Admin de beneficios V62 + banner de fidelidad.
--    Se conserva la firma de los RPC V60 para no romper el Admin existente,
--    pero la semantica de cliente ahora es recurrente: cada 10 completados.
-- --------------------------------------------------------------------------
update public.banners
set title='Completa 10 servicios y recibe 50%',
    metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
      'title_en','Complete 10 services and get 50% off',
      'subtitle','Cada 10 servicios completados desbloqueas 50% en el valor de tu siguiente servicio elegible.',
      'subtitle_en','Every 10 completed services unlocks 50% off the service value of your next eligible booking.',
      'cta','Ver mi progreso',
      'cta_en','View my progress',
      'rule','loyalty_every_10_completed_services_50_next_service'
    ),
    updated_at=now()
where image_url='wissa://banner/loyalty';

create or replace function public.wissa_loyalty_admin_summary_v60()
returns jsonb
language plpgsql
security definer
stable
set search_path=public,pg_temp
as $$
declare
  v_provider_id uuid;
  v_provider_limit integer:=10;
  v_provider_used integer:=0;
  v_provider_active boolean:=false;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then raise exception 'No autorizado'; end if;

  select id,max_redemptions,is_active
    into v_provider_id,v_provider_limit,v_provider_active
  from public.promotion_campaigns
  where code='launch_first10_offerers_50'
  limit 1;

  if v_provider_id is not null then
    select count(*)::int into v_provider_used
    from public.provider_completion_bonuses
    where campaign_id=v_provider_id and status<>'cancelled';
  end if;

  return jsonb_build_object(
    'client_completed_services',coalesce((select count(*) from public.bookings b where b.payment_status='paid' and b.status in ('completed','completed_pending_release') and coalesce(b.refund_status,'not_requested') not in ('refunded','refund_processing')),0),
    'client_loyalty_count',coalesce((select count(*) from public.loyalty_rewards r where r.role='client' and r.reward_type='client_50_discount' and r.status<>'cancelled'),0),
    'client_rewards_available',coalesce((select count(*) from public.loyalty_rewards r where r.role='client' and r.reward_type='client_50_discount' and r.status='earned'),0),
    'client_rewards_applied',coalesce((select count(*) from public.loyalty_rewards r where r.role='client' and r.reward_type='client_50_discount' and r.status='applied'),0),
    'client_loyalty_amount',coalesce((select round(sum(r.amount),2) from public.loyalty_rewards r where r.role='client' and r.reward_type='client_50_discount' and r.status='applied'),0),
    'provider_loyalty_count',v_provider_used,
    'provider_loyalty_amount',coalesce((select round(sum(amount),2) from public.provider_completion_bonuses where campaign_id=v_provider_id and status<>'cancelled'),0),
    'provider_limit',coalesce(v_provider_limit,10),
    'provider_remaining',greatest(coalesce(v_provider_limit,10)-v_provider_used,0),
    'provider_active',coalesce(v_provider_active,false) and v_provider_used<coalesce(v_provider_limit,10),
    'cancel_bonus_available',coalesce((select count(*) from public.customer_bonuses where bonus_type='provider_cancel_7' and status='available'),0),
    'cancel_bonus_available_amount',coalesce((select round(sum(amount-used_amount),2) from public.customer_bonuses where bonus_type='provider_cancel_7' and status='available'),0),
    'cancel_bonus_used_amount',coalesce((select round(sum(used_amount),2) from public.customer_bonuses where bonus_type='provider_cancel_7' and status='used'),0),
    'loyalty_rule','Cada 10 servicios completados -> 50% en el valor del siguiente servicio elegible'
  );
end;
$$;

revoke execute on function public.wissa_loyalty_admin_summary_v60() from public,anon;
grant execute on function public.wissa_loyalty_admin_summary_v60() to authenticated,service_role;

create or replace function public.wissa_loyalty_admin_rows_v60(
  p_search text default '',
  p_status text default 'all',
  p_limit integer default 250
)
returns table(
  record_kind text,
  id uuid,
  person_id uuid,
  person_name text,
  person_email text,
  person_role text,
  benefit_type text,
  benefit_label text,
  amount numeric,
  status text,
  source_booking_id uuid,
  used_booking_id uuid,
  issued_at timestamptz,
  used_at timestamptz
)
language plpgsql
security definer
stable
set search_path=public,pg_temp
as $$
declare
  v_search text:=lower(trim(coalesce(p_search,'')));
  v_status text:=lower(trim(coalesce(p_status,'all')));
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then raise exception 'No autorizado'; end if;

  return query
  with rows as (
    select
      'client_loyalty'::text record_kind,
      r.id,
      r.user_id person_id,
      coalesce(p.display_name,p.full_name,p.email,'Cliente')::text person_name,
      p.email::text person_email,
      'Cliente'::text person_role,
      r.reward_type::text benefit_type,
      ('Fidelidad ciclo '||r.cycle_number||' · 50% próximo servicio')::text benefit_label,
      r.amount::numeric amount,
      r.status::text status,
      r.booking_id source_booking_id,
      null::uuid used_booking_id,
      r.created_at issued_at,
      case when r.status='applied' then r.updated_at else null end used_at
    from public.loyalty_rewards r
    left join public.profiles p on p.id=r.user_id
    where r.role='client' and r.reward_type='client_50_discount'

    union all

    select
      'provider_launch_bonus'::text,
      b.id,b.provider_id,
      coalesce(p.display_name,p.full_name,p.email,'Ofrecer')::text,
      p.email::text,
      'Ofrecer'::text,
      'launch_first10_offerers_50'::text,
      'Bono lanzamiento Ofrecer · USD 50'::text,
      b.amount::numeric,b.status::text,b.source_booking_id,null::uuid,b.earned_at,b.paid_at
    from public.provider_completion_bonuses b
    join public.promotion_campaigns c on c.id=b.campaign_id and c.code='launch_first10_offerers_50'
    left join public.profiles p on p.id=b.provider_id

    union all

    select
      'customer_bonus'::text,b.id,b.buyer_id,
      coalesce(p.display_name,p.full_name,p.email,'Cliente')::text,p.email::text,'Cliente'::text,
      b.bonus_type::text,'Bono cancelación tardía · USD 7'::text,b.amount,b.status,
      b.source_booking_id,b.used_booking_id,b.issued_at,b.used_at
    from public.customer_bonuses b
    left join public.profiles p on p.id=b.buyer_id
    where b.bonus_type='provider_cancel_7'
  )
  select * from rows r
  where (v_status='all' or lower(r.status)=v_status)
    and (v_search='' or lower(concat_ws(' ',r.person_name,r.person_email,r.person_role,r.benefit_label,r.benefit_type)) like '%'||v_search||'%')
  order by r.issued_at desc
  limit greatest(1,least(coalesce(p_limit,250),1000));
end;
$$;

revoke execute on function public.wissa_loyalty_admin_rows_v60(text,text,integer) from public,anon;
grant execute on function public.wissa_loyalty_admin_rows_v60(text,text,integer) to authenticated,service_role;

commit;
