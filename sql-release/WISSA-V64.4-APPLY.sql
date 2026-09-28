-- ============================================================================
-- WISSA V64.4 - BOOKING STABILITY / SINGLE APPLY
-- Ejecutar este UNICO archivo para actualizar la base de datos.
-- No borra usuarios ni reservas.
-- ============================================================================

-- Compatibilidad previa: asegura las columnas operativas que usa el flujo
-- de reservas actual antes de recrear funciones/triggers de V64.
begin;
select pg_advisory_xact_lock(hashtext('wissa_v64_4_booking_stability_preflight'));

alter table public.bookings alter column provider_id drop not null;

alter table public.bookings
  add column if not exists required_professionals integer not null default 1,
  add column if not exists selected_professionals integer not null default 0,
  add column if not exists accepted_professionals integer not null default 0,
  add column if not exists team_min_professionals integer not null default 1,
  add column if not exists team_recommended_professionals integer not null default 1,
  add column if not exists team_max_professionals integer not null default 1,
  add column if not exists team_rule_id uuid references public.service_team_rules(id),
  add column if not exists team_ready_at timestamptz,
  add column if not exists payment_unlocked_at timestamptz,
  add column if not exists commission_rate_snapshot numeric not null default 0.20,
  add column if not exists provider_pool_amount numeric not null default 0,
  add column if not exists financial_snapshot jsonb not null default '{}'::jsonb,
  add column if not exists assignment_mode text not null default 'hybrid_post_payment',
  add column if not exists candidate_selection_status text not null default 'not_started',
  add column if not exists candidate_display_count integer not null default 3,
  add column if not exists candidate_select_count integer not null default 2,
  add column if not exists candidate_round integer not null default 0,
  add column if not exists candidate_selected_at timestamptz,
  add column if not exists winner_provider_id uuid references public.profiles(id),
  add column if not exists mobility_fee_per_professional numeric not null default 5,
  add column if not exists mobility_fee_per_booking numeric not null default 5,
  add column if not exists mobility_fee_total numeric not null default 0,
  add column if not exists additional_professional_fee_total numeric not null default 0,
  add column if not exists pricing_strategy text not null default 'metered',
  add column if not exists pricing_block_key text,
  add column if not exists estimated_service_minutes integer,
  add column if not exists service_started_at timestamptz,
  add column if not exists actual_service_minutes integer;

-- La bandeja de invitaciones debe aceptar el nuevo flujo aun si la instalación
-- venía de una versión anterior.
alter table public.booking_professional_assignments
  add column if not exists invitation_round integer not null default 1,
  add column if not exists invitation_expires_at timestamptz,
  add column if not exists invitation_source text not null default 'wissa',
  add column if not exists is_winner boolean not null default false;

commit;

-- WISSA V64.3 MASTER APPLY - ejecutar completo en Supabase SQL Editor
-- Incluye V64.0 + V64.1 + V64.2 + V64.3 en orden.

-- ===== BEGIN 01-WISSA-V64.0-MIGRATION-PRODUCTION-FLOW.sql =====
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

-- ===== END 01-WISSA-V64.0-MIGRATION-PRODUCTION-FLOW.sql =====

-- ===== BEGIN 02-WISSA-V64.1-HYBRID-PRICING.sql =====
-- ==========================================================================
-- WISSA V64.1 - HYBRID PRICING / LARGE JOB TIME BLOCKS
-- 0..250 m2: formula aprobada por metraje.
-- >250 m2: bloques configurables por equipo + tiempo + precio cerrado.
-- Movilidad: un solo monto fijo por reserva; nunca USD/km.
-- Idempotente. No elimina usuarios ni reservas.
-- ==========================================================================
begin;
select pg_advisory_xact_lock(hashtext('wissa_v64_1_hybrid_pricing'));

-- --------------------------------------------------------------------------
-- 1. Snapshot operativo de cada reserva.
-- --------------------------------------------------------------------------
alter table public.bookings
  add column if not exists mobility_fee_per_booking numeric not null default 5,
  add column if not exists pricing_strategy text not null default 'metered',
  add column if not exists pricing_block_key text,
  add column if not exists estimated_service_minutes integer,
  add column if not exists service_started_at timestamptz,
  add column if not exists actual_service_minutes integer;

-- Reservas V64 existentes: la movilidad ya era total interno. Conservar el dato.
update public.bookings
set mobility_fee_per_booking = greatest(0, coalesce(nullif(mobility_fee_total,0), mobility_fee_per_professional, 5))
where mobility_fee_per_booking is null or mobility_fee_per_booking = 5;

-- Captura duración real para poder calibrar los bloques con datos operativos.
-- Funciona con cualquier RPC/UI que actualice service_stage.
create or replace function public.wissa_v64_capture_service_duration()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if new.service_stage is distinct from old.service_stage then
    if new.service_stage='in_service' and new.service_started_at is null then
      new.service_started_at:=now();
    end if;
    if new.service_stage='finished' and new.service_started_at is not null then
      new.actual_service_minutes:=greatest(1,round(extract(epoch from (now()-new.service_started_at))/60.0)::int);
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists trg_wissa_v64_capture_service_duration on public.bookings;
create trigger trg_wissa_v64_capture_service_duration
before update of service_stage on public.bookings
for each row execute function public.wissa_v64_capture_service_duration();

-- --------------------------------------------------------------------------
-- 2. Fuente de verdad de Limpieza.
--    Hasta 250 m2 se replica exactamente la especificacion aprobada:
--      1..60   = 35
--      61..120 = 35 + (m2-60)*0.28
--      121..220= 51.80 + (m2-120)*0.38
--      221..250= 89.80 + (m2-220)*1.00
-- --------------------------------------------------------------------------
update public.app_settings
set value = coalesce(value,'{}'::jsonb)
  || jsonb_build_object(
    'pricing_version',64,
    'pricing_revision','64.1-hybrid',
    'travel_mode','fixed_per_booking_internal',
    'travel_rate_per_km',0,
    'mobility_fee_per_booking',coalesce(nullif(value->>'mobility_fee_per_booking','')::numeric,nullif(value->>'mobility_fee_per_professional','')::numeric,5),
    -- Campo legacy sincronizado para clientes anteriores. Ya no se multiplica por equipo.
    'mobility_fee_per_professional',coalesce(nullif(value->>'mobility_fee_per_booking','')::numeric,nullif(value->>'mobility_fee_per_professional','')::numeric,5),
    'hide_mobility_from_customer_breakdown',true,
    'pricing_strategy','metered_to_250_then_time_blocks',
    'parametric_engine',jsonb_build_object(
      'minimum_price',35,
      'minimum_included_sqm',60,
      'tier1_end_sqm',120,
      'tier1_rate_per_sqm',0.28,
      'tier2_end_sqm',220,
      'tier2_rate_per_sqm',0.38,
      'team_threshold_sqm',250,
      'team_base_price',89.80,
      'team_rate_per_sqm',1.00,
      'continuous_team_pricing',true,
      'quote_threshold_sqm',700,
      'deep_cleaning_rate_per_sqm',0.15,
      'professionals_at_team_threshold',2,
      'max_professionals',5
    ),
    -- Los precios de trabajos >250 m2 quedan en 0 deliberadamente: la arquitectura
    -- esta lista, pero Wissa no debe inventar un precio hasta que negocio lo defina.
    'large_job_blocks',jsonb_build_array(
      jsonb_build_object(
        'key','251_350','label','Más de 250 a 350 m²','min_sqm',250,'max_sqm',350,
        'professionals',2,'estimated_hours',4,'standard_price',0,'deep_price',0,'active',true
      ),
      jsonb_build_object(
        'key','351_500','label','Más de 350 a 500 m²','min_sqm',350,'max_sqm',500,
        'professionals',2,'estimated_hours',6,'standard_price',0,'deep_price',0,'active',true
      ),
      jsonb_build_object(
        'key','501_700','label','Más de 500 a 700 m²','min_sqm',500,'max_sqm',700,
        'professionals',3,'estimated_hours',6,'standard_price',0,'deep_price',0,'active',true
      )
    )
  ),
  updated_at=now()
where key='cleaning_pricing';

