import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'

const root = process.cwd()
const read = (relative: string) => fs.readFileSync(path.join(root, relative), 'utf8')

test('V66.8 distribución financiera conserva columnas separadas de servicio, extras y traslado', () => {
  const page = read('src/components/admin/FinancialDistributionPage.tsx')
  assert.match(page, /service_share/)
  assert.match(page, /extras_share/)
  assert.match(page, /travel_fee/)
  assert.match(page, /Pago profesional/)
})

test('V66.8 incluye SQL idempotente de recálculo sin tocar liquidaciones pagadas', () => {
  const sql = read('sql-release/WISSA-V66.8-HOTFIX-ERRORES-REALES-APPLY.sql')
  assert.match(sql, /yt_v668_assignment_recalculate/)
  assert.match(sql, /reason','paid_assignment'/)
  assert.match(sql, /extras_share=v_extras_net_share/)
  assert.match(sql, /travel_fee=v_travel_share/)
  assert.match(sql, /nullif\(b\.seller_payout,0\)/)
})
