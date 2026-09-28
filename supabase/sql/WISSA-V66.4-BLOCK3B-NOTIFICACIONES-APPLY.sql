begin;

-- WISSA V66.4 / BLOQUE 3B
-- Notificaciones idempotentes + múltiples dispositivos + fallback push desde DB.
-- No borra usuarios ni reservas.

-- -----------------------------------------------------------------------------
-- 1. Registro multi-dispositivo de tokens push
-- -----------------------------------------------------------------------------
create table if not exists public.user_push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  token text not null,
  platform text,
  device_name text,
  app_version text,
  is_active boolean not null default true,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists user_push_tokens_user_token_uidx
  on public.user_push_tokens(user_id, token);
create index if not exists user_push_tokens_active_idx
  on public.user_push_tokens(user_id, is_active, last_seen_at desc);

alter table public.user_push_tokens enable row level security;

drop policy if exists user_push_tokens_select_own_v664 on public.user_push_tokens;
create policy user_push_tokens_select_own_v664
on public.user_push_tokens for select to authenticated
using (user_id = auth.uid());

drop policy if exists user_push_tokens_insert_own_v664 on public.user_push_tokens;
create policy user_push_tokens_insert_own_v664
on public.user_push_tokens for insert to authenticated
with check (user_id = auth.uid());

drop policy if exists user_push_tokens_update_own_v664 on public.user_push_tokens;
create policy user_push_tokens_update_own_v664
on public.user_push_tokens for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists user_push_tokens_delete_own_v664 on public.user_push_tokens;
create policy user_push_tokens_delete_own_v664
on public.user_push_tokens for delete to authenticated
using (user_id = auth.uid());

grant select, insert, update, delete on public.user_push_tokens to authenticated;
grant all on public.user_push_tokens to service_role;

-- Migrar el token legado actual sin romper compatibilidad.
insert into public.user_push_tokens(user_id, token, platform, device_name, app_version, is_active, last_seen_at, updated_at)
select p.id, p.push_token, null, 'token legado', null, true, now(), now()
from public.profiles p
where nullif(trim(coalesce(p.push_token,'')), '') is not null
  and (p.push_token like 'ExponentPushToken[%]' or p.push_token like 'ExpoPushToken[%]')
on conflict (user_id, token) do update
set is_active = true,
    last_seen_at = now(),
    updated_at = now();

-- -----------------------------------------------------------------------------
-- 2. Metadatos de idempotencia y entrega en notifications
-- -----------------------------------------------------------------------------
alter table public.notifications add column if not exists notification_key text;
alter table public.notifications add column if not exists delivery_status text not null default 'internal';
alter table public.notifications add column if not exists push_attempted_at timestamptz;
alter table public.notifications add column if not exists push_sent_at timestamptz;
alter table public.notifications add column if not exists push_last_error text;

alter table public.notifications drop constraint if exists notifications_delivery_status_check;
alter table public.notifications
  add constraint notifications_delivery_status_check
  check (delivery_status in ('internal','queued','sent','skipped','failed')) not valid;
alter table public.notifications validate constraint notifications_delivery_status_check;

create index if not exists notifications_user_notification_key_idx
  on public.notifications(user_id, notification_key)
  where notification_key is not null;
create index if not exists notifications_delivery_status_created_idx
  on public.notifications(delivery_status, created_at desc);

-- Estado queued para envíos lanzados asíncronamente desde PostgreSQL/pg_net.
alter table public.push_notification_logs drop constraint if exists push_notification_logs_status_check;
alter table public.push_notification_logs
  add constraint push_notification_logs_status_check
  check (status in ('pending','queued','sent','failed','skipped')) not valid;
alter table public.push_notification_logs validate constraint push_notification_logs_status_check;
alter table public.push_notification_logs add column if not exists idempotency_key text;
alter table public.push_notification_logs add column if not exists transport text;
alter table public.push_notification_logs add column if not exists token_suffix text;
create index if not exists push_notification_logs_idempotency_idx
  on public.push_notification_logs(idempotency_key, created_at desc)
  where idempotency_key is not null;

