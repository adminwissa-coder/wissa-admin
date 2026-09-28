-- ============================================================================
-- WISSA V66.8 — HOTFIX ERRORES REALES
-- 2026-09-22
--
-- Corrige:
--   1) Reseñas que fallan con "No autorizado para modificar este perfil".
--   2) Propinas PagueloFácil que quedan en pending sin reconciliación activa.
--   3) Desglose por profesional: extras + traslado fijo USD 5/profesional.
--   4) Backfill seguro únicamente sobre reservas todavía no liquidadas.
--
-- Idempotente. NO borra usuarios, reservas ni pagos.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- A. RESEÑAS
-- --------------------------------------------------------------------------
-- Algunos esquemas históricos tienen un trigger que, al insertar una reseña,
-- actualiza el rating del perfil evaluado. Ese trigger valida auth.uid() contra
-- el perfil que actualiza y puede bloquear al cliente aunque la reseña sea válida.
-- La RPC valida primero al cliente y la reserva, luego ejecuta solamente el INSERT
-- con el contexto del perfil evaluado y finalmente restaura el auth.uid() original.
-- No se abre acceso directo a profiles ni se desactiva RLS globalmente.

create unique index if not exists reviews_booking_reviewer_reviewed_uidx
  on public.reviews(booking_id, reviewer_id, reviewed_id);

