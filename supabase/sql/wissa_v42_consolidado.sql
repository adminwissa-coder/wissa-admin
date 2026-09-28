-- ==========================================================================
-- WISSA V40 CONSOLIDADO - INSTALACION FINAL
-- Fecha: 2026-08-17
-- Incluye V36 + V37 + V38 + V39 + V40.
-- Si aun no instalaste esas versiones, ejecuta SOLO este archivo completo.
--
-- V40: Admin Empresas 360 con KPI, filtros, ficha integral, alertas,
-- personal, servicios/categorias, reservas, finanzas, suscripcion y acciones.
-- ===========================================================================

-- ============================================================================
-- WISSA V39 CONSOLIDADO - REGLAS FINALES PARA INSTALACION
-- Fecha: 2026-08-17
-- EJECUTAR ESTE ARCHIVO COMPLETO SI AUN NO SE INSTALARON V36/V37/V38.
--
-- REGLAS FINALES:
--   CLIENTE: primeros 10 de Limpieza -> 50%.
--   OFRECER: primeros 10 distintos que completen Limpieza -> +USD 50 en ESA liquidacion.
--   CLIENTE: cancelacion tardia de Ofrecer -> bono USD 7 para Limpieza,
--            Limpieza exteriores o Plomeria; visible/seleccionable en checkout.
--   CLIENTE cancela reserva con USD 7 usado -> bono consumido/perdido.
--   OFRECER cancela reserva con USD 7 usado -> bono restaurado.
--   DEVOLUCION: flujo Admin existente, referencia operativa aprox. 24 horas.
--   CODIGO DE CIERRE: solo cuando el cliente inicia el cierre; nunca al pagar.
--
-- Este consolidado contiene V38 y al final V39 reemplaza las definiciones que
-- deban ajustarse. No ejecutar V37/V38 por separado si se usa este archivo.
-- ============================================================================

-- ============================================================================
-- WISSA V38 CONSOLIDADO - REGLAS FINALES
-- EJECUTAR ESTE ARCHIVO COMPLETO.
-- La seccion V38 al final reemplaza cualquier definicion intermedia V37
-- relacionada con el antiguo bono USD 50 para clientes. La regla FINAL es:
-- CLIENTE: primeros 10 -> 50%. OFRECER: primeros 10 que completen limpieza -> +USD 50.
-- ============================================================================

-- ==========================================================================
-- WISSA V37 CONSOLIDADO
-- Incluye optimización V36 + cambios funcionales V37 solicitados por cliente.
-- Ejecutar en Supabase SQL Editor sobre la base Wissa actual.
-- Fecha: 2026-08-17
-- ==========================================================================

-- ============================================================================
-- WISSA v36 - OPTIMIZACION DE RENDIMIENTO / CACHE / MARKETPLACE / ADMIN
-- Fecha: 2026-08-16
--
-- MIGRACION INCREMENTAL para la base actual de Wissa.
-- No elimina datos, no cambia estados de reservas/pagos y no reemplaza los RPC
-- administrativos existentes. Puede ejecutarse sobre la base actual.
-- ============================================================================

-- --------------------------------------------------------------------------
-- 1. INDICES PARA LOS FLUJOS MAS CONSULTADOS EN MOBILE / ADMIN
-- --------------------------------------------------------------------------

create index if not exists idx_reviews_reviewed_id_created_at
  on public.reviews (reviewed_id, created_at desc);

create index if not exists idx_services_active_created_at
  on public.services (is_active, created_at desc);

create index if not exists idx_services_provider_active
  on public.services (provider_id, is_active);

create index if not exists idx_services_category_active
  on public.services (category, is_active);

create index if not exists idx_bookings_provider_status_date
  on public.bookings (provider_id, status, booking_date, booking_time);

create index if not exists idx_bookings_buyer_status_date
  on public.bookings (buyer_id, status, booking_date, booking_time);

create index if not exists idx_bookings_payment_status
  on public.bookings (payment_status, status, created_at desc);

create index if not exists idx_chat_rooms_provider_open
  on public.chat_rooms (provider_id, is_closed, last_message_at desc);

create index if not exists idx_chat_rooms_buyer_open
  on public.chat_rooms (buyer_id, is_closed, last_message_at desc);

create index if not exists idx_notifications_user_read_created
  on public.notifications (user_id, is_read, created_at desc);

create index if not exists idx_service_categories_active_sort
  on public.service_categories (is_active, sort_order);

create index if not exists idx_profiles_marketplace_visibility
  on public.profiles (provider_status, status, is_suspended, is_available)
  where coalesce(is_admin, false) = false;

create index if not exists idx_company_members_company_status_user
  on public.company_members (company_id, status, user_id);

create index if not exists idx_companies_status_subscription_created
  on public.companies (status, subscription_status, created_at desc);

create index if not exists idx_booking_admin_cases_status_created
  on public.booking_admin_cases (status, created_at desc);

create index if not exists idx_push_notification_logs_status_created
  on public.push_notification_logs (status, created_at desc);

-- --------------------------------------------------------------------------
-- 2. RESEÑAS AGREGADAS
-- Home/Explorar llaman a este RPC para obtener promedio + cantidad por proveedor
-- sin descargar miles de filas de public.reviews al dispositivo.
-- --------------------------------------------------------------------------

create or replace function public.yt_provider_review_stats(p_provider_ids uuid[])
returns table (
  reviewed_id uuid,
  rating_avg numeric,
  reviews_count bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    r.reviewed_id,
    round(avg(r.rating)::numeric, 2) as rating_avg,
    count(*)::bigint as reviews_count
  from public.reviews r
  where r.reviewed_id = any(coalesce(p_provider_ids, '{}'::uuid[]))
  group by r.reviewed_id;
$$;

revoke execute on function public.yt_provider_review_stats(uuid[]) from public;
grant execute on function public.yt_provider_review_stats(uuid[]) to anon, authenticated, service_role;

-- --------------------------------------------------------------------------
-- 3. REFRESCAR METADATOS POSTGREST
-- --------------------------------------------------------------------------

notify pgrst, 'reload schema';


-- ============================================================================
-- WISSA v37 - DEFINICIONES BASE (AJUSTADAS/REEMPLAZADAS POR V38 ANTES DEL COMMIT)
-- Fecha: 2026-08-17
--
-- Implementa:
--  1) Promocion lanzamiento: primeros 10 clientes elegibles, 50%.
--  2) Bono USD 50 para limpieza para esos primeros 10 clientes, emitido al pagar.
--  3) Bono USD 7 cuando quien ofrece cancela el mismo dia o un dia antes.
--  4) Codigo unico de cierre se genera/muestra solo al iniciar el cierre.
--  5) Descriptor exacto de documentos para evitar descargas cruzadas en Admin.
--
-- Requiere la base Wissa actual (incluyendo refunds v25+). Es idempotente.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- A. CAMPANAS Y TRAZABILIDAD DE BENEFICIOS
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

insert into public.promotion_campaigns (
  code, name, benefit_type, benefit_value, max_redemptions, service_scope, is_active, starts_at, metadata
)
values (
  'launch_first10_50',
  'Primeros 10 clientes - 50%',
  'percentage',
  50,
  10,
  'cleaning',
  true,
  now(),
  jsonb_build_object(
    'funded_by', 'wissa',
    'stackable', false,
    'description', '50% para la primera reserva elegible de limpieza de los primeros 10 clientes.'
  )
)
on conflict (code) do update
set name = excluded.name,
    benefit_type = excluded.benefit_type,
    benefit_value = excluded.benefit_value,
    max_redemptions = excluded.max_redemptions,
    service_scope = excluded.service_scope,
    metadata = excluded.metadata,
    updated_at = now();

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
  on public.promotion_redemptions (booking_id)
  where status = 'applied';

create unique index if not exists uq_promotion_redemption_buyer_campaign_active
  on public.promotion_redemptions (campaign_id, buyer_id)
  where status = 'applied';

create index if not exists idx_promotion_redemptions_campaign_status
  on public.promotion_redemptions (campaign_id, status, created_at);

