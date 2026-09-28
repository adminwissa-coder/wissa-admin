-- WISSA V66.2 · BLOQUE 2B · FINANZAS / COMISIONES / RETIROS
-- Idempotente. Requiere V66.1 Bloque 2A aplicado.
-- NO borra usuarios ni datos operativos.

begin;

-- ============================================================================
-- 1) FINANZAS DEL PROFESIONAL: equipo real + categorías + pasarela + propinas
-- ============================================================================

drop view if exists public.v_provider_earnings_summary;
drop view if exists public.v_provider_tips;
drop view if exists public.v_provider_payouts;
drop view if exists public.v_provider_earnings;

create view public.v_provider_earnings
with (security_invoker = true) as
with team_rows as (
  select
    b.id as booking_id,
    a.provider_id,
    coalesce(nullif(b.service_title,''), nullif(s.title,''), 'Servicio Wissa')::text as service_title,
    coalesce(nullif(s.category,''), 'Otros')::text as service_category,
    b.status as booking_status,
    b.payment_status,
    case when coalesce(a.payout_status,'pending')='paid' then 'released' else 'not_released' end::text as payout_release_status,
    b.finance_status,
    case
      when coalesce(a.payout_status,'pending') = 'paid' then 'Liquidado'
      when b.status in ('completed','completed_pending_release') then 'Disponible para retirar'
      else 'En proceso'
    end::text as booking_status_label,
    round(greatest(case when coalesce(a.net_provider_amount,0)>0 then a.net_provider_amount else coalesce(a.service_share,0)+coalesce(a.travel_fee,0) end,0),2)::numeric as provider_net,
    round(greatest(coalesce(a.service_share,0),0),2)::numeric as service_share,
    round(greatest(coalesce(a.extras_share,0),0),2)::numeric as extras_share,
    round(greatest(coalesce(a.travel_fee,0),0),2)::numeric as travel_fee,
    round(greatest(coalesce(a.tip_amount,0),0),2)::numeric as tip_amount,
    coalesce(nullif(b.payment_method,''), nullif(b.payment_provider,''), 'No indicado')::text as payment_method,
    coalesce(nullif(b.payment_provider,''), nullif(b.payment_method,''), 'No indicado')::text as payment_provider,
    b.paid_at,
    b.completed_at,
    b.payout_released_at,
    b.provider_paid_out_at,
    b.booking_date,
    b.booking_time,
    b.created_at,
    a.id as assignment_id,
    a.slot_number,
    a.payout_status,
    a.payout_id
  from public.booking_professional_assignments a
  join public.bookings b on b.id = a.booking_id
  left join public.services s on s.id = b.service_id
  where a.provider_id = auth.uid()
    and a.status in ('accepted','completed')
    and b.payment_status = 'paid'
), legacy_rows as (
  select
    b.id as booking_id,
    b.provider_id,
    coalesce(nullif(b.service_title,''), nullif(s.title,''), 'Servicio Wissa')::text as service_title,
    coalesce(nullif(s.category,''), 'Otros')::text as service_category,
    b.status as booking_status,
    b.payment_status,
    b.payout_release_status,
    b.finance_status,
    case
      when b.payout_release_status='released' then 'Liquidado'
      when b.status in ('completed','completed_pending_release') then 'Disponible para retirar'
      else 'En proceso'
    end::text as booking_status_label,
    round(greatest(coalesce(b.seller_payout,0),0),2)::numeric as provider_net,
    round(greatest(coalesce(b.seller_payout,0) - coalesce(b.travel_fee,0),0),2)::numeric as service_share,
    0::numeric as extras_share,
    round(greatest(coalesce(b.travel_fee,0),0),2)::numeric as travel_fee,
    0::numeric as tip_amount,
    coalesce(nullif(b.payment_method,''), nullif(b.payment_provider,''), 'No indicado')::text as payment_method,
    coalesce(nullif(b.payment_provider,''), nullif(b.payment_method,''), 'No indicado')::text as payment_provider,
    b.paid_at,
    b.completed_at,
    b.payout_released_at,
    b.provider_paid_out_at,
    b.booking_date,
    b.booking_time,
    b.created_at,
    null::uuid as assignment_id,
    1::integer as slot_number,
    case when b.payout_release_status='released' then 'paid' else 'pending' end::text as payout_status,
    null::uuid as payout_id
  from public.bookings b
  left join public.services s on s.id = b.service_id
  where b.provider_id = auth.uid()
    and b.payment_status='paid'
    and not exists (
      select 1
      from public.booking_professional_assignments a
      where a.booking_id=b.id and a.status in ('accepted','completed')
    )
)
select * from team_rows
union all
select * from legacy_rows;

create view public.v_provider_payouts
with (security_invoker = true) as
select
  pp.id,
  pp.provider_id,
  pp.booking_id,
  coalesce(nullif(b.service_title,''),nullif(s.title,''),'Servicio Wissa')::text as service_title,
  coalesce(nullif(s.category,''),'Otros')::text as service_category,
  round(greatest(coalesce(pp.amount,0),0),2)::numeric as amount,
  pp.status,
  case
    when pp.status='paid' then 'Liquidado'
    when pp.status='pending' then 'Pendiente'
    when pp.status='cancelled' then 'Cancelado'
    else initcap(replace(coalesce(pp.status,'sin_estado'),'_',' '))
  end::text as status_label,
  pp.method,
  coalesce(nullif(b.payment_method,''),nullif(b.payment_provider,''),pp.method,'No indicado')::text as payment_method,
  coalesce(nullif(b.payment_provider,''),nullif(b.payment_method,''),pp.method,'No indicado')::text as payment_provider,
  pp.reference,
  pp.notes,
  pp.paid_at,
  pp.created_at,
  pp.updated_at,
  b.booking_date,
  b.booking_time,
  b.payout_release_status,
  b.finance_status,
  b.payout_released_at,
  pp.assignment_id,
  pp.payout_kind,
  round(greatest(coalesce(pp.service_amount,0),0),2)::numeric as service_amount,
  round(greatest(coalesce(a.service_share,0),0),2)::numeric as professional_service_amount,
  round(greatest(coalesce(a.extras_share,0),0),2)::numeric as extras_amount,
  round(greatest(coalesce(a.travel_fee,0),0),2)::numeric as travel_fee,
  round(greatest(coalesce(pp.tip_amount,0),0),2)::numeric as tip_amount,
  pp.receipt_bucket,
  pp.receipt_path,
  pp.receipt_url,
  pp.receipt_name,
  pp.receipt_mime,
  pp.receipt_size,
  null::text as proof_bucket,
  null::text as proof_path,
  null::text as proof_url
