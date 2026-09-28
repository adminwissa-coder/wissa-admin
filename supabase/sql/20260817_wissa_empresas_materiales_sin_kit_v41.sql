-- ============================================================================
-- WISSA V41 - EMPRESAS SIN KIT WISSA / MATERIALES E INSUMOS
-- Fecha: 2026-08-17
--
-- REGLA FINAL:
--   * Marketplace / cliente particular: conserva Kit Wissa cuando aplique.
--   * Empresa: Wissa NO vende ni entrega kits.
--   * Limpieza / Limpieza exteriores: materiales e insumos los aporta la empresa.
--   * Plomería: herramientas normales del técnico; repuestos/materiales especiales
--     se cotizan por separado después del diagnóstico.
--   * Toda reserva empresarial fuerza kit_amount = 0 y wissa_kit_revenue = 0.
-- ============================================================================

begin;

-- 1) Sanitiza cualquier configuración de precios empresarial para que nunca
--    herede kits del fallback global ni permita guardarlos por error.
create or replace function public.yt_company_strip_wissa_kits_v41(p_key text, p_value jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_key text := lower(trim(coalesce(p_key, '')));
  v_value jsonb;
  v_policy jsonb;
begin
  if v_key not in ('cleaning_pricing', 'exterior_cleaning_pricing', 'plumbing_pricing') then
    raise exception 'Configuracion no permitida: %', p_key;
  end if;

  v_value := public.yt_normalize_service_pricing_value(v_key, coalesce(p_value, '{}'::jsonb));

  if v_key in ('cleaning_pricing', 'exterior_cleaning_pricing') then
    v_value := jsonb_set(v_value, '{cleaning_kit_enabled}', 'false'::jsonb, true);
    v_value := jsonb_set(v_value, '{cleaning_kit_price}', '0'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,enabled}', 'false'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,basic,price}', '0'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,premium,price}', '0'::jsonb, true);
    v_policy := jsonb_build_object(
      'mode', 'company_provided',
      'label', 'Materiales e insumos proporcionados por la empresa',
      'wissa_kit_enabled', false,
      'description', 'La empresa contratante proporciona los materiales e insumos necesarios. Wissa no entrega kits en servicios empresariales.'
    );
  else
    v_value := jsonb_set(v_value, '{kits,enabled}', 'false'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,basic,price}', '0'::jsonb, true);
    v_value := jsonb_set(v_value, '{kits,premium,price}', '0'::jsonb, true);
    v_policy := jsonb_build_object(
      'mode', 'special_materials_quote',
      'label', 'Repuestos y materiales especiales bajo cotizacion',
      'wissa_kit_enabled', false,
      'description', 'Las herramientas normales del tecnico forman parte del servicio. Repuestos y materiales especiales se cotizan y aprueban por separado.'
    );
  end if;

  return v_value || jsonb_build_object(
    'company_materials_policy', v_policy,
    'company_wissa_kit_enabled', false
  );
end;
$$;

revoke execute on function public.yt_company_strip_wissa_kits_v41(text, jsonb) from public, anon;
grant execute on function public.yt_company_strip_wissa_kits_v41(text, jsonb) to authenticated, service_role;

-- 2) Toda lectura efectiva de tarifas empresariales elimina el Kit Wissa,
--    incluso si la empresa usa como fallback la tarifa global del marketplace.
create or replace function public.yt_effective_company_service_pricing_value(p_company_id uuid, p_key text)
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_key text := lower(trim(coalesce(p_key, '')));
  v_value jsonb;
begin
  if v_key not in ('cleaning_pricing', 'exterior_cleaning_pricing', 'plumbing_pricing') then
    raise exception 'Configuracion no permitida: %', p_key;
  end if;

  select cps.value into v_value
  from public.company_service_pricing_settings cps
  where cps.company_id = p_company_id
    and cps.pricing_key = v_key;

  if v_value is null then
    select a.value into v_value
    from public.app_settings a
    where a.key = v_key;
  end if;

  return public.yt_company_strip_wissa_kits_v41(v_key, coalesce(v_value, '{}'::jsonb));
end;
$$;