create table if not exists public.customer_bonuses (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid not null references public.profiles(id),
  bonus_type text not null check (bonus_type in ('welcome_cleaning_50','provider_cancel_7')),
  amount numeric not null check (amount > 0),
  used_amount numeric not null default 0,
  service_scope text not null default 'any' check (service_scope in ('any','cleaning')),
  status text not null default 'available' check (status in ('available','used','cancelled')),
  source_booking_id uuid references public.bookings(id),
  used_booking_id uuid references public.bookings(id),
  issued_at timestamptz not null default now(),
  used_at timestamptz,
  expires_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uq_customer_bonus_source_type
  on public.customer_bonuses (bonus_type, source_booking_id)
  where source_booking_id is not null and status <> 'cancelled';

create unique index if not exists uq_customer_bonus_welcome_per_buyer
  on public.customer_bonuses (buyer_id, bonus_type)
  where bonus_type = 'welcome_cleaning_50' and status <> 'cancelled';

create index if not exists idx_customer_bonuses_buyer_status
  on public.customer_bonuses (buyer_id, status, issued_at);

alter table public.bookings
  add column if not exists gross_total_amount numeric,
  add column if not exists promotion_discount_amount numeric not null default 0,
  add column if not exists bonus_discount_amount numeric not null default 0,
  add column if not exists benefit_code text,
  add column if not exists benefit_label text,
  add column if not exists benefit_applied_at timestamptz,
  add column if not exists applied_bonus_id uuid,
  add column if not exists provider_cancelled_at timestamptz;

update public.bookings
set gross_total_amount = coalesce(total_amount, subtotal_amount, price_snapshot, 0)
where gross_total_amount is null;

alter table public.bookings
  alter column gross_total_amount set default 0;

alter table public.bookings
  drop constraint if exists bookings_applied_bonus_id_fkey;

alter table public.bookings
  add constraint bookings_applied_bonus_id_fkey
  foreign key (applied_bonus_id) references public.customer_bonuses(id);

-- --------------------------------------------------------------------------
-- B. RLS DE BONOS / PROMOCIONES
-- --------------------------------------------------------------------------
alter table public.promotion_campaigns enable row level security;
alter table public.promotion_redemptions enable row level security;
alter table public.customer_bonuses enable row level security;

drop policy if exists promotion_campaigns_read_v37 on public.promotion_campaigns;
create policy promotion_campaigns_read_v37
on public.promotion_campaigns for select
to authenticated
using (is_active = true or public.yt_admin_is_current_admin());

drop policy if exists promotion_redemptions_owner_read_v37 on public.promotion_redemptions;
create policy promotion_redemptions_owner_read_v37
on public.promotion_redemptions for select
to authenticated
using (buyer_id = auth.uid() or public.yt_admin_is_current_admin());

drop policy if exists customer_bonuses_owner_read_v37 on public.customer_bonuses;
create policy customer_bonuses_owner_read_v37
on public.customer_bonuses for select
to authenticated
using (buyer_id = auth.uid() or public.yt_admin_is_current_admin());

revoke insert, update, delete on public.promotion_redemptions from authenticated;
revoke insert, update, delete on public.customer_bonuses from authenticated;

grant select on public.promotion_campaigns, public.promotion_redemptions, public.customer_bonuses to authenticated;

-- --------------------------------------------------------------------------
-- C. APLICAR BENEFICIO A UNA RESERVA (NO COMBINA BENEFICIOS)
-- Prioridad: lanzamiento 50% -> bono USD 50 -> bono USD 7.
-- El proveedor conserva seller_payout; el descuento lo subsidia Wissa.
-- --------------------------------------------------------------------------
create or replace function public.yt_apply_booking_benefits_v37(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_campaign public.promotion_campaigns%rowtype;
  v_bonus public.customer_bonuses%rowtype;
  v_category text := '';
  v_is_cleaning boolean := false;
  v_gross numeric := 0;
  v_promo_discount numeric := 0;
  v_bonus_discount numeric := 0;
  v_final numeric := 0;
  v_benefit_code text := null;
  v_benefit_label text := null;
  v_redemption_id uuid := null;
  v_now timestamptz := now();
  v_details jsonb := '{}'::jsonb;
  v_payment_method text := null;
begin
  select * into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if not found then
    raise exception 'Reserva no encontrada.';
  end if;

  if auth.uid() is not null
     and auth.uid() <> v_booking.buyer_id
     and not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado.';
  end if;

  if v_booking.benefit_applied_at is not null then
    return jsonb_build_object(
      'ok', true,
      'already_applied', true,
      'booking_id', v_booking.id,
      'benefit_code', v_booking.benefit_code,
      'benefit_label', v_booking.benefit_label,
      'gross_total', v_booking.gross_total_amount,
      'promotion_discount', v_booking.promotion_discount_amount,
      'bonus_discount', v_booking.bonus_discount_amount,
      'total', v_booking.total_amount
    );
  end if;

  -- Los beneficios se fijan antes del pago y no pueden inyectarse sobre reservas cerradas/pagadas.
  if coalesce(v_booking.payment_status,'not_started') = 'paid'
     or v_booking.status not in ('pending','pending_payment') then
    return jsonb_build_object(
      'ok', true,
      'eligible', false,
      'reason', 'booking_not_open_for_benefits',
      'booking_id', v_booking.id,
      'total', v_booking.total_amount
    );
  end if;

  select coalesce(s.category, v_booking.service_details->>'category', '')
  into v_category
  from public.services s
  where s.id = v_booking.service_id;

  if v_category is null or v_category = '' then
    v_category := coalesce(v_booking.service_details->>'category', '');
  end if;

  v_is_cleaning := lower(v_category) like '%limpieza%' or lower(v_category) like '%clean%';
  v_gross := greatest(coalesce(nullif(v_booking.gross_total_amount, 0), v_booking.total_amount, v_booking.subtotal_amount, v_booking.price_snapshot, 0), 0);
  v_details := coalesce(v_booking.service_details, '{}'::jsonb);

  select * into v_campaign
  from public.promotion_campaigns c
  where c.code = 'launch_first10_50'
    and c.is_active = true
    and (c.starts_at is null or c.starts_at <= v_now)
    and (c.ends_at is null or c.ends_at >= v_now)
  limit 1;

  if found and v_is_cleaning and (v_campaign.starts_at is null or v_booking.created_at >= v_campaign.starts_at) then
    -- Serializa el cupo para evitar que dos clientes tomen el #10 al mismo tiempo.
    perform pg_advisory_xact_lock(hashtext('wissa:launch_first10_50')::bigint);

    if not exists (
      select 1 from public.promotion_redemptions r
      where r.campaign_id = v_campaign.id
        and r.buyer_id = v_booking.buyer_id
        and r.status = 'applied'
    ) and (
      select count(*) from public.promotion_redemptions r
      where r.campaign_id = v_campaign.id and r.status = 'applied'
    ) < v_campaign.max_redemptions then
      v_promo_discount := round(v_gross * (v_campaign.benefit_value / 100.0), 2);
      v_benefit_code := v_campaign.code;
      v_benefit_label := 'Promoción primeros 10 clientes · 50%';

      insert into public.promotion_redemptions (
        campaign_id, buyer_id, booking_id, discount_percent, discount_amount, status, metadata
      ) values (
        v_campaign.id,
        v_booking.buyer_id,
        v_booking.id,
        v_campaign.benefit_value,
        v_promo_discount,
        'applied',
        jsonb_build_object('service_category', v_category, 'funded_by', 'wissa')
      ) returning id into v_redemption_id;
    end if;
  end if;

  -- No combinar el 50% con bonos. Si no obtuvo la promo, usar como máximo un bono.
  if v_benefit_code is null then
    select * into v_bonus
    from public.customer_bonuses b
    where b.buyer_id = v_booking.buyer_id
      and b.status = 'available'
      and b.issued_at <= coalesce(v_booking.created_at, v_now)
      and (b.expires_at is null or b.expires_at >= v_now)
      and (b.service_scope = 'any' or (b.service_scope = 'cleaning' and v_is_cleaning))
    order by
      case b.bonus_type when 'welcome_cleaning_50' then 1 else 2 end,
      b.amount desc,
      b.issued_at asc
    for update skip locked
    limit 1;

    if found then
      v_bonus_discount := least(v_bonus.amount, v_gross);
      v_benefit_code := v_bonus.bonus_type;
      v_benefit_label := case v_bonus.bonus_type
        when 'welcome_cleaning_50' then 'Bono de bienvenida · USD 50 para limpieza'
        when 'provider_cancel_7' then 'Bono por cancelación de quien ofrece · USD 7'
        else 'Bono Wissa'
      end;

      update public.customer_bonuses
      set status = 'used',
          used_amount = v_bonus_discount,
          used_booking_id = v_booking.id,
          used_at = v_now,
          updated_at = v_now
      where id = v_bonus.id;
    end if;
  end if;

  v_final := greatest(round(v_gross - v_promo_discount - v_bonus_discount, 2), 0);
  v_payment_method := case
    when v_promo_discount > 0 then 'promotion'
    when v_bonus_discount > 0 then 'bonus'
    else null
  end;

  v_details := jsonb_set(
    v_details,
    '{benefits}',
    jsonb_build_object(
      'code', v_benefit_code,
      'label', v_benefit_label,
      'gross_total', v_gross,
      'promotion_discount', v_promo_discount,
      'bonus_discount', v_bonus_discount,
      'final_total', v_final,
      'funded_by', case when v_benefit_code is null then null else 'wissa' end
    ),
    true
  );
  v_details := jsonb_set(v_details, '{total}', to_jsonb(v_final), true);
  if jsonb_typeof(v_details->'pricing') = 'object' then
    v_details := jsonb_set(v_details, '{pricing,total_amount}', to_jsonb(v_final), true);
  end if;

  update public.bookings
  set gross_total_amount = v_gross,
      promotion_discount_amount = v_promo_discount,
      bonus_discount_amount = v_bonus_discount,
      benefit_code = v_benefit_code,
      benefit_label = v_benefit_label,
      benefit_applied_at = v_now,
      applied_bonus_id = case when v_bonus.id is not null then v_bonus.id else null end,
      total_amount = v_final,
      service_details = v_details,
      updated_at = v_now,
      payment_status = case when v_final = 0 then 'paid' else payment_status end,
      status = case when v_final = 0 then 'paid_pending_acceptance' else status end,
      paid_at = case when v_final = 0 then coalesce(paid_at, v_now) else paid_at end,
      payment_provider = case when v_final = 0 then 'wissa_benefit' else payment_provider end,
      payment_method = case when v_final = 0 then coalesce(v_payment_method, 'promotion') else payment_method end
  where id = v_booking.id;

  if v_final = 0 and not exists (select 1 from public.payment_orders po where po.booking_id = v_booking.id and po.status = 'approved') then
    insert into public.payment_orders (
      booking_id, buyer_id, provider_id, provider,
      amount_total, platform_fee, provider_net, currency,
      status, payment_method, method, amount, approved_at, paid_at,
      kind, release_status, created_at, updated_at
    ) values (
      v_booking.id, v_booking.buyer_id, v_booking.provider_id, 'wissa_benefit',
      0, coalesce(v_booking.platform_fee,0), coalesce(v_booking.seller_payout,0), 'USD',
      'approved', coalesce(v_payment_method,'promotion'), coalesce(v_payment_method,'promotion'), 0, v_now, v_now,
      'booking', 'pending', v_now, v_now
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'booking_id', v_booking.id,
    'benefit_code', v_benefit_code,
    'benefit_label', v_benefit_label,
    'gross_total', v_gross,
    'promotion_discount', v_promo_discount,
    'bonus_discount', v_bonus_discount,
    'total', v_final,
    'payment_covered', v_final = 0
  );
end;
$$;

revoke execute on function public.yt_apply_booking_benefits_v37(uuid) from public, anon;
grant execute on function public.yt_apply_booking_benefits_v37(uuid) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- D. AL PAGAR LA PROMOCION DE LOS PRIMEROS 10, EMITIR BONO USD 50 LIMPIEZA
-- --------------------------------------------------------------------------
create or replace function public.yt_v37_grant_welcome_bonus_after_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_has_launch boolean := false;
begin
  if new.payment_status = 'paid'
     and (tg_op = 'INSERT' or old.payment_status is distinct from new.payment_status) then
    select exists (
      select 1
      from public.promotion_redemptions r
      join public.promotion_campaigns c on c.id = r.campaign_id
      where r.booking_id = new.id
        and r.status = 'applied'
        and c.code = 'launch_first10_50'
    ) into v_has_launch;

    if v_has_launch then
      insert into public.customer_bonuses (
        buyer_id, bonus_type, amount, service_scope, status, source_booking_id, metadata
      ) values (
        new.buyer_id,
        'welcome_cleaning_50',
        50,
        'cleaning',
        'available',
        new.id,
        jsonb_build_object('origin', 'launch_first10_50', 'stackable_with_launch_promo', false)
      ) on conflict do nothing;

      insert into public.notifications (
        user_id, title, body, type, screen, related_booking_id, metadata, is_read, created_at
      )
      select
        new.buyer_id,
        'Bono de USD 50 disponible',
        'Por ser parte de los primeros 10 clientes, tienes un bono de USD 50 para tu próxima reserva de limpieza.',
        'bonus_welcome_50',
        '/(client-tabs)/bookings',
        new.id,
        jsonb_build_object('booking_id', new.id, 'amount', 50, 'scope', 'cleaning'),
        false,
        now()
      where not exists (
        select 1 from public.notifications n
        where n.user_id = new.buyer_id
          and n.type = 'bonus_welcome_50'
          and n.related_booking_id = new.id
      );
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_v37_grant_welcome_bonus_after_paid on public.bookings;
create trigger trg_v37_grant_welcome_bonus_after_paid
after insert or update of payment_status on public.bookings
for each row execute function public.yt_v37_grant_welcome_bonus_after_paid();

-- Si una reserva NO pagada con promo se cancela/rechaza, libera el cupo.
create or replace function public.yt_v37_release_unpaid_promo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status in ('cancelled','rejected')
     and coalesce(new.payment_status,'') <> 'paid'
     and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    update public.promotion_redemptions
    set status = 'cancelled', updated_at = now(),
        metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object('released_reason','unpaid_booking_cancelled')
    where booking_id = new.id and status = 'applied';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_v37_release_unpaid_promo on public.bookings;
create trigger trg_v37_release_unpaid_promo
after insert or update of status, payment_status on public.bookings
for each row execute function public.yt_v37_release_unpaid_promo();

-- --------------------------------------------------------------------------
-- E. CANCELACION POR QUIEN OFRECE + BONO USD 7
-- El trigger de devoluciones existente se encarga de crear refund_pending.
-- --------------------------------------------------------------------------
create or replace function public.yt_provider_cancel_booking_v37(
  p_booking_id uuid,
  p_reason text default 'Cancelada por quien ofrece'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_today date := (now() at time zone 'America/Panama')::date;
  v_days integer;
  v_bonus_id uuid;
  v_bonus_granted boolean := false;
  v_reason text := coalesce(nullif(btrim(p_reason),''), 'Cancelada por quien ofrece');
begin
  select * into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if not found then raise exception 'Reserva no encontrada.'; end if;
  if auth.uid() is distinct from v_booking.provider_id then
    raise exception 'Solo quien ofrece puede cancelar esta reserva.';
  end if;
  if coalesce(v_booking.payment_status,'') <> 'paid' then
    raise exception 'Solo se puede cancelar desde este flujo una reserva pagada.';
  end if;
  if v_booking.status <> 'accepted' then
    raise exception 'Solo se puede cancelar una reserva aceptada y aún no cerrada.';
  end if;
  if coalesce(v_booking.buyer_confirmed,false) or coalesce(v_booking.provider_confirmed,false) then
    raise exception 'El cierre del servicio ya comenzó; la reserva no se puede cancelar desde este flujo.';
  end if;

  v_days := v_booking.booking_date - v_today;

  -- Si el cliente había usado un bono en esta reserva, restaurarlo porque el proveedor canceló.
  if v_booking.applied_bonus_id is not null then
    update public.customer_bonuses
    set status = 'available',
        used_amount = 0,
        used_booking_id = null,
        used_at = null,
        updated_at = now(),
        metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object('restored_from_provider_cancel_booking_id', v_booking.id)
    where id = v_booking.applied_bonus_id and status = 'used';
  end if;

  update public.bookings
  set status = 'cancelled',
      cancel_reason = v_reason,
      provider_cancelled_at = now(),
      provider_confirmed = false,
      buyer_confirmed = false,
      updated_at = now()
  where id = v_booking.id;

  if v_days between 0 and 1 then
    insert into public.customer_bonuses (
      buyer_id, bonus_type, amount, service_scope, status, source_booking_id, metadata
    ) values (
      v_booking.buyer_id,
      'provider_cancel_7',
      7,
      'any',
      'available',
      v_booking.id,
      jsonb_build_object(
        'reason', 'provider_cancelled_same_or_previous_day',
        'booking_date', v_booking.booking_date,
        'cancel_date_panama', v_today,
        'days_before', v_days
      )
    )
    on conflict do nothing
    returning id into v_bonus_id;

    v_bonus_granted := v_bonus_id is not null or exists (
      select 1 from public.customer_bonuses b
      where b.bonus_type = 'provider_cancel_7'
        and b.source_booking_id = v_booking.id
        and b.status <> 'cancelled'
    );
  end if;

  insert into public.notifications (
    user_id, title, body, type, screen, related_booking_id, metadata, is_read, created_at
  ) values (
    v_booking.buyer_id,
    case when v_bonus_granted then 'Reserva cancelada · bono de USD 7' else 'Reserva cancelada por quien ofrece' end,
    case when v_bonus_granted
      then 'Quien ofrece canceló el mismo día o un día antes. Wissa te otorgó un bono de USD 7 para una próxima reserva. La devolución del pago quedó en revisión.'
      else 'Quien ofrece canceló la reserva. La devolución del pago quedó en revisión por Wissa.'
    end,
    case when v_bonus_granted then 'provider_cancel_bonus_7' else 'provider_cancelled_booking' end,
    '/(client-tabs)/bookings',
    v_booking.id,
    jsonb_build_object('booking_id', v_booking.id, 'bonus_granted', v_bonus_granted, 'bonus_amount', case when v_bonus_granted then 7 else 0 end),
    false,
    now()
  );

  return jsonb_build_object(
    'ok', true,
    'booking_id', v_booking.id,
    'status', 'cancelled',
    'refund_pending', true,
    'bonus_granted', v_bonus_granted,
    'bonus_amount', case when v_bonus_granted then 7 else 0 end,
    'days_before', v_days
  );
end;
$$;

revoke execute on function public.yt_provider_cancel_booking_v37(uuid,text) from public, anon;
grant execute on function public.yt_provider_cancel_booking_v37(uuid,text) to authenticated, service_role;

-- Bloquea cancelaciones/rechazos directos de los participantes una vez iniciado el cierre.
create or replace function public.yt_v37_guard_booking_after_closing_started()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.status = 'accepted'
     and coalesce(old.buyer_confirmed,false) = true
     and new.status in ('cancelled','rejected')
     and auth.uid() in (old.buyer_id, old.provider_id) then
    raise exception 'El cierre del servicio ya comenzó. La reserva no se puede cancelar ni rechazar desde la app.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_v37_guard_booking_after_closing_started on public.bookings;
create trigger trg_v37_guard_booking_after_closing_started
before update of status on public.bookings
for each row execute function public.yt_v37_guard_booking_after_closing_started();

-- --------------------------------------------------------------------------
-- F. CODIGO DE CIERRE: GENERAR SOLO CUANDO EL CLIENTE INICIA EL CIERRE
-- --------------------------------------------------------------------------
create or replace function public.generate_booking_confirmation_code()
returns trigger
language plpgsql
as $$
begin
  if new.payment_status = 'paid'
     and coalesce(new.buyer_confirmed,false) = true
     and new.status in ('accepted','completed_pending_release')
     and coalesce(new.confirmation_code,'') = '' then
    new.confirmation_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
    new.confirmation_code_created_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_generate_booking_confirmation_code on public.bookings;
drop trigger if exists trg_bookings_confirmation_code on public.bookings;
create trigger trg_generate_booking_confirmation_code
before insert or update of payment_status, buyer_confirmed, status, confirmation_code on public.bookings
for each row execute function public.generate_booking_confirmation_code();

-- Retirar códigos prematuros de reservas activas que todavía no comenzaron cierre.
update public.bookings
set confirmation_code = null,
    confirmation_code_created_at = null,
    updated_at = now()
where confirmation_code_verified_at is null
  and coalesce(buyer_confirmed,false) = false
  and status in ('pending','pending_payment','paid_pending_acceptance','accepted');

create or replace function public.confirm_booking_completed_by_client(p_booking_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
begin
  select * into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if not found then raise exception 'No se encontró la reserva.'; end if;
  if auth.uid() is distinct from v_booking.buyer_id then
    raise exception 'Solo quien contrata puede iniciar el cierre de este servicio.';
  end if;
  if coalesce(v_booking.payment_status,'not_started') <> 'paid' then
    raise exception 'La reserva aún no tiene pago aprobado.';
  end if;
  if v_booking.status <> 'accepted' then
    raise exception 'La reserva debe estar aceptada antes de iniciar el cierre.';
  end if;
  if coalesce(v_booking.buyer_confirmed,false) then return true; end if;

  update public.bookings
  set buyer_confirmed = true,
      updated_at = now()
  where id = p_booking_id;

  return true;
end;
$$;

grant execute on function public.confirm_booking_completed_by_client(uuid) to authenticated;

create or replace function public.verify_booking_confirmation_code(p_booking_id uuid, p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
begin
  select * into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if not found then raise exception 'No se encontró la reserva.'; end if;
  if auth.uid() is distinct from v_booking.provider_id then
    raise exception 'Solo quien ofrece puede validar el código.';
  end if;
  if coalesce(v_booking.payment_status,'not_started') <> 'paid' then
    raise exception 'La reserva aún no tiene pago aprobado.';
  end if;
  if v_booking.status <> 'accepted' then
    raise exception 'La reserva debe estar aceptada antes de validar el cierre.';
  end if;
  if not coalesce(v_booking.buyer_confirmed,false) then
    raise exception 'El cliente todavía no inició el cierre del servicio.';
  end if;
  if coalesce(v_booking.confirmation_code,'') = '' then
    raise exception 'El código de cierre todavía no está disponible.';
  end if;
  if coalesce(v_booking.confirmation_code,'') <> trim(coalesce(p_code,'')) then
    raise exception 'El código no coincide.';
  end if;

  update public.bookings
  set provider_confirmed = true,
      confirmation_code_verified_at = now(),
      confirmation_code_verified_by = auth.uid(),
      status = 'completed_pending_release',
      completed_at = coalesce(completed_at, now()),
      updated_at = now()
  where id = p_booking_id;

  return true;
end;
$$;

grant execute on function public.verify_booking_confirmation_code(uuid,text) to authenticated;

-- Evita mensajes legacy diciendo que el código ya existe al momento del pago.
create or replace function public.yt_v37_sanitize_payment_notification()
returns trigger
language plpgsql
as $$
begin
  if new.type = 'payment_approved' and lower(coalesce(new.body,'')) like '%código%' then
    new.body := 'Tu pago fue aprobado. El código de cierre se habilitará cuando confirmes que el servicio finalizó.';
    new.metadata := coalesce(new.metadata,'{}'::jsonb) - 'confirmation_code';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_v37_sanitize_payment_notification on public.notifications;
create trigger trg_v37_sanitize_payment_notification
before insert or update on public.notifications
for each row execute function public.yt_v37_sanitize_payment_notification();

-- Limpiar también avisos de pagos previos que todavía expongan el flujo antiguo.
update public.notifications
set body = 'Tu pago fue aprobado. El código de cierre se habilitará cuando confirmes que el servicio finalizó.',
    metadata = coalesce(metadata,'{}'::jsonb) - 'confirmation_code'
where type = 'payment_approved'
  and lower(coalesce(body,'')) like '%código%';

-- --------------------------------------------------------------------------
-- G. ADMIN: DESCRIPTOR EXACTO DE DOCUMENTO PARA ABRIR/DESCARGAR
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_document_descriptor_v37(p_document_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, storage
as $$
declare
  v_doc public.identity_documents%rowtype;
  v_bucket text;
  v_path text;
  v_filename text;
  v_exists boolean := false;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  select * into v_doc
  from public.identity_documents d
  where d.id = p_document_id;

  if not found then raise exception 'Documento no encontrado'; end if;

  v_path := btrim(coalesce(v_doc.storage_path,''));
  v_bucket := btrim(coalesce(v_doc.storage_bucket,''));

  if v_bucket = '' then
    v_bucket := case
      when v_path ~ '^[0-9a-fA-F-]+/(selfie|police_record|cedula)/' then 'provider-verification'
      else 'identity-documents'
    end;
  end if;

  select exists (
    select 1 from storage.objects o
    where o.bucket_id = v_bucket and o.name = v_path
  ) into v_exists;

  if not v_exists then
    -- Fallback legacy: probar el otro bucket sin cambiar la fila equivocadamente.
    if v_bucket = 'provider-verification' then
      if exists (select 1 from storage.objects o where o.bucket_id = 'identity-documents' and o.name = v_path) then
        v_bucket := 'identity-documents';
        v_exists := true;
      end if;
    else
      if exists (select 1 from storage.objects o where o.bucket_id = 'provider-verification' and o.name = v_path) then
        v_bucket := 'provider-verification';
        v_exists := true;
      end if;
    end if;
  end if;

  if not v_exists then
    raise exception 'El archivo registrado no existe en Storage: %/%', v_bucket, v_path;
  end if;

  v_filename := regexp_replace(v_path, '^.*/', '');

  return jsonb_build_object(
    'id', v_doc.id,
    'user_id', v_doc.user_id,
    'document_type', case lower(coalesce(v_doc.document_type,''))
      when 'record_policivo' then 'police_record'
      when 'identity' then 'cedula'
      else v_doc.document_type
    end,
    'storage_bucket', v_bucket,
    'storage_path', v_path,
    'original_filename', v_filename,
    'exists', true
  );
end;
$$;

revoke execute on function public.yt_admin_document_descriptor_v37(uuid) from public, anon;
grant execute on function public.yt_admin_document_descriptor_v37(uuid) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- H. ADMIN: RESUMEN E HISTORIAL DE PROMOS/BONOS
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_benefits_summary_v37()
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_campaign public.promotion_campaigns%rowtype;
  v_used integer := 0;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  select * into v_campaign from public.promotion_campaigns where code = 'launch_first10_50' limit 1;
  select count(*) into v_used from public.promotion_redemptions r
  where r.campaign_id = v_campaign.id and r.status = 'applied';

  return jsonb_build_object(
    'launch_limit', coalesce(v_campaign.max_redemptions,10),
    'launch_used', v_used,
    'launch_remaining', greatest(coalesce(v_campaign.max_redemptions,10) - v_used, 0),
    'bonuses_available', (select count(*) from public.customer_bonuses where status = 'available'),
    'bonuses_available_amount', coalesce((select round(sum(amount),2) from public.customer_bonuses where status = 'available'),0),
    'bonuses_used', (select count(*) from public.customer_bonuses where status = 'used'),
    'welcome_50_issued', (select count(*) from public.customer_bonuses where bonus_type = 'welcome_cleaning_50' and status <> 'cancelled'),
    'provider_cancel_7_issued', (select count(*) from public.customer_bonuses where bonus_type = 'provider_cancel_7' and status <> 'cancelled'),
    'promotion_discount_total', coalesce((select round(sum(discount_amount),2) from public.promotion_redemptions where status = 'applied'),0),
    'bonus_used_amount', coalesce((select round(sum(used_amount),2) from public.customer_bonuses where status = 'used'),0),
    'benefit_cost_total',
      coalesce((select round(sum(discount_amount),2) from public.promotion_redemptions where status = 'applied'),0)
      + coalesce((select round(sum(used_amount),2) from public.customer_bonuses where status = 'used'),0)
  );
end;
$$;

create or replace function public.yt_admin_benefits_json(
  p_search text default '',
  p_status text default 'all',
  p_limit integer default 200
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_search text := '%' || lower(trim(coalesce(p_search,''))) || '%';
  v_status text := lower(trim(coalesce(p_status,'all')));
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(q) order by q.issued_at desc)
    from (
      select * from (
        select
          'promotion'::text as record_kind,
          r.id,
          r.buyer_id,
          coalesce(p.display_name,p.full_name,p.email,'Cliente') as client_name,
          p.email as client_email,
          c.code as benefit_type,
          c.name as benefit_label,
          r.discount_amount as amount,
          r.status,
          r.booking_id as source_booking_id,
          r.booking_id as used_booking_id,
          r.created_at as issued_at,
          r.updated_at as used_at
        from public.promotion_redemptions r
        join public.promotion_campaigns c on c.id = r.campaign_id
        left join public.profiles p on p.id = r.buyer_id

        union all

        select
          'bonus'::text,
          b.id,
          b.buyer_id,
          coalesce(p.display_name,p.full_name,p.email,'Cliente'),
          p.email,
          b.bonus_type,
          case b.bonus_type
            when 'welcome_cleaning_50' then 'Bono USD 50 limpieza'
            when 'provider_cancel_7' then 'Bono USD 7 cancelación'
            else b.bonus_type
          end,
          b.amount,
          b.status,
          b.source_booking_id,
          b.used_booking_id,
          b.issued_at,
          b.used_at
        from public.customer_bonuses b
        left join public.profiles p on p.id = b.buyer_id
      ) x
      where (v_status = 'all' or lower(x.status) = v_status)
        and (
          trim(coalesce(p_search,'')) = ''
          or lower(coalesce(x.client_name,'')) like v_search
          or lower(coalesce(x.client_email,'')) like v_search
          or lower(coalesce(x.benefit_label,'')) like v_search
          or lower(coalesce(x.benefit_type,'')) like v_search
        )
      limit greatest(1, least(coalesce(p_limit,200),500))
    ) q
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.yt_admin_benefits_summary_v37() from public, anon;
revoke execute on function public.yt_admin_benefits_json(text,text,integer) from public, anon;
grant execute on function public.yt_admin_benefits_summary_v37() to authenticated, service_role;
grant execute on function public.yt_admin_benefits_json(text,text,integer) to authenticated, service_role;

notify pgrst, 'reload schema';
-- V37 y V38 se mantienen en la MISMA transaccion. Las definiciones V38 de abajo
-- sustituyen las intermedias antes del commit final.

-- ============================================================================
-- WISSA v38 - CORRECCION BONO USD 50 PARA ROL OFRECER
-- Fecha: 2026-08-17
--
-- Regla definitiva:
--   A) Primeros 10 CLIENTES elegibles de limpieza -> 50% en su reserva.
--   B) Primeros 10 OFERENTES distintos que completen una reserva de limpieza
--      -> incentivo USD 50, una sola vez por oferente, sumado a la liquidacion
--         de ESA reserva completada.
--   C) Bono cliente USD 7 por cancelacion tardia de quien ofrece -> se mantiene.
--
-- El USD 50 NO es un cupon del cliente y NO se aplica a una reserva futura.
-- ============================================================================

-- 1. Desactivar por completo la regla equivocada de USD 50 para clientes.
drop trigger if exists trg_v37_grant_welcome_bonus_after_paid on public.bookings;
drop function if exists public.yt_v37_grant_welcome_bonus_after_paid();
drop index if exists public.uq_customer_bonus_welcome_per_buyer;

-- Si v37 llego a probarse en algun ambiente, los bonos USD 50 aun no usados se anulan.
update public.customer_bonuses
set status = 'cancelled',
    updated_at = now(),
    metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
      'cancelled_by', 'v38_provider_bonus_correction',
      'reason', 'USD 50 belongs to provider incentive, not customer benefit'
    )
where bonus_type = 'welcome_cleaning_50'
  and status = 'available';

-- 2. Campana independiente para Ofrecer: 10 oferentes x USD 50.
insert into public.promotion_campaigns (
  code, name, benefit_type, benefit_value, max_redemptions, service_scope, is_active, starts_at, metadata
)
values (
  'launch_first10_offerers_50',
  'Primeros 10 Ofrecer - USD 50 por primera limpieza completada',
  'fixed',
  50,
  10,
  'cleaning',
  true,
  now(),
  jsonb_build_object(
    'audience', 'provider',
    'role', 'ofrecer',
    'trigger', 'first_completed_cleaning_booking',
    'one_per_provider', true,
    'funded_by', 'wissa',
    'description', 'Los primeros 10 oferentes distintos reciben USD 50 adicionales al completar una reserva elegible de limpieza.'
  )
)
on conflict (code) do update
set name = excluded.name,
    benefit_type = excluded.benefit_type,
    benefit_value = excluded.benefit_value,
    max_redemptions = excluded.max_redemptions,
    service_scope = excluded.service_scope,
    is_active = excluded.is_active,
    metadata = excluded.metadata,
    updated_at = now();

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
  on public.provider_completion_bonuses (campaign_id, provider_id)
  where status <> 'cancelled';

create unique index if not exists uq_provider_completion_bonus_booking_campaign
  on public.provider_completion_bonuses (campaign_id, source_booking_id)
  where status <> 'cancelled';

create index if not exists idx_provider_completion_bonus_status
  on public.provider_completion_bonuses (campaign_id, status, earned_at);

alter table public.bookings
  add column if not exists provider_bonus_amount numeric not null default 0,
  add column if not exists provider_bonus_id uuid;

alter table public.bookings
  drop constraint if exists bookings_provider_bonus_id_fkey;

alter table public.bookings
  add constraint bookings_provider_bonus_id_fkey
  foreign key (provider_bonus_id) references public.provider_completion_bonuses(id);

alter table public.provider_completion_bonuses enable row level security;

drop policy if exists provider_completion_bonuses_owner_read_v38 on public.provider_completion_bonuses;
create policy provider_completion_bonuses_owner_read_v38
on public.provider_completion_bonuses for select
to authenticated
using (provider_id = auth.uid() or public.yt_admin_is_current_admin());

revoke insert, update, delete on public.provider_completion_bonuses from authenticated;
grant select on public.provider_completion_bonuses to authenticated;

-- 3. Clientes: mantener 50% lanzamiento + SOLO bono USD 7 por cancelacion.
create or replace function public.yt_apply_booking_benefits_v37(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_campaign public.promotion_campaigns%rowtype;
  v_bonus public.customer_bonuses%rowtype;
  v_category text := '';
  v_is_cleaning boolean := false;
  v_gross numeric := 0;
  v_promo_discount numeric := 0;
  v_bonus_discount numeric := 0;
  v_final numeric := 0;
  v_benefit_code text := null;
  v_benefit_label text := null;
  v_redemption_id uuid := null;
  v_now timestamptz := now();
  v_details jsonb := '{}'::jsonb;
  v_payment_method text := null;
begin
  select * into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if not found then
    raise exception 'Reserva no encontrada.';
  end if;

  if auth.uid() is not null
     and auth.uid() <> v_booking.buyer_id
     and not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado.';
  end if;

  if v_booking.benefit_applied_at is not null then
    return jsonb_build_object(
      'ok', true,
      'already_applied', true,
      'booking_id', v_booking.id,
      'benefit_code', v_booking.benefit_code,
      'benefit_label', v_booking.benefit_label,
      'gross_total', v_booking.gross_total_amount,
      'promotion_discount', v_booking.promotion_discount_amount,
      'bonus_discount', v_booking.bonus_discount_amount,
      'total', v_booking.total_amount
    );
  end if;

  -- Los beneficios se fijan antes del pago y no pueden inyectarse sobre reservas cerradas/pagadas.
  if coalesce(v_booking.payment_status,'not_started') = 'paid'
     or v_booking.status not in ('pending','pending_payment') then
    return jsonb_build_object(
      'ok', true,
      'eligible', false,
      'reason', 'booking_not_open_for_benefits',
      'booking_id', v_booking.id,
      'total', v_booking.total_amount
    );
  end if;

  select coalesce(s.category, v_booking.service_details->>'category', '')
  into v_category
  from public.services s
  where s.id = v_booking.service_id;

  if v_category is null or v_category = '' then
    v_category := coalesce(v_booking.service_details->>'category', '');
  end if;

  v_is_cleaning := lower(v_category) like '%limpieza%' or lower(v_category) like '%clean%';
  v_gross := greatest(coalesce(nullif(v_booking.gross_total_amount, 0), v_booking.total_amount, v_booking.subtotal_amount, v_booking.price_snapshot, 0), 0);
  v_details := coalesce(v_booking.service_details, '{}'::jsonb);

  select * into v_campaign
  from public.promotion_campaigns c
  where c.code = 'launch_first10_50'
    and c.is_active = true
    and (c.starts_at is null or c.starts_at <= v_now)
    and (c.ends_at is null or c.ends_at >= v_now)
  limit 1;

  if found and v_is_cleaning and (v_campaign.starts_at is null or v_booking.created_at >= v_campaign.starts_at) then
    -- Serializa el cupo para evitar que dos clientes tomen el #10 al mismo tiempo.
    perform pg_advisory_xact_lock(hashtext('wissa:launch_first10_50')::bigint);

    if not exists (
      select 1 from public.promotion_redemptions r
      where r.campaign_id = v_campaign.id
        and r.buyer_id = v_booking.buyer_id
        and r.status = 'applied'
    ) and (
      select count(*) from public.promotion_redemptions r
      where r.campaign_id = v_campaign.id and r.status = 'applied'
    ) < v_campaign.max_redemptions then
      v_promo_discount := round(v_gross * (v_campaign.benefit_value / 100.0), 2);
      v_benefit_code := v_campaign.code;
      v_benefit_label := 'Promoción primeros 10 clientes · 50%';

      insert into public.promotion_redemptions (
        campaign_id, buyer_id, booking_id, discount_percent, discount_amount, status, metadata
      ) values (
        v_campaign.id,
        v_booking.buyer_id,
        v_booking.id,
        v_campaign.benefit_value,
        v_promo_discount,
        'applied',
        jsonb_build_object('service_category', v_category, 'funded_by', 'wissa')
      ) returning id into v_redemption_id;
    end if;
  end if;

  -- No combinar el 50% con el bono compensatorio USD 7. El bono USD 50 ahora pertenece a Ofrecer y NO es descuento de cliente.
  if v_benefit_code is null then
    select * into v_bonus
    from public.customer_bonuses b
    where b.buyer_id = v_booking.buyer_id
      and b.status = 'available'
      and b.bonus_type = 'provider_cancel_7'
      and b.issued_at <= coalesce(v_booking.created_at, v_now)
      and (b.expires_at is null or b.expires_at >= v_now)
      and (b.service_scope = 'any' or (b.service_scope = 'cleaning' and v_is_cleaning))
    order by b.issued_at asc
    for update skip locked
    limit 1;

    if found then
      v_bonus_discount := least(v_bonus.amount, v_gross);
      v_benefit_code := v_bonus.bonus_type;
      v_benefit_label := case v_bonus.bonus_type
        when 'provider_cancel_7' then 'Bono por cancelación de quien ofrece · USD 7'
        else 'Bono Wissa'
      end;

      update public.customer_bonuses
      set status = 'used',
          used_amount = v_bonus_discount,
          used_booking_id = v_booking.id,
          used_at = v_now,
          updated_at = v_now
      where id = v_bonus.id;
    end if;
  end if;

  v_final := greatest(round(v_gross - v_promo_discount - v_bonus_discount, 2), 0);
  v_payment_method := case
    when v_promo_discount > 0 then 'promotion'
    when v_bonus_discount > 0 then 'bonus'
    else null
  end;

  v_details := jsonb_set(
    v_details,
    '{benefits}',
    jsonb_build_object(
      'code', v_benefit_code,
      'label', v_benefit_label,
      'gross_total', v_gross,
      'promotion_discount', v_promo_discount,
      'bonus_discount', v_bonus_discount,
      'final_total', v_final,
      'funded_by', case when v_benefit_code is null then null else 'wissa' end
    ),
    true
  );
  v_details := jsonb_set(v_details, '{total}', to_jsonb(v_final), true);
  if jsonb_typeof(v_details->'pricing') = 'object' then
    v_details := jsonb_set(v_details, '{pricing,total_amount}', to_jsonb(v_final), true);
  end if;

  update public.bookings
  set gross_total_amount = v_gross,
      promotion_discount_amount = v_promo_discount,
      bonus_discount_amount = v_bonus_discount,
      benefit_code = v_benefit_code,
      benefit_label = v_benefit_label,
      benefit_applied_at = v_now,
      applied_bonus_id = case when v_bonus.id is not null then v_bonus.id else null end,
      total_amount = v_final,
      service_details = v_details,
      updated_at = v_now,
      payment_status = case when v_final = 0 then 'paid' else payment_status end,
      status = case when v_final = 0 then 'paid_pending_acceptance' else status end,
      paid_at = case when v_final = 0 then coalesce(paid_at, v_now) else paid_at end,
      payment_provider = case when v_final = 0 then 'wissa_benefit' else payment_provider end,
      payment_method = case when v_final = 0 then coalesce(v_payment_method, 'promotion') else payment_method end
  where id = v_booking.id;

  if v_final = 0 and not exists (select 1 from public.payment_orders po where po.booking_id = v_booking.id and po.status = 'approved') then
    insert into public.payment_orders (
      booking_id, buyer_id, provider_id, provider,
      amount_total, platform_fee, provider_net, currency,
      status, payment_method, method, amount, approved_at, paid_at,
      kind, release_status, created_at, updated_at
    ) values (
      v_booking.id, v_booking.buyer_id, v_booking.provider_id, 'wissa_benefit',
      0, coalesce(v_booking.platform_fee,0), coalesce(v_booking.seller_payout,0), 'USD',
      'approved', coalesce(v_payment_method,'promotion'), coalesce(v_payment_method,'promotion'), 0, v_now, v_now,
      'booking', 'pending', v_now, v_now
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'booking_id', v_booking.id,
    'benefit_code', v_benefit_code,
    'benefit_label', v_benefit_label,
    'gross_total', v_gross,
    'promotion_discount', v_promo_discount,
    'bonus_discount', v_bonus_discount,
    'total', v_final,
    'payment_covered', v_final = 0
  );
end;
$$;

revoke execute on function public.yt_apply_booking_benefits_v37(uuid) from public, anon;
grant execute on function public.yt_apply_booking_benefits_v37(uuid) to authenticated, service_role;

-- 4. Otorgar USD 50 al primer servicio elegible completado por cada Ofrecer,
--    hasta agotar los 10 cupos globales.
create or replace function public.yt_v38_grant_provider_completion_bonus()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_campaign public.promotion_campaigns%rowtype;
  v_category text := '';
  v_is_cleaning boolean := false;
  v_is_offerer boolean := false;
  v_bonus_id uuid;
  v_base_payout numeric := 0;
  v_count integer := 0;
begin
  if new.provider_id is null
     or coalesce(new.payment_status,'') <> 'paid'
     or new.status not in ('completed_pending_release','completed') then
    return new;
  end if;

  -- Solo actuar cuando la reserva entra por primera vez a estado de servicio completado.
  if tg_op = 'UPDATE'
     and old.status in ('completed_pending_release','completed') then
    return new;
  end if;

  select * into v_campaign
  from public.promotion_campaigns c
  where c.code = 'launch_first10_offerers_50'
    and c.is_active = true
    and (c.starts_at is null or c.starts_at <= now())
    and (c.ends_at is null or c.ends_at >= now())
  limit 1;

  if not found then return new; end if;
  if v_campaign.starts_at is not null and new.created_at < v_campaign.starts_at then return new; end if;

  select coalesce(s.category, new.service_details->>'category', '')
  into v_category
  from public.services s
  where s.id = new.service_id;

  if coalesce(v_category,'') = '' then
    v_category := coalesce(new.service_details->>'category','');
  end if;

  v_is_cleaning := lower(v_category) like '%limpieza%' or lower(v_category) like '%clean%';
  if not v_is_cleaning then return new; end if;

  select exists (
    select 1
    from public.profiles p
    where p.id = new.provider_id
      and (
        lower(coalesce(p.role,'')) in ('provider','vendor','ofrecer','both','ambos')
        or lower(coalesce(p.mode_preference,'')) = 'provider'
        or coalesce(p.provider_enabled,false) = true
      )
  ) into v_is_offerer;

  if not v_is_offerer then return new; end if;

  -- Serializa los 10 cupos para impedir que dos cierres consuman el cupo #10.
  perform pg_advisory_xact_lock(hashtext('wissa:launch_first10_offerers_50')::bigint);

  if exists (
    select 1 from public.provider_completion_bonuses b
    where b.campaign_id = v_campaign.id
      and b.provider_id = new.provider_id
      and b.status <> 'cancelled'
  ) then
    return new;
  end if;

  select count(*) into v_count
  from public.provider_completion_bonuses b
  where b.campaign_id = v_campaign.id
    and b.status <> 'cancelled';

  if v_count >= v_campaign.max_redemptions then return new; end if;

  insert into public.provider_completion_bonuses (
    campaign_id, provider_id, source_booking_id, amount, status, metadata
  ) values (
    v_campaign.id,
    new.provider_id,
    new.id,
    v_campaign.benefit_value,
    'earned',
    jsonb_build_object(
      'service_category', v_category,
      'booking_completed_at', coalesce(new.completed_at, now()),
      'funded_by', 'wissa',
      'rule', 'first_completed_cleaning_booking_per_offerer'
    )
  ) returning id into v_bonus_id;

  v_base_payout := greatest(coalesce(
    nullif(new.seller_payout,0),
    nullif(new.gross_total_amount,0) - coalesce(new.platform_fee,0),
    nullif(new.price_snapshot,0) - coalesce(new.platform_fee,0),
    0
  ), 0);

  update public.bookings
  set provider_bonus_amount = v_campaign.benefit_value,
      provider_bonus_id = v_bonus_id,
      seller_payout = round(v_base_payout + v_campaign.benefit_value, 2),
      service_details = jsonb_set(
        coalesce(service_details,'{}'::jsonb),
        '{provider_bonus}',
        jsonb_build_object(
          'code', v_campaign.code,
          'label', 'Bono Ofrecer · USD 50',
          'amount', v_campaign.benefit_value,
          'funded_by', 'wissa',
          'earned', true,
          'bonus_id', v_bonus_id
        ),
        true
      ),
      updated_at = now()
  where id = new.id;

  insert into public.notifications (
    user_id, title, body, type, screen, related_booking_id, metadata, is_read, created_at
  )
  select
    new.provider_id,
    'Ganaste un bono de USD 50',
    'Completaste una reserva elegible de limpieza y estás entre los primeros 10 Ofrecer. Wissa agregó USD 50 a la liquidación de esta reserva.',
    'provider_launch_bonus_50',
    '/(provider-tabs)/earnings',
    new.id,
    jsonb_build_object(
      'booking_id', new.id,
      'bonus_id', v_bonus_id,
      'amount', v_campaign.benefit_value,
      'campaign', v_campaign.code
    ),
    false,
    now()
  where not exists (
    select 1 from public.notifications n
    where n.user_id = new.provider_id
      and n.related_booking_id = new.id
      and n.type = 'provider_launch_bonus_50'
  );

  -- Refrescar el saldo visible del oferente con seller_payout ya incrementado.
  if to_regprocedure('public.yt_recalculate_provider_balance(uuid)') is not null then
    perform public.yt_recalculate_provider_balance(new.provider_id);
  end if;

  return new;
end;
$$;

drop trigger if exists trg_v38_grant_provider_completion_bonus on public.bookings;
create trigger trg_v38_grant_provider_completion_bonus
after insert or update of status, payment_status on public.bookings
for each row execute function public.yt_v38_grant_provider_completion_bonus();

-- 5. Cuando Admin liquida la reserva, marcar el incentivo como pagado.
create or replace function public.yt_v38_sync_provider_bonus_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.provider_bonus_id is not null
     and coalesce(new.payout_release_status,'') = 'released'
     and (tg_op = 'INSERT' or old.payout_release_status is distinct from new.payout_release_status) then
    update public.provider_completion_bonuses
    set status = 'paid',
        paid_at = coalesce(new.payout_released_at, new.provider_paid_out_at, now()),
        updated_at = now(),
        metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object('paid_with_booking_id', new.id)
    where id = new.provider_bonus_id and status = 'earned';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_v38_sync_provider_bonus_paid on public.bookings;
create trigger trg_v38_sync_provider_bonus_paid
after insert or update of payout_release_status on public.bookings
for each row execute function public.yt_v38_sync_provider_bonus_paid();

-- 6. Liberacion Admin: seller_payout de booking manda sobre provider_net de la orden,
--    porque seller_payout puede incluir el incentivo Wissa de USD 50.
drop function if exists public.yt_admin_release_booking_payment(uuid, text);

create function public.yt_admin_release_booking_payment(
  p_booking_id uuid,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_now timestamptz := now();
  v_rate numeric := coalesce(public.yt_platform_commission_rate(), 0.12);
  v_total numeric := 0;
  v_fee numeric := 0;
  v_amount numeric := 0;
  v_order_id uuid;
  v_order_amount_total numeric := 0;
  v_order_amount numeric := 0;
  v_order_platform_fee numeric := 0;
  v_order_provider_net numeric := 0;
  v_payout_id uuid;
  v_notification_id uuid;
  v_internal_notification_id uuid;
  v_push_log_id uuid;
  v_reference text;
  v_service_title text := 'Servicio Wissa';
  v_title text := 'Pago liquidado';
  v_body text := 'Administracion registro la liquidacion de tu servicio.';
  v_already_released boolean := false;
begin
  if not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado. Solo administradores.';
  end if;

  select b.*
  into v_booking
  from public.bookings b
  where b.id = p_booking_id
  for update;

  if v_booking.id is null then
    raise exception 'Reserva no encontrada.';
  end if;

  if coalesce(v_booking.payment_status, '') <> 'paid' then
    raise exception 'La reserva no esta pagada.';
  end if;

  if coalesce(v_booking.status, '') not in ('completed', 'completed_pending_release') then
    raise exception 'La reserva debe estar completada para liberar.';
  end if;

  select coalesce(v_booking.service_title, s.title, 'Servicio Wissa')
  into v_service_title
  from public.services s
  where s.id = v_booking.service_id
  limit 1;

  v_service_title := coalesce(nullif(v_service_title, ''), v_booking.service_title, 'Servicio Wissa');
  v_already_released := coalesce(v_booking.payout_release_status, 'not_released') = 'released'
    or coalesce(v_booking.finance_status, '') = 'released';

  select
    po.id,
    coalesce(po.amount_total, 0),
    coalesce(po.amount, 0),
    coalesce(po.platform_fee, 0),
    coalesce(po.provider_net, 0)
  into
    v_order_id,
    v_order_amount_total,
    v_order_amount,
    v_order_platform_fee,
    v_order_provider_net
  from public.payment_orders po
  where po.booking_id = p_booking_id
    and po.status = 'approved'
  order by po.approved_at desc nulls last, po.paid_at desc nulls last, po.created_at desc nulls last
  limit 1;

  v_total := coalesce(nullif(v_order_amount_total, 0), nullif(v_order_amount, 0), nullif(v_booking.total_amount, 0), nullif(v_booking.price_snapshot, 0), 0);
  v_fee := coalesce(nullif(v_order_platform_fee, 0), nullif(v_booking.platform_fee, 0), round(v_total * v_rate, 2), 0);
  v_amount := coalesce(nullif(v_booking.seller_payout, 0), nullif(v_order_provider_net, 0), round(greatest(v_total - v_fee, 0), 2), 0);

  if v_total <= 0 then
    raise exception 'El monto total de la reserva no es valido.';
  end if;

  if v_amount <= 0 then
    raise exception 'El monto neto del proveedor no es valido.';
  end if;

  v_reference := 'ADMIN-' || upper(left(replace(p_booking_id::text, '-', ''), 10));

  select pp.id
  into v_payout_id
  from public.provider_payouts pp
  where pp.booking_id = p_booking_id
    and pp.provider_id = v_booking.provider_id
  order by pp.paid_at desc nulls last, pp.created_at desc nulls last
  limit 1;

  if v_payout_id is null then
    insert into public.provider_payouts(
      provider_id,
      booking_id,
      amount,
      status,
      method,
      reference,
      admin_id,
      paid_at,
      notes,
      created_at,
      updated_at
    )
    values (
      v_booking.provider_id,
      p_booking_id,
      v_amount,
      'paid',
      'manual_admin',
      v_reference,
      auth.uid(),
      v_now,
      coalesce(nullif(p_note, ''), 'Liquidacion registrada desde admin web.'),
      v_now,
      v_now
    )
    returning id into v_payout_id;
  else
    update public.provider_payouts
    set
      provider_id = v_booking.provider_id,
      amount = v_amount,
      status = 'paid',
      method = coalesce(nullif(method, ''), 'manual_admin'),
      reference = coalesce(nullif(reference, ''), v_reference),
      admin_id = coalesce(admin_id, auth.uid()),
      paid_at = coalesce(paid_at, v_now),
      notes = coalesce(nullif(p_note, ''), notes, 'Liquidacion registrada desde admin web.'),
      updated_at = v_now
    where id = v_payout_id;
  end if;

  update public.bookings
  set
    status = case when status = 'completed_pending_release' then 'completed' else status end,
    total_amount = coalesce(nullif(total_amount, 0), v_total),
    platform_fee = v_fee,
    seller_payout = v_amount,
    payout_release_status = 'released',
    finance_status = 'released',
    released_at = coalesce(released_at, v_now),
    payout_released_at = coalesce(payout_released_at, v_now),
    provider_paid_out_at = coalesce(provider_paid_out_at, v_now),
    admin_release_note = coalesce(nullif(p_note, ''), admin_release_note, 'Liquidacion registrada desde admin web.'),
    updated_at = v_now
  where id = p_booking_id;

  update public.payment_orders
  set
    release_status = 'released',
    amount = coalesce(nullif(amount, 0), v_total),
    amount_total = coalesce(nullif(amount_total, 0), v_total),
    platform_fee = v_fee,
    provider_net = v_amount,
    updated_at = v_now
  where booking_id = p_booking_id
    and status = 'approved';

  perform public.yt_recalculate_provider_balance(v_booking.provider_id);

  select n.id
  into v_notification_id
  from public.notifications n
  where n.user_id = v_booking.provider_id
    and n.related_booking_id = p_booking_id
    and n.type = 'payout_released_admin'
  order by n.created_at desc
  limit 1;

  if v_notification_id is null then
    insert into public.notifications(
      user_id,
      title,
      body,
      type,
      screen,
      related_booking_id,
      metadata,
      is_read,
      created_at
    )
    values (
      v_booking.provider_id,
      v_title,
      v_body,
      'payout_released_admin',
      '/main/provider-billing',
      p_booking_id,
      jsonb_build_object(
        'booking_id', p_booking_id,
        'payout_id', v_payout_id,
        'amount', v_amount,
        'reference', v_reference,
        'service_title', v_service_title
      ),
      false,
      v_now
    )
    returning id into v_notification_id;
  end if;

  select i.id
  into v_internal_notification_id
  from public.internal_notifications i
  where i.user_id = v_booking.provider_id
    and i.reference_id = p_booking_id
    and i.type = 'payout_released_admin'
  order by i.created_at desc
  limit 1;

  if v_internal_notification_id is null then
    insert into public.internal_notifications(
      user_id,
      title,
      body,
      type,
      reference_id,
      metadata,
      is_read,
      created_at
    )
    values (
      v_booking.provider_id,
      v_title,
      v_body,
      'payout_released_admin',
      p_booking_id,
      jsonb_build_object(
        'booking_id', p_booking_id,
        'payout_id', v_payout_id,
        'amount', v_amount,
        'reference', v_reference
      ),
      false,
      v_now
    )
    returning id into v_internal_notification_id;
  end if;

  select p.id
  into v_push_log_id
  from public.push_notification_logs p
  where p.user_id = v_booking.provider_id
    and p.booking_id = p_booking_id
    and p.type = 'payout_released_admin'
    and p.status in ('pending', 'sent')
  order by case p.status when 'pending' then 0 else 1 end, p.created_at desc
  limit 1;

  if v_push_log_id is null then
    insert into public.push_notification_logs(
      user_id,
      notification_id,
      booking_id,
      title,
      body,
      type,
      status,
      created_at,
      updated_at
    )
    values (
      v_booking.provider_id,
      v_notification_id,
      p_booking_id,
      v_title,
      v_body,
      'payout_released_admin',
      'pending',
      v_now,
      v_now
    )
    returning id into v_push_log_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'already_released', v_already_released,
    'booking_id', p_booking_id,
    'provider_id', v_booking.provider_id,
    'buyer_id', v_booking.buyer_id,
    'payout_id', v_payout_id,
    'notification_id', v_notification_id,
    'internal_notification_id', v_internal_notification_id,
    'push_log_id', v_push_log_id,
    'amount', v_amount,
    'reference', v_reference,
    'released_at', v_now,
    'title', v_title,
    'body', v_body,
    'screen', '/main/provider-billing'
  );
end;
$$;

drop function if exists public.yt_admin_dashboard_summary();

create function public.yt_admin_dashboard_summary()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_approved_amount numeric := 0;
  v_platform_commission_earned numeric := 0;
  v_platform_commission_withdrawn numeric := 0;
  v_notifications_pending bigint := 0;
  v_push_pending bigint := 0;
  v_approved_payments bigint := 0;
  v_active_bookings bigint := 0;
begin
  if not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado.';
  end if;

  select
    coalesce(count(*), 0),
    coalesce(sum(coalesce(amount_total, amount, 0)), 0),
    coalesce(sum(coalesce(nullif(platform_fee, 0), round(coalesce(amount_total, amount, 0) * public.yt_platform_commission_rate(), 2), 0)), 0)
  into v_approved_payments, v_approved_amount, v_platform_commission_earned
  from public.payment_orders
  where status = 'approved';

  select coalesce(sum(amount), 0)
  into v_platform_commission_withdrawn
  from public.platform_commission_withdrawals
  where company_id is null
    and coalesce(source_type, 'platform_commission') = 'platform_commission'
    and coalesce(status, 'collected') in ('collected', 'approved', 'paid');

  select coalesce(count(*), 0)
  into v_active_bookings
  from public.bookings
  where coalesce(status, '') not in ('rejected', 'cancelled')
    and coalesce(payment_status, '') not in ('failed', 'cancelled');

  select coalesce(count(*), 0)
  into v_push_pending
  from public.push_notification_logs
  where status = 'pending'
    and admin_read_at is null
    and admin_archived_at is null;

  select
    coalesce((select count(*) from public.notifications where coalesce(is_read, false) = false and admin_archived_at is null), 0)
    + coalesce((select count(*) from public.internal_notifications where coalesce(is_read, false) = false and admin_archived_at is null), 0)
    + coalesce(v_push_pending, 0)
  into v_notifications_pending;

  return jsonb_build_object(
    'users', (select count(*) from public.profiles),
    'companies', (select count(*) from public.companies),
    'services', (select count(*) from public.services),
    'active_services', (select count(*) from public.services where coalesce(is_active, false)),
    'services_missing_location', (
      select count(*)
      from public.services
      where coalesce(is_active, false)
        and (offer_latitude is null or offer_longitude is null)
    ),
    'bookings', v_active_bookings,
    'bookings_total', (select count(*) from public.bookings),
    'payments', v_approved_payments,
    'payment_orders_total', (select count(*) from public.payment_orders),
    'failed_payments', (select count(*) from public.payment_orders where status in ('rejected', 'cancelled')),
    'pending_payments', (select count(*) from public.payment_orders where status = 'pending'),
    'approved_amount', v_approved_amount,
    'platform_commission', v_platform_commission_earned,
    'platform_commission_withdrawn', v_platform_commission_withdrawn,
    'platform_commission_pending', greatest(v_platform_commission_earned - v_platform_commission_withdrawn, 0),
    'release_pending', (
      select count(*)
      from public.bookings
      where payment_status = 'paid'
        and status in ('completed','completed_pending_release')
        and coalesce(payout_release_status, 'not_released') <> 'released'
    ),
    'released_bookings', (select count(*) from public.bookings where coalesce(payout_release_status, '') = 'released'),
    'admin_notifications_pending', v_notifications_pending,
    'push_pending', v_push_pending
  );
end;
$$;

grant execute on function public.yt_admin_archive_notification(text, uuid, boolean) to authenticated, service_role;
grant execute on function public.yt_admin_notifications_json(text, text, integer, date, date) to authenticated, service_role;
grant execute on function public.yt_admin_release_booking_payment(uuid, text) to authenticated, service_role;
grant execute on function public.yt_admin_dashboard_summary() to authenticated, service_role;

revoke execute on function public.yt_admin_archive_notification(text, uuid, boolean) from public, anon;
revoke execute on function public.yt_admin_notifications_json(text, text, integer, date, date) from public, anon;
revoke execute on function public.yt_admin_release_booking_payment(uuid, text) from public, anon;

-- 7. Admin - resumen actualizado.
create or replace function public.yt_admin_benefits_summary_v38()
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_client_campaign public.promotion_campaigns%rowtype;
  v_provider_campaign public.promotion_campaigns%rowtype;
  v_client_used integer := 0;
  v_provider_used integer := 0;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  select * into v_client_campaign from public.promotion_campaigns where code = 'launch_first10_50' limit 1;
  select * into v_provider_campaign from public.promotion_campaigns where code = 'launch_first10_offerers_50' limit 1;

  select count(*) into v_client_used
  from public.promotion_redemptions r
  where r.campaign_id = v_client_campaign.id and r.status = 'applied';

  select count(*) into v_provider_used
  from public.provider_completion_bonuses b
  where b.campaign_id = v_provider_campaign.id and b.status <> 'cancelled';

  return jsonb_build_object(
    'client_launch_limit', coalesce(v_client_campaign.max_redemptions,10),
    'client_launch_used', v_client_used,
    'client_launch_remaining', greatest(coalesce(v_client_campaign.max_redemptions,10) - v_client_used, 0),
    'provider_bonus_limit', coalesce(v_provider_campaign.max_redemptions,10),
    'provider_bonus_used', v_provider_used,
    'provider_bonus_remaining', greatest(coalesce(v_provider_campaign.max_redemptions,10) - v_provider_used, 0),
    'provider_bonus_earned_amount', coalesce((select round(sum(amount),2) from public.provider_completion_bonuses where status in ('earned','paid')),0),
    'provider_bonus_paid_amount', coalesce((select round(sum(amount),2) from public.provider_completion_bonuses where status = 'paid'),0),
    'provider_cancel_7_available', (select count(*) from public.customer_bonuses where bonus_type = 'provider_cancel_7' and status = 'available'),
    'provider_cancel_7_available_amount', coalesce((select round(sum(amount),2) from public.customer_bonuses where bonus_type = 'provider_cancel_7' and status = 'available'),0),
    'provider_cancel_7_issued', (select count(*) from public.customer_bonuses where bonus_type = 'provider_cancel_7' and status <> 'cancelled'),
    'provider_cancel_7_used_amount', coalesce((select round(sum(used_amount),2) from public.customer_bonuses where bonus_type = 'provider_cancel_7' and status = 'used'),0),
    'promotion_discount_total', coalesce((select round(sum(discount_amount),2) from public.promotion_redemptions where status = 'applied'),0),
    'benefit_cost_total',
      coalesce((select round(sum(discount_amount),2) from public.promotion_redemptions where status = 'applied'),0)
      + coalesce((select round(sum(used_amount),2) from public.customer_bonuses where bonus_type = 'provider_cancel_7' and status = 'used'),0)
      + coalesce((select round(sum(amount),2) from public.provider_completion_bonuses where status in ('earned','paid')),0)
  );
end;
$$;

create or replace function public.yt_admin_benefits_json_v38(
  p_search text default '',
  p_status text default 'all',
  p_limit integer default 250
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_search text := '%' || lower(trim(coalesce(p_search,''))) || '%';
  v_status text := lower(trim(coalesce(p_status,'all')));
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(q) order by q.issued_at desc)
    from (
      select * from (
        select
          'client_promotion'::text as record_kind,
          r.id,
          r.buyer_id as person_id,
          coalesce(p.display_name,p.full_name,p.email,'Cliente') as person_name,
          p.email as person_email,
          'Cliente'::text as person_role,
          c.code as benefit_type,
          c.name as benefit_label,
          r.discount_amount as amount,
          r.status,
          r.booking_id as source_booking_id,
          r.booking_id as used_booking_id,
          r.created_at as issued_at,
          r.updated_at as used_at
        from public.promotion_redemptions r
        join public.promotion_campaigns c on c.id = r.campaign_id
        left join public.profiles p on p.id = r.buyer_id
        where c.code = 'launch_first10_50'

        union all

        select
          'customer_bonus'::text,
          b.id,
          b.buyer_id,
          coalesce(p.display_name,p.full_name,p.email,'Cliente'),
          p.email,
          'Cliente'::text,
          b.bonus_type,
          'Bono USD 7 · cancelación de quien ofrece',
          b.amount,
          b.status,
          b.source_booking_id,
          b.used_booking_id,
          b.issued_at,
          b.used_at
        from public.customer_bonuses b
        left join public.profiles p on p.id = b.buyer_id
        where b.bonus_type = 'provider_cancel_7'

        union all

        select
          'provider_bonus'::text,
          pb.id,
          pb.provider_id,
          coalesce(p.display_name,p.full_name,p.email,'Ofrecer'),
          p.email,
          'Ofrecer'::text,
          c.code,
          'Bono Ofrecer USD 50 · primera limpieza completada',
          pb.amount,
          pb.status,
          pb.source_booking_id,
          null::uuid,
          pb.earned_at,
          pb.paid_at
        from public.provider_completion_bonuses pb
        join public.promotion_campaigns c on c.id = pb.campaign_id
        left join public.profiles p on p.id = pb.provider_id
      ) x
      where (v_status = 'all' or lower(x.status) = v_status)
        and (
          trim(coalesce(p_search,'')) = ''
          or lower(coalesce(x.person_name,'')) like v_search
          or lower(coalesce(x.person_email,'')) like v_search
          or lower(coalesce(x.person_role,'')) like v_search
          or lower(coalesce(x.benefit_label,'')) like v_search
          or lower(coalesce(x.benefit_type,'')) like v_search
        )
      limit greatest(1, least(coalesce(p_limit,250),500))
    ) q
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.yt_admin_benefits_summary_v38() from public, anon;
revoke execute on function public.yt_admin_benefits_json_v38(text,text,integer) from public, anon;
grant execute on function public.yt_admin_benefits_summary_v38() to authenticated, service_role;
grant execute on function public.yt_admin_benefits_json_v38(text,text,integer) to authenticated, service_role;

notify pgrst, 'reload schema';
commit;
-- ============================================================================
-- WISSA v39 - BONO USD 7 EN CHECKOUT + REGLAS DE CANCELACION + CIERRE
-- Fecha: 2026-08-17
--
-- Reglas finales:
--   1) El bono USD 7 nace cuando OFRECER cancela una reserva PAGADA el mismo dia
--      o 1 dia antes.
--   2) El bono se puede usar en la siguiente reserva elegible de:
--      Limpieza, Limpieza exteriores o Plomeria.
--   3) El cliente decide en checkout si lo aplica o lo conserva.
--   4) Si el CLIENTE cancela la reserva donde uso el bono, los USD 7 se pierden.
--   5) Si OFRECER cancela esa reserva, el bono usado se restaura.
--   6) El reembolso monetario de la reserva cancelada sigue siendo independiente
--      y queda a cargo del Admin Wissa (mensaje operativo: aprox. 24 horas).
--   7) El codigo unico de cierre se mantiene: solo nace cuando el cliente inicia
--      el cierre; nunca al pagar.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- A. ALCANCE DEL BONO USD 7: SOLO SERVICIOS PRINCIPALES WISSA
-- --------------------------------------------------------------------------
alter table public.customer_bonuses
  drop constraint if exists customer_bonuses_service_scope_check;

