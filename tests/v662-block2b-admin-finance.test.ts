import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
const root=process.cwd()
const read=(p:string)=>fs.readFileSync(path.join(root,p),'utf8')

test('V66.2 Finanzas Admin filtra por categoría y pasarela',()=>{
  const src=read('src/app/dashboard/finanzas/page.tsx')
  assert.match(src,/yt_admin_wissa_finance_v66_json/)
  assert.match(src,/service_category/)
  assert.match(src,/gateway/)
  assert.match(src,/Pago a profesionales/)
  assert.match(src,/Propinas/)
})

test('V66.2 Reservas Admin usa términos profesionales y conserva el desglose de equipo en el RPC',()=>{
  const src=read('src/components/admin/ReservationsPremiumPage.tsx')
  const sql=read('supabase/sql/WISSA-V66.2-BLOCK2B-FINANZAS-COMISIONES-APPLY.sql')
  assert.match(src,/yt_admin_bookings_v66_json/)
  assert.match(src,/Profesional/)
  assert.match(sql,/professional_breakdown/)
  assert.doesNotMatch(src,/label:\s*"Neto"/)
})

test('V66.2 Comisiones tiene filtros y retiro arriba',()=>{
  const page=read('src/app/dashboard/retiro-comision/page.tsx')
  const table=read('src/components/admin/AdminTablePage.tsx')
  assert.match(page,/yt_admin_wissa_marketplace_revenue_v66_json/)
  assert.match(page,/Todas las categorías/)
  assert.match(page,/Todas las pasarelas/)
  assert.match(table,/Retirar saldo Wissa/)
  assert.match(table,/facetFilters/)
})

test('V66.2 Distribución muestra servicio, extras, traslado, propina y pago profesional',()=>{
  const src=read('src/components/admin/FinancialDistributionPage.tsx')
  assert.match(src,/yt_admin_booking_distribution_v66/)
  assert.match(src,/<th>Extras<\/th>/)
  assert.match(src,/<th>Traslado<\/th>/)
  assert.match(src,/<th>Propina<\/th>/)
  assert.match(src,/<th>Pago profesional<\/th>/)
})

test('V66.2 Retiros Admin es assignment-aware y filtra categoría/pasarela',()=>{
  const page=read('src/app/dashboard/retiros/page.tsx')
  assert.match(page,/yt_admin_withdrawals_v66_json/)
  assert.match(page,/service_category/)
  assert.match(page,/gateway/)
  assert.match(page,/Total a liquidar/)
  assert.match(page,/Propina/)
})
