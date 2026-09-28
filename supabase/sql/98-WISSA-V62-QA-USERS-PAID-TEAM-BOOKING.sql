-- ============================================================================
-- WISSA V62.0 - USUARIOS QA + ESCENARIOS DE RESERVA
-- Fecha: 2026-09-14
-- Password para TODOS los usuarios QA: Navi1718
--
-- Crea/actualiza:
--   qa.cliente@wissa.test       (Cliente)
--   luis.miguel@wissa.test      (Ofrecer 1)
--   ana.torres@wissa.test       (Ofrecer 2)
--   carlos.ruiz@wissa.test      (Ofrecer 3)
--   maria.lopez@wissa.test      (Ofrecer 4 / reemplazo)
--   jose.perez@wissa.test       (Ofrecer 5 / reemplazo)
--
-- Crea 3 escenarios:
--   A) 1 profesional, SIN pagar -> pago habilitado inmediatamente.
--   B) 2 profesionales, 1/2 aceptado -> pago bloqueado hasta 2/2.
--   C) 3 profesionales, 3/3 aceptados y PAGADA -> flujo multi completo listo
--      para probar detalle, chat/seguimiento, factura PDF y liquidación futura.
--
-- Requiere: V61 + Wissa-V62.0-MIGRATION.sql aplicadas.
-- Es idempotente para los IDs QA definidos abajo.
-- ============================================================================

begin;
select pg_advisory_xact_lock(hashtext('wissa_v62_qa_seed'));

-- Supabase incluye pgcrypto normalmente. Se usa para guardar el password bcrypt.
create extension if not exists pgcrypto;
set local search_path = public, extensions, auth, pg_temp;

create temp table _wissa_qa_users(
  email text primary key,
  full_name text not null,
  kind text not null,
  latitude numeric,
  longitude numeric,
  location_label text,
  user_id uuid
) on commit drop;

insert into _wissa_qa_users(email,full_name,kind,latitude,longitude,location_label)
values
('qa.cliente@wissa.test','Cliente QA Wissa','client',8.9824,-79.5199,'El Dorado, Panamá'),
('luis.miguel@wissa.test','Luis Miguel QA','provider',8.9981,-79.5367,'Betania, Panamá'),
('ana.torres@wissa.test','Ana Torres QA','provider',8.9872,-79.5280,'El Ingenio, Panamá'),
('carlos.ruiz@wissa.test','Carlos Ruiz QA','provider',9.0040,-79.5200,'San Francisco, Panamá'),
('maria.lopez@wissa.test','María López QA','provider',8.9720,-79.5320,'Bella Vista, Panamá'),
('jose.perez@wissa.test','José Pérez QA','provider',9.0110,-79.5470,'Condado del Rey, Panamá');

-- --------------------------------------------------------------------------
-- 1. AUTH USERS. Si el correo ya existe, conserva su UUID y solo resetea
--    password/confirmación. No borra otros usuarios del proyecto.
-- --------------------------------------------------------------------------
do $$
declare
  r record;
  v_id uuid;
begin
  for r in select * from _wissa_qa_users order by email loop
    select u.id into v_id from auth.users u where lower(u.email)=lower(r.email) limit 1;

    if v_id is null then
      v_id := gen_random_uuid();
      insert into auth.users(
        instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
        raw_app_meta_data,raw_user_meta_data,created_at,updated_at
      ) values(
        '00000000-0000-0000-0000-000000000000'::uuid,
        v_id,'authenticated','authenticated',r.email,
        crypt('Navi1718',gen_salt('bf')),
        now(),
        jsonb_build_object('provider','email','providers',jsonb_build_array('email')),
        jsonb_build_object('full_name',r.full_name),
        now(),now()
      );
    else
      update auth.users
         set encrypted_password=crypt('Navi1718',gen_salt('bf')),
             email_confirmed_at=coalesce(email_confirmed_at,now()),
             raw_app_meta_data=coalesce(raw_app_meta_data,'{}'::jsonb) || jsonb_build_object('provider','email','providers',jsonb_build_array('email')),
             raw_user_meta_data=coalesce(raw_user_meta_data,'{}'::jsonb) || jsonb_build_object('full_name',r.full_name),
             updated_at=now()
       where id=v_id;
    end if;

    update _wissa_qa_users set user_id=v_id where email=r.email;
  end loop;