alter table public.customer_bonuses
  add constraint customer_bonuses_service_scope_check
  check (service_scope in ('any','cleaning','core_services'));

update public.customer_bonuses
set service_scope = 'core_services',
    updated_at = now(),
    metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
      'scope_v39', 'cleaning_exterior_cleaning_plumbing'
    )
where bonus_type = 'provider_cancel_7'
  and service_scope = 'any';

create or replace function public.yt_v39_is_core_service_category(p_category text)
returns boolean
language sql
immutable
as $$
  select
    lower(coalesce(p_category,'')) like '%limpieza%'
    or lower(coalesce(p_category,'')) like '%clean%'
    or lower(coalesce(p_category,'')) like '%plomer%'
    or lower(coalesce(p_category,'')) like '%plumb%';
$$;

-- --------------------------------------------------------------------------
-- B. PREVIEW PARA EL CHECKOUT DEL CLIENTE
-- --------------------------------------------------------------------------
create or replace function public.yt_customer_cancel_bonus_preview_v39(p_category text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bonus public.customer_bonuses%rowtype;
  v_supported boolean := public.yt_v39_is_core_service_category(p_category);
begin
  if auth.uid() is null then
    return jsonb_build_object('eligible', false, 'reason', 'not_authenticated');
  end if;

  if not v_supported then
    return jsonb_build_object(
      'eligible', false,
      'reason', 'service_not_supported',
      'supported_services', jsonb_build_array('Limpieza','Limpieza exteriores','Plomeria')
    );
  end if;

  select * into v_bonus
  from public.customer_bonuses b
  where b.buyer_id = auth.uid()
    and b.status = 'available'
    and b.bonus_type = 'provider_cancel_7'
    and (b.expires_at is null or b.expires_at >= now())
    and b.service_scope in ('any','core_services')
  order by b.issued_at asc
  limit 1;

  if not found then
    return jsonb_build_object('eligible', false, 'reason', 'no_available_bonus');
  end if;

  return jsonb_build_object(
    'eligible', true,
    'bonus_id', v_bonus.id,
    'amount', v_bonus.amount,
    'source_booking_id', v_bonus.source_booking_id,
    'service_scope', v_bonus.service_scope,
    'issued_at', v_bonus.issued_at,
    'label', 'Bono de compensacion por cancelacion de quien ofrece'
  );
end;
$$;

revoke execute on function public.yt_customer_cancel_bonus_preview_v39(text) from public, anon;
grant execute on function public.yt_customer_cancel_bonus_preview_v39(text) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- C. APLICACION DE BENEFICIOS EN LA RESERVA
--     50% lanzamiento tiene prioridad. El bono USD 7 solo se consume si el
--     cliente lo selecciono y no entro la promocion 50%.
-- --------------------------------------------------------------------------
create or replace function public.yt_apply_booking_benefits_v39(
  p_booking_id uuid,
  p_apply_cancel_bonus boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_campaign public.promotion_campaigns%rowtype;
  v_bonus public.customer_bonuses%rowtype;
  v_category text := '';
  v_is_cleaning boolean := false;
  v_is_core_service boolean := false;
  v_gross numeric := 0;
  v_promo_discount numeric := 0;
  v_bonus_discount numeric := 0;
  v_final numeric := 0;
  v_benefit_code text := null;
  v_benefit_label text := null;
  v_redemption_id uuid := null;
  v_now timestamptz := now();
  v_details jsonb := '{}'::jsonb;
  v_payment_method text := null;
begin
  select * into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if not found then
    raise exception 'Reserva no encontrada.';
  end if;

  if auth.uid() is not null
     and auth.uid() <> v_booking.buyer_id
     and not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado.';
  end if;

  if v_booking.benefit_applied_at is not null then
    return jsonb_build_object(
      'ok', true,
      'already_applied', true,
      'booking_id', v_booking.id,
      'benefit_code', v_booking.benefit_code,
      'benefit_label', v_booking.benefit_label,
      'gross_total', v_booking.gross_total_amount,
      'promotion_discount', v_booking.promotion_discount_amount,
      'bonus_discount', v_booking.bonus_discount_amount,
      'total', v_booking.total_amount
    );
  end if;

  if coalesce(v_booking.payment_status,'not_started') = 'paid'
     or v_booking.status not in ('pending','pending_payment') then
    return jsonb_build_object(
      'ok', true,
      'eligible', false,
      'reason', 'booking_not_open_for_benefits',
      'booking_id', v_booking.id,
      'total', v_booking.total_amount
    );
  end if;

  select coalesce(s.category, v_booking.service_details->>'category', '')
  into v_category
  from public.services s
  where s.id = v_booking.service_id;

  if coalesce(v_category,'') = '' then
    v_category := coalesce(v_booking.service_details->>'category', '');
  end if;

  v_is_cleaning := lower(v_category) like '%limpieza%' or lower(v_category) like '%clean%';
  v_is_core_service := public.yt_v39_is_core_service_category(v_category);
  v_gross := greatest(coalesce(nullif(v_booking.gross_total_amount, 0), v_booking.total_amount, v_booking.subtotal_amount, v_booking.price_snapshot, 0), 0);
  v_details := coalesce(v_booking.service_details, '{}'::jsonb);

  -- Promocion automatica de los primeros 10 clientes de limpieza.
  select * into v_campaign
  from public.promotion_campaigns c
  where c.code = 'launch_first10_50'
    and c.is_active = true
    and (c.starts_at is null or c.starts_at <= v_now)
    and (c.ends_at is null or c.ends_at >= v_now)
  limit 1;

  if found and v_is_cleaning and (v_campaign.starts_at is null or v_booking.created_at >= v_campaign.starts_at) then
    perform pg_advisory_xact_lock(hashtext('wissa:launch_first10_50')::bigint);

    if not exists (
      select 1 from public.promotion_redemptions r
      where r.campaign_id = v_campaign.id
        and r.buyer_id = v_booking.buyer_id
        and r.status = 'applied'
    ) and (
      select count(*) from public.promotion_redemptions r
      where r.campaign_id = v_campaign.id and r.status = 'applied'
    ) < v_campaign.max_redemptions then
      v_promo_discount := round(v_gross * (v_campaign.benefit_value / 100.0), 2);
      v_benefit_code := v_campaign.code;
      v_benefit_label := 'Promocion primeros 10 clientes · 50%';

      insert into public.promotion_redemptions (
        campaign_id, buyer_id, booking_id, discount_percent, discount_amount, status, metadata
      ) values (
        v_campaign.id,
        v_booking.buyer_id,
        v_booking.id,
        v_campaign.benefit_value,
        v_promo_discount,
        'applied',
        jsonb_build_object('service_category', v_category, 'funded_by', 'wissa')
      ) returning id into v_redemption_id;
    end if;
  end if;

  -- Bono USD 7: solo si el cliente lo eligio y la reserva es de los 3 servicios.
  if v_benefit_code is null and coalesce(p_apply_cancel_bonus,false) and v_is_core_service then
    select * into v_bonus
    from public.customer_bonuses b
    where b.buyer_id = v_booking.buyer_id
      and b.status = 'available'
      and b.bonus_type = 'provider_cancel_7'
      and b.issued_at <= coalesce(v_booking.created_at, v_now)
      and (b.expires_at is null or b.expires_at >= v_now)
      and b.service_scope in ('any','core_services')
    order by b.issued_at asc
    for update skip locked
    limit 1;

    if found then
      v_bonus_discount := least(v_bonus.amount, v_gross);
      v_benefit_code := v_bonus.bonus_type;
      v_benefit_label := 'Bono por cancelacion de quien ofrece · USD 7';

      update public.customer_bonuses
      set status = 'used',
          used_amount = v_bonus_discount,
          used_booking_id = v_booking.id,
          used_at = v_now,
          updated_at = v_now,
          metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
            'selected_by_customer', true,
            'used_service_category', v_category
          )
      where id = v_bonus.id;
    end if;
  end if;

  v_final := greatest(round(v_gross - v_promo_discount - v_bonus_discount, 2), 0);
  v_payment_method := case
    when v_promo_discount > 0 then 'promotion'
    when v_bonus_discount > 0 then 'bonus'
    else null
  end;

  v_details := jsonb_set(
    v_details,
    '{benefits}',
    jsonb_build_object(
      'code', v_benefit_code,
      'label', v_benefit_label,
      'gross_total', v_gross,
      'promotion_discount', v_promo_discount,
      'bonus_discount', v_bonus_discount,
      'final_total', v_final,
      'cancel_bonus_requested', coalesce(p_apply_cancel_bonus,false),
      'funded_by', case when v_benefit_code is null then null else 'wissa' end
    ),
    true
  );
  v_details := jsonb_set(v_details, '{total}', to_jsonb(v_final), true);
  if jsonb_typeof(v_details->'pricing') = 'object' then
    v_details := jsonb_set(v_details, '{pricing,total_amount}', to_jsonb(v_final), true);
  end if;

  update public.bookings
  set gross_total_amount = v_gross,
      promotion_discount_amount = v_promo_discount,
      bonus_discount_amount = v_bonus_discount,
      benefit_code = v_benefit_code,
      benefit_label = v_benefit_label,
      benefit_applied_at = v_now,
      applied_bonus_id = case when v_bonus.id is not null then v_bonus.id else null end,
      total_amount = v_final,
      service_details = v_details,
      updated_at = v_now,
      payment_status = case when v_final = 0 then 'paid' else payment_status end,
      status = case when v_final = 0 then 'paid_pending_acceptance' else status end,
      paid_at = case when v_final = 0 then coalesce(paid_at, v_now) else paid_at end,
      payment_provider = case when v_final = 0 then 'wissa_benefit' else payment_provider end,
      payment_method = case when v_final = 0 then coalesce(v_payment_method, 'promotion') else payment_method end
  where id = v_booking.id;

  if v_final = 0 and not exists (
    select 1 from public.payment_orders po
    where po.booking_id = v_booking.id and po.status = 'approved'
  ) then
    insert into public.payment_orders (
      booking_id, buyer_id, provider_id, provider,
      amount_total, platform_fee, provider_net, currency,
      status, payment_method, method, amount, approved_at, paid_at,
      kind, release_status, created_at, updated_at
    ) values (
      v_booking.id, v_booking.buyer_id, v_booking.provider_id, 'wissa_benefit',
      0, coalesce(v_booking.platform_fee,0), coalesce(v_booking.seller_payout,0), 'USD',
      'approved', coalesce(v_payment_method,'promotion'), coalesce(v_payment_method,'promotion'), 0, v_now, v_now,
      'booking', 'pending', v_now, v_now
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'booking_id', v_booking.id,
    'benefit_code', v_benefit_code,
    'benefit_label', v_benefit_label,
    'gross_total', v_gross,
    'promotion_discount', v_promo_discount,
    'bonus_discount', v_bonus_discount,
    'total', v_final,
    'payment_covered', v_final = 0,
    'cancel_bonus_requested', coalesce(p_apply_cancel_bonus,false),
    'cancel_bonus_applied', v_bonus_discount > 0
  );
end;
$$;

revoke execute on function public.yt_apply_booking_benefits_v39(uuid,boolean) from public, anon;
grant execute on function public.yt_apply_booking_benefits_v39(uuid,boolean) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- D. CANCELACION POR QUIEN OFRECE: RESTAURA BONO USADO + CREA NUEVO USD 7
-- --------------------------------------------------------------------------
create or replace function public.yt_provider_cancel_booking_v37(
  p_booking_id uuid,
  p_reason text default 'Cancelada por quien ofrece'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking public.bookings%rowtype;
  v_today date := (now() at time zone 'America/Panama')::date;
  v_days integer;
  v_bonus_id uuid;
  v_bonus_granted boolean := false;
  v_reason text := coalesce(nullif(btrim(p_reason),''), 'Cancelada por quien ofrece');
begin
  select * into v_booking
  from public.bookings
  where id = p_booking_id
  for update;

  if not found then raise exception 'Reserva no encontrada.'; end if;
  if auth.uid() is distinct from v_booking.provider_id then
    raise exception 'Solo quien ofrece puede cancelar esta reserva.';
  end if;
  if coalesce(v_booking.payment_status,'') <> 'paid' then
    raise exception 'Solo se puede cancelar desde este flujo una reserva pagada.';
  end if;
  if v_booking.status <> 'accepted' then
    raise exception 'Solo se puede cancelar una reserva aceptada y aun no cerrada.';
  end if;
  if coalesce(v_booking.buyer_confirmed,false) or coalesce(v_booking.provider_confirmed,false) then
    raise exception 'El cierre del servicio ya comenzo; la reserva no se puede cancelar desde este flujo.';
  end if;

  v_days := v_booking.booking_date - v_today;

  -- Si el cliente habia usado un bono USD 7 aqui, no lo pierde por una nueva
  -- cancelacion de quien ofrece: vuelve a Disponible.
  if v_booking.applied_bonus_id is not null then
    update public.customer_bonuses
    set status = 'available',
        used_amount = 0,
        used_booking_id = null,
        used_at = null,
        updated_at = now(),
        metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
          'restored_from_provider_cancel_booking_id', v_booking.id,
          'restored_at', now()
        )
    where id = v_booking.applied_bonus_id
      and bonus_type = 'provider_cancel_7'
      and status = 'used';
  end if;

  update public.bookings
  set status = 'cancelled',
      cancel_reason = v_reason,
      provider_cancelled_at = now(),
      provider_confirmed = false,
      buyer_confirmed = false,
      updated_at = now()
  where id = v_booking.id;

  if v_days between 0 and 1 then
    insert into public.customer_bonuses (
      buyer_id, bonus_type, amount, service_scope, status, source_booking_id, metadata
    ) values (
      v_booking.buyer_id,
      'provider_cancel_7',
      7,
      'core_services',
      'available',
      v_booking.id,
      jsonb_build_object(
        'reason', 'provider_cancelled_same_or_previous_day',
        'booking_date', v_booking.booking_date,
        'cancel_date_panama', v_today,
        'days_before', v_days,
        'valid_for', jsonb_build_array('Limpieza','Limpieza exteriores','Plomeria')
      )
    )
    on conflict do nothing
    returning id into v_bonus_id;

    v_bonus_granted := v_bonus_id is not null or exists (
      select 1 from public.customer_bonuses b
      where b.bonus_type = 'provider_cancel_7'
        and b.source_booking_id = v_booking.id
        and b.status <> 'cancelled'
    );
  end if;

  insert into public.notifications (
    user_id, title, body, type, screen, related_booking_id, metadata, is_read, created_at
  ) values (
    v_booking.buyer_id,
    case when v_bonus_granted then 'Reserva cancelada · bono de USD 7' else 'Reserva cancelada por quien ofrece' end,
    case when v_bonus_granted
      then 'Quien ofrece cancelo el mismo dia o un dia antes. Tienes un bono de USD 7 para Limpieza, Limpieza exteriores o Plomeria. La devolucion del pago quedo en revision y Wissa la procesa administrativamente, normalmente en aproximadamente 24 horas.'
      else 'Quien ofrece cancelo la reserva. La devolucion del pago quedo en revision por Wissa y normalmente se procesa administrativamente en aproximadamente 24 horas.'
    end,
    case when v_bonus_granted then 'provider_cancel_bonus_7' else 'provider_cancelled_booking' end,
    '/(client-tabs)/bookings',
    v_booking.id,
    jsonb_build_object(
      'booking_id', v_booking.id,
      'bonus_granted', v_bonus_granted,
      'bonus_amount', case when v_bonus_granted then 7 else 0 end,
      'refund_eta_hours_approx', 24,
      'bonus_valid_for', jsonb_build_array('cleaning','exterior_cleaning','plumbing')
    ),
    false,
    now()
  );

  return jsonb_build_object(
    'ok', true,
    'booking_id', v_booking.id,
    'status', 'cancelled',
    'refund_pending', true,
    'refund_eta_hours_approx', 24,
    'bonus_granted', v_bonus_granted,
    'bonus_amount', case when v_bonus_granted then 7 else 0 end,
    'days_before', v_days
  );
end;
$$;

revoke execute on function public.yt_provider_cancel_booking_v37(uuid,text) from public, anon;
grant execute on function public.yt_provider_cancel_booking_v37(uuid,text) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- E. SI CLIENTE CANCELA LA RESERVA DONDE USO EL BONO, EL BONO SE PIERDE.
--    SI OFRECER CANCELA, SE RESTAURA. Este trigger refuerza ambos casos incluso
--    si algun flujo legacy cambia el bono antes de cambiar el status.
-- --------------------------------------------------------------------------
create or replace function public.yt_v39_sync_cancel_bonus_after_booking_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_bonus_type text;
begin
  if new.status <> 'cancelled'
     or old.status = 'cancelled'
     or old.applied_bonus_id is null then
    return new;
  end if;

  select bonus_type into v_bonus_type
  from public.customer_bonuses
  where id = old.applied_bonus_id;

  if coalesce(v_bonus_type,'') <> 'provider_cancel_7' then
    return new;
  end if;

  if v_actor = old.buyer_id then
    -- Cancelacion normal del cliente: el credito ya usado queda consumido.
    update public.customer_bonuses
    set status = 'used',
        used_amount = greatest(coalesce(old.bonus_discount_amount,0), least(amount,7)),
        used_booking_id = new.id,
        used_at = coalesce(used_at, now()),
        updated_at = now(),
        metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
          'forfeited_by_client_cancellation', true,
          'forfeited_booking_id', new.id,
          'forfeited_at', now()
        )
    where id = old.applied_bonus_id;
  elsif v_actor = old.provider_id then
    -- Cancelacion de Ofrecer: el cliente conserva el credito.
    update public.customer_bonuses
    set status = 'available',
        used_amount = 0,
        used_booking_id = null,
        used_at = null,
        updated_at = now(),
        metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
          'restored_by_provider_cancellation', true,
          'restored_booking_id', new.id,
          'restored_at', now()
        )
    where id = old.applied_bonus_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_v39_sync_cancel_bonus_after_booking_cancel on public.bookings;
