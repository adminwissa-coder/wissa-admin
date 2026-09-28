-- ============================================================================
-- WISSA V64.0 - PRODUCTION FLOW
-- Flujo híbrido: pago -> selección de profesionales -> primera aceptación gana
-- para servicios de una sola persona. Mantiene equipo real 2..5 cuando aplica.
-- Incluye movilidad fija interna, recargo por profesionales adicionales,
-- ubicación obligatoria de trabajo, kits y notificaciones de producción.
-- Idempotente. No elimina usuarios ni reservas.
-- ============================================================================
begin;
select pg_advisory_xact_lock(hashtext('wissa_v64_production_flow'));

-- --------------------------------------------------------------------------
-- 1. Reserva: permitir que aún no exista profesional definitivo después del pago.
-- --------------------------------------------------------------------------
alter table public.bookings alter column provider_id drop not null;
alter table public.bookings
  add column if not exists assignment_mode text not null default 'hybrid_post_payment',
  add column if not exists candidate_selection_status text not null default 'not_started',
  add column if not exists candidate_display_count integer not null default 3,
  add column if not exists candidate_select_count integer not null default 2,
  add column if not exists candidate_round integer not null default 0,
  add column if not exists candidate_selected_at timestamptz,
  add column if not exists winner_provider_id uuid references public.profiles(id),
  add column if not exists mobility_fee_per_professional numeric not null default 5,
  add column if not exists mobility_fee_total numeric not null default 0,
  add column if not exists additional_professional_fee_total numeric not null default 0;

-- La tabla de asignaciones también se usa como bandeja de invitaciones.
alter table public.booking_professional_assignments
  add column if not exists invitation_round integer not null default 1,
  add column if not exists invitation_expires_at timestamptz,
  add column if not exists invitation_source text not null default 'wissa',
  add column if not exists is_winner boolean not null default false;

-- --------------------------------------------------------------------------
-- 2. Configuración de producción.
-- --------------------------------------------------------------------------
insert into public.app_settings(key,value,updated_at)
values(
  'wissa_matching',
  jsonb_build_object(
    'primary_radius_km',20,
    'extended_radius_km',35,
    'candidate_display_count',3,
    'candidate_select_count',2,
    'response_timeout_minutes',5,
    'max_candidates_to_evaluate',15,
    'single_worker_mode','client_selects_two_first_accepts',
    'team_mode','first_required_acceptances',
    'provider_location_required',true
  ),
  now()
)
on conflict(key) do update set value=coalesce(public.app_settings.value,'{}'::jsonb)||excluded.value,updated_at=now();

-- Movilidad fija: se integra al valor del servicio y no se muestra como una línea
-- separada al cliente. La distancia queda solo para ordenar candidatos/cobertura.
update public.app_settings
set value = coalesce(value,'{}'::jsonb)
  || jsonb_build_object(
    'pricing_version',64,
    'pricing_revision','64.0',
    'travel_mode','fixed_internal',
    'travel_rate_per_km',0,
    'mobility_fee_per_professional',coalesce(nullif(value->>'mobility_fee_per_professional','')::numeric,5),
    'hide_mobility_from_customer_breakdown',true,
    'additional_professional_fees',coalesce(value->'additional_professional_fees',jsonb_build_object('2',15,'3',15,'4',15,'5',15))
  ),
  updated_at=now()
where key in ('cleaning_pricing','exterior_cleaning_pricing','plumbing_pricing');

-- Limpieza: Kit básico preparado. Los productos sueltos siguen en booking_catalog.
update public.app_settings
set value=jsonb_set(
  jsonb_set(
    jsonb_set(
      jsonb_set(
        jsonb_set(coalesce(value,'{}'::jsonb),'{kits,enabled}','true'::jsonb,true),
        '{kits,basic,title}','"Kit básico"'::jsonb,true),
      '{kits,basic,description}','"Jabón, escoba, trapeador, bolsas de basura y paños de limpieza."'::jsonb,true),
    '{kits,basic,price}','15'::jsonb,true),
  '{kits,premium,title}','"Personalizable"'::jsonb,true),
  updated_at=now()
