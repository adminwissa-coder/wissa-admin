-- ============================================================================
-- WISSA v25 - OFRECER: VERIFICACION, CONTACTO Y DATOS DE COBRO
-- Fecha: 2026-08-13
--
-- OBJETIVOS
--   1) Separar Clientes de Ofrecer en Admin Web.
--   2) Perfil administrativo completo del proveedor.
--   3) Yappy y/o cuenta bancaria persistentes para liquidaciones.
--   4) Telefono + WhatsApp para contacto administrativo.
--   5) Verificacion privada: foto personal + record policivo.
--   6) Notificar a Admin al subir documentos.
--   7) Admin abre/descarga documentos mediante Storage privado y signed URL.
--   8) Admin aprueba/rechaza cada documento y finalmente habilita al proveedor.
--   9) Un proveedor no aprobado NO puede ponerse disponible ni aceptar/completar.
--  10) Retiros de ofrecer muestra metodo/destino de cobro enmascarado.
--
-- REQUIERE
--   - public.yt_admin_is_current_admin()
--   - tablas profiles, identity_documents, notifications, internal_notifications,
--     bookings, services, provider_payouts, payout_requests, withdrawal_requests.
--   - Wissa v24.1 para el flujo actual de liquidaciones.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- A. PERFIL: CONTACTO DE OFRECER
-- --------------------------------------------------------------------------
alter table public.profiles
  add column if not exists whatsapp_phone text;

alter table public.profiles
  add column if not exists preferred_contact_method text default 'whatsapp';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'profiles_preferred_contact_method_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_preferred_contact_method_check
      check (preferred_contact_method is null or preferred_contact_method in ('phone','whatsapp'));
  end if;
end $$;

-- --------------------------------------------------------------------------
-- B. METODOS DE COBRO DEL PROVEEDOR
-- --------------------------------------------------------------------------
create table if not exists public.provider_payout_methods (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.profiles(id) on delete cascade,
  method_type text not null check (method_type in ('yappy','bank')),
  label text,
  account_holder text not null,
  yappy_phone text,
  bank_name text,
  bank_account_type text,
  bank_account_number text,
  is_default boolean not null default false,
  is_active boolean not null default true,
  is_verified boolean not null default false,
  verified_at timestamptz,
  verified_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider_id, method_type),
  constraint provider_payout_methods_payload_check check (
    (method_type = 'yappy' and nullif(btrim(yappy_phone),'') is not null)
    or
    (method_type = 'bank'
      and nullif(btrim(bank_name),'') is not null
      and nullif(btrim(bank_account_number),'') is not null)
  )
);

create index if not exists provider_payout_methods_provider_idx
  on public.provider_payout_methods(provider_id, is_active desc, is_default desc);

create or replace function public.yt_provider_payout_method_before_write_v25()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := now();

  -- El proveedor puede editar sus datos, pero no puede auto-validarlos.
  if not public.yt_admin_is_current_admin() then
    if tg_op = 'INSERT' then
      new.is_verified := false;
      new.verified_at := null;
      new.verified_by := null;
    else
      new.is_verified := old.is_verified;
      new.verified_at := old.verified_at;
      new.verified_by := old.verified_by;
    end if;
  end if;

  if new.is_active and not exists (
    select 1 from public.provider_payout_methods m
    where m.provider_id = new.provider_id
      and m.id <> coalesce(new.id, gen_random_uuid())
      and m.is_active
  ) then
    new.is_default := true;
  end if;

  if not new.is_active then
    new.is_default := false;
  end if;

  if new.is_default then
    update public.provider_payout_methods
      set is_default = false,
          updated_at = now()
    where provider_id = new.provider_id
      and id <> new.id
      and is_default = true;
  end if;

  return new;
end;
$$;

drop trigger if exists provider_payout_methods_before_write_v25 on public.provider_payout_methods;
create trigger provider_payout_methods_before_write_v25
before insert or update on public.provider_payout_methods
for each row execute function public.yt_provider_payout_method_before_write_v25();

alter table public.provider_payout_methods enable row level security;

drop policy if exists provider_payout_methods_owner_select_v25 on public.provider_payout_methods;
create policy provider_payout_methods_owner_select_v25
on public.provider_payout_methods for select
to authenticated
using (provider_id = auth.uid() or public.yt_admin_is_current_admin());

drop policy if exists provider_payout_methods_owner_insert_v25 on public.provider_payout_methods;
create policy provider_payout_methods_owner_insert_v25
on public.provider_payout_methods for insert
to authenticated
with check (provider_id = auth.uid() or public.yt_admin_is_current_admin());

drop policy if exists provider_payout_methods_owner_update_v25 on public.provider_payout_methods;
create policy provider_payout_methods_owner_update_v25
on public.provider_payout_methods for update
to authenticated
using (provider_id = auth.uid() or public.yt_admin_is_current_admin())
with check (provider_id = auth.uid() or public.yt_admin_is_current_admin());

drop policy if exists provider_payout_methods_owner_delete_v25 on public.provider_payout_methods;
create policy provider_payout_methods_owner_delete_v25
on public.provider_payout_methods for delete
to authenticated
using (public.yt_admin_is_current_admin());

grant select, insert, update on public.provider_payout_methods to authenticated;
grant all on public.provider_payout_methods to service_role;

-- --------------------------------------------------------------------------
-- C. STORAGE PRIVADO PARA VERIFICACION
-- --------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'provider-verification',
  'provider-verification',
  false,
  10485760,
  array['image/jpeg','image/png','image/webp','application/pdf']
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists provider_verification_owner_select_v25 on storage.objects;
create policy provider_verification_owner_select_v25
on storage.objects for select
to authenticated
using (
  bucket_id = 'provider-verification'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.yt_admin_is_current_admin()
  )
);

