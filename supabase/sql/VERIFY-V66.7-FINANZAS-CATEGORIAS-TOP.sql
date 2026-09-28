-- Verifica que exista el nuevo resumen filtrable por categoria.
select
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as arguments
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname='wissa_finance_summary_v67';

-- Prueba manual opcional desde una sesion admin autenticada:
-- select public.wissa_finance_summary_v67(null);
-- select public.wissa_finance_summary_v67('Limpieza');