-- Movilidad fija por reserva para las demás categorías. No se cambia su motor de precio.
update public.app_settings
set value = coalesce(value,'{}'::jsonb)
  || jsonb_build_object(
    'pricing_version',64,
    'pricing_revision','64.1-fixed-mobility',
    'travel_mode','fixed_per_booking_internal',
    'travel_rate_per_km',0,
    'mobility_fee_per_booking',coalesce(nullif(value->>'mobility_fee_per_booking','')::numeric,nullif(value->>'mobility_fee_per_professional','')::numeric,5),
    'mobility_fee_per_professional',coalesce(nullif(value->>'mobility_fee_per_booking','')::numeric,nullif(value->>'mobility_fee_per_professional','')::numeric,5),
    'hide_mobility_from_customer_breakdown',true
  ),
  updated_at=now()
where key in ('exterior_cleaning_pricing','plumbing_pricing');

-- --------------------------------------------------------------------------
-- 3. Metadata de negocio. No contiene texto QA visible al usuario.
-- --------------------------------------------------------------------------
insert into public.app_settings(key,value,updated_at)
values(
  'wissa_hybrid_pricing',
  jsonb_build_object(
    'revision','64.1',
    'metered_max_sqm',250,
    'large_job_mode','team_time_blocks',
    'large_job_team_is_system_defined',true,
    'candidate_count_is_separate_from_worker_count',true,
    'mobility_mode','fixed_per_booking',
    'mobility_default',5,
    'collect_estimated_duration',true,
    'collect_actual_duration_when_available',true
  ),
  now()
)
on conflict(key) do update set value=excluded.value,updated_at=now();

-- --------------------------------------------------------------------------
-- 4. Reasignación automática para reservas normales (1 profesional final).
--    La primera ronda sigue siendo elegida por el cliente. Si la ronda vence
--    sin aceptación, Wissa usa el resto del pool guardado al crear la reserva.
-- --------------------------------------------------------------------------
alter table public.bookings
  add column if not exists candidate_attempted_provider_ids uuid[] not null default '{}'::uuid[];

-- Recupera historial de intentos existente antes de instalar esta revisión.
update public.bookings b
set candidate_attempted_provider_ids = x.provider_ids
from (
  select booking_id, array_agg(distinct provider_id) filter (where provider_id is not null) as provider_ids
  from public.booking_professional_assignments
  group by booking_id
) x
where x.booking_id=b.id
  and coalesce(cardinality(b.candidate_attempted_provider_ids),0)=0
  and coalesce(cardinality(x.provider_ids),0)>0;

create or replace function public.wissa_v64_track_candidate_attempt()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  update public.bookings b
  set candidate_attempted_provider_ids = array(
        select distinct candidate_id
        from unnest(coalesce(b.candidate_attempted_provider_ids,'{}'::uuid[]) || array[new.provider_id]) candidate_id
        where candidate_id is not null
      ),
      updated_at=now()
  where b.id=new.booking_id;
  return new;
end; $$;

drop trigger if exists trg_wissa_v64_track_candidate_attempt on public.booking_professional_assignments;
create trigger trg_wissa_v64_track_candidate_attempt
after insert on public.booking_professional_assignments
for each row execute function public.wissa_v64_track_candidate_attempt();

-- El tiempo de respuesta se administra desde wissa_matching. Así no queda
-- hardcodeado en Mobile ni en la función de selección inicial.
create or replace function public.wissa_v64_set_invitation_expiry()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare v_minutes integer:=5; begin
  select greatest(1,least(60,coalesce((value->>'response_timeout_minutes')::integer,5)))
  into v_minutes
  from public.app_settings where key='wissa_matching';
  v_minutes:=coalesce(v_minutes,5);
  new.invitation_expires_at:=now()+make_interval(mins=>v_minutes);
  return new;
exception when others then
  new.invitation_expires_at:=now()+interval '5 minutes';
  return new;
end; $$;

drop trigger if exists trg_wissa_v64_set_invitation_expiry on public.booking_professional_assignments;
create trigger trg_wissa_v64_set_invitation_expiry
before insert on public.booking_professional_assignments
for each row when (new.status='pending')
execute function public.wissa_v64_set_invitation_expiry();

create or replace function public.yt_v64_auto_reassign_booking(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  b public.bookings%rowtype;
  v_required integer;
  v_accepted integer:=0;
  v_pending integer:=0;
  v_round integer:=0;
  v_inserted integer:=0;
  v_provider uuid;
  v_service uuid;
  v_candidate jsonb;
  v_attempted uuid[]:='{}'::uuid[];
  v_buyer_name text:='Cliente Wissa';
  v_title text:='Servicio Wissa';
begin
  select * into b from public.bookings where id=p_booking_id for update;
  if not found then return jsonb_build_object('ok',false,'reason','not_found'); end if;
  if coalesce(b.payment_status,'')<>'paid' then return jsonb_build_object('ok',false,'reason','payment_pending'); end if;

  v_required:=greatest(1,least(5,coalesce(b.required_professionals,1)));
  -- El fallback automático solicitado aplica al flujo normal: dos candidatos,
  -- un solo profesional final. Los equipos reales conservan el motor 2..5.
  if v_required<>1 then return jsonb_build_object('ok',true,'reassigned',false,'reason','team_flow'); end if;
  if coalesce(b.status,'') in ('completed','completed_pending_release','cancelled','rejected') then
    return jsonb_build_object('ok',true,'reassigned',false,'reason','closed');
  end if;

  select count(*) into v_accepted
  from public.booking_professional_assignments
  where booking_id=p_booking_id and status in ('accepted','completed');
  if v_accepted>0 then return jsonb_build_object('ok',true,'reassigned',false,'reason','already_confirmed'); end if;

  -- Si todavía hay una invitación vigente, no iniciar otra ronda.
  select count(*) into v_pending
  from public.booking_professional_assignments
  where booking_id=p_booking_id and status='pending'
    and coalesce(invitation_expires_at,now()+interval '1 minute')>now();
  if v_pending>0 then return jsonb_build_object('ok',true,'reassigned',false,'reason','waiting_response'); end if;

  -- Cierra la ronda vencida y libera los slots 1..5 para la siguiente.
  update public.booking_professional_assignments
  set status='cancelled',rejected_at=coalesce(rejected_at,now()),
      rejection_reason=coalesce(nullif(rejection_reason,''),'Tiempo de respuesta agotado'),updated_at=now()
  where booking_id=p_booking_id and status='pending';

  delete from public.booking_professional_assignments
  where booking_id=p_booking_id and status in ('cancelled','rejected');

  v_attempted:=coalesce(b.candidate_attempted_provider_ids,'{}'::uuid[]);
  v_round:=greatest(coalesce(b.candidate_round,0)+1,1);

  for v_candidate in
    select c.item
    from jsonb_array_elements(coalesce(b.service_details->'matching_candidates','[]'::jsonb)) with ordinality c(item,ord)
    where coalesce(c.item->>'provider_id','') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    order by coalesce(nullif(c.item->>'rank','')::integer,c.ord::integer),c.ord
  loop
    exit when v_inserted>=2;
    v_provider:=(v_candidate->>'provider_id')::uuid;
    continue when v_provider=any(v_attempted);

    if not exists(
      select 1 from public.profiles p
      where p.id=v_provider
        and coalesce(p.is_active,true)=true
        and coalesce(p.is_suspended,false)=false
        and coalesce(p.provider_status,'approved')='approved'
        and coalesce(p.is_available,false)=true
        and coalesce(p.latitude,p.lat) is not null
        and coalesce(p.longitude,p.lng) is not null
    ) then continue; end if;

    v_service:=null;
    begin
      v_service:=nullif(v_candidate->>'service_id','')::uuid;
    exception when others then
      v_service:=null;
    end;
    if v_service is null or not exists(
      select 1 from public.services s where s.id=v_service and s.provider_id=v_provider and coalesce(s.is_active,true)=true
    ) then
      select s.id into v_service from public.services s
      where s.provider_id=v_provider and coalesce(s.is_active,true)=true
        and (coalesce(b.service_details->>'category','')='' or lower(coalesce(s.category,''))=lower(coalesce(b.service_details->>'category','')))
      order by case when s.id=b.service_id then 0 else 1 end,s.updated_at desc nulls last limit 1;
    end if;
    continue when v_service is null;

    v_inserted:=v_inserted+1;
    insert into public.booking_professional_assignments(
      booking_id,provider_id,service_id,slot_number,status,invitation_round,invitation_source
    ) values(
      p_booking_id,v_provider,v_service,v_inserted,'pending',v_round,'automatic_reassignment'
    );
    v_attempted:=array_append(v_attempted,v_provider);
  end loop;

  if v_inserted>0 then
    update public.bookings
    set candidate_round=v_round,
        selected_professionals=v_inserted,
        candidate_selection_status='waiting_acceptance',
        candidate_selected_at=now(),
        candidate_attempted_provider_ids=v_attempted,
        updated_at=now()
    where id=p_booking_id;

    select coalesce(p.full_name,p.display_name,'Cliente Wissa') into v_buyer_name from public.profiles p where p.id=b.buyer_id;
    select coalesce(s.title,b.service_title,'Servicio Wissa') into v_title from public.services s where s.id=b.service_id;

    insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read,created_at)
    select a.provider_id,'Nueva solicitud de '||v_buyer_name,
           coalesce(v_title,'Servicio Wissa')||' · Reserva pagada. Confirma si puedes realizarla.',
           'booking_request','/main/booking/'||p_booking_id::text,p_booking_id,
           jsonb_build_object('booking_id',p_booking_id,'buyer_name',v_buyer_name,'round',v_round,'automatic',true),false,now()
    from public.booking_professional_assignments a
    where a.booking_id=p_booking_id and a.status='pending' and a.invitation_round=v_round;

    insert into public.notifications(user_id,title,body,type,screen,related_booking_id,metadata,is_read,created_at)
    values(
      b.buyer_id,'Seguimos buscando',
      'Enviamos tu solicitud a nuevas opciones disponibles. Te avisaremos cuando un profesional confirme.',
      'booking_reassign','/main/booking/'||p_booking_id::text,p_booking_id,
      jsonb_build_object('booking_id',p_booking_id,'round',v_round),false,now()
    );

    return jsonb_build_object('ok',true,'reassigned',true,'round',v_round,'invited',v_inserted);
  end if;

  update public.bookings
  set candidate_selection_status='needs_reassignment',updated_at=now()
  where id=p_booking_id;

  return jsonb_build_object('ok',true,'reassigned',false,'reason','candidate_pool_exhausted');