-- -----------------------------------------------------------------------------
-- 3. Clave canónica de evento. Evita que diferentes caminos del flujo creen
--    avisos repetidos de la misma etapa.
-- -----------------------------------------------------------------------------
create or replace function public.yt_notification_key_v664(
  p_related_booking_id uuid,
  p_type text,
  p_title text,
  p_body text,
  p_metadata jsonb default '{}'::jsonb,
  p_explicit_key text default null
) returns text
language plpgsql
immutable
as $$
declare
  v_type text := lower(trim(coalesce(p_type,'')));
  v_booking text := coalesce(p_related_booking_id::text, nullif(p_metadata->>'booking_id',''));
  v_family text;
  v_stage text := '';
begin
  if nullif(trim(coalesce(p_explicit_key,'')), '') is not null then
    return trim(p_explicit_key);
  end if;

  if v_type in ('booking_paid','payment_approved','payment_received','yappy_payment_approved') then
    v_family := 'payment_confirmed';
  elsif v_type in ('booking_completed','code_verified','code_verified_provider','code_verified_admin') then
    v_family := 'booking_completed';
  elsif v_type in ('payout_released','payout_released_admin') then
    v_family := 'payout_released';
  elsif v_type in ('booking_rejected','booking_reassign') then
    v_family := 'booking_reassignment';
  elsif v_type in ('new_message','chat_message') then
    v_family := 'chat_message';
  else
    v_family := nullif(v_type,'');
  end if;

  if v_family is null then
    return null;
  end if;

  if v_family = 'chat_message' then
    v_stage := coalesce(nullif(p_metadata->>'message_id',''), nullif(p_metadata->>'event_id',''));
    if v_stage is null then return null; end if;
  elsif v_type = 'booking_accepted' then
    -- La RPC histórica y el trigger V66.4 pueden describir la misma aceptación
    -- con metadatos distintos. El contador accepted es el estado canónico.
    v_stage := coalesce(
      nullif(p_metadata->>'accepted',''),
      nullif(p_metadata->>'assignment_id',''),
      nullif(p_metadata->>'provider_id',''),
      md5(coalesce(p_title,'') || '|' || coalesce(p_body,''))
    );
  elsif v_type = 'booking_progress' then
    v_stage := coalesce(
      nullif(p_metadata->>'assignment_id',''),
      nullif(p_metadata->>'provider_id',''),
      nullif(p_metadata->>'completed',''),
      md5(coalesce(p_title,'') || '|' || coalesce(p_body,''))
    );
  elsif v_type in ('booking_candidates_selected','booking_request') then
    -- Una invitación por profesional/usuario y ronda. La RPC antigua no adjunta
    -- assignment_id, mientras el trigger sí; usar ronda evita el doble aviso.
    v_stage := coalesce(
      nullif(p_metadata->>'round',''),
      nullif(p_metadata->>'candidate_round',''),
      nullif(p_metadata->>'assignment_id',''),
      ''
    );
  elsif v_family = 'booking_reassignment' then
    v_stage := coalesce(nullif(p_metadata->>'provider_id',''), nullif(p_metadata->>'assignment_id',''), 'team');
  elsif v_family = 'payout_released' then
    v_stage := coalesce(nullif(p_metadata->>'payout_id',''), nullif(p_metadata->>'assignment_id',''), nullif(p_metadata->>'assignment_slot',''), 'booking');
  elsif v_type = 'tip_received' then
    v_stage := coalesce(nullif(p_metadata->>'tip_id',''), nullif(p_metadata->>'allocation_id',''), 'tip');
  elsif v_type = 'booking_update' then
    v_stage := coalesce(nullif(p_metadata->>'event_id',''), md5(coalesce(p_title,'') || '|' || coalesce(p_body,'')));
  end if;

  if v_booking is not null and v_booking <> '' then
    return v_booking || ':' || v_family || ':' || coalesce(v_stage,'');
  end if;

  if nullif(p_metadata->>'event_id','') is not null then
    return v_family || ':' || (p_metadata->>'event_id');
  end if;

  return null;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Copia profesional centralizada. Reemplaza textos técnicos/antiguos.
-- -----------------------------------------------------------------------------
create or replace function public.yt_apply_wissa_notification_copy()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payload jsonb := to_jsonb(new);
  v_type text := lower(coalesce(new.type, ''));
  v_booking_id_text text;
  v_booking_id uuid;
  v_service_title text := 'tu servicio';
  v_client_name text := 'El cliente';
  v_provider_name text := 'Un profesional';
  v_amount numeric;
  v_accepted integer := 0;
  v_required integer := 0;
