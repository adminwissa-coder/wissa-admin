-- ==========================================================================
-- WISSA V60.3 - FINANZAS, PLOMERIA, PROMOCION LIMITADA, BANNERS Y QA
-- Fecha: 2026-09-11
-- Incremental e idempotente. Ejecutar primero en copia/ambiente de pruebas.
-- NO borra usuarios ni historicos.
-- ==========================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. Reglas oficiales V60
-- --------------------------------------------------------------------------
insert into public.app_settings(key, value, updated_at)
values (
  'wissa_v60_rules',
  jsonb_build_object(
    'version', 60,
    'currency', 'USD',
    'cleaning_commission_rate', 0.20,
    'exterior_commission_rate', 0.20,
    'plumbing_commission_rate', 0.35,
    'travel_rate_per_km', 0.60,
    'platform_usage_fee', 2.00,
    'itbms_rate', 0.07,
    'refund_min_hours', 24,
    'refund_max_hours', 72,
    'launch_client_limit', 10,
    'launch_client_discount_percent', 50,
    'launch_provider_limit', 10,
    'launch_provider_bonus_usd', 50,
    'launch_total_benefits', 20,
    'plumbing_mode', 'diagnosis_only'
  ),
  now()
)
on conflict (key) do update
set value = excluded.value,
    updated_at = now();

insert into public.app_settings(key, value, updated_at)
values
  ('platform_commission', '{"rate":0.20,"percent":20,"label":"Comision Wissa general"}'::jsonb, now()),
  ('platform_commission_percent', '{"rate":0.20,"percent":20,"label":"20%"}'::jsonb, now())
on conflict (key) do update
set value = excluded.value,
    updated_at = now();

alter table public.bookings
  add column if not exists tax_rate numeric not null default 0.07;

comment on column public.bookings.tax_rate is 'V60: ITBMS aplicado al importe final sujeto a impuesto. Regla oficial 7%.';

-- --------------------------------------------------------------------------
-- 2. Normalizacion V60 de pricing sin romper precios administrados
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
  v_inspection numeric := 25;
begin
  if jsonb_typeof(v_value) <> 'object' then v_value := '{}'::jsonb; end if;

  v_value := jsonb_set(v_value, '{pricing_version}', '60'::jsonb, true);
  v_value := jsonb_set(v_value, '{travel_mode}', 'road_distance'::jsonb, true);
  v_value := jsonb_set(v_value, '{travel_flat_fee}', '0'::jsonb, true);
  v_value := jsonb_set(v_value, '{travel_rate_per_km}', '0.60'::jsonb, true);

  if v_key = 'plumbing_pricing' then
    v_inspection := greatest(coalesce(
      nullif(v_value->>'inspection_fee','')::numeric,
      nullif(v_value #>> '{job_base,revision}','')::numeric,
      25
    ), 0);
    v_value := jsonb_set(v_value, '{platform_commission_rate}', '0.35'::jsonb, true);
    v_value := jsonb_set(v_value, '{pricing_mode}', 'inspection_road_v60'::jsonb, true);
    v_value := jsonb_set(v_value, '{inspection_fee}', to_jsonb(v_inspection), true);
    v_value := jsonb_set(v_value, '{job_base,revision}', to_jsonb(v_inspection), true);
    v_value := jsonb_set(v_value, '{quote_after_inspection}', 'false'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,enabled}', 'false'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,basic,price}', '0'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,premium,price}', '0'::jsonb, true);
    v_value := jsonb_set(v_value, '{plumbing_mode}', '"diagnosis_only"'::jsonb, true);
    return v_value;
  end if;

  if v_key in ('cleaning_pricing','exterior_cleaning_pricing') then
    v_value := jsonb_set(v_value, '{platform_commission_rate}', '0.20'::jsonb, true);
    return v_value;
  end if;

  return v_value;
exception when others then
  return coalesce(p_value, '{}'::jsonb);
end;
$$;

grant execute on function public.yt_v60_apply_pricing_rules(text,jsonb) to anon, authenticated, service_role;

-- Actualiza los tres valores actuales sin alterar las tarifas configuradas.
update public.app_settings a
set value = public.yt_v60_apply_pricing_rules(a.key, a.value),
    updated_at = now()
where a.key in ('cleaning_pricing','exterior_cleaning_pricing','plumbing_pricing');

-- Si no existe Plomeria, crea una base segura de USD 25 diagnostico.
insert into public.app_settings(key, value, updated_at)
select 'plumbing_pricing', public.yt_v60_apply_pricing_rules('plumbing_pricing', jsonb_build_object(
  'inspection_fee', 25,
  'job_base', jsonb_build_object('revision',25),
  'currency','USD'
)), now()
where not exists (select 1 from public.app_settings where key='plumbing_pricing');

