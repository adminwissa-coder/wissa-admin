export function hourlyServicePrice(
  block: { professionals: number; hours: number; standard_hourly_rate: number },
  deep = false,
  deepSurcharge = 1.5,
) {
  const rate = block.standard_hourly_rate + (deep ? deepSurcharge : 0);
  return Math.round(block.professionals * Math.min(8, block.hours) * rate * 100) / 100;
}
