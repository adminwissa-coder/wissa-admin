-- ============================================================================
-- WISSA v24 - RETIROS / LIQUIDACIONES DE OFRECER
-- Fecha: 2026-08-13
--
-- Corrige el desfase entre:
--   - app proveedor: servicio completado y esperando liquidación
--   - admin: "Retiros de ofrecer" vacío hasta que ya existía un payout/request
--
-- Desde ahora el RPC también devuelve como movimiento pendiente todo booking:
--   payment_status = paid
--   status in (completed_pending_release, completed)
--   payout_release_status != released
--
-- Esos registros aparecen con source = provider_pending y el admin puede
-- liquidarlos usando el RPC ya existente yt_admin_release_booking_payment.
-- ============================================================================

begin;

create or replace function public.yt_admin_withdrawals_json(
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
  party_name text,
  status text,
  amount numeric,
  method text,
  reference text,
  created_at timestamptz,
  booking_id uuid,
  provider_id uuid,
  payment_status text,
  payout_release_status text
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_search text := lower(trim(coalesce(p_search, '')));
  v_status text := lower(trim(coalesce(p_status, 'all')));
  v_limit integer := greatest(1, least(coalesce(p_limit, 500), 2000));
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  -- 1) Servicios ya pagados/completados que Wissa todavía debe liquidar.
  if v_status in ('all', 'provider_pending', 'pending', 'completed_pending_release', 'completed', 'not_released') then
    return query
    select
      b.id::text,
      'provider_pending'::text,
      coalesce(nullif(b.service_title, ''), nullif(s.title, ''), 'Servicio Wissa')::text,
      coalesce(nullif(p.display_name, ''), nullif(p.full_name, ''), nullif(p.email, ''), 'Proveedor')::text,
      b.status::text,
      round(greatest(coalesce(
        nullif(b.seller_payout, 0),
        greatest(coalesce(b.total_amount, b.subtotal_amount, b.price_snapshot, 0)
          - coalesce(b.platform_fee, 0)
          - coalesce(b.kit_amount, 0), 0),
        0
      ), 0), 2),
      'Wissa'::text,
      coalesce(nullif(b.reservation_code, ''), b.id::text)::text,
      coalesce(b.completed_at, b.updated_at, b.created_at),
      b.id,
      b.provider_id,
      b.payment_status::text,
      coalesce(nullif(b.payout_release_status, ''), 'not_released')::text
    from public.bookings b
    left join public.services s on s.id = b.service_id
    left join public.profiles p on p.id = b.provider_id
    where b.payment_status = 'paid'
      and b.status in ('completed_pending_release', 'completed')
      and coalesce(b.payout_release_status, 'not_released') <> 'released'
      and coalesce(b.refund_status, 'not_requested') <> 'refunded'
      and (
        v_status in ('all', 'provider_pending', 'pending', 'not_released')
        or lower(b.status) = v_status
      )
      and (
        p_date_from is null
        or (coalesce(b.completed_at, b.updated_at, b.created_at) at time zone 'America/Panama')::date >= p_date_from
      )
      and (
        p_date_to is null
        or (coalesce(b.completed_at, b.updated_at, b.created_at) at time zone 'America/Panama')::date <= p_date_to
      )
      and (
        v_search = ''
        or lower(concat_ws(' ',
          b.id::text,
          b.reservation_code,
          b.service_title,
          s.title,
          p.display_name,
          p.full_name,
          p.email
        )) like '%' || v_search || '%'
      )
    order by coalesce(b.completed_at, b.updated_at, b.created_at) desc
    limit v_limit;
  end if;

  -- 2) Liquidaciones ya registradas al proveedor.
  if v_status in ('all', 'provider_payout', 'paid', 'pending', 'cancelled') then
    return query
    select
      pp.id::text,
      'provider_payout'::text,
      coalesce(nullif(b.service_title, ''), nullif(s.title, ''), 'Liquidación de servicio')::text,
      coalesce(nullif(p.display_name, ''), nullif(p.full_name, ''), nullif(p.email, ''), 'Proveedor')::text,
      pp.status::text,
      round(greatest(coalesce(pp.amount, 0), 0), 2),
      coalesce(nullif(pp.method, ''), 'manual')::text,
      coalesce(nullif(pp.reference, ''), pp.id::text)::text,
      coalesce(pp.paid_at, pp.created_at),
      pp.booking_id,
      pp.provider_id,
      coalesce(b.payment_status, 'paid')::text,
      coalesce(b.payout_release_status, case when pp.status = 'paid' then 'released' else 'not_released' end)::text
    from public.provider_payouts pp
    left join public.bookings b on b.id = pp.booking_id
    left join public.services s on s.id = b.service_id
    left join public.profiles p on p.id = pp.provider_id
    where (v_status in ('all', 'provider_payout') or lower(pp.status) = v_status)
      and (
        p_date_from is null
        or (coalesce(pp.paid_at, pp.created_at) at time zone 'America/Panama')::date >= p_date_from
      )
      and (
        p_date_to is null
        or (coalesce(pp.paid_at, pp.created_at) at time zone 'America/Panama')::date <= p_date_to
      )
      and (
        v_search = ''
        or lower(concat_ws(' ',
          pp.id::text,
          pp.reference,
          pp.method,
          b.reservation_code,
          b.service_title,
          s.title,
          p.display_name,
          p.full_name,
          p.email
        )) like '%' || v_search || '%'
      )
    order by coalesce(pp.paid_at, pp.created_at) desc
    limit v_limit;
  end if;

  -- 3) Solicitudes históricas de payout, si el flujo anterior las utilizó.
  if v_status in ('all', 'payout_request', 'pending', 'paid', 'cancelled') then
    return query
    select
      pr.id::text,
      'payout_request'::text,
      'Solicitud de retiro'::text,
      coalesce(nullif(p.display_name, ''), nullif(p.full_name, ''), nullif(p.email, ''), 'Proveedor')::text,
      pr.status::text,
      round(greatest(coalesce(pr.amount, 0), 0), 2),
      'Solicitud proveedor'::text,
      pr.id::text,
      pr.created_at,
      null::uuid,
      pr.provider_id,
      null::text,
      null::text
    from public.payout_requests pr
    left join public.profiles p on p.id = pr.provider_id
    where (v_status in ('all', 'payout_request') or lower(pr.status) = v_status)
      and (p_date_from is null or (pr.created_at at time zone 'America/Panama')::date >= p_date_from)
      and (p_date_to is null or (pr.created_at at time zone 'America/Panama')::date <= p_date_to)
      and (
        v_search = ''
        or lower(concat_ws(' ', pr.id::text, p.display_name, p.full_name, p.email)) like '%' || v_search || '%'
      )
    order by pr.created_at desc
    limit v_limit;
  end if;

  -- 4) Solicitudes genéricas de retiro del flujo legado.
  if v_status in ('all', 'withdrawal_request', 'pending', 'paid', 'cancelled') then
    return query
    select
      wr.id::text,
      'withdrawal_request'::text,
      'Solicitud de retiro'::text,
      coalesce(nullif(p.display_name, ''), nullif(p.full_name, ''), nullif(p.email, ''), 'Proveedor')::text,
      coalesce(wr.status, 'pending')::text,
      round(greatest(coalesce(wr.amount, 0), 0), 2),
      coalesce(nullif(wr.method, ''), 'Solicitud proveedor')::text,
      coalesce(nullif(wr.note, ''), wr.id::text)::text,
      wr.created_at,
      null::uuid,
      wr.user_id,
      null::text,
      null::text
    from public.withdrawal_requests wr
    left join public.profiles p on p.id = wr.user_id
    where (v_status in ('all', 'withdrawal_request') or lower(coalesce(wr.status, 'pending')) = v_status)
      and (p_date_from is null or (wr.created_at at time zone 'America/Panama')::date >= p_date_from)
      and (p_date_to is null or (wr.created_at at time zone 'America/Panama')::date <= p_date_to)
      and (
        v_search = ''
        or lower(concat_ws(' ', wr.id::text, wr.method, wr.note, p.display_name, p.full_name, p.email)) like '%' || v_search || '%'
      )
    order by wr.created_at desc
    limit v_limit;
  end if;
end;
$$;

revoke execute on function public.yt_admin_withdrawals_json(text,text,integer,date,date) from public, anon;
grant execute on function public.yt_admin_withdrawals_json(text,text,integer,date,date) to authenticated, service_role;

commit;

-- VALIDACIÓN: servicios pagados/completados aún por liquidar.
select
  b.id,
  b.service_title,
  b.status,
  b.payment_status,
  b.payout_release_status,
  b.seller_payout,
  b.completed_at
from public.bookings b
where b.payment_status = 'paid'
  and b.status in ('completed_pending_release', 'completed')
  and coalesce(b.payout_release_status, 'not_released') <> 'released'
order by coalesce(b.completed_at, b.updated_at, b.created_at) desc;