-- Guardado global desde Admin: aplica la capa V60 DESPUES de cualquier normalizador historico.
create or replace function public.yt_admin_update_service_pricing(p_key text, p_value jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := lower(trim(coalesce(p_key, '')));
  v_normalized jsonb;
  v_updated_at timestamptz := now();
  v_synced_services integer := 0;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;
  if v_key not in ('cleaning_pricing','exterior_cleaning_pricing','plumbing_pricing') then
    raise exception 'Configuracion no permitida: %', p_key;
  end if;

  v_normalized := public.yt_normalize_service_pricing_value(v_key, coalesce(p_value,'{}'::jsonb));
  v_normalized := public.yt_v60_apply_pricing_rules(v_key, v_normalized || coalesce(p_value,'{}'::jsonb));

  insert into public.app_settings(key,value,updated_by,updated_at)
  values(v_key,v_normalized,auth.uid(),v_updated_at)
  on conflict(key) do update set value=excluded.value, updated_by=excluded.updated_by, updated_at=excluded.updated_at;

  update public.services s
  set price = case
      when v_key='plumbing_pricing' then greatest(coalesce(nullif(v_normalized->>'inspection_fee','')::numeric,25),0)
      else public.yt_base_service_price(s.category, v_normalized)
    end,
    updated_at = v_updated_at
  where public.yt_category_matches_pricing_key(s.category,v_key)
    and (s.company_id is null or not exists (
      select 1 from public.company_service_pricing_settings cps
      where cps.company_id=s.company_id and cps.pricing_key=v_key
    ));
  get diagnostics v_synced_services = row_count;

  return jsonb_build_object('ok',true,'key',v_key,'value',v_normalized,'updated_at',v_updated_at,'synced_services',v_synced_services);
end;
$$;

revoke execute on function public.yt_admin_update_service_pricing(text,jsonb) from public, anon;
grant execute on function public.yt_admin_update_service_pricing(text,jsonb) to authenticated, service_role;

-- V60.1: sincroniza inmediatamente los servicios existentes con la tarifa global
-- ya configurada en Categorias y precios. Esto corrige servicios historicos con
-- price/base_price en 0 sin esperar a que el administrador vuelva a guardar.
do $$
declare
  v_setting record;
  v_value jsonb;
begin
  for v_setting in
    select key, value
    from public.app_settings
    where key in ('cleaning_pricing','exterior_cleaning_pricing','plumbing_pricing')
  loop
    v_value := public.yt_v60_apply_pricing_rules(v_setting.key, v_setting.value);

    update public.services s
    set price = case
        when v_setting.key='plumbing_pricing' then greatest(coalesce(
          nullif(v_value->>'inspection_fee','')::numeric,
          nullif(v_value #>> '{job_base,revision}','')::numeric,
          25
        ),0)
        else public.yt_base_service_price(s.category, v_value)
      end,
      updated_at = now()
    where public.yt_category_matches_pricing_key(s.category,v_setting.key)
      and (s.company_id is null or not exists (
        select 1
        from public.company_service_pricing_settings cps
        where cps.company_id=s.company_id
          and cps.pricing_key=v_setting.key
      ));
  end loop;
end;
$$;

-- Empresa: tambien aplica 20% limpieza/exterior y 35% plomeria; sin Kit Wissa.
create or replace function public.yt_company_strip_wissa_kits_v41(p_key text, p_value jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_key text := lower(trim(coalesce(p_key,'')));
  v_value jsonb;
  v_policy jsonb;
begin
  if v_key not in ('cleaning_pricing','exterior_cleaning_pricing','plumbing_pricing') then
    raise exception 'Configuracion no permitida: %', p_key;
  end if;
  v_value := public.yt_normalize_service_pricing_value(v_key,coalesce(p_value,'{}'::jsonb));
  v_value := public.yt_v60_apply_pricing_rules(v_key,v_value || coalesce(p_value,'{}'::jsonb));
  v_value := jsonb_set(v_value,'{cleaning_kit_enabled}','false'::jsonb,true);
  v_value := jsonb_set(v_value,'{cleaning_kit_price}','0'::jsonb,true);
  v_value := jsonb_set(v_value,'{kits,enabled}','false'::jsonb,true);
  v_value := jsonb_set(v_value,'{kits,basic,price}','0'::jsonb,true);
  v_value := jsonb_set(v_value,'{kits,premium,price}','0'::jsonb,true);
  v_policy := case when v_key='plumbing_pricing'
    then jsonb_build_object('mode','diagnosis_only','label','Solo diagnostico','description','La reparacion posterior se coordina directamente entre empresa y proveedor.')
    else jsonb_build_object('mode','company_provided','label','Materiales aportados por la empresa','description','Wissa no cobra kits en servicios empresariales.')
  end;
  return v_value || jsonb_build_object('company_materials_policy',v_policy,'company_wissa_kit_enabled',false);
end;
$$;

revoke execute on function public.yt_company_strip_wissa_kits_v41(text,jsonb) from public, anon;
grant execute on function public.yt_company_strip_wissa_kits_v41(text,jsonb) to authenticated, service_role;

update public.company_service_pricing_settings cps
set value = public.yt_company_strip_wissa_kits_v41(cps.pricing_key,cps.value), updated_at=now()
where cps.pricing_key in ('cleaning_pricing','exterior_cleaning_pricing','plumbing_pricing');

-- --------------------------------------------------------------------------
-- 3. Plomeria solo diagnostico: elimina catalogo de cobro y desactiva campos de precio legacy
-- --------------------------------------------------------------------------
delete from public.booking_catalog
where lower(translate(coalesce(category_name,''),'íóáéúñ','ioaeun')) like '%plomer%';

update public.service_category_fields
set is_active=false, updated_at=now()
where lower(translate(coalesce(category_name,''),'íóáéúñ','ioaeun')) like '%plomer%'
  and field_key in ('plumbing_complexity','plumbing_points','plumbing_parts','parts','complexity','points');

-- Guardia dura: no permitir catalogo Plomeria por acceso directo.
create or replace function public.yt_v60_guard_plumbing_catalog()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  if lower(translate(coalesce(new.category_name,''),'íóáéúñ','ioaeun')) like '%plomer%' then
    raise exception 'V60: Plomeria no admite extras, kits ni materiales dentro de Wissa.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_v60_guard_plumbing_catalog on public.booking_catalog;
create trigger trg_v60_guard_plumbing_catalog
before insert or update on public.booking_catalog
for each row execute function public.yt_v60_guard_plumbing_catalog();

-- --------------------------------------------------------------------------
-- 4. Finanzas: comision por categoria, ITBMS al final y traslado 100% proveedor
-- --------------------------------------------------------------------------
create or replace function public.yt_platform_commission_rate()
returns numeric
language sql
stable
set search_path=public
as $$ select 0.20::numeric $$;

grant execute on function public.yt_platform_commission_rate() to anon, authenticated, service_role;

create or replace function public.yt_v60_commission_rate_for_booking(p_category text)
returns numeric
language sql
immutable
as $$
  select case
    when lower(translate(coalesce(p_category,''),'íóáéúñ','ioaeun')) like '%plomer%' then 0.35::numeric
    else 0.20::numeric
  end
$$;

grant execute on function public.yt_v60_commission_rate_for_booking(text) to anon,authenticated,service_role;

create or replace function public.yt_apply_booking_finance_guard()
returns trigger
language plpgsql
set search_path=public
as $$
declare
  v_category text := coalesce(new.service_details->>'category',new.service_title,'');
  v_rate numeric := 0.20;
  v_service numeric := greatest(coalesce(new.service_subtotal,0),0);
  v_kit numeric := greatest(coalesce(new.kit_amount,0),0);
  v_travel numeric := greatest(coalesce(new.travel_fee,0),0);
  v_usage numeric := greatest(coalesce(new.platform_usage_fee,0),0);
  v_pre_tax numeric := greatest(coalesce(new.subtotal_amount,0),0);
  v_discount numeric := greatest(coalesce(new.promotion_discount_amount,0),0) + greatest(coalesce(new.bonus_discount_amount,0),0);
  v_taxable numeric := 0;
begin
  if (v_category is null or trim(v_category)='') and new.service_id is not null then
    select coalesce(s.category,'') into v_category from public.services s where s.id=new.service_id;
  end if;
  v_rate := public.yt_v60_commission_rate_for_booking(v_category);

  -- Plomeria: sin kit/materiales dentro de Wissa.
  if v_rate=0.35 then
    new.kit_amount := 0;
    new.wissa_kit_revenue := 0;
    v_kit := 0;
  end if;

  if v_service <= 0 and v_pre_tax > 0 then
    v_service := greatest(v_pre_tax - v_kit - v_travel - v_usage,0);
    new.service_subtotal := round(v_service,2);
  end if;

  new.platform_fee := round(v_service*v_rate,2);
  new.seller_payout := round(greatest(v_service-new.platform_fee,0)+v_travel,2);
  new.wissa_kit_revenue := case when v_rate=0.35 then 0 else round(v_kit,2) end;
  new.wissa_total_revenue := round(new.platform_fee + new.wissa_kit_revenue + v_usage,2);

  if coalesce(new.finance_version,0) >= 60 then
    new.tax_rate := 0.07;
    if v_pre_tax <= 0 then
      v_pre_tax := round(v_service+v_kit+v_travel+v_usage,2);
      new.subtotal_amount := v_pre_tax;
    end if;
    v_taxable := round(greatest(v_pre_tax-v_discount,0),2);
    new.tax_amount := round(v_taxable*0.07,2);
    new.total_amount := round(v_taxable+new.tax_amount,2);
  end if;

  return new;
end;
$$;

drop trigger if exists yt_apply_booking_finance_guard_trg on public.bookings;
create trigger yt_apply_booking_finance_guard_trg
before insert or update of subtotal_amount,total_amount,service_subtotal,kit_amount,travel_fee,platform_usage_fee,promotion_discount_amount,bonus_discount_amount,platform_fee,seller_payout
on public.bookings
for each row execute function public.yt_apply_booking_finance_guard();

create or replace function public.yt_apply_payment_order_finance_guard()
returns trigger
language plpgsql
set search_path=public
as $$
declare
  v_total numeric:=0;
  v_fee numeric:=0;
  v_provider numeric:=0;
begin
  if new.booking_id is not null then
    select coalesce(b.total_amount,0),coalesce(b.platform_fee,0),coalesce(b.seller_payout,0)
      into v_total,v_fee,v_provider
    from public.bookings b where b.id=new.booking_id;
  end if;
  if v_total<=0 then v_total:=greatest(coalesce(new.amount_total,new.amount,0),0); end if;
  if coalesce(new.amount_total,0)=0 then new.amount_total:=round(v_total,2); end if;
  if coalesce(new.amount,0)=0 then new.amount:=round(v_total,2); end if;
  new.platform_fee:=round(v_fee,2);
  new.provider_net:=round(v_provider,2);
  return new;
end;
$$;

drop trigger if exists yt_apply_payment_order_finance_guard_trg on public.payment_orders;
create trigger yt_apply_payment_order_finance_guard_trg
before insert or update of amount_total,amount,platform_fee,provider_net,booking_id
on public.payment_orders
for each row execute function public.yt_apply_payment_order_finance_guard();

-- --------------------------------------------------------------------------
-- 5. Promocion de lanzamiento limitada: 10 clientes + 10 Ofrecer
--    Cliente: primeros 10 clientes distintos -> 50% sobre el servicio elegible.
--    Ofrecer independiente: primeros 10 distintos -> USD 50 al completar
--    su primera reserva elegible. Cada persona participa una sola vez.
--    Al agotarse ambos cupos (20 beneficios) la promocion queda finalizada.
-- --------------------------------------------------------------------------
create table if not exists public.promotion_campaigns (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  benefit_type text not null check (benefit_type in ('percentage','fixed')),
  benefit_value numeric not null check (benefit_value > 0),
  max_redemptions integer not null check (max_redemptions > 0),
  service_scope text not null default 'any' check (service_scope in ('any','cleaning')),
  is_active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.promotion_redemptions (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.promotion_campaigns(id) on delete cascade,
  buyer_id uuid not null references public.profiles(id),
  booking_id uuid not null references public.bookings(id),
  discount_percent numeric not null default 0,
  discount_amount numeric not null default 0,
  status text not null default 'applied' check (status in ('applied','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create unique index if not exists uq_promotion_redemption_booking_active
  on public.promotion_redemptions (booking_id) where status='applied';
create unique index if not exists uq_promotion_redemption_buyer_campaign_active
  on public.promotion_redemptions (campaign_id,buyer_id) where status='applied';
create index if not exists idx_promotion_redemptions_campaign_status
  on public.promotion_redemptions (campaign_id,status,created_at);

create table if not exists public.provider_completion_bonuses (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.promotion_campaigns(id) on delete restrict,
  provider_id uuid not null references public.profiles(id),
  source_booking_id uuid not null references public.bookings(id),
  amount numeric not null default 50 check (amount > 0),
  status text not null default 'earned' check (status in ('earned','paid','cancelled')),
  earned_at timestamptz not null default now(),
  paid_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uq_provider_completion_bonus_provider_campaign
  on public.provider_completion_bonuses (campaign_id,provider_id) where status<>'cancelled';
create unique index if not exists uq_provider_completion_bonus_booking_campaign
  on public.provider_completion_bonuses (campaign_id,source_booking_id) where status<>'cancelled';
create index if not exists idx_provider_completion_bonus_status
  on public.provider_completion_bonuses (campaign_id,status,earned_at);

alter table public.bookings
  add column if not exists provider_bonus_amount numeric not null default 0,
  add column if not exists provider_bonus_id uuid;

do $$ begin
  alter table public.bookings drop constraint if exists bookings_provider_bonus_id_fkey;
  alter table public.bookings add constraint bookings_provider_bonus_id_fkey
    foreign key (provider_bonus_id) references public.provider_completion_bonuses(id);
exception when duplicate_object then null; end $$;

alter table public.promotion_campaigns enable row level security;
alter table public.promotion_redemptions enable row level security;
alter table public.provider_completion_bonuses enable row level security;

drop policy if exists promotion_campaigns_read_v37 on public.promotion_campaigns;
create policy promotion_campaigns_read_v37 on public.promotion_campaigns for select to authenticated
using (is_active=true or public.yt_admin_is_current_admin());
drop policy if exists promotion_redemptions_owner_read_v37 on public.promotion_redemptions;
create policy promotion_redemptions_owner_read_v37 on public.promotion_redemptions for select to authenticated
using (buyer_id=auth.uid() or public.yt_admin_is_current_admin());
drop policy if exists provider_completion_bonuses_owner_read_v38 on public.provider_completion_bonuses;
create policy provider_completion_bonuses_owner_read_v38 on public.provider_completion_bonuses for select to authenticated
using (provider_id=auth.uid() or public.yt_admin_is_current_admin());

revoke insert,update,delete on public.promotion_redemptions from authenticated;
revoke insert,update,delete on public.provider_completion_bonuses from authenticated;
grant select on public.promotion_campaigns,public.promotion_redemptions,public.provider_completion_bonuses to authenticated;

insert into public.promotion_campaigns(code,name,benefit_type,benefit_value,max_redemptions,service_scope,is_active,starts_at,metadata)
values(
  'launch_first10_50','Primeros 10 clientes - 50%','percentage',50,10,'cleaning',true,now(),
  jsonb_build_object('audience','client','one_per_user',true,'funded_by','wissa','description','50% sobre el servicio elegible para los primeros 10 clientes distintos.')
)
on conflict(code) do update set
  name=excluded.name,benefit_type=excluded.benefit_type,benefit_value=excluded.benefit_value,
  max_redemptions=excluded.max_redemptions,service_scope=excluded.service_scope,
  metadata=excluded.metadata,updated_at=now();

insert into public.promotion_campaigns(code,name,benefit_type,benefit_value,max_redemptions,service_scope,is_active,starts_at,metadata)
values(
  'launch_first10_offerers_50','Primeros 10 Ofrecer - USD 50','fixed',50,10,'cleaning',true,now(),
  jsonb_build_object('audience','provider','role','ofrecer','one_per_provider',true,'funded_by','wissa','description','USD 50 para los primeros 10 Ofrecer independientes que completen una reserva elegible.')
)
on conflict(code) do update set
  name=excluded.name,benefit_type=excluded.benefit_type,benefit_value=excluded.benefit_value,
  max_redemptions=excluded.max_redemptions,service_scope=excluded.service_scope,
  metadata=excluded.metadata,updated_at=now();

-- V60.2 pudo dejar estas campañas inactivas. V60.3 las reactiva solo mientras queden cupos.
update public.promotion_campaigns c
set is_active=true, ends_at=null, updated_at=now()
where c.code='launch_first10_50'
  and (
    select count(*) from public.promotion_redemptions r
    where r.campaign_id=c.id and r.status='applied'
  ) < coalesce(c.max_redemptions,10);

update public.promotion_campaigns c
set is_active=true, ends_at=null, updated_at=now()
where c.code='launch_first10_offerers_50'
  and (
    select count(*) from public.provider_completion_bonuses b
    where b.campaign_id=c.id and b.status<>'cancelled'
  ) < coalesce(c.max_redemptions,10);

-- La regla V60 anterior de fidelidad ciclica queda deshabilitada.
drop trigger if exists trg_v60_provider_loyalty_bonus on public.bookings;

create or replace function public.yt_v603_refresh_launch_campaign_state()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_client_count integer:=0;
  v_provider_count integer:=0;
  v_client_limit integer:=10;
  v_provider_limit integer:=10;
  v_complete boolean:=false;
begin
  select coalesce(c.max_redemptions,10),count(r.id)::int
  into v_client_limit,v_client_count
  from public.promotion_campaigns c
  left join public.promotion_redemptions r on r.campaign_id=c.id and r.status='applied'
  where c.code='launch_first10_50'
  group by c.max_redemptions;

  select coalesce(c.max_redemptions,10),count(b.id)::int
  into v_provider_limit,v_provider_count
  from public.promotion_campaigns c
  left join public.provider_completion_bonuses b on b.campaign_id=c.id and b.status<>'cancelled'
  where c.code='launch_first10_offerers_50'
  group by c.max_redemptions;

  v_client_count:=coalesce(v_client_count,0);
  v_provider_count:=coalesce(v_provider_count,0);
  v_complete:=v_client_count>=v_client_limit and v_provider_count>=v_provider_limit;

  if v_client_count>=v_client_limit then
    update public.promotion_campaigns set is_active=false,ends_at=coalesce(ends_at,now()),updated_at=now()
    where code='launch_first10_50' and is_active=true;

    -- El banner deja de mostrarse cuando ya no quedan cupos de cliente.
    update public.banners
    set is_active=false, status='paused', updated_at=now()
    where image_url='wissa://banner/loyalty' and is_active=true;
  end if;
  if v_provider_count>=v_provider_limit then
    update public.promotion_campaigns set is_active=false,ends_at=coalesce(ends_at,now()),updated_at=now()
    where code='launch_first10_offerers_50' and is_active=true;
  end if;

  insert into public.app_settings(key,value,updated_at)
  values('launch_promo_v603',jsonb_build_object(
    'client_limit',v_client_limit,'client_used',v_client_count,
    'provider_limit',v_provider_limit,'provider_used',v_provider_count,
    'total_limit',v_client_limit+v_provider_limit,'total_used',v_client_count+v_provider_count,
    'completed',v_complete
  ),now())
  on conflict(key) do update set value=excluded.value,updated_at=now();

  return jsonb_build_object(
    'client_limit',v_client_limit,'client_used',v_client_count,
    'provider_limit',v_provider_limit,'provider_used',v_provider_count,
    'total_limit',v_client_limit+v_provider_limit,'total_used',v_client_count+v_provider_count,
    'completed',v_complete
  );
end;
$$;

create or replace function public.yt_apply_booking_benefits_v60(
  p_booking_id uuid,
  p_apply_cancel_bonus boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_booking public.bookings%rowtype;
  v_campaign public.promotion_campaigns%rowtype;
  v_bonus public.customer_bonuses%rowtype;
  v_category text:='';
  v_is_cleaning boolean:=false;
  v_count integer:=0;
  v_promo numeric:=0;
  v_bonus_discount numeric:=0;
  v_pre_tax numeric:=0;
  v_taxable numeric:=0;
  v_tax numeric:=0;
  v_total numeric:=0;
  v_label text:=null;
  v_code text:=null;
  v_now timestamptz:=now();
  v_details jsonb:='{}'::jsonb;
begin
  select * into v_booking from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  if auth.uid() is not null and auth.uid()<>v_booking.buyer_id and not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado.';
  end if;
  if v_booking.benefit_applied_at is not null then
    return jsonb_build_object('ok',true,'already_applied',true,'booking_id',v_booking.id,'benefit_code',v_booking.benefit_code,'benefit_label',v_booking.benefit_label,'promotion_discount',v_booking.promotion_discount_amount,'bonus_discount',v_booking.bonus_discount_amount,'total',v_booking.total_amount);
  end if;
  if coalesce(v_booking.payment_status,'not_started')='paid' or v_booking.status not in ('pending','pending_payment') then
    return jsonb_build_object('ok',true,'eligible',false,'reason','booking_not_open_for_benefits','booking_id',v_booking.id,'total',v_booking.total_amount);
  end if;

  select coalesce(s.category,v_booking.service_details->>'category','') into v_category
  from public.services s where s.id=v_booking.service_id;
  if coalesce(v_category,'')='' then v_category:=coalesce(v_booking.service_details->>'category',''); end if;
  v_is_cleaning:=lower(v_category) like '%limpieza%' or lower(v_category) like '%clean%';

  select * into v_campaign from public.promotion_campaigns c
  where c.code='launch_first10_50' and c.is_active=true
    and (c.starts_at is null or c.starts_at<=v_now)
    and (c.ends_at is null or c.ends_at>=v_now)
  limit 1;

  if found and v_is_cleaning then
    perform pg_advisory_xact_lock(hashtext('wissa:launch_first10_50')::bigint);
    select count(*)::int into v_count from public.promotion_redemptions r
    where r.campaign_id=v_campaign.id and r.status='applied';
    if v_count<v_campaign.max_redemptions and not exists(
      select 1 from public.promotion_redemptions r
      where r.campaign_id=v_campaign.id and r.buyer_id=v_booking.buyer_id and r.status='applied'
    ) then
      -- El 50% aplica solo al servicio; traslado, plataforma, kits e ITBMS no reciben descuento.
      v_promo:=round(greatest(coalesce(v_booking.service_subtotal,0),0)*(v_campaign.benefit_value/100.0),2);
      if v_promo>0 then
        v_code:=v_campaign.code;
        v_label:='Promoción primeros 10 clientes · 50%';
        insert into public.promotion_redemptions(campaign_id,buyer_id,booking_id,discount_percent,discount_amount,status,metadata)
        values(v_campaign.id,v_booking.buyer_id,v_booking.id,v_campaign.benefit_value,v_promo,'applied',
          jsonb_build_object('service_category',v_category,'funded_by','wissa','rule','first10_clients_once'));
        perform public.yt_v603_refresh_launch_campaign_state();
      end if;
    end if;
  end if;

  -- USD 7 sigue siendo compensacion por cancelacion tardia y no se combina con la promo 50%.
  if v_code is null and coalesce(p_apply_cancel_bonus,false) then
    select * into v_bonus from public.customer_bonuses b
    where b.buyer_id=v_booking.buyer_id and b.status='available' and b.bonus_type='provider_cancel_7'
      and (b.expires_at is null or b.expires_at>=v_now)
    order by b.issued_at asc for update skip locked limit 1;
    if found then
      v_bonus_discount:=least(greatest(v_bonus.amount,0),greatest(coalesce(v_booking.subtotal_amount,0),0));
      update public.customer_bonuses set status='used',used_amount=v_bonus_discount,used_booking_id=v_booking.id,used_at=v_now,updated_at=v_now where id=v_bonus.id;
      v_label:='Bono por cancelación de quien ofrece · USD 7';
      v_code:='provider_cancel_7';
    end if;
  end if;

  v_pre_tax:=greatest(coalesce(v_booking.subtotal_amount,0),0);
  v_taxable:=round(greatest(v_pre_tax-v_promo-v_bonus_discount,0),2);
  v_tax:=round(v_taxable*0.07,2);
  v_total:=round(v_taxable+v_tax,2);
  v_details:=coalesce(v_booking.service_details,'{}'::jsonb);
  v_details:=jsonb_set(v_details,'{benefits}',jsonb_build_object(
    'code',v_code,'label',v_label,'promotion_discount',v_promo,'bonus_discount',v_bonus_discount,
    'subtotal_before_tax',v_pre_tax,'tax_rate',0.07,'tax_amount',v_tax,'final_total',v_total
  ),true);
  v_details:=jsonb_set(v_details,'{pricing,tax_rate}','0.07'::jsonb,true);
  v_details:=jsonb_set(v_details,'{pricing,tax_amount}',to_jsonb(v_tax),true);
  v_details:=jsonb_set(v_details,'{pricing,total_amount}',to_jsonb(v_total),true);

  update public.bookings set
    gross_total_amount=round(v_pre_tax+round(v_pre_tax*0.07,2),2),
    promotion_discount_amount=v_promo,
    bonus_discount_amount=v_bonus_discount,
    benefit_code=v_code,
    benefit_label=v_label,
    benefit_applied_at=v_now,
    applied_bonus_id=case when v_bonus.id is not null then v_bonus.id else null end,
    tax_rate=0.07,
    tax_amount=v_tax,
    total_amount=v_total,
    service_details=v_details,
    finance_version=60,
    updated_at=v_now
  where id=v_booking.id;

  return jsonb_build_object('ok',true,'booking_id',v_booking.id,'benefit_code',v_code,'benefit_label',v_label,'promotion_discount',v_promo,'bonus_discount',v_bonus_discount,'tax_amount',v_tax,'total',v_total,'cancel_bonus_applied',v_bonus_discount>0);
end;
$$;
revoke execute on function public.yt_apply_booking_benefits_v60(uuid,boolean) from public,anon;
grant execute on function public.yt_apply_booking_benefits_v60(uuid,boolean) to authenticated,service_role;

create or replace function public.yt_v603_grant_provider_launch_bonus()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_campaign public.promotion_campaigns%rowtype;
  v_category text:='';
  v_is_cleaning boolean:=false;
  v_is_offerer boolean:=false;
  v_bonus_id uuid;
  v_base_payout numeric:=0;
  v_count integer:=0;
begin
  if new.provider_id is null or coalesce(new.payment_status,'')<>'paid'
     or new.status not in ('completed_pending_release','completed') then return new; end if;
  if tg_op='UPDATE' and old.status in ('completed_pending_release','completed') then return new; end if;

  -- Personal de empresa no consume los 10 cupos de Ofrecer independiente.
  if coalesce(new.is_company_booking,false) or new.company_id is not null or new.company_member_id is not null
     or exists(select 1 from public.services sx where sx.id=new.service_id and (coalesce(sx.source_type,'')='company_service' or sx.company_id is not null or sx.company_member_id is not null))
  then return new; end if;

  select * into v_campaign from public.promotion_campaigns c
  where c.code='launch_first10_offerers_50' and c.is_active=true
    and (c.starts_at is null or c.starts_at<=now()) and (c.ends_at is null or c.ends_at>=now()) limit 1;
  if not found then return new; end if;

  select coalesce(s.category,new.service_details->>'category','') into v_category from public.services s where s.id=new.service_id;
  if coalesce(v_category,'')='' then v_category:=coalesce(new.service_details->>'category',''); end if;
  v_is_cleaning:=lower(v_category) like '%limpieza%' or lower(v_category) like '%clean%';
  if not v_is_cleaning then return new; end if;

  select exists(select 1 from public.profiles p where p.id=new.provider_id and (
    lower(coalesce(p.role,'')) in ('provider','vendor','ofrecer','both','ambos')
    or lower(coalesce(p.mode_preference,''))='provider' or coalesce(p.provider_enabled,false)=true
  )) into v_is_offerer;
  if not v_is_offerer then return new; end if;

  perform pg_advisory_xact_lock(hashtext('wissa:launch_first10_offerers_50')::bigint);
  if exists(select 1 from public.provider_completion_bonuses b where b.campaign_id=v_campaign.id and b.provider_id=new.provider_id and b.status<>'cancelled') then return new; end if;
  select count(*)::int into v_count from public.provider_completion_bonuses b where b.campaign_id=v_campaign.id and b.status<>'cancelled';
  if v_count>=v_campaign.max_redemptions then
    perform public.yt_v603_refresh_launch_campaign_state();
    return new;
  end if;

  insert into public.provider_completion_bonuses(campaign_id,provider_id,source_booking_id,amount,status,metadata)
  values(v_campaign.id,new.provider_id,new.id,v_campaign.benefit_value,'earned',jsonb_build_object(
    'service_category',v_category,'funded_by','wissa','rule','first10_independent_offerers_once'
  )) returning id into v_bonus_id;

  v_base_payout:=greatest(coalesce(nullif(new.seller_payout,0),0),0);
  update public.bookings set
    provider_bonus_amount=v_campaign.benefit_value,
    provider_bonus_id=v_bonus_id,
    seller_payout=round(v_base_payout+v_campaign.benefit_value,2),
    service_details=jsonb_set(coalesce(service_details,'{}'::jsonb),'{provider_bonus}',jsonb_build_object(
      'code',v_campaign.code,'label','Bono Ofrecer · USD 50','amount',v_campaign.benefit_value,'funded_by','wissa','earned',true,'bonus_id',v_bonus_id
    ),true),
    updated_at=now()
  where id=new.id;

  insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read,created_at)
  select new.provider_id,'Ganaste un bono de USD 50',
    'Completaste una reserva elegible y estás entre los primeros 10 Ofrecer. Wissa agregó USD 50 a esta liquidación.',
    'provider_launch_bonus_50','/(provider-tabs)/earnings',new.id,
    jsonb_build_object('booking_id',new.id,'bonus_id',v_bonus_id,'amount',v_campaign.benefit_value,'campaign',v_campaign.code),false,now()
  where not exists(select 1 from public.notifications n where n.user_id=new.provider_id and n.related_booking_id=new.id and n.type='provider_launch_bonus_50');

  perform public.yt_v603_refresh_launch_campaign_state();
  if to_regprocedure('public.yt_recalculate_provider_balance(uuid)') is not null then
    perform public.yt_recalculate_provider_balance(new.provider_id);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_v603_provider_launch_bonus on public.bookings;
create trigger trg_v603_provider_launch_bonus
after insert or update of status,payment_status on public.bookings
for each row execute function public.yt_v603_grant_provider_launch_bonus();

create or replace function public.wissa_launch_promo_status_v603()
returns jsonb
language plpgsql
security definer
stable
set search_path=public
as $$
declare
  v_uid uuid:=auth.uid();
  v_client public.promotion_campaigns%rowtype;
  v_provider public.promotion_campaigns%rowtype;
  v_client_used integer:=0;
  v_provider_used integer:=0;
  v_user_client boolean:=false;
  v_user_provider boolean:=false;
begin
  select * into v_client from public.promotion_campaigns where code='launch_first10_50' limit 1;
  select * into v_provider from public.promotion_campaigns where code='launch_first10_offerers_50' limit 1;
  if v_client.id is not null then
    select count(*)::int into v_client_used from public.promotion_redemptions where campaign_id=v_client.id and status='applied';
    if v_uid is not null then select exists(select 1 from public.promotion_redemptions where campaign_id=v_client.id and buyer_id=v_uid and status='applied') into v_user_client; end if;
  end if;
  if v_provider.id is not null then
    select count(*)::int into v_provider_used from public.provider_completion_bonuses where campaign_id=v_provider.id and status<>'cancelled';
    if v_uid is not null then select exists(select 1 from public.provider_completion_bonuses where campaign_id=v_provider.id and provider_id=v_uid and status<>'cancelled') into v_user_provider; end if;
  end if;
  return jsonb_build_object(
    'client_limit',coalesce(v_client.max_redemptions,10),'client_used',v_client_used,
    'client_remaining',greatest(coalesce(v_client.max_redemptions,10)-v_client_used,0),
    'client_active',coalesce(v_client.is_active,false) and v_client_used<coalesce(v_client.max_redemptions,10),
    'provider_limit',coalesce(v_provider.max_redemptions,10),'provider_used',v_provider_used,
    'provider_remaining',greatest(coalesce(v_provider.max_redemptions,10)-v_provider_used,0),
    'provider_active',coalesce(v_provider.is_active,false) and v_provider_used<coalesce(v_provider.max_redemptions,10),
    'total_used',v_client_used+v_provider_used,'total_limit',coalesce(v_client.max_redemptions,10)+coalesce(v_provider.max_redemptions,10),
    'complete',(v_client_used>=coalesce(v_client.max_redemptions,10) and v_provider_used>=coalesce(v_provider.max_redemptions,10)),
    'user_client_redeemed',v_user_client,'user_provider_redeemed',v_user_provider
  );
end;
$$;
revoke execute on function public.wissa_launch_promo_status_v603() from public,anon;
grant execute on function public.wissa_launch_promo_status_v603() to authenticated,service_role;

select public.yt_v603_refresh_launch_campaign_state();

-- --------------------------------------------------------------------------
-- 6. Banners Home: maximo 5 activos + storage para Admin Web
-- --------------------------------------------------------------------------
create or replace function public.yt_v60_limit_home_banners()
returns trigger
language plpgsql
set search_path=public
as $$
declare v_count integer;
begin
  if new.position='home' and coalesce(new.is_active,true)=true and coalesce(new.status,'active')<>'paused' then
    select count(*)::int into v_count from public.banners b
    where b.position='home' and b.is_active=true and coalesce(b.status,'active')<>'paused'
      and (tg_op='INSERT' or b.id<>new.id);
    if v_count>=5 then raise exception 'Solo se permiten 5 banners activos en Home.'; end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_v60_limit_home_banners on public.banners;
create trigger trg_v60_limit_home_banners before insert or update on public.banners
for each row execute function public.yt_v60_limit_home_banners();

-- Semillas locales incluidas en Mobile/Admin; pueden editarse, pausarse o eliminarse.
-- V60.2: copy mas corto para mobile + soporte de hasta 5 banners sin exceder el limite.
insert into public.banners(title,image_url,position,sort_order,is_active,status,metadata)
select x.title,x.image_url,'home',x.sort_order,true,'active',x.metadata
from (values
  ('Limpieza para tu hogar','wissa://banner/home-cleaning',1,jsonb_build_object('title_en','Cleaning for your home','subtitle','Espacios limpios, cómodos y listos para disfrutar.','subtitle_en','Clean, comfortable spaces ready to enjoy.','cta','Ver limpieza','cta_en','View cleaning')),
  ('Limpieza de exteriores','wissa://banner/exterior',2,jsonb_build_object('title_en','Exterior cleaning','subtitle','Patios, terrazas, piscinas y más.','subtitle_en','Patios, terraces, pools and more.','cta','Ver exteriores','cta_en','View exterior services')),
  ('Plomería','wissa://banner/plumbing',3,jsonb_build_object('title_en','Plumbing','subtitle','Diagnóstico profesional para identificar el problema a tiempo.','subtitle_en','Professional diagnosis to identify the problem in time.','cta','Ver plomería','cta_en','View plumbing'))
) as x(title,image_url,sort_order,metadata)
where not exists (select 1 from public.banners b where b.image_url=x.image_url);

-- Mantiene actualizado el copy de las semillas aunque la migracion se vuelva a ejecutar.
update public.banners set
  title='Limpieza para tu hogar', sort_order=1,
  metadata=jsonb_build_object('title_en','Cleaning for your home','subtitle','Espacios limpios, cómodos y listos para disfrutar.','subtitle_en','Clean, comfortable spaces ready to enjoy.','cta','Ver limpieza','cta_en','View cleaning')
where image_url='wissa://banner/home-cleaning';

update public.banners set
  title='Limpieza de exteriores', sort_order=2,
  metadata=jsonb_build_object('title_en','Exterior cleaning','subtitle','Patios, terrazas, piscinas y más.','subtitle_en','Patios, terraces, pools and more.','cta','Ver exteriores','cta_en','View exterior services')
where image_url='wissa://banner/exterior';

update public.banners set
  title='Plomería', sort_order=3,
  metadata=jsonb_build_object('title_en','Plumbing','subtitle','Diagnóstico profesional para identificar el problema a tiempo.','subtitle_en','Professional diagnosis to identify the problem in time.','cta','Ver plomería','cta_en','View plumbing')
where image_url='wissa://banner/plumbing';

-- Agrega las dos semillas adicionales solo si queda espacio dentro del maximo de 5 activos.
do $$
declare
  v_count int;
begin
  select count(*)::int into v_count from public.banners where position='home' and is_active=true and coalesce(status,'active')<>'paused';
  if v_count < 5 and not exists(select 1 from public.banners where image_url='wissa://banner/loyalty') then
    insert into public.banners(title,image_url,position,sort_order,is_active,status,metadata)
    values('50% para los primeros 10 clientes','wissa://banner/loyalty','home',4,true,'active',
      jsonb_build_object('title_en','50% off for the first 10 customers','subtitle','Promoción de lanzamiento limitada a 10 clientes elegibles.','subtitle_en','Launch promotion limited to 10 eligible customers.','cta','Ver promoción','cta_en','View promotion'));
  end if;

  select count(*)::int into v_count from public.banners where position='home' and is_active=true and coalesce(status,'active')<>'paused';
  if v_count < 5 and not exists(select 1 from public.banners where image_url='wissa://banner/professionals') then
    insert into public.banners(title,image_url,position,sort_order,is_active,status,metadata)
    values('Profesionales verificados','wissa://banner/professionals','home',5,true,'active',
      jsonb_build_object('title_en','Verified professionals','subtitle','Confianza, puntualidad y atención de calidad en cada servicio.','subtitle_en','Trust, punctuality and quality care in every service.','cta','Ver profesionales','cta_en','View professionals'));
  end if;
end $$;

-- Si ya existen, actualiza tambien sus textos sin forzar su estado activo/pausado.
update public.banners set
  title='50% para los primeros 10 clientes', sort_order=4,
  metadata=jsonb_build_object('title_en','50% off for the first 10 customers','subtitle','Promoción de lanzamiento limitada a 10 clientes elegibles.','subtitle_en','Launch promotion limited to 10 eligible customers.','cta','Ver promoción','cta_en','View promotion')
where image_url='wissa://banner/loyalty';

update public.banners set
  title='Profesionales verificados', sort_order=5,
  metadata=jsonb_build_object('title_en','Verified professionals','subtitle','Confianza, puntualidad y atención de calidad en cada servicio.','subtitle_en','Trust, punctuality and quality care in every service.','cta','Ver profesionales','cta_en','View professionals')
where image_url='wissa://banner/professionals';

-- Bucket publico solo para banners. Escritura restringida a admins.
do $$ begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
    values('wissa-banners','wissa-banners',true,5242880,array['image/jpeg','image/png','image/webp'])
    on conflict(id) do update set public=true,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
  end if;
end $$;

do $$ begin
  if to_regclass('storage.objects') is not null then
    execute 'drop policy if exists "wissa_banners_admin_insert_v60" on storage.objects';
    execute 'drop policy if exists "wissa_banners_admin_update_v60" on storage.objects';
    execute 'drop policy if exists "wissa_banners_admin_delete_v60" on storage.objects';
    execute 'create policy "wissa_banners_admin_insert_v60" on storage.objects for insert to authenticated with check (bucket_id=''wissa-banners'' and exists(select 1 from public.profiles p where p.id=auth.uid() and (coalesce(p.is_admin,false)=true or p.role in (''admin'',''super_admin''))))';
    execute 'create policy "wissa_banners_admin_update_v60" on storage.objects for update to authenticated using (bucket_id=''wissa-banners'' and exists(select 1 from public.profiles p where p.id=auth.uid() and (coalesce(p.is_admin,false)=true or p.role in (''admin'',''super_admin'')))) with check (bucket_id=''wissa-banners'')';
    execute 'create policy "wissa_banners_admin_delete_v60" on storage.objects for delete to authenticated using (bucket_id=''wissa-banners'' and exists(select 1 from public.profiles p where p.id=auth.uid() and (coalesce(p.is_admin,false)=true or p.role in (''admin'',''super_admin''))))';
  end if;
end $$;

-- --------------------------------------------------------------------------
-- 7. Resumen financiero V60 separado por concepto/categoria
-- --------------------------------------------------------------------------
create or replace function public.wissa_finance_summary_v60()
returns jsonb
language plpgsql
security definer
stable
set search_path=public
as $$
declare r jsonb;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then raise exception 'No autorizado'; end if;
  select jsonb_build_object(
    'services_and_extras',coalesce(round(sum(greatest(coalesce(b.service_subtotal,0),0)),2),0),
    'kits_cleaning',coalesce(round(sum(case when lower(translate(coalesce(b.kit_category_name,b.service_details->>'category',''),'íóáéúñ','ioaeun')) like '%limpieza%' and lower(translate(coalesce(b.kit_category_name,b.service_details->>'category',''),'íóáéúñ','ioaeun')) not like '%exterior%' then greatest(coalesce(b.kit_amount,0),0) else 0 end),2),0),
    'kits_exterior',coalesce(round(sum(case when lower(translate(coalesce(b.kit_category_name,b.service_details->>'category',''),'íóáéúñ','ioaeun')) like '%exterior%' then greatest(coalesce(b.kit_amount,0),0) else 0 end),2),0),
    'travel',coalesce(round(sum(greatest(coalesce(b.travel_fee,0),0)),2),0),
    'platform_usage',coalesce(round(sum(greatest(coalesce(b.platform_usage_fee,0),0)),2),0),
    'itbms',coalesce(round(sum(greatest(coalesce(b.tax_amount,0),0)),2),0),
    'wissa_commission',coalesce(round(sum(greatest(coalesce(b.platform_fee,0),0)),2),0),
    'provider_net',coalesce(round(sum(greatest(coalesce(b.seller_payout,0),0)),2),0),
    'discounts',coalesce(round(sum(greatest(coalesce(b.promotion_discount_amount,0),0)+greatest(coalesce(b.bonus_discount_amount,0),0)),2),0),
    'refunds',coalesce(round(sum(case when coalesce(b.refund_status,'')='refunded' then greatest(coalesce(b.refund_amount,0),0) else 0 end),2),0),
    'total_processed',coalesce(round(sum(greatest(coalesce(b.total_amount,0),0)),2),0)
  ) into r
  from public.bookings b
  where b.payment_status='paid';
  return coalesce(r,'{}'::jsonb);
end;
$$;

revoke execute on function public.wissa_finance_summary_v60() from public,anon;
grant execute on function public.wissa_finance_summary_v60() to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 8. Admin promociones/bonos V60.3
-- --------------------------------------------------------------------------
create or replace function public.wissa_loyalty_admin_summary_v60()
returns jsonb
language plpgsql
security definer
stable
set search_path=public
as $$
declare
  v_client_id uuid;
  v_provider_id uuid;
  v_client_limit integer:=10;
  v_provider_limit integer:=10;
  v_client_used integer:=0;
  v_provider_used integer:=0;
  v_client_active boolean:=false;
  v_provider_active boolean:=false;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then raise exception 'No autorizado'; end if;

  select id,max_redemptions,is_active into v_client_id,v_client_limit,v_client_active
  from public.promotion_campaigns where code='launch_first10_50' limit 1;
  select id,max_redemptions,is_active into v_provider_id,v_provider_limit,v_provider_active
  from public.promotion_campaigns where code='launch_first10_offerers_50' limit 1;

  if v_client_id is not null then
    select count(*)::int into v_client_used from public.promotion_redemptions where campaign_id=v_client_id and status='applied';
  end if;
  if v_provider_id is not null then
    select count(*)::int into v_provider_used from public.provider_completion_bonuses where campaign_id=v_provider_id and status<>'cancelled';
  end if;

  return jsonb_build_object(
    'client_loyalty_count',v_client_used,
    'client_loyalty_amount',coalesce((select round(sum(discount_amount),2) from public.promotion_redemptions where campaign_id=v_client_id and status='applied'),0),
    'client_limit',coalesce(v_client_limit,10),
    'client_remaining',greatest(coalesce(v_client_limit,10)-v_client_used,0),
    'client_active',coalesce(v_client_active,false) and v_client_used<coalesce(v_client_limit,10),
    'provider_loyalty_count',v_provider_used,
    'provider_loyalty_amount',coalesce((select round(sum(amount),2) from public.provider_completion_bonuses where campaign_id=v_provider_id and status<>'cancelled'),0),
    'provider_limit',coalesce(v_provider_limit,10),
    'provider_remaining',greatest(coalesce(v_provider_limit,10)-v_provider_used,0),
    'provider_active',coalesce(v_provider_active,false) and v_provider_used<coalesce(v_provider_limit,10),
    'total_used',v_client_used+v_provider_used,
    'total_limit',coalesce(v_client_limit,10)+coalesce(v_provider_limit,10),
    'campaign_complete',(v_client_used>=coalesce(v_client_limit,10) and v_provider_used>=coalesce(v_provider_limit,10)),
    'cancel_bonus_available',(select count(*) from public.customer_bonuses where bonus_type='provider_cancel_7' and status='available'),
    'cancel_bonus_available_amount',coalesce((select round(sum(amount-used_amount),2) from public.customer_bonuses where bonus_type='provider_cancel_7' and status='available'),0),
    'cancel_bonus_used_amount',coalesce((select round(sum(used_amount),2) from public.customer_bonuses where bonus_type='provider_cancel_7' and status='used'),0)
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
set search_path=public
as $$
declare v_search text:=lower(trim(coalesce(p_search,''))); v_status text:=lower(trim(coalesce(p_status,'all')));
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then raise exception 'No autorizado'; end if;
  return query
  with rows as (
    select
      'client_launch_promo'::text record_kind,
      r.id,
      r.buyer_id person_id,
      coalesce(p.display_name,p.full_name,p.email,'Cliente')::text person_name,
      p.email::text person_email,
      'Cliente'::text person_role,
      'launch_first10_50'::text benefit_type,
      'Primeros 10 clientes · 50% descuento'::text benefit_label,
      r.discount_amount::numeric amount,
      r.status::text status,
      r.booking_id source_booking_id,
      null::uuid used_booking_id,
      r.created_at issued_at,
      null::timestamptz used_at
    from public.promotion_redemptions r
    join public.promotion_campaigns c on c.id=r.campaign_id and c.code='launch_first10_50'
    left join public.profiles p on p.id=r.buyer_id

    union all

    select
      'provider_launch_bonus'::text,
      b.id,
      b.provider_id,
      coalesce(p.display_name,p.full_name,p.email,'Ofrecer')::text,
      p.email::text,
      'Ofrecer'::text,
      'launch_first10_offerers_50'::text,
      'Primeros 10 Ofrecer · bono USD 50'::text,
      b.amount::numeric,
      b.status::text,
      b.source_booking_id,
      null::uuid,
      b.earned_at,
      b.paid_at
    from public.provider_completion_bonuses b
    join public.promotion_campaigns c on c.id=b.campaign_id and c.code='launch_first10_offerers_50'
    left join public.profiles p on p.id=b.provider_id

    union all

    select
      'customer_bonus'::text,b.id,b.buyer_id,
      coalesce(p.display_name,p.full_name,p.email,'Cliente')::text,p.email::text,'Cliente'::text,
      b.bonus_type::text,'Bono cancelación tardía · USD 7'::text,b.amount,b.status,b.source_booking_id,b.used_booking_id,b.issued_at,b.used_at
    from public.customer_bonuses b left join public.profiles p on p.id=b.buyer_id
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

-- --------------------------------------------------------------------------
-- 8. Textos operativos: devolucion estimada 24-72 h
-- --------------------------------------------------------------------------
insert into public.app_settings(key,value,updated_at)
values('refund_policy_v60',jsonb_build_object('min_hours',24,'max_hours',72,'label_es','Devolucion estimada entre 24 y 72 horas','label_en','Estimated refund within 24 to 72 hours'),now())
on conflict(key) do update set value=excluded.value,updated_at=now();

notify pgrst,'reload schema';
commit;
