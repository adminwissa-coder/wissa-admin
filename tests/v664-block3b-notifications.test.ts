import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

const sql = fs.readFileSync(new URL('../supabase/sql/WISSA-V66.4-BLOCK3B-NOTIFICACIONES-APPLY.sql', import.meta.url), 'utf8')
const page = fs.readFileSync(new URL('../src/app/dashboard/notificaciones/page.tsx', import.meta.url), 'utf8')
const table = fs.readFileSync(new URL('../src/components/admin/AdminTablePage.tsx', import.meta.url), 'utf8')
const utils = fs.readFileSync(new URL('../src/lib/utils.ts', import.meta.url), 'utf8')

test('V66.4 Admin entrega el hotfix idempotente de notificaciones sin reset', () => {
  assert.match(sql, /WISSA V66\.4 \/ BLOQUE 3B/)
  assert.match(sql, /create table if not exists public\.user_push_tokens/)
  assert.match(sql, /yt_notification_upsert_v664/)
  assert.match(sql, /trg_zz_wissa_notification_guard_v664/)
  assert.match(sql, /wissa_v66_block3b_notifications/)
  assert.doesNotMatch(sql, /delete from auth\.users/i)
})

test('V66.4 Admin distingue entregas en cola de pendientes y fallidas', () => {
  assert.match(page, /"queued"/)
  assert.match(utils, /queued:\s*[\"']En cola[\"']/)
  assert.match(table, /\["pending", "queued"\]\.includes/)
  assert.match(table, /Entregas en proceso/)
})