end; $$;
revoke all on function public.yt_v64_auto_reassign_booking(uuid) from public,anon,authenticated;
grant execute on function public.yt_v64_auto_reassign_booking(uuid) to service_role;

-- Endpoint seguro para que el cliente refresque su propia reserva. El motor solo
-- actúa si la ronda realmente venció; abrir la pantalla no salta el temporizador.
create or replace function public.yt_v64_refresh_candidate_round(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare b public.bookings%rowtype; begin
  select * into b from public.bookings where id=p_booking_id;
  if not found then raise exception 'Reserva no encontrada.'; end if;
  if auth.uid() is null or (auth.uid()<>b.buyer_id and not public.yt_admin_is_current_admin()) then
    return jsonb_build_object('ok',false,'reason','not_applicable');
  end if;
  return public.yt_v64_auto_reassign_booking(p_booking_id);
end; $$;
grant execute on function public.yt_v64_refresh_candidate_round(uuid) to authenticated,service_role;

-- Procesador para Supabase Cron. Si pg_cron ya está habilitado se programa cada
-- minuto; si no está habilitado, el RPC seguro de arriba mantiene el fallback al
-- abrir/refrescar el detalle y la función queda lista para activarla desde Cron.
create or replace function public.yt_v64_process_expired_candidate_rounds()
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare r record; v_count integer:=0; v_result jsonb; begin
  for r in
    select b.id
    from public.bookings b
    where coalesce(b.payment_status,'')='paid'
      and greatest(1,least(5,coalesce(b.required_professionals,1)))=1
      and coalesce(b.status,'')='paid_pending_acceptance'
      and coalesce(b.candidate_selection_status,'') in ('waiting_acceptance','needs_reassignment')
      and not exists(
        select 1 from public.booking_professional_assignments a
        where a.booking_id=b.id and a.status in ('accepted','completed')
      )
      and (
        coalesce(b.candidate_selection_status,'')='needs_reassignment'
        or not exists(
          select 1 from public.booking_professional_assignments a
          where a.booking_id=b.id and a.status='pending'
            and coalesce(a.invitation_expires_at,now()+interval '1 minute')>now()
        )
      )
    order by b.updated_at
    limit 100
  loop
    v_result:=public.yt_v64_auto_reassign_booking(r.id);
    if coalesce((v_result->>'reassigned')::boolean,false) then v_count:=v_count+1; end if;
  end loop;
  return v_count;
end; $$;
revoke all on function public.yt_v64_process_expired_candidate_rounds() from public,anon,authenticated;
grant execute on function public.yt_v64_process_expired_candidate_rounds() to service_role;

-- Actualiza parámetros de negocio sin exponer nombres técnicos en Admin.
update public.app_settings
set value=coalesce(value,'{}'::jsonb)||jsonb_build_object(
  'automatic_reassignment',true,
  'fallback_source','booking_candidate_pool'
),updated_at=now()
where key='wissa_matching';

-- Programa el worker solo cuando pg_cron ya existe en el proyecto. No intenta
-- instalar extensiones ni falla la migración si Cron no está habilitado.
do $$
declare v_job bigint; begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    begin
      execute 'select jobid from cron.job where jobname=''wissa-v64-candidate-fallback'' limit 1' into v_job;
      if v_job is not null then execute format('select cron.unschedule(%s)',v_job); end if;
      execute $cron$select cron.schedule('wissa-v64-candidate-fallback','* * * * *','select public.yt_v64_process_expired_candidate_rounds();')$cron$;
    exception when others then
      null;
    end;
  end if;
end $$;

-- --------------------------------------------------------------------------
-- 5. Administración de cobertura y tiempo de respuesta.
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_matching_settings_json()
returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v jsonb; begin
  if not public.yt_admin_is_current_admin() then raise exception 'No autorizado.'; end if;
  select coalesce(value,'{}'::jsonb) into v from public.app_settings where key='wissa_matching';
  return coalesce(v,'{}'::jsonb);
end; $$;
grant execute on function public.yt_admin_matching_settings_json() to authenticated,service_role;

create or replace function public.yt_admin_update_matching_settings(
  p_primary_radius_km numeric,
  p_extended_radius_km numeric,
  p_response_timeout_minutes integer,
  p_max_candidates_to_evaluate integer default 15
)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v jsonb; begin
  if not public.yt_admin_is_current_admin() then raise exception 'No autorizado.'; end if;
  if coalesce(p_primary_radius_km,0)<=0 then raise exception 'La cobertura inicial debe ser mayor que cero.'; end if;
  if coalesce(p_extended_radius_km,0)<p_primary_radius_km then raise exception 'La cobertura ampliada no puede ser menor que la inicial.'; end if;

  update public.app_settings
  set value=coalesce(value,'{}'::jsonb)||jsonb_build_object(
      'primary_radius_km',round(greatest(1,least(200,p_primary_radius_km)),2),
      'extended_radius_km',round(greatest(p_primary_radius_km,least(300,p_extended_radius_km)),2),
      'response_timeout_minutes',greatest(1,least(60,coalesce(p_response_timeout_minutes,5))),
      'max_candidates_to_evaluate',greatest(3,least(30,coalesce(p_max_candidates_to_evaluate,15))),
      'candidate_display_count',3,
      'candidate_select_count',2,
      'provider_location_required',true,
      'automatic_reassignment',true
    ),updated_at=now()
  where key='wissa_matching'
  returning value into v;

  if v is null then
    insert into public.app_settings(key,value,updated_at)
    values('wissa_matching',jsonb_build_object(
      'primary_radius_km',round(greatest(1,least(200,p_primary_radius_km)),2),
      'extended_radius_km',round(greatest(p_primary_radius_km,least(300,p_extended_radius_km)),2),
      'response_timeout_minutes',greatest(1,least(60,coalesce(p_response_timeout_minutes,5))),
      'max_candidates_to_evaluate',greatest(3,least(30,coalesce(p_max_candidates_to_evaluate,15))),
      'candidate_display_count',3,'candidate_select_count',2,
      'provider_location_required',true,'automatic_reassignment',true
    ),now()) returning value into v;
  end if;
  return v;
end; $$;
grant execute on function public.yt_admin_update_matching_settings(numeric,numeric,integer,integer) to authenticated,service_role;

commit;

-- ===== END 02-WISSA-V64.1-HYBRID-PRICING.sql =====

-- ===== BEGIN 03-WISSA-V64.1-AUTH-LOGIN-HOTFIX.sql =====
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

-- ===== END 03-WISSA-V64.1-AUTH-LOGIN-HOTFIX.sql =====

-- ===== BEGIN 04-WISSA-V64.2-PROVIDER-READY-HOTFIX.sql =====
-- ============================================================================
-- WISSA V64.2 - PROVIDER READY HOTFIX
-- Fecha: 2026-09-15
-- Objetivos:
-- 1) Permitir crear una reserva V64 híbrida sin provider_id antes del pago/selección.
-- 2) Sincronizar ubicación de trabajo cuando ya existe en perfil o servicio.
-- 3) Evitar que el Marketplace ofrezca profesionales que no estén realmente listos.
-- 4) Validar en servidor que toda invitación vaya a un profesional elegible.
-- ============================================================================

