import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const manager = fs.readFileSync('src/components/admin/CategoryPricingManagerPage.tsx','utf8')
const card = fs.readFileSync('src/components/admin/AccompanimentPricingCard.tsx','utf8')
const config = fs.readFileSync('src/app/dashboard/configuracion/page.tsx','utf8')

test('V75.1 Acompañamiento vive junto a Limpieza y Exterior en Categorías y precios', () => {
  assert.match(manager, /key: "accompaniment"/)
  assert.match(manager, /title: "Acompañamiento"/)
  assert.match(manager, /AccompanimentPricingCard embedded/)
  assert.doesNotMatch(config, /<AccompanimentPricingCard/)
})

test('V75.1 Admin edita tarifa horas y opciones del wizard', () => {
  assert.match(card, /Tarifa por hora/)
  assert.match(card, /Mínimo de horas/)
  assert.match(card, /Máximo de horas/)
  assert.match(card, /Opciones del cliente/)
  assert.match(card, /label_es/)
  assert.match(card, /label_en/)
  assert.match(card, /Detalle obligatorio/)
  assert.match(card, /Agregar opción/)
  assert.match(card, /yt_admin_update_accompaniment_config_v751/)
})