begin
  v_booking_id_text := coalesce(
    nullif(v_payload->>'related_booking_id', ''),
    nullif(v_payload->>'reference_id', ''),
    nullif(v_payload->>'booking_id', ''),
    nullif(v_payload->'metadata'->>'booking_id','')
  );

  if v_booking_id_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_booking_id := v_booking_id_text::uuid;
  end if;

  if v_booking_id is not null then
    select
      coalesce(nullif(b.service_title, ''), nullif(s.title, ''), 'tu servicio'),
      coalesce(nullif(client.full_name, ''), nullif(client.display_name, ''), nullif(client.email, ''), 'El cliente'),
      coalesce(nullif(provider.full_name, ''), nullif(provider.display_name, ''), nullif(provider.email, ''), 'Un profesional'),
      coalesce(nullif(b.total_amount, 0), nullif(b.price_snapshot, 0), 0)
    into v_service_title, v_client_name, v_provider_name, v_amount
    from public.bookings b
    left join public.services s on s.id = b.service_id
    left join public.profiles client on client.id = b.buyer_id
    left join public.profiles provider on provider.id = coalesce(
      nullif(v_payload->'metadata'->>'provider_id','')::uuid,
      b.provider_id,
      b.winner_provider_id
    )
    where b.id = v_booking_id
    limit 1;
  end if;

  begin v_accepted := coalesce((v_payload->'metadata'->>'accepted')::integer,0); exception when others then v_accepted := 0; end;
  begin v_required := coalesce((v_payload->'metadata'->>'required')::integer,0); exception when others then v_required := 0; end;

  if v_type in ('payout_released_admin', 'payout_released') then
    new.title := 'Tu cobro está listo';
    new.body := 'Wissa registró el pago de ' || v_service_title || '. Consulta el detalle en Finanzas.';
  elsif v_type in ('booking_paid', 'booking_pending_acceptance', 'payment_approved', 'payment_received', 'yappy_payment_approved') then
    new.title := 'Pago confirmado';
    new.body := 'Recibimos tu pago de ' || v_service_title || '. Ya puedes continuar con la selección de profesionales.';
  elsif v_type in ('booking_created', 'provider_new_booking', 'booking_request') then
    new.title := 'Nueva solicitud de servicio';
    new.body := v_client_name || ' te envió una solicitud para ' || v_service_title || '. Revisa la fecha, ubicación y detalles antes de responder.';
  elsif v_type = 'booking_candidates_selected' then
    new.title := 'Solicitudes enviadas';
    new.body := 'Los profesionales seleccionados ya recibieron tu solicitud. Te avisaremos a medida que confirmen.';
  elsif v_type = 'booking_accepted' then
    if v_required > 1 and v_accepted > 0 and v_accepted < v_required then
      new.title := 'Tu equipo está tomando forma';
      new.body := v_accepted || ' de ' || v_required || ' profesionales ya confirmaron. Te avisaremos cuando el equipo esté completo.';
    else
      new.title := 'Servicio confirmado';
      new.body := case when v_required > 1 then 'Tu equipo ya está completo para ' || v_service_title || '.' else v_provider_name || ' confirmó ' || v_service_title || '. Ya puedes coordinar los detalles.' end;
    end if;
  elsif v_type in ('booking_rejected', 'booking_reassign') then
    new.title := 'Seguimos coordinando tu servicio';
    new.body := 'Uno de los profesionales no pudo confirmar. Tu reserva continúa activa mientras Wissa coordina una alternativa.';
  elsif v_type = 'booking_closed' then
    new.title := 'Esta solicitud ya fue cubierta';
    new.body := 'El equipo para ' || v_service_title || ' ya está completo. Gracias por tu disponibilidad.';
  elsif v_type = 'booking_confirmation_pending' then
    new.title := 'El cliente confirmó el servicio';
    new.body := v_client_name || ' confirmó que ' || v_service_title || ' se realizó. Revisa la reserva y completa el cierre.';
  elsif v_type = 'booking_progress' then
    new.title := 'Avance del servicio';
    new.body := 'Un profesional completó su parte. El servicio finalizará cuando todo el equipo complete su asignación.';
  elsif v_type in ('booking_completed', 'code_verified', 'code_verified_provider', 'code_verified_admin') then
    new.title := 'Servicio finalizado';
    new.body := 'El servicio de ' || v_service_title || ' fue completado. Ya puedes revisar el detalle final.';
  elsif v_type = 'provider_en_route' then
    new.title := 'Tu profesional va en camino';
    new.body := 'El profesional ya se dirige a la ubicación del servicio.';
  elsif v_type = 'service_started' then
    new.title := 'Servicio iniciado';
    new.body := 'Tu servicio ya está en proceso.';
  elsif v_type = 'booking_cancelled' then
    new.title := 'Reserva cancelada';
    new.body := 'Se canceló ' || v_service_title || '. Consulta el detalle de la reserva para más información.';
  elsif v_type = 'refund_requested' then
    new.title := 'Solicitud de devolución recibida';
    new.body := 'Estamos revisando la devolución de ' || v_service_title || '. Te avisaremos cuando haya una actualización.';
  elsif v_type = 'refund_completed' then
    new.title := 'Devolución completada';
    new.body := 'La devolución de ' || v_service_title || ' ya fue registrada.';
  elsif v_type in ('new_message', 'chat_message') and v_booking_id is not null then
    new.title := 'Nuevo mensaje';
    new.body := 'Tienes un mensaje nuevo sobre ' || v_service_title || '. Entra al chat para responder.';
  elsif v_type = 'tip_received' then
    new.title := 'Recibiste una propina';
    new.body := case when nullif(v_payload->'metadata'->>'provider_share','') is not null
      then 'Recibiste USD ' || to_char((v_payload->'metadata'->>'provider_share')::numeric,'FM999999990.00') || ' de propina por ' || v_service_title || '.'
      else 'Recibiste una propina por ' || v_service_title || '.' end;
  elsif v_type = 'review_requested' then
    new.title := '¿Cómo estuvo tu servicio?';
    new.body := 'Tu opinión ayuda a mantener la calidad de Wissa. Puedes dejar tu reseña desde la reserva.';
  end if;

  return new;
