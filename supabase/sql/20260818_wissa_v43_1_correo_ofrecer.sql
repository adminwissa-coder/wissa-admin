-- WISSA V43.1 - FIX CORREO EN PERFIL DE OFRECER (ADMIN WEB)
-- Ejecutar sobre una base que ya tenga Wissa V43 instalada.
-- Objetivo:
-- 1) Recuperar correos antiguos desde auth.users cuando profiles.email esté vacío.
-- 2) Hacer que el listado y detalle de Ofrecer usen auth.users.email como fallback.
-- 3) No cambia reservas, pagos, promociones ni lógica móvil.

begin;

-- -----------------------------------------------------------------------------
-- A. BACKFILL DE PERFILES ANTIGUOS
-- -----------------------------------------------------------------------------
update public.profiles p
set
  email = lower(trim(u.email)),
  updated_at = now()
from auth.users u
where u.id = p.id
  and nullif(trim(coalesce(p.email, '')), '') is null
  and nullif(trim(coalesce(u.email, '')), '') is not null;

-- -----------------------------------------------------------------------------
-- B. LISTADO ADMIN DE OFERENTES: FALLBACK A AUTH.USERS.EMAIL
-- -----------------------------------------------------------------------------
create or replace function public.yt_admin_providers_json(
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
    coalesce(nullif(trim(p.email), ''), nullif(trim(au.email), ''))::text,
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
  left join auth.users au on au.id = p.id
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
      or lower(concat_ws(' ',
        p.id::text,
        p.display_name,
        p.full_name,
        coalesce(nullif(trim(p.email), ''), nullif(trim(au.email), '')),
        p.phone,
        p.whatsapp_phone,
        p.city,
        p.provider_status,
        pm.method_type,
        pm.bank_name,
        pm.yappy_phone
      )) like '%' || v_search || '%'
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

-- -----------------------------------------------------------------------------
-- C. DETALLE ADMIN DE OFRECER: FALLBACK A AUTH.USERS.EMAIL
-- -----------------------------------------------------------------------------
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
    'email', coalesce(nullif(trim(p.email), ''), nullif(trim(au.email), '')),
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
  left join auth.users au on au.id = p.id
  where p.id = p_provider_id;

  if v_profile is null then
    raise exception 'Proveedor no encontrado';
  end if;

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
    'storage_bucket', d.storage_bucket,
    'document_url', d.document_url,
    'status', d.status,
    'reviewed_by', d.reviewed_by,
    'reviewed_at', d.reviewed_at,
    'admin_note', d.admin_note,
    'created_at', d.created_at,
    'updated_at', d.updated_at,
    'is_latest', d.id = (
      select d2.id
      from public.identity_documents d2
      where d2.user_id = d.user_id and d2.document_type = d.document_type
      order by d2.created_at desc
      limit 1
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

notify pgrst, 'reload schema';

commit;

-- Verificación opcional después de ejecutar:
-- select p.id, p.full_name, p.email as profile_email, u.email as auth_email
-- from public.profiles p
-- join auth.users u on u.id = p.id
-- where lower(coalesce(p.full_name,'')) like '%luis%miguel%';