drop policy if exists provider_verification_owner_insert_v25 on storage.objects;
create policy provider_verification_owner_insert_v25
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'provider-verification'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists provider_verification_owner_update_v25 on storage.objects;
create policy provider_verification_owner_update_v25
on storage.objects for update
to authenticated
using (
  bucket_id = 'provider-verification'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'provider-verification'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists provider_verification_owner_delete_v25 on storage.objects;
create policy provider_verification_owner_delete_v25
on storage.objects for delete
to authenticated
using (
  bucket_id = 'provider-verification'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- --------------------------------------------------------------------------
-- D. DOCUMENTOS: RLS + NOTIFICACION AL ADMIN
-- --------------------------------------------------------------------------
alter table public.identity_documents enable row level security;

create or replace function public.yt_identity_document_guard_v25()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if not public.yt_admin_is_current_admin() then
    if tg_op = 'INSERT' then
      new.status := 'pending';
      new.reviewed_by := null;
      new.reviewed_at := null;
      new.admin_note := null;
      new.updated_at := now();
    else
      if new.status is distinct from old.status
        or new.reviewed_by is distinct from old.reviewed_by
        or new.reviewed_at is distinct from old.reviewed_at
        or new.admin_note is distinct from old.admin_note then
        raise exception 'El estado de verificación solo puede cambiarlo Wissa';
      end if;
      new.updated_at := now();
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists identity_document_guard_v25 on public.identity_documents;
create trigger identity_document_guard_v25
before insert or update on public.identity_documents
for each row execute function public.yt_identity_document_guard_v25();

drop policy if exists identity_documents_owner_select_v25 on public.identity_documents;
create policy identity_documents_owner_select_v25
on public.identity_documents for select
to authenticated
using (user_id = auth.uid() or public.yt_admin_is_current_admin());

drop policy if exists identity_documents_owner_insert_v25 on public.identity_documents;
create policy identity_documents_owner_insert_v25
on public.identity_documents for insert
to authenticated
with check (user_id = auth.uid());

drop policy if exists identity_documents_admin_update_v25 on public.identity_documents;
create policy identity_documents_admin_update_v25
on public.identity_documents for update
to authenticated
using (public.yt_admin_is_current_admin())
with check (public.yt_admin_is_current_admin());

create or replace function public.yt_identity_document_submitted_v25()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text;
  v_label text;
begin
  if new.status <> 'pending' then
    return new;
  end if;

  if new.document_type not in ('selfie','police_record','cedula') then
    return new;
  end if;

  select coalesce(nullif(display_name,''), nullif(full_name,''), nullif(email,''), 'Proveedor Wissa')
  into v_name
  from public.profiles
  where id = new.user_id;

  v_label := case new.document_type
    when 'selfie' then 'foto personal'
    when 'police_record' then 'récord policivo'
    else 'cédula'
  end;

  if new.document_type in ('selfie','police_record') then
    update public.profiles
    set provider_status = 'pending',
        is_verified = false,
        is_available = false,
        provider_review_note = 'Documentación de Ofrecer en revisión',
        updated_at = now()
    where id = new.user_id;
  end if;

  insert into public.internal_notifications (
    user_id, title, body, type, reference_id, is_read, metadata
  )
  select
    p.id,
    'Nueva verificación de Ofrecer',
    v_name || ' envió ' || v_label || ' para revisión.',
    'provider_verification_pending',
    new.id,
    false,
    jsonb_build_object(
      'provider_id', new.user_id,
      'document_id', new.id,
      'document_type', new.document_type,
      'screen', '/dashboard/ofrecer/' || new.user_id::text
    )
  from public.profiles p
  where coalesce(p.is_admin,false) = true
     or p.role in ('admin','super_admin');

  return new;
end;
$$;

drop trigger if exists identity_document_submitted_v25 on public.identity_documents;
create trigger identity_document_submitted_v25
after insert on public.identity_documents
for each row execute function public.yt_identity_document_submitted_v25();

-- --------------------------------------------------------------------------
-- E. HELPERS
-- --------------------------------------------------------------------------
create or replace function public.yt_is_provider_profile_v25(p_profile public.profiles)
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce((p_profile).provider_enabled,false)
    or (p_profile).role in ('vendor','provider','ofrecer','both','ambos')
    or exists (select 1 from public.services s where s.provider_id = (p_profile).id);
$$;

-- Normaliza perfiles de Ofrecer heredados: si nunca fueron verificados, quedan pendientes.
update public.profiles p
set provider_status = 'pending',
    is_available = false,
    provider_review_note = coalesce(nullif(p.provider_review_note,''), 'Verificación de Ofrecer pendiente'),
    updated_at = now()
where public.yt_is_provider_profile_v25(p)
  and coalesce(p.is_verified,false) = false
  and coalesce(p.provider_status,'approved') = 'approved';

create or replace function public.yt_mask_payout_destination_v25(
  p_method_type text,
  p_yappy_phone text,
  p_bank_name text,
  p_bank_account_number text
)
returns text
language sql
immutable
as $$
  select case
    when p_method_type = 'yappy' then
      'Yappy · •••• ' || right(regexp_replace(coalesce(p_yappy_phone,''),'[^0-9]','','g'), 4)
    when p_method_type = 'bank' then
      coalesce(nullif(p_bank_name,''),'Banco') || ' · •••• ' || right(regexp_replace(coalesce(p_bank_account_number,''),'[^0-9A-Za-z]','','g'), 4)
    else 'Sin método'
  end;
$$;

create or replace function public.yt_provider_verification_readiness_v25(p_provider_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_selfie text;
  v_police text;
  v_has_payout boolean := false;
  v_has_contact boolean := false;
begin
  select d.status into v_selfie
  from public.identity_documents d
  where d.user_id = p_provider_id and d.document_type = 'selfie'
  order by d.created_at desc
  limit 1;

  select d.status into v_police
  from public.identity_documents d
  where d.user_id = p_provider_id and d.document_type = 'police_record'
  order by d.created_at desc
  limit 1;

  select exists (
    select 1 from public.provider_payout_methods m
    where m.provider_id = p_provider_id and m.is_active
  ) into v_has_payout;

  select exists (
    select 1 from public.profiles p
    where p.id = p_provider_id
      and (
        nullif(regexp_replace(coalesce(p.phone,''),'\s','','g'),'') is not null
        or nullif(regexp_replace(coalesce(p.whatsapp_phone,''),'\s','','g'),'') is not null
      )
  ) into v_has_contact;

  return jsonb_build_object(
    'selfie_status', coalesce(v_selfie,'missing'),
    'police_record_status', coalesce(v_police,'missing'),
    'has_payout_method', v_has_payout,
    'has_contact', v_has_contact,
    'ready', coalesce(v_selfie,'missing') = 'approved'
      and coalesce(v_police,'missing') = 'approved'
      and v_has_payout
      and v_has_contact
  );
end;
$$;

revoke execute on function public.yt_provider_verification_readiness_v25(uuid) from public, anon;
grant execute on function public.yt_provider_verification_readiness_v25(uuid) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- F. APP: GUARDAR DATOS DE COBRO Y CONTACTO
-- --------------------------------------------------------------------------
create or replace function public.yt_provider_save_payout_profile(
  p_phone text default null,
  p_whatsapp_phone text default null,
  p_preferred_contact_method text default 'whatsapp',
  p_yappy_active boolean default false,
  p_yappy_phone text default null,
  p_yappy_holder text default null,
  p_yappy_default boolean default false,
  p_bank_active boolean default false,
  p_bank_name text default null,
  p_bank_account_type text default null,
  p_bank_account_number text default null,
  p_bank_holder text default null,
  p_bank_default boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_yappy_default boolean := coalesce(p_yappy_default,false);
  v_bank_default boolean := coalesce(p_bank_default,false);
begin
  if v_user is null then
    raise exception 'No autenticado';
  end if;

  if coalesce(p_preferred_contact_method,'whatsapp') not in ('phone','whatsapp') then
    raise exception 'Método de contacto inválido';
  end if;

  if coalesce(p_yappy_active,false) then
    if nullif(btrim(coalesce(p_yappy_phone,'')),'') is null
      or nullif(btrim(coalesce(p_yappy_holder,'')),'') is null then
      raise exception 'Completa el número Yappy y el titular';
    end if;
  end if;

  if coalesce(p_bank_active,false) then
    if nullif(btrim(coalesce(p_bank_name,'')),'') is null
      or nullif(btrim(coalesce(p_bank_account_number,'')),'') is null
      or nullif(btrim(coalesce(p_bank_holder,'')),'') is null then
      raise exception 'Completa banco, número de cuenta y titular';
    end if;
  end if;

  if not coalesce(p_yappy_active,false) and not coalesce(p_bank_active,false) then
    raise exception 'Configura al menos Yappy o una cuenta bancaria';
  end if;

  -- Solo puede existir un predeterminado. Si llegan ambos marcados, priorizamos Yappy.
  if v_yappy_default and v_bank_default then
    v_bank_default := false;
  end if;

  -- Si solo uno está activo, ese queda predeterminado.
  if coalesce(p_yappy_active,false) and not coalesce(p_bank_active,false) then
    v_yappy_default := true;
  elsif coalesce(p_bank_active,false) and not coalesce(p_yappy_active,false) then
    v_bank_default := true;
  elsif not v_yappy_default and not v_bank_default then
    v_yappy_default := true;
  end if;

  update public.profiles
  set phone = nullif(btrim(coalesce(p_phone,'')),''),
      whatsapp_phone = nullif(btrim(coalesce(p_whatsapp_phone,'')),''),
      preferred_contact_method = coalesce(p_preferred_contact_method,'whatsapp'),
      updated_at = now()
  where id = v_user;

  if coalesce(p_yappy_active,false) then
    insert into public.provider_payout_methods (
      provider_id, method_type, label, account_holder, yappy_phone,
      is_default, is_active, is_verified, created_at, updated_at
    ) values (
      v_user, 'yappy', 'Yappy', btrim(p_yappy_holder), btrim(p_yappy_phone),
      v_yappy_default, true, false, now(), now()
    )
    on conflict (provider_id, method_type) do update
    set label = 'Yappy',
        account_holder = excluded.account_holder,
        yappy_phone = excluded.yappy_phone,
        is_default = excluded.is_default,
        is_active = true,
        is_verified = case
          when public.provider_payout_methods.yappy_phone is distinct from excluded.yappy_phone
            or public.provider_payout_methods.account_holder is distinct from excluded.account_holder
          then false else public.provider_payout_methods.is_verified end,
        verified_at = case
          when public.provider_payout_methods.yappy_phone is distinct from excluded.yappy_phone
            or public.provider_payout_methods.account_holder is distinct from excluded.account_holder
          then null else public.provider_payout_methods.verified_at end,
        verified_by = case
          when public.provider_payout_methods.yappy_phone is distinct from excluded.yappy_phone
            or public.provider_payout_methods.account_holder is distinct from excluded.account_holder
          then null else public.provider_payout_methods.verified_by end,
        updated_at = now();
  else
    update public.provider_payout_methods
    set is_active = false, is_default = false, updated_at = now()
    where provider_id = v_user and method_type = 'yappy';
  end if;

  if coalesce(p_bank_active,false) then
    insert into public.provider_payout_methods (
      provider_id, method_type, label, account_holder,
      bank_name, bank_account_type, bank_account_number,
      is_default, is_active, is_verified, created_at, updated_at
    ) values (
      v_user, 'bank', 'Cuenta bancaria', btrim(p_bank_holder),
      btrim(p_bank_name), nullif(btrim(coalesce(p_bank_account_type,'')),''), btrim(p_bank_account_number),
      v_bank_default, true, false, now(), now()
    )
    on conflict (provider_id, method_type) do update
    set label = 'Cuenta bancaria',
        account_holder = excluded.account_holder,
        bank_name = excluded.bank_name,
        bank_account_type = excluded.bank_account_type,
        bank_account_number = excluded.bank_account_number,
        is_default = excluded.is_default,
        is_active = true,
        is_verified = case
          when public.provider_payout_methods.bank_name is distinct from excluded.bank_name
            or public.provider_payout_methods.bank_account_number is distinct from excluded.bank_account_number
            or public.provider_payout_methods.account_holder is distinct from excluded.account_holder
          then false else public.provider_payout_methods.is_verified end,
        verified_at = case
          when public.provider_payout_methods.bank_name is distinct from excluded.bank_name
            or public.provider_payout_methods.bank_account_number is distinct from excluded.bank_account_number
            or public.provider_payout_methods.account_holder is distinct from excluded.account_holder
          then null else public.provider_payout_methods.verified_at end,
        verified_by = case
          when public.provider_payout_methods.bank_name is distinct from excluded.bank_name
            or public.provider_payout_methods.bank_account_number is distinct from excluded.bank_account_number
            or public.provider_payout_methods.account_holder is distinct from excluded.account_holder
          then null else public.provider_payout_methods.verified_by end,
        updated_at = now();
  else
    update public.provider_payout_methods
    set is_active = false, is_default = false, updated_at = now()
    where provider_id = v_user and method_type = 'bank';
  end if;

  return jsonb_build_object(
    'ok', true,
    'provider_id', v_user,
    'readiness', public.yt_provider_verification_readiness_v25(v_user)
  );
end;
$$;

revoke execute on function public.yt_provider_save_payout_profile(text,text,text,boolean,text,text,boolean,boolean,text,text,text,text,boolean) from public, anon;
grant execute on function public.yt_provider_save_payout_profile(text,text,text,boolean,text,text,boolean,boolean,text,text,text,text,boolean) to authenticated, service_role;

create or replace function public.yt_provider_payout_profile_json()
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_result jsonb;
begin
  if v_user is null then raise exception 'No autenticado'; end if;

  select jsonb_build_object(
    'profile', jsonb_build_object(
      'id', p.id,
      'full_name', p.full_name,
      'phone', p.phone,
      'whatsapp_phone', p.whatsapp_phone,
      'preferred_contact_method', coalesce(p.preferred_contact_method,'whatsapp')
    ),
    'methods', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id,
        'method_type', m.method_type,
        'account_holder', m.account_holder,
        'yappy_phone', m.yappy_phone,
        'bank_name', m.bank_name,
        'bank_account_type', m.bank_account_type,
        'bank_account_number', m.bank_account_number,
        'is_default', m.is_default,
        'is_active', m.is_active,
        'is_verified', m.is_verified,
        'updated_at', m.updated_at
      ) order by m.is_default desc, m.method_type)
      from public.provider_payout_methods m
      where m.provider_id = p.id
    ), '[]'::jsonb)
  ) into v_result
  from public.profiles p
  where p.id = v_user;

  return coalesce(v_result, '{}'::jsonb);
