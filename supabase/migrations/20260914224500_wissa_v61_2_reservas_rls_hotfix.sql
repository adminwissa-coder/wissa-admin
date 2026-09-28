-- WISSA V61.2 - Hotfix RLS Reservas / Asignaciones multi-profesional
-- Corrige recursión entre las políticas SELECT de public.bookings y
-- public.booking_professional_assignments introducidas en V61.0.
--
-- Síntoma visible en Mobile:
--   "Reservas - No se pudieron cargar tus reservas."
-- incluso cuando el usuario no tiene reservas después de un reset QA.
--
-- Este script es idempotente y NO elimina datos ni usuarios.

begin;

-- Las funciones SECURITY DEFINER consultan las tablas base sin volver a entrar
-- en las políticas RLS que se están evaluando. No aceptan user_id externo para
-- evitar que un cliente pueda consultar pertenencia de otro usuario.
create or replace function public.yt_v61_current_user_is_booking_buyer(p_booking_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.bookings b
    where b.id = p_booking_id
      and b.buyer_id = auth.uid()
  );
$$;

create or replace function public.yt_v61_current_user_is_assigned_provider(p_booking_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.booking_professional_assignments a
    where a.booking_id = p_booking_id
      and a.provider_id = auth.uid()
      and a.status <> 'cancelled'
  );
$$;

revoke all on function public.yt_v61_current_user_is_booking_buyer(uuid) from public;
revoke all on function public.yt_v61_current_user_is_assigned_provider(uuid) from public;
grant execute on function public.yt_v61_current_user_is_booking_buyer(uuid) to authenticated;
grant execute on function public.yt_v61_current_user_is_assigned_provider(uuid) to authenticated;

-- Política de asignaciones: ya no consulta bookings directamente desde RLS.
drop policy if exists "v61_assignment_select" on public.booking_professional_assignments;
create policy "v61_assignment_select"
on public.booking_professional_assignments
for select
to authenticated
using (
  provider_id = auth.uid()
  or public.yt_v61_current_user_is_booking_buyer(booking_id)
  or public.yt_admin_is_current_admin()
);

-- Política de bookings para profesionales secundarios: ya no consulta la tabla
-- de asignaciones directamente desde RLS, evitando el ciclo bookings ->
-- assignments -> bookings.
drop policy if exists "v61_assigned_provider_booking_select" on public.bookings;
create policy "v61_assigned_provider_booking_select"
on public.bookings
for select
to authenticated
using (
  public.yt_v61_current_user_is_assigned_provider(id)
);

comment on function public.yt_v61_current_user_is_booking_buyer(uuid)
is 'V61.2 RLS helper: comprueba si auth.uid() es comprador de la reserva sin recursión entre políticas.';

comment on function public.yt_v61_current_user_is_assigned_provider(uuid)
is 'V61.2 RLS helper: comprueba si auth.uid() está asignado a la reserva sin recursión entre políticas.';

commit;
