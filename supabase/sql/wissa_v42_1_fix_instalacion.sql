-- ==========================================================================
-- WISSA V42.1 - FIX DE INSTALACION
-- Corrige ERROR 42P16: cannot drop columns from view
--
-- IMPORTANTE:
-- Si ejecutaste wissa_v42_consolidado.sql y recibiste ese error, las
-- transacciones V36-V41 anteriores ya pudieron quedar confirmadas y la
-- transaccion V42 final fue revertida. Ejecuta ESTE archivo completo.
-- No necesitas volver a ejecutar V36-V41.
-- ==========================================================================

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
