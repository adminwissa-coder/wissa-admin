-- ============================================================================
-- WISSA V43 RELEASE CANDIDATE - MODERACION / STORE HARDENING
-- Fecha: 2026-08-17
-- EJECUTAR SOBRE V42.1 YA INSTALADA.
--
-- Incluye:
--   * Bloqueo de usuarios bidireccional para interacciones/chat.
--   * Reporte específico de mensajes y reseñas.
--   * Filtro básico configurable de UGC en chat y reseñas.
--   * RPC de moderación para Admin Wissa.
--   * Índices y RLS necesarios.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- 1. BLOQUEO DE USUARIOS
-- --------------------------------------------------------------------------
create table if not exists public.user_blocks (
  id uuid primary key default gen_random_uuid(),
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint user_blocks_not_self check (blocker_id <> blocked_id),
  constraint user_blocks_unique_pair unique (blocker_id, blocked_id)
);

create index if not exists idx_user_blocks_blocker_created_v43
  on public.user_blocks (blocker_id, created_at desc);
create index if not exists idx_user_blocks_blocked_created_v43
  on public.user_blocks (blocked_id, created_at desc);

alter table public.user_blocks enable row level security;

drop policy if exists user_blocks_select_v43 on public.user_blocks;
create policy user_blocks_select_v43 on public.user_blocks
for select to authenticated
using (
  blocker_id = auth.uid()
  or public.yt_admin_is_current_admin()
);

drop policy if exists user_blocks_insert_v43 on public.user_blocks;
create policy user_blocks_insert_v43 on public.user_blocks
for insert to authenticated
with check (blocker_id = auth.uid() and blocked_id <> auth.uid());

drop policy if exists user_blocks_update_v43 on public.user_blocks;
create policy user_blocks_update_v43 on public.user_blocks
for update to authenticated
using (blocker_id = auth.uid() or public.yt_admin_is_current_admin())
with check (blocker_id = auth.uid() or public.yt_admin_is_current_admin());

drop policy if exists user_blocks_delete_v43 on public.user_blocks;
create policy user_blocks_delete_v43 on public.user_blocks
for delete to authenticated
using (blocker_id = auth.uid() or public.yt_admin_is_current_admin());

create or replace function public.yt_users_blocked_v43(p_user_a uuid, p_user_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.user_blocks b
    where (b.blocker_id = p_user_a and b.blocked_id = p_user_b)
       or (b.blocker_id = p_user_b and b.blocked_id = p_user_a)
  );
$$;

create or replace function public.yt_user_block_state_v43(p_other_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_blocked_by_me boolean := false;
  v_blocked_me boolean := false;
begin
  if v_user_id is null then
    raise exception 'Debes iniciar sesión.';
  end if;
  if p_other_user_id is null then
    return jsonb_build_object('blocked_by_me', false, 'blocked_me', false, 'either', false);
  end if;

  select exists (
    select 1 from public.user_blocks
    where blocker_id = v_user_id and blocked_id = p_other_user_id
  ) into v_blocked_by_me;

  select exists (
    select 1 from public.user_blocks
    where blocker_id = p_other_user_id and blocked_id = v_user_id
  ) into v_blocked_me;

  return jsonb_build_object(
    'blocked_by_me', v_blocked_by_me,
    'blocked_me', v_blocked_me,
    'either', v_blocked_by_me or v_blocked_me
  );
end;
$$;

create or replace function public.yt_my_blocked_user_ids_v43()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(distinct user_id), '{}'::uuid[])
  from (
    select blocked_id as user_id from public.user_blocks where blocker_id = auth.uid()
    union
    select blocker_id as user_id from public.user_blocks where blocked_id = auth.uid()
  ) q;
$$;

