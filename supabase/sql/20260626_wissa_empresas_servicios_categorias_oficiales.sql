-- Wissa Empresas: servicios oficiales por categoría
-- Aplicar en Supabase SQL Editor después del patch CRUD de empresas.
-- No elimina datos.

alter table public.services
  add column if not exists company_id uuid references public.companies(id),
  add column if not exists company_member_id uuid references public.company_members(id),
  add column if not exists source_type text not null default 'marketplace',
  add column if not exists created_by uuid references public.profiles(id);

create index if not exists idx_services_company_id on public.services(company_id);
create index if not exists idx_services_company_member_id on public.services(company_member_id);

create or replace function public.yt_company_web_create_service(
  p_company_id uuid,
  p_company_member_id uuid,
  p_title text,
  p_description text default null,
  p_category text default 'Limpieza',
  p_price numeric default 0,
  p_duration_minutes integer default 60
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_provider_id uuid;
  v_service_id uuid;
  v_category text := trim(coalesce(p_category, ''));
begin
  if v_user_id is null then
    raise exception 'Debes iniciar sesion.';
  end if;

  if not public.yt_is_company_admin(p_company_id, v_user_id) then
    raise exception 'Solo el Admin Empresa puede crear servicios.';
  end if;

  select cm.user_id
  into v_provider_id
  from public.company_members cm
  where cm.id = p_company_member_id
    and cm.company_id = p_company_id
    and coalesce(cm.status, 'active') in ('active', 'invited');

  if v_provider_id is null then
    raise exception 'El personal seleccionado debe iniciar sesion en Wissa antes de asignarle servicios.';
  end if;

  if nullif(trim(coalesce(p_title, '')), '') is null then
    raise exception 'El titulo del servicio es obligatorio.';
  end if;

  if v_category not in ('Limpieza', 'Plomería', 'Limpieza de exteriores') then
    raise exception 'Selecciona una categoria base: Limpieza, Plomería o Limpieza de exteriores.';
  end if;

  insert into public.services (
    provider_id,
    title,
    description,
    category,
    price,
    duration_minutes,
    is_active,
    company_id,
    company_member_id,
    source_type,
    created_by
  ) values (
    v_provider_id,
    trim(p_title),
    nullif(trim(coalesce(p_description, '')), ''),
    v_category,
    greatest(coalesce(p_price, 0), 0),
    greatest(coalesce(p_duration_minutes, 60), 15),
    true,
    p_company_id,
    p_company_member_id,
    'company_service',
    v_user_id
  ) returning id into v_service_id;

  return v_service_id;
end;
$$;

grant execute on function public.yt_company_web_create_service(uuid, uuid, text, text, text, numeric, integer) to authenticated, service_role;
revoke execute on function public.yt_company_web_create_service(uuid, uuid, text, text, text, numeric, integer) from public, anon;