create trigger trg_v39_sync_cancel_bonus_after_booking_cancel
after update of status on public.bookings
for each row execute function public.yt_v39_sync_cancel_bonus_after_booking_cancel();

-- --------------------------------------------------------------------------
-- F. CODIGO DE CIERRE: REAFIRMAR REGLA FINAL
-- --------------------------------------------------------------------------
create or replace function public.generate_booking_confirmation_code()
returns trigger
language plpgsql
as $$
begin
  if new.payment_status = 'paid'
     and coalesce(new.buyer_confirmed,false) = true
     and new.status in ('accepted','completed_pending_release')
     and coalesce(new.confirmation_code,'') = '' then
    new.confirmation_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
    new.confirmation_code_created_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_generate_booking_confirmation_code on public.bookings;
drop trigger if exists trg_bookings_confirmation_code on public.bookings;
create trigger trg_generate_booking_confirmation_code
before insert or update of payment_status, buyer_confirmed, status, confirmation_code on public.bookings
for each row execute function public.generate_booking_confirmation_code();

-- Limpiar cualquier codigo prematuro legacy que no haya iniciado cierre.
update public.bookings
set confirmation_code = null,
    confirmation_code_created_at = null,
    updated_at = now()
where confirmation_code_verified_at is null
  and coalesce(buyer_confirmed,false) = false
  and status in ('pending','pending_payment','paid_pending_acceptance','accepted');