-- 3) Guardar precios desde Portal Empresa/Admin Empresa también fuerza sin kit.
create or replace function public.yt_company_update_service_pricing(p_company_id uuid, p_key text, p_value jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_key text := lower(trim(coalesce(p_key, '')));
  v_normalized jsonb;
  v_updated_at timestamptz := now();
  v_synced_services integer := 0;
begin
  if v_user_id is null then raise exception 'Debes iniciar sesion.'; end if;
  if not (public.yt_admin_is_current_admin() or public.yt_is_company_admin(p_company_id, v_user_id)) then
    raise exception 'No autorizado para cambiar las tarifas de esta empresa.';
  end if;
  if v_key not in ('cleaning_pricing', 'exterior_cleaning_pricing', 'plumbing_pricing') then
    raise exception 'Configuracion no permitida: %', p_key;
  end if;
  if not exists (select 1 from public.companies where id = p_company_id) then
    raise exception 'Empresa no encontrada.';
  end if;

  v_normalized := public.yt_company_strip_wissa_kits_v41(v_key, p_value);

  insert into public.company_service_pricing_settings (company_id, pricing_key, value, updated_by, updated_at)
  values (p_company_id, v_key, v_normalized, v_user_id, v_updated_at)
  on conflict (company_id, pricing_key) do update
    set value = excluded.value,
        updated_by = excluded.updated_by,
        updated_at = excluded.updated_at;

  update public.services s
  set price = public.yt_base_service_price(s.category, v_normalized),
      updated_at = v_updated_at
  where s.company_id = p_company_id
    and public.yt_category_matches_pricing_key(s.category, v_key)
    and public.yt_base_service_price(s.category, v_normalized) > 0;
  get diagnostics v_synced_services = row_count;

  return jsonb_build_object(
    'ok', true,
    'key', v_key,
    'value', v_normalized,
    'updated_at', v_updated_at,
    'synced_services', v_synced_services,
    'company_wissa_kit_enabled', false,
    'materials_policy', v_normalized->'company_materials_policy'
  );
end;
$$;

revoke execute on function public.yt_company_update_service_pricing(uuid, text, jsonb) from public, anon;
grant execute on function public.yt_company_update_service_pricing(uuid, text, jsonb) to authenticated, service_role;

-- Normaliza los overrides ya guardados. No toca app_settings: el marketplace
-- particular conserva sus kits normalmente.
update public.company_service_pricing_settings cps
set value = public.yt_company_strip_wissa_kits_v41(cps.pricing_key, cps.value),
    updated_at = now()
where cps.pricing_key in ('cleaning_pricing', 'exterior_cleaning_pricing', 'plumbing_pricing');

-- 4) Guardia dura sobre reservas empresariales. Si cualquier cliente antiguo,
--    pantalla o integración intenta enviar un kit, se elimina antes de guardar.
create or replace function public.yt_company_booking_no_wissa_kit_v41()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_kit numeric := 0;
  v_is_company boolean := false;
  v_category text := '';
  v_policy text;
  v_company_provides boolean := true;
begin
  v_is_company := coalesce(new.is_company_booking, false)
    or new.company_id is not null
    or new.company_booking_id is not null;

  if not v_is_company then
    return new;
  end if;

  v_kit := greatest(
    coalesce(
      nullif(new.kit_amount, 0),
      public.yt_safe_numeric(coalesce(new.service_details, '{}'::jsonb)->>'kit_amount', 0, 0, 1000000),
      0
    ),
    0
  );

  v_category := lower(coalesce(new.service_details->>'category', new.service_title, ''));
  if v_category like '%plomer%' then
    v_company_provides := false;
    v_policy := 'Herramientas normales incluidas; repuestos y materiales especiales se cotizan y aprueban por separado.';
  else
    v_policy := 'La empresa contratante proporciona los materiales e insumos necesarios. Wissa no incluye ni entrega kits empresariales.';
  end if;

  -- Si un cliente antiguo sumó el kit al monto antes de enviar la reserva,
  -- retiramos exactamente ese componente para que la empresa no lo pague.
  if v_kit > 0 then
    if coalesce(new.subtotal_amount, 0) > 0 then
      new.subtotal_amount := round(greatest(new.subtotal_amount - v_kit, 0), 2);
    end if;
    if coalesce(new.total_amount, 0) > 0 then
      new.total_amount := round(greatest(new.total_amount - v_kit, 0), 2);
    end if;
  end if;

  new.kit_amount := 0;
  new.wissa_kit_revenue := 0;
  new.wissa_total_revenue := round(greatest(coalesce(new.platform_fee, 0), 0), 2);
  new.service_details := (coalesce(new.service_details, '{}'::jsonb) - 'cleaning_kit' - 'kit' - 'kit_option')
    || jsonb_build_object(
      'kit_amount', 0,
      'wissa_kit_included', false,
      'company_materials_policy', true,
      'materials_and_supplies_provided_by_company', v_company_provides,
      'materials_policy', v_policy
    );

  return new;
end;
$$;

drop trigger if exists zzzz_company_booking_no_wissa_kit_v41 on public.bookings;
create trigger zzzz_company_booking_no_wissa_kit_v41
before insert or update on public.bookings
for each row execute function public.yt_company_booking_no_wissa_kit_v41();

-- Capa adicional: aunque otro trigger cambie los valores, una reserva nueva o
-- modificada de empresa no puede persistir ingresos de Kit Wissa.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'bookings_company_no_wissa_kit_v41_chk'
      and conrelid = 'public.bookings'::regclass
  ) then
    alter table public.bookings
      add constraint bookings_company_no_wissa_kit_v41_chk
      check (
        not (coalesce(is_company_booking, false) or company_id is not null or company_booking_id is not null)
        or (coalesce(kit_amount, 0) = 0 and coalesce(wissa_kit_revenue, 0) = 0)
      ) not valid;
  end if;
end $$;

comment on function public.yt_company_booking_no_wissa_kit_v41() is
  'V41: fuerza Kit Wissa = 0 en reservas empresariales y registra la politica de materiales e insumos.';

notify pgrst, 'reload schema';

commit;