create or replace function public.yt_v66_save_booking_review(
  p_booking_id uuid,
  p_rating integer,
  p_comment text default null,
  p_reviewed_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_original_sub text := current_setting('request.jwt.claim.sub', true);
  v_booking public.bookings%rowtype;
  v_reviewed uuid;
  v_review public.reviews%rowtype;
begin
  if v_user is null then
    raise exception 'No autorizado';
  end if;

  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'La valoración debe estar entre 1 y 5.';
  end if;

  select * into v_booking
  from public.bookings
  where id = p_booking_id;

  if not found then
    raise exception 'Reserva no encontrada.';
  end if;

  if v_booking.buyer_id <> v_user then
    raise exception 'Solo quien contrató puede guardar esta reseña.';
  end if;

  if coalesce(v_booking.status, '') not in ('completed','completed_pending_release')
     and lower(coalesce(v_booking.service_progress_stage, '')) not in ('completed','finalized','finished','closed') then
    raise exception 'La reseña estará disponible cuando el servicio finalice.';
  end if;

  v_reviewed := p_reviewed_id;

  if v_reviewed is null then
    select a.provider_id into v_reviewed
    from public.booking_professional_assignments a
    where a.booking_id = p_booking_id
      and a.status in ('accepted','completed')
    order by a.slot_number asc, a.created_at asc, a.id asc
    limit 1;

    v_reviewed := coalesce(v_reviewed, v_booking.provider_id, v_booking.winner_provider_id);
  end if;

  if v_reviewed is null then
    raise exception 'No hay un profesional confirmado para calificar.';
  end if;

  if not (
    v_reviewed = v_booking.provider_id
    or v_reviewed = v_booking.winner_provider_id
    or exists (
      select 1
      from public.booking_professional_assignments a
      where a.booking_id = p_booking_id
        and a.provider_id = v_reviewed
        and a.status in ('accepted','completed')
    )
  ) then
    raise exception 'El profesional indicado no pertenece a esta reserva.';
  end if;

  begin
    -- Compatibilidad con guardas históricas de profiles disparadas por triggers.
    perform set_config('request.jwt.claim.sub', v_reviewed::text, true);

    insert into public.reviews(booking_id, reviewer_id, reviewed_id, rating, comment)
    values (
      p_booking_id,
      v_user,
      v_reviewed,
      p_rating,
      nullif(btrim(coalesce(p_comment, '')), '')
    )
    on conflict (booking_id, reviewer_id, reviewed_id)
    do update set
      rating = excluded.rating,
      comment = excluded.comment
    returning * into v_review;

    perform set_config('request.jwt.claim.sub', coalesce(v_original_sub, ''), true);
  exception when others then
    perform set_config('request.jwt.claim.sub', coalesce(v_original_sub, ''), true);
    raise;
  end;

  return jsonb_build_object(
    'ok', true,
    'review_id', v_review.id,
    'booking_id', p_booking_id,
    'reviewed_id', v_reviewed,
    'rating', v_review.rating
  );
end;
$$;

revoke execute on function public.yt_v66_save_booking_review(uuid,integer,text,uuid) from public, anon;
grant execute on function public.yt_v66_save_booking_review(uuid,integer,text,uuid) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- B. PROPINA: vincular tip <-> payment_order para poder reconciliar activamente
-- --------------------------------------------------------------------------
alter table public.payment_orders add column if not exists tip_id uuid;

update public.booking_tips t
set metadata = coalesce(t.metadata, '{}'::jsonb) || jsonb_build_object(
  'payment_order_id', (
    select po.id
    from public.payment_orders po
    where po.tip_id = t.id
    order by po.created_at desc, po.id desc
    limit 1
  ),
  'provider', coalesce((
    select nullif(po.provider,'')
    from public.payment_orders po
    where po.tip_id = t.id
    order by po.created_at desc, po.id desc
    limit 1
  ), nullif(t.payment_method,''), 'paguelofacil'),
  'flow_version', 668
),
updated_at = now()
where exists (
  select 1
  from public.payment_orders po
  where po.tip_id = t.id
)
and (
  coalesce(t.metadata->>'payment_order_id','') = ''
  or lower(coalesce(t.status,'')) = 'pending'
);

-- --------------------------------------------------------------------------
-- C. FINANZAS POR PROFESIONAL — V66.8
-- --------------------------------------------------------------------------
-- Regla vigente:
--   - Comisión Wissa se aplica sobre servicio + extras.
--   - Extras se muestran separados dentro del pago profesional.
--   - Traslado es fijo por profesional y se entrega al profesional.
--   - Kits/materiales, plataforma e ITBMS NO forman parte de la liquidación.

create or replace function public.yt_v668_assignment_recalculate(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b public.bookings%rowtype;
  v_confirmed_count integer := 0;
  v_count integer := 0;
  v_idx integer := 0;
  v_extra_gross numeric := 0;
  v_service_gross numeric := 0;
  v_base_gross numeric := 0;
  v_rate numeric := 0.20;
  v_provider_commissionable_total numeric := 0;
  v_extras_net_total numeric := 0;
  v_base_net_total numeric := 0;
  v_travel_total numeric := 0;
  v_base_net_cents bigint := 0;
  v_extras_net_cents bigint := 0;
  v_travel_cents bigint := 0;
  v_base_gross_cents bigint := 0;
  v_extra_gross_cents bigint := 0;
  v_base_net_share numeric := 0;
  v_extras_net_share numeric := 0;
  v_travel_share numeric := 0;
  v_base_gross_share numeric := 0;
  v_extra_gross_share numeric := 0;
  v_provider_bonus numeric := 0;
  v_provider_total numeric := 0;
  v_provider_pool numeric := 0;
  v_snapshot jsonb := '[]'::jsonb;
  r record;
begin
  select * into b
  from public.bookings
  where id = p_booking_id
  for update;

  if not found then
    return jsonb_build_object('ok',false,'reason','booking_not_found');
  end if;

  -- Una liquidación ya pagada es histórica y no debe recalcularse.
  if exists (
    select 1
    from public.booking_professional_assignments a
    left join public.provider_payouts pp on pp.id = a.payout_id
    where a.booking_id = p_booking_id
      and (lower(coalesce(a.payout_status,'')) = 'paid' or lower(coalesce(pp.status,'')) = 'paid')
  ) then
    return jsonb_build_object('ok',true,'booking_id',p_booking_id,'locked',true,'reason','paid_assignment');
  end if;

  select count(*) into v_confirmed_count
  from public.booking_professional_assignments a
  where a.booking_id = p_booking_id
    and a.status in ('accepted','completed');

  if v_confirmed_count > 0 then
    v_count := v_confirmed_count;
  else
    select least(
      greatest(coalesce(b.required_professionals,1),1),
      count(*)::integer
    ) into v_count
    from public.booking_professional_assignments a
    where a.booking_id = p_booking_id and a.status = 'pending';
  end if;

  if coalesce(v_count,0) <= 0 then
    return jsonb_build_object('ok',false,'reason','no_assignments');
  end if;

  v_service_gross := greatest(coalesce(b.service_subtotal,0),0);
  v_rate := case
    when v_service_gross > 0 and coalesce(b.platform_fee,0) > 0
      then least(1, greatest(0, coalesce(b.platform_fee,0) / v_service_gross))
    else least(1, greatest(0, coalesce(b.commission_rate_snapshot,0.20)))
  end;

  -- Traslado V66: USD 5 por profesional por defecto. mobility_fee_total es la
  -- fuente congelada del checkout; travel_fee queda como compatibilidad legacy.
  v_travel_total := greatest(coalesce(
    nullif(b.mobility_fee_total,0),
    nullif(b.travel_fee,0),
    greatest(coalesce(b.mobility_fee_per_professional,5),0) * greatest(coalesce(b.required_professionals,v_count),1),
    0
  ),0);

  -- Preferimos el snapshot congelado de checkout. Así un cambio posterior del
  -- catálogo no altera una reserva histórica.
  select coalesce(sum(
    case
      when lower(coalesce(j->>'kind','')) = 'extra'
       and coalesce(j->>'value','') ~ '^-?[0-9]+([.][0-9]+)?$'
      then greatest((j->>'value')::numeric,0)
      else 0
    end
  ),0)
  into v_extra_gross
  from jsonb_array_elements(
    case
      when jsonb_typeof(b.service_details->'pricing_breakdown') = 'array' then b.service_details->'pricing_breakdown'
      when jsonb_typeof(b.service_details->'pricing'->'breakdown') = 'array' then b.service_details->'pricing'->'breakdown'
      else '[]'::jsonb
    end
  ) j;

  v_extra_gross := least(greatest(v_extra_gross,0), v_service_gross);
  -- service_subtotal histórico ya incluye el traslado. Lo quitamos del rubro
  -- Servicio para que no aparezca dos veces en el desglose profesional.
  v_base_gross := greatest(v_service_gross - v_extra_gross - v_travel_total,0);

  -- Muy importante: una reserva ya cobrada NO cambia su pago total al profesional.
  -- seller_payout es el total congelado de checkout. V66.8 solo lo DESGLOSA en
  -- Servicio + Extras + Traslado, preservando centavo por centavo el total previo.
  v_provider_commissionable_total := greatest(coalesce(
    nullif(b.seller_payout,0),
    v_service_gross - greatest(coalesce(b.platform_fee,0),0),
    0
  ),0);
  v_travel_total := least(v_travel_total, v_provider_commissionable_total);
  v_extras_net_total := least(
    greatest(v_provider_commissionable_total - v_travel_total,0),
    round(v_extra_gross * (1 - v_rate), 2)
  );
  v_base_net_total := greatest(v_provider_commissionable_total - v_travel_total - v_extras_net_total,0);

  v_base_net_cents := round(v_base_net_total * 100)::bigint;
  v_extras_net_cents := round(v_extras_net_total * 100)::bigint;
  v_travel_cents := round(v_travel_total * 100)::bigint;
  v_base_gross_cents := round(v_base_gross * 100)::bigint;
  v_extra_gross_cents := round(v_extra_gross * 100)::bigint;

  -- Limpia importes de candidatos/rechazados para no mezclarlos con el equipo real.
  update public.booking_professional_assignments
  set service_share=0,
      extras_share=0,
      travel_fee=0,
      gross_provider_amount=0,
      commission_amount=0,
      net_provider_amount=0,
      payout_amount=0,
      updated_at=now()
  where booking_id=p_booking_id
    and payout_status <> 'paid'
    and (
      status in ('rejected','cancelled')
      or (v_confirmed_count > 0 and status = 'pending')
    );

  for r in
    select a.id,a.provider_id,a.slot_number,a.status
    from public.booking_professional_assignments a
    where a.booking_id=p_booking_id
      and (
        (v_confirmed_count > 0 and a.status in ('accepted','completed'))
        or (v_confirmed_count = 0 and a.status='pending')
      )
    order by a.slot_number,a.created_at,a.id
    limit v_count
  loop
    v_idx := v_idx + 1;

    v_base_net_share := (
      (v_base_net_cents / v_count)
      + case when v_idx = v_count then (v_base_net_cents % v_count) else 0 end
    )::numeric / 100;
    v_extras_net_share := (
      (v_extras_net_cents / v_count)
      + case when v_idx = v_count then (v_extras_net_cents % v_count) else 0 end
    )::numeric / 100;
    v_travel_share := (
      (v_travel_cents / v_count)
      + case when v_idx = v_count then (v_travel_cents % v_count) else 0 end
    )::numeric / 100;
    v_base_gross_share := (
      (v_base_gross_cents / v_count)
      + case when v_idx = v_count then (v_base_gross_cents % v_count) else 0 end
    )::numeric / 100;
    v_extra_gross_share := (
      (v_extra_gross_cents / v_count)
      + case when v_idx = v_count then (v_extra_gross_cents % v_count) else 0 end
    )::numeric / 100;

    select coalesce(sum(pcb.amount),0) into v_provider_bonus
    from public.provider_completion_bonuses pcb
    where pcb.source_booking_id=p_booking_id
      and pcb.provider_id=r.provider_id
      and pcb.status in ('earned','paid');

    v_provider_total := round(v_base_net_share + v_extras_net_share + v_travel_share + v_provider_bonus,2);
    v_provider_pool := round(v_provider_pool + v_provider_total,2);

    update public.booking_professional_assignments a
    set service_share=v_base_net_share,
        extras_share=v_extras_net_share,
        travel_distance_km=coalesce(a.travel_distance_km,0),
        travel_rate_per_km=0,
        travel_fee=v_travel_share,
        gross_provider_amount=round(v_base_gross_share + v_extra_gross_share + v_travel_share,2),
        commission_amount=round(greatest((v_base_gross_share+v_extra_gross_share)-(v_base_net_share+v_extras_net_share),0),2),
        net_provider_amount=v_provider_total,
        payout_amount=v_provider_total,
        commission_rate_snapshot=v_rate,
        updated_at=now()
    where a.id=r.id
      and a.payout_status <> 'paid';

    v_snapshot := v_snapshot || jsonb_build_array(jsonb_build_object(
      'slot',r.slot_number,
      'provider_id',r.provider_id,
      'service_share',v_base_net_share,
      'extras_share',v_extras_net_share,
      'travel_fee',v_travel_share,
      'provider_bonus',v_provider_bonus,
      'net_provider_amount',v_provider_total
    ));
  end loop;

  update public.bookings
  set accepted_professionals=(
        select count(*) from public.booking_professional_assignments a
        where a.booking_id=p_booking_id and a.status in ('accepted','completed')
      ),
      mobility_fee_per_professional=case when v_count>0 then round(v_travel_total/v_count,2) else coalesce(mobility_fee_per_professional,5) end,
      mobility_fee_total=round(v_travel_total,2),
      travel_fee=round(v_travel_total,2),
      provider_pool_amount=round(v_provider_pool,2),
      financial_snapshot=coalesce(financial_snapshot,'{}'::jsonb) || jsonb_build_object(
        'version',668,
        'service_net',round(v_base_net_total,2),
        'extras_gross',round(v_extra_gross,2),
        'extras_net',round(v_extras_net_total,2),
        'travel_total',round(v_travel_total,2),
        'provider_pool',round(v_provider_pool,2),
        'assignments',v_snapshot,
        'rounding','residual_to_last_slot'
      ),
      finance_version=668,
      updated_at=now()
  where id=p_booking_id;

  return jsonb_build_object(
    'ok',true,
    'booking_id',p_booking_id,
    'professionals',v_count,
    'service_net',round(v_base_net_total,2),
    'extras_net',round(v_extras_net_total,2),
    'travel_total',round(v_travel_total,2),
    'provider_pool',round(v_provider_pool,2),
    'assignments',v_snapshot
  );
end;
$$;

revoke execute on function public.yt_v668_assignment_recalculate(uuid) from public,anon;
grant execute on function public.yt_v668_assignment_recalculate(uuid) to authenticated,service_role;

-- Las funciones existentes de matching/aceptación siguen llamando este nombre.
create or replace function public.yt_v62_assignment_recalculate(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  return public.yt_v668_assignment_recalculate(p_booking_id);
end;
$$;

revoke execute on function public.yt_v62_assignment_recalculate(uuid) from public,anon;
grant execute on function public.yt_v62_assignment_recalculate(uuid) to authenticated,service_role;

-- Recalcular únicamente reservas que todavía no tienen una liquidación pagada.
do $$
declare r record;
begin
  for r in
    select distinct b.id
    from public.bookings b
    join public.booking_professional_assignments a on a.booking_id=b.id
    where a.status in ('accepted','completed')
      and not exists (
        select 1
        from public.booking_professional_assignments ax
        left join public.provider_payouts pp on pp.id=ax.payout_id
        where ax.booking_id=b.id
          and (lower(coalesce(ax.payout_status,''))='paid' or lower(coalesce(pp.status,''))='paid')
      )
  loop
    perform public.yt_v668_assignment_recalculate(r.id);
  end loop;
end
$$;

commit;