end $$;

-- --------------------------------------------------------------------------
-- 2. PROFILES QA.
-- --------------------------------------------------------------------------
insert into public.profiles(
  id,full_name,display_name,email,role,status,is_active,is_suspended,is_verified,
  provider_status,provider_enabled,is_available,show_on_map,lat,lng,latitude,longitude,
  location_label,city,account_type,mode_preference,updated_at
)
select
  q.user_id,q.full_name,q.full_name,q.email,
  case when q.kind='client' then 'client' else 'provider' end,
  'active',true,false,true,
  case when q.kind='provider' then 'approved' else 'approved' end,
  (q.kind='provider'),(q.kind='provider'),true,
  q.latitude::double precision,q.longitude::double precision,
  q.latitude::double precision,q.longitude::double precision,
  q.location_label,'Panamá',
  case when q.kind='provider' then 'provider' else 'client' end,
  case when q.kind='provider' then 'provider' else 'buyer' end,
  now()
from _wissa_qa_users q
on conflict(id) do update set
  full_name=excluded.full_name,
  display_name=excluded.display_name,
  email=excluded.email,
  role=excluded.role,
  status='active',
  is_active=true,
  is_suspended=false,
  is_verified=true,
  provider_status=excluded.provider_status,
  provider_enabled=excluded.provider_enabled,
  is_available=excluded.is_available,
  show_on_map=true,
  lat=excluded.lat,lng=excluded.lng,latitude=excluded.latitude,longitude=excluded.longitude,
  location_label=excluded.location_label,city=excluded.city,account_type=excluded.account_type,
  mode_preference=excluded.mode_preference,updated_at=now();

-- --------------------------------------------------------------------------
-- 3. SERVICIOS Y DISPONIBILIDAD DE LOS 5 OFRECER QA.
-- --------------------------------------------------------------------------
do $$
declare
  r record;
  v_service_id uuid;
  v_index int:=0;
begin
  for r in select * from _wissa_qa_users where kind='provider' order by email loop
    v_index:=v_index+1;
    v_service_id := case v_index
      when 1 then '62000000-0000-0000-0000-000000000101'::uuid
      when 2 then '62000000-0000-0000-0000-000000000102'::uuid
      when 3 then '62000000-0000-0000-0000-000000000103'::uuid
      when 4 then '62000000-0000-0000-0000-000000000104'::uuid
      else        '62000000-0000-0000-0000-000000000105'::uuid end;

    insert into public.services(
      id,provider_id,title,description,category,price,duration_minutes,is_active,
      offer_location_address,offer_latitude,offer_longitude,source_type,created_by,updated_at
    ) values(
      v_service_id,r.user_id,'[QA V62] Limpieza Wissa',
      'Servicio ficticio para probar equipos, aceptación, pago, ruta y liquidación V62.',
      'Limpieza',35,60,true,r.location_label,r.latitude::double precision,r.longitude::double precision,
      'marketplace',r.user_id,now()
    )
    on conflict(id) do update set
      provider_id=excluded.provider_id,title=excluded.title,description=excluded.description,
      category='Limpieza',price=35,duration_minutes=60,is_active=true,
      offer_location_address=excluded.offer_location_address,
      offer_latitude=excluded.offer_latitude,offer_longitude=excluded.offer_longitude,
      source_type='marketplace',created_by=excluded.created_by,updated_at=now();

    delete from public.availability where provider_id=r.user_id;
    insert into public.availability(provider_id,day_of_week,start_time,end_time,is_active)
    select r.user_id,d,'07:00','19:00',true from generate_series(0,6) d;

    insert into public.provider_availability_settings(
      provider_id,slot_minutes,default_duration_minutes,buffer_minutes,booking_window_days,allow_recurring,external_calendar_enabled,updated_at
    ) values(r.user_id,60,60,0,60,false,false,now())
    on conflict(provider_id) do update set
      slot_minutes=60,default_duration_minutes=60,buffer_minutes=0,booking_window_days=60,
      allow_recurring=false,external_calendar_enabled=false,updated_at=now();
  end loop;
