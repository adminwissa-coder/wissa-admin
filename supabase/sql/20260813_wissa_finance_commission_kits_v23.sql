-- ============================================================================
-- WISSA v23 - FINANZAS ADMIN: COMISION 12% + KITS WISSA
-- Fecha: 2026-08-13
--
-- Regla contable:
--   - Comisión Wissa = 12% SOLO del servicio profesional.
--   - Kit Wissa = 100% ingreso Wissa.
--   - Traslado = 100% para quien ofrece; NO forma parte del ingreso Wissa.
--   - Retirable en "Retiro de ingresos Wissa" = comisión + kits - retiros.
--   - Planes empresariales siguen separados; no entran en este retiro.
--
-- Requiere Wissa v22 aplicado (bookings.service_subtotal, kit_amount,
-- travel_fee, wissa_kit_revenue, wissa_total_revenue).
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1) Finanzas: una sola fuente de verdad por reserva pagada.
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_wissa_finance_json(
  p_search text default '',
  p_status text default 'all',
  p_limit integer default 500,
  p_date_from date default null,
  p_date_to date default null
)
returns table (
  id uuid,
  booking_id uuid,
  service_title text,
  buyer_name text,
  provider_name text,
  gateway text,
  method text,
  status text,
  status_label text,
  release_status text,
  amount numeric,
  service_subtotal numeric,
  travel_fee numeric,
  platform_fee numeric,
  kit_amount numeric,
  wissa_total_revenue numeric,
  provider_net numeric,
  reference text,
  created_at timestamptz,
  paid_at timestamptz
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_search text := lower(trim(coalesce(p_search, '')));
  v_status text := lower(trim(coalesce(p_status, 'all')));
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  return query
  select
    b.id,
    b.id,
    coalesce(nullif(b.service_title, ''), nullif(s.title, ''), 'Servicio Wissa')::text,
    coalesce(nullif(buyer.display_name, ''), nullif(buyer.full_name, ''), nullif(buyer.email, ''), 'Cliente')::text,
    coalesce(nullif(provider.display_name, ''), nullif(provider.full_name, ''), nullif(provider.email, ''), 'Proveedor')::text,
    coalesce(nullif(b.payment_provider, ''), 'Wissa')::text,
    coalesce(nullif(b.payment_method, ''), 'No indicado')::text,
    'approved'::text,
    'Pagado'::text,
    coalesce(nullif(b.payout_release_status, ''), 'not_released')::text,
    round(greatest(coalesce(b.total_amount, b.subtotal_amount, b.price_snapshot, 0), 0), 2),
    round(greatest(coalesce(
      nullif(b.service_subtotal, 0),
      greatest(coalesce(b.total_amount, 0) - coalesce(b.kit_amount, 0) - coalesce(b.travel_fee, 0), 0),
      0
    ), 0), 2),
    round(greatest(coalesce(b.travel_fee, 0), 0), 2),
    round(greatest(coalesce(b.platform_fee, 0), 0), 2),
    round(greatest(coalesce(nullif(b.wissa_kit_revenue, 0), b.kit_amount, 0), 0), 2),
    round(
      greatest(coalesce(b.platform_fee, 0), 0)
      + greatest(coalesce(nullif(b.wissa_kit_revenue, 0), b.kit_amount, 0), 0),
      2
    ),
    round(greatest(coalesce(b.seller_payout, 0), 0), 2),
    coalesce(
      nullif(b.yappy_transaction_id, ''),
      nullif(b.yappy_order_id, ''),
      nullif(b.reservation_code, ''),
      b.id::text
    )::text,
    coalesce(b.paid_at, b.created_at),
    b.paid_at
  from public.bookings b
  left join public.services s on s.id = b.service_id
  left join public.profiles buyer on buyer.id = b.buyer_id
  left join public.profiles provider on provider.id = b.provider_id
  where b.payment_status = 'paid'
    and coalesce(b.status, '') not in ('rejected', 'cancelled')
    and coalesce(b.refund_status, 'not_requested') <> 'refunded'
    and (
      v_status = 'all'
      or v_status = 'approved'
      or (v_status = 'released' and coalesce(b.payout_release_status, 'not_released') = 'released')
      or (v_status = 'not_released' and coalesce(b.payout_release_status, 'not_released') <> 'released')
    )
    and (
      p_date_from is null
      or (coalesce(b.paid_at, b.created_at) at time zone 'America/Panama')::date >= p_date_from
    )
    and (
      p_date_to is null
      or (coalesce(b.paid_at, b.created_at) at time zone 'America/Panama')::date <= p_date_to
    )
    and (
      v_search = ''
      or lower(concat_ws(' ',
        b.id::text,
        b.reservation_code,
        b.service_title,
        s.title,
        buyer.display_name,
        buyer.full_name,
        buyer.email,
        provider.display_name,
        provider.full_name,
        provider.email,
        b.payment_provider,
        b.payment_method,
        b.yappy_transaction_id,
        b.yappy_order_id
      )) like '%' || v_search || '%'
    )
  order by coalesce(b.paid_at, b.created_at) desc
  limit greatest(1, least(coalesce(p_limit, 500), 2000));
end;
$$;

revoke execute on function public.yt_admin_wissa_finance_json(text,text,integer,date,date) from public, anon;
grant execute on function public.yt_admin_wissa_finance_json(text,text,integer,date,date) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- 2) Retiro Wissa: movimientos de comisión + kit y saldo combinado.
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_wissa_marketplace_revenue_json(
  p_search text default '',
  p_status text default 'all',
  p_limit integer default 500,
  p_date_from date default null,
  p_date_to date default null
)
returns table (
  id text,
  source text,
  service_title text,
  buyer_name text,
  provider_name text,
  status text,
  amount numeric,
  commission_amount numeric,
  kit_amount numeric,
  method text,
  reference text,
  created_at timestamptz
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_search text := lower(trim(coalesce(p_search, '')));
  v_status text := lower(trim(coalesce(p_status, 'all')));
  v_total_commission numeric := 0;
  v_total_kits numeric := 0;
  v_total_withdrawn numeric := 0;
  v_available numeric := 0;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  select
    coalesce(sum(greatest(coalesce(b.platform_fee, 0), 0)), 0),
    coalesce(sum(greatest(coalesce(nullif(b.wissa_kit_revenue, 0), b.kit_amount, 0), 0)), 0)
  into v_total_commission, v_total_kits
  from public.bookings b
  where b.payment_status = 'paid'
    and coalesce(b.status, '') not in ('rejected', 'cancelled')
    and coalesce(b.refund_status, 'not_requested') <> 'refunded';

  select coalesce(sum(greatest(coalesce(w.amount, 0), 0)), 0)
  into v_total_withdrawn
  from public.platform_commission_withdrawals w
  where coalesce(w.status, 'collected') in ('collected', 'paid', 'approved');

  v_available := round(greatest(v_total_commission + v_total_kits - v_total_withdrawn, 0), 2);

  -- Ingresos por reserva: amount = comisión + kit.
  if v_status in ('all', 'earned', 'platform_commission_earned') then
    return query
    select
      ('earned:' || b.id::text)::text,
      'platform_commission_earned'::text,
      coalesce(nullif(b.service_title, ''), nullif(s.title, ''), 'Servicio Wissa')::text,
      coalesce(nullif(buyer.display_name, ''), nullif(buyer.full_name, ''), nullif(buyer.email, ''), 'Cliente')::text,
      coalesce(nullif(provider.display_name, ''), nullif(provider.full_name, ''), nullif(provider.email, ''), 'Proveedor')::text,
      'earned'::text,
      round(
        greatest(coalesce(b.platform_fee, 0), 0)
        + greatest(coalesce(nullif(b.wissa_kit_revenue, 0), b.kit_amount, 0), 0),
        2
      ),
      round(greatest(coalesce(b.platform_fee, 0), 0), 2),
      round(greatest(coalesce(nullif(b.wissa_kit_revenue, 0), b.kit_amount, 0), 0), 2),
      coalesce(nullif(b.payment_method, ''), nullif(b.payment_provider, ''), 'Pago Wissa')::text,
      coalesce(nullif(b.reservation_code, ''), nullif(b.yappy_transaction_id, ''), b.id::text)::text,
      coalesce(b.paid_at, b.created_at)
    from public.bookings b
    left join public.services s on s.id = b.service_id
    left join public.profiles buyer on buyer.id = b.buyer_id
    left join public.profiles provider on provider.id = b.provider_id
    where b.payment_status = 'paid'
      and coalesce(b.status, '') not in ('rejected', 'cancelled')
      and coalesce(b.refund_status, 'not_requested') <> 'refunded'
      and (
        p_date_from is null
        or (coalesce(b.paid_at, b.created_at) at time zone 'America/Panama')::date >= p_date_from
      )
      and (
        p_date_to is null
        or (coalesce(b.paid_at, b.created_at) at time zone 'America/Panama')::date <= p_date_to
      )
      and (
        v_search = ''
        or lower(concat_ws(' ',
          b.id::text,
          b.reservation_code,
          b.service_title,
          s.title,
          buyer.display_name,
          buyer.full_name,
          buyer.email,
          provider.display_name,
          provider.full_name,
          provider.email
        )) like '%' || v_search || '%'
      )
    order by coalesce(b.paid_at, b.created_at) desc
    limit greatest(1, least(coalesce(p_limit, 500), 2000));
  end if;

  -- Retiros registrados del fondo combinado.
  if v_status in ('all', 'collected', 'platform_commission_withdrawal') then
    return query
    select
      ('withdrawal:' || w.id::text)::text,
      'platform_commission_withdrawal'::text,
      'Retiro de ingresos Wissa'::text,
      'Wissa'::text,
      coalesce(nullif(adminp.display_name, ''), nullif(adminp.full_name, ''), nullif(adminp.email, ''), 'Administrador')::text,
      'collected'::text,
      round(greatest(coalesce(w.amount, 0), 0), 2),
      0::numeric,
      0::numeric,
      coalesce(nullif(w.method, ''), 'manual_admin')::text,
      coalesce(nullif(w.reference, ''), nullif(w.note, ''), w.id::text)::text,
      coalesce(w.collected_at, w.created_at)
    from public.platform_commission_withdrawals w
    left join public.profiles adminp on adminp.id = coalesce(w.collected_by, w.admin_id)
    where coalesce(w.status, 'collected') in ('collected', 'paid', 'approved')
      and (
        p_date_from is null
        or (coalesce(w.collected_at, w.created_at) at time zone 'America/Panama')::date >= p_date_from
      )
      and (
        p_date_to is null
        or (coalesce(w.collected_at, w.created_at) at time zone 'America/Panama')::date <= p_date_to
      )
      and (
        v_search = ''
        or lower(concat_ws(' ',
          w.id::text,
          w.reference,
          w.note,
          w.notes,
          w.method,
          adminp.display_name,
          adminp.full_name,
          adminp.email
        )) like '%' || v_search || '%'
      )
    order by coalesce(w.collected_at, w.created_at) desc
    limit greatest(1, least(coalesce(p_limit, 500), 2000));
  end if;

  -- Una única fila operativa para ejecutar el retiro del saldo combinado.
  if v_status in ('all', 'pending', 'platform_commission_pending')
     and (
       v_search = ''
       or 'saldo disponible wissa comisión comision kits kit retiro' like '%' || v_search || '%'
     ) then
    return query
    select
      'pending:wissa-marketplace'::text,
      'platform_commission_pending'::text,
      'Saldo disponible · comisión + kits'::text,
      'Wissa'::text,
      'Disponible para retiro'::text,
      'pending'::text,
      v_available,
      round(v_total_commission, 2),
      round(v_total_kits, 2),
      'manual_admin'::text,
      'Saldo global'::text,
      now();
  end if;
end;
$$;

revoke execute on function public.yt_admin_wissa_marketplace_revenue_json(text,text,integer,date,date) from public, anon;
grant execute on function public.yt_admin_wissa_marketplace_revenue_json(text,text,integer,date,date) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- 3) Retiro del fondo combinado comisión + kits.
--    Mantiene la tabla existente platform_commission_withdrawals para no romper
--    reportes anteriores, pero el source_type identifica la nueva regla.
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_withdraw_wissa_marketplace_revenue(
  p_amount numeric,
  p_note text default null,
  p_method text default 'manual_admin',
  p_period_start date default null,
  p_period_end date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_commission numeric := 0;
  v_kits numeric := 0;
  v_earned numeric := 0;
  v_withdrawn numeric := 0;
  v_available numeric := 0;
  v_amount numeric := round(greatest(coalesce(p_amount, 0), 0), 2);
  v_id uuid;
  v_reference text;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  if v_amount <= 0 then
    raise exception 'El monto debe ser mayor que cero';
  end if;

  select
    coalesce(sum(greatest(coalesce(b.platform_fee, 0), 0)), 0),
    coalesce(sum(greatest(coalesce(nullif(b.wissa_kit_revenue, 0), b.kit_amount, 0), 0)), 0)
  into v_commission, v_kits
  from public.bookings b
  where b.payment_status = 'paid'
    and coalesce(b.status, '') not in ('rejected', 'cancelled')
    and coalesce(b.refund_status, 'not_requested') <> 'refunded';

  v_earned := round(v_commission + v_kits, 2);

  select coalesce(sum(greatest(coalesce(w.amount, 0), 0)), 0)
  into v_withdrawn
  from public.platform_commission_withdrawals w
  where coalesce(w.status, 'collected') in ('collected', 'paid', 'approved');

  v_available := round(greatest(v_earned - v_withdrawn, 0), 2);

  if v_amount > v_available then
    raise exception 'Monto mayor al saldo disponible de Wissa. Disponible: USD %', to_char(v_available, 'FM999999990.00');
  end if;

  v_reference := 'WISSA-' || to_char(clock_timestamp() at time zone 'America/Panama', 'YYYYMMDD-HH24MISS');

  insert into public.platform_commission_withdrawals (
    amount,
    method,
    reference,
    note,
    admin_id,
    currency,
    status,
    period_start,
    period_end,
    notes,
    collected_by,
    collected_at,
    updated_at,
    metadata,
    source_type
  ) values (
    v_amount,
    coalesce(nullif(trim(p_method), ''), 'manual_admin'),
    v_reference,
    nullif(trim(coalesce(p_note, '')), ''),
    auth.uid(),
    'USD',
    'collected',
    p_period_start,
    p_period_end,
    nullif(trim(coalesce(p_note, '')), ''),
    auth.uid(),
    now(),
    now(),
    jsonb_build_object(
      'rule_version', 23,
      'fund', 'wissa_marketplace_revenue',
      'includes', jsonb_build_array('commission_12_percent', 'kits_100_percent'),
      'commission_generated_before', round(v_commission, 2),
      'kits_generated_before', round(v_kits, 2),
      'earned_before', v_earned,
      'withdrawn_before', round(v_withdrawn, 2),
      'available_before', v_available
    ),
    'wissa_marketplace_revenue'
  )
  returning id into v_id;

  return jsonb_build_object(
    'ok', true,
    'id', v_id,
    'reference', v_reference,
    'amount', v_amount,
    'commission_generated', round(v_commission, 2),
    'kit_generated', round(v_kits, 2),
    'available_before', v_available,
    'available_after', round(v_available - v_amount, 2)
  );
end;
$$;

revoke execute on function public.yt_admin_withdraw_wissa_marketplace_revenue(numeric,text,text,date,date) from public, anon;
grant execute on function public.yt_admin_withdraw_wissa_marketplace_revenue(numeric,text,text,date,date) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- 4) Dashboard: resumen coherente con el fondo retirable.
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_wissa_revenue_summary()
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_commission numeric := 0;
  v_kits numeric := 0;
  v_plans numeric := 0;
  v_withdrawn numeric := 0;
  v_marketplace numeric := 0;
  v_withdrawable numeric := 0;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  select
    coalesce(sum(greatest(coalesce(b.platform_fee, 0), 0)), 0),
    coalesce(sum(greatest(coalesce(nullif(b.wissa_kit_revenue, 0), b.kit_amount, 0), 0)), 0)
  into v_commission, v_kits
  from public.bookings b
  where b.payment_status = 'paid'
    and coalesce(b.status, '') not in ('rejected', 'cancelled')
    and coalesce(b.refund_status, 'not_requested') <> 'refunded';

  select coalesce(sum(greatest(coalesce(w.amount, 0), 0)), 0)
  into v_withdrawn
  from public.platform_commission_withdrawals w
  where coalesce(w.status, 'collected') in ('collected', 'paid', 'approved');

  select coalesce(sum(greatest(coalesce(o.amount, 0), 0)), 0)
  into v_plans
  from public.company_plan_orders o
  where o.status in ('approved', 'paid');

  v_marketplace := round(v_commission + v_kits, 2);
  v_withdrawable := round(greatest(v_marketplace - v_withdrawn, 0), 2);

  return jsonb_build_object(
    'commission_revenue', round(v_commission, 2),
    'kit_revenue', round(v_kits, 2),
    'marketplace_revenue', v_marketplace,
    'marketplace_withdrawn', round(v_withdrawn, 2),
    'marketplace_withdrawable', v_withdrawable,
    'company_plan_revenue', round(v_plans, 2),
    'total_revenue', round(v_marketplace + v_plans, 2)
  );
end;
$$;

revoke execute on function public.yt_admin_wissa_revenue_summary() from public, anon;
grant execute on function public.yt_admin_wissa_revenue_summary() to authenticated, service_role;

commit;

-- --------------------------------------------------------------------------
-- VALIDACIÓN RÁPIDA
-- Debe cumplirse:
-- ingreso_marketplace = comisión_12 + kits
-- disponible_retiro   = ingreso_marketplace - retiros
-- --------------------------------------------------------------------------
select
  round(coalesce(sum(platform_fee), 0), 2) as comision_12_generada,
  round(coalesce(sum(coalesce(nullif(wissa_kit_revenue, 0), kit_amount, 0)), 0), 2) as kits_generados,
  round(coalesce(sum(platform_fee + coalesce(nullif(wissa_kit_revenue, 0), kit_amount, 0)), 0), 2) as ingreso_wissa_marketplace
from public.bookings
where payment_status = 'paid'
  and coalesce(status, '') not in ('rejected', 'cancelled')
  and coalesce(refund_status, 'not_requested') <> 'refunded';

select
  round(coalesce(sum(amount), 0), 2) as retirado_wissa_marketplace
from public.platform_commission_withdrawals
where coalesce(status, 'collected') in ('collected', 'paid', 'approved');