begin;
select pg_advisory_xact_lock(hashtext('wissa_v64_2_provider_ready_hotfix'));

-- --------------------------------------------------------------------------
-- A. CORRECCIÓN CRÍTICA: una reserva híbrida nace SIN profesional asignado.
-- El trigger legado V25 interpretaba provider_id=NULL como proveedor inválido.
-- --------------------------------------------------------------------------
create or replace function public.yt_guard_new_booking_provider_v25()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_verified boolean;
  v_status text;
  v_suspended boolean;
begin
  -- Reservas empresariales conservan su flujo propio.
  if coalesce(new.is_company_booking,false) then
    return new;
  end if;

  -- V64: primero se crea/paga una única reserva y después se seleccionan candidatos.
  if new.provider_id is null then
    if coalesce(new.assignment_mode,'') in ('hybrid_post_payment','team_post_payment') then
      return new;
    end if;
    raise exception 'La reserva todavía no tiene un profesional válido asignado';
  end if;

  select coalesce(is_verified,false), coalesce(provider_status,'pending'), coalesce(is_suspended,false)
    into v_verified, v_status, v_suspended
  from public.profiles
  where id = new.provider_id;

  if not coalesce(v_verified,false)
     or coalesce(v_status,'pending') <> 'approved'
     or coalesce(v_suspended,false) then
    raise exception 'Este profesional no está disponible para recibir nuevas solicitudes';
  end if;

  return new;
end;
$$;

-- --------------------------------------------------------------------------
-- B. BACKFILL SEGURO DE UBICACIÓN.
-- No inventa coordenadas en producción: usa perfil <-> último servicio activo.
-- --------------------------------------------------------------------------
with service_location as (
  select distinct on (s.provider_id)
    s.provider_id,
    s.offer_latitude,
    s.offer_longitude,
    nullif(trim(s.offer_location_address),'') as offer_location_address
  from public.services s
  where s.provider_id is not null
    and coalesce(s.is_active,true)=true
    and s.offer_latitude is not null
    and s.offer_longitude is not null
  order by s.provider_id, s.updated_at desc nulls last, s.created_at desc nulls last
)
update public.profiles p
set
  latitude = coalesce(p.latitude,p.lat,sl.offer_latitude),
  longitude = coalesce(p.longitude,p.lng,sl.offer_longitude),
  lat = coalesce(p.lat,p.latitude,sl.offer_latitude),
  lng = coalesce(p.lng,p.longitude,sl.offer_longitude),
  location_label = coalesce(nullif(trim(p.location_label),''),sl.offer_location_address,p.city,'Ubicación de trabajo'),
  updated_at = now()
from service_location sl
where p.id=sl.provider_id
  and (
    coalesce(p.latitude,p.lat) is null
    or coalesce(p.longitude,p.lng) is null
    or nullif(trim(p.location_label),'') is null
  );

-- Si el perfil sí tiene ubicación, sincronizarla al servicio cuando el servicio no la tenga.
update public.services s
set
  offer_latitude = coalesce(s.offer_latitude,p.latitude,p.lat),
  offer_longitude = coalesce(s.offer_longitude,p.longitude,p.lng),
  offer_location_address = coalesce(nullif(trim(s.offer_location_address),''),nullif(trim(p.location_label),''),p.city,'Ubicación de trabajo'),
  updated_at = now()
from public.profiles p
where p.id=s.provider_id
  and coalesce(s.is_active,true)=true
  and coalesce(p.latitude,p.lat) is not null
  and coalesce(p.longitude,p.lng) is not null
  and (
    s.offer_latitude is null
    or s.offer_longitude is null
    or nullif(trim(s.offer_location_address),'') is null
  );

-- Solo activar flags de exposición para perfiles YA aprobados y verificados.
update public.profiles p
set
  provider_enabled=true,
  show_on_map=true,
  updated_at=now()
where (
    coalesce(p.role,'')='provider'
    or coalesce(p.account_type,'')='provider'
    or coalesce(p.mode_preference,'')='provider'
    or exists(select 1 from public.services s where s.provider_id=p.id)
  )
  and coalesce(p.is_verified,false)=true
  and coalesce(p.provider_status,'')='approved'
  and coalesce(p.is_suspended,false)=false
  and coalesce(p.is_active,true)=true
  and coalesce(p.latitude,p.lat) is not null
  and coalesce(p.longitude,p.lng) is not null;

-- --------------------------------------------------------------------------
-- C. MARKETPLACE: solo mostrar opciones que pueden recibir la solicitud.
-- Mantiene exactamente la misma forma/columnas de la vista existente.
-- --------------------------------------------------------------------------
create or replace view public.v_client_marketplace_services as
select
  s.id,
  s.id as service_id,
  s.provider_id,
  s.company_id,
  s.company_member_id,
  s.source_type,
  case
    when s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null
      then 'company_service'
    else 'independent_service'
  end as marketplace_type,
  case
    when s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null
      then 'Personal empresa'
    else 'Independiente'
  end as provider_kind,
  s.title,
  s.description,
  s.category,
  s.price,
  s.duration_minutes,
  s.is_active,
  s.is_featured,
  s.featured_order,
  s.featured_until,
  coalesce(
    nullif(s.offer_location_address, ''),
    case
      when s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null then 'A domicilio'
    end,
    p.location_label,
    c.address,
    c.city,
    p.city
  ) as location_label,
  coalesce(s.offer_latitude, p.latitude, p.lat) as latitude,
  coalesce(s.offer_longitude, p.longitude, p.lng) as longitude,
  p.full_name as staff_name,
  p.avatar_url as staff_avatar_url,
  coalesce(p.rating_avg, 0) as rating_avg,
  coalesce(p.is_verified, false) as staff_verified,
  case
    when s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null
      then coalesce(cm.is_available, true)
    else coalesce(p.is_available, false)
  end as staff_available,
  p.city as staff_city,
  c.name as company_name,
  c.logo_url as company_logo_url,
  c.status as company_status,
  c.subscription_status,
  c.plan_status,
  cm.full_name as company_member_name,
  cm.email as company_member_email,
  cm.status as company_member_status,
  s.created_at,
  s.updated_at