from public.provider_payouts pp
left join public.bookings b on b.id=pp.booking_id
left join public.services s on s.id=b.service_id
left join public.booking_professional_assignments a on a.id=pp.assignment_id
where pp.provider_id=auth.uid();

create view public.v_provider_tips
with (security_invoker = true) as
select
  a.id,
  a.booking_id,
  a.provider_id,
  t.amount,
  round(greatest(coalesce(a.provider_share,0),0),2)::numeric as provider_share,
  t.payment_method,
  coalesce(nullif(t.payment_method,''), nullif(b.payment_provider,''), 'No indicado')::text as payment_provider,
  t.status as tip_status,
  a.status as allocation_status,
  a.payout_id,
  a.paid_out_at,
  t.paid_at,
  a.created_at,
  coalesce(nullif(b.service_title,''),nullif(s.title,''),'Servicio Wissa')::text as service_title,
  coalesce(nullif(s.category,''),'Otros')::text as service_category
from public.booking_tip_allocations a
join public.booking_tips t on t.id=a.tip_id
join public.bookings b on b.id=a.booking_id
left join public.services s on s.id=b.service_id
where a.provider_id=auth.uid()
  and lower(coalesce(t.status,'')) in ('paid','approved');

create view public.v_provider_earnings_summary
with (security_invoker = true) as
with service_totals as (
  select
    coalesce(sum(provider_net) filter (
      where booking_status in ('completed','completed_pending_release')
        and coalesce(payout_status,'pending') <> 'paid'
    ),0)::numeric as available_service,
    coalesce(sum(provider_net) filter (
      where booking_status not in ('completed','completed_pending_release')
        and coalesce(payout_status,'pending') <> 'paid'
    ),0)::numeric as pending_service,
    coalesce(sum(provider_net) filter (where coalesce(payout_status,'pending')='paid'),0)::numeric as paid_service,
    count(distinct booking_id) filter (where payment_status='paid')::bigint as approved_services,
    count(distinct booking_id) filter (where coalesce(payout_status,'pending')='paid')::bigint as settled_services
  from public.v_provider_earnings
), tip_totals as (
  select
    coalesce(sum(provider_share) filter (
      where payout_id is null
        and paid_out_at is null
        and lower(coalesce(allocation_status,'allocated')) not in ('paid','cancelled')
    ),0)::numeric as available_tips,
    coalesce(sum(provider_share) filter (
      where payout_id is not null or paid_out_at is not null or lower(coalesce(allocation_status,''))='paid'
    ),0)::numeric as paid_tips
  from public.v_provider_tips
)
select
  auth.uid() as provider_id,
  round(greatest(coalesce(s.available_service,0)+coalesce(t.available_tips,0),0),2)::numeric as disponible_liquidar,
  round(greatest(coalesce(s.available_service,0),0),2)::numeric as disponible_servicios,
  round(greatest(coalesce(t.available_tips,0),0),2)::numeric as disponible_propinas,
  round(greatest(coalesce(s.pending_service,0),0),2)::numeric as pendiente_validacion,
  round(greatest(coalesce(s.paid_service,0)+coalesce(t.paid_tips,0),0),2)::numeric as pagado_acumulado,
  s.approved_services as servicios_aprobados,
  s.settled_services as liquidaciones_registradas
from service_totals s cross join tip_totals t;

grant select on public.v_provider_earnings, public.v_provider_earnings_summary, public.v_provider_payouts, public.v_provider_tips to authenticated;

-- Solicitud de retiro por el saldo disponible. Incluye servicio + propinas aún no liquidadas.
create or replace function public.yt_v66_request_provider_withdrawal()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_user uuid := auth.uid();
  v_services numeric := 0;
  v_tips numeric := 0;
  v_available numeric := 0;
  v_existing uuid;
  v_request public.payout_requests%rowtype;
begin
  if v_user is null then raise exception 'No autorizado'; end if;

  select id into v_existing
  from public.payout_requests
  where provider_id=v_user and lower(coalesce(status,''))='pending'
  order by created_at desc limit 1;

  if v_existing is not null then
    return jsonb_build_object(
      'ok',false,'reason','pending_exists','request_id',v_existing,
      'message','Ya tienes una solicitud de retiro pendiente.'
    );
  end if;

  select coalesce(sum(provider_net),0) into v_services
  from public.v_provider_earnings
  where booking_status in ('completed','completed_pending_release')
    and coalesce(payout_status,'pending') <> 'paid';

  select coalesce(sum(provider_share),0) into v_tips
  from public.v_provider_tips
  where payout_id is null
    and paid_out_at is null
    and lower(coalesce(allocation_status,'allocated')) not in ('paid','cancelled');

  v_available := round(greatest(v_services + v_tips,0),2);

  if v_available <= 0 then
    return jsonb_build_object('ok',false,'reason','no_balance','message','No tienes saldo disponible para retirar.');
  end if;

  insert into public.payout_requests(provider_id,amount,status)
  values(v_user,v_available,'pending') returning * into v_request;

  return jsonb_build_object(
    'ok',true,
    'request_id',v_request.id,
    'amount',v_request.amount,
    'service_amount',round(v_services,2),
    'tip_amount',round(v_tips,2),
    'status',v_request.status
  );
end;
$$;
revoke execute on function public.yt_v66_request_provider_withdrawal() from public,anon;
grant execute on function public.yt_v66_request_provider_withdrawal() to authenticated,service_role;