commit;


-- ==========================================================================
-- V40 · ADMIN EMPRESAS 360
-- ===========================================================================
-- ==========================================================================
-- WISSA V40 - ADMIN EMPRESAS 360
-- Fecha: 2026-08-17
-- Mejora /dashboard/empresas con resumen, ficha 360, personal, servicios,
-- reservas, finanzas, plan/suscripcion, alertas y edicion administrativa.
-- ===========================================================================

begin;

create index if not exists idx_company_members_company_status_role
  on public.company_members (company_id, status, internal_role);

create index if not exists idx_services_company_active_category
  on public.services (company_id, is_active, category);

create index if not exists idx_bookings_company_created_status
  on public.bookings (company_id, created_at desc, status);

create index if not exists idx_company_plan_orders_company_status_created
  on public.company_plan_orders (company_id, status, created_at desc);

create index if not exists idx_company_payments_company_status_created
  on public.company_payments (company_id, status, created_at desc);

create index if not exists idx_company_invoices_company_status_created
  on public.company_invoices (company_id, status, created_at desc);

create index if not exists idx_company_subscription_events_company_sent
  on public.company_subscription_events (company_id, sent_at desc);

-- --------------------------------------------------------------------------
-- LISTADO + KPI EN UNA SOLA LLAMADA
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_companies_overview_v40(
  p_search text default '',
  p_status text default 'all',
  p_limit integer default 250
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_search text := lower(trim(coalesce(p_search, '')));
  v_status text := lower(trim(coalesce(p_status, 'all')));
  v_limit integer := greatest(1, least(coalesce(p_limit, 250), 500));
  v_result jsonb;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'Acceso administrativo requerido.';
  end if;

  with member_stats as (
    select company_id,
           count(*)::bigint as members_count,
           count(*) filter (where status = 'active')::bigint as active_members_count
    from public.company_members
    group by company_id
  ), service_stats as (
    select company_id,
           count(*)::bigint as services_count,
           count(*) filter (where is_active = true)::bigint as active_services_count
    from public.services
    where company_id is not null
    group by company_id
  ), booking_stats as (
    select company_id,
           count(*)::bigint as bookings_count,
           count(*) filter (where status in ('completed','completed_pending_release'))::bigint as completed_bookings_count,
           coalesce(sum(total_amount),0)::numeric as booked_total
    from public.bookings
    where company_id is not null
    group by company_id
  ), plan_stats as (
    select company_id,
           coalesce(sum(amount) filter (where status in ('approved','paid')),0)::numeric as plan_paid_total
    from public.company_plan_orders
    group by company_id
  ), base as (
    select
      c.id,
      c.name,
      c.legal_name,
      c.ruc,
      c.email,
      c.phone,
      c.contact_name,
      c.contact_email,
      c.contact_phone,
      c.city,
      c.status,
      c.verification_status,
      c.plan_name,
      c.subscription_status,
      c.subscription_expires_at,
      c.plan_expires_at,
      case
        when coalesce(c.subscription_expires_at, c.plan_expires_at) is null then null
        else floor(extract(epoch from (coalesce(c.subscription_expires_at, c.plan_expires_at) - now())) / 86400)::integer
      end as days_remaining,
      coalesce(ms.members_count,0) as members_count,
      coalesce(ms.active_members_count,0) as active_members_count,
      coalesce(ss.services_count,0) as services_count,
      coalesce(ss.active_services_count,0) as active_services_count,
      coalesce(bs.bookings_count,0) as bookings_count,
      coalesce(bs.completed_bookings_count,0) as completed_bookings_count,
      coalesce(bs.booked_total,0) as booked_total,
      coalesce(ps.plan_paid_total,0) as plan_paid_total,
      c.created_at
    from public.companies c
    left join member_stats ms on ms.company_id = c.id
    left join service_stats ss on ss.company_id = c.id
    left join booking_stats bs on bs.company_id = c.id
    left join plan_stats ps on ps.company_id = c.id
  ), filtered as (
    select *
    from base b
    where (
      v_search = ''
      or lower(coalesce(b.name,'')) like '%' || v_search || '%'
      or lower(coalesce(b.legal_name,'')) like '%' || v_search || '%'
      or lower(coalesce(b.ruc,'')) like '%' || v_search || '%'
      or lower(coalesce(b.email,'')) like '%' || v_search || '%'
      or lower(coalesce(b.phone,'')) like '%' || v_search || '%'
      or lower(coalesce(b.contact_name,'')) like '%' || v_search || '%'
      or lower(coalesce(b.contact_email,'')) like '%' || v_search || '%'
      or lower(coalesce(b.contact_phone,'')) like '%' || v_search || '%'
    )
    and (
      v_status = 'all'
      or (v_status in ('active','pending','suspended','rejected') and b.status = v_status)
      or (v_status = 'expiring' and b.subscription_status = 'active' and b.days_remaining between 0 and 7)
      or (v_status = 'expired' and (b.subscription_status = 'expired' or b.days_remaining < 0))
      or (v_status = 'pending_payment' and b.subscription_status = 'pending_payment')
    )
    order by b.created_at desc
    limit v_limit
  ), global_summary as (
    select jsonb_build_object(
      'total', count(*),
      'active', count(*) filter (where c.status = 'active'),
      'pending', count(*) filter (where c.status = 'pending'),
      'suspended', count(*) filter (where c.status = 'suspended'),
      'expiring_7d', count(*) filter (
        where c.subscription_status = 'active'
          and coalesce(c.subscription_expires_at,c.plan_expires_at) >= now()
          and coalesce(c.subscription_expires_at,c.plan_expires_at) < now() + interval '8 days'
      ),
      'expired', count(*) filter (
        where c.subscription_status = 'expired'
           or (coalesce(c.subscription_expires_at,c.plan_expires_at) is not null and coalesce(c.subscription_expires_at,c.plan_expires_at) < now())
      ),
      'active_subscriptions', count(*) filter (where c.subscription_status = 'active'),
      'plan_revenue', coalesce((select sum(po.amount) from public.company_plan_orders po where po.status in ('approved','paid')),0),
      'booked_total', coalesce((select sum(b.total_amount) from public.bookings b where b.company_id is not null),0)
    ) as payload
    from public.companies c
  )
  select jsonb_build_object(
    'summary', (select payload from global_summary),
    'companies', coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at desc) from filtered f), '[]'::jsonb)
  ) into v_result;

  return coalesce(v_result, jsonb_build_object('summary','{}'::jsonb,'companies','[]'::jsonb));