end $$;

-- --------------------------------------------------------------------------
-- 4. LIMPIA SOLO LOS ESCENARIOS QA V62 ANTERIORES.
-- --------------------------------------------------------------------------
delete from public.bookings where id in (
  '62000000-0000-0000-0000-000000001001'::uuid,
  '62000000-0000-0000-0000-000000001002'::uuid,
  '62000000-0000-0000-0000-000000001003'::uuid
);

-- --------------------------------------------------------------------------
-- 5. CREA LOS 3 ESCENARIOS.
-- --------------------------------------------------------------------------
do $$
declare
  v_client uuid;
  v_p1 uuid; v_p2 uuid; v_p3 uuid; v_p4 uuid; v_p5 uuid;
  v_service1 uuid:='62000000-0000-0000-0000-000000000101'::uuid;
  v_b1 uuid:='62000000-0000-0000-0000-000000001001'::uuid;
  v_b2 uuid:='62000000-0000-0000-0000-000000001002'::uuid;
  v_b3 uuid:='62000000-0000-0000-0000-000000001003'::uuid;
  v_rule_single uuid;
  v_rule_two uuid;
  v_rule_three uuid;
  v_destination jsonb:=jsonb_build_object('address','El Dorado, Panamá','latitude',8.9824,'longitude',-79.5199,'source','qa_v62');
