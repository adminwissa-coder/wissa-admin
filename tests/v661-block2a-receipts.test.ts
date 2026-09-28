import assert from 'node:assert/strict'
import test from 'node:test'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(resolve(here, '../src/components/admin/AdminTablePage.tsx'), 'utf8')

test('V66.1 selector de comprobante se abre antes del prompt de liquidación', () => {
  const start = source.indexOf('async function releaseBooking')
  const block = source.slice(start, source.indexOf('async function markNotification', start) > start ? source.indexOf('async function markNotification', start) : start + 12000)
  const picker = block.indexOf('await choosePayoutReceipt()')
  const prompt = block.indexOf('window.prompt("Nota o referencia de liquidación:')
  assert.ok(picker >= 0, 'releaseBooking debe abrir el selector de comprobante')
  assert.ok(prompt > picker, 'el prompt debe ejecutarse después del selector para conservar user activation')
})

test('V66.1 comprobante valida PDF/JPG/PNG, 10MB y guarda metadata de storage', () => {
  assert.match(source, /application\/pdf,image\/jpeg,image\/png/)
  assert.match(source, /10 \* 1024 \* 1024/)
  assert.match(source, /provider-payout-receipts/)
  assert.match(source, /p_receipt_bucket: uploaded\.bucket/)
  assert.match(source, /p_receipt_path: uploaded\.path/)
  assert.match(source, /p_receipt_name: receipt\.name/)
  assert.match(source, /p_receipt_size: receipt\.size/)
})

test('V66.1 el selector oculto permanece en DOM y maneja cancelación/foco', () => {
  assert.doesNotMatch(source, /input\.style\.display = "none"/)
  assert.match(source, /input\.style\.position = "fixed"/)
  assert.match(source, /input\.addEventListener\("cancel"/)
  assert.match(source, /window\.addEventListener\("focus", onWindowFocus\)/)
})