from public.services s
left join public.profiles p on p.id = s.provider_id
left join public.companies c on c.id = s.company_id
left join public.company_members cm on cm.id = s.company_member_id
where s.is_active = true
  and coalesce(p.status, 'active') <> 'suspended'
  and coalesce(p.is_suspended, false) = false
  and coalesce(s.offer_latitude,p.latitude,p.lat) is not null
  and coalesce(s.offer_longitude,p.longitude,p.lng) is not null
  and (
    (
      coalesce(s.source_type, 'normal') <> 'company_service'
      and s.company_id is null
      and s.company_member_id is null
      and coalesce(p.provider_status, '') = 'approved'
      and coalesce(p.is_verified,false)=true
      and coalesce(p.is_available,false)=true
      and coalesce(p.provider_enabled,true)=true
    )
    or
    (
      (s.source_type = 'company_service' or s.company_id is not null or s.company_member_id is not null)
      and s.provider_id is not null
      and coalesce(cm.status, 'active') = 'active'
      and coalesce(cm.is_available,true)=true
      and coalesce(c.subscription_status, c.plan_status, 'active') = 'active'
    )
  );

grant select on public.v_client_marketplace_services to anon, authenticated, service_role;

-- --------------------------------------------------------------------------
-- D. GUARD ÚNICO PARA INVITACIONES/ASIGNACIONES.
-- Evita que caché o clientes antiguos inviten a un profesional no listo.
-- --------------------------------------------------------------------------
create or replace function public.yt_v64_2_guard_assignment_provider_ready()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_company boolean:=false;
  v_ready boolean:=false;
begin
  if new.provider_id is null then
    raise exception 'La solicitud necesita un profesional válido';
  end if;

  select coalesce(b.is_company_booking,false)
    into v_company
  from public.bookings b
  where b.id=new.booking_id;

  if coalesce(v_company,false) then
    select exists(
      select 1
      from public.profiles p
      where p.id=new.provider_id
        and coalesce(p.is_active,true)=true
        and coalesce(p.is_suspended,false)=false
        and coalesce(p.latitude,p.lat) is not null
        and coalesce(p.longitude,p.lng) is not null
    ) into v_ready;
  else
    select exists(
      select 1
      from public.profiles p
      where p.id=new.provider_id
        and coalesce(p.is_active,true)=true
        and coalesce(p.is_suspended,false)=false
        and coalesce(p.is_verified,false)=true
        and coalesce(p.provider_status,'')='approved'
        and coalesce(p.provider_enabled,true)=true
        and coalesce(p.is_available,false)=true
        and coalesce(p.latitude,p.lat) is not null
        and coalesce(p.longitude,p.lng) is not null
        and exists(
          select 1 from public.services s
          where s.provider_id=p.id and coalesce(s.is_active,true)=true
        )
    ) into v_ready;
  end if;

  if not coalesce(v_ready,false) then
    raise exception 'Este profesional ya no está disponible. Wissa buscará otra opción.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_v64_2_assignment_provider_ready_insert on public.booking_professional_assignments;
drop trigger if exists trg_v64_2_assignment_provider_ready_update on public.booking_professional_assignments;

create trigger trg_v64_2_assignment_provider_ready_insert
before insert on public.booking_professional_assignments
for each row
when (new.status in ('pending','accepted'))
execute function public.yt_v64_2_guard_assignment_provider_ready();

create trigger trg_v64_2_assignment_provider_ready_update
before update of provider_id,status on public.booking_professional_assignments
for each row
when (new.status in ('pending','accepted'))
execute function public.yt_v64_2_guard_assignment_provider_ready();

commit;

-- Diagnóstico: todo lo que aparece aquí requiere completar ubicación/estado antes de entrar al Marketplace.
select
  p.id,
  p.full_name,
  p.email,
  p.provider_status,
  p.is_verified,
  p.is_available,
  coalesce(p.latitude,p.lat) as latitude,
  coalesce(p.longitude,p.lng) as longitude,
  p.location_label
from public.profiles p
where (
    coalesce(p.role,'')='provider'
    or coalesce(p.account_type,'')='provider'
    or coalesce(p.mode_preference,'')='provider'
    or exists(select 1 from public.services s where s.provider_id=p.id)
  )
  and (
    coalesce(p.provider_status,'')<>'approved'
    or coalesce(p.is_verified,false)=false
    or coalesce(p.is_available,false)=false
    or coalesce(p.latitude,p.lat) is null
    or coalesce(p.longitude,p.lng) is null
  )
order by p.full_name nulls last, p.email nulls last;

-- ===== END 04-WISSA-V64.2-PROVIDER-READY-HOTFIX.sql =====

-- ===== BEGIN 06-WISSA-V64.3-COMMERCIAL-PRICING-COPY-CLEANUP.sql =====
-- ==========================================================================
-- WISSA V64.3 - COMMERCIAL PRICING + PUBLIC COPY CLEANUP
-- Objetivos:
--   * Eliminar textos internos/QA de datos visibles.
--   * Evitar servicios de Ofrecer con precio 0.
--   * Definir precios comerciales para todos los bloques de limpieza >250 m2.
--   * Dar precio individual al 2.o, 3.o, 4.o y 5.o profesional.
--   * Mantener ubicacion de trabajo y precio administrados por Wissa.
-- Idempotente. No elimina usuarios ni reservas.
-- ==========================================================================
begin;
select pg_advisory_xact_lock(hashtext('wissa_v64_3_commercial_pricing_copy_cleanup'));

-- --------------------------------------------------------------------------
-- 1. Limpieza defensiva de textos que vienen de datos historicos.
-- --------------------------------------------------------------------------
create or replace function public.wissa_v643_public_text(p_text text)
returns text
language plpgsql
immutable
set search_path=public,pg_temp
as $$
declare v text:=coalesce(p_text,'');
begin
  v:=regexp_replace(v,'\[(QA|DEV|TEST|DEBUG|STAGE|STAGING)[^]]*\][[:space:]]*','','gi');
  v:=regexp_replace(v,'(^|[[:space:]])(QA|DEV|TEST|DEBUG)([: -]+|$)',' ','gi');
  v:=regexp_replace(v,'(^|[[:space:]])V[0-9]+(\.[0-9]+){0,3}([[:space:]]|$)',' ','gi');
  v:=regexp_replace(v,'[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}',' ','gi');
  v:=regexp_replace(v,'provider_id','profesional','gi');
  v:=regexp_replace(v,'booking_id','reserva','gi');
  v:=regexp_replace(v,'pending_payment','Pendiente de pago','gi');
  v:=regexp_replace(v,'paid_pending_acceptance','Esperando confirmación','gi');
  v:=regexp_replace(v,'accepted','Aceptado','gi');
  v:=regexp_replace(v,'matching','búsqueda','gi');
  v:=regexp_replace(v,'pool','grupo','gi');
  v:=regexp_replace(v,'snapshot','registro','gi');
  v:=regexp_replace(v,'not_started','Sin iniciar','gi');
  v:=regexp_replace(v,'Supabase','la plataforma','gi');
  v:=regexp_replace(v,'SQL','el sistema','gi');
  v:=regexp_replace(v,'cupos','asignaciones','gi');
  v:=regexp_replace(v,'cupo','asignación','gi');
  v:=regexp_replace(v,'UUID','referencia','gi');
  v:=regexp_replace(v,'[[:space:]]+',' ','g');
  return btrim(v,' -–—:|');
end $$;

-- Servicios existentes: nunca dejar una etiqueta QA visible y nunca precio 0.
update public.services
set title = case
      when lower(public.wissa_v643_public_text(title)) in ('limpieza wissa','limpieza') then 'Limpieza'
      when lower(public.wissa_v643_public_text(title)) in ('plomeria wissa','plomería wissa','plomeria','plomería') then 'Plomería'
      when nullif(public.wissa_v643_public_text(title),'') is null then coalesce(nullif(trim(category),''),'Servicio Wissa')
      else public.wissa_v643_public_text(title)
    end,
    description = case
      when coalesce(description,'') ~* '(\[qa|(^|[^a-z])qa([^a-z]|$)|(^|[^a-z])v[0-9]+|uuid|provider_id|booking_id|pending_payment|matching|snapshot|servicio ficticio|probar equipos|prueba de equipo)'
        then case
          when lower(coalesce(category,'')) like '%plomer%' then 'Servicio profesional de plomería disponible a través de Wissa.'
          when lower(coalesce(category,'')) like '%exterior%' then 'Servicio profesional de limpieza exterior disponible a través de Wissa.'
          when lower(coalesce(category,'')) like '%limpieza%' then 'Servicio profesional de limpieza disponible a través de Wissa.'
          else 'Servicio profesional disponible a través de Wissa.'
        end
      else nullif(public.wissa_v643_public_text(description),'')
    end,
    price = case
      when coalesce(price,0)>0 then price
      when lower(coalesce(category,'')) like '%plomer%' then 25
      when lower(coalesce(category,'')) like '%exterior%' then 40
      when lower(coalesce(category,'')) like '%limpieza%' then 35
      else 35
    end;