end;
$$;

revoke execute on function public.yt_provider_payout_profile_json() from public, anon;
grant execute on function public.yt_provider_payout_profile_json() to authenticated, service_role;

-- --------------------------------------------------------------------------
-- G. APP: RESUMEN DE VERIFICACION
-- --------------------------------------------------------------------------
create or replace function public.yt_provider_verification_summary()
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_profile jsonb;
  v_documents jsonb;
  v_readiness jsonb;
begin
  if v_user is null then raise exception 'No autenticado'; end if;

  select jsonb_build_object(
    'id', p.id,
    'provider_status', p.provider_status,
    'is_verified', p.is_verified,
    'is_available', p.is_available,
    'provider_review_note', p.provider_review_note,
    'approved_at', p.approved_at
  ) into v_profile
  from public.profiles p where p.id = v_user;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.document_type), '[]'::jsonb)
  into v_documents
  from (
    select distinct on (d.document_type)
      d.id,
      d.document_type,
      d.storage_path,
      d.status,
      d.admin_note,
      d.reviewed_at,
      d.created_at,
      d.updated_at
    from public.identity_documents d
    where d.user_id = v_user
      and d.document_type in ('selfie','police_record','cedula')
    order by d.document_type, d.created_at desc
  ) x;

  v_readiness := public.yt_provider_verification_readiness_v25(v_user);

  return jsonb_build_object(
    'profile', coalesce(v_profile,'{}'::jsonb),
    'documents', coalesce(v_documents,'[]'::jsonb),
    'readiness', v_readiness
  );
