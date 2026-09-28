import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'

const root = process.cwd()
const read = (p:string) => fs.readFileSync(path.join(root,p),'utf8')

test('V66.6 conserva caché de sesión y refresco silencioso en tablas admin', () => {
  const table = read('src/components/admin/AdminTablePage.tsx')
  const cache = read('src/lib/admin-table-cache.ts')
  assert.match(table, /readAdminTableCache/)
  assert.match(table, /writeAdminTableCache/)
  assert.match(table, /load\(true\)/)
  assert.match(cache, /sessionStorage/)
  assert.match(cache, /STALE_MAX_MS/)
})

test('V66.6 organiza el detalle administrativo por secciones comerciales', () => {
  const table = read('src/components/admin/AdminTablePage.tsx')
  assert.match(table, /Cliente y profesionales/)
  assert.match(table, /Finanzas/)
  assert.match(table, /Seguimiento/)
  assert.match(table, /Profesional: /)
})

test('V66.6 elimina proveedor como copy operativo en módulos principales', () => {
  const refunds = read('src/app/dashboard/devoluciones/page.tsx')
  const services = read('src/app/dashboard/servicios/page.tsx')
  assert.doesNotMatch(refunds, /label:\s*"Proveedor"/)
  assert.doesNotMatch(services, /label:\s*"Proveedor"/)
  assert.match(refunds, /Profesional/)
  assert.match(services, /Profesional/)
})

test('V66.6 muestra sincronización no bloqueante y detalle responsive', () => {
  const table = read('src/components/admin/AdminTablePage.tsx')
  const css = read('src/app/globals.css')
  assert.match(table, /Datos sincronizados automáticamente/)
  assert.match(css, /admin-freshness-row/)
  assert.match(css, /detail-sections/)
  assert.match(css, /grid-template-columns:1fr/)
})
