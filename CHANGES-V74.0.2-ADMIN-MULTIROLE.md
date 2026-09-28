# V74.0.2 Admin Multirol

- Alinea Admin con el nuevo modelo de una sola identidad `Cliente + Ofrecer`.
- Corrige el KPI de profesionales para no perder cuentas `both` cuando el modo activo es Cliente.
- `yt_admin_clients_json` deja de excluir una cuenta solo por tener capacidad Ofrecer.
- Añade presentación legible de roles: Cliente / Ofrecer / Cliente + Ofrecer.
- Actualiza pruebas obsoletas que todavía inspeccionaban la ruta antigua de Reservas en vez de `ReservationsPremiumPage`.
- Actualiza pruebas de notificaciones a la implementación actual.
- Actualiza gates que aún esperaban un Admin pre-shadcn.
- `.env.local` queda permitido para desarrollo, pero bloqueado en auditoría de artefacto.

Validación ejecutada sobre el código revisado: 64/64 tests del Admin pasan.