end;
$$;

-- --------------------------------------------------------------------------
-- FICHA 360 DE UNA EMPRESA
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_company_detail_v40(p_company_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company public.companies%rowtype;
  v_days integer;
  v_members jsonb;
  v_services jsonb;
  v_bookings jsonb;
  v_plan_orders jsonb;
  v_payments jsonb;
  v_invoices jsonb;
  v_events jsonb;
  v_alerts jsonb;
  v_stats jsonb;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'Acceso administrativo requerido.';
  end if;

  select * into v_company from public.companies where id = p_company_id;
  if v_company.id is null then raise exception 'Empresa no encontrada.'; end if;

  v_days := case
    when coalesce(v_company.subscription_expires_at, v_company.plan_expires_at) is null then null
    else floor(extract(epoch from (coalesce(v_company.subscription_expires_at, v_company.plan_expires_at) - now())) / 86400)::integer
  end;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', cm.id,
    'full_name', cm.full_name,
    'email', cm.email,
    'phone', cm.phone,
    'position', cm.position,
    'department', cm.department,
    'role', cm.role,
    'internal_role', cm.internal_role,
    'status', cm.status,
    'can_create_bookings', cm.can_create_bookings,
    'can_approve_bookings', cm.can_approve_bookings,
    'can_view_finance', cm.can_view_finance,
    'can_manage_staff', cm.can_manage_staff,
    'last_login_at', cm.last_login_at,
    'created_at', cm.created_at
  ) order by (cm.status = 'active') desc, cm.full_name nulls last), '[]'::jsonb)
  into v_members
  from public.company_members cm where cm.company_id = p_company_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id,
    'title', s.title,
    'description', s.description,
    'category', s.category,
    'price', s.price,
    'duration_minutes', s.duration_minutes,
    'is_active', s.is_active,
    'source_type', s.source_type,
    'member_name', cm.full_name,
    'member_email', cm.email,
    'provider_name', p.full_name,
    'provider_email', p.email,
    'bookings_count', (select count(*) from public.bookings b where b.service_id = s.id),
    'created_at', s.created_at
  ) order by s.is_active desc, s.created_at desc), '[]'::jsonb)
  into v_services
  from public.services s
  left join public.company_members cm on cm.id = s.company_member_id
  left join public.profiles p on p.id = s.provider_id
  where s.company_id = p_company_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id,
    'service_title', coalesce(b.service_title, s.title),
    'company_reference', b.company_reference,
    'company_department', b.company_department,
    'booking_date', b.booking_date,
    'booking_time', b.booking_time,
    'total_amount', b.total_amount,
    'payment_status', b.payment_status,
    'status', b.status,
    'company_request_status', b.company_request_status,
    'requested_by_name', coalesce(rp.full_name, 'Empresa'),
    'created_at', b.created_at
  ) order by b.created_at desc), '[]'::jsonb)
  into v_bookings
  from (
    select * from public.bookings where company_id = p_company_id order by created_at desc limit 100
  ) b
  left join public.services s on s.id = b.service_id
  left join public.profiles rp on rp.id = b.company_requested_by;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', po.id,
    'amount', po.amount,
    'currency', po.currency,
    'provider', po.provider,
    'payment_method', po.payment_method,
    'status', po.status,
    'yappy_transaction_id', po.yappy_transaction_id,
    'pf_transaction_id', po.pf_transaction_id,
    'public_checkout_token', po.public_checkout_token,
    'paid_at', po.paid_at,
    'created_at', po.created_at
  ) order by po.created_at desc), '[]'::jsonb)
  into v_plan_orders
  from public.company_plan_orders po where po.company_id = p_company_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', cp.id,
    'concept', case when cp.company_booking_id is null then 'Pago de empresa' else 'Pago de reserva empresarial' end,
    'amount', cp.amount,
    'currency', cp.currency,
    'status', cp.status,
    'method', cp.method,
    'provider', cp.provider,
    'external_reference', cp.external_reference,
    'transaction_id', cp.transaction_id,
    'invoice_number', cp.invoice_number,
    'paid_at', cp.paid_at,
    'created_at', cp.created_at
  ) order by cp.created_at desc), '[]'::jsonb)
  into v_payments
  from public.company_payments cp where cp.company_id = p_company_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', ci.id,
    'invoice_number', ci.invoice_number,
    'period_start', ci.period_start,
    'period_end', ci.period_end,
    'subtotal', ci.subtotal,
    'tax_amount', ci.tax_amount,
    'total_amount', ci.total_amount,
    'status', ci.status,
    'issued_at', ci.issued_at,
    'due_at', ci.due_at,
    'paid_at', ci.paid_at,
    'created_at', ci.created_at
  ) order by ci.created_at desc), '[]'::jsonb)
  into v_invoices
  from public.company_invoices ci where ci.company_id = p_company_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', se.id,
    'event_type', se.event_type,
    'title', se.title,
    'body', se.body,
    'sent_at', se.sent_at
  ) order by se.sent_at desc), '[]'::jsonb)
  into v_events
  from (
    select * from public.company_subscription_events where company_id = p_company_id order by sent_at desc limit 50
  ) se;

  select jsonb_build_object(
    'members', (select count(*) from public.company_members cm where cm.company_id = p_company_id),
    'active_members', (select count(*) from public.company_members cm where cm.company_id = p_company_id and cm.status = 'active'),
    'services', (select count(*) from public.services s where s.company_id = p_company_id),
    'active_services', (select count(*) from public.services s where s.company_id = p_company_id and s.is_active = true),
    'bookings', (select count(*) from public.bookings b where b.company_id = p_company_id),
    'completed_bookings', (select count(*) from public.bookings b where b.company_id = p_company_id and b.status in ('completed','completed_pending_release')),
    'booked_total', coalesce((select sum(b.total_amount) from public.bookings b where b.company_id = p_company_id),0),
    'company_payments_total', coalesce((select sum(cp.amount) from public.company_payments cp where cp.company_id = p_company_id and cp.status = 'paid'),0),
    'plan_paid_total', coalesce((select sum(po.amount) from public.company_plan_orders po where po.company_id = p_company_id and po.status in ('approved','paid')),0),
    'invoiced_total', coalesce((select sum(ci.total_amount) from public.company_invoices ci where ci.company_id = p_company_id and ci.status <> 'cancelled'),0)
  ) into v_stats;

  with alert_rows as (
    select 'warning'::text tone, 'Empresa pendiente'::text title, 'La cuenta todavía está pendiente de activación administrativa.'::text body where v_company.status = 'pending'
    union all select 'danger', 'Empresa suspendida', coalesce(nullif(v_company.suspended_reason,''), 'La empresa está suspendida y no debería operar normalmente.') where v_company.status = 'suspended'
    union all select 'warning', 'Verificación pendiente', 'Revisa los datos comerciales y fiscales antes de verificar la empresa.' where v_company.verification_status = 'pending'
    union all select 'danger', 'Verificación rechazada', 'La verificación de la empresa fue rechazada y requiere seguimiento.' where v_company.verification_status = 'rejected'
    union all select 'danger', 'Plan vencido', 'La suscripción empresarial está vencida.' where v_company.subscription_status = 'expired' or coalesce(v_days,0) < 0
    union all select 'warning', 'Plan próximo a vencer', format('La suscripción vence en %s día(s).', v_days) where v_company.subscription_status = 'active' and v_days between 0 and 7
    union all select 'warning', 'Pago de plan pendiente', 'La suscripción está marcada como pendiente de pago.' where v_company.subscription_status = 'pending_payment'
    union all select 'warning', 'Sin administrador activo', 'La empresa no tiene un Admin Empresa activo.' where not exists (select 1 from public.company_members cm where cm.company_id = p_company_id and cm.status = 'active' and coalesce(cm.internal_role,'') = 'company_admin')
    union all select 'warning', 'Sin servicios activos', 'La empresa no tiene servicios activos para operar.' where not exists (select 1 from public.services s where s.company_id = p_company_id and s.is_active = true)
  )
  select coalesce(jsonb_agg(jsonb_build_object('tone',tone,'title',title,'body',body)), '[]'::jsonb) into v_alerts from alert_rows;

  return jsonb_build_object(
    'company', to_jsonb(v_company) || jsonb_build_object('days_remaining', v_days),
    'members', v_members,
    'services', v_services,
    'bookings', v_bookings,
    'plan_orders', v_plan_orders,
    'payments', v_payments,
    'invoices', v_invoices,
    'subscription_events', v_events,
    'alerts', v_alerts,
    'stats', v_stats
  );