end;
$$;

-- Asegurar que la copia se aplique antes del guard de idempotencia.
drop trigger if exists trg_wissa_notification_copy on public.notifications;
create trigger trg_wissa_notification_copy
before insert or update of title, body, type, related_booking_id
on public.notifications
for each row execute function public.yt_apply_wissa_notification_copy();

-- -----------------------------------------------------------------------------
-- 5. Guard central: pago nunca va a Ofrecer + dedupe transaccional.
-- -----------------------------------------------------------------------------
drop trigger if exists trg_wissa_notification_guard_v6493 on public.notifications;
drop trigger if exists trg_zz_wissa_notification_guard_v664 on public.notifications;

create or replace function public.wissa_notification_guard_v664()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_is_provider_for_booking boolean := false;
  v_existing_id uuid;
  v_key text;
begin
  if new.related_booking_id is not null then
    select exists(
      select 1
      from public.bookings b
      left join public.profiles p on p.id = new.user_id
      where b.id = new.related_booking_id
        and b.buyer_id is distinct from new.user_id
        and (
             b.provider_id = new.user_id
          or b.winner_provider_id = new.user_id
          or exists(select 1 from public.booking_professional_assignments a where a.booking_id=b.id and a.provider_id=new.user_id)
          or coalesce(p.role,'')='provider'
          or coalesce(p.account_type,'')='provider'
          or coalesce(p.mode_preference,'')='provider'
        )
    ) into v_is_provider_for_booking;
  end if;

  if v_is_provider_for_booking and lower(coalesce(new.type,'')) in ('booking_paid','payment_received','payment_approved','yappy_payment_approved') then
    return null;
  end if;

  -- Completar la ronda en eventos de coordinación antiguos que no la traían.
  if new.related_booking_id is not null
     and lower(coalesce(new.type,'')) in ('booking_rejected','booking_reassign','booking_request','booking_candidates_selected')
     and nullif(coalesce(new.metadata,'{}'::jsonb)->>'round','') is null then
    new.metadata := coalesce(new.metadata,'{}'::jsonb) || jsonb_build_object(
      'round', coalesce((select b.candidate_round from public.bookings b where b.id=new.related_booking_id),0)
    );
  end if;

  v_key := public.yt_notification_key_v664(new.related_booking_id,new.type,new.title,new.body,coalesce(new.metadata,'{}'::jsonb),new.notification_key);
  new.notification_key := v_key;

  if v_key is not null then
    perform pg_advisory_xact_lock(hashtext(new.user_id::text || ':' || v_key));
    select id into v_existing_id
    from public.notifications
    where user_id = new.user_id and notification_key = v_key
    order by created_at desc limit 1;

    if v_existing_id is not null then
      update public.notifications
      set title = new.title,
          body = new.body,
          screen = coalesce(new.screen, screen),
          related_booking_id = coalesce(new.related_booking_id, related_booking_id),
          metadata = coalesce(metadata,'{}'::jsonb) || coalesce(new.metadata,'{}'::jsonb)
      where id = v_existing_id;
      return null;
    end if;
  end if;

  return new;