-- Snapshots de reservas y notificaciones historicas tambien quedan limpios.
do $$ begin
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='bookings' and column_name='service_title') then
    execute $q$update public.bookings set service_title=case when lower(public.wissa_v643_public_text(service_title))='limpieza wissa' then 'Limpieza' when lower(public.wissa_v643_public_text(service_title)) in ('plomeria wissa','plomería wissa') then 'Plomería' else public.wissa_v643_public_text(service_title) end where service_title is not null$q$;
  end if;
  if to_regclass('public.notifications') is not null then
    execute $q$update public.notifications set title=public.wissa_v643_public_text(title), body=public.wissa_v643_public_text(body) where title is not null or body is not null$q$;
  end if;
end $$;

-- Reservas y notificaciones nuevas también pasan por la misma capa de texto público.
create or replace function public.wissa_v643_prepare_booking_copy()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if new.service_title is not null then
    new.service_title:=public.wissa_v643_public_text(new.service_title);
    if lower(new.service_title)='limpieza wissa' then new.service_title:='Limpieza'; end if;
    if lower(new.service_title) in ('plomeria wissa','plomería wissa') then new.service_title:='Plomería'; end if;
  end if;
  return new;
end $$;

do $$ begin
  if exists(select 1 from information_schema.columns where table_schema='public' and table_name='bookings' and column_name='service_title') then
    execute 'drop trigger if exists trg_wissa_v643_prepare_booking_copy on public.bookings';
    execute 'create trigger trg_wissa_v643_prepare_booking_copy before insert or update of service_title on public.bookings for each row execute function public.wissa_v643_prepare_booking_copy()';
  end if;
end $$;

create or replace function public.wissa_v643_prepare_notification_copy()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if new.title is not null then new.title:=public.wissa_v643_public_text(new.title); end if;
  if new.body is not null then new.body:=public.wissa_v643_public_text(new.body); end if;
  return new;
end $$;

do $$ begin
  if to_regclass('public.notifications') is not null
     and exists(select 1 from information_schema.columns where table_schema='public' and table_name='notifications' and column_name='title')
     and exists(select 1 from information_schema.columns where table_schema='public' and table_name='notifications' and column_name='body') then
    execute 'drop trigger if exists trg_wissa_v643_prepare_notification_copy on public.notifications';
    execute 'create trigger trg_wissa_v643_prepare_notification_copy before insert or update of title,body on public.notifications for each row execute function public.wissa_v643_prepare_notification_copy()';
  end if;
end $$;

-- Liquidaciones históricas y futuras tampoco exponen versiones/cupos internos.
do $$ begin
  if to_regclass('public.provider_payouts') is not null then
    begin
      update public.provider_payouts set notes=public.wissa_v643_public_text(notes) where notes is not null;
    exception when undefined_column then null;
    end;
  end if;
end $$;

create or replace function public.wissa_v643_prepare_payout_copy()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if new.notes is not null then new.notes:=public.wissa_v643_public_text(new.notes); end if;
  return new;
end $$;

do $$ begin
  if to_regclass('public.provider_payouts') is not null then
    execute 'drop trigger if exists trg_wissa_v643_prepare_payout_copy on public.provider_payouts';
    execute 'create trigger trg_wissa_v643_prepare_payout_copy before insert or update of notes on public.provider_payouts for each row execute function public.wissa_v643_prepare_payout_copy()';
  end if;
end $$;

-- Cualquier servicio nuevo se limpia y toma el precio comercial vigente.
create or replace function public.wissa_v643_prepare_service()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare
  v_pricing jsonb;
  v_price numeric;
  v_category text:=lower(coalesce(new.category,''));
