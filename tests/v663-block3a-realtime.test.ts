import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

const read = (path: string) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8')
const hook = read('src/hooks/useRealtimeRefresh.ts')
const tablePage = read('src/components/admin/AdminTablePage.tsx')
const distribution = read('src/components/admin/FinancialDistributionPage.tsx')
const finance = read('src/app/dashboard/finanzas/page.tsx')
const dashboard = read('src/app/dashboard/page.tsx')

test('V66.3 Admin tiene Realtime con debounce y limpieza del canal', () => {
  assert.match(hook, /postgres_changes/)
  assert.match(hook, /visibilitychange/)
  assert.match(hook, /removeChannel/)
  assert.match(hook, /queuedRef/)
})

test('V66.3 AdminTablePage refresca reservas, finanzas, retiros y devoluciones por tabla', () => {
  assert.match(tablePage, /realtimeSourcesForModule/)
  assert.match(tablePage, /yt_admin_bookings_v66_json/)
  assert.match(tablePage, /yt_admin_wissa_finance_v66_json/)
  assert.match(tablePage, /yt_admin_withdrawals_v66_json/)
  assert.match(tablePage, /platform_commission_withdrawals/)
  assert.match(tablePage, /booking_refunds/)
})

test('V66.3 distribución y dashboard financiero se resincronizan sin pulsar Actualizar', () => {
  assert.match(distribution, /scope: "admin-distribution"/)
  assert.match(distribution, /booking_professional_assignments/)
  assert.match(finance, /scope:'admin-finance-summary'/)
  assert.match(dashboard, /scope: "admin-dashboard"/)
  assert.match(dashboard, /booking_tip_allocations/)
})
