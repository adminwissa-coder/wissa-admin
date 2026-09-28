-- WISSA V66.7 - Finanzas: selector superior por categoria
-- Idempotente. No borra ni modifica datos operativos.

create or replace function public.wissa_finance_summary_v67(p_category text default null)
returns jsonb
language plpgsql
security definer
stable
set search_path=public
as $$
declare
  v_result jsonb;
  v_category text := nullif(trim(coalesce(p_category,'')),'');
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  if lower(coalesce(v_category,'')) = 'all' then
    v_category := null;
  end if;

  with paid as (
    select b.*, coalesce(nullif(s.category,''),'Otros')::text as finance_category
    from public.bookings b
    left join public.services s on s.id=b.service_id
    where b.payment_status='paid'
      and coalesce(b.status,'') not in ('cancelled','rejected')
      and coalesce(b.refund_status,'not_requested') <> 'refunded'
      and (
        v_category is null
        or lower(trim(coalesce(nullif(s.category,''),'Otros'))) = lower(v_category)
      )
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
    'paguelofacil_total', round(coalesce(sum(case when lower(coalesce(p.payment_provider,p.payment_method,'')) like '%facil%' or lower(coalesce(p.payment_provider,p.payment_method,'')) like '%pf%' then greatest(coalesce(p.total_amount,0),0) else 0 end),0),2),
    'category', coalesce(v_category,'all')
  ) into v_result
  from paid p
  left join assignment_totals a on a.booking_id=p.id
  left join tip_totals t on t.booking_id=p.id;

  return coalesce(v_result,'{}'::jsonb);
end;
$$;

revoke execute on function public.wissa_finance_summary_v67(text) from public,anon;
grant execute on function public.wissa_finance_summary_v67(text) to authenticated,service_role;
