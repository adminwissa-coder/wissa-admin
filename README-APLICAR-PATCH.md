# WISSA Admin V74.0.2 — Multirol + Release Gate

Aplicar sobre el Admin Web actual, conservando `.env.local` local.

Corrige:
- Dashboard: contador de Profesionales alineado con cuentas `provider_enabled` / `both`.
- Clientes: cuentas `both` siguen visibles como Cliente y muestran `Cliente + Ofrecer`.
- Gate de pruebas actualizado al componente premium real de Reservas.
- Tests antiguos de pre-shadcn actualizados a la integración Rare UI/shadcn actual.
- Auditoría local permite `.env.local`; auditoría de artefacto con `--artifact` lo bloquea.

SQL:
Ejecutar `supabase/sql/WISSA-V74.0.2-ADMIN-MULTIROLE-APPLY.sql` después del SQL V74 Mobile.
No borra usuarios ni datos de negocio.

Validar en tu PC:

```powershell
npm run typecheck
npm test
npm run lint
npm run build
npm run ui2:audit
node scripts/ui2-release-audit.mjs --artifact
```

Nota: el último comando debe ejecutarse sobre una copia/ZIP de entrega sin `.env.local`. En tu directorio local con `.env.local`, debe bloquear el artefacto de forma intencional.
