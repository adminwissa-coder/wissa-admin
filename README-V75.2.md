# WISSA Admin V75.2 — Header Notifications Polish

## Incluye
- Badge compacta y circular en la campana.
- Popover de notificaciones sin salir de la pantalla actual.
- Filtros: Todas / No leídas / Sistema.
- Acción Marcar leídas.
- Acceso Ver todas las notificaciones.
- Responsive y dark mode usando tokens existentes.

## No cambia
- SQL
- Supabase schema
- Dependencias
- Centro completo de notificaciones

## Validación local
```powershell
npm run typecheck
npm test
npm run build
```

El test específico incluido es `tests/v752-admin-header-notifications.test.ts`.