create or replace function public.yt_block_user_v43(p_blocked_id uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_id uuid;
begin
  if v_user_id is null then raise exception 'Debes iniciar sesión.'; end if;
  if p_blocked_id is null then raise exception 'Usuario inválido.'; end if;
  if p_blocked_id = v_user_id then raise exception 'No puedes bloquear tu propia cuenta.'; end if;
  if not exists (select 1 from public.profiles where id = p_blocked_id) then
    raise exception 'Usuario no encontrado.';
  end if;

  insert into public.user_blocks (blocker_id, blocked_id, reason, created_at, updated_at)
  values (v_user_id, p_blocked_id, nullif(trim(coalesce(p_reason,'')),''), now(), now())
  on conflict (blocker_id, blocked_id) do update
    set reason = coalesce(excluded.reason, public.user_blocks.reason),
        updated_at = now()
  returning id into v_id;

  return jsonb_build_object('ok', true, 'block_id', v_id, 'blocked_id', p_blocked_id);
end;
$$;

create or replace function public.yt_unblock_user_v43(p_blocked_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_deleted integer := 0;
begin
  if v_user_id is null then raise exception 'Debes iniciar sesión.'; end if;

  delete from public.user_blocks
  where blocker_id = v_user_id and blocked_id = p_blocked_id;
  get diagnostics v_deleted = row_count;

  return jsonb_build_object('ok', true, 'unblocked', v_deleted > 0, 'blocked_id', p_blocked_id);
end;
$$;

-- --------------------------------------------------------------------------
-- 2. FILTRO UGC CONFIGURABLE
-- --------------------------------------------------------------------------
create table if not exists public.ugc_moderation_terms (
  id uuid primary key default gen_random_uuid(),
  term text not null unique,
  category text not null default 'abuse',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.ugc_moderation_terms enable row level security;

drop policy if exists ugc_terms_admin_v43 on public.ugc_moderation_terms;
create policy ugc_terms_admin_v43 on public.ugc_moderation_terms
for all to authenticated
using (public.yt_admin_is_current_admin())
with check (public.yt_admin_is_current_admin());

insert into public.ugc_moderation_terms(term, category, is_active)
values
  ('puta', 'abuse', true),
  ('puto', 'abuse', true),
  ('imbecil', 'abuse', true),
  ('imbécil', 'abuse', true),
  ('estupido', 'abuse', true),
  ('estúpido', 'abuse', true),
  ('maricon', 'harassment', true),
  ('maricón', 'harassment', true)
on conflict (term) do nothing;

create or replace function public.yt_ugc_rejection_reason_v43(p_text text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_text text := lower(trim(coalesce(p_text,'')));
  v_term text;
  v_url_count integer := 0;
begin
  if v_text = '' then return null; end if;

  -- Spam evidente: tres o más enlaces en una sola pieza de UGC.
  v_url_count := (length(v_text) - length(replace(v_text, 'http', ''))) / 4;
  if v_url_count >= 3 then return 'spam_links'; end if;

  select t.term into v_term
  from public.ugc_moderation_terms t
  where t.is_active = true
    and exists (
      select 1
      from regexp_split_to_table(v_text, E'[^[:alnum:]áéíóúüñ]+') as tok(value)
      where tok.value = lower(t.term)
    )
  limit 1;

  if v_term is not null then return 'abusive_language'; end if;
  return null;
end;
$$;

create or replace function public.yt_chat_message_guard_v43()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_buyer uuid;
  v_provider uuid;
  v_other uuid;
  v_reason text;
begin
  select buyer_id, provider_id into v_buyer, v_provider
  from public.chat_rooms
  where id = new.room_id;

  if v_buyer is null or v_provider is null then
    raise exception 'Sala de chat inválida.';
  end if;

  if new.sender_id <> v_buyer and new.sender_id <> v_provider then
    raise exception 'No autorizado para escribir en este chat.';
  end if;

  if auth.uid() is not null and new.sender_id <> auth.uid() then
    raise exception 'No autorizado para enviar mensajes en nombre de otro usuario.';
  end if;

  v_other := case when new.sender_id = v_buyer then v_provider else v_buyer end;
  if public.yt_users_blocked_v43(new.sender_id, v_other) then
    raise exception 'CHAT_BLOCKED: esta conversación no permite nuevos mensajes.';
  end if;

  v_reason := public.yt_ugc_rejection_reason_v43(new.message);
  if v_reason is not null then
    raise exception 'UGC_REJECTED: revisa el contenido antes de enviarlo.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_chat_message_guard_v43 on public.chat_messages;
create trigger trg_chat_message_guard_v43
before insert or update of message on public.chat_messages
for each row execute function public.yt_chat_message_guard_v43();

create or replace function public.yt_review_ugc_guard_v43()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reason text;
begin
  if nullif(trim(coalesce(new.comment,'')),'') is null then return new; end if;
  v_reason := public.yt_ugc_rejection_reason_v43(new.comment);
  if v_reason is not null then
    raise exception 'UGC_REJECTED: revisa el comentario antes de publicarlo.';
  end if;
  return new;
end;
$$;

create or replace function public.yt_booking_user_block_guard_v43()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.buyer_id is not null
     and new.provider_id is not null
     and public.yt_users_blocked_v43(new.buyer_id, new.provider_id) then
    raise exception 'USER_BLOCKED: no se puede crear o reasignar una reserva entre estas cuentas.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_booking_user_block_guard_v43 on public.bookings;
create trigger trg_booking_user_block_guard_v43
before insert or update of buyer_id, provider_id on public.bookings
for each row execute function public.yt_booking_user_block_guard_v43();

drop trigger if exists trg_review_ugc_guard_v43 on public.reviews;
create trigger trg_review_ugc_guard_v43
before insert or update of comment on public.reviews
for each row execute function public.yt_review_ugc_guard_v43();

-- --------------------------------------------------------------------------
-- 3. REPORTES DE CONTENIDO
-- --------------------------------------------------------------------------
alter table public.reports
  add column if not exists content_type text not null default 'user',
  add column if not exists reported_chat_message_id uuid,
  add column if not exists reported_review_id uuid,
  add column if not exists reported_content_excerpt text,
  add column if not exists moderation_reason text,
  add column if not exists moderated_by uuid,
  add column if not exists moderated_at timestamptz;

create index if not exists idx_reports_status_content_created_v43
  on public.reports(status, content_type, created_at desc);
create index if not exists idx_reports_chat_message_v43
  on public.reports(reported_chat_message_id)
  where reported_chat_message_id is not null;
create index if not exists idx_reports_review_v43
  on public.reports(reported_review_id)
  where reported_review_id is not null;

create or replace function public.yt_report_chat_message_v43(
  p_message_id uuid,
  p_reason text default 'Contenido inapropiado',
  p_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_message public.chat_messages%rowtype;
  v_room public.chat_rooms%rowtype;
  v_report_id uuid;
begin
  if v_user_id is null then raise exception 'Debes iniciar sesión.'; end if;

  select * into v_message from public.chat_messages where id = p_message_id;
  if not found then raise exception 'Mensaje no encontrado.'; end if;

  select * into v_room from public.chat_rooms where id = v_message.room_id;
  if not found or v_user_id not in (v_room.buyer_id, v_room.provider_id) then
    raise exception 'No autorizado para reportar este mensaje.';
  end if;
  if v_message.sender_id = v_user_id then raise exception 'No puedes reportar tu propio mensaje.'; end if;

  select id into v_report_id
  from public.reports
  where reporter_id = v_user_id
    and reported_chat_message_id = p_message_id
    and status = 'open'
  order by created_at desc
  limit 1;

  if v_report_id is null then
    insert into public.reports(
      booking_id, reporter_id, reported_id, reason, description, status,
      content_type, reported_chat_message_id, reported_content_excerpt,
      moderation_reason, created_at, updated_at
    ) values (
      v_room.booking_id, v_user_id, v_message.sender_id,
      coalesce(nullif(trim(p_reason),''),'Contenido inapropiado'),
      nullif(trim(coalesce(p_description,'')),''), 'open',
      'chat_message', p_message_id, left(v_message.message, 320),
      'user_report', now(), now()
    ) returning id into v_report_id;
  end if;

  return jsonb_build_object('ok', true, 'report_id', v_report_id, 'content_type', 'chat_message');
end;
$$;

create or replace function public.yt_report_review_v43(
  p_review_id uuid,
  p_reason text default 'Reseña inapropiada'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_review public.reviews%rowtype;
  v_report_id uuid;
begin
  if v_user_id is null then raise exception 'Debes iniciar sesión.'; end if;

  select * into v_review from public.reviews where id = p_review_id;
  if not found then raise exception 'Reseña no encontrada.'; end if;
  if v_review.reviewer_id = v_user_id then raise exception 'No puedes reportar tu propia reseña.'; end if;

  select id into v_report_id
  from public.reports
  where reporter_id = v_user_id
    and reported_review_id = p_review_id
    and status = 'open'
  order by created_at desc
  limit 1;

  if v_report_id is null then
    insert into public.reports(
      booking_id, reporter_id, reported_id, reason, description, status,
      content_type, reported_review_id, reported_content_excerpt,
      moderation_reason, created_at, updated_at
    ) values (
      v_review.booking_id, v_user_id, v_review.reviewer_id,
      coalesce(nullif(trim(p_reason),''),'Reseña inapropiada'),
      'Reporte de reseña enviado desde la aplicación.', 'open',
      'review', p_review_id, left(coalesce(v_review.comment,''), 320),
      'user_report', now(), now()
    ) returning id into v_report_id;
  end if;

  return jsonb_build_object('ok', true, 'report_id', v_report_id, 'content_type', 'review');
end;
$$;

-- --------------------------------------------------------------------------
-- 4. ADMIN: CENTRO DE MODERACION
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_moderation_overview_v43(
  p_status text default 'open',
  p_search text default '',
  p_limit integer default 200
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_status text := lower(trim(coalesce(p_status,'open')));
  v_search text := lower(trim(coalesce(p_search,'')));
  v_limit integer := greatest(1, least(coalesce(p_limit,200),500));
  v_rows jsonb;
  v_stats jsonb;
begin
  if not public.yt_admin_is_current_admin() then raise exception 'No autorizado.'; end if;

  select jsonb_build_object(
    'open', count(*) filter (where status = 'open'),
    'resolved', count(*) filter (where status = 'resolved'),
    'dismissed', count(*) filter (where status = 'dismissed'),
    'content_reports', count(*) filter (where content_type in ('chat_message','review')),
    'active_blocks', (select count(*) from public.user_blocks),
    'active_terms', (select count(*) from public.ugc_moderation_terms where is_active = true)
  ) into v_stats
  from public.reports;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at desc), '[]'::jsonb)
  into v_rows
  from (
    select
      r.id,
      r.booking_id,
      r.reporter_id,
      r.reported_id,
      r.reason,
      r.description,
      r.status,
      r.admin_note,
      r.content_type,
      r.reported_chat_message_id,
      r.reported_review_id,
      r.reported_content_excerpt,
      r.moderation_reason,
      r.moderated_by,
      r.moderated_at,
      r.created_at,
      r.updated_at,
      coalesce(reporter.display_name, reporter.full_name, reporter.email, 'Usuario') as reporter_name,
      reporter.email as reporter_email,
      coalesce(reported.display_name, reported.full_name, reported.email, 'Usuario') as reported_name,
      reported.email as reported_email,
      coalesce(reported.is_suspended,false) as reported_suspended,
      b.service_title,
      b.status as booking_status
    from public.reports r
    left join public.profiles reporter on reporter.id = r.reporter_id
    left join public.profiles reported on reported.id = r.reported_id
    left join public.bookings b on b.id = r.booking_id
    where (v_status = 'all' or lower(r.status) = v_status)
      and (
        v_search = ''
        or lower(coalesce(r.reason,'')) like '%' || v_search || '%'
        or lower(coalesce(r.description,'')) like '%' || v_search || '%'
        or lower(coalesce(r.reported_content_excerpt,'')) like '%' || v_search || '%'
        or lower(coalesce(reporter.display_name, reporter.full_name, reporter.email,'')) like '%' || v_search || '%'
        or lower(coalesce(reported.display_name, reported.full_name, reported.email,'')) like '%' || v_search || '%'
      )
    order by r.created_at desc
    limit v_limit
  ) q;

  return jsonb_build_object('stats', coalesce(v_stats,'{}'::jsonb), 'reports', coalesce(v_rows,'[]'::jsonb));
end;
$$;

create or replace function public.yt_admin_moderation_action_v43(
  p_report_id uuid,
  p_action text,
  p_note text default null,
  p_suspend_user boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action text := lower(trim(coalesce(p_action,'')));
  v_report public.reports%rowtype;
  v_status text;
begin
  if not public.yt_admin_is_current_admin() then raise exception 'No autorizado.'; end if;
  if v_action not in ('resolve','dismiss','reopen') then raise exception 'Acción inválida.'; end if;

  select * into v_report from public.reports where id = p_report_id for update;
  if not found then raise exception 'Reporte no encontrado.'; end if;

  v_status := case v_action when 'resolve' then 'resolved' when 'dismiss' then 'dismissed' else 'open' end;

  update public.reports
  set status = v_status,
      admin_note = nullif(trim(coalesce(p_note,'')),''),
      moderated_by = auth.uid(),
      moderated_at = now(),
      updated_at = now()
  where id = p_report_id;

  if p_suspend_user and v_report.reported_id is not null then
    update public.profiles
    set is_suspended = true,
        status = 'suspended',
        suspended_at = now(),
        suspended_reason = coalesce(nullif(trim(coalesce(p_note,'')),''), 'Suspendido por moderación Wissa'),
        last_admin_action_at = now(),
        last_admin_action_by = auth.uid(),
        updated_at = now()
    where id = v_report.reported_id;
  end if;

  if v_report.reporter_id is not null and v_status in ('resolved','dismissed') then
    insert into public.notifications(user_id,title,body,type,screen,metadata,is_read,created_at)
    values (
      v_report.reporter_id,
      case when v_status='resolved' then 'Reporte revisado' else 'Reporte cerrado' end,
      case when v_status='resolved'
        then 'Administración Wissa revisó tu reporte y aplicó el seguimiento correspondiente.'
        else 'Administración Wissa revisó tu reporte y cerró el caso.' end,
      'moderation_report_update', '/main/notifications',
      jsonb_build_object('report_id',p_report_id,'status',v_status), false, now()
    );
  end if;

  return jsonb_build_object('ok',true,'report_id',p_report_id,'status',v_status,'user_suspended',p_suspend_user and v_report.reported_id is not null);
end;
$$;

revoke execute on function public.yt_users_blocked_v43(uuid,uuid) from public, anon;
revoke execute on function public.yt_user_block_state_v43(uuid) from public, anon;
revoke execute on function public.yt_my_blocked_user_ids_v43() from public, anon;
revoke execute on function public.yt_block_user_v43(uuid,text) from public, anon;
revoke execute on function public.yt_unblock_user_v43(uuid) from public, anon;
revoke execute on function public.yt_ugc_rejection_reason_v43(text) from public, anon;
revoke execute on function public.yt_report_chat_message_v43(uuid,text,text) from public, anon;
revoke execute on function public.yt_report_review_v43(uuid,text) from public, anon;
revoke execute on function public.yt_admin_moderation_overview_v43(text,text,integer) from public, anon;
revoke execute on function public.yt_admin_moderation_action_v43(uuid,text,text,boolean) from public, anon;

revoke execute on function public.yt_users_blocked_v43(uuid,uuid) from authenticated;
grant execute on function public.yt_users_blocked_v43(uuid,uuid) to service_role;
grant execute on function public.yt_user_block_state_v43(uuid) to authenticated, service_role;
grant execute on function public.yt_my_blocked_user_ids_v43() to authenticated, service_role;
grant execute on function public.yt_block_user_v43(uuid,text) to authenticated, service_role;
grant execute on function public.yt_unblock_user_v43(uuid) to authenticated, service_role;
grant execute on function public.yt_report_chat_message_v43(uuid,text,text) to authenticated, service_role;
grant execute on function public.yt_report_review_v43(uuid,text) to authenticated, service_role;
grant execute on function public.yt_admin_moderation_overview_v43(text,text,integer) to authenticated, service_role;
grant execute on function public.yt_admin_moderation_action_v43(uuid,text,text,boolean) to authenticated, service_role;

notify pgrst, 'reload schema';
commit;

-- FIN WISSA V43 RELEASE CANDIDATE