end;
$$;

create trigger trg_zz_wissa_notification_guard_v664
before insert on public.notifications
for each row execute function public.wissa_notification_guard_v664();

-- Backfill de claves para avisos actuales. No borramos historial; marcamos como
-- duplicado lógico las copias antiguas repetidas y las archivamos.
update public.notifications n
set notification_key = public.yt_notification_key_v664(n.related_booking_id,n.type,n.title,n.body,n.metadata,n.notification_key)
where n.notification_key is null;

with ranked as (
  select id,
         first_value(id) over(partition by user_id,notification_key order by created_at desc,id desc) as keep_id,
         row_number() over(partition by user_id,notification_key order by created_at desc,id desc) as rn
  from public.notifications
  where notification_key is not null and deleted_at is null
)
update public.notifications n
set archived_at = coalesce(n.archived_at, now()),
    metadata = coalesce(n.metadata,'{}'::jsonb) || jsonb_build_object('duplicate_of',r.keep_id,'deduped_by','v66.4')
from ranked r
where n.id=r.id and r.rn>1;

-- -----------------------------------------------------------------------------
-- 6. RPC server-side usada por send-push. Devuelve el registro canónico aunque
--    un trigger legado intente insertar la misma etapa.
-- -----------------------------------------------------------------------------
create or replace function public.yt_notification_upsert_v664(
  p_user_id uuid,
  p_title text,
  p_body text,
  p_type text default null,
  p_screen text default null,
  p_related_booking_id uuid default null,
  p_metadata jsonb default '{}'::jsonb,
  p_notification_key text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key text;
  v_id uuid;
  v_inserted boolean := false;
  v_row public.notifications%rowtype;
begin
  if p_user_id is null then raise exception 'Usuario destino requerido.'; end if;
  if nullif(trim(coalesce(p_title,'')),'') is null or nullif(trim(coalesce(p_body,'')),'') is null then
    raise exception 'Título y mensaje requeridos.';
  end if;

  v_key := public.yt_notification_key_v664(p_related_booking_id,p_type,p_title,p_body,coalesce(p_metadata,'{}'::jsonb),p_notification_key);
  if v_key is not null then
    perform pg_advisory_xact_lock(hashtext(p_user_id::text || ':' || v_key));
    select id into v_id from public.notifications where user_id=p_user_id and notification_key=v_key order by created_at desc limit 1;
  end if;

  if v_id is null then
    insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read,notification_key)
    values(p_user_id,p_title,p_body,p_type,p_screen,p_related_booking_id,coalesce(p_metadata,'{}'::jsonb),false,v_key)
    returning id into v_id;
    v_inserted := v_id is not null;

    -- Si el guard encontró una copia equivalente creada por otro camino, el
    -- INSERT puede quedar suprimido. Recuperar el canónico.
    if v_id is null and v_key is not null then
      select id into v_id from public.notifications where user_id=p_user_id and notification_key=v_key order by created_at desc limit 1;
    end if;
  else
    update public.notifications
    set title=p_title,
        body=p_body,
        screen=coalesce(p_screen,screen),
        related_booking_id=coalesce(p_related_booking_id,related_booking_id),
        metadata=coalesce(metadata,'{}'::jsonb)||coalesce(p_metadata,'{}'::jsonb)
    where id=v_id;
  end if;

  if v_id is null then raise exception 'No se pudo registrar la notificación.'; end if;
  select * into v_row from public.notifications where id=v_id;

  return jsonb_build_object(
    'ok',true,
    'id',v_row.id,
    'inserted',v_inserted,
    'notification_key',v_row.notification_key,
    'delivery_status',v_row.delivery_status,
    'push_sent_at',v_row.push_sent_at,
    'deleted',v_row.deleted_at is not null
  );