-- ============================================================================
-- 2) RESUMEN ADMIN FINANCIERO V66
-- ============================================================================
create or replace function public.wissa_finance_summary_v66()
returns jsonb
language plpgsql
security definer
stable
set search_path=public
as $$
declare
  v_result jsonb;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then raise exception 'No autorizado'; end if;

  with paid as (
    select b.*
    from public.bookings b
    where b.payment_status='paid'
      and coalesce(b.status,'') not in ('cancelled','rejected')
      and coalesce(b.refund_status,'not_requested') <> 'refunded'
  ), assignment_totals as (
    select a.booking_id,
      sum(case when a.status in ('accepted','completed') then coalesce(a.service_share,0) else 0 end)::numeric as service_share,
      sum(case when a.status in ('accepted','completed') then coalesce(a.extras_share,0) else 0 end)::numeric as extras_share,
      sum(case when a.status in ('accepted','completed') then coalesce(a.travel_fee,0) else 0 end)::numeric as travel_share,
      sum(case when a.status in ('accepted','completed') then case when coalesce(a.net_provider_amount,0)>0 then a.net_provider_amount else coalesce(a.service_share,0)+coalesce(a.travel_fee,0) end else 0 end)::numeric as professional_total
    from public.booking_professional_assignments a
    group by a.booking_id
  ), tip_totals as (
    select t.booking_id, sum(a.provider_share)::numeric as tips_total
    from public.booking_tips t
    join public.booking_tip_allocations a on a.tip_id=t.id
    where lower(coalesce(t.status,'')) in ('paid','approved')
    group by t.booking_id
  )
  select jsonb_build_object(
    'services', round(coalesce(sum(greatest(coalesce(p.service_subtotal,0),0)),0),2),
    'extras', round(coalesce(sum(greatest(coalesce(a.extras_share,0),0)),0),2),
    'kits_materials', round(coalesce(sum(greatest(coalesce(nullif(p.wissa_kit_revenue,0),p.kit_amount,0),0)),0),2),
    'travel', round(coalesce(sum(greatest(coalesce(a.travel_share,p.mobility_fee_total,p.travel_fee,0),0)),0),2),
    'platform_usage', round(coalesce(sum(greatest(coalesce(p.platform_usage_fee,0),0)),0),2),
    'itbms', round(coalesce(sum(greatest(coalesce(p.tax_amount,0),0)),0),2),
    'wissa_commission', round(coalesce(sum(greatest(coalesce(p.platform_fee,0),0)),0),2),
    'professional_total', round(coalesce(sum(greatest(coalesce(a.professional_total,p.seller_payout,0),0)),0),2),
    'tips', round(coalesce(sum(greatest(coalesce(t.tips_total,0),0)),0),2),
    'total_processed', round(coalesce(sum(greatest(coalesce(p.total_amount,p.subtotal_amount,p.price_snapshot,0),0)),0),2),
    'yappy_total', round(coalesce(sum(case when lower(coalesce(p.payment_provider,p.payment_method,'')) like '%yappy%' then greatest(coalesce(p.total_amount,0),0) else 0 end),0),2),
    'paguelofacil_total', round(coalesce(sum(case when lower(coalesce(p.payment_provider,p.payment_method,'')) like '%facil%' or lower(coalesce(p.payment_provider,p.payment_method,'')) like '%pf%' then greatest(coalesce(p.total_amount,0),0) else 0 end),0),2)
  ) into v_result
  from paid p
  left join assignment_totals a on a.booking_id=p.id
  left join tip_totals t on t.booking_id=p.id;

  return coalesce(v_result,'{}'::jsonb);
end;
$$;
revoke execute on function public.wissa_finance_summary_v66() from public,anon;
grant execute on function public.wissa_finance_summary_v66() to authenticated,service_role;

