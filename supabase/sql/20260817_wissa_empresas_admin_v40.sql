-- ==========================================================================
-- WISSA V40 - ADMIN EMPRESAS 360
-- Fecha: 2026-08-17
-- Mejora /dashboard/empresas con resumen, ficha 360, personal, servicios,
-- reservas, finanzas, plan/suscripcion, alertas y edicion administrativa.
-- ===========================================================================

begin;

create index if not exists idx_company_members_company_status_role
  on public.company_members (company_id, status, internal_role);

create index if not exists idx_services_company_active_category
  on public.services (company_id, is_active, category);

create index if not exists idx_bookings_company_created_status
  on public.bookings (company_id, created_at desc, status);

create index if not exists idx_company_plan_orders_company_status_created
  on public.company_plan_orders (company_id, status, created_at desc);

create index if not exists idx_company_payments_company_status_created
  on public.company_payments (company_id, status, created_at desc);

create index if not exists idx_company_invoices_company_status_created
  on public.company_invoices (company_id, status, created_at desc);

create index if not exists idx_company_subscription_events_company_sent
  on public.company_subscription_events (company_id, sent_at desc);

-- --------------------------------------------------------------------------
-- LISTADO + KPI EN UNA SOLA LLAMADA
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_companies_overview_v40(
  p_search text default '',
  p_status text default 'all',
  p_limit integer default 250
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_search text := lower(trim(coalesce(p_search, '')));
  v_status text := lower(trim(coalesce(p_status, 'all')));
  v_limit integer := greatest(1, least(coalesce(p_limit, 250), 500));
  v_result jsonb;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'Acceso administrativo requerido.';
  end if;

  with member_stats as (
    select company_id,
           count(*)::bigint as members_count,
           count(*) filter (where status = 'active')::bigint as active_members_count
    from public.company_members
    group by company_id
  ), service_stats as (
    select company_id,
           count(*)::bigint as services_count,
           count(*) filter (where is_active = true)::bigint as active_services_count
    from public.services
    where company_id is not null
    group by company_id
  ), booking_stats as (
    select company_id,
           count(*)::bigint as bookings_count,
           count(*) filter (where status in ('completed','completed_pending_release'))::bigint as completed_bookings_count,
           coalesce(sum(total_amount),0)::numeric as booked_total
    from public.bookings
    where company_id is not null
    group by company_id
  ), plan_stats as (
    select company_id,
           coalesce(sum(amount) filter (where status in ('approved','paid')),0)::numeric as plan_paid_total
    from public.company_plan_orders
    group by company_id
  ), base as (
    select
      c.id,
      c.name,
      c.legal_name,
      c.ruc,
      c.email,
      c.phone,
      c.contact_name,
      c.contact_email,
      c.contact_phone,
      c.city,
      c.status,
      c.verification_status,
      c.plan_name,
      c.subscription_status,
      c.subscription_expires_at,
      c.plan_expires_at,
      case
        when coalesce(c.subscription_expires_at, c.plan_expires_at) is null then null
        else floor(extract(epoch from (coalesce(c.subscription_expires_at, c.plan_expires_at) - now())) / 86400)::integer
      end as days_remaining,
      coalesce(ms.members_count,0) as members_count,
      coalesce(ms.active_members_count,0) as active_members_count,
      coalesce(ss.services_count,0) as services_count,
      coalesce(ss.active_services_count,0) as active_services_count,
      coalesce(bs.bookings_count,0) as bookings_count,
      coalesce(bs.completed_bookings_count,0) as completed_bookings_count,
      coalesce(bs.booked_total,0) as booked_total,
      coalesce(ps.plan_paid_total,0) as plan_paid_total,
      c.created_at
    from public.companies c
    left join member_stats ms on ms.company_id = c.id
    left join service_stats ss on ss.company_id = c.id
    left join booking_stats bs on bs.company_id = c.id
    left join plan_stats ps on ps.company_id = c.id
  ), filtered as (
    select *
    from base b
    where (
      v_search = ''
      or lower(coalesce(b.name,'')) like '%' || v_search || '%'
      or lower(coalesce(b.legal_name,'')) like '%' || v_search || '%'
      or lower(coalesce(b.ruc,'')) like '%' || v_search || '%'
      or lower(coalesce(b.email,'')) like '%' || v_search || '%'
      or lower(coalesce(b.phone,'')) like '%' || v_search || '%'
      or lower(coalesce(b.contact_name,'')) like '%' || v_search || '%'
      or lower(coalesce(b.contact_email,'')) like '%' || v_search || '%'
      or lower(coalesce(b.contact_phone,'')) like '%' || v_search || '%'
    )
    and (
      v_status = 'all'
      or (v_status in ('active','pending','suspended','rejected') and b.status = v_status)
      or (v_status = 'expiring' and b.subscription_status = 'active' and b.days_remaining between 0 and 7)
      or (v_status = 'expired' and (b.subscription_status = 'expired' or b.days_remaining < 0))
      or (v_status = 'pending_payment' and b.subscription_status = 'pending_payment')
    )
    order by b.created_at desc
    limit v_limit
  ), global_summary as (
    select jsonb_build_object(
      'total', count(*),
      'active', count(*) filter (where c.status = 'active'),
      'pending', count(*) filter (where c.status = 'pending'),
      'suspended', count(*) filter (where c.status = 'suspended'),
      'expiring_7d', count(*) filter (
        where c.subscription_status = 'active'
          and coalesce(c.subscription_expires_at,c.plan_expires_at) >= now()
          and coalesce(c.subscription_expires_at,c.plan_expires_at) < now() + interval '8 days'
      ),
      'expired', count(*) filter (
        where c.subscription_status = 'expired'
           or (coalesce(c.subscription_expires_at,c.plan_expires_at) is not null and coalesce(c.subscription_expires_at,c.plan_expires_at) < now())
      ),
      'active_subscriptions', count(*) filter (where c.subscription_status = 'active'),
      'plan_revenue', coalesce((select sum(po.amount) from public.company_plan_orders po where po.status in ('approved','paid')),0),
      'booked_total', coalesce((select sum(b.total_amount) from public.bookings b where b.company_id is not null),0)
    ) as payload
    from public.companies c
  )
  select jsonb_build_object(
    'summary', (select payload from global_summary),
    'companies', coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at desc) from filtered f), '[]'::jsonb)
  ) into v_result;

  return coalesce(v_result, jsonb_build_object('summary','{}'::jsonb,'companies','[]'::jsonb));