end;
$$;

revoke execute on function public.yt_provider_verification_summary() from public, anon;
grant execute on function public.yt_provider_verification_summary() to authenticated, service_role;

-- --------------------------------------------------------------------------
-- H. ADMIN: APROBAR / RECHAZAR DOCUMENTO
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_provider_review_document(
  p_document_id uuid,
  p_decision text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_provider uuid;
  v_type text;
  v_ready jsonb;
  v_label text;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  if lower(coalesce(p_decision,'')) not in ('approved','rejected') then
    raise exception 'Decisión inválida';
  end if;

  select user_id, document_type into v_provider, v_type
  from public.identity_documents
  where id = p_document_id
  for update;

  if v_provider is null then raise exception 'Documento no encontrado'; end if;

  update public.identity_documents
  set status = lower(p_decision),
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      admin_note = nullif(btrim(coalesce(p_note,'')),''),
      updated_at = now()
  where id = p_document_id;

  v_label := case v_type
    when 'selfie' then 'foto personal'
    when 'police_record' then 'récord policivo'
    when 'cedula' then 'cédula'
    else 'documento'
  end;

  if lower(p_decision) = 'rejected' then
    if v_type in ('selfie','police_record') then
      update public.profiles
      set provider_status = 'pending',
          is_verified = false,
          is_available = false,
          provider_review_note = coalesce(nullif(btrim(coalesce(p_note,'')),''), 'Documento rechazado: vuelve a cargarlo.'),
          updated_at = now()
      where id = v_provider;
    end if;

    insert into public.notifications (user_id,title,body,type,screen,metadata,is_read)
    values (
      v_provider,
      'Documento de verificación rechazado',
      'Tu ' || v_label || ' necesita corrección.' || case when nullif(btrim(coalesce(p_note,'')),'') is not null then ' Motivo: ' || btrim(p_note) else '' end,
      'provider_verification_rejected',
      '/main/verification',
      jsonb_build_object('document_id', p_document_id, 'document_type', v_type, 'decision', 'rejected'),
      false
    );
  else
    insert into public.notifications (user_id,title,body,type,screen,metadata,is_read)
    values (
      v_provider,
      'Documento de verificación aprobado',
      'Wissa aprobó tu ' || v_label || '. Revisa el estado de tu verificación.',
      'provider_verification_document_approved',
      '/main/verification',
      jsonb_build_object('document_id', p_document_id, 'document_type', v_type, 'decision', 'approved'),
      false
    );
  end if;

  v_ready := public.yt_provider_verification_readiness_v25(v_provider);

  return jsonb_build_object(
    'ok', true,
    'provider_id', v_provider,
    'document_id', p_document_id,
    'status', lower(p_decision),
    'readiness', v_ready
  );
end;
$$;

revoke execute on function public.yt_admin_provider_review_document(uuid,text,text) from public, anon;
grant execute on function public.yt_admin_provider_review_document(uuid,text,text) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- I. ADMIN: APROBACION FINAL DEL PROVEEDOR
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_finalize_provider_verification(p_provider_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_readiness jsonb;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  if not exists (select 1 from public.profiles where id = p_provider_id) then
    raise exception 'Proveedor no encontrado';
  end if;

  v_readiness := public.yt_provider_verification_readiness_v25(p_provider_id);

  if coalesce((v_readiness->>'ready')::boolean,false) = false then
    raise exception 'La verificación no está completa. Se requiere foto, récord policivo, contacto y al menos un método de cobro.';
  end if;

  update public.profiles
  set provider_status = 'approved',
      is_verified = true,
      is_available = false,
      provider_review_note = null,
      approved_at = now(),
      approved_by = auth.uid(),
      updated_at = now()
  where id = p_provider_id;

  insert into public.notifications (user_id,title,body,type,screen,metadata,is_read)
  values (
    p_provider_id,
    'Cuenta de Ofrecer verificada',
    'Tu cuenta fue aprobada por Wissa. Ya puedes activar tu disponibilidad y recibir servicios.',
    'provider_verification_approved',
    '/(provider-tabs)/dashboard',
    jsonb_build_object('provider_id', p_provider_id, 'approved_by', auth.uid()),
    false
  );

  return jsonb_build_object('ok',true,'provider_id',p_provider_id,'status','approved');
end;
$$;

revoke execute on function public.yt_admin_finalize_provider_verification(uuid) from public, anon;
grant execute on function public.yt_admin_finalize_provider_verification(uuid) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- J. ADMIN: MARCAR METODO DE COBRO COMO VALIDADO/NO VALIDADO
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_verify_provider_payout_method(
  p_method_id uuid,
  p_verified boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_provider uuid;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  update public.provider_payout_methods
  set is_verified = coalesce(p_verified,false),
      verified_at = case when coalesce(p_verified,false) then now() else null end,
      verified_by = case when coalesce(p_verified,false) then auth.uid() else null end,
      updated_at = now()
  where id = p_method_id
  returning provider_id into v_provider;

  if v_provider is null then raise exception 'Método no encontrado'; end if;

  return jsonb_build_object('ok',true,'provider_id',v_provider,'verified',coalesce(p_verified,false));
end;
$$;

revoke execute on function public.yt_admin_verify_provider_payout_method(uuid,boolean) from public, anon;
grant execute on function public.yt_admin_verify_provider_payout_method(uuid,boolean) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- K. ADMIN: LISTADO DE CLIENTES (SIN OFRECER)
-- --------------------------------------------------------------------------
drop function if exists public.yt_admin_clients_json(text,text,integer,date,date);
create function public.yt_admin_clients_json(
  p_search text default '',
  p_status text default 'all',
  p_limit integer default 500,
  p_date_from date default null,
  p_date_to date default null
)
returns table (
  id uuid,
  full_name text,
  email text,
  phone text,
  city text,
  role text,
  status text,
  is_verified boolean,
  created_at timestamptz
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_search text := lower(trim(coalesce(p_search,'')));
  v_status text := lower(trim(coalesce(p_status,'all')));
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  return query
  select
    p.id,
    coalesce(nullif(p.display_name,''), nullif(p.full_name,''), 'Cliente Wissa')::text,
    p.email::text,
    p.phone::text,
    p.city::text,
    coalesce(p.role,'client')::text,
    case when coalesce(p.is_suspended,false) or coalesce(p.status,'active') = 'suspended' then 'suspended' else 'active' end::text,
    coalesce(p.is_verified,false),
    p.created_at
  from public.profiles p
  where coalesce(p.is_admin,false) = false
    and coalesce(p.role,'client') not in ('admin','super_admin','company','empresa','company_staff','personal_empresa')
    and not public.yt_is_provider_profile_v25(p)
    and (
      v_status = 'all'
      or (v_status = 'active' and not coalesce(p.is_suspended,false) and coalesce(p.status,'active') <> 'suspended')
      or (v_status = 'suspended' and (coalesce(p.is_suspended,false) or coalesce(p.status,'active') = 'suspended'))
      or lower(coalesce(p.role,'')) = v_status
    )
    and (p_date_from is null or (p.created_at at time zone 'America/Panama')::date >= p_date_from)
    and (p_date_to is null or (p.created_at at time zone 'America/Panama')::date <= p_date_to)
    and (
      v_search = ''
      or lower(concat_ws(' ',p.id::text,p.display_name,p.full_name,p.email,p.phone,p.city,p.role)) like '%' || v_search || '%'
    )
  order by p.created_at desc
  limit greatest(1, least(coalesce(p_limit,500),2000));
end;
$$;

revoke execute on function public.yt_admin_clients_json(text,text,integer,date,date) from public, anon;
grant execute on function public.yt_admin_clients_json(text,text,integer,date,date) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- L. ADMIN: LISTADO DE OFRECER / PROVEEDORES
-- --------------------------------------------------------------------------
drop function if exists public.yt_admin_providers_json(text,text,integer,date,date);
create function public.yt_admin_providers_json(
  p_search text default '',
  p_status text default 'all',
  p_limit integer default 500,
  p_date_from date default null,
  p_date_to date default null
)
returns table (
  id uuid,
  full_name text,
  email text,
  phone text,
  whatsapp_phone text,
  city text,
  provider_status text,
  is_verified boolean,
  is_available boolean,
  rating_avg numeric,
  services_count bigint,
  bookings_count bigint,
  pending_documents bigint,
  payout_method text,
  payout_destination text,
  created_at timestamptz
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_search text := lower(trim(coalesce(p_search,'')));
  v_status text := lower(trim(coalesce(p_status,'all')));
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  return query
  select
    p.id,
    coalesce(nullif(p.display_name,''), nullif(p.full_name,''), 'Proveedor Wissa')::text,
    p.email::text,
    p.phone::text,
    p.whatsapp_phone::text,
    p.city::text,
    (case
      when coalesce(p.is_verified,false) and coalesce(p.provider_status,'approved') = 'approved' then 'approved'
      when coalesce(p.provider_status,'') = 'rejected' then 'rejected'
      else 'pending'
    end)::text,
    coalesce(p.is_verified,false),
    coalesce(p.is_available,false),
    coalesce(p.rating_avg,0),
    (select count(*) from public.services s where s.provider_id = p.id),
    (select count(*) from public.bookings b where b.provider_id = p.id),
    (
      select count(*)
      from (
        select distinct on (d.document_type) d.document_type, d.status
        from public.identity_documents d
        where d.user_id = p.id and d.document_type in ('selfie','police_record','cedula')
        order by d.document_type, d.created_at desc
      ) latest
      where latest.status = 'pending'
    ),
    coalesce(pm.method_type,'Sin método')::text,
    case
      when pm.id is null then 'Sin configurar'::text
      else public.yt_mask_payout_destination_v25(pm.method_type,pm.yappy_phone,pm.bank_name,pm.bank_account_number)
    end,
    p.created_at
  from public.profiles p
  left join lateral (
    select m.*
    from public.provider_payout_methods m
    where m.provider_id = p.id and m.is_active
    order by m.is_default desc, m.updated_at desc
    limit 1
  ) pm on true
  where coalesce(p.is_admin,false) = false
    and public.yt_is_provider_profile_v25(p)
    and (
      v_status = 'all'
      or (v_status = 'approved' and coalesce(p.is_verified,false) and coalesce(p.provider_status,'approved') = 'approved')
      or (v_status = 'rejected' and coalesce(p.provider_status,'') = 'rejected')
      or (v_status = 'pending' and not coalesce(p.is_verified,false) and coalesce(p.provider_status,'') <> 'rejected')
      or (v_status = 'verified' and coalesce(p.is_verified,false))
      or (v_status = 'unverified' and not coalesce(p.is_verified,false))
      or (v_status = 'available' and coalesce(p.is_available,false))
    )
    and (p_date_from is null or (p.created_at at time zone 'America/Panama')::date >= p_date_from)
    and (p_date_to is null or (p.created_at at time zone 'America/Panama')::date <= p_date_to)
    and (
      v_search = ''
      or lower(concat_ws(' ',p.id::text,p.display_name,p.full_name,p.email,p.phone,p.whatsapp_phone,p.city,p.provider_status,pm.method_type,pm.bank_name,pm.yappy_phone)) like '%' || v_search || '%'
    )
  order by
    case when not coalesce(p.is_verified,false) and coalesce(p.provider_status,'') <> 'rejected' then 0 else 1 end,
    p.updated_at desc nulls last,
    p.created_at desc
  limit greatest(1, least(coalesce(p_limit,500),2000));
end;
$$;

revoke execute on function public.yt_admin_providers_json(text,text,integer,date,date) from public, anon;
grant execute on function public.yt_admin_providers_json(text,text,integer,date,date) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- M. ADMIN: DETALLE COMPLETO DEL PROVEEDOR
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_provider_detail_json(p_provider_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_profile jsonb;
  v_methods jsonb;
  v_documents jsonb;
  v_stats jsonb;
  v_readiness jsonb;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  select jsonb_build_object(
    'id', p.id,
    'full_name', p.full_name,
    'display_name', p.display_name,
    'email', p.email,
    'phone', p.phone,
    'whatsapp_phone', p.whatsapp_phone,
    'preferred_contact_method', p.preferred_contact_method,
    'city', p.city,
    'bio', p.bio,
    'occupation', p.occupation,
    'languages', p.languages,
    'avatar_url', p.avatar_url,
    'role', p.role,
    'provider_enabled', p.provider_enabled,
    'provider_status', p.provider_status,
    'provider_review_note', p.provider_review_note,
    'is_verified', p.is_verified,
    'is_available', p.is_available,
    'is_suspended', p.is_suspended,
    'suspended_reason', p.suspended_reason,
    'rating_avg', p.rating_avg,
    'approved_at', p.approved_at,
    'approved_by', p.approved_by,
    'created_at', p.created_at,
    'updated_at', p.updated_at
  ) into v_profile
  from public.profiles p
  where p.id = p_provider_id;

  if v_profile is null then raise exception 'Proveedor no encontrado'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'method_type', m.method_type,
    'label', m.label,
    'account_holder', m.account_holder,
    'yappy_phone', m.yappy_phone,
    'bank_name', m.bank_name,
    'bank_account_type', m.bank_account_type,
    'bank_account_number', m.bank_account_number,
    'is_default', m.is_default,
    'is_active', m.is_active,
    'is_verified', m.is_verified,
    'verified_at', m.verified_at,
    'updated_at', m.updated_at
  ) order by m.is_default desc, m.method_type), '[]'::jsonb)
  into v_methods
  from public.provider_payout_methods m
  where m.provider_id = p_provider_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id,
    'document_type', d.document_type,
    'storage_path', d.storage_path,
    'status', d.status,
    'reviewed_by', d.reviewed_by,
    'reviewed_at', d.reviewed_at,
    'admin_note', d.admin_note,
    'created_at', d.created_at,
    'updated_at', d.updated_at,
    'is_latest', d.id = (
      select d2.id from public.identity_documents d2
      where d2.user_id = d.user_id and d2.document_type = d.document_type
      order by d2.created_at desc limit 1
    )
  ) order by d.created_at desc), '[]'::jsonb)
  into v_documents
  from public.identity_documents d
  where d.user_id = p_provider_id
    and d.document_type in ('selfie','police_record','cedula');

  select jsonb_build_object(
    'services', (select count(*) from public.services s where s.provider_id = p_provider_id),
    'active_services', (select count(*) from public.services s where s.provider_id = p_provider_id and s.is_active),
    'bookings', (select count(*) from public.bookings b where b.provider_id = p_provider_id),
    'completed_bookings', (select count(*) from public.bookings b where b.provider_id = p_provider_id and b.status in ('completed_pending_release','completed')),
    'pending_payout_amount', coalesce((select round(sum(greatest(coalesce(b.seller_payout,0),0)),2) from public.bookings b where b.provider_id = p_provider_id and b.payment_status = 'paid' and b.status in ('completed_pending_release','completed') and coalesce(b.payout_release_status,'not_released') <> 'released'),0),
    'paid_payout_amount', coalesce((select round(sum(greatest(coalesce(pp.amount,0),0)),2) from public.provider_payouts pp where pp.provider_id = p_provider_id and pp.status = 'paid'),0)
  ) into v_stats;

  v_readiness := public.yt_provider_verification_readiness_v25(p_provider_id);

  return jsonb_build_object(
    'profile', coalesce(v_profile,'{}'::jsonb),
    'payout_methods', coalesce(v_methods,'[]'::jsonb),
    'documents', coalesce(v_documents,'[]'::jsonb),
    'stats', coalesce(v_stats,'{}'::jsonb),
    'readiness', v_readiness
  );