end;
$$;
revoke execute on function public.yt_notification_upsert_v664(uuid,text,text,text,text,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.yt_notification_upsert_v664(uuid,text,text,text,text,uuid,jsonb,text) to service_role;

-- Compatibilidad: los Edge Functions históricos llaman notify_user(). Desde V66.4
-- esa función usa el mismo guard canónico en lugar de crear otra fila paralela.
create or replace function public.notify_user(
  p_user_id uuid,
  p_title text,
  p_body text,
  p_type text default null,
  p_screen text default null,
  p_related_booking_id uuid default null,
  p_metadata jsonb default '{}'::jsonb,
  p_dedupe_key text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_result jsonb;
  v_id uuid;
begin
  if p_user_id is null then return null; end if;

  v_result := public.yt_notification_upsert_v664(
    p_user_id,
    coalesce(nullif(trim(p_title),''),'Notificación'),
    coalesce(p_body,''),
    p_type,
    p_screen,
    p_related_booking_id,
    coalesce(p_metadata,'{}'::jsonb) || case when p_dedupe_key is not null then jsonb_build_object('legacy_dedupe_key',p_dedupe_key) else '{}'::jsonb end,
    null
  );
  begin v_id := (v_result->>'id')::uuid; exception when others then v_id := null; end;
  return v_id;
end;
$$;
revoke execute on function public.notify_user(uuid,text,text,text,text,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.notify_user(uuid,text,text,text,text,uuid,jsonb,text) to service_role;

-- -----------------------------------------------------------------------------
-- 7. Fallback para notificaciones insertadas directamente por SQL/RPC heredado.
--    pg_net se usa solo para esos eventos. Los eventos enviados por send-push
--    llevan push_transport=edge y se procesan desde la Edge Function.
-- -----------------------------------------------------------------------------
do $$
begin
  begin
    execute 'create extension if not exists pg_net';
  exception when others then
    raise notice 'pg_net no pudo habilitarse automáticamente: %', sqlerrm;
  end;
end $$;

create or replace function public.yt_push_notification_after_insert_v664()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, net, pg_temp
as $$
declare
  v_token text;
  v_request_id bigint;
  v_valid integer := 0;
  v_queued integer := 0;
  v_failed integer := 0;
  v_payload jsonb;
begin
  if lower(coalesce(new.metadata->>'push_transport','')) = 'edge' then
    return new;
  end if;

  v_payload := jsonb_build_object(
    'title',new.title,
    'body',new.body,
    'sound','default',
    'channelId','default',
    'priority','high',
    'data',coalesce(new.metadata,'{}'::jsonb) || jsonb_build_object(
      'screen',coalesce(new.screen,'/main/notifications'),
      'type',coalesce(new.type,'general'),
      'relatedBookingId',new.related_booking_id,
      'notificationId',new.id,
      'notificationKey',new.notification_key
    )
  );

  for v_token in
    select distinct q.token
    from (
      select t.token
      from public.user_push_tokens t
      where t.user_id=new.user_id and t.is_active=true
      union all
      select p.push_token
      from public.profiles p
      where p.id=new.user_id and nullif(trim(coalesce(p.push_token,'')),'') is not null
    ) q
    where q.token like 'ExponentPushToken[%]' or q.token like 'ExpoPushToken[%]'
  loop
    v_valid := v_valid + 1;
    begin
      v_request_id := net.http_post(
        url := 'https://exp.host/--/api/v2/push/send',
        headers := '{"Content-Type":"application/json","Accept":"application/json"}'::jsonb,
        body := v_payload || jsonb_build_object('to',v_token)
      );
      v_queued := v_queued + 1;
      insert into public.push_notification_logs(user_id,notification_id,booking_id,title,body,type,status,response,created_at,updated_at,idempotency_key,transport,token_suffix)
      values(new.user_id,new.id,new.related_booking_id,new.title,new.body,coalesce(new.type,'general'),'queued',jsonb_build_object('request_id',v_request_id),now(),now(),new.notification_key,'database_pg_net',right(v_token,12));
    exception when others then
      v_failed := v_failed + 1;
      insert into public.push_notification_logs(user_id,notification_id,booking_id,title,body,type,status,error_message,response,created_at,updated_at,idempotency_key,transport,token_suffix)
      values(new.user_id,new.id,new.related_booking_id,new.title,new.body,coalesce(new.type,'general'),'failed',sqlerrm,'{}'::jsonb,now(),now(),new.notification_key,'database_pg_net',right(v_token,12));
    end;
  end loop;

  if v_valid=0 then
    update public.notifications set delivery_status='skipped',push_attempted_at=now(),push_last_error='No hay un dispositivo registrado para recibir notificaciones.' where id=new.id;
    insert into public.push_notification_logs(user_id,notification_id,booking_id,title,body,type,status,error_message,response,created_at,updated_at,idempotency_key,transport)
    values(new.user_id,new.id,new.related_booking_id,new.title,new.body,coalesce(new.type,'general'),'skipped','No active push token','{}'::jsonb,now(),now(),new.notification_key,'database_pg_net');
  elsif v_queued>0 then
    update public.notifications set delivery_status='queued',push_attempted_at=now(),push_last_error=case when v_failed>0 then v_failed||' dispositivo(s) no pudieron encolarse.' else null end where id=new.id;
  else
    update public.notifications set delivery_status='failed',push_attempted_at=now(),push_last_error='No se pudo encolar la notificación push.' where id=new.id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_notification_push_v664 on public.notifications;
create trigger trg_notification_push_v664
after insert on public.notifications
for each row execute function public.yt_push_notification_after_insert_v664();

-- -----------------------------------------------------------------------------
-- 8. Eventos de flujo que antes dependían de que una pantalla Mobile enviara el
--    push. Desde ahora el cambio real de BD genera el aviso.
-- -----------------------------------------------------------------------------
create or replace function public.yt_notify_assignment_flow_v664()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  b public.bookings%rowtype;
  v_accepted integer := 0;
  v_required integer := 1;
  v_remaining integer := 0;
  v_type text;
  v_title text;
  v_body text;
begin
  select * into b from public.bookings where id=new.booking_id;
  if not found then return new; end if;

  v_required := greatest(1,coalesce(b.required_professionals,1));

  -- Nueva invitación: solo cuando la reserva ya está pagada.
  if tg_op='INSERT' and lower(coalesce(new.status,'')) in ('pending','selected','invited') and lower(coalesce(b.payment_status,''))='paid' then
    insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read)
    values(new.provider_id,'Nueva solicitud de servicio','Tienes una nueva solicitud en Wissa.','booking_request','/main/booking/'||b.id,b.id,
      jsonb_build_object('assignment_id',new.id,'provider_id',new.provider_id,'round',coalesce(b.candidate_round,0)),false);
    return new;
  end if;

  if tg_op='UPDATE' and old.status is distinct from new.status then
    if lower(coalesce(new.status,''))='accepted' then
      select count(*) into v_accepted from public.booking_professional_assignments where booking_id=b.id and status='accepted';
      insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read)
      values(b.buyer_id,'Servicio confirmado','Un profesional confirmó tu servicio.','booking_accepted','/main/booking/'||b.id,b.id,
        jsonb_build_object('assignment_id',new.id,'provider_id',new.provider_id,'accepted',v_accepted,'required',v_required),false);
    elsif lower(coalesce(new.status,'')) in ('rejected','cancelled') and lower(coalesce(old.status,'')) in ('pending','selected','invited','accepted') then
      insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read)
      values(b.buyer_id,'Seguimos coordinando tu servicio','Uno de los profesionales no pudo continuar.','booking_reassign','/main/booking/'||b.id,b.id,
        jsonb_build_object('assignment_id',new.id,'provider_id',new.provider_id),false);
    elsif lower(coalesce(new.status,''))='completed' and lower(coalesce(old.status,''))<>'completed' then
      select count(*) into v_remaining from public.booking_professional_assignments where booking_id=b.id and status='accepted';
      v_type := case when v_remaining=0 then 'booking_completed' else 'booking_progress' end;
      insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read)
      values(b.buyer_id,'Avance del servicio','Se registró el cierre de un profesional.',v_type,'/main/booking/'||b.id,b.id,
        jsonb_build_object('assignment_id',new.id,'provider_id',new.provider_id,'remaining',v_remaining,'completed',v_required-v_remaining),false);
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_notify_assignment_flow_v664 on public.booking_professional_assignments;
create trigger trg_notify_assignment_flow_v664
after insert or update of status on public.booking_professional_assignments
for each row execute function public.yt_notify_assignment_flow_v664();

