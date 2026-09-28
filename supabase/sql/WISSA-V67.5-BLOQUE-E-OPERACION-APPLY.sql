begin;

-- WISSA V67.5 · Bloque E · Operación completa de Acompañamiento
-- Incremental sobre V67.3/V67.4. No borra usuarios, reservas, pagos ni históricos.

-- 1) Endurece la preselección previa al pago.
-- Además del snapshot de matching, respeta la preferencia Mujer/Hombre cuando exista.
create or replace function public.yt_v671_preselect_accompaniment_candidate(
  p_booking_id uuid,
  p_provider_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  b public.bookings%rowtype;
  v_category text;
  v_in_snapshot boolean := false;
  v_preference text;
  v_profile_gender text;
begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  if auth.uid() is null or auth.uid()<>b.buyer_id then raise exception 'No autorizado.'; end if;
  if coalesce(b.payment_status,'')='paid' then raise exception 'La reserva ya fue pagada.'; end if;

  select coalesce(nullif(b.service_details->>'category',''), s.category, '')
    into v_category
  from public.services s
  where s.id=b.service_id;

  if lower(v_category) not in ('acompañamiento','acompanamiento') then
    raise exception 'Esta acción solo aplica a Acompañamiento.';
  end if;

  select exists(
    select 1
    from jsonb_array_elements(coalesce(b.service_details->'matching_candidates','[]'::jsonb)) c(item)
    where nullif(c.item->>'provider_id','')::uuid = p_provider_id
  ) into v_in_snapshot;

  if not v_in_snapshot then
    raise exception 'La persona seleccionada ya no está disponible para esta reserva.';
  end if;

  select p.accompaniment_profile_gender
    into v_profile_gender
  from public.profiles p
  where p.id=p_provider_id
    and coalesce(p.is_active,true)=true
    and coalesce(p.is_suspended,false)=false
    and coalesce(p.provider_status,'approved')='approved'
    and coalesce(p.is_available,false)=true;

  if not found then
    raise exception 'La persona seleccionada ya no está disponible.';
  end if;

  v_preference := coalesce(
    nullif(b.service_details->'values'->>'accompaniment_preference',''),
    nullif(b.service_details->>'accompaniment_preference',''),
    'Sin preferencia'
  );

  if v_preference in ('Mujer','Hombre') and coalesce(v_profile_gender,'') <> v_preference then
    raise exception 'La persona seleccionada ya no coincide con la preferencia de la reserva.';
  end if;

  if not exists(
    select 1 from public.services s
    where s.provider_id=p_provider_id
      and coalesce(s.is_active,true)=true
      and lower(coalesce(s.category,'')) in ('acompañamiento','acompanamiento')
  ) then
    raise exception 'La persona seleccionada no tiene Acompañamiento disponible.';
  end if;

  update public.bookings
  set service_details = coalesce(service_details,'{}'::jsonb)
      || jsonb_build_object(
           'preselected_provider_id',p_provider_id::text,
           'preselected_provider_ids',jsonb_build_array(p_provider_id::text),
           'preselected_at',now(),
           'accompaniment_preference_validated',true
         ),
      required_professionals=1,
      selected_professionals=1,
      updated_at=now()
  where id=p_booking_id;

  return jsonb_build_object('ok',true,'booking_id',p_booking_id,'provider_id',p_provider_id,'preference',v_preference);
end;
$$;

grant execute on function public.yt_v671_preselect_accompaniment_candidate(uuid,uuid) to authenticated,service_role;

-- 2) Confirmación post-pago idempotente.
-- Evita que el cliente tenga que reconstruir manualmente el array de candidatos
-- y permite reintentar sin duplicar assignments o notificaciones.
create or replace function public.yt_v675_finalize_accompaniment_selection(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  b public.bookings%rowtype;
  v_category text;
  v_provider_text text;
  v_provider_id uuid;
  v_existing boolean := false;
  v_result jsonb;
begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  if auth.uid() is null or (auth.uid()<>b.buyer_id and not public.yt_admin_is_current_admin()) then
    raise exception 'No autorizado.';
  end if;

  select coalesce(nullif(b.service_details->>'category',''), s.category, '')
    into v_category
  from public.services s
  where s.id=b.service_id;

  if lower(v_category) not in ('acompañamiento','acompanamiento') then
    raise exception 'Esta acción solo aplica a Acompañamiento.';
  end if;
  if coalesce(b.payment_status,'') <> 'paid' then
    raise exception 'Primero completa el pago de la reserva.';
  end if;

  select exists(
    select 1
    from public.booking_professional_assignments a
    where a.booking_id=p_booking_id and a.status in ('pending','accepted','completed')
  ) into v_existing;

  if v_existing and coalesce(b.candidate_selection_status,'') in ('waiting_acceptance','completed','accepted') then
    return jsonb_build_object('ok',true,'already_sent',true,'booking_id',p_booking_id);
  end if;

  v_provider_text := coalesce(
    nullif(b.service_details->>'preselected_provider_id',''),
    nullif(b.service_details->'preselected_provider_ids'->>0,'')
  );

  if v_provider_text is null or v_provider_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'Selecciona una persona disponible antes de continuar.';
  end if;
  v_provider_id := v_provider_text::uuid;

  -- Revalida que la persona siga habilitada para Acompañamiento.
  if not exists(
    select 1
    from public.profiles p
    join public.services s on s.provider_id=p.id
    where p.id=v_provider_id
      and coalesce(p.is_active,true)=true
      and coalesce(p.is_suspended,false)=false
      and coalesce(p.provider_status,'approved')='approved'
      and coalesce(p.is_available,false)=true
      and coalesce(s.is_active,true)=true
      and lower(coalesce(s.category,'')) in ('acompañamiento','acompanamiento')
  ) then
    raise exception 'La persona seleccionada ya no está disponible. Elige otra opción.';
  end if;

  v_result := public.yt_v64_select_booking_candidates(p_booking_id,array[v_provider_id]);

  update public.bookings
  set service_details=coalesce(service_details,'{}'::jsonb)
      || jsonb_build_object('accompaniment_request_sent_at',now(),'accompaniment_selected_provider_id',v_provider_id::text),
      updated_at=now()
  where id=p_booking_id;

  return coalesce(v_result,'{}'::jsonb) || jsonb_build_object(
    'ok',true,
    'already_sent',false,
    'booking_id',p_booking_id,
    'provider_id',v_provider_id
  );
end;
$$;

grant execute on function public.yt_v675_finalize_accompaniment_selection(uuid) to authenticated,service_role;

commit;