end;
$$;

revoke execute on function public.yt_admin_provider_detail_json(uuid) from public, anon;
grant execute on function public.yt_admin_provider_detail_json(uuid) to authenticated, service_role;

-- --------------------------------------------------------------------------
-- N. GUARDAS DE NEGOCIO: PROVEEDOR NO VERIFICADO NO OPERA
-- --------------------------------------------------------------------------
create or replace function public.yt_guard_provider_availability_v25()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.is_available = true and coalesce(old.is_available,false) is distinct from true then
    if public.yt_is_provider_profile_v25(new)
       and (coalesce(new.is_verified,false) = false or coalesce(new.provider_status,'pending') <> 'approved') then
      raise exception 'Completa y aprueba la verificación de Ofrecer antes de activar tu disponibilidad';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_guard_provider_availability_v25 on public.profiles;
create trigger profiles_guard_provider_availability_v25
before update of is_available on public.profiles
for each row execute function public.yt_guard_provider_availability_v25();

create or replace function public.yt_guard_new_booking_provider_v25()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_verified boolean;
  v_status text;
  v_suspended boolean;
begin
  -- Las reservas empresariales conservan su propio flujo de aprobación.
  if coalesce(new.is_company_booking,false) then
    return new;
  end if;

  select coalesce(is_verified,false), coalesce(provider_status,'pending'), coalesce(is_suspended,false)
  into v_verified, v_status, v_suspended
  from public.profiles
  where id = new.provider_id;

  if not coalesce(v_verified,false) or coalesce(v_status,'pending') <> 'approved' or coalesce(v_suspended,false) then
    raise exception 'Este proveedor todavía no está habilitado para recibir nuevas reservas';
  end if;

  return new;
