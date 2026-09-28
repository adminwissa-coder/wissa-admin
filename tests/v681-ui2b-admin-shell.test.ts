import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const read = (p: string) => fs.readFileSync(path.join(root, p), 'utf8');

test('UI2-B aplica shell premium sin reemplazar rutas principales', () => {
  const shell = read('src/components/admin/AdminShell.tsx');
  assert.match(shell, /wissa-ui2-shell/);
  assert.match(shell, /ui2-sidebar/);
  assert.match(shell, /ui2-global-search/);
  assert.match(shell, /yt_admin_notifications_json/);
  assert.match(shell, /yt_admin_is_current_admin/);
  assert.match(shell, /yt-admin-theme/);
});

test('UI2-B conserva navegación simple aprobada y añade búsqueda a módulos reales', () => {
  const shell = read('src/components/admin/AdminShell.tsx');
  for (const item of ['Dashboard','Reservas','Servicios','Profesionales','Empresas','Finanzas','Liquidaciones','Devoluciones','Configuración']) {
    assert.match(shell, new RegExp(`label: "${item}"`));
  }
  for (const route of ['/dashboard/usuarios','/dashboard/categorias','/dashboard/notificaciones','/dashboard/beneficios','/dashboard/reportes']) {
    assert.match(shell, new RegExp(route.replaceAll('/', '\\/')));
  }
});

test('UI2-B importa tokens y prepara tema antes de hidratar', () => {
  const layout = read('src/app/layout.tsx');
  assert.match(layout, /wissa-ui2\.css/);
  assert.match(layout, /suppressHydrationWarning/);
  assert.match(layout, /prefers-color-scheme: dark/);
});

test('UI2-B incluye responsive y reduced motion', () => {
  const css = read('src/app/wissa-ui2.css');
  assert.match(css, /@media \(max-width: 1040px\)/);
  assert.match(css, /@media \(max-width: 760px\)/);
  assert.match(css, /prefers-reduced-motion/);
});