-- ============================================================================
-- 3) ADMIN FINANZAS: una fila por reserva, equipo agregado y desglose real
-- ============================================================================
drop function if exists public.yt_admin_wissa_finance_v66_json(text,text,integer,date,date);
create function public.yt_admin_wissa_finance_v66_json(
  p_search text default '', p_status text default 'all', p_limit integer default 500,
  p_date_from date default null, p_date_to date default null
)
returns table(
  id uuid,
  booking_id uuid,
  service_title text,
  service_category text,
  buyer_name text,
  provider_name text,
  professionals_count integer,
  professional_breakdown text,
  gateway text,
  method text,
  status text,
  status_label text,
  release_status text,
  amount numeric,
  service_subtotal numeric,
  extras_amount numeric,
  travel_fee numeric,
  tip_amount numeric,
  platform_fee numeric,
  platform_usage_fee numeric,
  tax_amount numeric,
  kit_amount numeric,
  wissa_total_revenue numeric,
  professional_total numeric,
  reference text,
  created_at timestamptz,
  paid_at timestamptz
)
language plpgsql
security definer
stable
set search_path=public
as $$
declare
  v_search text:=lower(trim(coalesce(p_search,'')));
  v_status text:=lower(trim(coalesce(p_status,'all')));
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then raise exception 'No autorizado'; end if;

  return query
  with team as (
    select
      a.booking_id,
      count(*) filter (where a.status in ('accepted','completed'))::integer as professionals_count,
      string_agg(
        case when a.status in ('accepted','completed') then
          coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Profesional')
        end,
        ' · ' order by a.slot_number
      ) filter (where a.status in ('accepted','completed')) as professional_names,
      string_agg(
        case when a.status in ('accepted','completed') then
          concat(
            coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Profesional'),
            ': Servicio ',to_char(greatest(coalesce(a.service_share,0),0),'FM999999990.00'),
            ' · Extras ',to_char(greatest(coalesce(a.extras_share,0),0),'FM999999990.00'),
            ' · Traslado ',to_char(greatest(coalesce(a.travel_fee,0),0),'FM999999990.00'),
            ' · Pago profesional ',to_char(greatest(case when coalesce(a.net_provider_amount,0)>0 then a.net_provider_amount else coalesce(a.service_share,0)+coalesce(a.travel_fee,0) end,0),'FM999999990.00')
          )
        end,
        ' | ' order by a.slot_number
      ) filter (where a.status in ('accepted','completed')) as professional_breakdown,
      sum(case when a.status in ('accepted','completed') then coalesce(a.extras_share,0) else 0 end)::numeric as extras_amount,
      sum(case when a.status in ('accepted','completed') then coalesce(a.travel_fee,0) else 0 end)::numeric as travel_total,
      sum(case when a.status in ('accepted','completed') then case when coalesce(a.net_provider_amount,0)>0 then a.net_provider_amount else coalesce(a.service_share,0)+coalesce(a.travel_fee,0) end else 0 end)::numeric as professional_total
    from public.booking_professional_assignments a
    left join public.profiles p on p.id=a.provider_id
    group by a.booking_id
  ), tips as (
    select t.booking_id, sum(a.provider_share)::numeric as tip_total
    from public.booking_tips t
    join public.booking_tip_allocations a on a.tip_id=t.id
    where lower(coalesce(t.status,'')) in ('paid','approved')
    group by t.booking_id
  )
  select
    b.id,
    b.id,
    coalesce(nullif(b.service_title,''),nullif(s.title,''),'Servicio Wissa')::text,
    coalesce(nullif(s.category,''),'Otros')::text,
    coalesce(nullif(buyer.display_name,''),nullif(buyer.full_name,''),nullif(buyer.email,''),'Cliente')::text,
    coalesce(nullif(team.professional_names,''),nullif(provider.display_name,''),nullif(provider.full_name,''),nullif(provider.email,''),'Sin asignar')::text,
    greatest(coalesce(team.professionals_count,0),case when b.provider_id is not null then 1 else 0 end)::integer,
    coalesce(nullif(team.professional_breakdown,''),
      case when b.provider_id is not null then concat(coalesce(nullif(provider.display_name,''),nullif(provider.full_name,''),'Profesional'),': Pago profesional ',to_char(greatest(coalesce(b.seller_payout,0),0),'FM999999990.00')) else 'Sin profesionales confirmados' end
    )::text,
    coalesce(nullif(b.payment_provider,''),nullif(b.payment_method,''),'Wissa')::text,
    coalesce(nullif(b.payment_method,''),nullif(b.payment_provider,''),'No indicado')::text,
    'approved'::text,
    'Pagado'::text,
    coalesce(nullif(b.payout_release_status,''),'not_released')::text,
    round(greatest(coalesce(b.total_amount,b.subtotal_amount,b.price_snapshot,0),0),2)::numeric,
    round(greatest(coalesce(b.service_subtotal,0),0),2)::numeric,
    round(greatest(coalesce(team.extras_amount,0),0),2)::numeric,
    round(greatest(coalesce(team.travel_total,b.mobility_fee_total,b.travel_fee,0),0),2)::numeric,
    round(greatest(coalesce(tips.tip_total,0),0),2)::numeric,
    round(greatest(coalesce(b.platform_fee,0),0),2)::numeric,
    round(greatest(coalesce(b.platform_usage_fee,0),0),2)::numeric,
    round(greatest(coalesce(b.tax_amount,0),0),2)::numeric,
    round(greatest(coalesce(nullif(b.wissa_kit_revenue,0),b.kit_amount,0),0),2)::numeric,
    round(greatest(coalesce(b.platform_fee,0),0)+greatest(coalesce(nullif(b.wissa_kit_revenue,0),b.kit_amount,0),0),2)::numeric,
    round(greatest(coalesce(team.professional_total,nullif(b.seller_payout,0),0),0),2)::numeric,
    coalesce(nullif(b.yappy_transaction_id,''),nullif(b.yappy_order_id,''),nullif(b.reservation_code,''),b.id::text)::text,
    coalesce(b.paid_at,b.created_at),
    b.paid_at
  from public.bookings b
  left join public.services s on s.id=b.service_id
  left join public.profiles buyer on buyer.id=b.buyer_id
  left join public.profiles provider on provider.id=b.provider_id
  left join team on team.booking_id=b.id
  left join tips on tips.booking_id=b.id
  where b.payment_status='paid'
    and coalesce(b.status,'') not in ('rejected','cancelled')
    and coalesce(b.refund_status,'not_requested') <> 'refunded'
    and (
      v_status='all'
      or v_status='approved'
      or (v_status='released' and coalesce(b.payout_release_status,'not_released')='released')
      or (v_status='not_released' and coalesce(b.payout_release_status,'not_released')<>'released')
    )
    and (p_date_from is null or (coalesce(b.paid_at,b.created_at) at time zone 'America/Panama')::date>=p_date_from)
    and (p_date_to is null or (coalesce(b.paid_at,b.created_at) at time zone 'America/Panama')::date<=p_date_to)
    and (
      v_search=''
      or lower(concat_ws(' ',b.id::text,b.reservation_code,b.service_title,s.title,s.category,buyer.display_name,buyer.full_name,buyer.email,provider.display_name,provider.full_name,b.payment_provider,b.payment_method,team.professional_names)) like '%'||v_search||'%'
    )
  order by coalesce(b.paid_at,b.created_at) desc
  limit greatest(1,least(coalesce(p_limit,500),2000));
end;
$$;
revoke execute on function public.yt_admin_wissa_finance_v66_json(text,text,integer,date,date) from public,anon;
grant execute on function public.yt_admin_wissa_finance_v66_json(text,text,integer,date,date) to authenticated,service_role;

