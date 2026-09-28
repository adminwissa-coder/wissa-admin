import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'

const root = process.cwd()
const read = (relative: string) => fs.readFileSync(path.join(root, relative), 'utf8')

test('V67.2 finanzas carga categorías activas y oculta plomería sin borrar datos', () => {
  const page = read('src/app/dashboard/finanzas/page.tsx')
  assert.match(page, /from\("service_categories"\)/)
  assert.match(page, /eq\("is_active", true\)/)
  assert.match(page, /isPlumbing/)
  assert.match(page, /excludedFacetValues=\{\{ service_category: \["Plomería", "Plomeria", "Plumbing"\] \}\}/)
})

test('V67.2 selector superior sincroniza categoría con movimientos y resumen', () => {
  const page = read('src/app/dashboard/finanzas/page.tsx')
  assert.match(page, /wissa_finance_summary_v67/)
  assert.match(page, /externalFacetValues=\{\{ service_category: selectedServiceCategory \}\}/)
  assert.match(page, /hiddenFacetKeys=\{\["service_category"\]\}/)
})

test('V67.2 conceptos contables filtran movimientos reales', () => {
  const page = read('src/app/dashboard/finanzas/page.tsx')
  for (const field of ['service_subtotal','extras_amount','travel_fee','tip_amount','kit_amount','platform_fee']) {
    assert.match(page, new RegExp(field))
  }
  assert.match(page, /rowFilter=\{rowFilter\}/)
})

test('AdminTablePage soporta filtros superiores premium sin duplicar el select', () => {
  const page = read('src/components/admin/AdminTablePage.tsx')
  assert.match(page, /hiddenFacetKeys/)
  assert.match(page, /excludedFacetValues/)
  assert.match(page, /rowFilter/)
  assert.match(page, /finance-premium-filters/)
})
