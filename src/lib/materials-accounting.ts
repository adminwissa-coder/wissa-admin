type Row = Record<string, unknown>
const record = (value: unknown): Row => {
  if (typeof value === 'string') { try { return record(JSON.parse(value)) } catch { return {} } }
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Row : {}
}
const number = (value: unknown) => Math.round((Math.max(0, Number(value) || 0) + Number.EPSILON) * 100) / 100

/** Read only persisted amounts. Never reconstruct a historical price from today's catalog. */
export function materialsAccounting(detailsValue: unknown, legacyAmount: unknown = 0): Row {
  const details = record(detailsValue)
  const pricing = record(details.pricing)
  const materials = record(details.materials ?? pricing.materials)
  const basic = materials.kit_amount ?? details.basic_kit_amount ?? pricing.basic_kit_amount
  const custom = materials.custom_materials_amount ?? details.custom_materials_amount ?? pricing.custom_materials_amount
  const known = basic != null && custom != null
  const items = Array.isArray(materials.items) ? materials.items.map(record) : []
  const breakdown = Array.isArray(details.pricing_breakdown) ? details.pricing_breakdown : Array.isArray(pricing.breakdown) ? pricing.breakdown : []
  return {
    basic_kit_amount: known ? number(basic) : null,
    custom_materials_amount: known ? number(custom) : null,
    materials_detail: items.map((item) => `${String(item.name || 'Material')} · ${number(item.quantity)} × USD ${number(item.unit_price).toFixed(2)} = USD ${number(item.subtotal).toFixed(2)}`).join(' | ') || (known ? 'Sin productos personalizados' : 'Reserva histórica sin desglose'),
    materials_total: known ? number(number(basic) + number(custom)) : number(legacyAmount),
    accounting_breakdown: breakdown.map(record).filter((item) => Number(item.value) > 0).map((item) => `${String(item.label || 'Concepto')}: USD ${number(item.value).toFixed(2)}`).join(' | '),
    snapshot_tax_amount: pricing.tax_amount ?? details.tax_amount ?? null,
    snapshot_platform_usage_fee: pricing.platform_usage_fee ?? details.platform_usage_fee ?? null,
  }
}