-- ============================================================================
-- 4) ADMIN RESERVAS: nombres y desglose multi-profesional sin "Neto"
-- ============================================================================
drop function if exists public.yt_admin_bookings_v66_json(text,text,integer,date,date);
create function public.yt_admin_bookings_v66_json(
  p_search text default '', p_status text default 'all', p_limit integer default 500,
  p_date_from date default null, p_date_to date default null
)
returns table(
  id uuid,
  booking_id uuid,
  reservation_code text,
  service_title text,
  service_category text,
  pricing_summary text,
  pricing_source_label text,
  pricing_breakdown text,
  buyer_name text,
  provider_name text,
  professional_count integer,
  professional_breakdown text,
  quote_status text,
  status text,
  status_label text,
  payment_status text,
  payment_status_label text,
  payout_release_status text,
  subtotal_amount numeric,
  platform_fee numeric,
  professional_total numeric,
  amount numeric,
  booking_date date,
  booking_time text,
  created_at timestamptz
)
language plpgsql
security definer
stable
set search_path=public
as $$
declare
  v_search text:=lower(trim(coalesce(p_search,'')));
  v_status text:=lower(trim(coalesce(p_status,'all')));
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then raise exception 'No autorizado'; end if;

  return query
  with team as (
    select
      a.booking_id,
      count(*) filter (where a.status in ('accepted','completed'))::integer as professional_count,
      string_agg(
        case when a.status in ('accepted','completed') then coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Profesional') end,
        ' · ' order by a.slot_number
      ) filter (where a.status in ('accepted','completed')) as professional_names,
      string_agg(
        case when a.status in ('accepted','completed') then concat(
          coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Profesional'),
          ': Servicio $',to_char(greatest(coalesce(a.service_share,0),0),'FM999999990.00'),
          ' · Extras $',to_char(greatest(coalesce(a.extras_share,0),0),'FM999999990.00'),
          ' · Traslado $',to_char(greatest(coalesce(a.travel_fee,0),0),'FM999999990.00'),
          ' · Pago profesional $',to_char(greatest(case when coalesce(a.net_provider_amount,0)>0 then a.net_provider_amount else coalesce(a.service_share,0)+coalesce(a.travel_fee,0) end,0),'FM999999990.00')
        ) end,
        ' | ' order by a.slot_number
      ) filter (where a.status in ('accepted','completed')) as professional_breakdown,
      sum(case when a.status in ('accepted','completed') then case when coalesce(a.net_provider_amount,0)>0 then a.net_provider_amount else coalesce(a.service_share,0)+coalesce(a.travel_fee,0) end else 0 end)::numeric as professional_total
    from public.booking_professional_assignments a
    left join public.profiles p on p.id=a.provider_id
    group by a.booking_id
  )
  select
    b.id,
    b.id,
    b.reservation_code,
    coalesce(nullif(b.service_title,''),nullif(s.title,''),'Servicio Wissa')::text,
    coalesce(nullif(s.category,''),'Otros')::text,
    concat(
      case when coalesce(b.service_type,'single')='maintenance' then 'Plan recurrente' else 'Una sola vez' end,
      case when coalesce(b.square_meters,0)>0 then concat(' · ',trim(to_char(b.square_meters,'FM999999990.##')),' m²') else '' end,
      ' · ',greatest(coalesce(b.required_professionals,1),1),' profesional',case when greatest(coalesce(b.required_professionals,1),1)=1 then '' else 'es' end
    )::text,
    case when coalesce(b.pricing_strategy,'') in ('','metered') then 'Tarifa calculada para la reserva' else 'Tarifa configurada' end::text,
    concat(
      'Servicio ',to_char(greatest(coalesce(b.service_subtotal,0),0),'FM999999990.00'),
      ' · Traslado ',to_char(greatest(coalesce(b.mobility_fee_total,b.travel_fee,0),0),'FM999999990.00'),
      ' · Kit/materiales ',to_char(greatest(coalesce(nullif(b.wissa_kit_revenue,0),b.kit_amount,0),0),'FM999999990.00'),
      ' · Plataforma ',to_char(greatest(coalesce(b.platform_usage_fee,0),0),'FM999999990.00')
    )::text,
    coalesce(nullif(buyer.display_name,''),nullif(buyer.full_name,''),nullif(buyer.email,''),'Cliente')::text,
    coalesce(nullif(team.professional_names,''),nullif(provider.display_name,''),nullif(provider.full_name,''),nullif(provider.email,''),'Sin asignar')::text,
    greatest(coalesce(team.professional_count,0),case when b.provider_id is not null then 1 else 0 end)::integer,
    coalesce(nullif(team.professional_breakdown,''),case when b.provider_id is not null then concat(coalesce(nullif(provider.display_name,''),nullif(provider.full_name,''),'Profesional'),': Pago profesional $',to_char(greatest(coalesce(b.seller_payout,0),0),'FM999999990.00')) else 'Sin profesionales confirmados' end)::text,
    case when b.payment_status='paid' then 'confirmed' else 'pending' end::text,
    b.status,
    initcap(replace(coalesce(b.status,'pending'),'_',' '))::text,
    b.payment_status,
    initcap(replace(coalesce(b.payment_status,'not_started'),'_',' '))::text,
    b.payout_release_status,
    round(greatest(coalesce(b.subtotal_amount,b.service_subtotal,0),0),2)::numeric,
    round(greatest(coalesce(b.platform_fee,0),0),2)::numeric,
    round(greatest(coalesce(team.professional_total,nullif(b.seller_payout,0),0),0),2)::numeric,
    round(greatest(coalesce(b.total_amount,b.subtotal_amount,b.price_snapshot,0),0),2)::numeric,
    b.booking_date,
    b.booking_time,
    b.created_at
  from public.bookings b
  left join public.services s on s.id=b.service_id
  left join public.profiles buyer on buyer.id=b.buyer_id
  left join public.profiles provider on provider.id=b.provider_id
  left join team on team.booking_id=b.id
  where (
      v_status='all'
      or lower(coalesce(b.status,''))=v_status
      or lower(coalesce(b.payment_status,''))=v_status
      or lower(coalesce(b.payout_release_status,''))=v_status
    )
    and (p_date_from is null or b.booking_date>=p_date_from)
    and (p_date_to is null or b.booking_date<=p_date_to)
    and (
      v_search=''
      or lower(concat_ws(' ',b.id::text,b.reservation_code,b.service_title,s.title,s.category,buyer.display_name,buyer.full_name,buyer.email,provider.display_name,provider.full_name,team.professional_names)) like '%'||v_search||'%'
    )
  order by b.created_at desc
  limit greatest(1,least(coalesce(p_limit,500),2000));
end;
$$;
revoke execute on function public.yt_admin_bookings_v66_json(text,text,integer,date,date) from public,anon;
grant execute on function public.yt_admin_bookings_v66_json(text,text,integer,date,date) to authenticated,service_role;

