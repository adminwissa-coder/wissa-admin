-- WISSA V66.3 - BLOQUE 3A - REALTIME
-- Habilita las tablas operativas necesarias en la publicación supabase_realtime.
-- Idempotente: solo agrega una tabla cuando existe y todavía no está publicada.
-- No borra datos, usuarios ni políticas RLS.

begin;

do $$
declare
  table_name text;
  realtime_tables text[] := array[
    'bookings',
    'booking_professional_assignments',
    'payment_orders',
    'provider_payouts',
    'booking_tips',
    'booking_tip_allocations',
    'withdrawal_requests',
    'payout_requests',
    'platform_commission_withdrawals',
    'booking_refunds',
    'company_payments',
    'company_payouts',
    'company_plan_orders',
    'company_booking_approvals',
    'services',
    'profiles',
    'availability'
  ];
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise exception 'No existe la publicación supabase_realtime en este proyecto.';
  end if;

  if exists (
    select 1 from pg_publication
    where pubname = 'supabase_realtime' and puballtables = true
  ) then
    raise notice 'supabase_realtime ya publica todas las tablas; no se requieren altas individuales.';
    return;
  end if;

  foreach table_name in array realtime_tables loop
    if to_regclass(format('public.%I', table_name)) is null then
      raise notice 'Realtime: %.% no existe; se omite.', 'public', table_name;
      continue;
    end if;

    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = table_name
    ) then
      execute format('alter publication supabase_realtime add table public.%I', table_name);
      raise notice 'Realtime habilitado para public.%', table_name;
    end if;
  end loop;
end
$$;

-- Marca de versión no invasiva en app_settings cuando la tabla existe.
do $$
begin
  if to_regclass('public.app_settings') is not null then
    insert into public.app_settings(key, value, updated_at)
    values (
      'wissa_release_realtime',
      jsonb_build_object(
        'version', '66.3',
        'block', '3A',
        'name', 'REALTIME',
        'updated_at', now()
      ),
      now()
    )
    on conflict (key) do update
      set value = excluded.value,
          updated_at = now();
  end if;
end
$$;

commit;
