import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const read = (p: string) => fs.readFileSync(path.join(root, p), 'utf8');

test('sidebar principal queda simplificado y sin Moderación', () => {
  const shell = read('src/components/admin/AdminShell.tsx');
  for (const item of ['Dashboard','Reservas','Servicios','Profesionales','Empresas','Finanzas','Liquidaciones','Devoluciones','Configuración']) {
    assert.match(shell, new RegExp(`label: "${item}"`));
  }
  assert.doesNotMatch(shell, /label: "Moderación"/);
  assert.doesNotMatch(shell, /label: "Casos"/);
  assert.doesNotMatch(shell, /label: "Reportes"/);
});

test('existen hubs simples de Liquidaciones y Configuración', () => {
  assert.ok(fs.existsSync(path.join(root, 'src/app/dashboard/liquidaciones/page.tsx')));
  assert.ok(fs.existsSync(path.join(root, 'src/app/dashboard/configuracion/page.tsx')));
  const config = read('src/app/dashboard/configuracion/page.tsx');
  assert.match(config, /Reglas de equipo/);
  assert.match(config, /Moderación y Casos dejan de mostrarse/);
});

test('reservas usa columnas operativas simples', () => {
  const reservations = read('src/components/admin/ReservationsPremiumPage.tsx');
  for (const label of ['Reserva','Cliente','Servicio','Fecha','Profesional','Estado','Pago','Total']) {
    assert.match(reservations, new RegExp(label));
  }
  assert.doesNotMatch(reservations, /Configuración reservada/);
  assert.doesNotMatch(reservations, /Desglose profesional/);
});

test('finanzas incorpora selector superior por concepto', () => {
  const finance = read('src/app/dashboard/finanzas/page.tsx');
  for (const concept of ['Servicios','Extras','Traslado','Propinas','Kits y materiales','Comisión Wissa']) {
    assert.match(finance, new RegExp(concept));
  }
  assert.match(finance, /Ingresos totales/);
  assert.match(finance, /Pagos a profesionales/);
});

test('estilos del rediseño simple están incluidos', () => {
  const css = read('src/app/admin-overrides.css');
  for (const token of ['wissa-simple-shell','simple-sidebar','simple-kpi-grid','simple-dashboard-grid','simple-finance-tabs','simple-hub-grid']) {
    assert.match(css, new RegExp(token));
  }
});