begin
  select user_id into v_client from _wissa_qa_users where email='qa.cliente@wissa.test';
  select user_id into v_p1 from _wissa_qa_users where email='luis.miguel@wissa.test';
  select user_id into v_p2 from _wissa_qa_users where email='ana.torres@wissa.test';
  select user_id into v_p3 from _wissa_qa_users where email='carlos.ruiz@wissa.test';
  select user_id into v_p4 from _wissa_qa_users where email='maria.lopez@wissa.test';
  select user_id into v_p5 from _wissa_qa_users where email='jose.perez@wissa.test';

  select id into v_rule_single from public.service_team_rules where category='Limpieza' and cleaning_mode='standard' and property_type='casa' and sqm_min<=70 and sqm_max>=70 order by priority limit 1;
  select id into v_rule_two from public.service_team_rules where category='Limpieza' and cleaning_mode='standard' and property_type='casa' and sqm_min<=300 and sqm_max>=300 order by priority limit 1;
  select id into v_rule_three from public.service_team_rules where category='Limpieza' and cleaning_mode='deep' and property_type='casa' and sqm_min<=300 and sqm_max>=300 order by priority limit 1;

  -- A) 1 profesional: pago habilitado de inmediato, todavía NO pagado.
  insert into public.bookings(
    id,buyer_id,provider_id,service_id,booking_date,booking_time,duration_minutes,location,notes,
    price_snapshot,status,payment_status,subtotal_amount,tax_amount,total_amount,gross_total_amount,
    platform_fee,seller_payout,service_subtotal,kit_amount,travel_fee,travel_distance_km,travel_rate_per_km,
    platform_usage_fee,finance_version,required_professionals,selected_professionals,accepted_professionals,
    team_min_professionals,team_recommended_professionals,team_max_professionals,team_rule_id,
    payment_unlocked_at,commission_rate_snapshot,provider_pool_amount,service_title,service_details,updated_at
  ) values(
    v_b1,v_client,v_p1,v_service1,current_date+1,'08:00',60,'El Dorado, Panamá','[QA V62] Reserva individual: pago habilitado antes de aceptación.',
    35,'pending_payment','pending_payment',40,2.80,42.80,42.80,
    7,31,35,0,3,5,0.60,2,62,1,1,0,1,1,1,v_rule_single,
    now(),0.20,31,'Limpieza estándar QA · 1 profesional',
    jsonb_build_object(
      'qa_scenario','single_payment_enabled','category','Limpieza','cleaning_plan','Limpieza estándar','place_type','Casa','square_meters',70,
      'professionals_required',1,'location',v_destination,
      'travel_distance_by_provider',jsonb_build_object(v_p1::text,5.0),
      'assigned_provider_ids',jsonb_build_array(v_p1),
      'pricing',jsonb_build_object('engine','wissa_pricing_v62','platform_commission_rate',0.20,'tax_rate',0.07,'breakdown',jsonb_build_array(
        jsonb_build_object('key','cleaning_service','label','Limpieza estándar · Casa · 70 m²','value',35,'kind','service'),
        jsonb_build_object('key','travel','label','Traslado','value',3,'kind','travel'),
        jsonb_build_object('key','platform_usage_fee','label','Uso de plataforma','value',2),
        jsonb_build_object('key','tax','label','ITBMS (7%)','value',2.80)
      ))
    ),now()
  );

  insert into public.booking_professional_assignments(booking_id,provider_id,service_id,slot_number,status,created_at,updated_at)
  values(v_b1,v_p1,v_service1,1,'pending',now(),now());
  perform public.yt_v62_assignment_recalculate(v_b1);

  -- B) 2 profesionales: 1/2 aceptado; pago debe seguir BLOQUEADO.
  insert into public.bookings(
    id,buyer_id,provider_id,service_id,booking_date,booking_time,duration_minutes,location,notes,
    price_snapshot,status,payment_status,subtotal_amount,tax_amount,total_amount,gross_total_amount,
    platform_fee,seller_payout,service_subtotal,kit_amount,travel_fee,travel_distance_km,travel_rate_per_km,
    platform_usage_fee,finance_version,required_professionals,selected_professionals,accepted_professionals,
    team_min_professionals,team_recommended_professionals,team_max_professionals,team_rule_id,
    commission_rate_snapshot,provider_pool_amount,service_title,service_details,updated_at
  ) values(
    v_b2,v_client,v_p1,v_service1,current_date+2,'10:00',120,'El Dorado, Panamá','[QA V62] Equipo 2: Luis aceptó, Ana pendiente. Pago bloqueado.',
    285,'pending','not_started',297.20,20.80,318.00,318.00,
    57,240.20,285,0,12.20,20.3333,0.60,2,62,2,2,1,2,2,3,v_rule_two,
    0.20,240.20,'Limpieza estándar QA · equipo 2',
    jsonb_build_object(
      'qa_scenario','team_2_one_of_two','category','Limpieza','cleaning_plan','Limpieza estándar','place_type','Casa','square_meters',300,
      'professionals_required',2,'location',v_destination,
      'travel_distance_by_provider',jsonb_build_object(v_p1::text,8.0,v_p2::text,12.3333),
      'assigned_provider_ids',jsonb_build_array(v_p1,v_p2),
      'pricing',jsonb_build_object('engine','wissa_pricing_v62','platform_commission_rate',0.20,'tax_rate',0.07)
    ),now()
  );
  insert into public.booking_professional_assignments(booking_id,provider_id,service_id,slot_number,status,accepted_at,created_at,updated_at)
  values
    (v_b2,v_p1,v_service1,1,'accepted',now(),now(),now()),
    (v_b2,v_p2,'62000000-0000-0000-0000-000000000102'::uuid,2,'pending',null,now(),now());
  perform public.yt_v62_assignment_recalculate(v_b2);
  update public.bookings set accepted_professionals=1,payment_unlocked_at=null,team_ready_at=null,status='pending',payment_status='not_started' where id=v_b2;

  -- C) 3 profesionales: 3/3 aceptados + pago simulado aprobado.
  --    Deep 300 m² = 330; traslados individuales 5/7/9 km; plataforma 2; ITBMS 7%.
  insert into public.bookings(
    id,buyer_id,provider_id,service_id,booking_date,booking_time,duration_minutes,location,notes,
    price_snapshot,status,payment_status,paid_at,subtotal_amount,tax_amount,total_amount,gross_total_amount,
    platform_fee,seller_payout,service_subtotal,kit_amount,travel_fee,travel_distance_km,travel_rate_per_km,
    platform_usage_fee,finance_version,service_stage,required_professionals,selected_professionals,accepted_professionals,
    team_min_professionals,team_recommended_professionals,team_max_professionals,team_rule_id,
    team_ready_at,payment_unlocked_at,provider_acceptance_at,commission_rate_snapshot,provider_pool_amount,
    service_title,reservation_code,service_details,updated_at
  ) values(
    v_b3,v_client,v_p1,v_service1,current_date+3,'09:00',180,'El Dorado, Panamá','[QA V62] Equipo 3 pagado: listo para probar seguimiento, cierre, PDF y liquidación.',
    330,'accepted','paid',now(),344.60,24.12,368.72,368.72,
    66,276.60,330,0,12.60,21,0.60,2,62,'confirmed',3,3,3,2,3,4,v_rule_three,
    now(),now(),now(),0.20,276.60,
    'Limpieza profunda QA · equipo 3','QA-V62-TEAM3',
    jsonb_build_object(
      'qa_scenario','team_3_paid','category','Limpieza','cleaning_plan','Limpieza profunda','cleaning_type','deep','place_type','Casa','square_meters',300,
      'professionals_required',3,'location',v_destination,
      'travel_distance_by_provider',jsonb_build_object(v_p1::text,5.0,v_p2::text,7.0,v_p3::text,9.0),
      'assigned_provider_ids',jsonb_build_array(v_p1,v_p2,v_p3),
      'travel_matches',jsonb_build_array(
        jsonb_build_object('provider_id',v_p1,'origin_label','Betania, Panamá','distance_km',5.0,'travel_fee',3.0),
        jsonb_build_object('provider_id',v_p2,'origin_label','El Ingenio, Panamá','distance_km',7.0,'travel_fee',4.2),
        jsonb_build_object('provider_id',v_p3,'origin_label','San Francisco, Panamá','distance_km',9.0,'travel_fee',5.4)
      ),
      'pricing',jsonb_build_object(
        'engine','wissa_pricing_v62','platform_commission_rate',0.20,'tax_rate',0.07,'subtotal',344.60,'tax_amount',24.12,'total_amount',368.72,
        'breakdown',jsonb_build_array(
          jsonb_build_object('key','cleaning_service','label','Limpieza estándar · Casa · 300 m²','value',285,'kind','service'),
          jsonb_build_object('key','deep_cleaning','label','Limpieza profunda · 300 m² × USD 0.15','value',45,'kind','service'),
          jsonb_build_object('key','travel','label','Traslado del equipo','value',12.60,'kind','travel'),
          jsonb_build_object('key','platform_usage_fee','label','Uso de plataforma','value',2),
          jsonb_build_object('key','tax','label','ITBMS (7%)','value',24.12)
        )
      )
    ),now()
  );

  insert into public.booking_professional_assignments(booking_id,provider_id,service_id,slot_number,status,accepted_at,created_at,updated_at)
  values
    (v_b3,v_p1,v_service1,1,'accepted',now(),now(),now()),
    (v_b3,v_p2,'62000000-0000-0000-0000-000000000102'::uuid,2,'accepted',now(),now(),now()),
    (v_b3,v_p3,'62000000-0000-0000-0000-000000000103'::uuid,3,'accepted',now(),now(),now());

  perform public.yt_v62_assignment_recalculate(v_b3);
  update public.bookings set
    status='accepted',payment_status='paid',paid_at=coalesce(paid_at,now()),accepted_professionals=3,
    team_ready_at=coalesce(team_ready_at,now()),payment_unlocked_at=coalesce(payment_unlocked_at,now()),
    provider_acceptance_at=coalesce(provider_acceptance_at,now()),service_stage='confirmed',
    seller_payout=provider_pool_amount,updated_at=now()
  where id=v_b3;

  insert into public.payment_orders(
    id,booking_id,buyer_id,provider_id,client_id,provider,amount_total,platform_fee,provider_net,currency,status,
    payment_method,pf_reference,pf_transaction_id,paid_at,created_at,updated_at,kind,method,amount,release_status
  ) values(
    '62000000-0000-0000-0000-000000002003'::uuid,v_b3,v_client,v_p1,v_client,
    'paguelofacil',368.72,68.00,276.60,'USD','approved','card','QA-V62-PF-TEAM3','QA-V62-TXN-TEAM3',now(),now(),now(),'booking','card',368.72,'pending'
  ) on conflict(id) do update set
    status='approved',amount_total=368.72,platform_fee=68.00,provider_net=276.60,paid_at=now(),updated_at=now();

  insert into public.payment_events(payment_order_id,event_type,raw_payload,created_at)
  select '62000000-0000-0000-0000-000000002003'::uuid,'qa_payment_approved',jsonb_build_object('source','Wissa V62 QA','simulated',true,'amount',368.72),now();

  -- Notificaciones útiles para ver el flujo en las cuentas ficticias.
  insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata)
  values
    (v_client,'QA V62 · Equipo 3/3 confirmado','Pago QA aprobado. Tu equipo está confirmado y la reserva está lista para seguimiento.','booking_paid','/main/booking/'||v_b3::text,v_b3,jsonb_build_object('qa',true)),
    (v_p1,'QA V62 · Reserva pagada','Cupo 1/3 confirmado. Pago protegido por Wissa.','booking_paid','/main/booking/'||v_b3::text,v_b3,jsonb_build_object('qa',true,'slot',1)),
    (v_p2,'QA V62 · Reserva pagada','Cupo 2/3 confirmado. Pago protegido por Wissa.','booking_paid','/main/booking/'||v_b3::text,v_b3,jsonb_build_object('qa',true,'slot',2)),
    (v_p3,'QA V62 · Reserva pagada','Cupo 3/3 confirmado. Pago protegido por Wissa.','booking_paid','/main/booking/'||v_b3::text,v_b3,jsonb_build_object('qa',true,'slot',3));