end;
$$;

-- --------------------------------------------------------------------------
-- FICHA 360 DE UNA EMPRESA
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_company_detail_v40(p_company_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company public.companies%rowtype;
  v_days integer;
  v_members jsonb;
  v_services jsonb;
  v_bookings jsonb;
  v_plan_orders jsonb;
  v_payments jsonb;
  v_invoices jsonb;
  v_events jsonb;
  v_alerts jsonb;
  v_stats jsonb;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'Acceso administrativo requerido.';
  end if;

  select * into v_company from public.companies where id = p_company_id;
  if v_company.id is null then raise exception 'Empresa no encontrada.'; end if;

  v_days := case
    when coalesce(v_company.subscription_expires_at, v_company.plan_expires_at) is null then null
    else floor(extract(epoch from (coalesce(v_company.subscription_expires_at, v_company.plan_expires_at) - now())) / 86400)::integer
  end;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', cm.id,
    'full_name', cm.full_name,
    'email', cm.email,
    'phone', cm.phone,
    'position', cm.position,
    'department', cm.department,
    'role', cm.role,
    'internal_role', cm.internal_role,
    'status', cm.status,
    'can_create_bookings', cm.can_create_bookings,
    'can_approve_bookings', cm.can_approve_bookings,
    'can_view_finance', cm.can_view_finance,
    'can_manage_staff', cm.can_manage_staff,
    'last_login_at', cm.last_login_at,
    'created_at', cm.created_at
  ) order by (cm.status = 'active') desc, cm.full_name nulls last), '[]'::jsonb)
  into v_members
  from public.company_members cm where cm.company_id = p_company_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id,
    'title', s.title,
    'description', s.description,
    'category', s.category,
    'price', s.price,
    'duration_minutes', s.duration_minutes,
    'is_active', s.is_active,
    'source_type', s.source_type,
    'member_name', cm.full_name,
    'member_email', cm.email,
    'provider_name', p.full_name,
    'provider_email', p.email,
    'bookings_count', (select count(*) from public.bookings b where b.service_id = s.id),
    'created_at', s.created_at
  ) order by s.is_active desc, s.created_at desc), '[]'::jsonb)
  into v_services
  from public.services s
  left join public.company_members cm on cm.id = s.company_member_id
  left join public.profiles p on p.id = s.provider_id
  where s.company_id = p_company_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id,
    'service_title', coalesce(b.service_title, s.title),
    'company_reference', b.company_reference,
    'company_department', b.company_department,
    'booking_date', b.booking_date,
    'booking_time', b.booking_time,
    'total_amount', b.total_amount,
    'payment_status', b.payment_status,
    'status', b.status,
    'company_request_status', b.company_request_status,
    'requested_by_name', coalesce(rp.full_name, 'Empresa'),
    'created_at', b.created_at
  ) order by b.created_at desc), '[]'::jsonb)
  into v_bookings
  from (
    select * from public.bookings where company_id = p_company_id order by created_at desc limit 100
  ) b
  left join public.services s on s.id = b.service_id
  left join public.profiles rp on rp.id = b.company_requested_by;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', po.id,
    'amount', po.amount,
    'currency', po.currency,
    'provider', po.provider,
    'payment_method', po.payment_method,
    'status', po.status,
    'yappy_transaction_id', po.yappy_transaction_id,
    'pf_transaction_id', po.pf_transaction_id,
    'public_checkout_token', po.public_checkout_token,
    'paid_at', po.paid_at,
    'created_at', po.created_at
  ) order by po.created_at desc), '[]'::jsonb)
  into v_plan_orders
  from public.company_plan_orders po where po.company_id = p_company_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', cp.id,
    'concept', case when cp.company_booking_id is null then 'Pago de empresa' else 'Pago de reserva empresarial' end,
    'amount', cp.amount,
    'currency', cp.currency,
    'status', cp.status,
    'method', cp.method,
    'provider', cp.provider,
    'external_reference', cp.external_reference,
    'transaction_id', cp.transaction_id,
    'invoice_number', cp.invoice_number,
    'paid_at', cp.paid_at,
    'created_at', cp.created_at
  ) order by cp.created_at desc), '[]'::jsonb)
  into v_payments
  from public.company_payments cp where cp.company_id = p_company_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', ci.id,
    'invoice_number', ci.invoice_number,
    'period_start', ci.period_start,
    'period_end', ci.period_end,
    'subtotal', ci.subtotal,
    'tax_amount', ci.tax_amount,
    'total_amount', ci.total_amount,
    'status', ci.status,
    'issued_at', ci.issued_at,
    'due_at', ci.due_at,
    'paid_at', ci.paid_at,
    'created_at', ci.created_at
  ) order by ci.created_at desc), '[]'::jsonb)
  into v_invoices
  from public.company_invoices ci where ci.company_id = p_company_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', se.id,
    'event_type', se.event_type,
    'title', se.title,
    'body', se.body,
    'sent_at', se.sent_at
  ) order by se.sent_at desc), '[]'::jsonb)
  into v_events
  from (
    select * from public.company_subscription_events where company_id = p_company_id order by sent_at desc limit 50
  ) se;

  select jsonb_build_object(
    'members', (select count(*) from public.company_members cm where cm.company_id = p_company_id),
    'active_members', (select count(*) from public.company_members cm where cm.company_id = p_company_id and cm.status = 'active'),
    'services', (select count(*) from public.services s where s.company_id = p_company_id),
    'active_services', (select count(*) from public.services s where s.company_id = p_company_id and s.is_active = true),
    'bookings', (select count(*) from public.bookings b where b.company_id = p_company_id),
    'completed_bookings', (select count(*) from public.bookings b where b.company_id = p_company_id and b.status in ('completed','completed_pending_release')),
    'booked_total', coalesce((select sum(b.total_amount) from public.bookings b where b.company_id = p_company_id),0),
    'company_payments_total', coalesce((select sum(cp.amount) from public.company_payments cp where cp.company_id = p_company_id and cp.status = 'paid'),0),
    'plan_paid_total', coalesce((select sum(po.amount) from public.company_plan_orders po where po.company_id = p_company_id and po.status in ('approved','paid')),0),
    'invoiced_total', coalesce((select sum(ci.total_amount) from public.company_invoices ci where ci.company_id = p_company_id and ci.status <> 'cancelled'),0)
  ) into v_stats;

  with alert_rows as (
    select 'warning'::text tone, 'Empresa pendiente'::text title, 'La cuenta todavía está pendiente de activación administrativa.'::text body where v_company.status = 'pending'
    union all select 'danger', 'Empresa suspendida', coalesce(nullif(v_company.suspended_reason,''), 'La empresa está suspendida y no debería operar normalmente.') where v_company.status = 'suspended'
    union all select 'warning', 'Verificación pendiente', 'Revisa los datos comerciales y fiscales antes de verificar la empresa.' where v_company.verification_status = 'pending'
    union all select 'danger', 'Verificación rechazada', 'La verificación de la empresa fue rechazada y requiere seguimiento.' where v_company.verification_status = 'rejected'
    union all select 'danger', 'Plan vencido', 'La suscripción empresarial está vencida.' where v_company.subscription_status = 'expired' or coalesce(v_days,0) < 0
    union all select 'warning', 'Plan próximo a vencer', format('La suscripción vence en %s día(s).', v_days) where v_company.subscription_status = 'active' and v_days between 0 and 7
    union all select 'warning', 'Pago de plan pendiente', 'La suscripción está marcada como pendiente de pago.' where v_company.subscription_status = 'pending_payment'
    union all select 'warning', 'Sin administrador activo', 'La empresa no tiene un Admin Empresa activo.' where not exists (select 1 from public.company_members cm where cm.company_id = p_company_id and cm.status = 'active' and coalesce(cm.internal_role,'') = 'company_admin')
    union all select 'warning', 'Sin servicios activos', 'La empresa no tiene servicios activos para operar.' where not exists (select 1 from public.services s where s.company_id = p_company_id and s.is_active = true)
  )
  select coalesce(jsonb_agg(jsonb_build_object('tone',tone,'title',title,'body',body)), '[]'::jsonb) into v_alerts from alert_rows;

  return jsonb_build_object(
    'company', to_jsonb(v_company) || jsonb_build_object('days_remaining', v_days),
    'members', v_members,
    'services', v_services,
    'bookings', v_bookings,
    'plan_orders', v_plan_orders,
    'payments', v_payments,
    'invoices', v_invoices,
    'subscription_events', v_events,
    'alerts', v_alerts,
    'stats', v_stats
  );