end;
$$;

-- --------------------------------------------------------------------------
-- EDICION DE DATOS COMERCIALES DESDE ADMIN
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_company_update_v40(
  p_company_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company public.companies%rowtype;
  v_name text;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'Acceso administrativo requerido.';
  end if;
  select * into v_company from public.companies where id = p_company_id;
  if v_company.id is null then raise exception 'Empresa no encontrada.'; end if;

  v_name := case when p_payload ? 'name' then nullif(trim(p_payload->>'name'),'') else v_company.name end;
  if v_name is null then raise exception 'El nombre comercial es obligatorio.'; end if;

  if p_payload ? 'billing_mode' and (p_payload->>'billing_mode') not in ('per_booking','monthly_invoice','credit','manual') then
    raise exception 'Modo de facturacion no valido.';
  end if;
  if p_payload ? 'billing_cycle' and (p_payload->>'billing_cycle') not in ('none','weekly','biweekly','monthly') then
    raise exception 'Ciclo de facturacion no valido.';
  end if;

  update public.companies c set
    name = v_name,
    legal_name = case when p_payload ? 'legal_name' then nullif(trim(p_payload->>'legal_name'),'') else c.legal_name end,
    ruc = case when p_payload ? 'ruc' then nullif(trim(p_payload->>'ruc'),'') else c.ruc end,
    tax_id = case when p_payload ? 'ruc' then nullif(trim(p_payload->>'ruc'),'') else c.tax_id end,
    business_type = case when p_payload ? 'business_type' then nullif(trim(p_payload->>'business_type'),'') else c.business_type end,
    email = case when p_payload ? 'email' then nullif(trim(p_payload->>'email'),'') else c.email end,
    phone = case when p_payload ? 'phone' then nullif(trim(p_payload->>'phone'),'') else c.phone end,
    website = case when p_payload ? 'website' then nullif(trim(p_payload->>'website'),'') else c.website end,
    city = case when p_payload ? 'city' then coalesce(nullif(trim(p_payload->>'city'),''),'Panamá') else c.city end,
    address = case when p_payload ? 'address' then nullif(trim(p_payload->>'address'),'') else c.address end,
    contact_name = case when p_payload ? 'contact_name' then nullif(trim(p_payload->>'contact_name'),'') else c.contact_name end,
    contact_email = case when p_payload ? 'contact_email' then nullif(trim(p_payload->>'contact_email'),'') else c.contact_email end,
    contact_phone = case when p_payload ? 'contact_phone' then nullif(trim(p_payload->>'contact_phone'),'') else c.contact_phone end,
    billing_email = case when p_payload ? 'billing_email' then nullif(trim(p_payload->>'billing_email'),'') else c.billing_email end,
    billing_phone = case when p_payload ? 'billing_phone' then nullif(trim(p_payload->>'billing_phone'),'') else c.billing_phone end,
    billing_address = case when p_payload ? 'billing_address' then nullif(trim(p_payload->>'billing_address'),'') else c.billing_address end,
    billing_mode = case when p_payload ? 'billing_mode' then p_payload->>'billing_mode' else c.billing_mode end,
    billing_cycle = case when p_payload ? 'billing_cycle' then p_payload->>'billing_cycle' else c.billing_cycle end,
    payment_terms_days = case when p_payload ? 'payment_terms_days' then greatest(0,least(365,(p_payload->>'payment_terms_days')::integer)) else c.payment_terms_days end,
    requires_approval = case when p_payload ? 'requires_approval' then (p_payload->>'requires_approval')::boolean else c.requires_approval end,
    auto_approve_bookings = case when p_payload ? 'auto_approve_bookings' then (p_payload->>'auto_approve_bookings')::boolean else c.auto_approve_bookings end,
    updated_by = auth.uid(),
    updated_at = now()
  where c.id = p_company_id;

  return jsonb_build_object('ok',true,'company_id',p_company_id,'updated_at',now());
end;
$$;

-- --------------------------------------------------------------------------
-- ACCIONES ADMINISTRATIVAS DE ESTADO / PLAN
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_company_action_v40(
  p_company_id uuid,
  p_action text,
  p_note text default null,
  p_days integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action text := lower(trim(coalesce(p_action,'')));
  v_note text := nullif(trim(coalesce(p_note,'')),'');
  v_days integer := greatest(1,least(coalesce(p_days,30),365));
  v_title text;
  v_body text;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'Acceso administrativo requerido.';
  end if;
  if not exists (select 1 from public.companies where id = p_company_id) then raise exception 'Empresa no encontrada.'; end if;

  if v_action = 'activate' then
    update public.companies set status='active', rejected_reason=null, suspended_reason=null, updated_by=auth.uid(), updated_at=now() where id=p_company_id;
    v_title := 'Empresa activada'; v_body := coalesce(v_note,'La empresa fue activada por Administración Wissa.');
  elsif v_action = 'suspend' then
    update public.companies set status='suspended', suspended_reason=coalesce(v_note,'Revisión administrativa'), updated_by=auth.uid(), updated_at=now() where id=p_company_id;
    v_title := 'Empresa suspendida'; v_body := coalesce(v_note,'La empresa fue suspendida por Administración Wissa.');
  elsif v_action = 'reactivate' then
    update public.companies set status='active', suspended_reason=null, updated_by=auth.uid(), updated_at=now() where id=p_company_id;
    v_title := 'Empresa reactivada'; v_body := coalesce(v_note,'La empresa fue reactivada por Administración Wissa.');
  elsif v_action = 'verify' then
    update public.companies set verification_status='verified', approved_by=auth.uid(), approved_at=coalesce(approved_at,now()), rejected_reason=null, updated_by=auth.uid(), updated_at=now() where id=p_company_id;
    v_title := 'Empresa verificada'; v_body := coalesce(v_note,'Administración Wissa verificó la empresa.');
  elsif v_action = 'extend' then
    update public.companies set
      status = case when status='suspended' then status else 'active' end,
      plan_status='active',
      subscription_status='active',
      subscription_started_at=coalesce(subscription_started_at,now()),
      subscription_expires_at=greatest(coalesce(subscription_expires_at,now()),now()) + make_interval(days => v_days),
      plan_expires_at=greatest(coalesce(plan_expires_at,subscription_expires_at,now()),now()) + make_interval(days => v_days),
      subscription_auto_blocked=false,
      subscription_grace_until=null,
      updated_by=auth.uid(),
      updated_at=now()
    where id=p_company_id;
    v_title := format('Plan extendido %s días',v_days); v_body := coalesce(v_note,format('Administración Wissa extendió el plan por %s días.',v_days));
  else
    raise exception 'Accion administrativa no valida: %', v_action;
  end if;

  insert into public.company_subscription_events(company_id,event_type,title,body,sent_to,sent_at,metadata)
  values (p_company_id,'admin_'||v_action,v_title,v_body,auth.uid(),now(),jsonb_build_object('source','admin_web_v40','days',case when v_action='extend' then v_days else null end));

  return jsonb_build_object('ok',true,'company_id',p_company_id,'action',v_action,'title',v_title,'body',v_body);
end;
$$;

revoke execute on function public.yt_admin_companies_overview_v40(text,text,integer) from public;
revoke execute on function public.yt_admin_company_detail_v40(uuid) from public;
revoke execute on function public.yt_admin_company_update_v40(uuid,jsonb) from public;
revoke execute on function public.yt_admin_company_action_v40(uuid,text,text,integer) from public;

grant execute on function public.yt_admin_companies_overview_v40(text,text,integer) to authenticated, service_role;
grant execute on function public.yt_admin_company_detail_v40(uuid) to authenticated, service_role;
grant execute on function public.yt_admin_company_update_v40(uuid,jsonb) to authenticated, service_role;
grant execute on function public.yt_admin_company_action_v40(uuid,text,text,integer) to authenticated, service_role;

notify pgrst, 'reload schema';
commit;


-- ============================================================================
-- WISSA V41 - EMPRESAS: MATERIALES E INSUMOS / SIN KIT WISSA
-- ============================================================================
-- ============================================================================
-- WISSA V41 - EMPRESAS SIN KIT WISSA / MATERIALES E INSUMOS
-- Fecha: 2026-08-17
--
-- REGLA FINAL:
--   * Marketplace / cliente particular: conserva Kit Wissa cuando aplique.
--   * Empresa: Wissa NO vende ni entrega kits.
--   * Limpieza / Limpieza exteriores: materiales e insumos los aporta la empresa.
--   * Plomería: herramientas normales del técnico; repuestos/materiales especiales
--     se cotizan por separado después del diagnóstico.
--   * Toda reserva empresarial fuerza kit_amount = 0 y wissa_kit_revenue = 0.
-- ============================================================================

begin;

-- 1) Sanitiza cualquier configuración de precios empresarial para que nunca
--    herede kits del fallback global ni permita guardarlos por error.
create or replace function public.yt_company_strip_wissa_kits_v41(p_key text, p_value jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_key text := lower(trim(coalesce(p_key, '')));
  v_value jsonb;
  v_policy jsonb;
begin
  if v_key not in ('cleaning_pricing', 'exterior_cleaning_pricing', 'plumbing_pricing') then
    raise exception 'Configuracion no permitida: %', p_key;
  end if;

  v_value := public.yt_normalize_service_pricing_value(v_key, coalesce(p_value, '{}'::jsonb));

  if v_key in ('cleaning_pricing', 'exterior_cleaning_pricing') then
    v_value := jsonb_set(v_value, '{cleaning_kit_enabled}', 'false'::jsonb, true);
    v_value := jsonb_set(v_value, '{cleaning_kit_price}', '0'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,enabled}', 'false'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,basic,price}', '0'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,premium,price}', '0'::jsonb, true);
    v_policy := jsonb_build_object(
      'mode', 'company_provided',
      'label', 'Materiales e insumos proporcionados por la empresa',
      'wissa_kit_enabled', false,
      'description', 'La empresa contratante proporciona los materiales e insumos necesarios. Wissa no entrega kits en servicios empresariales.'
    );
  else
    v_value := jsonb_set(v_value, '{kits,enabled}', 'false'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,basic,price}', '0'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,premium,price}', '0'::jsonb, true);
    v_policy := jsonb_build_object(
      'mode', 'special_materials_quote',
      'label', 'Repuestos y materiales especiales bajo cotizacion',
      'wissa_kit_enabled', false,
      'description', 'Las herramientas normales del tecnico forman parte del servicio. Repuestos y materiales especiales se cotizan y aprueban por separado.'
    );
  end if;

  return v_value || jsonb_build_object(
    'company_materials_policy', v_policy,
    'company_wissa_kit_enabled', false
  );
end;
$$;

revoke execute on function public.yt_company_strip_wissa_kits_v41(text, jsonb) from public, anon;
grant execute on function public.yt_company_strip_wissa_kits_v41(text, jsonb) to authenticated, service_role;

-- 2) Toda lectura efectiva de tarifas empresariales elimina el Kit Wissa,
--    incluso si la empresa usa como fallback la tarifa global del marketplace.
create or replace function public.yt_effective_company_service_pricing_value(p_company_id uuid, p_key text)
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_key text := lower(trim(coalesce(p_key, '')));
  v_value jsonb;
begin
  if v_key not in ('cleaning_pricing', 'exterior_cleaning_pricing', 'plumbing_pricing') then
    raise exception 'Configuracion no permitida: %', p_key;
  end if;

  select cps.value into v_value
  from public.company_service_pricing_settings cps
  where cps.company_id = p_company_id
    and cps.pricing_key = v_key;

  if v_value is null then
    select a.value into v_value
    from public.app_settings a
    where a.key = v_key;
  end if;

  return public.yt_company_strip_wissa_kits_v41(v_key, coalesce(v_value, '{}'::jsonb));
end;
$$;

-- 3) Guardar precios desde Portal Empresa/Admin Empresa también fuerza sin kit.
create or replace function public.yt_company_update_service_pricing(p_company_id uuid, p_key text, p_value jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_key text := lower(trim(coalesce(p_key, '')));
  v_normalized jsonb;
  v_updated_at timestamptz := now();
  v_synced_services integer := 0;
begin
  if v_user_id is null then raise exception 'Debes iniciar sesion.'; end if;
  if not (public.yt_admin_is_current_admin() or public.yt_is_company_admin(p_company_id, v_user_id)) then
    raise exception 'No autorizado para cambiar las tarifas de esta empresa.';
  end if;
  if v_key not in ('cleaning_pricing', 'exterior_cleaning_pricing', 'plumbing_pricing') then
    raise exception 'Configuracion no permitida: %', p_key;
  end if;
  if not exists (select 1 from public.companies where id = p_company_id) then
    raise exception 'Empresa no encontrada.';
  end if;

  v_normalized := public.yt_company_strip_wissa_kits_v41(v_key, p_value);

  insert into public.company_service_pricing_settings (company_id, pricing_key, value, updated_by, updated_at)
  values (p_company_id, v_key, v_normalized, v_user_id, v_updated_at)
  on conflict (company_id, pricing_key) do update
    set value = excluded.value,
        updated_by = excluded.updated_by,
        updated_at = excluded.updated_at;

  update public.services s
  set price = public.yt_base_service_price(s.category, v_normalized),
      updated_at = v_updated_at
  where s.company_id = p_company_id
    and public.yt_category_matches_pricing_key(s.category, v_key)
    and public.yt_base_service_price(s.category, v_normalized) > 0;
  get diagnostics v_synced_services = row_count;

  return jsonb_build_object(
    'ok', true,
    'key', v_key,
    'value', v_normalized,
    'updated_at', v_updated_at,
    'synced_services', v_synced_services,
    'company_wissa_kit_enabled', false,
    'materials_policy', v_normalized->'company_materials_policy'
  );
end;
$$;

revoke execute on function public.yt_company_update_service_pricing(uuid, text, jsonb) from public, anon;
grant execute on function public.yt_company_update_service_pricing(uuid, text, jsonb) to authenticated, service_role;

-- Normaliza los overrides ya guardados. No toca app_settings: el marketplace
-- particular conserva sus kits normalmente.
update public.company_service_pricing_settings cps
set value = public.yt_company_strip_wissa_kits_v41(cps.pricing_key, cps.value),
    updated_at = now()
where cps.pricing_key in ('cleaning_pricing', 'exterior_cleaning_pricing', 'plumbing_pricing');

-- 4) Guardia dura sobre reservas empresariales. Si cualquier cliente antiguo,
--    pantalla o integración intenta enviar un kit, se elimina antes de guardar.
create or replace function public.yt_company_booking_no_wissa_kit_v41()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_kit numeric := 0;
  v_is_company boolean := false;
  v_category text := '';
  v_policy text;
  v_company_provides boolean := true;
begin
  v_is_company := coalesce(new.is_company_booking, false)
    or new.company_id is not null
    or new.company_booking_id is not null;

  if not v_is_company then
    return new;
  end if;

  v_kit := greatest(
    coalesce(
      nullif(new.kit_amount, 0),
      public.yt_safe_numeric(coalesce(new.service_details, '{}'::jsonb)->>'kit_amount', 0, 0, 1000000),
      0
    ),
    0
  );

  v_category := lower(coalesce(new.service_details->>'category', new.service_title, ''));
  if v_category like '%plomer%' then
    v_company_provides := false;
    v_policy := 'Herramientas normales incluidas; repuestos y materiales especiales se cotizan y aprueban por separado.';
  else
    v_policy := 'La empresa contratante proporciona los materiales e insumos necesarios. Wissa no incluye ni entrega kits empresariales.';
  end if;

  -- Si un cliente antiguo sumó el kit al monto antes de enviar la reserva,
  -- retiramos exactamente ese componente para que la empresa no lo pague.
  if v_kit > 0 then
    if coalesce(new.subtotal_amount, 0) > 0 then
      new.subtotal_amount := round(greatest(new.subtotal_amount - v_kit, 0), 2);
    end if;
    if coalesce(new.total_amount, 0) > 0 then
      new.total_amount := round(greatest(new.total_amount - v_kit, 0), 2);
    end if;
  end if;

  new.kit_amount := 0;
  new.wissa_kit_revenue := 0;
  new.wissa_total_revenue := round(greatest(coalesce(new.platform_fee, 0), 0), 2);
  new.service_details := (coalesce(new.service_details, '{}'::jsonb) - 'cleaning_kit' - 'kit' - 'kit_option')
    || jsonb_build_object(
      'kit_amount', 0,
      'wissa_kit_included', false,
      'company_materials_policy', true,
      'materials_and_supplies_provided_by_company', v_company_provides,
      'materials_policy', v_policy
    );

  return new;
end;
$$;

drop trigger if exists zzzz_company_booking_no_wissa_kit_v41 on public.bookings;
create trigger zzzz_company_booking_no_wissa_kit_v41
before insert or update on public.bookings
for each row execute function public.yt_company_booking_no_wissa_kit_v41();

