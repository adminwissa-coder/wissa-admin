-- WISSA V66.8 — Verificación del hotfix (solo lectura)

-- 1) Funciones y columna requeridas.
select
  to_regprocedure('public.yt_v66_save_booking_review(uuid,integer,text,uuid)') is not null as review_rpc_ok,
  to_regprocedure('public.yt_v668_assignment_recalculate(uuid)') is not null as finance_v668_rpc_ok,
  to_regprocedure('public.yt_v62_assignment_recalculate(uuid)') is not null as legacy_finance_wrapper_ok;

select
  exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='payment_orders' and column_name='tip_id'
  ) as payment_orders_tip_id_ok;

-- 2) Desglose financiero reciente. La suma de Servicio + Extras + Traslado
-- debe coincidir con el pago profesional congelado para reservas históricas
-- no liquidadas. Esto permite verificar el caso que antes mostraba extras/traslado en 0.
select
  a.booking_id,
  a.slot_number,
  a.status,
  round(coalesce(a.service_share,0),2) as servicio_profesional,
  round(coalesce(a.extras_share,0),2) as extras_profesional,
  round(coalesce(a.travel_fee,0),2) as traslado_profesional,
  round(coalesce(a.net_provider_amount,0),2) as pago_profesional,
  round(coalesce(a.service_share,0)+coalesce(a.extras_share,0)+coalesce(a.travel_fee,0),2) as suma_desglose_sin_bonos,
  round(coalesce(b.seller_payout,0),2) as seller_payout_reserva,
  a.payout_status
from public.booking_professional_assignments a
join public.bookings b on b.id=a.booking_id
where a.status in ('accepted','completed')
order by a.updated_at desc
limit 20;

-- 3) Propinas pendientes. Si hay payment_order_id, el botón Actualizar del app
-- puede pedir reconciliación activa a pf-confirm-payment.
select
  t.id as tip_id,
  t.booking_id,
  t.amount,
  t.status,
  t.payment_method,
  t.metadata->>'payment_order_id' as payment_order_id,
  po.status as payment_order_status,
  po.pf_reference,
  po.pf_transaction_id,
  t.updated_at
from public.booking_tips t
left join public.payment_orders po
  on po.id::text = t.metadata->>'payment_order_id'
where lower(coalesce(t.status,''))='pending'
order by t.updated_at desc
limit 20;