create or replace function public.yt_notify_booking_participants_v664()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  r record;
  v_stage text := lower(coalesce(new.service_progress_stage,new.service_stage,''));
begin
  -- Pago confirmado: aviso únicamente al cliente. El guard evita que un aviso de
  -- pago heredado termine en la bandeja de Ofrecer.
  if old.payment_status is distinct from new.payment_status and lower(coalesce(new.payment_status,''))='paid' then
    insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read)
    values(new.buyer_id,'Pago confirmado','Recibimos tu pago.','booking_paid','/main/booking/'||new.id,new.id,
      jsonb_build_object('payment_status','paid'),false);
  end if;

  -- Cambio operativo visible para el cliente.
  if old.service_progress_stage is distinct from new.service_progress_stage then
    if v_stage in ('on_the_way','en_route') then
      insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read)
      values(new.buyer_id,'Tu profesional va en camino','El profesional ya se dirige a la ubicación del servicio.','provider_en_route','/main/booking/'||new.id,new.id,
        jsonb_build_object('stage','on_the_way'),false);
    elsif v_stage in ('in_service','arrived') then
      insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read)
      values(new.buyer_id,'Servicio iniciado','Tu servicio ya está en proceso.','service_started','/main/booking/'||new.id,new.id,
        jsonb_build_object('stage','in_service'),false);
    end if;
  end if;

  -- El cliente inicia el cierre: avisar a TODOS los profesionales confirmados.
  if old.buyer_confirmed is distinct from new.buyer_confirmed and coalesce(new.buyer_confirmed,false)=true then
    for r in
      select distinct provider_id
      from public.booking_professional_assignments
      where booking_id=new.id and status in ('accepted','completed')
      union
      select coalesce(new.provider_id,new.winner_provider_id)
      where coalesce(new.provider_id,new.winner_provider_id) is not null
    loop
      insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read)
      values(r.provider_id,'El cliente confirmó el servicio','El cliente confirmó que el servicio se realizó.','booking_confirmation_pending','/main/booking/'||new.id,new.id,
        jsonb_build_object('provider_id',r.provider_id),false);
    end loop;
  end if;

  -- Cancelación: avisar a todo el equipo relacionado, no solo bookings.provider_id.
  if old.status is distinct from new.status and lower(coalesce(new.status,''))='cancelled' then
    for r in
      select distinct provider_id
      from public.booking_professional_assignments
      where booking_id=new.id and status in ('pending','selected','invited','accepted','completed')
      union
      select coalesce(new.provider_id,new.winner_provider_id)
      where coalesce(new.provider_id,new.winner_provider_id) is not null
    loop
      insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read)
      values(r.provider_id,'Reserva cancelada','La reserva fue cancelada.','booking_cancelled','/main/booking/'||new.id,new.id,
        jsonb_build_object('provider_id',r.provider_id),false);
    end loop;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_notify_booking_participants_v664 on public.bookings;