begin
  new.title:=public.wissa_v643_public_text(new.title);
  if nullif(trim(new.title),'') is null then new.title:=coalesce(nullif(trim(new.category),''),'Servicio Wissa'); end if;
  if lower(new.title)='limpieza wissa' then new.title:='Limpieza'; end if;
  if lower(new.title) in ('plomeria wissa','plomería wissa') then new.title:='Plomería'; end if;

  if coalesce(new.description,'') ~* '(\[qa|(^|[^a-z])qa([^a-z]|$)|(^|[^a-z])v[0-9]+|uuid|provider_id|booking_id|pending_payment|matching|snapshot|servicio ficticio|probar equipos)' then
    new.description:=case when v_category like '%plomer%' then 'Servicio profesional de plomería disponible a través de Wissa.'
      when v_category like '%exterior%' then 'Servicio profesional de limpieza exterior disponible a través de Wissa.'
      when v_category like '%limpieza%' then 'Servicio profesional de limpieza disponible a través de Wissa.'
      else 'Servicio profesional disponible a través de Wissa.' end;
  else
    new.description:=nullif(public.wissa_v643_public_text(new.description),'');
  end if;

  select value into v_pricing from public.app_settings where key=case
    when v_category like '%plomer%' then 'plumbing_pricing'
    when v_category like '%exterior%' then 'exterior_cleaning_pricing'
    when v_category like '%limpieza%' then 'cleaning_pricing'
    else null end;

  if v_category like '%plomer%' then
    v_price:=coalesce(nullif(v_pricing->>'inspection_fee','')::numeric,25);
  elsif v_category like '%exterior%' then
    v_price:=coalesce(nullif(v_pricing#>>'{fixed_service_prices,basica}','')::numeric,nullif(v_pricing->>'fixed_service_price','')::numeric,40);
  elsif v_category like '%limpieza%' then
    v_price:=coalesce(nullif(v_pricing#>>'{parametric_engine,minimum_price}','')::numeric,35);
  else
    v_price:=greatest(35,coalesce(new.price,35));
  end if;
  new.price:=greatest(1,coalesce(v_price,35));
  return new;
end $$;

drop trigger if exists trg_wissa_v643_prepare_service on public.services;
create trigger trg_wissa_v643_prepare_service
before insert or update of title,description,category,price on public.services
for each row execute function public.wissa_v643_prepare_service();

-- --------------------------------------------------------------------------
-- 2. Formula comercial de Limpieza.
--    0..250 m2 conserva formula aprobada.
--    >250 m2 usa capacidad de equipo + horas: estándar USD 17/hora-persona,
--    profunda USD 20.50/hora-persona, redondeada al precio cerrado del bloque.
-- --------------------------------------------------------------------------
update public.app_settings
set value=coalesce(value,'{}'::jsonb) || jsonb_build_object(
  'pricing_version',64,
  'pricing_revision','64.3-commercial-blocks',
  'platform_commission_rate',0.20,
  'mobility_fee_per_booking',5,
  'platform_usage_fee',2,
  'itbms_rate',0.07,
  'additional_professional_fees','{"2":35,"3":35,"4":35,"5":35}'::jsonb,
  'parametric_engine',coalesce(value->'parametric_engine','{}'::jsonb) || jsonb_build_object(
    'minimum_price',35,
    'minimum_included_sqm',60,
    'tier1_end_sqm',120,
    'tier1_rate_per_sqm',0.28,
    'tier2_end_sqm',220,
    'tier2_rate_per_sqm',0.38,
    'team_threshold_sqm',250,
    'team_base_price',89.80,
    'team_rate_per_sqm',1.00,
    'quote_threshold_sqm',2000,
    'deep_cleaning_rate_per_sqm',0.15,
    'professionals_at_team_threshold',2,
    'max_professionals',5
  ),
  'large_job_blocks','[
    {"key":"251_350","label":"Más de 250 a 350 m²","min_sqm":250,"max_sqm":350,"professionals":2,"estimated_hours":4,"standard_price":136,"deep_price":164,"active":true},
    {"key":"351_500","label":"Más de 350 a 500 m²","min_sqm":350,"max_sqm":500,"professionals":2,"estimated_hours":6,"standard_price":204,"deep_price":246,"active":true},
    {"key":"501_700","label":"Más de 500 a 700 m²","min_sqm":500,"max_sqm":700,"professionals":3,"estimated_hours":6,"standard_price":306,"deep_price":369,"active":true},
    {"key":"701_900","label":"Más de 700 a 900 m²","min_sqm":700,"max_sqm":900,"professionals":4,"estimated_hours":6,"standard_price":408,"deep_price":492,"active":true},
    {"key":"901_1200","label":"Más de 900 a 1,200 m²","min_sqm":900,"max_sqm":1200,"professionals":5,"estimated_hours":6,"standard_price":510,"deep_price":615,"active":true},
    {"key":"1201_1500","label":"Más de 1,200 a 1,500 m²","min_sqm":1200,"max_sqm":1500,"professionals":5,"estimated_hours":8,"standard_price":680,"deep_price":820,"active":true},
    {"key":"1501_2000","label":"Más de 1,500 a 2,000 m²","min_sqm":1500,"max_sqm":2000,"professionals":5,"estimated_hours":10,"standard_price":850,"deep_price":1025,"active":true}
  ]'::jsonb,
  'kits',coalesce(value->'kits','{}'::jsonb) || jsonb_build_object(
    'enabled',true,
    'basic',jsonb_build_object('title','Kit básico','description','Jabón, escoba, trapeador, bolsas de basura y paños de limpieza.','price',15),
    'premium',jsonb_build_object('title','Personalizar materiales','description','El cliente paga únicamente los productos que seleccione.','price',15)
  )
), updated_at=now()
where key='cleaning_pricing';

-- Exterior y Plomeria: todos los cargos de equipo tienen precio inicial.
update public.app_settings
set value=coalesce(value,'{}'::jsonb) || jsonb_build_object(
  'pricing_version',64,'pricing_revision','64.3-commercial',
  'platform_commission_rate',0.20,'mobility_fee_per_booking',5,'platform_usage_fee',2,'itbms_rate',0.07,
  'fixed_service_price',greatest(1,coalesce(nullif((value->>'fixed_service_price')::numeric,0),40)),
  'fixed_service_prices',jsonb_build_object('basica',greatest(1,coalesce(nullif((value#>>'{fixed_service_prices,basica}')::numeric,0),40)),'premium',greatest(1,coalesce(nullif((value#>>'{fixed_service_prices,premium}')::numeric,0),40))),
  'additional_professional_fees','{"2":30,"3":30,"4":30,"5":30}'::jsonb
), updated_at=now()
where key='exterior_cleaning_pricing';

update public.app_settings
set value=coalesce(value,'{}'::jsonb) || jsonb_build_object(
  'pricing_version',64,'pricing_revision','64.3-commercial',
  'platform_commission_rate',0.35,'mobility_fee_per_booking',5,'platform_usage_fee',2,'itbms_rate',0.07,
  'inspection_fee',greatest(1,coalesce(nullif((value->>'inspection_fee')::numeric,0),25)),
  'additional_professional_fees','{"2":40,"3":40,"4":40,"5":40}'::jsonb
), updated_at=now()
where key='plumbing_pricing';

-- Si una instalacion no tenia las llaves, crearlas con valores completos.
insert into public.app_settings(key,value,updated_at)
select 'cleaning_pricing',jsonb_build_object(
  'pricing_version',64,'currency','USD','platform_commission_rate',0.20,'platform_usage_fee',2,'itbms_rate',0.07,'mobility_fee_per_booking',5,
  'additional_professional_fees','{"2":35,"3":35,"4":35,"5":35}'::jsonb,
  'parametric_engine',jsonb_build_object('minimum_price',35,'minimum_included_sqm',60,'tier1_end_sqm',120,'tier1_rate_per_sqm',0.28,'tier2_end_sqm',220,'tier2_rate_per_sqm',0.38,'team_threshold_sqm',250,'team_base_price',89.80,'team_rate_per_sqm',1.00,'quote_threshold_sqm',2000,'deep_cleaning_rate_per_sqm',0.15,'professionals_at_team_threshold',2,'max_professionals',5),
  'large_job_blocks','[{"key":"251_350","label":"Más de 250 a 350 m²","min_sqm":250,"max_sqm":350,"professionals":2,"estimated_hours":4,"standard_price":136,"deep_price":164,"active":true},{"key":"351_500","label":"Más de 350 a 500 m²","min_sqm":350,"max_sqm":500,"professionals":2,"estimated_hours":6,"standard_price":204,"deep_price":246,"active":true},{"key":"501_700","label":"Más de 500 a 700 m²","min_sqm":500,"max_sqm":700,"professionals":3,"estimated_hours":6,"standard_price":306,"deep_price":369,"active":true},{"key":"701_900","label":"Más de 700 a 900 m²","min_sqm":700,"max_sqm":900,"professionals":4,"estimated_hours":6,"standard_price":408,"deep_price":492,"active":true},{"key":"901_1200","label":"Más de 900 a 1,200 m²","min_sqm":900,"max_sqm":1200,"professionals":5,"estimated_hours":6,"standard_price":510,"deep_price":615,"active":true},{"key":"1201_1500","label":"Más de 1,200 a 1,500 m²","min_sqm":1200,"max_sqm":1500,"professionals":5,"estimated_hours":8,"standard_price":680,"deep_price":820,"active":true},{"key":"1501_2000","label":"Más de 1,500 a 2,000 m²","min_sqm":1500,"max_sqm":2000,"professionals":5,"estimated_hours":10,"standard_price":850,"deep_price":1025,"active":true}]'::jsonb,
  'kits',jsonb_build_object('enabled',true,'basic',jsonb_build_object('title','Kit básico','description','Jabón, escoba, trapeador, bolsas de basura y paños de limpieza.','price',15),'premium',jsonb_build_object('title','Personalizar materiales','description','El cliente paga únicamente los productos que seleccione.','price',15))
),now()
where not exists(select 1 from public.app_settings where key='cleaning_pricing');

insert into public.app_settings(key,value,updated_at)
select 'exterior_cleaning_pricing',jsonb_build_object(
  'pricing_version',64,'currency','USD','platform_commission_rate',0.20,'platform_usage_fee',2,'itbms_rate',0.07,
  'mobility_fee_per_booking',5,'fixed_service_price',40,'fixed_service_prices',jsonb_build_object('basica',40,'premium',40),
  'additional_professional_fees','{"2":30,"3":30,"4":30,"5":30}'::jsonb
),now()
where not exists(select 1 from public.app_settings where key='exterior_cleaning_pricing');

insert into public.app_settings(key,value,updated_at)
select 'plumbing_pricing',jsonb_build_object(
  'pricing_version',64,'currency','USD','platform_commission_rate',0.35,'platform_usage_fee',2,'itbms_rate',0.07,
  'mobility_fee_per_booking',5,'inspection_fee',25,
  'additional_professional_fees','{"2":40,"3":40,"4":40,"5":40}'::jsonb
),now()
where not exists(select 1 from public.app_settings where key='plumbing_pricing');

-- --------------------------------------------------------------------------
-- 3. Reglas de equipo: precio separado para cada posicion 2..5.
-- --------------------------------------------------------------------------
alter table public.service_team_rules
  add column if not exists additional_professional_fees jsonb not null default '{"2":35,"3":35,"4":35,"5":35}'::jsonb;

update public.service_team_rules
set additional_professional_fee=greatest(1,coalesce(nullif(additional_professional_fee,0),35)),
    additional_professional_fees=jsonb_build_object(
      '2',greatest(1,coalesce(nullif((additional_professional_fees->>'2')::numeric,0),nullif(additional_professional_fee,0),35)),
      '3',greatest(1,coalesce(nullif((additional_professional_fees->>'3')::numeric,0),nullif(additional_professional_fee,0),35)),
      '4',greatest(1,coalesce(nullif((additional_professional_fees->>'4')::numeric,0),nullif(additional_professional_fee,0),35)),
      '5',greatest(1,coalesce(nullif((additional_professional_fees->>'5')::numeric,0),nullif(additional_professional_fee,0),35))
    ), updated_at=now();

create or replace function public.yt_admin_upsert_team_rule_v62(p_rule jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
  v_id uuid;
  v_min int; v_rec int; v_max int;
  v_fees jsonb;
begin
  if not public.yt_admin_is_current_admin() then raise exception 'Solo Admin Wissa puede editar reglas de equipo.'; end if;
  v_id:=nullif(p_rule->>'id','')::uuid;
  v_min:=greatest(1,least(5,coalesce((p_rule->>'min_professionals')::int,1)));
  v_rec:=greatest(v_min,least(5,coalesce((p_rule->>'recommended_professionals')::int,v_min)));
  v_max:=greatest(v_rec,least(5,coalesce((p_rule->>'max_professionals')::int,v_rec)));
  v_fees:=jsonb_build_object(
    '2',greatest(1,coalesce(nullif((p_rule#>>'{additional_professional_fees,2}')::numeric,0),nullif((p_rule->>'additional_professional_fee')::numeric,0),35)),
    '3',greatest(1,coalesce(nullif((p_rule#>>'{additional_professional_fees,3}')::numeric,0),nullif((p_rule->>'additional_professional_fee')::numeric,0),35)),
    '4',greatest(1,coalesce(nullif((p_rule#>>'{additional_professional_fees,4}')::numeric,0),nullif((p_rule->>'additional_professional_fee')::numeric,0),35)),
    '5',greatest(1,coalesce(nullif((p_rule#>>'{additional_professional_fees,5}')::numeric,0),nullif((p_rule->>'additional_professional_fee')::numeric,0),35))
  );
  if v_id is null then
    insert into public.service_team_rules(category,cleaning_mode,property_type,sqm_min,sqm_max,min_professionals,recommended_professionals,max_professionals,additional_professional_fee,additional_professional_fees,is_active,priority,metadata)
    values(coalesce(nullif(trim(p_rule->>'category'),''),'Limpieza'),case when p_rule->>'cleaning_mode' in ('standard','deep','any') then p_rule->>'cleaning_mode' else 'any' end,coalesce(nullif(trim(p_rule->>'property_type'),''),'any'),greatest(0,coalesce((p_rule->>'sqm_min')::int,1)),greatest(1,coalesce((p_rule->>'sqm_max')::int,400)),v_min,v_rec,v_max,(v_fees->>'2')::numeric,v_fees,coalesce((p_rule->>'is_active')::boolean,true),coalesce((p_rule->>'priority')::int,100),coalesce(p_rule->'metadata','{}'::jsonb)-'seed') returning id into v_id;
  else
    update public.service_team_rules set category=coalesce(nullif(trim(p_rule->>'category'),''),category),cleaning_mode=case when p_rule->>'cleaning_mode' in ('standard','deep','any') then p_rule->>'cleaning_mode' else cleaning_mode end,property_type=coalesce(nullif(trim(p_rule->>'property_type'),''),property_type),sqm_min=greatest(0,coalesce((p_rule->>'sqm_min')::int,sqm_min)),sqm_max=greatest(greatest(0,coalesce((p_rule->>'sqm_min')::int,sqm_min)),coalesce((p_rule->>'sqm_max')::int,sqm_max)),min_professionals=v_min,recommended_professionals=v_rec,max_professionals=v_max,additional_professional_fee=(v_fees->>'2')::numeric,additional_professional_fees=v_fees,is_active=coalesce((p_rule->>'is_active')::boolean,is_active),priority=coalesce((p_rule->>'priority')::int,priority),metadata=(coalesce(metadata,'{}'::jsonb)||coalesce(p_rule->'metadata','{}'::jsonb))-'seed',updated_at=now() where id=v_id;
  end if;
  return to_jsonb((select x from public.service_team_rules x where x.id=v_id));
end $$;
grant execute on function public.yt_admin_upsert_team_rule_v62(jsonb) to authenticated,service_role;

-- Reglas base para el motor comercial. No duplican reglas existentes con el mismo rango.
insert into public.service_team_rules(category,cleaning_mode,property_type,sqm_min,sqm_max,min_professionals,recommended_professionals,max_professionals,additional_professional_fee,additional_professional_fees,is_active,priority,metadata)
select x.category,x.cleaning_mode,x.property_type,x.sqm_min,x.sqm_max,x.min_professionals,x.recommended_professionals,x.max_professionals,35,'{"2":35,"3":35,"4":35,"5":35}'::jsonb,true,50,'{"commercial_model":"hybrid_time_block"}'::jsonb
from (values
  ('Limpieza','any','any',1,250,1,1,1),
  ('Limpieza','any','any',251,350,2,2,2),
  ('Limpieza','any','any',351,500,2,2,2),
  ('Limpieza','any','any',501,700,3,3,3),
  ('Limpieza','any','any',701,900,4,4,4),
  ('Limpieza','any','any',901,1200,5,5,5),
  ('Limpieza','any','any',1201,1500,5,5,5),
  ('Limpieza','any','any',1501,2000,5,5,5)
) as x(category,cleaning_mode,property_type,sqm_min,sqm_max,min_professionals,recommended_professionals,max_professionals)
where not exists (
  select 1 from public.service_team_rules r
  where lower(r.category)=lower(x.category)
    and r.cleaning_mode=x.cleaning_mode
    and lower(r.property_type)=lower(x.property_type)
    and r.sqm_min=x.sqm_min and r.sqm_max=x.sqm_max
);

-- Los productos/extras activos del catalogo no deben quedar con precio 0.
do $$ begin
  if to_regclass('public.booking_catalog') is not null then
    begin
      update public.booking_catalog
      set price=case when lower(coalesce(kind,''))='product' then 5 when lower(coalesce(kind,''))='extra' then 10 else 5 end
      where coalesce(active,true)=true and lower(coalesce(kind,'')) in ('product','extra') and coalesce(price,0)<=0;
    exception when undefined_column then null;
    end;
  end if;
end $$;

commit;

-- Verificacion util tras ejecutar:
select key,value->'additional_professional_fees' as team_prices,value->'large_job_blocks' as large_job_blocks
from public.app_settings where key in ('cleaning_pricing','exterior_cleaning_pricing','plumbing_pricing') order by key;

-- ===== END 06-WISSA-V64.3-COMMERCIAL-PRICING-COPY-CLEANUP.sql =====

-- ============================================================================
-- V64.4 FIX FINAL: refrescar inmediatamente el esquema de Supabase/PostgREST.
-- Esto evita el PGRST204/PGRST202 que podía mostrar "No pudimos crear la reserva"
-- justo después de agregar columnas o funciones nuevas.
-- ============================================================================

-- Asegurar nuevamente provider_id nullable después de cualquier trigger/migración previa.
alter table public.bookings alter column provider_id drop not null;

-- Dejar explícitamente el flujo híbrido como default para nuevas reservas.
alter table public.bookings alter column assignment_mode set default 'hybrid_post_payment';
alter table public.bookings alter column candidate_selection_status set default 'not_started';

-- Forzar refresco de schema cache de la API de Supabase.
notify pgrst, 'reload schema';
select pg_notify('pgrst','reload schema');

-- Marca de versión para diagnóstico no visible al cliente.
insert into public.app_settings(key,value,updated_at)
values(
  'wissa_release',
  jsonb_build_object(
    'version','64.4',
    'release','booking-stability',
    'booking_schema_ready',true,
    'single_apply_sql',true,
    'updated_at',now()
  ),
  now()
)
on conflict(key) do update
set value=coalesce(public.app_settings.value,'{}'::jsonb)||excluded.value,
    updated_at=now();

-- Segundo aviso al final de todas las operaciones para garantizar que PostgREST
-- vea tanto columnas como funciones y triggers recién creados.
notify pgrst, 'reload schema';
select pg_notify('pgrst','reload schema');

select
  'WISSA V64.4 LISTO' as resultado,
  (select count(*) from information_schema.columns where table_schema='public' and table_name='bookings' and column_name in (
    'assignment_mode','candidate_selection_status','mobility_fee_per_booking','pricing_strategy','estimated_service_minutes','required_professionals'
  )) as columnas_reserva_verificadas,
  (select value->>'booking_schema_ready' from public.app_settings where key='wissa_release') as booking_schema_ready;