where key='cleaning_pricing';

-- --------------------------------------------------------------------------
-- 3. Catálogo de productos individuales para Kit personalizable.
--    La inserción se hace solo si existe booking_catalog y sus columnas esperadas.
-- --------------------------------------------------------------------------
do $$
declare v_cat text := 'Limpieza'; begin
  if to_regclass('public.booking_catalog') is not null then
    insert into public.booking_catalog(kind,category_name,name_es,name_en,description_es,description_en,price,active,sort_order)
    select x.kind,x.category_name,x.name_es,x.name_en,x.description_es,x.description_en,x.price,x.active,x.sort_order
    from (values
      ('product',v_cat,'Escoba','Broom','Escoba individual para el servicio.','Individual broom for the service.',5::numeric,true,201),
      ('product',v_cat,'Jabón','Soap','Jabón de limpieza para superficies.','Cleaning soap for surfaces.',5::numeric,true,202),
      ('product',v_cat,'Trapeador','Mop','Trapeador para pisos.','Floor mop.',6::numeric,true,203),
      ('product',v_cat,'Bolsas de basura','Trash bags','Paquete de bolsas de basura.','Pack of trash bags.',4::numeric,true,204),
      ('product',v_cat,'Paños de microfibra','Microfiber cloths','Paquete de paños de microfibra.','Pack of microfiber cloths.',5::numeric,true,205),
      ('product',v_cat,'Desinfectante','Disinfectant','Desinfectante multiuso.','Multi-purpose disinfectant.',6::numeric,true,206),
      ('product',v_cat,'Esponjas','Sponges','Paquete de esponjas.','Pack of sponges.',3::numeric,true,207),
      ('product',v_cat,'Guantes','Gloves','Par de guantes de limpieza.','Pair of cleaning gloves.',4::numeric,true,208),
      ('product',v_cat,'Limpiavidrios','Glass cleaner','Producto para cristales y espejos.','Cleaner for glass and mirrors.',6::numeric,true,209),
      ('product',v_cat,'Desengrasante','Degreaser','Desengrasante para cocina y superficies.','Degreaser for kitchen and surfaces.',7::numeric,true,210)
    ) as x(kind,category_name,name_es,name_en,description_es,description_en,price,active,sort_order)
    where not exists (
      select 1 from public.booking_catalog c
      where c.kind=x.kind and lower(trim(coalesce(c.category_name,'')))=lower(trim(x.category_name))
        and lower(trim(coalesce(c.name_es,'')))=lower(trim(x.name_es))
    );
  end if;
exception when undefined_column then
  -- Instalaciones antiguas pueden tener una forma diferente del catálogo.
  null;
end $$;

-- --------------------------------------------------------------------------
-- 4. Regla de equipo: precios fijos por 2.º, 3.º, 4.º y 5.º profesional.
-- --------------------------------------------------------------------------
alter table public.service_team_rules
  add column if not exists additional_professional_fees jsonb not null default '{"2":15,"3":15,"4":15,"5":15}'::jsonb;

update public.service_team_rules
set additional_professional_fees = coalesce(additional_professional_fees,'{}'::jsonb)
  || jsonb_build_object(
      '2',coalesce(nullif(additional_professional_fees->>'2','')::numeric,nullif(additional_professional_fee::text,'')::numeric,15),
      '3',coalesce(nullif(additional_professional_fees->>'3','')::numeric,nullif(additional_professional_fee::text,'')::numeric,15),
      '4',coalesce(nullif(additional_professional_fees->>'4','')::numeric,nullif(additional_professional_fee::text,'')::numeric,15),
      '5',coalesce(nullif(additional_professional_fees->>'5','')::numeric,nullif(additional_professional_fee::text,'')::numeric,15)
    ),
    updated_at=now();

