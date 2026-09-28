import assert from 'node:assert/strict';
import test from 'node:test';
import { scaleCleaningPrices } from '../src/lib/scale-cleaning-prices.ts';

const blocks = [{ standard_hourly_rate: 12, deep_hourly_rate: 13.5, hours: 4, professionals: 1 }, { standard_hourly_rate: 15, deep_hourly_rate: 16.5, hours: 8, professionals: 2 }];
const price = (rate: number) => Math.round(4 * rate * 100) / 100;
test('31, 35 y 40 actualizan estándar y profunda sin sumar la base', () => {
  for (const [base, standard, deep] of [[31, 49.6, 55.6], [35, 56, 62], [40, 64, 70]]) {
    const next = scaleCleaningPrices(blocks, 30, base, 1.5);
    assert.equal(price(next[0].standard_hourly_rate), standard);
    assert.equal(price(next[0].deep_hourly_rate), deep);
    assert.equal(next[1].professionals, 2);
    assert.equal(next[1].hours, 8);
    assert.equal(next[1].standard_hourly_rate, 15 * base / 30);
  }
});
test('cambios sucesivos, decimales, recarga y regreso al precio original', () => {
  let previous = 30;
  let current = blocks;
  for (const next of [31, 35, 40, 17.37, 53.19, 30]) {
    current = JSON.parse(JSON.stringify(scaleCleaningPrices(current, previous, next, 1.5)));
    assert.equal(price(current[0].standard_hourly_rate), Math.round(48 * next / 30 * 100) / 100);
    previous = next;
  }
  assert.equal(price(current[0].standard_hourly_rate), 48);
});
test('usa la configuración existente, no una base 30 quemada', () => {
  const next = scaleCleaningPrices([{ standard_hourly_rate: 20, deep_hourly_rate: 22 }], 50, 75, 2);
  assert.equal(next[0].standard_hourly_rate, 30);
  assert.equal(next[0].deep_hourly_rate, 32);
  assert.throws(() => scaleCleaningPrices(blocks, 30, 0, 1.5));
});