-- Capa adicional: aunque otro trigger cambie los valores, una reserva nueva o
-- modificada de empresa no puede persistir ingresos de Kit Wissa.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'bookings_company_no_wissa_kit_v41_chk'
      and conrelid = 'public.bookings'::regclass
  ) then
    alter table public.bookings
      add constraint bookings_company_no_wissa_kit_v41_chk
      check (
        not (coalesce(is_company_booking, false) or company_id is not null or company_booking_id is not null)
        or (coalesce(kit_amount, 0) = 0 and coalesce(wissa_kit_revenue, 0) = 0)
      ) not valid;
  end if;
end $$;

comment on function public.yt_company_booking_no_wissa_kit_v41() is
  'V41: fuerza Kit Wissa = 0 en reservas empresariales y registra la politica de materiales e insumos.';

notify pgrst, 'reload schema';

commit;

-- ==========================================================================
-- WISSA V42 - MODOS DE TRABAJO SEPARADOS: OFRECER PERSONAL / PERSONAL EMPRESA
-- Fecha: 2026-08-17
--
-- FINALIDAD:
--  * La misma cuenta puede tener contexto Ofrecer personal y Personal Empresa.
--  * Servicios, reservas, chats, disponibilidad y dinero se mantienen separados.
--  * Wissa liquida reservas empresariales a la empresa, no al trabajador.
--  * El incentivo +USD 50 de Ofrecer NO aplica a reservas empresariales.
-- ===========================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. DISPONIBILIDAD EMPRESARIAL INDEPENDIENTE DEL PERFIL PERSONAL
-- --------------------------------------------------------------------------
alter table public.company_members
  add column if not exists is_available boolean not null default true;

create or replace function public.yt_get_my_company_availability_v42()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select cm.is_available
    from public.company_members cm
    where cm.user_id = auth.uid()
      and coalesce(cm.status, 'active') = 'active'
      and coalesce(cm.internal_role,
        case when cm.role in ('admin_empresa','supervisor','finanzas') then 'company_admin' else 'company_staff' end
      ) = 'company_staff'
    order by cm.updated_at desc nulls last, cm.created_at desc
    limit 1
  ), false);
$$;

create or replace function public.yt_set_my_company_availability_v42(p_is_available boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
begin
  update public.company_members cm
  set is_available = coalesce(p_is_available, false),
      updated_at = now()
  where cm.user_id = auth.uid()
    and coalesce(cm.status, 'active') = 'active'
    and coalesce(cm.internal_role,
      case when cm.role in ('admin_empresa','supervisor','finanzas') then 'company_admin' else 'company_staff' end
    ) = 'company_staff';

  get diagnostics v_count = row_count;
  if v_count = 0 then
    raise exception 'No tienes un acceso activo como Personal Empresa.';
  end if;

  return jsonb_build_object('ok', true, 'is_available', coalesce(p_is_available, false), 'updated_memberships', v_count);
end;
$$;

revoke execute on function public.yt_get_my_company_availability_v42() from public, anon;
revoke execute on function public.yt_set_my_company_availability_v42(boolean) from public, anon;
grant execute on function public.yt_get_my_company_availability_v42() to authenticated, service_role;
grant execute on function public.yt_set_my_company_availability_v42(boolean) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- COMPATIBILIDAD V42.1
-- PostgreSQL no permite que CREATE OR REPLACE VIEW elimine columnas que ya
-- existen en una vista. Re-creamos solamente las vistas de trabajo afectadas.
-- v_provider_earnings_summary depende de v_provider_earnings, por eso se
-- elimina primero y se reconstruye al final.
-- --------------------------------------------------------------------------
drop view if exists public.v_provider_earnings_summary;
drop view if exists public.v_provider_payouts;
drop view if exists public.v_provider_earnings;
drop view if exists public.v_company_staff_bookings;
drop view if exists public.v_company_staff_services;
drop view if exists public.v_client_marketplace_services;

-- Marketplace: la disponibilidad de un servicio empresarial viene del miembro
-- de empresa. La de un Ofrecer independiente sigue viniendo de profiles.
create view public.v_client_marketplace_services as
select
  s.id,
  s.id as service_id,
  s.provider_id,
  s.company_id,
  s.company_member_id,
  s.source_type,
  case
    when s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null
      then 'company_service'
    else 'independent_service'
  end as marketplace_type,
  case
    when s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null
      then 'Personal empresa'
    else 'Independiente'
  end as provider_kind,
  s.title,
  s.description,
  s.category,
  s.price,
  s.duration_minutes,
  s.is_active,
  s.is_featured,
  s.featured_order,
  s.featured_until,
  coalesce(
    nullif(s.offer_location_address, ''),
    case
      when s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null then 'A domicilio'
    end,
    p.location_label,
    c.address,
    c.city,
    p.city
  ) as location_label,
  coalesce(s.offer_latitude, p.latitude, p.lat) as latitude,
  coalesce(s.offer_longitude, p.longitude, p.lng) as longitude,
  p.full_name as staff_name,
  p.avatar_url as staff_avatar_url,
  coalesce(p.rating_avg, 0) as rating_avg,
  coalesce(p.is_verified, false) as staff_verified,
  case
    when s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null
      then coalesce(cm.is_available, true)
    else coalesce(p.is_available, true)
  end as staff_available,
  p.city as staff_city,
  c.name as company_name,
  c.logo_url as company_logo_url,
  c.status as company_status,
  c.subscription_status,
  c.plan_status,
  cm.full_name as company_member_name,
  cm.email as company_member_email,
  cm.status as company_member_status,
  s.created_at,
  s.updated_at
from public.services s
left join public.profiles p on p.id = s.provider_id
left join public.companies c on c.id = s.company_id
left join public.company_members cm on cm.id = s.company_member_id
where s.is_active = true
  and coalesce(p.status, 'active') <> 'suspended'
  and coalesce(p.is_suspended, false) = false
  and (
    (
      coalesce(s.source_type, 'normal') <> 'company_service'
      and s.company_id is null
      and s.company_member_id is null
      and coalesce(p.provider_status, 'approved') = 'approved'
    )
    or
    (
      (s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null)
      and s.provider_id is not null
      and coalesce(cm.status, 'active') = 'active'
      and coalesce(c.subscription_status, c.plan_status, 'active') = 'active'
    )
  );

grant select on public.v_client_marketplace_services to anon, authenticated, service_role;

-- --------------------------------------------------------------------------
-- 2. VISTAS DE PERSONAL EMPRESA: SOLO TRABAJO ASIGNADO A LA CUENTA ACTUAL
-- --------------------------------------------------------------------------
create view public.v_company_staff_services
with (security_invoker = true) as
select
  s.id,
  s.provider_id as staff_user_id,
  s.company_id,
  c.name as company_name,
  s.company_member_id,
  cm.full_name as staff_name,
  cm.email as staff_email,
  s.title,
  s.description,
  s.category,
  s.price,
  s.duration_minutes,
  s.is_active,
  s.created_at,
  s.updated_at
from public.services s
join public.companies c on c.id = s.company_id
left join public.company_members cm on cm.id = s.company_member_id
where coalesce(s.source_type, '') = 'company_service'
  and s.provider_id = auth.uid()
  and coalesce(cm.status, 'active') = 'active';

grant select on public.v_company_staff_services to authenticated, service_role;

create view public.v_company_staff_bookings
with (security_invoker = true) as
select
  b.id,
  b.provider_id as staff_user_id,
  coalesce(b.company_id, s.company_id) as company_id,
  c.name as company_name,
  b.service_id,
  coalesce(b.service_title, s.title, 'Servicio empresa') as service_title,
  buyer.full_name as client_name,
  b.booking_date,
  b.booking_time,
  b.status,
  b.payment_status,
  b.payout_release_status,
  b.company_request_status,
  b.company_approval_status,
  coalesce(b.total_amount, b.price_snapshot, 0) as total_amount,
  coalesce(b.platform_fee, 0) as platform_fee,
  greatest(coalesce(b.total_amount, b.price_snapshot, 0) - coalesce(b.platform_fee, 0), 0) as company_net,
  b.created_at,
  b.updated_at
from public.bookings b
join public.services s on s.id = b.service_id and coalesce(s.source_type, '') = 'company_service'
left join public.companies c on c.id = coalesce(b.company_id, s.company_id)
left join public.profiles buyer on buyer.id = b.buyer_id
where b.provider_id = auth.uid();

grant select on public.v_company_staff_bookings to authenticated, service_role;

-- --------------------------------------------------------------------------
-- 3. FINANZAS DE OFRECER PERSONAL: EXCLUIR RESERVAS EMPRESARIALES
-- --------------------------------------------------------------------------
create view public.v_provider_earnings
with (security_invoker = true) as
select
  b.id as booking_id,
  b.provider_id,
  coalesce(b.service_title, s.title, 'Servicio') as service_title,
  b.status as booking_status,
  b.payment_status,
  b.payout_release_status,
  b.finance_status,
  public.yt_booking_public_status(b.status, b.payment_status, b.payout_release_status, b.finance_status) as booking_status_label,
  coalesce(nullif(b.total_amount, 0), nullif(b.price_snapshot, 0), 0) as total_amount,
  coalesce(nullif(b.platform_fee, 0), round(coalesce(nullif(b.total_amount, 0), nullif(b.price_snapshot, 0), 0) * 0.07, 2), 0) as platform_fee,
  coalesce(nullif(b.seller_payout, 0), round(coalesce(nullif(b.total_amount, 0), nullif(b.price_snapshot, 0), 0) * 0.93, 2), 0) as provider_net,
  b.paid_at,
  b.completed_at,
  b.payout_released_at,
  b.provider_paid_out_at,
  b.booking_date,
  b.booking_time,
  b.created_at,
  pp.id as payout_id,
  pp.amount as payout_amount,
  pp.status as payout_status,
  pp.method as payout_method,
  pp.reference as payout_reference,
  pp.paid_at as payout_paid_at
from public.bookings b
left join public.services s on s.id = b.service_id
left join lateral (
  select p.*
  from public.provider_payouts p
  where p.booking_id = b.id
    and p.provider_id = b.provider_id
  order by p.paid_at desc nulls last, p.created_at desc nulls last
  limit 1
) pp on true
where b.provider_id = auth.uid()
  and b.payment_status = 'paid'
  and coalesce(b.is_company_booking, false) = false
  and b.company_id is null
  and coalesce(s.source_type, 'marketplace') <> 'company_service';

create view public.v_provider_payouts
with (security_invoker = true) as
select
  pp.id,
  pp.provider_id,
  pp.booking_id,
  coalesce(b.service_title, s.title, 'Servicio') as service_title,
  pp.amount,
  pp.status,
  case
    when pp.status = 'paid' then 'Liquidado'
    when pp.status = 'pending' then 'Pendiente'
    when pp.status = 'failed' then 'Fallido'
    when pp.status = 'cancelled' then 'Cancelado'
    else initcap(replace(coalesce(nullif(pp.status, ''), 'sin_estado'), '_', ' '))
  end as status_label,
  pp.method,
  pp.reference,
  pp.notes,
  pp.paid_at,
  pp.created_at,
  pp.updated_at,
  b.booking_date,
  b.booking_time,
  b.payout_release_status,
  b.finance_status,
  b.payout_released_at
from public.provider_payouts pp
left join public.bookings b on b.id = pp.booking_id
left join public.services s on s.id = b.service_id
where pp.provider_id = auth.uid()
  and coalesce(b.is_company_booking, false) = false
  and b.company_id is null
  and coalesce(s.source_type, 'marketplace') <> 'company_service';

create view public.v_provider_earnings_summary
with (security_invoker = true) as
select
  auth.uid() as provider_id,
  coalesce(sum(provider_net) filter (
    where coalesce(payout_release_status, 'not_released') <> 'released'
      and booking_status in ('completed','completed_pending_release')
  ), 0) as disponible_liquidar,
  coalesce(sum(provider_net) filter (
    where coalesce(payout_release_status, 'not_released') <> 'released'
      and booking_status not in ('completed','completed_pending_release')
  ), 0) as pendiente_validacion,
  coalesce(sum(provider_net) filter (
    where coalesce(payout_release_status, 'not_released') = 'released'
  ), 0) as pagado_acumulado,
  count(distinct booking_id) filter (
    where payment_status = 'paid'
  ) as servicios_aprobados,
  count(distinct booking_id) filter (
    where coalesce(payout_release_status, 'not_released') = 'released'
  ) as liquidaciones_registradas
from public.v_provider_earnings;

grant select on public.v_provider_earnings, public.v_provider_earnings_summary, public.v_provider_payouts to authenticated;

-- --------------------------------------------------------------------------
-- 4. BONO +USD 50: SOLO OFRECER INDEPENDIENTE, NUNCA PERSONAL EMPRESA
-- --------------------------------------------------------------------------
create or replace function public.yt_v38_grant_provider_completion_bonus()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_campaign public.promotion_campaigns%rowtype;
  v_category text := '';
  v_is_cleaning boolean := false;
  v_is_offerer boolean := false;
  v_bonus_id uuid;
  v_base_payout numeric := 0;
  v_count integer := 0;
begin
  if new.provider_id is null
     or coalesce(new.payment_status,'') <> 'paid'
     or new.status not in ('completed_pending_release','completed') then
    return new;
  end if;

  -- Regla V42: una reserva de empresa nunca consume uno de los 10 incentivos
  -- de Ofrecer independiente, aunque la misma persona tenga ambos contextos.
  if coalesce(new.is_company_booking, false)
     or new.company_id is not null
     or new.company_member_id is not null
     or exists (
       select 1 from public.services sx
       where sx.id = new.service_id
         and (coalesce(sx.source_type,'') = 'company_service' or sx.company_id is not null or sx.company_member_id is not null)
     ) then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.status in ('completed_pending_release','completed') then
    return new;
  end if;

  select * into v_campaign
  from public.promotion_campaigns c
  where c.code = 'launch_first10_offerers_50'
    and c.is_active = true
    and (c.starts_at is null or c.starts_at <= now())
    and (c.ends_at is null or c.ends_at >= now())
  limit 1;

  if not found then return new; end if;
  if v_campaign.starts_at is not null and new.created_at < v_campaign.starts_at then return new; end if;

  select coalesce(s.category, new.service_details->>'category', '')
  into v_category
  from public.services s
  where s.id = new.service_id;

  if coalesce(v_category,'') = '' then
    v_category := coalesce(new.service_details->>'category','');
  end if;

  v_is_cleaning := lower(v_category) like '%limpieza%' or lower(v_category) like '%clean%';
  if not v_is_cleaning then return new; end if;

  select exists (
    select 1 from public.profiles p
    where p.id = new.provider_id
      and (
        lower(coalesce(p.role,'')) in ('provider','vendor','ofrecer','both','ambos')
        or lower(coalesce(p.mode_preference,'')) = 'provider'
        or coalesce(p.provider_enabled,false) = true
      )
  ) into v_is_offerer;

  if not v_is_offerer then return new; end if;

  perform pg_advisory_xact_lock(hashtext('wissa:launch_first10_offerers_50')::bigint);

  if exists (
    select 1 from public.provider_completion_bonuses b
    where b.campaign_id = v_campaign.id
      and b.provider_id = new.provider_id
      and b.status <> 'cancelled'
  ) then return new; end if;

  select count(*) into v_count
  from public.provider_completion_bonuses b
  where b.campaign_id = v_campaign.id and b.status <> 'cancelled';

  if v_count >= v_campaign.max_redemptions then return new; end if;

  insert into public.provider_completion_bonuses (
    campaign_id, provider_id, source_booking_id, amount, status, metadata
  ) values (
    v_campaign.id, new.provider_id, new.id, v_campaign.benefit_value, 'earned',
    jsonb_build_object(
      'service_category', v_category,
      'booking_completed_at', coalesce(new.completed_at, now()),
      'funded_by', 'wissa',
      'rule', 'first_completed_cleaning_booking_per_independent_offerer',
      'mode', 'provider'
    )
  ) returning id into v_bonus_id;

  v_base_payout := greatest(coalesce(
    nullif(new.seller_payout,0),
    nullif(new.gross_total_amount,0) - coalesce(new.platform_fee,0),
    nullif(new.price_snapshot,0) - coalesce(new.platform_fee,0),
    0
  ), 0);

  update public.bookings
  set provider_bonus_amount = v_campaign.benefit_value,
      provider_bonus_id = v_bonus_id,
      seller_payout = round(v_base_payout + v_campaign.benefit_value, 2),
      service_details = jsonb_set(
        coalesce(service_details,'{}'::jsonb),
        '{provider_bonus}',
        jsonb_build_object(
          'code', v_campaign.code,
          'label', 'Bono Ofrecer · USD 50',
          'amount', v_campaign.benefit_value,
          'funded_by', 'wissa',
          'earned', true,
          'bonus_id', v_bonus_id,
          'mode', 'provider'
        ), true
      ),
      updated_at = now()
  where id = new.id;

  insert into public.notifications (
    user_id, title, body, type, screen, related_booking_id, metadata, is_read, created_at
  )
  select
    new.provider_id,
    'Ganaste un bono de USD 50',
    'Completaste una reserva elegible de limpieza como Ofrecer independiente y estás entre los primeros 10. Wissa agregó USD 50 a la liquidación de esta reserva.',
    'provider_launch_bonus_50',
    '/(provider-tabs)/earnings',
    new.id,
    jsonb_build_object('booking_id', new.id, 'bonus_id', v_bonus_id, 'amount', v_campaign.benefit_value, 'campaign', v_campaign.code, 'mode', 'provider'),
    false,
    now()
  where not exists (
    select 1 from public.notifications n
    where n.user_id = new.provider_id
      and n.related_booking_id = new.id
      and n.type = 'provider_launch_bonus_50'
  );

  if to_regprocedure('public.yt_recalculate_provider_balance(uuid)') is not null then
    perform public.yt_recalculate_provider_balance(new.provider_id);
  end if;

  return new;
end;
$$;

-- Índices para los dos contextos.
create index if not exists idx_bookings_provider_personal_v42
  on public.bookings (provider_id, created_at desc)
  where company_id is null and coalesce(is_company_booking, false) = false;

create index if not exists idx_company_members_user_active_available_v42
  on public.company_members (user_id, status, is_available);

notify pgrst, 'reload schema';

commit;

-- FIN WISSA V42