end;
$$;

drop trigger if exists bookings_guard_new_provider_v25 on public.bookings;
create trigger bookings_guard_new_provider_v25
before insert on public.bookings
for each row execute function public.yt_guard_new_booking_provider_v25();

create or replace function public.yt_guard_verified_provider_booking_v25()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_verified boolean;
  v_status text;
  v_suspended boolean;
begin
  if new.status is distinct from old.status
     and new.status in ('accepted','completed_pending_release','completed') then
    select coalesce(is_verified,false), coalesce(provider_status,'pending'), coalesce(is_suspended,false)
    into v_verified, v_status, v_suspended
    from public.profiles
    where id = new.provider_id;

    if not coalesce(v_verified,false) or coalesce(v_status,'pending') <> 'approved' or coalesce(v_suspended,false) then
      raise exception 'El proveedor no está habilitado para ejecutar servicios';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists bookings_guard_verified_provider_v25 on public.bookings;
create trigger bookings_guard_verified_provider_v25
before update of status on public.bookings
for each row execute function public.yt_guard_verified_provider_booking_v25();

-- --------------------------------------------------------------------------
-- O. RETIROS DE OFRECER: AÑADE METODO Y DESTINO DE COBRO ENMASCARADO
--    IMPORTANTE: se elimina la firma antes de recrearla porque cambia RETURNS.
-- --------------------------------------------------------------------------
drop function if exists public.yt_admin_withdrawals_json(text,text,integer,date,date);

