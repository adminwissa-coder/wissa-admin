import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const cfg = fs.readFileSync('src/components/admin/CategoryPricingManagerPage.tsx','utf8');
const card = fs.readFileSync('src/components/admin/AccompanimentPricingCard.tsx','utf8');

test('V75.1 Categorías y precios muestra editor de Acompañamiento', () => {
  assert.match(cfg, /AccompanimentPricingCard/);
  assert.match(card, /Tarifa por hora/);
  assert.match(card, /Mínimo de horas/);
  assert.match(card, /80% profesional \/ 20% Wissa/);
  assert.match(card, /yt_admin_update_accompaniment_config_v751/);
});

test('V67.3 editor conserva tarifa única y mínimo técnico de 2 horas', () => {
  assert.match(card, /hourly_rate: 15/);
  assert.match(card, /minimum_hours: 2/);
  assert.match(card, /presentation_mode: "single_rate"/);
  assert.match(card, /Math\.max\(2/);
});
