import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (p: string) => readFileSync(new URL(`../${p}`, import.meta.url), 'utf8');

test('V68.4 UI2-E aplica capa visual al AdminTablePage sin cambiar RPCs', () => {
  const page = read('src/components/admin/AdminTablePage.tsx');
  assert.match(page, /ui2-admin-table-page/);
  assert.match(page, /ui2-module-hero/);
  assert.match(page, /ui2-module-filters/);
  assert.match(page, /ui2-data-card/);
  assert.match(page, /supabase\.rpc/);
});

test('V68.4 UI2-E separa filtros de Servicios por estado y categoría', () => {
  const page = read('src/app/dashboard/servicios/page.tsx');
  assert.match(page, /statusOptions=\{\["all", "active", "inactive"\]\}/);
  assert.match(page, /facetFilters=[\s\S]*category/);
  assert.match(page, /excludedFacetValues=[\s\S]*Plomería/);
});

test('V68.4 UI2-E oculta Plomería del selector visual de precios sin borrar soporte interno', () => {
  const pricing = read('src/components/admin/CategoryPricingManagerPage.tsx');
  const tabBlock = pricing.slice(pricing.indexOf('const categoryTabs'), pricing.indexOf('function readObject'));
  assert.doesNotMatch(tabBlock, /Plomería/);
  assert.match(pricing, /plumbing_pricing/);
  assert.match(pricing, /Plomería solo diagnóstico/);
});

test('V68.4 UI2-E mejora notificaciones y responsive con base shadcn/Rare UI controlada', () => {
  const notifications = read('src/app/dashboard/notificaciones/page.tsx');
  const css = read('src/app/wissa-ui2.css');
  const pkg = read('package.json');
  assert.match(notifications, /Todos los tipos de aviso/);
  assert.match(notifications, /Todos los canales/);
  assert.match(css, /UI2-E · OPERATIONAL MODULES/);
  assert.match(css, /@media \(max-width: 760px\)/);
  assert.match(css, /prefers-reduced-motion/);
  assert.match(pkg, /shadcn/);
  assert.match(read('components.json'), /\"ui\"\s*:\s*\"@\/components\/ui\"/);
});