create function public.yt_admin_withdrawals_json(
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
  payout_release_status text,
  payout_method text,
  payout_destination text
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

  -- 1) Servicios pagados/completados aún no liquidados.
  if v_status in ('all','provider_pending','pending','completed_pending_release','completed','not_released') then
    return query
    select
      b.id::text,
      'provider_pending'::text,
      coalesce(nullif(b.service_title,''),nullif(s.title,''),'Servicio Wissa')::text,
      coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Proveedor')::text,
      b.status::text,
      round(greatest(coalesce(nullif(b.seller_payout,0), greatest(coalesce(b.total_amount,b.subtotal_amount,b.price_snapshot,0) - coalesce(b.platform_fee,0) - coalesce(b.kit_amount,0),0),0),0),2),
      'Wissa'::text,
      coalesce(nullif(b.reservation_code,''),b.id::text)::text,
      coalesce(b.completed_at,b.updated_at,b.created_at),
      b.id,
      b.provider_id,
      b.payment_status::text,
      coalesce(nullif(b.payout_release_status,''),'not_released')::text,
      coalesce(pm.method_type,'Sin método')::text,
      case when pm.id is null then 'Sin configurar'::text else public.yt_mask_payout_destination_v25(pm.method_type,pm.yappy_phone,pm.bank_name,pm.bank_account_number) end
    from public.bookings b
    left join public.services s on s.id = b.service_id
    left join public.profiles p on p.id = b.provider_id
    left join lateral (
      select m.* from public.provider_payout_methods m
      where m.provider_id = b.provider_id and m.is_active
      order by m.is_default desc, m.updated_at desc limit 1
    ) pm on true
    where b.payment_status = 'paid'
      and b.status in ('completed_pending_release','completed')
      and coalesce(b.payout_release_status,'not_released') <> 'released'
      and coalesce(b.refund_status,'not_requested') <> 'refunded'
      and (v_status in ('all','provider_pending','pending','not_released') or lower(b.status) = v_status)
      and (p_date_from is null or (coalesce(b.completed_at,b.updated_at,b.created_at) at time zone 'America/Panama')::date >= p_date_from)
      and (p_date_to is null or (coalesce(b.completed_at,b.updated_at,b.created_at) at time zone 'America/Panama')::date <= p_date_to)
      and (
        v_search = ''
        or lower(concat_ws(' ',b.id::text,b.reservation_code,b.service_title,s.title,p.display_name,p.full_name,p.email,p.phone,p.whatsapp_phone,pm.method_type,pm.bank_name,pm.yappy_phone)) like '%' || v_search || '%'
      )
    order by coalesce(b.completed_at,b.updated_at,b.created_at) desc
    limit v_limit;
  end if;

  -- 2) Liquidaciones ya registradas.
  if v_status in ('all','provider_payout','paid','pending','cancelled') then
    return query
    select
      pp.id::text,
      'provider_payout'::text,
      coalesce(nullif(b.service_title,''),nullif(s.title,''),'Liquidación de servicio')::text,
      coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Proveedor')::text,
      pp.status::text,
      round(greatest(coalesce(pp.amount,0),0),2),
      coalesce(nullif(pp.method,''),'manual')::text,
      coalesce(nullif(pp.reference,''),pp.id::text)::text,
      coalesce(pp.paid_at,pp.created_at),
      pp.booking_id,
      pp.provider_id,
      coalesce(b.payment_status,'paid')::text,
      coalesce(b.payout_release_status,case when pp.status='paid' then 'released' else 'not_released' end)::text,
      coalesce(pm.method_type, nullif(pp.method,''), 'Sin método')::text,
      case when pm.id is null then coalesce(nullif(pp.method,''),'Sin configurar')::text else public.yt_mask_payout_destination_v25(pm.method_type,pm.yappy_phone,pm.bank_name,pm.bank_account_number) end
    from public.provider_payouts pp
    left join public.bookings b on b.id = pp.booking_id
    left join public.services s on s.id = b.service_id
    left join public.profiles p on p.id = pp.provider_id
    left join lateral (
      select m.* from public.provider_payout_methods m
      where m.provider_id = pp.provider_id and m.is_active
      order by m.is_default desc, m.updated_at desc limit 1
    ) pm on true
    where (v_status in ('all','provider_payout') or lower(pp.status) = v_status)
      and (p_date_from is null or (coalesce(pp.paid_at,pp.created_at) at time zone 'America/Panama')::date >= p_date_from)
      and (p_date_to is null or (coalesce(pp.paid_at,pp.created_at) at time zone 'America/Panama')::date <= p_date_to)
      and (
        v_search = ''
        or lower(concat_ws(' ',pp.id::text,pp.reference,pp.method,b.reservation_code,b.service_title,s.title,p.display_name,p.full_name,p.email,p.phone,p.whatsapp_phone,pm.method_type,pm.bank_name,pm.yappy_phone)) like '%' || v_search || '%'
      )
    order by coalesce(pp.paid_at,pp.created_at) desc
    limit v_limit;
  end if;

  -- 3) Solicitudes históricas de payout.
  if v_status in ('all','payout_request','pending','paid','cancelled') then
    return query
    select
      pr.id::text,
      'payout_request'::text,
      'Solicitud de retiro'::text,
      coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Proveedor')::text,
      pr.status::text,
      round(greatest(coalesce(pr.amount,0),0),2),
      'Solicitud proveedor'::text,
      pr.id::text,
      pr.created_at,
      null::uuid,
      pr.provider_id,
      null::text,
      null::text,
      coalesce(pm.method_type,'Sin método')::text,
      case when pm.id is null then 'Sin configurar'::text else public.yt_mask_payout_destination_v25(pm.method_type,pm.yappy_phone,pm.bank_name,pm.bank_account_number) end
    from public.payout_requests pr
    left join public.profiles p on p.id = pr.provider_id
    left join lateral (
      select m.* from public.provider_payout_methods m
      where m.provider_id = pr.provider_id and m.is_active
      order by m.is_default desc, m.updated_at desc limit 1
    ) pm on true
    where (v_status in ('all','payout_request') or lower(pr.status)=v_status)
      and (p_date_from is null or (pr.created_at at time zone 'America/Panama')::date >= p_date_from)
      and (p_date_to is null or (pr.created_at at time zone 'America/Panama')::date <= p_date_to)
      and (v_search='' or lower(concat_ws(' ',pr.id::text,p.display_name,p.full_name,p.email,p.phone,p.whatsapp_phone,pm.method_type,pm.bank_name,pm.yappy_phone)) like '%'||v_search||'%')
    order by pr.created_at desc
    limit v_limit;
  end if;

  -- 4) Solicitudes genéricas legadas.
  if v_status in ('all','withdrawal_request','pending','paid','cancelled') then
    return query
    select
      wr.id::text,
      'withdrawal_request'::text,
      'Solicitud de retiro'::text,
      coalesce(nullif(p.display_name,''),nullif(p.full_name,''),nullif(p.email,''),'Proveedor')::text,
      coalesce(wr.status,'pending')::text,
      round(greatest(coalesce(wr.amount,0),0),2),
      coalesce(nullif(wr.method,''),'Solicitud proveedor')::text,
      coalesce(nullif(wr.note,''),wr.id::text)::text,
      wr.created_at,
      null::uuid,
      wr.user_id,
      null::text,
      null::text,
      coalesce(pm.method_type,nullif(wr.method,''),'Sin método')::text,
      case when pm.id is null then coalesce(nullif(wr.method,''),'Sin configurar')::text else public.yt_mask_payout_destination_v25(pm.method_type,pm.yappy_phone,pm.bank_name,pm.bank_account_number) end
    from public.withdrawal_requests wr
    left join public.profiles p on p.id = wr.user_id
    left join lateral (
      select m.* from public.provider_payout_methods m
      where m.provider_id = wr.user_id and m.is_active
      order by m.is_default desc, m.updated_at desc limit 1
    ) pm on true
    where (v_status in ('all','withdrawal_request') or lower(coalesce(wr.status,'pending'))=v_status)
      and (p_date_from is null or (wr.created_at at time zone 'America/Panama')::date >= p_date_from)
      and (p_date_to is null or (wr.created_at at time zone 'America/Panama')::date <= p_date_to)
      and (v_search='' or lower(concat_ws(' ',wr.id::text,wr.note,wr.method,p.display_name,p.full_name,p.email,p.phone,p.whatsapp_phone,pm.method_type,pm.bank_name,pm.yappy_phone)) like '%'||v_search||'%')
    order by wr.created_at desc
    limit v_limit;
  end if;
end;
$$;

revoke execute on function public.yt_admin_withdrawals_json(text,text,integer,date,date) from public, anon;
grant execute on function public.yt_admin_withdrawals_json(text,text,integer,date,date) to authenticated, service_role;

commit;

-- ============================================================================
-- VALIDACION RAPIDA (NO MODIFICA DATOS)
-- ============================================================================
select
  count(*) filter (where public.yt_is_provider_profile_v25(p)) as ofrecer,
  count(*) filter (where not public.yt_is_provider_profile_v25(p) and coalesce(p.is_admin,false)=false) as clientes
from public.profiles p;

select id, provider_id, method_type, is_default, is_active, is_verified, updated_at
from public.provider_payout_methods
order by updated_at desc
limit 20;

select id, user_id, document_type, status, created_at, reviewed_at
from public.identity_documents
where document_type in ('selfie','police_record','cedula')
order by created_at desc
limit 20;
