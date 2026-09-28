import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

/**
 * Utility required by shadcn/Rare UI.
 * Keeps Tailwind class merging while preserving Wissa's existing helpers.
 */
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function text(value: unknown, fallback = "Sin dato") {
  if (value === null || value === undefined) return fallback;
  const out = String(value).trim();
  if (!out || out === "null" || out === "undefined") return fallback;
  return out;
}

export function money(value: unknown, currency = "USD") {
  const raw =
    typeof value === "number"
      ? value
      : Number(String(value ?? "0").replace(/[^0-9.-]/g, ""));
  const amount = Number.isFinite(raw) ? raw : 0;

  return new Intl.NumberFormat("es-PA", {
    style: "currency",
    currency,
    minimumFractionDigits: 2,
  }).format(amount);
}

export function formatPanamaDateTime(value: unknown, fallback = "Sin dato") {
  if (!value) return fallback;
  const d = new Date(String(value));
  if (Number.isNaN(d.getTime())) return fallback;

  return new Intl.DateTimeFormat("es-PA", {
    timeZone: "America/Panama",
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(d);
}

export function formatPanamaDate(value: unknown, fallback = "Sin dato") {
  if (!value) return fallback;

  const raw = String(value);
  const d = raw.length <= 10 ? new Date(`${raw}T12:00:00-05:00`) : new Date(raw);
  if (Number.isNaN(d.getTime())) return fallback;

  return new Intl.DateTimeFormat("es-PA", {
    timeZone: "America/Panama",
    day: "2-digit",
    month: "short",
    year: "numeric",
  }).format(d);
}

export function formatPanamaTime(value: unknown, fallback = "Sin dato") {
  if (!value) return fallback;

  const raw = String(value);
  if (/^\d{2}:\d{2}/.test(raw)) return raw.slice(0, 5);

  const d = new Date(raw);
  if (Number.isNaN(d.getTime())) return fallback;

  return new Intl.DateTimeFormat("es-PA", {
    timeZone: "America/Panama",
    hour: "2-digit",
    minute: "2-digit",
  }).format(d);
}

export const date = formatPanamaDate;
export const datetime = formatPanamaDateTime;
export const dateOnly = formatPanamaDate;
export const dateTime = formatPanamaDateTime;
export const dateFmt = formatPanamaDate;

export function statusLabel(value: unknown) {
  const raw = text(value, "pending");
  const key = raw.toLowerCase().trim().replace(/[\s-]+/g, "_");
  const labels: Record<string, string> = {
    pending: "Pendiente",
    pending_payment: "Pendiente de pago",
    processing: "Procesando",
    approved: "Aprobado",
    paid: "Pagado",
    authorized: "Autorizado",
    paid_pending_acceptance: "Pago confirmado · esperando profesional",
    accepted: "Confirmada",
    completed_pending_release: "Completado · por liberar",
    completed: "Completado",
    released: "Liquidado",
    not_released: "No liberado",
    not_requested: "Sin devolución",
    refund_pending: "Devolución pendiente",
    refund_processing: "Devolución en revisión",
    refunded: "Reembolsado",
    refund_rejected: "Devolución rechazada",
    failed: "Fallido",
    rejected: "Rechazado",
    cancelled: "Cancelado",
    active: "Activo",
    inactive: "Inactivo",
    buyer: "Cliente",
    client: "Cliente",
    contratar: "Cliente",
    provider: "Ofrecer",
    vendor: "Ofrecer",
    ofrecer: "Ofrecer",
    both: "Cliente + Ofrecer",
    ambos: "Cliente + Ofrecer",
    paused: "Pausado",
    ready: "Ubicación lista",
    missing_location: "Falta ubicación",
    suspended: "Suspendido",
    queued: "En cola",
    sent: "Enviada",
    skipped: "Omitida",
    unread: "Sin leer",
    read: "Leída",
    archived: "Archivada",
    deleted: "Eliminada",
    notifications: "Notificación interna",
    internal_notifications: "Aviso interno",
    push_notification_logs: "Entrega al dispositivo",
    platform_commission_pending: "Ingreso Wissa pendiente",
    platform_commission_withdrawal: "Retiro Wissa",
    platform_commission_earned: "Ingreso Wissa generado",
    earned: "Ganada",
    booking_payment: "Pago de reserva",
    company_plan: "Plan empresarial",
    company_admin: "Admin empresa",
    company_staff: "Personal empresa",
    pending_admin: "Pendiente admin",
    invited: "Invitado",
    removed: "Removido",
    draft: "Borrador",
    not_required: "No requerido",
    provider_pending: "Por pagar a profesional",
    provider_payout: "Liquidación profesional",
    payout_request: "Solicitud profesional",
    withdrawal_request: "Solicitud de retiro",
    collected: "Retirada",
    "requiere cotización": "Precio no disponible",
    "requiere cotizacion": "Precio no disponible",
    "cotización": "Precio no disponible",
    cotizacion: "Precio no disponible",
  };

  return labels[key] || raw.replaceAll("_", " ");
}
