import assert from 'node:assert/strict'
import test from 'node:test'
import { materialsAccounting } from '../src/lib/materials-accounting.ts'

test('custom accounting shows zero basic, saved products and separate materials', () => {
  const a=materialsAccounting({ materials:{kit_amount:0,custom_materials_amount:17,items:[{name:'Escoba',quantity:1,unit_price:5,subtotal:5}]},pricing:{tax_amount:6.23} },17)
  assert.equal(a.basic_kit_amount,0)
  assert.equal(a.custom_materials_amount,17)
  assert.equal(a.materials_total,17)
  assert.match(String(a.materials_detail),/Escoba · 1 × USD 5.00 = USD 5.00/)
  assert.equal(a.snapshot_tax_amount,6.23)
})
test('legacy totals are retained without inventing a kit classification', () => {
  const a=materialsAccounting({},15)
  assert.equal(a.basic_kit_amount,null)
  assert.equal(a.custom_materials_amount,null)
  assert.equal(a.materials_total,15)
})
test('explicit zero kit is not replaced with an old aggregate', () => {
  assert.equal(materialsAccounting({basic_kit_amount:0,custom_materials_amount:0},15).basic_kit_amount,0)
})
