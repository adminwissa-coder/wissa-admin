type HourlyBlock = {
  standard_hourly_rate: number;
  deep_hourly_rate: number;
};

// Keep precision across edits (30 -> 31 -> 35 -> 40 -> 30).
// Only the final service amount is rounded to cents.
export function scaleCleaningPrices<T extends HourlyBlock>(
  blocks: T[], previousBase: number, nextBase: number, deepSurcharge: number,
): T[] {
  if (![previousBase, nextBase].every((n) => Number.isFinite(n) && n > 0)) {
    throw new Error('El precio base debe ser mayor que cero.');
  }
  const factor = nextBase / previousBase;
  return blocks.map((block) => {
    const rate = Number((block.standard_hourly_rate * factor).toFixed(10));
    return { ...block, standard_hourly_rate: rate, deep_hourly_rate: Number((rate + deepSurcharge).toFixed(10)) };
  });
}