end;
$$;

-- --------------------------------------------------------------------------
-- EDICION DE DATOS COMERCIALES DESDE ADMIN
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_company_update_v40(
  p_company_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company public.companies%rowtype;
  v_name text;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'Acceso administrativo requerido.';
  end if;
  select * into v_company from public.companies where id = p_company_id;
  if v_company.id is null then raise exception 'Empresa no encontrada.'; end if;

  v_name := case when p_payload ? 'name' then nullif(trim(p_payload->>'name'),'') else v_company.name end;
  if v_name is null then raise exception 'El nombre comercial es obligatorio.'; end if;

  if p_payload ? 'billing_mode' and (p_payload->>'billing_mode') not in ('per_booking','monthly_invoice','credit','manual') then
    raise exception 'Modo de facturacion no valido.';
  end if;
  if p_payload ? 'billing_cycle' and (p_payload->>'billing_cycle') not in ('none','weekly','biweekly','monthly') then
    raise exception 'Ciclo de facturacion no valido.';
  end if;

  update public.companies c set
    name = v_name,
    legal_name = case when p_payload ? 'legal_name' then nullif(trim(p_payload->>'legal_name'),'') else c.legal_name end,
    ruc = case when p_payload ? 'ruc' then nullif(trim(p_payload->>'ruc'),'') else c.ruc end,
    tax_id = case when p_payload ? 'ruc' then nullif(trim(p_payload->>'ruc'),'') else c.tax_id end,
    business_type = case when p_payload ? 'business_type' then nullif(trim(p_payload->>'business_type'),'') else c.business_type end,
    email = case when p_payload ? 'email' then nullif(trim(p_payload->>'email'),'') else c.email end,
    phone = case when p_payload ? 'phone' then nullif(trim(p_payload->>'phone'),'') else c.phone end,
    website = case when p_payload ? 'website' then nullif(trim(p_payload->>'website'),'') else c.website end,
    city = case when p_payload ? 'city' then coalesce(nullif(trim(p_payload->>'city'),''),'Panamá') else c.city end,
    address = case when p_payload ? 'address' then nullif(trim(p_payload->>'address'),'') else c.address end,
    contact_name = case when p_payload ? 'contact_name' then nullif(trim(p_payload->>'contact_name'),'') else c.contact_name end,
    contact_email = case when p_payload ? 'contact_email' then nullif(trim(p_payload->>'contact_email'),'') else c.contact_email end,
    contact_phone = case when p_payload ? 'contact_phone' then nullif(trim(p_payload->>'contact_phone'),'') else c.contact_phone end,
    billing_email = case when p_payload ? 'billing_email' then nullif(trim(p_payload->>'billing_email'),'') else c.billing_email end,
    billing_phone = case when p_payload ? 'billing_phone' then nullif(trim(p_payload->>'billing_phone'),'') else c.billing_phone end,
    billing_address = case when p_payload ? 'billing_address' then nullif(trim(p_payload->>'billing_address'),'') else c.billing_address end,
    billing_mode = case when p_payload ? 'billing_mode' then p_payload->>'billing_mode' else c.billing_mode end,
    billing_cycle = case when p_payload ? 'billing_cycle' then p_payload->>'billing_cycle' else c.billing_cycle end,
    payment_terms_days = case when p_payload ? 'payment_terms_days' then greatest(0,least(365,(p_payload->>'payment_terms_days')::integer)) else c.payment_terms_days end,
    requires_approval = case when p_payload ? 'requires_approval' then (p_payload->>'requires_approval')::boolean else c.requires_approval end,
    auto_approve_bookings = case when p_payload ? 'auto_approve_bookings' then (p_payload->>'auto_approve_bookings')::boolean else c.auto_approve_bookings end,
    updated_by = auth.uid(),
    updated_at = now()
  where c.id = p_company_id;

  return jsonb_build_object('ok',true,'company_id',p_company_id,'updated_at',now());
end;
$$;

-- --------------------------------------------------------------------------
-- ACCIONES ADMINISTRATIVAS DE ESTADO / PLAN
-- --------------------------------------------------------------------------
create or replace function public.yt_admin_company_action_v40(
  p_company_id uuid,
  p_action text,
  p_note text default null,
  p_days integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action text := lower(trim(coalesce(p_action,'')));
  v_note text := nullif(trim(coalesce(p_note,'')),'');
  v_days integer := greatest(1,least(coalesce(p_days,30),365));
  v_title text;
  v_body text;
begin
  if auth.uid() is null or not public.yt_admin_is_current_admin() then
    raise exception 'Acceso administrativo requerido.';
  end if;
  if not exists (select 1 from public.companies where id = p_company_id) then raise exception 'Empresa no encontrada.'; end if;

  if v_action = 'activate' then
    update public.companies set status='active', rejected_reason=null, suspended_reason=null, updated_by=auth.uid(), updated_at=now() where id=p_company_id;
    v_title := 'Empresa activada'; v_body := coalesce(v_note,'La empresa fue activada por Administración Wissa.');
  elsif v_action = 'suspend' then
    update public.companies set status='suspended', suspended_reason=coalesce(v_note,'Revisión administrativa'), updated_by=auth.uid(), updated_at=now() where id=p_company_id;
    v_title := 'Empresa suspendida'; v_body := coalesce(v_note,'La empresa fue suspendida por Administración Wissa.');
  elsif v_action = 'reactivate' then
    update public.companies set status='active', suspended_reason=null, updated_by=auth.uid(), updated_at=now() where id=p_company_id;
    v_title := 'Empresa reactivada'; v_body := coalesce(v_note,'La empresa fue reactivada por Administración Wissa.');
  elsif v_action = 'verify' then
    update public.companies set verification_status='verified', approved_by=auth.uid(), approved_at=coalesce(approved_at,now()), rejected_reason=null, updated_by=auth.uid(), updated_at=now() where id=p_company_id;
    v_title := 'Empresa verificada'; v_body := coalesce(v_note,'Administración Wissa verificó la empresa.');
  elsif v_action = 'extend' then
    update public.companies set
      status = case when status='suspended' then status else 'active' end,
      plan_status='active',
      subscription_status='active',
      subscription_started_at=coalesce(subscription_started_at,now()),
      subscription_expires_at=greatest(coalesce(subscription_expires_at,now()),now()) + make_interval(days => v_days),
      plan_expires_at=greatest(coalesce(plan_expires_at,subscription_expires_at,now()),now()) + make_interval(days => v_days),
      subscription_auto_blocked=false,
      subscription_grace_until=null,
      updated_by=auth.uid(),
      updated_at=now()
    where id=p_company_id;
    v_title := format('Plan extendido %s días',v_days); v_body := coalesce(v_note,format('Administración Wissa extendió el plan por %s días.',v_days));
  else
    raise exception 'Accion administrativa no valida: %', v_action;
  end if;

  insert into public.company_subscription_events(company_id,event_type,title,body,sent_to,sent_at,metadata)
  values (p_company_id,'admin_'||v_action,v_title,v_body,auth.uid(),now(),jsonb_build_object('source','admin_web_v40','days',case when v_action='extend' then v_days else null end));

  return jsonb_build_object('ok',true,'company_id',p_company_id,'action',v_action,'title',v_title,'body',v_body);
end;
$$;

revoke execute on function public.yt_admin_companies_overview_v40(text,text,integer) from public;
revoke execute on function public.yt_admin_company_detail_v40(uuid) from public;
revoke execute on function public.yt_admin_company_update_v40(uuid,jsonb) from public;
revoke execute on function public.yt_admin_company_action_v40(uuid,text,text,integer) from public;

grant execute on function public.yt_admin_companies_overview_v40(text,text,integer) to authenticated, service_role;
grant execute on function public.yt_admin_company_detail_v40(uuid) to authenticated, service_role;
grant execute on function public.yt_admin_company_update_v40(uuid,jsonb) to authenticated, service_role;
grant execute on function public.yt_admin_company_action_v40(uuid,text,text,integer) to authenticated, service_role;

notify pgrst, 'reload schema';
commit;
