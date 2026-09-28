-- Wissa Empresas: personal sin sedes/departamentos y vínculo automático con la app
-- Ejecutar después de los SQL anteriores del portal empresa.
-- Este patch NO elimina datos. Oculta sedes/departamentos del flujo y enlaza personal por correo cuando entra en la app.

-- 1) Cuando un usuario se crea o actualiza en profiles con un correo que existe en company_members,
--    queda vinculado automáticamente a esa empresa.
create or replace function public.yt_link_company_member_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(trim(coalesce(new.email, '')));
  v_company_id uuid;
  v_role text;
begin
  if v_email = '' then
    return new;
  end if;

  update public.company_members cm
  set user_id = coalesce(cm.user_id, new.id),
      status = case when coalesce(cm.status, 'invited') in ('invited', 'pending') then 'active' else cm.status end,
      joined_at = coalesce(cm.joined_at, now()),
      accepted_at = coalesce(cm.accepted_at, now()),
      updated_at = now()
  where lower(cm.email) = v_email
    and (cm.user_id is null or cm.user_id = new.id)
    and coalesce(cm.status, 'invited') <> 'removed';

  select cm.company_id,
         coalesce(cm.internal_role, case when cm.role = 'admin_empresa' then 'company_admin' else 'company_staff' end)
  into v_company_id, v_role
  from public.company_members cm
  where cm.user_id = new.id
    and coalesce(cm.status, 'active') = 'active'
  order by case when coalesce(cm.internal_role, cm.role) in ('company_admin', 'admin_empresa') then 0 else 1 end,
           cm.created_at desc nulls last
  limit 1;

  if v_company_id is not null then
    update public.profiles p
    set company_enabled = true,
        active_company_id = v_company_id,
        company_role = coalesce(v_role, 'company_staff'),
        updated_at = now()
    where p.id = new.id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_yt_link_company_member_profile on public.profiles;
create trigger trg_yt_link_company_member_profile
after insert or update of email on public.profiles
for each row
execute function public.yt_link_company_member_profile();

-- 2) Reemplazo compatible: el portal empresa agrega personal sin sede ni departamento.
--    Se mantiene la misma firma para no romper llamadas existentes.
create or replace function public.yt_company_web_create_member(
  p_company_id uuid,
  p_full_name text,
  p_email text,
  p_phone text default null,
  p_department text default null,
  p_position text default null,
  p_internal_role text default 'company_staff',
  p_location_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := lower(trim(coalesce(p_email, '')));
  v_member_id uuid;
  v_existing_user uuid;
  v_role text := case when p_internal_role = 'company_admin' then 'company_admin' else 'company_staff' end;
begin
  if v_user_id is null then
    raise exception 'Debes iniciar sesion.';
  end if;

  if not public.yt_is_company_admin(p_company_id, v_user_id) then
    raise exception 'Solo el Admin Empresa puede agregar personal.';
  end if;

  if nullif(trim(coalesce(p_full_name, '')), '') is null then
    raise exception 'El nombre es obligatorio.';
  end if;

  if v_email = '' then
    raise exception 'El correo es obligatorio.';
  end if;

  select id into v_existing_user
  from public.profiles
  where lower(coalesce(email, '')) = v_email
  limit 1;

  select id into v_member_id
  from public.company_members
  where company_id = p_company_id
    and lower(email) = v_email
  limit 1;

  if v_member_id is not null then
    update public.company_members
    set user_id = coalesce(user_id, v_existing_user),
        full_name = trim(p_full_name),
        phone = nullif(trim(coalesce(p_phone, '')), ''),
        department = null,
        position = nullif(trim(coalesce(p_position, '')), ''),
        location_id = null,
        role = case when v_role = 'company_admin' then 'admin_empresa' else 'operador' end,
        internal_role = v_role,
        status = case when v_existing_user is null then 'invited' else 'active' end,
        can_create_bookings = true,
        can_approve_bookings = (v_role = 'company_admin'),
        can_view_finance = (v_role = 'company_admin'),
        can_manage_staff = (v_role = 'company_admin'),
        accepted_at = case when v_existing_user is null then accepted_at else coalesce(accepted_at, now()) end,
        joined_at = case when v_existing_user is null then joined_at else coalesce(joined_at, now()) end,
        updated_at = now()
    where id = v_member_id;
  else
    insert into public.company_members (
      company_id,
      location_id,
      user_id,
      full_name,
      email,
      phone,
      department,
      position,
      role,
      internal_role,
      status,
      can_create_bookings,
      can_approve_bookings,
      can_view_finance,
      can_manage_staff,
      invited_by,
      invited_at,
      accepted_at,
      joined_at,
      metadata
    ) values (
      p_company_id,
      null,
      v_existing_user,
      trim(p_full_name),
      v_email,
      nullif(trim(coalesce(p_phone, '')), ''),
      null,
      nullif(trim(coalesce(p_position, '')), ''),
      case when v_role = 'company_admin' then 'admin_empresa' else 'operador' end,
      v_role,
      case when v_existing_user is null then 'invited' else 'active' end,
      true,
      (v_role = 'company_admin'),
      (v_role = 'company_admin'),
      (v_role = 'company_admin'),
      v_user_id,
      now(),
      case when v_existing_user is null then null else now() end,
      case when v_existing_user is null then null else now() end,
      jsonb_build_object('source', 'company_web', 'password_managed_by', 'app_user')
    ) returning id into v_member_id;
  end if;

  if v_existing_user is not null then
    update public.profiles
    set company_enabled = true,
        active_company_id = p_company_id,
        company_role = v_role,
        updated_at = now()
    where id = v_existing_user;
  end if;

  return v_member_id;
end;
$$;

grant execute on function public.yt_company_web_create_member(uuid, text, text, text, text, text, text, uuid) to authenticated, service_role;
revoke execute on function public.yt_company_web_create_member(uuid, text, text, text, text, text, text, uuid) from public, anon;

-- 3) Vista útil para el app: servicios empresariales asignados al personal logueado.
--    En la app puedes consultar esta vista para mostrar "Servicios de mi empresa".
create or replace view public.v_company_staff_services as
select
  s.id,
  s.provider_id as staff_user_id,
  s.company_id,
  c.name as company_name,
  s.company_member_id,
  cm.full_name as staff_name,
  cm.email as staff_email,
  s.title,
  s.description,
  s.category,
  s.price,
  s.duration_minutes,
  s.is_active,
  s.created_at,
  s.updated_at
from public.services s
join public.companies c on c.id = s.company_id
left join public.company_members cm on cm.id = s.company_member_id
where coalesce(s.source_type, '') = 'company_service';

grant select on public.v_company_staff_services to authenticated, service_role;
