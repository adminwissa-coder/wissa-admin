import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
const root=process.cwd()
const read=(p:string)=>fs.readFileSync(path.join(root,p),'utf8')

test('V68.3 UI2-D conserva RPC financieros reales',()=>{
  const src=read('src/app/dashboard/finanzas/page.tsx')
  assert.match(src,/wissa_finance_summary_v67/)
  assert.match(src,/yt_admin_wissa_finance_v66_json/)
  assert.match(src,/service_categories/)
})

test('V68.3 UI2-D categoría gobierna visuales y movimientos',()=>{
  const src=read('src/app/dashboard/finanzas/page.tsx')
  assert.match(src,/selectedServiceCategory/)
  assert.match(src,/externalFacetValues=\{\{ service_category: selectedServiceCategory \}\}/)
  assert.match(src,/categoryRows/)
  assert.match(src,/buildTrend\(categoryRows/)
})

test('V68.3 UI2-D preserva conceptos contables y oculta plomería solo visualmente',()=>{
  const src=read('src/app/dashboard/finanzas/page.tsx')
  for (const field of ['service_subtotal','extras_amount','travel_fee','tip_amount','kit_amount','platform_fee']) assert.match(src,new RegExp(field))
  assert.match(src,/isPlumbing/)
  assert.match(src,/excludedFacetValues=\{\{ service_category: \["Plomería", "Plomeria", "Plumbing"\] \}\}/)
})

test('V68.3 UI2-D incluye UI responsive y reduced motion',()=>{
  const css=read('src/app/wissa-ui2.css')
  assert.match(css,/WISSA UI 2\.0 · UI2-D FINANZAS/)
  assert.match(css,/@media \(max-width: 760px\)/)
  assert.match(css,/@media \(prefers-reduced-motion: reduce\)/)
})