create trigger trg_notify_booking_participants_v664
after update of buyer_confirmed,status,payment_status,service_progress_stage on public.bookings
for each row execute function public.yt_notify_booking_participants_v664();

-- Propina: cada allocation representa la parte real del profesional.
create or replace function public.yt_notify_tip_allocation_v664()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  if new.provider_id is not null and coalesce(new.provider_share,0)>0 and lower(coalesce(new.status,'')) in ('allocated','paid') then
    insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read)
    values(new.provider_id,'Recibiste una propina','Se registró una propina para tu servicio.','tip_received','/(provider-tabs)/earnings',new.booking_id,
      jsonb_build_object('allocation_id',new.id,'tip_id',new.tip_id,'provider_share',new.provider_share,'provider_id',new.provider_id),false);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_tip_allocation_v664 on public.booking_tip_allocations;
create trigger trg_notify_tip_allocation_v664
after insert or update of provider_share,status on public.booking_tip_allocations
for each row
when (new.provider_share > 0)
execute function public.yt_notify_tip_allocation_v664();

-- -----------------------------------------------------------------------------
-- 9. Configuración de versión
-- -----------------------------------------------------------------------------
insert into public.app_settings(key,value,updated_at)
values('wissa_v66_block3b_notifications',jsonb_build_object(
  'version','66.4',
  'release','BLOCK3B-NOTIFICATIONS',
  'multi_device_push',true,
  'database_fallback_push',true,
  'idempotent_notifications',true,
  'assignment_flow_events',true,
  'tip_notifications',true,
  'updated_at',now()
),now())
on conflict(key) do update set value=excluded.value,updated_at=excluded.updated_at;

notify pgrst,'reload schema';
select pg_notify('pgrst','reload schema');
commit;
