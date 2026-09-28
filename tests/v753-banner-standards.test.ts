import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('src/app/dashboard/banners/page.tsx', 'utf8')

test('V75.3 Admin define banner estándar 1200x600 y valida 2:1', () => {
  assert.match(source, /BANNER_WIDTH = 1200/)
  assert.match(source, /BANNER_HEIGHT = 600/)
  assert.match(source, /mínimo 1000×500 px/)
  assert.match(source, /relación 2:1/)
})

test('V75.3 Admin informa rotación automática del Home', () => {
  assert.match(source, /Automática cada 5\.5 s/)
})
