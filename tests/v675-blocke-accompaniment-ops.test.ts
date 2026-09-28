import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'

const root = process.cwd()
const read = (file: string) => fs.readFileSync(path.join(root, file), 'utf8')

test('V67.5 Reservas expone categoría para operar Acompañamiento', () => {
  const page = read('src/components/admin/ReservationsPremiumPage.tsx')
  assert.match(page, /Categoría/)
  assert.match(page, /service_category/)
  assert.match(page, /Todas las categorías/)
})

test('V67.5 Admin incluye SQL operacional sin contabilidad paralela', () => {
  const sql = read('supabase/sql/WISSA-V67.5-BLOQUE-E-OPERACION-APPLY.sql')
  assert.match(sql, /yt_v675_finalize_accompaniment_selection/)
  assert.match(sql, /booking_professional_assignments/)
  assert.match(sql, /yt_v64_select_booking_candidates/)
  assert.doesNotMatch(sql, /create\s+table\s+.*accompaniment.*(finance|payout|tip|review)/i)
})
