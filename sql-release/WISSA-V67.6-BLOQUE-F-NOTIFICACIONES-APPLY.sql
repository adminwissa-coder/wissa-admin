begin;

-- WISSA V67.6 · Bloque F · Notificaciones de Acompañamiento
-- Incremental sobre V67.5. No borra usuarios, reservas, pagos ni históricos.
-- Objetivo: asegurar que notificación interna y push usen la misma copia de negocio.

create or replace function public.yt_v671_accompaniment_notification_copy()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_payload jsonb := to_jsonb(new);
  v_type text := lower(coalesce(new.type,''));
  v_booking_text text;
  v_booking_id uuid;
  v_category text;
  v_amount numeric := 0;
begin
  v_booking_text := coalesce(
    nullif(v_payload->>'related_booking_id',''),
    nullif(v_payload->>'reference_id',''),
    nullif(v_payload->>'booking_id',''),
    nullif(v_payload->'metadata'->>'booking_id','')
  );
  if v_booking_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_booking_id := v_booking_text::uuid;
  end if;
  if v_booking_id is null then return new; end if;

  select coalesce(nullif(b.service_details->>'category',''),s.category,'')
    into v_category
  from public.bookings b
  left join public.services s on s.id=b.service_id
  where b.id=v_booking_id;

  if lower(translate(v_category,'ÁÉÍÓÚÜÑáéíóúüñ','AEIOUUNaeiouun')) not like '%acompanamiento%' then
    return new;
  end if;

  begin
    v_amount := coalesce(nullif(v_payload->'metadata'->>'provider_share','')::numeric,0);
  exception when others then
    v_amount := 0;
  end;

  if v_type in ('booking_created','provider_new_booking','booking_request') then
    new.title := 'Nueva solicitud de acompañamiento';
    new.body := 'Tienes una nueva solicitud de acompañamiento. Revisa el plan, horario y punto de encuentro antes de responder.';
  elsif v_type in ('booking_paid','booking_pending_acceptance','payment_approved','payment_received','yappy_payment_approved') then
    new.title := 'Pago confirmado';
    new.body := 'Tu pago de Acompañamiento fue confirmado. La solicitud continuará con la persona que elegiste.';
  elsif v_type='booking_candidates_selected' then
    new.title := 'Solicitud de acompañamiento enviada';
    new.body := 'La persona que elegiste ya recibió tu solicitud. Te avisaremos cuando confirme.';
  elsif v_type='booking_accepted' then
    new.title := 'Acompañamiento confirmado';
    new.body := 'Tu acompañamiento está confirmado. Revisa la reserva para ver el horario y punto de encuentro.';
  elsif v_type in ('booking_rejected','booking_reassign') then
    new.title := 'Necesitamos otra opción';
    new.body := 'La persona elegida no pudo confirmar tu acompañamiento. Revisa la reserva para continuar con otra persona disponible.';
  elsif v_type='booking_closed' then
    new.title := 'Solicitud de acompañamiento cubierta';
    new.body := 'Esta solicitud ya fue confirmada. Gracias por tu disponibilidad.';
  elsif v_type='provider_en_route' then
    new.title := 'Tu acompañante va en camino';
    new.body := 'La persona que elegiste ya se dirige al punto de encuentro.';
  elsif v_type='service_started' then
    new.title := 'Acompañamiento iniciado';
    new.body := 'Tu acompañamiento ya está en curso.';
  elsif v_type='booking_confirmation_pending' then
    new.title := 'El cliente confirmó el acompañamiento';
    new.body := 'El cliente confirmó que el acompañamiento se realizó. Revisa la reserva y completa el cierre.';
  elsif v_type='booking_progress' then
    new.title := 'Acompañamiento actualizado';
    new.body := 'Se registró un avance en tu acompañamiento. Revisa la reserva para ver el estado actual.';
  elsif v_type in ('booking_completed','code_verified','code_verified_provider','code_verified_admin') then
    new.title := 'Acompañamiento finalizado';
    new.body := 'El acompañamiento finalizó. Ya puedes dejar una reseña y, si deseas, una propina.';
  elsif v_type='review_requested' then
    new.title := '¿Cómo estuvo tu acompañamiento?';
    new.body := 'Tu opinión ayuda a mantener la calidad de Wissa. Puedes dejar tu reseña desde la reserva.';
  elsif v_type='booking_cancelled' then
    new.title := 'Acompañamiento cancelado';
    new.body := 'La reserva de Acompañamiento fue cancelada. Revisa el detalle para más información.';
  elsif v_type='refund_requested' then
    new.title := 'Devolución de Acompañamiento en revisión';
    new.body := 'Recibimos tu solicitud de devolución. Te avisaremos cuando haya una actualización.';
  elsif v_type='refund_completed' then
    new.title := 'Devolución completada';
    new.body := 'La devolución correspondiente a tu Acompañamiento ya fue registrada.';
  elsif v_type='tip_received' then
    new.title := 'Recibiste una propina';
    new.body := case when v_amount > 0
      then 'Recibiste USD ' || trim(to_char(v_amount,'FM999999990.00')) || ' de propina por un Acompañamiento.'
      else 'Recibiste una propina por un Acompañamiento.' end;
  elsif v_type in ('payout_released','payout_released_admin') then
    new.title := 'Tu cobro está listo';
    new.body := 'Wissa registró el pago de tu Acompañamiento. Consulta el detalle en Finanzas.';
  elsif v_type in ('new_message','chat_message') then
    new.title := 'Nuevo mensaje sobre tu acompañamiento';
    new.body := 'Tienes un mensaje nuevo relacionado con tu Acompañamiento. Entra al chat para responder.';
  end if;

  new.metadata := coalesce(new.metadata,'{}'::jsonb) || jsonb_build_object(
    'category','Acompañamiento',
    'copy_release','V67.6'
  );
  return new;
end;
$$;

-- Mantener el trigger con el mismo nombre para no crear duplicados.
drop trigger if exists trg_zy_accompaniment_notification_copy on public.notifications;
create trigger trg_zy_accompaniment_notification_copy
before insert or update of title,body,type,related_booking_id
on public.notifications
for each row execute function public.yt_v671_accompaniment_notification_copy();

commit;