end $$;

commit;

-- --------------------------------------------------------------------------
-- 6. CREDENCIALES Y VALIDACION VISUAL.
-- --------------------------------------------------------------------------
select email,full_name,kind,'Navi1718' as password from (
  values
    ('qa.cliente@wissa.test','Cliente QA Wissa','CLIENTE'),
    ('luis.miguel@wissa.test','Luis Miguel QA','OFRECER'),
    ('ana.torres@wissa.test','Ana Torres QA','OFRECER'),
    ('carlos.ruiz@wissa.test','Carlos Ruiz QA','OFRECER'),
    ('maria.lopez@wissa.test','María López QA','OFRECER / REEMPLAZO'),
    ('jose.perez@wissa.test','José Pérez QA','OFRECER / REEMPLAZO')
) x(email,full_name,kind);

select
  b.id,
  b.service_title,
  b.status,
  b.payment_status,
  b.required_professionals,
  b.accepted_professionals,
  b.payment_unlocked_at,
  b.total_amount,
  b.provider_pool_amount
from public.bookings b
where b.id in (
  '62000000-0000-0000-0000-000000001001'::uuid,
  '62000000-0000-0000-0000-000000001002'::uuid,
  '62000000-0000-0000-0000-000000001003'::uuid
)
order by b.id;

select
  a.booking_id,a.slot_number,p.full_name as profesional,a.status,
  a.service_share,a.travel_distance_km,a.travel_fee,a.net_provider_amount,a.payout_status
from public.booking_professional_assignments a
join public.profiles p on p.id=a.provider_id
where a.booking_id in (
  '62000000-0000-0000-0000-000000001001'::uuid,
  '62000000-0000-0000-0000-000000001002'::uuid,
  '62000000-0000-0000-0000-000000001003'::uuid
)
order by a.booking_id,a.slot_number;
