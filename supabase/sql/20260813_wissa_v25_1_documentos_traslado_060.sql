-- ============================================================================
-- WISSA v25.1 - FIX DOCUMENTOS LEGACY + TRASLADO USD 0.60/KM
-- Fecha: 2026-08-13
--
-- Corrige:
--  1) Admin Abrir/Descargar documentos antiguos del bucket identity-documents.
--  2) Compatibilidad record_policivo -> police_record.
--  3) Documentos antiguos auto-aprobados vuelven a revisión manual.
--  4) Nuevos documentos guardan su bucket real.
--  5) Traslado cambia de USD 1.60/km a USD 0.60/km para nuevas reservas.
--
-- No recalcula reservas ya pagadas/completadas.
-- ============================================================================

begin;

-- --------------------------------------------------------------------------
-- A. DOCUMENTOS: IDENTIFICAR BUCKET REAL
-- --------------------------------------------------------------------------
alter table public.identity_documents
  add column if not exists storage_bucket text;

-- Los documentos nuevos v25 usan una carpeta intermedia por tipo.
-- Los documentos legacy se guardaban en identity-documents con forma:
-- <user_id>/<timestamp>-cedula.jpg
update public.identity_documents
set storage_bucket = case
  when coalesce(document_url,'') like '%/provider-verification/%' then 'provider-verification'
  when coalesce(document_url,'') like '%/identity-documents/%' then 'identity-documents'
  when storage_path ~ '^[0-9a-fA-F-]+/(selfie|police_record|cedula)/' then 'provider-verification'
  else 'identity-documents'
end
where nullif(btrim(coalesce(storage_bucket,'')), '') is null;

alter table public.identity_documents
  alter column storage_bucket set default 'provider-verification';

update public.identity_documents
set storage_bucket = 'provider-verification'
where storage_bucket not in ('provider-verification','identity-documents')
   or storage_bucket is null;

-- Normalizar nombre legacy.
update public.identity_documents
set document_type = 'police_record',
    updated_at = now()
where document_type = 'record_policivo';

-- El flujo anterior auto-aprobaba documentos al subirlos. Desde v25 la
-- aprobación debe hacerla Administración manualmente.
update public.identity_documents
set status = 'pending',
    reviewed_by = null,
    reviewed_at = null,
    admin_note = 'Pendiente de revisión manual por Administración de Wissa.',
    updated_at = now()
where storage_bucket = 'identity-documents'
  and (
    lower(coalesce(admin_note,'')) like '%verificación automática%'
    or lower(coalesce(admin_note,'')) like '%verificacion automatica%'
  );

-- Admin puede leer documentos del bucket legacy privado.
drop policy if exists identity_documents_admin_select_v251 on storage.objects;
create policy identity_documents_admin_select_v251
on storage.objects for select
to authenticated
using (
  bucket_id = 'identity-documents'
  and public.yt_admin_is_current_admin()
);

-- --------------------------------------------------------------------------
-- B. RPC APP/ADMIN DEVUELVEN BUCKET REAL
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
      d.storage_bucket,
      d.document_url,
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
    'storage_bucket', d.storage_bucket,
    'document_url', d.document_url,
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

-- --------------------------------------------------------------------------
-- C. TRASLADO: NUEVA TARIFA USD 0.60/KM
-- --------------------------------------------------------------------------
alter table public.bookings
  alter column travel_rate_per_km set default 0.60;