-- ============================================================================
-- 5) ADMIN DISTRIBUCIÓN: detalle por profesional, extras, traslado y propina
-- ============================================================================
create or replace function public.yt_admin_booking_distribution_v66(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path=public
as $$
declare
  v_booking public.bookings%rowtype;
  v_team jsonb := '[]'::jsonb;
  v_tip_total numeric := 0;
  v_provider_total numeric := 0;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then raise exception 'No autorizado'; end if;

  select * into v_booking from public.bookings where id=p_booking_id;
  if not found then raise exception 'Reserva no encontrada'; end if;

  select coalesce(jsonb_agg(row_data order by slot), '[]'::jsonb),
         coalesce(sum((row_data->>'professional_payment')::numeric),0),
         coalesce(sum((row_data->>'tip_amount')::numeric),0)
  into v_team, v_provider_total, v_tip_total
  from (
    select
      a.slot_number as slot,
      jsonb_build_object(
        'slot',a.slot_number,
        'assignment_id',a.id,
        'provider_id',a.provider_id,
        'provider_name',coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Profesional'),
        'status',a.status,
        'service_share',round(greatest(coalesce(a.service_share,0),0),2),
        'extras_share',round(greatest(coalesce(a.extras_share,0),0),2),
        'travel_fee',round(greatest(coalesce(a.travel_fee,0),0),2),
        'tip_amount',round(greatest(coalesce(t.tip_amount,0),0),2),
        'professional_payment',round(greatest((case when coalesce(a.net_provider_amount,0)>0 then a.net_provider_amount else coalesce(a.service_share,0)+coalesce(a.travel_fee,0) end)+coalesce(t.tip_amount,0),0),2),
        'payout_status',coalesce(nullif(pp.status,''),nullif(a.payout_status,''),'pending'),
        'payout_id',coalesce(pp.id,a.payout_id),
        'receipt_bucket',pp.receipt_bucket,
        'receipt_path',pp.receipt_path,
        'receipt_url',pp.receipt_url
      ) as row_data
    from public.booking_professional_assignments a
    left join public.profiles p on p.id=a.provider_id
    left join lateral (
      select sum(x.provider_share)::numeric as tip_amount
      from public.booking_tip_allocations x
      join public.booking_tips bt on bt.id=x.tip_id
      where x.assignment_id=a.id and lower(coalesce(bt.status,'')) in ('paid','approved')
    ) t on true
    left join public.provider_payouts pp on pp.id=coalesce(a.payout_id,
      (select pp2.id from public.provider_payouts pp2 where pp2.assignment_id=a.id order by pp2.created_at desc limit 1)
    )
    where a.booking_id=p_booking_id
      and a.status in ('accepted','completed','pending')
  ) q;

  return jsonb_build_object(
    'booking_id',v_booking.id,
    'reservation_code',v_booking.reservation_code,
    'status',v_booking.status,
    'payment_status',v_booking.payment_status,
    'payout_release_status',v_booking.payout_release_status,
    'required_professionals',greatest(coalesce(v_booking.required_professionals,1),1),
    'accepted_professionals',coalesce(v_booking.accepted_professionals,0),
    'client_total',round(greatest(coalesce(v_booking.total_amount,0),0),2),
    'gross_total',round(greatest(coalesce(v_booking.gross_total_amount,v_booking.total_amount,0),0),2),
    'service_subtotal',round(greatest(coalesce(v_booking.service_subtotal,0),0),2),
    'wissa_commission',round(greatest(coalesce(v_booking.platform_fee,0),0),2),
    'platform_usage_fee',round(greatest(coalesce(v_booking.platform_usage_fee,0),0),2),
    'kits_materials',round(greatest(coalesce(nullif(v_booking.wissa_kit_revenue,0),v_booking.kit_amount,0),0),2),
    'travel_total',round(greatest(coalesce(v_booking.mobility_fee_total,v_booking.travel_fee,0),0),2),
    'itbms',round(greatest(coalesce(v_booking.tax_amount,0),0),2),
    'loyalty_subsidy',round(greatest(coalesce(v_booking.loyalty_subsidy_amount,0),0),2),
    'provider_pool',round(greatest(coalesce(v_provider_total,0),0),2),
    'tips_total',round(greatest(coalesce(v_tip_total,0),0),2),
    'commission_rate',coalesce(v_booking.commission_rate_snapshot,0.20),
    'team',v_team
  );
end;
$$;
revoke execute on function public.yt_admin_booking_distribution_v66(uuid) from public,anon;
grant execute on function public.yt_admin_booking_distribution_v66(uuid) to authenticated,service_role;

-- ============================================================================
-- 6) COMISIONES WISSA: por categoría / pasarela + saldo + retiros
-- ============================================================================
drop function if exists public.yt_admin_wissa_marketplace_revenue_v66_json(text,text,integer,date,date);
create function public.yt_admin_wissa_marketplace_revenue_v66_json(
  p_search text default '', p_status text default 'all', p_limit integer default 500,
  p_date_from date default null, p_date_to date default null
)
returns table(
  id text,
  source text,
  service_title text,
  service_category text,
  buyer_name text,
  provider_name text,
  status text,
  amount numeric,
  commission_amount numeric,
  kit_amount numeric,
  extras_amount numeric,
  method text,
  gateway text,
  reference text,
  created_at timestamptz
)
language plpgsql
security definer
stable
set search_path=public
as $$
declare
  v_search text:=lower(trim(coalesce(p_search,'')));
  v_status text:=lower(trim(coalesce(p_status,'all')));
  v_earned numeric:=0;
  v_withdrawn numeric:=0;
  v_pending numeric:=0;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then raise exception 'No autorizado'; end if;

  select coalesce(sum(greatest(coalesce(b.platform_fee,0),0)+greatest(coalesce(nullif(b.wissa_kit_revenue,0),b.kit_amount,0),0)),0)
  into v_earned
  from public.bookings b
  where b.payment_status='paid'
    and coalesce(b.refund_status,'not_requested')<>'refunded'
    and coalesce(b.status,'') not in ('cancelled','rejected');

  select coalesce(sum(w.amount),0) into v_withdrawn
  from public.platform_commission_withdrawals w
  where lower(coalesce(w.status,'collected')) not in ('cancelled','rejected');

  v_pending:=greatest(v_earned-v_withdrawn,0);

  return query
  with earned as (
    select
      ('booking:'||b.id::text)::text as id,
      'platform_commission_earned'::text as source,
      coalesce(nullif(b.service_title,''),nullif(s.title,''),'Servicio Wissa')::text as service_title,
      coalesce(nullif(s.category,''),'Otros')::text as service_category,
      coalesce(nullif(buyer.display_name,''),nullif(buyer.full_name,''),nullif(buyer.email,''),'Cliente')::text as buyer_name,
      coalesce(nullif(team.professional_names,''),'Equipo profesional')::text as provider_name,
      'earned'::text as status,
      round(greatest(coalesce(b.platform_fee,0),0)+greatest(coalesce(nullif(b.wissa_kit_revenue,0),b.kit_amount,0),0),2)::numeric as amount,
      round(greatest(coalesce(b.platform_fee,0),0),2)::numeric as commission_amount,
      round(greatest(coalesce(nullif(b.wissa_kit_revenue,0),b.kit_amount,0),0),2)::numeric as kit_amount,
      round(greatest(coalesce(team.extras_amount,0),0),2)::numeric as extras_amount,
      coalesce(nullif(b.payment_method,''),'No indicado')::text as method,
      coalesce(nullif(b.payment_provider,''),nullif(b.payment_method,''),'Wissa')::text as gateway,
      coalesce(nullif(b.reservation_code,''),b.id::text)::text as reference,
      coalesce(b.paid_at,b.created_at)::timestamptz as created_at
    from public.bookings b
    left join public.services s on s.id=b.service_id
    left join public.profiles buyer on buyer.id=b.buyer_id
    left join lateral (
      select
        string_agg(distinct coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Profesional'),' · ') as professional_names,
        sum(coalesce(a.extras_share,0))::numeric as extras_amount
      from public.booking_professional_assignments a
      left join public.profiles p on p.id=a.provider_id
      where a.booking_id=b.id and a.status in ('accepted','completed')
    ) team on true
    where b.payment_status='paid'
      and coalesce(b.refund_status,'not_requested')<>'refunded'
      and coalesce(b.status,'') not in ('cancelled','rejected')
      and (p_date_from is null or (coalesce(b.paid_at,b.created_at) at time zone 'America/Panama')::date>=p_date_from)
      and (p_date_to is null or (coalesce(b.paid_at,b.created_at) at time zone 'America/Panama')::date<=p_date_to)
  ), pending as (
    select
      'pending:marketplace'::text,
      'platform_commission_pending'::text,
      'Saldo disponible Wissa'::text,
      'Todas'::text,
      'Wissa'::text,
      'Administración'::text,
      'pending'::text,
      round(v_pending,2)::numeric,
      0::numeric,
      0::numeric,
      0::numeric,
      'manual_admin'::text,
      'Wissa'::text,
      'Saldo disponible'::text,
      now()::timestamptz
    where v_pending>0
  ), withdrawals as (
    select
      ('withdrawal:'||w.id::text)::text,
      'platform_commission_withdrawal'::text,
      'Retiro Wissa'::text,
      'Todas'::text,
      'Wissa'::text,
      'Administración'::text,
      coalesce(nullif(w.status,''),'collected')::text,
      round(w.amount,2)::numeric,
      0::numeric,
      0::numeric,
      0::numeric,
      coalesce(nullif(w.method,''),'manual_admin')::text,
      'Wissa'::text,
      coalesce(nullif(w.reference,''),w.id::text)::text,
      coalesce(w.collected_at,w.created_at)::timestamptz
    from public.platform_commission_withdrawals w
    where (p_date_from is null or (coalesce(w.collected_at,w.created_at) at time zone 'America/Panama')::date>=p_date_from)
      and (p_date_to is null or (coalesce(w.collected_at,w.created_at) at time zone 'America/Panama')::date<=p_date_to)
  ), all_rows as (
    select * from earned
    union all select * from pending
    union all select * from withdrawals
  )
  select * from all_rows r
  where (
      v_status='all'
      or lower(r.status)=v_status
      or lower(r.source)=v_status
      or (v_status='collected' and r.source='platform_commission_withdrawal')
    )
    and (
      v_search=''
      or lower(concat_ws(' ',r.id,r.source,r.service_title,r.service_category,r.buyer_name,r.provider_name,r.method,r.gateway,r.reference)) like '%'||v_search||'%'
    )
  order by r.created_at desc
  limit greatest(1,least(coalesce(p_limit,500),2000));
end;
$$;
revoke execute on function public.yt_admin_wissa_marketplace_revenue_v66_json(text,text,integer,date,date) from public,anon;
grant execute on function public.yt_admin_wissa_marketplace_revenue_v66_json(text,text,integer,date,date) to authenticated,service_role;


-- ============================================================================
-- 7) RETIROS / LIQUIDACIONES PROFESIONALES: assignment-aware + categoría
-- ============================================================================
drop function if exists public.yt_admin_withdrawals_v66_json(text,text,integer,date,date);
create function public.yt_admin_withdrawals_v66_json(
  p_search text default '', p_status text default 'all', p_limit integer default 500,
  p_date_from date default null, p_date_to date default null
)
returns table(
  id text,
  source text,
  reservation_code text,
  service_title text,
  service_category text,
  provider_name text,
  party_name text,
  provider_id uuid,
  booking_id uuid,
  assignment_id uuid,
  payment_status text,
  booking_status text,
  payout_release_status text,
  payout_status text,
  status text,
  amount numeric,
  service_amount numeric,
  extras_amount numeric,
  travel_fee numeric,
  tip_amount numeric,
  gateway text,
  payout_method text,
  payout_destination text,
  method text,
  reference text,
  payout_receipt_bucket text,
  payout_receipt_path text,
  receipt_bucket text,
  receipt_path text,
  created_at timestamptz
)
language plpgsql
security definer
stable
set search_path=public
as $$
declare
  v_search text:=lower(trim(coalesce(p_search,'')));
  v_status text:=lower(trim(coalesce(p_status,'all')));
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then raise exception 'No autorizado'; end if;

  return query
  with methods as (
    select distinct on (m.provider_id)
      m.provider_id,
      case when m.method_type='yappy' then 'Yappy' when m.method_type='bank' then 'Transferencia bancaria' else initcap(coalesce(m.method_type,'Otro')) end::text as payout_method,
      case
        when m.method_type='yappy' then concat('Yappy · ****',right(regexp_replace(coalesce(m.yappy_phone,''),'[^0-9]','','g'),4))
        when m.method_type='bank' then concat(coalesce(nullif(m.bank_name,''),'Banco'),' · ****',right(regexp_replace(coalesce(m.bank_account_number,''),'[^0-9A-Za-z]','','g'),4))
        else coalesce(nullif(m.label,''),'Método registrado')
      end::text as payout_destination
    from public.provider_payout_methods m
    where coalesce(m.is_active,true)=true
    order by m.provider_id, m.is_default desc, m.updated_at desc
  ), pending_assignments as (
    select
      ('assignment:'||a.id::text)::text as id,
      'provider_pending'::text as source,
      b.reservation_code::text,
      coalesce(nullif(b.service_title,''),nullif(s.title,''),'Servicio Wissa')::text as service_title,
      coalesce(nullif(s.category,''),'Otros')::text as service_category,
      coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Profesional')::text as provider_name,
      coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Profesional')::text as party_name,
      a.provider_id,
      b.id as booking_id,
      a.id as assignment_id,
      b.payment_status,
      b.status as booking_status,
      b.payout_release_status,
      coalesce(nullif(a.payout_status,''),'pending')::text as payout_status,
      b.status::text as status,
      round(greatest((case when coalesce(a.net_provider_amount,0)>0 then a.net_provider_amount else coalesce(a.service_share,0)+coalesce(a.travel_fee,0) end)+coalesce(a.tip_amount,0),0),2)::numeric as amount,
      round(greatest(case when coalesce(a.net_provider_amount,0)>0 then a.net_provider_amount-coalesce(a.travel_fee,0) else coalesce(a.service_share,0) end,0),2)::numeric as service_amount,
      round(greatest(coalesce(a.extras_share,0),0),2)::numeric as extras_amount,
      round(greatest(coalesce(a.travel_fee,0),0),2)::numeric as travel_fee,
      round(greatest(coalesce(a.tip_amount,0),0),2)::numeric as tip_amount,
      coalesce(nullif(b.payment_provider,''),nullif(b.payment_method,''),'Wissa')::text as gateway,
      coalesce(m.payout_method,'Sin método')::text,
      coalesce(m.payout_destination,'Configurar datos de cobro')::text,
      'Pendiente de liquidación'::text as method,
      coalesce(nullif(b.reservation_code,''),b.id::text)::text as reference,
      null::text as payout_receipt_bucket,
      null::text as payout_receipt_path,
      null::text as receipt_bucket,
      null::text as receipt_path,
      coalesce(a.completed_at,b.completed_at,b.created_at)::timestamptz as created_at
    from public.booking_professional_assignments a
    join public.bookings b on b.id=a.booking_id
    left join public.services s on s.id=b.service_id
    left join public.profiles p on p.id=a.provider_id
    left join methods m on m.provider_id=a.provider_id
    where a.status in ('accepted','completed')
      and b.payment_status='paid'
      and b.status in ('completed','completed_pending_release')
      and coalesce(a.payout_status,'pending')<>'paid'
  ), payouts as (
    select
      ('payout:'||pp.id::text)::text,
      'provider_payout'::text,
      b.reservation_code::text,
      coalesce(nullif(b.service_title,''),nullif(s.title,''),'Servicio Wissa')::text,
      coalesce(nullif(s.category,''),'Otros')::text,
      coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Profesional')::text,
      coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Profesional')::text,
      pp.provider_id,
      pp.booking_id,
      pp.assignment_id,
      b.payment_status,
      b.status,
      b.payout_release_status,
      pp.status::text,
      pp.status::text,
      round(greatest(coalesce(pp.amount,0),0),2)::numeric,
      round(greatest(coalesce(pp.service_amount,0),0),2)::numeric,
      round(greatest(coalesce(a.extras_share,0),0),2)::numeric,
      round(greatest(coalesce(a.travel_fee,0),0),2)::numeric,
      round(greatest(coalesce(pp.tip_amount,0),0),2)::numeric,
      coalesce(nullif(b.payment_provider,''),nullif(b.payment_method,''),'Wissa')::text,
      coalesce(m.payout_method,'Sin método')::text,
      coalesce(m.payout_destination,'Configurar datos de cobro')::text,
      coalesce(nullif(pp.method,''),'manual_admin')::text,
      coalesce(nullif(pp.reference,''),pp.id::text)::text,
      pp.receipt_bucket,
      pp.receipt_path,
      pp.receipt_bucket,
      pp.receipt_path,
      coalesce(pp.paid_at,pp.created_at)::timestamptz
    from public.provider_payouts pp
    left join public.bookings b on b.id=pp.booking_id
    left join public.services s on s.id=b.service_id
    left join public.profiles p on p.id=pp.provider_id
    left join public.booking_professional_assignments a on a.id=pp.assignment_id
    left join methods m on m.provider_id=pp.provider_id
  ), requests as (
    select
      ('request:'||r.id::text)::text,
      'payout_request'::text,
      null::text,
      'Solicitud de retiro'::text,
      'Todas'::text,
      coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Profesional')::text,
      coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Profesional')::text,
      r.provider_id,
      null::uuid,
      null::uuid,
      null::text,
      null::text,
      null::text,
      null::text,
      r.status::text,
      round(greatest(coalesce(r.amount,0),0),2)::numeric,
      0::numeric,0::numeric,0::numeric,0::numeric,
      'No aplica'::text,
      coalesce(m.payout_method,'Sin método')::text,
      coalesce(m.payout_destination,'Configurar datos de cobro')::text,
      'Solicitud del profesional'::text,
      r.id::text,
      null::text,null::text,null::text,null::text,
      r.created_at::timestamptz
    from public.payout_requests r
    left join public.profiles p on p.id=r.provider_id
    left join methods m on m.provider_id=r.provider_id
  ), all_rows as (
    select * from pending_assignments
    union all select * from payouts
    union all select * from requests
  )
  select * from all_rows x
  where (v_status='all' or lower(x.status)=v_status or lower(x.source)=v_status or lower(coalesce(x.payout_status,''))=v_status)
    and (p_date_from is null or (x.created_at at time zone 'America/Panama')::date>=p_date_from)
    and (p_date_to is null or (x.created_at at time zone 'America/Panama')::date<=p_date_to)
    and (v_search='' or lower(concat_ws(' ',x.id,x.source,x.reservation_code,x.service_title,x.service_category,x.provider_name,x.payout_method,x.payout_destination,x.gateway,x.reference)) like '%'||v_search||'%')
  order by x.created_at desc
  limit greatest(1,least(coalesce(p_limit,500),2000));
end;
$$;
revoke execute on function public.yt_admin_withdrawals_v66_json(text,text,integer,date,date) from public,anon;
grant execute on function public.yt_admin_withdrawals_v66_json(text,text,integer,date,date) to authenticated,service_role;

-- Version marker for support/audit.
insert into public.app_settings(key,value,updated_at)
values(
  'release_v66_block2b',
  jsonb_build_object(
    'version','66.2',
    'block','2B',
    'name','FINANZAS-COMISIONES',
    'provider_finance_categories',true,
    'payment_gateway_breakdown',true,
    'multi_professional_admin_breakdown',true,
    'withdrawal_request',true,
    'updated_at',now()
  ),
  now()
)
on conflict(key) do update set value=excluded.value,updated_at=now();

commit;
