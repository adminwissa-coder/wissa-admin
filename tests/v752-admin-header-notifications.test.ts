import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const shell = fs.readFileSync('src/components/admin/AdminShell.tsx', 'utf8');
const css = fs.readFileSync('src/app/wissa-ui2.css', 'utf8');

test('V75.2 campana abre popover en lugar de navegar directamente', () => {
  assert.match(shell, /ui2-notification-popover/);
  assert.match(shell, /setNotificationOpen/);
  assert.match(shell, /Todas/);
  assert.match(shell, /No leídas/);
  assert.match(shell, /Sistema/);
});

test('V75.2 permite marcar notificaciones como leidas y abrir el centro completo', () => {
  assert.match(shell, /yt_admin_mark_notification_read/);
  assert.match(shell, /Marcar leídas/);
  assert.match(shell, /Ver todas las notificaciones/);
  assert.match(shell, /\/dashboard\/notificaciones/);
});

test('V75.2 badge es compacto y responsive', () => {
  assert.match(css, /ui2-notification-button > span:not\(\.sr-only\)/);
  assert.match(css, /border-radius:\s*999px/);
  assert.match(css, /ui2-notification-popover/);
  assert.match(css, /@media \(max-width: 720px\)/);
});
