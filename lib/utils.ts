export function money(value: unknown) {
  const n = Number(value || 0);
  return new Intl.NumberFormat("es-PA", { style: "currency", currency: "USD" }).format(Number.isFinite(n) ? n : 0);
}

export function date(value: unknown) {
  if (!value) return "Sin fecha";
  try { return new Intl.DateTimeFormat("es-PA", { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" }).format(new Date(String(value))); }
  catch { return "Sin fecha"; }
}

export function text(value: unknown, fallback = "—") {
  if (value === null || value === undefined || value === "") return fallback;
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}
