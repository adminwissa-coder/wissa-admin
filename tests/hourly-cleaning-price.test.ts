import assert from 'node:assert/strict';
import test from 'node:test';
import { hourlyServicePrice } from '../src/lib/hourly-cleaning-price.ts';

test('estándar 4 horas = 48, 5 horas = 60; profunda 4 horas = 54', () => {
  const block = { professionals: 1, hours: 4, standard_hourly_rate: 12 };
  assert.equal(hourlyServicePrice(block), 48);
  assert.equal(hourlyServicePrice({ ...block, hours: 5 }), 60);
  assert.equal(hourlyServicePrice(block, true, 1.5), 54);
});
test('tarifa, horas, profesionales y adicional son independientes y configurables', () => {
  const block = { professionals: 2, hours: 5, standard_hourly_rate: 14 };
  assert.equal(hourlyServicePrice(block), 140);
  assert.equal(hourlyServicePrice(block, true, 2), 160);
  assert.equal(hourlyServicePrice(block, true, 0), 140);
});
test('no suma campos heredados de precio base', () => {
  for (const base of [30, 35, 40, 200]) {
    assert.equal(hourlyServicePrice({ professionals: 1, hours: 4, standard_hourly_rate: 12, ...{ fixed_service_price: base } }), 48);
  }
});
