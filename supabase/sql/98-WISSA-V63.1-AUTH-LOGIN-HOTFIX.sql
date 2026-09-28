-- ============================================================================
-- WISSA V63.1 - AUTH LOGIN HOTFIX
-- Corrige usuarios creados/actualizados por SQL que provocan:
--   500 / "Database error querying schema"
-- No crea reservas. No borra usuarios.
-- Password de los 5 usuarios demo Ofrecer: Navi1718
-- Idempotente.
-- ============================================================================

begin;
select pg_advisory_xact_lock(hashtext('wissa_v63_1_auth_login_hotfix'));
create extension if not exists pgcrypto;
set local search_path=public,extensions,auth,pg_temp;

-- --------------------------------------------------------------------------
-- 1) GoTrue espera strings vacíos y no NULL en varias columnas de auth.users.
--    Se corrigen solo columnas técnicas de tokens/cambios si existen.
-- --------------------------------------------------------------------------
do $$
declare
  c text;
  cols text[] := array[
    'confirmation_token',
    'recovery_token',
    'email_change',
    'email_change_token_new',
    'email_change_token_current',
    'phone_change',
    'phone_change_token',
    'reauthentication_token'
  ];
begin
  foreach c in array cols loop
    if exists (
      select 1
      from information_schema.columns
      where table_schema='auth' and table_name='users' and column_name=c
    ) then
      execute format('update auth.users set %I = '''' where %I is null', c, c);
    end if;
  end loop;
end $$;

-- --------------------------------------------------------------------------
-- 2) Reparar identities email existentes en general (incluye cuentas antiguas).
--    Esto no cambia correos ni contraseñas; solo alinea la identidad con GoTrue.
-- --------------------------------------------------------------------------
do $$
begin
  if exists(
    select 1 from information_schema.columns
    where table_schema='auth' and table_name='identities' and column_name='provider_id'
  ) then
    update auth.identities i
    set provider_id = i.user_id::text,
        identity_data = coalesce(i.identity_data,'{}'::jsonb)
          || jsonb_build_object(
               'sub', i.user_id::text,
               'email', lower(coalesce(u.email, i.identity_data->>'email','')),
               'email_verified', (u.email_confirmed_at is not null)
             ),
        updated_at = now()
    from auth.users u
    where i.user_id=u.id
      and i.provider='email'
      and (
        i.provider_id is distinct from i.user_id::text
        or coalesce(i.identity_data->>'sub','') <> i.user_id::text
      );
  end if;
end $$;

-- --------------------------------------------------------------------------
-- 3) Definición de usuarios demo Ofrecer.
-- --------------------------------------------------------------------------
create temp table _wissa_demo_offerer(
  email text primary key,
  full_name text not null,
  latitude double precision not null,
  longitude double precision not null,
  location_label text not null,
  user_id uuid
) on commit drop;

insert into _wissa_demo_offerer(email,full_name,latitude,longitude,location_label) values
('luis.miguel@wissa.test','Luis Miguel',8.9981,-79.5367,'Betania, Panamá'),
('ana.torres@wissa.test','Ana Torres',8.9872,-79.5280,'El Ingenio, Panamá'),
('carlos.ruiz@wissa.test','Carlos Ruiz',9.0040,-79.5200,'San Francisco, Panamá'),
('maria.lopez@wissa.test','María López',8.9720,-79.5320,'Bella Vista, Panamá'),
('jose.perez@wissa.test','José Pérez',9.0110,-79.5470,'Condado del Rey, Panamá');

-- --------------------------------------------------------------------------
-- 4) Crear o reparar auth.users con los campos requeridos por GoTrue.
-- --------------------------------------------------------------------------
do $$
declare
  r record;
  v_id uuid;
begin
  for r in select * from _wissa_demo_offerer order by email loop
    select id into v_id
    from auth.users
    where lower(email)=lower(r.email)
    limit 1;

    if v_id is null then
      v_id := gen_random_uuid();

      insert into auth.users(
        instance_id,
        id,
        aud,
        role,
        email,
        encrypted_password,
        email_confirmed_at,
        confirmation_token,
        recovery_token,
        email_change,
        email_change_token_new,
        raw_app_meta_data,
        raw_user_meta_data,
        created_at,
        updated_at
      ) values (
        '00000000-0000-0000-0000-000000000000'::uuid,
        v_id,
        'authenticated',
        'authenticated',
        lower(r.email),
        crypt('Navi1718', gen_salt('bf')),
        now(),
        '',
        '',
        '',
        '',
        jsonb_build_object('provider','email','providers',jsonb_build_array('email')),
        jsonb_build_object('full_name',r.full_name,'role','provider','app_role','provider'),
        now(),
        now()
      );
    else
      update auth.users
      set email = lower(r.email),
          encrypted_password = crypt('Navi1718', gen_salt('bf')),
          email_confirmed_at = coalesce(email_confirmed_at, now()),
          confirmation_token = coalesce(confirmation_token, ''),
          recovery_token = coalesce(recovery_token, ''),
          email_change = coalesce(email_change, ''),
          email_change_token_new = coalesce(email_change_token_new, ''),
          raw_app_meta_data = coalesce(raw_app_meta_data,'{}'::jsonb)
            || jsonb_build_object('provider','email','providers',jsonb_build_array('email')),
          raw_user_meta_data = coalesce(raw_user_meta_data,'{}'::jsonb)
            || jsonb_build_object('full_name',r.full_name,'role','provider','app_role','provider'),
          updated_at = now()
      where id = v_id;
    end if;

    -- Campos añadidos en versiones recientes de GoTrue, si existen.
    if exists(select 1 from information_schema.columns where table_schema='auth' and table_name='users' and column_name='is_sso_user') then
      execute 'update auth.users set is_sso_user=false where id=$1' using v_id;
    end if;
    if exists(select 1 from information_schema.columns where table_schema='auth' and table_name='users' and column_name='is_anonymous') then
      execute 'update auth.users set is_anonymous=false where id=$1' using v_id;
    end if;

    update _wissa_demo_offerer set user_id=v_id where email=r.email;
  end loop;
end $$;

-- --------------------------------------------------------------------------
-- 5) Reparar identities de email de los demos. Para email, provider_id debe apuntar al
--    identificador del usuario. Se adapta a esquemas nuevos/antiguos.
-- --------------------------------------------------------------------------
do $$
declare
  r record;
  has_provider_id boolean;
begin
  select exists(
    select 1 from information_schema.columns
    where table_schema='auth' and table_name='identities' and column_name='provider_id'
  ) into has_provider_id;

  for r in select * from _wissa_demo_offerer order by email loop
    delete from auth.identities where user_id=r.user_id and provider='email';

    if has_provider_id then
      execute $q$
        insert into auth.identities(
          id, provider_id, user_id, identity_data, provider,
          last_sign_in_at, created_at, updated_at
        ) values (
          gen_random_uuid(), $1, $2,
          jsonb_build_object(
            'sub',$1,
            'email',$3,
            'email_verified',true,
            'phone_verified',false
          ),
          'email', null, now(), now()
        )
      $q$ using r.user_id::text, r.user_id, lower(r.email);
    else
      execute $q$
        insert into auth.identities(
          id, user_id, identity_data, provider,
          last_sign_in_at, created_at, updated_at
        ) values (
          gen_random_uuid(), $1,
          jsonb_build_object(
            'sub',$2,
            'email',$3,
            'email_verified',true,
            'phone_verified',false
          ),
          'email', null, now(), now()
        )
      $q$ using r.user_id, r.user_id::text, lower(r.email);
    end if;
  end loop;
end $$;

-- --------------------------------------------------------------------------
-- 6) Perfil Ofrecer y datos funcionales. No crea reservas.
-- --------------------------------------------------------------------------
insert into public.profiles(
  id,full_name,display_name,email,role,status,is_active,is_suspended,is_verified,
  provider_status,provider_enabled,is_available,show_on_map,
  lat,lng,latitude,longitude,location_label,city,
  account_type,mode_preference,bio,updated_at
)
select
  user_id,full_name,full_name,lower(email),'provider','active',true,false,true,
  'approved',true,true,true,
  latitude,longitude,latitude,longitude,location_label,'Panamá',
  'provider','provider','Profesional Wissa.',now()
from _wissa_demo_offerer
on conflict(id) do update set
  full_name=excluded.full_name,
  display_name=excluded.display_name,
  email=excluded.email,
  role='provider',
  status='active',
  is_active=true,
  is_suspended=false,
  is_verified=true,
  provider_status='approved',
  provider_enabled=true,
  is_available=true,
  show_on_map=true,
  lat=excluded.lat,
  lng=excluded.lng,
  latitude=excluded.latitude,
  longitude=excluded.longitude,
  location_label=excluded.location_label,
  city='Panamá',
  account_type='provider',
  mode_preference='provider',
  updated_at=now();

-- Servicio Limpieza + horario funcional.
do $$
declare
  r record;
  v_service uuid;
begin
  for r in select * from _wissa_demo_offerer order by email loop
    select id into v_service
    from public.services
    where provider_id=r.user_id
      and lower(coalesce(category,''))='limpieza'
    order by updated_at desc nulls last
    limit 1;

    if v_service is null then
      insert into public.services(
        provider_id,title,description,category,price,duration_minutes,is_active,
        offer_location_address,offer_latitude,offer_longitude,source_type,created_by,updated_at
      ) values (
        r.user_id,
        'Limpieza para tu hogar, oficinas u otros.',
        'Servicio de limpieza disponible en Wissa.',
        'Limpieza',35,60,true,
        r.location_label,r.latitude,r.longitude,
        'marketplace',r.user_id,now()
      ) returning id into v_service;
    else
      update public.services
      set is_active=true,
          category='Limpieza',
          offer_location_address=r.location_label,
          offer_latitude=r.latitude,
          offer_longitude=r.longitude,
          source_type=coalesce(source_type,'marketplace'),
          updated_at=now()
      where id=v_service;
    end if;

    delete from public.availability where provider_id=r.user_id;
    insert into public.availability(provider_id,day_of_week,start_time,end_time,is_active)
    select
      r.user_id,
      d,
      case when d=0 then '00:00' else '08:00' end,
      case when d=0 then '00:00' when d=6 then '15:00' else '18:00' end,
      (d<>0)
    from generate_series(0,6) d;

    insert into public.provider_availability_settings(
      provider_id,slot_minutes,default_duration_minutes,buffer_minutes,
      booking_window_days,allow_recurring,external_calendar_enabled,updated_at
    ) values (
      r.user_id,60,60,0,60,false,false,now()
    )
    on conflict(provider_id) do update set
      slot_minutes=60,
      default_duration_minutes=60,
      buffer_minutes=0,
      booking_window_days=60,
      allow_recurring=false,
      external_calendar_enabled=false,
      updated_at=now();
  end loop;
end $$;

commit;

-- Verificación final: no debe haber NULL en los tokens críticos de los demos.
select
  p.full_name,
  p.email,
  p.provider_status,
  p.is_available,
  p.location_label,
  u.email_confirmed_at is not null as correo_confirmado,
  coalesce(u.confirmation_token,'<NULL>') as confirmation_token,
  coalesce(u.recovery_token,'<NULL>') as recovery_token,
  (select count(*) from auth.identities i where i.user_id=u.id and i.provider='email') as identidad_email,
  (select count(*) from public.services s where s.provider_id=p.id and s.is_active=true) as servicios_activos,
  (select count(*) from public.availability a where a.provider_id=p.id and a.is_active=true) as dias_laborables
from public.profiles p
join auth.users u on u.id=p.id
where lower(p.email) in (
  'luis.miguel@wissa.test',
  'ana.torres@wissa.test',
  'carlos.ruiz@wissa.test',
  'maria.lopez@wissa.test',
  'jose.perez@wissa.test'
)
order by p.email;
