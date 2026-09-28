-- ============================================================================
-- WISSA V62.2 - REPARAR / CREAR OFRECER DEMO (SIN CREAR RESERVAS)
-- Password de los 5 usuarios: Navi1718
-- Idempotente. NO crea cliente QA ni reservas de ejemplo.
-- ============================================================================
begin;
select pg_advisory_xact_lock(hashtext('wissa_v62_2_demo_offerer_users'));
create extension if not exists pgcrypto;
set local search_path=public,extensions,auth,pg_temp;

create temp table _wissa_demo_offerer(
  email text primary key, full_name text not null,
  latitude double precision not null, longitude double precision not null,
  location_label text not null, user_id uuid
) on commit drop;

insert into _wissa_demo_offerer(email,full_name,latitude,longitude,location_label) values
('luis.miguel@wissa.test','Luis Miguel QA',8.9981,-79.5367,'Betania, Panamá'),
('ana.torres@wissa.test','Ana Torres QA',8.9872,-79.5280,'El Ingenio, Panamá'),
('carlos.ruiz@wissa.test','Carlos Ruiz QA',9.0040,-79.5200,'San Francisco, Panamá'),
('maria.lopez@wissa.test','María López QA',8.9720,-79.5320,'Bella Vista, Panamá'),
('jose.perez@wissa.test','José Pérez QA',9.0110,-79.5470,'Condado del Rey, Panamá');

do $$
declare r record; v_id uuid;
begin
  for r in select * from _wissa_demo_offerer order by email loop
    select id into v_id from auth.users where lower(email)=lower(r.email) limit 1;
    if v_id is null then
      v_id:=gen_random_uuid();
      insert into auth.users(instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
      values('00000000-0000-0000-0000-000000000000'::uuid,v_id,'authenticated','authenticated',r.email,
        crypt('Navi1718',gen_salt('bf')),now(),
        jsonb_build_object('provider','email','providers',jsonb_build_array('email')),
        jsonb_build_object('full_name',r.full_name),now(),now());
    else
      update auth.users set encrypted_password=crypt('Navi1718',gen_salt('bf')),email_confirmed_at=coalesce(email_confirmed_at,now()),
        raw_app_meta_data=coalesce(raw_app_meta_data,'{}'::jsonb)||jsonb_build_object('provider','email','providers',jsonb_build_array('email')),
        raw_user_meta_data=coalesce(raw_user_meta_data,'{}'::jsonb)||jsonb_build_object('full_name',r.full_name),updated_at=now()
      where id=v_id;
    end if;

    -- GoTrue necesita una identidad email válida. Los seeds anteriores no la creaban.
    delete from auth.identities where user_id=v_id and provider='email';
    insert into auth.identities(id,provider_id,user_id,identity_data,provider,last_sign_in_at,created_at,updated_at)
    values(gen_random_uuid(),lower(r.email),v_id,
      jsonb_build_object('sub',v_id::text,'email',lower(r.email),'email_verified',true,'phone_verified',false),
      'email',null,now(),now());

    update _wissa_demo_offerer set user_id=v_id where email=r.email;
  end loop;
end $$;

insert into public.profiles(
  id,full_name,display_name,email,role,status,is_active,is_suspended,is_verified,provider_status,provider_enabled,is_available,show_on_map,
  lat,lng,latitude,longitude,location_label,city,account_type,mode_preference,bio,updated_at
)
select user_id,full_name,full_name,email,'provider','active',true,false,true,'approved',true,true,true,
  latitude,longitude,latitude,longitude,location_label,'Panamá','provider','provider','Profesional demo Wissa para pruebas funcionales.',now()
from _wissa_demo_offerer
on conflict(id) do update set full_name=excluded.full_name,display_name=excluded.display_name,email=excluded.email,role='provider',status='active',
  is_active=true,is_suspended=false,is_verified=true,provider_status='approved',provider_enabled=true,is_available=true,show_on_map=true,
  lat=excluded.lat,lng=excluded.lng,latitude=excluded.latitude,longitude=excluded.longitude,location_label=excluded.location_label,city='Panamá',
  account_type='provider',mode_preference='provider',updated_at=now();

-- Asegura servicio activo de Limpieza con ubicación base. Conserva otros servicios.
do $$
declare r record; v_service uuid;
begin
  for r in select * from _wissa_demo_offerer order by email loop
    select id into v_service from public.services where provider_id=r.user_id and lower(coalesce(category,''))='limpieza' order by updated_at desc nulls last limit 1;
    if v_service is null then
      insert into public.services(provider_id,title,description,category,price,duration_minutes,is_active,offer_location_address,offer_latitude,offer_longitude,source_type,created_by,updated_at)
      values(r.user_id,'Limpieza para tu hogar, oficinas u otros.','Servicio demo disponible para validar matching, rutas y aceptación.','Limpieza',35,60,true,
        r.location_label,r.latitude,r.longitude,'marketplace',r.user_id,now()) returning id into v_service;
    else
      update public.services set is_active=true,category='Limpieza',offer_location_address=r.location_label,offer_latitude=r.latitude,offer_longitude=r.longitude,
        source_type=coalesce(source_type,'marketplace'),updated_at=now() where id=v_service;
    end if;

    -- Lunes-Sábado activos. Domingo explícitamente cerrado para validar el motor de agenda.
    delete from public.availability where provider_id=r.user_id;
    insert into public.availability(provider_id,day_of_week,start_time,end_time,is_active)
    select r.user_id,d,case when d=0 then '00:00' else '08:00' end,case when d=0 then '00:00' else case when d=6 then '15:00' else '18:00' end end,(d<>0)
    from generate_series(0,6) d;

    insert into public.provider_availability_settings(provider_id,slot_minutes,default_duration_minutes,buffer_minutes,booking_window_days,allow_recurring,external_calendar_enabled,updated_at)
    values(r.user_id,60,60,0,60,false,false,now())
    on conflict(provider_id) do update set slot_minutes=60,default_duration_minutes=60,buffer_minutes=0,booking_window_days=60,
      allow_recurring=false,external_calendar_enabled=false,updated_at=now();
  end loop;
end $$;

commit;

select p.full_name,p.email,p.provider_status,p.is_available,p.location_label,
  (select count(*) from public.services s where s.provider_id=p.id and s.is_active=true) as servicios_activos,
  (select count(*) from public.availability a where a.provider_id=p.id and a.is_active=true) as dias_laborables
from public.profiles p where lower(p.email) in (
 'luis.miguel@wissa.test','ana.torres@wissa.test','carlos.ruiz@wissa.test','maria.lopez@wissa.test','jose.perez@wissa.test'
) order by p.email;