create or replace function public.yt_normalize_service_pricing_value(p_key text, p_value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_key text := lower(trim(coalesce(p_key, '')));
  v_value jsonb := coalesce(p_value, '{}'::jsonb);
  v_exterior boolean := v_key = 'exterior_cleaning_pricing';
  v_progressive jsonb;
  v_default_basic_title text := case when v_exterior then 'Limpieza exterior' else 'Plan Básico' end;
  v_default_premium_title text := case when v_exterior then 'Limpieza exterior' else 'Plan Premium' end;
  v_legacy_fixed numeric;
  v_basic_fixed numeric;
  v_premium_fixed numeric;
  v_legacy_kit numeric;
  v_basic_kit numeric;
  v_premium_kit numeric;
  v_kit_enabled boolean;
  v_inspection_fee numeric;
begin
  if jsonb_typeof(v_value) <> 'object' then
    raise exception 'La configuracion debe ser un objeto JSON';
  end if;

  if v_key in ('cleaning_pricing', 'exterior_cleaning_pricing') then
    v_progressive := public.yt_build_progressive_sqm_prices(v_value, v_exterior);
    v_legacy_fixed := public.yt_safe_numeric(v_value->>'fixed_service_price', 40, 0, 100000);
    v_basic_fixed := public.yt_safe_numeric(v_value #>> '{fixed_service_prices,basica}', v_legacy_fixed, 0, 100000);
    v_premium_fixed := case when v_exterior
      then v_basic_fixed
      else public.yt_safe_numeric(v_value #>> '{fixed_service_prices,premium}', v_legacy_fixed, 0, 100000)
    end;

    v_legacy_kit := public.yt_safe_numeric(v_value->>'cleaning_kit_price', 10, 0, 100000);
    v_basic_kit := public.yt_safe_numeric(v_value #>> '{kits,basic,price}', v_legacy_kit, 0, 100000);
    v_premium_kit := public.yt_safe_numeric(v_value #>> '{kits,premium,price}', greatest(v_basic_kit, 15), 0, 100000);
    v_kit_enabled := case lower(coalesce(v_value #>> '{kits,enabled}', v_value->>'cleaning_kit_enabled', 'true'))
      when 'false' then false when '0' then false when 'no' then false else true end;

    return jsonb_build_object(
      'pricing_version', 22,
      'pricing_mode', 'plan_fixed_plus_progressive_sqm_road_distance',
      'currency', coalesce(nullif(v_value->>'currency', ''), 'USD'),
      'platform_commission_rate', 0.12,
      'fixed_service_price', v_basic_fixed,
      'fixed_service_prices', jsonb_build_object('basica', v_basic_fixed, 'premium', v_premium_fixed),
      'travel_mode', 'road_distance',
      'travel_rate_per_km', 0.60,
      'travel_flat_fee', 0,
      'cleaning_kit_enabled', v_kit_enabled,
      'cleaning_kit_price', v_basic_kit,
      'kits', jsonb_build_object(
        'enabled', v_kit_enabled,
        'basic', jsonb_build_object(
          'title', coalesce(nullif(v_value #>> '{kits,basic,title}', ''), 'Kit Básico'),
          'description', coalesce(nullif(v_value #>> '{kits,basic,description}', ''), 'Insumos básicos administrados por Wissa.'),
          'price', v_basic_kit
        ),
        'premium', jsonb_build_object(
          'title', coalesce(nullif(v_value #>> '{kits,premium,title}', ''), 'Kit Premium'),
          'description', coalesce(nullif(v_value #>> '{kits,premium,description}', ''), 'Insumos premium administrados por Wissa.'),
          'price', v_premium_kit
        )
      ),
      'plan_contents', jsonb_build_object(
        'basica', jsonb_build_object(
          'title', coalesce(nullif(v_value #>> '{plan_contents,basica,title}', ''), v_default_basic_title),
          'summary', coalesce(nullif(v_value #>> '{plan_contents,basica,summary}', ''),
            case when v_exterior then 'Limpieza exterior calculada por metraje real.' else 'Mantenimiento general para espacios con suciedad normal.' end),
          'included', coalesce(
            case when jsonb_typeof(v_value #> '{plan_contents,basica,included}') = 'array' then v_value #> '{plan_contents,basica,included}' end,
            case when v_exterior
              then '["Área exterior seleccionada","Lavado y retiro de suciedad normal","Acceso indicado por el cliente"]'::jsonb
              else '["Pisos y superficies","Cocina y baños","Habitaciones y áreas seleccionadas"]'::jsonb end
          )
        ),
        'premium', jsonb_build_object(
          'title', coalesce(nullif(v_value #>> '{plan_contents,premium,title}', ''), v_default_premium_title),
          'summary', coalesce(nullif(v_value #>> '{plan_contents,premium,summary}', ''),
            case when v_exterior then 'Limpieza exterior calculada por metraje real.' else 'Limpieza profunda para suciedad acumulada y mayor nivel de detalle.' end),
          'included', coalesce(
            case when jsonb_typeof(v_value #> '{plan_contents,premium,included}') = 'array' then v_value #> '{plan_contents,premium,included}' end,
            case when v_exterior
              then '["Área exterior seleccionada","Atención de suciedad acumulada","Acceso indicado por el cliente"]'::jsonb
              else '["Todo lo del plan básico","Detalle de superficies y bordes","Áreas premium seleccionadas"]'::jsonb end
          )
        )
      ),
      'plans', jsonb_build_object('basica', 0, 'premium', 0),
      'included_square_meters', jsonb_build_object('basica', 0, 'premium', 0),
      'place_rates', coalesce(v_value->'place_rates', '{}'::jsonb),
      'progressive_prices', v_progressive,
      'range_prices', public.yt_progressive_prices_to_ranges(v_progressive)
    );
  end if;

  if v_key = 'plumbing_pricing' then
    v_inspection_fee := public.yt_safe_numeric(
      coalesce(v_value->>'inspection_fee', v_value #>> '{job_base,revision}'),
      20, 0, 100000
    );
    v_basic_kit := public.yt_safe_numeric(v_value #>> '{kits,basic,price}', 10, 0, 100000);
    v_premium_kit := public.yt_safe_numeric(v_value #>> '{kits,premium,price}', 15, 0, 100000);
    v_kit_enabled := case lower(coalesce(v_value #>> '{kits,enabled}', 'true'))
      when 'false' then false when '0' then false when 'no' then false else true end;

    return jsonb_build_object(
      'pricing_version', 22,
      'pricing_mode', 'inspection_plus_road_distance',
      'currency', coalesce(nullif(v_value->>'currency', ''), 'USD'),
      'platform_commission_rate', 0.12,
      'inspection_fee', v_inspection_fee,
      'quote_after_inspection', true,
      'travel_mode', 'road_distance',
      'travel_rate_per_km', 0.60,
      'travel_flat_fee', 0,
      'kits', jsonb_build_object(
        'enabled', v_kit_enabled,
        'basic', jsonb_build_object(
          'title', coalesce(nullif(v_value #>> '{kits,basic,title}', ''), 'Kit Básico'),
          'description', coalesce(nullif(v_value #>> '{kits,basic,description}', ''), 'Insumos básicos para la visita, administrados por Wissa.'),
          'price', v_basic_kit
        ),
        'premium', jsonb_build_object(
          'title', coalesce(nullif(v_value #>> '{kits,premium,title}', ''), 'Kit Premium'),
          'description', coalesce(nullif(v_value #>> '{kits,premium,description}', ''), 'Insumos premium para la visita, administrados por Wissa.'),
          'price', v_premium_kit
        )
      ),
      -- Campos legacy: se preservan para que clientes anteriores no fallen,
      -- pero NO participan en la reserva inicial v22.
      'extra_point_price', public.yt_safe_numeric(v_value->>'extra_point_price', 12, 0, 100000),
      'job_base', jsonb_build_object(
        'revision', v_inspection_fee,
        'fuga', public.yt_safe_numeric(v_value #>> '{job_base,fuga}', 35, 0, 100000),
        'destape', public.yt_safe_numeric(v_value #>> '{job_base,destape}', 40, 0, 100000),
        'grifo', public.yt_safe_numeric(v_value #>> '{job_base,grifo}', 45, 0, 100000),
        'sanitario', public.yt_safe_numeric(v_value #>> '{job_base,sanitario}', 60, 0, 100000),
        'calentador', public.yt_safe_numeric(v_value #>> '{job_base,calentador}', 75, 0, 100000),
        'exterior', public.yt_safe_numeric(v_value #>> '{job_base,exterior}', 50, 0, 100000),
        'otro', 0
      ),
      'complexity_multipliers', coalesce(v_value->'complexity_multipliers', '{"basica":1,"media":1.25,"alta":1.5}'::jsonb),
      'parts', coalesce(v_value->'parts', '{"sin_repuestos":0,"repuestos_basicos":15}'::jsonb)
    );
  end if;

  raise exception 'Configuracion no permitida: %', p_key;
end;
$$;

-- Re-normalizar configuraciones actuales a 0.60/km.
update public.app_settings a
set value = public.yt_normalize_service_pricing_value(a.key, a.value),
    updated_at = now()
where a.key in ('cleaning_pricing', 'exterior_cleaning_pricing', 'plumbing_pricing');

update public.company_service_pricing_settings cps
set value = public.yt_normalize_service_pricing_value(cps.pricing_key, cps.value),
    updated_at = now()
where cps.pricing_key in ('cleaning_pricing', 'exterior_cleaning_pricing', 'plumbing_pricing');

-- Mantener la tarifa histórica en reservas existentes y usar 0.60 cuando
-- una nueva reserva no trae tarifa explícita.
create or replace function public.yt_booking_financial_allocation_v22()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_service numeric;
  v_kit numeric;
  v_travel numeric;
  v_fee numeric;
begin
  v_kit := greatest(coalesce(nullif(new.kit_amount, 0), public.yt_safe_numeric(new.service_details->>'kit_amount', 0, 0, 1000000), 0), 0);
  v_travel := greatest(coalesce(nullif(new.travel_fee, 0), public.yt_safe_numeric(new.service_details->>'travel_fee', 0, 0, 1000000), 0), 0);
  v_service := greatest(coalesce(nullif(new.service_subtotal, 0), 0), 0);

  -- Compatibilidad con clientes anteriores: derivar servicio del total.
  if v_service <= 0 then
    v_service := greatest(coalesce(new.total_amount, new.subtotal_amount, new.price_snapshot, 0) - v_kit - v_travel, 0);
  end if;

  v_service := round(v_service, 2);
  v_kit := round(v_kit, 2);
  v_travel := round(v_travel, 2);
  v_fee := round(v_service * 0.12, 2);

  new.service_subtotal := v_service;
  new.kit_amount := v_kit;
  new.travel_fee := v_travel;
  new.travel_rate_per_km := coalesce(nullif(new.travel_rate_per_km, 0), 0.60);
  new.platform_fee := v_fee;
  new.wissa_kit_revenue := v_kit;
  new.wissa_total_revenue := round(v_fee + v_kit, 2);
  new.seller_payout := round(greatest(v_service - v_fee, 0) + v_travel, 2);

  return new;
end;
$$;

commit;

-- Validación rápida
select
  key,
  value->>'travel_rate_per_km' as travel_rate_per_km
from public.app_settings
where key in ('cleaning_pricing','exterior_cleaning_pricing','plumbing_pricing')
order by key;

select
  document_type,
  storage_bucket,
  status,
  count(*) as cantidad
from public.identity_documents
group by document_type, storage_bucket, status
order by document_type, storage_bucket, status;
