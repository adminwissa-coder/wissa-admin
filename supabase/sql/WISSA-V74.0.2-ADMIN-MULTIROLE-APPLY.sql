-- WISSA V74.0.2 — ADMIN MULTIROLE ALIGNMENT
-- Incremental / idempotent. Does not delete users or business data.

begin;

-- Clientes debe incluir cuentas con capacidad cliente aunque también tengan Ofrecer.
create or replace function public.yt_admin_clients_json(
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
    and lower(coalesce(p.role,'client')) not in ('admin','super_admin','company','empresa','company_staff','personal_empresa')
    and (
      lower(coalesce(p.role,'client')) in ('client','buyer','contratar','both','ambos')
      or lower(coalesce(p.account_type,'')) in ('client','buyer','contratar','both','ambos')
    )
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
      or lower(concat_ws(' ',p.id::text,p.display_name,p.full_name,p.email,p.phone,p.city,p.role,p.account_type)) like '%' || v_search || '%'
    )
  order by p.created_at desc
  limit greatest(1, least(coalesce(p_limit,500),2000));
end;
$$;

revoke execute on function public.yt_admin_clients_json(text,text,integer,date,date) from public, anon;
grant execute on function public.yt_admin_clients_json(text,text,integer,date,date) to authenticated, service_role;

-- Dashboard usa exactamente la misma noción de profesional independiente que Admin > Ofrecer.
create or replace function public.yt_admin_provider_count_v74()
returns bigint
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_count bigint;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'No autorizado';
  end if;

  select count(*)
  into v_count
  from public.profiles p
  where coalesce(p.is_admin,false) = false
    and (
      coalesce(p.provider_enabled,false)
      or lower(coalesce(p.role,'')) in ('both','ambos')
      or exists (
        select 1
        from public.services s
        where s.provider_id = p.id
          and coalesce(s.source_type,'marketplace') <> 'company_service'
          and s.company_id is null
          and s.company_member_id is null
      )
      or exists (
        select 1
        from public.bookings b
        where b.provider_id = p.id
          and coalesce(b.is_company_booking,false) = false
          and b.company_id is null
          and b.company_member_id is null
          and b.company_booking_id is null
      )
      or (
        lower(coalesce(p.role,'')) in ('vendor','provider','ofrecer')
        and not exists (
          select 1
          from public.company_members cm
          where cm.user_id = p.id
            and cm.status in ('active','invited','pending')
        )
      )
    );

  return coalesce(v_count,0);
end;
$$;

revoke execute on function public.yt_admin_provider_count_v74() from public, anon;
grant execute on function public.yt_admin_provider_count_v74() to authenticated, service_role;

commit;