create or replace function public.yt_v64_team_surcharge(p_category text,p_professionals integer)
returns numeric language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_pricing jsonb; v_total numeric:=0; i int; begin
  select value into v_pricing from public.app_settings
  where key=case
    when lower(translate(coalesce(p_category,''),'íóáéúñ','ioaeun')) like '%plomer%' then 'plumbing_pricing'
    when lower(translate(coalesce(p_category,''),'íóáéúñ','ioaeun')) like '%exterior%' then 'exterior_cleaning_pricing'
    else 'cleaning_pricing' end;
  for i in 2..greatest(1,least(5,coalesce(p_professionals,1))) loop
    v_total:=v_total+greatest(0,coalesce(nullif(v_pricing#>>array['additional_professional_fees',i::text],'')::numeric,15));
  end loop;
  return round(v_total,2);
end; $$;
grant execute on function public.yt_v64_team_surcharge(text,integer) to anon,authenticated,service_role;

-- --------------------------------------------------------------------------
-- 5. La ubicación de trabajo es requisito para recibir solicitudes.
-- --------------------------------------------------------------------------
create or replace function public.yt_v64_provider_ready_for_requests(p_provider_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare p public.profiles%rowtype; v_provider uuid:=coalesce(p_provider_id,auth.uid()); v_has_service boolean:=false; begin
  select * into p from public.profiles where id=v_provider;
  if not found then return jsonb_build_object('ready',false,'reason','Completa tu perfil.'); end if;
  select exists(select 1 from public.services s where s.provider_id=v_provider and coalesce(s.is_active,true)=true) into v_has_service;
  if coalesce(p.provider_status,'')<>'approved' then return jsonb_build_object('ready',false,'reason','Tu cuenta está pendiente de verificación.'); end if;
  if coalesce(p.is_suspended,false) then return jsonb_build_object('ready',false,'reason','Tu cuenta no está disponible para recibir solicitudes.'); end if;
  if coalesce(p.latitude,p.lat) is null or coalesce(p.longitude,p.lng) is null then return jsonb_build_object('ready',false,'reason','Configura tu ubicación de trabajo para recibir solicitudes.'); end if;
  if not v_has_service then return jsonb_build_object('ready',false,'reason','Publica al menos un servicio para recibir solicitudes.'); end if;
  if not coalesce(p.is_available,false) then return jsonb_build_object('ready',false,'reason','Activa tu disponibilidad cuando quieras recibir solicitudes.'); end if;
  return jsonb_build_object('ready',true,'reason','Listo para recibir solicitudes.','latitude',coalesce(p.latitude,p.lat),'longitude',coalesce(p.longitude,p.lng));
end; $$;
grant execute on function public.yt_v64_provider_ready_for_requests(uuid) to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 6. Pago PRIMERO. Se elimina el gate que exigía aceptación antes de checkout.
-- --------------------------------------------------------------------------
drop trigger if exists trg_v62_payment_order_gate on public.payment_orders;
drop trigger if exists trg_v62_sync_paid_team_state on public.bookings;

create or replace function public.yt_v64_sync_paid_booking_state()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_required int; begin
  if coalesce(new.payment_status,'')='paid' and coalesce(old.payment_status,'') is distinct from 'paid' then
    v_required:=greatest(1,least(5,coalesce(new.required_professionals,(new.service_details->>'professionals_required')::int,1)));
    update public.bookings
    set status='paid_pending_acceptance',
        accepted_professionals=0,
        candidate_selection_status=case when v_required=1 then 'awaiting_client_selection' else 'forming_team' end,
        candidate_round=case when v_required=1 then 0 else greatest(candidate_round,1) end,
        payment_unlocked_at=coalesce(payment_unlocked_at,now()),
        updated_at=now()
    where id=new.id;
  end if;
  return new;
end; $$;
create trigger trg_v64_sync_paid_booking_state
after update of payment_status on public.bookings
for each row when (new.payment_status='paid' and old.payment_status is distinct from new.payment_status)
execute function public.yt_v64_sync_paid_booking_state();

-- --------------------------------------------------------------------------
-- 7. Cliente selecciona candidatos después del pago.
--    Para 1 trabajador: exactamente 2 candidatos de los 3 mostrados.
-- --------------------------------------------------------------------------
create or replace function public.yt_v64_select_booking_candidates(p_booking_id uuid,p_provider_ids uuid[])
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  b public.bookings%rowtype; v_required int; v_provider uuid; v_slot int:=0; v_service uuid; v_count int; v_round int;
  v_title text; v_buyer_name text;
begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  if auth.uid() is null or (auth.uid()<>b.buyer_id and not public.yt_admin_is_current_admin()) then raise exception 'No autorizado.'; end if;
  if coalesce(b.payment_status,'')<>'paid' then raise exception 'Primero completa el pago de la reserva.'; end if;
  v_required:=greatest(1,least(5,coalesce(b.required_professionals,1)));
  v_count:=coalesce(array_length(p_provider_ids,1),0);
  if v_required=1 and v_count<>2 then raise exception 'Selecciona exactamente 2 profesionales.'; end if;
  if v_required>1 and v_count<v_required then raise exception 'Selecciona al menos % profesionales.',v_required; end if;
  if v_count>5 then raise exception 'Puedes seleccionar hasta 5 profesionales para esta ronda.'; end if;

  delete from public.booking_professional_assignments
  where booking_id=p_booking_id and status in ('pending','rejected','cancelled');
  v_round:=greatest(coalesce(b.candidate_round,0)+1,1);

  foreach v_provider in array p_provider_ids loop
    if not exists(
      select 1 from public.profiles p
      where p.id=v_provider and coalesce(p.is_active,true)=true and coalesce(p.is_suspended,false)=false
        and coalesce(p.provider_status,'approved')='approved' and coalesce(p.is_available,false)=true
        and coalesce(p.latitude,p.lat) is not null and coalesce(p.longitude,p.lng) is not null
    ) then
      raise exception 'Uno de los profesionales ya no está disponible.';
    end if;
    v_slot:=v_slot+1;
    select s.id into v_service from public.services s
    where s.provider_id=v_provider and coalesce(s.is_active,true)=true
      and (coalesce(b.service_details->>'category','')='' or lower(coalesce(s.category,''))=lower(coalesce(b.service_details->>'category','')))
    order by case when s.id=b.service_id then 0 else 1 end,s.updated_at desc nulls last limit 1;
    insert into public.booking_professional_assignments(booking_id,provider_id,service_id,slot_number,status,invitation_round,invitation_source,invitation_expires_at)
    values(p_booking_id,v_provider,coalesce(v_service,b.service_id),v_slot,'pending',v_round,'client_selection',now()+interval '5 minutes');
  end loop;

  update public.bookings
  set provider_id=null,winner_provider_id=null,accepted_professionals=0,
      selected_professionals=v_count,candidate_round=v_round,candidate_selection_status='waiting_acceptance',candidate_selected_at=now(),
      status='paid_pending_acceptance',updated_at=now()
  where id=p_booking_id;

  select coalesce(s.title,b.service_title,'Servicio Wissa') into v_title from public.services s where s.id=b.service_id;
  select coalesce(p.full_name,p.display_name,'Cliente Wissa') into v_buyer_name from public.profiles p where p.id=b.buyer_id;

  insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read,created_at)
  select a.provider_id,'Nueva solicitud de '||v_buyer_name,
         coalesce(v_title,'Servicio Wissa')||' · Reserva pagada. Revisa los detalles y confirma si puedes realizarla.',
         'booking_request','/main/booking/'||p_booking_id::text,p_booking_id,
         jsonb_build_object('booking_id',p_booking_id,'buyer_name',v_buyer_name,'round',v_round),false,now()
  from public.booking_professional_assignments a where a.booking_id=p_booking_id and a.status='pending';

  return jsonb_build_object('ok',true,'booking_id',p_booking_id,'selected',v_count,'required',v_required,'round',v_round);
end; $$;
grant execute on function public.yt_v64_select_booking_candidates(uuid,uuid[]) to authenticated,service_role;

-- --------------------------------------------------------------------------
-- 8. Primera aceptación gana para reserva de una persona. Para equipo 2..5,
--    se confirman las primeras N aceptaciones y se cierran las demás invitaciones.
-- --------------------------------------------------------------------------
create or replace function public.yt_v64_accept_booking_invitation(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  b public.bookings%rowtype; a public.booking_professional_assignments%rowtype; v_required int; v_accepted int; v_complete boolean;
  v_provider_name text; v_buyer_name text; v_title text;
begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  if coalesce(b.payment_status,'')<>'paid' then raise exception 'Esta reserva todavía no está pagada.'; end if;
  select * into a from public.booking_professional_assignments
  where booking_id=p_booking_id and provider_id=auth.uid() and status='pending'
  order by invitation_round desc,slot_number limit 1 for update;
  if not found then
    if exists(select 1 from public.booking_professional_assignments x where x.booking_id=p_booking_id and x.provider_id=auth.uid() and x.status='cancelled') then
      return jsonb_build_object('ok',false,'already_assigned',true,'message','Otro profesional confirmó este servicio antes.');
    end if;
    raise exception 'Esta solicitud ya no está disponible.';
  end if;

  v_required:=greatest(1,least(5,coalesce(b.required_professionals,1)));
  select count(*) into v_accepted from public.booking_professional_assignments where booking_id=p_booking_id and status in ('accepted','completed');
  if v_accepted>=v_required then
    update public.booking_professional_assignments set status='cancelled',updated_at=now() where id=a.id;
    return jsonb_build_object('ok',false,'already_assigned',true,'message','El servicio ya fue confirmado por otro profesional.');
  end if;

  update public.booking_professional_assignments
  set status='accepted',accepted_at=now(),is_winner=(v_required=1),updated_at=now()
  where id=a.id;
  v_accepted:=v_accepted+1; v_complete:=v_accepted>=v_required;

  if v_complete then
    update public.booking_professional_assignments
    set status='cancelled',updated_at=now()
    where booking_id=p_booking_id and status='pending';
  end if;

  update public.bookings
  set provider_id=case when v_required=1 then auth.uid() else coalesce(provider_id,auth.uid()) end,
      winner_provider_id=case when v_required=1 then auth.uid() else winner_provider_id end,
      accepted_professionals=v_accepted,
      provider_acceptance_at=case when v_complete then coalesce(provider_acceptance_at,now()) else provider_acceptance_at end,
      team_ready_at=case when v_complete then coalesce(team_ready_at,now()) else team_ready_at end,
      candidate_selection_status=case when v_complete then 'confirmed' else 'waiting_acceptance' end,
      status=case when v_complete then 'accepted' else 'paid_pending_acceptance' end,
      updated_at=now()
  where id=p_booking_id;

  perform public.yt_v62_assignment_recalculate(p_booking_id);

  select coalesce(p.full_name,p.display_name,'Profesional Wissa') into v_provider_name from public.profiles p where p.id=auth.uid();
  select coalesce(p.full_name,p.display_name,'Cliente Wissa') into v_buyer_name from public.profiles p where p.id=b.buyer_id;
  select coalesce(s.title,b.service_title,'Servicio Wissa') into v_title from public.services s where s.id=b.service_id;

  insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read,created_at)
  values(
    b.buyer_id,
    case when v_complete then 'Tu reserva está confirmada' else v_provider_name||' confirmó tu servicio' end,
    case when v_complete then v_provider_name||' confirmó. Tu servicio ya está listo para coordinarse.' else v_provider_name||' confirmó. Wissa continúa formando el equipo.' end,
    'booking_accepted','/main/booking/'||p_booking_id::text,p_booking_id,
    jsonb_build_object('provider_name',v_provider_name,'accepted',v_accepted,'required',v_required),false,now()
  );

  if v_complete then
    insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read,created_at)
    select x.provider_id,'Solicitud asignada','Otro profesional confirmó este servicio antes.','booking_closed','/(provider-tabs)/bookings',p_booking_id,
           jsonb_build_object('booking_id',p_booking_id),false,now()
    from public.booking_professional_assignments x
    where x.booking_id=p_booking_id and x.status='cancelled' and x.provider_id<>auth.uid();
  end if;

  return jsonb_build_object('ok',true,'accepted',v_accepted,'required',v_required,'all_accepted',v_complete,'winner',v_required=1 and v_complete,'provider_name',v_provider_name);
end; $$;
grant execute on function public.yt_v64_accept_booking_invitation(uuid) to authenticated,service_role;

create or replace function public.yt_v64_reject_booking_invitation(p_booking_id uuid,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.bookings%rowtype; a public.booking_professional_assignments%rowtype; v_pending int; v_accepted int; v_required int; begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  select * into a from public.booking_professional_assignments where booking_id=p_booking_id and provider_id=auth.uid() and status='pending' order by invitation_round desc,slot_number limit 1 for update;
  if not found then raise exception 'Esta solicitud ya no está disponible.'; end if;
  update public.booking_professional_assignments set status='rejected',rejected_at=now(),rejection_reason=coalesce(nullif(trim(p_reason),''),'No disponible'),updated_at=now() where id=a.id;
  v_required:=greatest(1,least(5,coalesce(b.required_professionals,1)));
  select count(*) into v_pending from public.booking_professional_assignments where booking_id=p_booking_id and status='pending';
  select count(*) into v_accepted from public.booking_professional_assignments where booking_id=p_booking_id and status in ('accepted','completed');
  if v_pending=0 and v_accepted<v_required then
    update public.bookings set candidate_selection_status='needs_reassignment',updated_at=now() where id=p_booking_id;
    insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read,created_at)
    values(b.buyer_id,'Seguimos buscando','Los profesionales seleccionados no pudieron tomar el servicio. Wissa buscará nuevas opciones.','booking_reassign','/main/booking/'||p_booking_id::text,p_booking_id,'{}'::jsonb,false,now());
  end if;
  return jsonb_build_object('ok',true,'pending',v_pending,'accepted',v_accepted,'required',v_required,'needs_reassignment',v_pending=0 and v_accepted<v_required);
end; $$;
grant execute on function public.yt_v64_reject_booking_invitation(uuid,text) to authenticated,service_role;

-- Alias para que pantallas V62 funcionen con la lógica V64 mientras se actualiza Mobile.
create or replace function public.yt_v62_accept_booking_assignment(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin return public.yt_v64_accept_booking_invitation(p_booking_id); end; $$;
create or replace function public.yt_v62_reject_booking_assignment(p_booking_id uuid,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin return public.yt_v64_reject_booking_invitation(p_booking_id,p_reason); end; $$;

-- --------------------------------------------------------------------------
-- 9. Regla de áreas profundas: máximo 2 selecciones. Guardada en app_settings
--    para que Admin/Mobile compartan el mismo criterio.
-- --------------------------------------------------------------------------
insert into public.app_settings(key,value,updated_at)
values('cleaning_deep_rules',jsonb_build_object('max_areas',2),now())
on conflict(key) do update set value=coalesce(public.app_settings.value,'{}'::jsonb)||excluded.value,updated_at=now();

-- --------------------------------------------------------------------------
-- 10. Metadata de release sin texto QA visible.
-- --------------------------------------------------------------------------
insert into public.app_settings(key,value,updated_at)
values('wissa_production_flow',jsonb_build_object(
  'version','64.0',
  'payment_before_provider_selection',true,
  'single_worker_candidates_shown',3,
  'single_worker_candidates_selected',2,
  'first_acceptance_wins',true,
  'one_booking',true,
  'one_payment',true,
  'one_invoice',true,
  'single_confirmed_chat',true,
  'fixed_mobility_fee',5,
  'mobility_hidden_in_customer_breakdown',true,
  'provider_work_location_required',true,
  'primary_radius_km',20,
  'extended_radius_km',35,
  'deep_cleaning_max_areas',2,
  'basic_kit_price',15
),now())
on conflict(key) do update set value=excluded.value,updated_at=now();

commit;
