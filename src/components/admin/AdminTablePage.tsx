"use client";

import { adminMessage, isInternalDetail } from "@/lib/admin-copy";
import { adminTableCacheKey, readAdminTableCache, writeAdminTableCache } from "@/lib/admin-table-cache";

import { ReactNode, useCallback, useEffect, useMemo, useState } from "react";
import { Archive, ArchiveRestore, Ban, CheckCheck, CheckCircle2, Clock, Download, Eye, FileText, RefreshCcw, RotateCcw, Search, Send, ShieldCheck, Trash2, Unlock, Upload, UserRound, XCircle } from "lucide-react";
import { materialsAccounting } from "@/lib/materials-accounting";
import { supabase } from "@/lib/supabase";
import { useRealtimeRefresh, type RealtimeSource } from "@/hooks/useRealtimeRefresh";
import { datetime, formatPanamaDate, formatPanamaTime, money, statusLabel, text } from "@/lib/utils";
import {
  isBusinessNotification,
  normalizeAdminNotificationRows,
  notificationMembers,
} from "@/lib/admin-notifications";

type Row = Record<string, unknown>;
type Column = {
  key: string;
  label: string;
  type?: "text" | "money" | "date" | "datetime" | "time" | "status" | "user" | "plan";
};
type FacetFilter = {
  key: string;
  label: string;
  allLabel?: string;
};
type Props = {
  title: string;
  eyebrow: string;
  description: string;
  rpc: string;
  entity?: string;
  columns: Column[];
  actions?: "users" | "payments" | "plans" | "bookings" | "withdrawals" | "platform_commissions" | "company_liquidations" | "refunds" | "notifications";
  enableDateFilter?: boolean;
  statusOptions?: string[];
  searchPlaceholder?: string;
  facetFilters?: FacetFilter[];
  externalFacetValues?: Record<string, string>;
  onFacetValueChange?: (key: string, value: string) => void;
  hiddenFacetKeys?: string[];
  excludedFacetValues?: Record<string, string[]>;
  rowFilter?: (row: Row) => boolean;
};

type RpcParams = {
  p_search: string;
  p_status: string;
  p_limit?: number;
  p_date_from?: string | null;
  p_date_to?: string | null;
};
type StatItem = { label: string; value: ReactNode; helper?: string; tone?: "default" | "danger" };

const defaultStatusOpts = ["all", "pending", "approved", "rejected", "cancelled", "active", "suspended", "paid", "failed", "released", "not_released", "not_requested", "refund_pending", "refund_processing", "refunded", "refund_rejected", "provider_pending", "provider_payout", "payout_request", "withdrawal_request", "platform_commission_pending", "platform_commission_withdrawal", "platform_commission_earned", "collected", "earned", "sent", "skipped", "read", "unread", "archived", "deleted"];


function realtimeSourcesForModule(rpc: string, actions?: Props["actions"]): RealtimeSource[] {
  if (rpc === "yt_admin_bookings_v66_json" || actions === "bookings") {
    return [
      { table: "bookings" },
      { table: "booking_professional_assignments" },
      { table: "payment_orders" },
      { table: "provider_payouts" },
      { table: "booking_tips" },
      { table: "booking_tip_allocations" },
    ];
  }
  if (rpc === "yt_admin_wissa_finance_v66_json") {
    return [
      { table: "bookings" },
      { table: "booking_professional_assignments" },
      { table: "payment_orders" },
      { table: "provider_payouts" },
      { table: "booking_tips" },
      { table: "booking_tip_allocations" },
      { table: "platform_commission_withdrawals" },
    ];
  }
  if (rpc === "yt_admin_withdrawals_v66_json" || actions === "withdrawals") {
    return [
      { table: "withdrawal_requests" },
      { table: "payout_requests" },
      { table: "provider_payouts" },
      { table: "booking_tip_allocations" },
      { table: "booking_professional_assignments" },
      { table: "bookings" },
    ];
  }
  if (rpc === "yt_admin_wissa_marketplace_revenue_v66_json" || actions === "platform_commissions") {
    return [
      { table: "bookings" },
      { table: "payment_orders" },
      { table: "platform_commission_withdrawals" },
      { table: "booking_tips" },
    ];
  }
  if (rpc === "yt_admin_refunds_json" || actions === "refunds") {
    return [
      { table: "booking_refunds" },
      { table: "payment_orders" },
      { table: "bookings" },
    ];
  }
  if (rpc === "yt_admin_company_services_finance_json" || actions === "company_liquidations") {
    return [
      { table: "company_payments" },
      { table: "company_payouts" },
      { table: "company_plan_orders" },
      { table: "bookings" },
    ];
  }
  return [];
}
const hiddenFields = new Set(["metadata", "raw_response", "pf_response", "yappy_response", "yappy_ipn_payload", "checkout_url", "public_checkout_token", "push_token", "travel_rate_per_km", "travel_distance_km", "error_message"]);
const hiddenDetailFields = new Set([
  ...hiddenFields,
  "id",
  "user_id",
  "buyer_id",
  "provider_id",
  "company_id",
  "booking_id",
  "payment_order_id",
  "related_booking_id",
  "reference_id",
  "admin_read_by",
  "admin_archived_by",
  "admin_deleted_by",
  "dedupe_key",
  "rn",
  "__notification_members",
]);
const labels: Record<string, string> = {
  id: "ID",
  booking_id: "Reserva",
  buyer_name: "Cliente",
  provider_name: "Profesional",
  provider_email: "Correo profesional",
  provider_city: "Ciudad profesional",
  provider_status: "Estado profesional",
  provider_verified: "Profesional verificado",
  service_title: "Servicio",
  category: "Categoría",
  status_label: "Estado",
  payment_status_label: "Pago",
  is_active: "Activo",
  location_status: "Ubicación base",
  offer_location_address: "Dirección base",
  offer_latitude: "Latitud base",
  offer_longitude: "Longitud base",
  legacy_price: "Precio anterior",
  base_price: "Tarifa del servicio",
  bookings_count: "Reservas creadas",
  total_booked_amount: "Total reservado",
  duration_minutes: "Duración",
  payout_release_status: "Liquidación",
  finance_status: "Finanzas",
  amount: "Monto",
  platform_fee: "Comisión Wissa 20%",
  commission_amount: "Comisión Wissa 20%",
  kit_amount: "Kit y materiales",
  basic_kit_amount: "Kit básico",
  custom_materials_amount: "Materiales personalizados",
  materials_detail: "Detalle de materiales",
  materials_total: "Total de materiales",
  accounting_breakdown: "Desglose de la reserva",
  snapshot_tax_amount: "ITBMS",
  snapshot_platform_usage_fee: "Cargo plataforma",
  wissa_kit_revenue: "Ingreso por kit",
  wissa_total_revenue: "Ingresos Wissa por servicios",
  service_subtotal: "Servicio profesional",
  travel_fee: "Movilidad incluida",
  travel_distance_km: "Distancia operativa",
  travel_rate_per_km: "Configuración anterior",
  provider_net: "Pago profesional o empresa",
  subtotal_amount: "Subtotal de la reserva",
  pricing_summary: "Configuración reservada",
  pricing_source_label: "Fuente del precio",
  pricing_breakdown: "Desglose del precio",
  requires_quote: "Precio no disponible",
  quote_status: "Estado del precio",
  booking_date: "Fecha reserva",
  booking_time: "Hora reserva",
  created_at: "Creado",
  updated_at: "Actualizado",
  paid_at: "Pagado",
  completed_at: "Completado",
  payout_released_at: "Liquidado",
  provider_paid_out_at: "Pago profesional",
  assignment_id: "Asignación profesional",
  payout_id: "Liquidación",
  payout_status: "Estado liquidación",
  payout_receipt_path: "Comprobante de pago",
  receipt_path: "Comprobante de pago",
  service_type: "Modalidad",
  maintenance_frequency: "Frecuencia mantenimiento",
  maintenance_discount_rate: "Descuento mantenimiento",
  maintenance_discount_amount: "Ahorro mantenimiento",
  square_meters: "Metraje",
  required_professionals: "Profesionales requeridos",
  base_required_professionals: "Profesionales base",
  optional_professionals: "Profesionales adicionales",
  optional_professional_fee: "Cargo profesional adicional",
  third_professional_flat_fee: "Tarifa 3er profesional",
  kit_basic_amount: "Kit básico",
  tip_amount: "Propina",
  released_at: "Liberado",
  admin_release_note: "Nota admin",
  location: "Ubicación",
  notes: "Notas",
  title: "Título",
  message: "Mensaje",
  body: "Mensaje",
  type: "Tipo",
  source: "Origen",
  party_name: "Cuenta",
  is_read: "Leída",
  read_status: "Lectura",
  admin_read_at: "Leida por admin",
  admin_archived_at: "Archivada por admin",
  is_archived: "Archivada",
  admin_deleted_at: "Eliminada por admin",
  is_deleted: "Eliminada",
  push_status: "Entrega",
  error_message: "Detalle de entrega",
  method: "Método",
  gateway: "Pasarela",
  company_id: "Empresa",
  provider_id: "Profesional",
  payment_order_id: "Orden de pago",
  period_start: "Periodo desde",
  period_end: "Periodo hasta",
  reference: "Referencia",
  requested_at: "Solicitada",
  processing_at: "En revision",
  refunded_at: "Devuelta",
  rejected_at: "Rechazada",
  refund_status: "Devolucion",
  refund_status_label: "Estado de devolucion",
  refund_reason: "Motivo de devolucion",
  refund_note: "Nota de devolucion",
  refund_method: "Metodo de devolucion",
  refund_reference: "Referencia de devolucion",
  refund_requested_at: "Devolucion solicitada",
  refund_processing_at: "Devolucion en revision",
  refund_completed_at: "Devuelta",
  refund_rejected_at: "Devolucion rechazada",
};


function pricingNumber(...values: unknown[]): number {
  for (const value of values) {
    const n = typeof value === "number" ? value : Number(value);
    if (Number.isFinite(n) && n >= 0) return n;
  }
  return 0;
}

function objectValue(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function categoryPricingKey(category: unknown): "cleaning_pricing" | "exterior_cleaning_pricing" | "plumbing_pricing" | null {
  const normalized = String(category ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .trim();
  if (normalized.includes("plomer")) return "plumbing_pricing";
  if (normalized.includes("exterior")) return "exterior_cleaning_pricing";
  if (normalized.includes("limpieza")) return "cleaning_pricing";
  return null;
}

function configuredServicePrice(key: string, rawValue: unknown): number {
  const value = objectValue(rawValue);
  if (key === "plumbing_pricing") {
    const jobBase = objectValue(value.job_base);
    return pricingNumber(value.inspection_fee, jobBase.revision);
  }
  const fixedPrices = objectValue(value.fixed_service_prices);
  const plans = objectValue(value.plans);
  return pricingNumber(fixedPrices.basica, value.fixed_service_price, plans.basica);
}

async function hydrateServicePricing(rows: Row[]): Promise<Row[]> {
  if (!rows.length) return rows;

  const { data, error } = await supabase
    .from("app_settings")
    .select("key,value")
    .in("key", ["cleaning_pricing", "exterior_cleaning_pricing", "plumbing_pricing"]);

  if (error || !Array.isArray(data)) return rows;

  const settings = new Map<string, unknown>();
  for (const item of data as Array<{ key?: string; value?: unknown }>) {
    if (item.key) settings.set(item.key, item.value);
  }

  return rows.map((row) => {
    const current = pricingNumber(row.base_price);
    if (current > 0) return row;

    const key = categoryPricingKey(row.category);
    if (!key) return row;

    const configured = configuredServicePrice(key, settings.get(key));
    return configured > 0 ? { ...row, base_price: configured } : row;
  });
}

export default function AdminTablePage({ title, eyebrow, description, rpc, entity, columns, actions, enableDateFilter = false, statusOptions, searchPlaceholder = "Buscar por nombre, servicio, referencia o estado...", facetFilters = [], externalFacetValues, onFacetValueChange, hiddenFacetKeys = [], excludedFacetValues = {}, rowFilter }: Props) {
  const [rows, setRows] = useState<Row[]>([]);
  const [searchDraft, setSearchDraft] = useState("");
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("all");
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");
  const [view, setView] = useState<Row | null>(null);
  const [processingId, setProcessingId] = useState<string | null>(null);
  const [facetValues, setFacetValues] = useState<Record<string, string>>({});
  const [lastUpdatedAt, setLastUpdatedAt] = useState<number | null>(null);

  useEffect(() => {
    if (!externalFacetValues) return;
    setFacetValues((current) => {
      let changed = false;
      const next = { ...current };
      for (const [key, value] of Object.entries(externalFacetValues)) {
        const normalized = value || "all";
        if ((next[key] || "all") !== normalized) {
          next[key] = normalized;
          changed = true;
        }
      }
      return changed ? next : current;
    });
  }, [externalFacetValues]);

  const updateFacetValue = useCallback((key: string, value: string) => {
    setFacetValues((current) => ({ ...current, [key]: value }));
    onFacetValueChange?.(key, value);
  }, [onFacetValueChange]);

  const realtimeSources = useMemo(() => realtimeSourcesForModule(rpc, actions), [actions, rpc]);
  const cacheKey = useMemo(() => adminTableCacheKey([rpc, entity, search, status, dateFrom, dateTo]), [dateFrom, dateTo, entity, rpc, search, status]);

  const visibleRows = useMemo(() => rows.filter((row) => {
    for (const [key, blockedValues] of Object.entries(excludedFacetValues)) {
      const current = asString(row[key]).trim().toLowerCase();
      if (blockedValues.some((value) => current === value.trim().toLowerCase())) return false;
    }
    return rowFilter ? rowFilter(row) : true;
  }), [excludedFacetValues, rowFilter, rows]);

  const facetOptions = useMemo(() => {
    const result: Record<string, string[]> = {};
    for (const facet of facetFilters) {
      const seen = new Map<string, string>();
      for (const row of visibleRows) {
        const raw = asString(row[facet.key]).trim();
        if (!raw) continue;
        const normalized = raw.toLowerCase();
        if (!seen.has(normalized)) seen.set(normalized, raw);
      }
      result[facet.key] = [...seen.values()].sort((a, b) => a.localeCompare(b, "es"));
    }
    return result;
  }, [facetFilters, visibleRows]);

  const displayRows = useMemo(() => visibleRows.filter((row) => facetFilters.every((facet) => {
    const selected = facetValues[facet.key] || "all";
    if (selected === "all") return true;
    return asString(row[facet.key]).trim().toLowerCase() === selected.toLowerCase();
  })), [facetFilters, facetValues, visibleRows]);

  const stats = useMemo(() => buildStats(displayRows, actions, rpc), [actions, displayRows, rpc]);
  const quickStatusOptions = useMemo(() => buildQuickStatusOptions(statusOptions || defaultStatusOpts, actions), [actions, statusOptions]);

  const load = useCallback(async (silent = false) => {
    if (!silent) setLoading(true);
    setErr("");

    const params: RpcParams = { p_search: search, p_status: status, p_limit: 200 };
    if (enableDateFilter) {
      params.p_date_from = dateFrom || null;
      params.p_date_to = dateTo || null;
    }

    let res = entity === "profiles"
      ? await supabase.rpc("yt_admin_list_profiles", { p_search: search, p_role: "all", p_status: status })
      : await supabase.rpc(rpc, params);

    if (res.error && rpc === "yt_admin_withdrawals_v66_json" && /could not find the function|schema cache|does not exist|PGRST202/i.test(res.error.message)) {
      res = await supabase.rpc("yt_admin_withdrawals_v65_json", params);
    }
    if (res.error && rpc === "yt_admin_withdrawals_v65_json" && /could not find the function|schema cache|does not exist|PGRST202/i.test(res.error.message)) {
      res = await supabase.rpc("yt_admin_withdrawals_json", params);
    }

    if (res.error) {
      setErr(res.error.message);
      setRows([]);
    } else {
      let nextRows = Array.isArray(res.data) ? (res.data as Row[]) : [];
      if (rpc === "yt_admin_services_json") {
        nextRows = await hydrateServicePricing(nextRows);
      }
      if ((rpc === "yt_admin_wissa_finance_json" || rpc === "yt_admin_wissa_finance_v66_json") && nextRows.length) {
        const ids = [...new Set(nextRows.map((row) => String(row.booking_id || row.id || "")).filter(Boolean))];
        const snapshots = new Map<string, unknown>();
        for (let offset = 0; offset < ids.length; offset += 50) {
          const { data, error } = await supabase.from("bookings").select("id,service_details").in("id", ids.slice(offset, offset + 50));
          if (error) { setErr("No se pudo cargar el desglose de materiales. Vuelve a actualizar: " + error.message); break; }
          for (const booking of data || []) snapshots.set(String(booking.id), booking.service_details);
        }
        nextRows = nextRows.map((row) => ({ ...row, ...materialsAccounting(snapshots.get(String(row.booking_id || row.id)), row.kit_amount) }));
      }
      const normalizedRows = normalizeModuleRows(nextRows, actions, rpc);
      setRows(normalizedRows);
      writeAdminTableCache(cacheKey, normalizedRows);
      setLastUpdatedAt(Date.now());
    }

    setLoading(false);
  }, [actions, cacheKey, dateFrom, dateTo, enableDateFilter, entity, rpc, search, status]);

  useEffect(() => {
    const cached = readAdminTableCache<Row[]>(cacheKey);
    if (cached?.value?.length) {
      setRows(cached.value);
      setLoading(false);
      setLastUpdatedAt(Date.now());
      const timer = window.setTimeout(() => void load(true), cached.isFresh ? 250 : 0);
      return () => window.clearTimeout(timer);
    }
    const timer = window.setTimeout(() => void load(), 0);
    return () => window.clearTimeout(timer);
  }, [cacheKey, load]);

  useRealtimeRefresh({
    scope: `admin-table-${rpc}`,
    sources: realtimeSources,
    onRefresh: () => load(true),
  });

  async function updatePushLog(pushLogId: string | null | undefined, payload: Row) {
    if (!pushLogId) return;
    const { error } = await supabase
      .from("push_notification_logs")
      .update({
        ...payload,
        updated_at: new Date().toISOString(),
      })
      .eq("id", pushLogId);
    if (error) setErr(`La liquidación quedó registrada, pero no se pudo actualizar el estado de la notificación.`);
  }

  async function choosePayoutReceipt(): Promise<File | null> {
    return new Promise((resolve) => {
      const input = document.createElement("input");
      input.type = "file";
      input.accept = ".pdf,.jpg,.jpeg,.png,application/pdf,image/jpeg,image/png";
      // Mantener el input dentro del DOM, pero fuera de pantalla. Algunos navegadores
      // bloquean el selector cuando el input está display:none o cuando se abre después
      // de un prompt que ya consumió la activación del usuario.
      input.style.position = "fixed";
      input.style.left = "-10000px";
      input.style.top = "0";
      input.style.width = "1px";
      input.style.height = "1px";
      input.style.opacity = "0";
      document.body.appendChild(input);

      let settled = false;
      const cleanup = () => {
        window.removeEventListener("focus", onWindowFocus);
        input.remove();
      };
      const finish = (file: File | null) => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(file);
      };
      const onWindowFocus = () => {
        // Safari/Chrome no siempre emiten "cancel". Al recuperar foco damos un pequeño
        // margen para que "change" se procese primero.
        window.setTimeout(() => {
          if (!settled && (!input.files || input.files.length === 0)) finish(null);
        }, 350);
      };

      input.addEventListener("change", () => finish(input.files?.[0] || null), { once: true });
      input.addEventListener("cancel", () => finish(null), { once: true });
      window.addEventListener("focus", onWindowFocus);
      input.click();
    });
  }

  function validatePayoutReceipt(file: File) {
    const allowed = new Set(["application/pdf", "image/jpeg", "image/png"]);
    const extensionOk = /\.(pdf|jpe?g|png)$/i.test(file.name);
    if ((!allowed.has(file.type) && !extensionOk) || file.size <= 0) return "El comprobante debe ser PDF, JPG, JPEG o PNG.";
    if (file.size > 10 * 1024 * 1024) return "El comprobante no puede superar 10 MB.";
    return "";
  }

  async function uploadPayoutReceipt(row: Row, file: File) {
    const bookingId = asString(row.booking_id) || rowId(row);
    const assignmentId = asString(row.assignment_id || row.booking_assignment_id) || "booking";
    const providerId = asString(row.provider_id);
    const safeName = file.name.replace(/[^A-Za-z0-9._-]+/g, "-").slice(-90) || "comprobante";
    const path = `${providerId || "provider"}/${bookingId}/${assignmentId}/${Date.now()}-${safeName}`;
    const bucket = "provider-payout-receipts";
    const { error } = await supabase.storage.from(bucket).upload(path, file, {
      contentType: file.type || undefined,
      upsert: false,
    });
    if (error) throw new Error(`No se pudo subir el comprobante: ${error.message}`);
    return { bucket, path };
  }

  async function openPayoutReceipt(row: Row) {
    const bucket = asString(row.payout_receipt_bucket || row.receipt_bucket) || "provider-payout-receipts";
    const path = asString(row.payout_receipt_path || row.receipt_path);
    if (!path) return;
    setErr("");
    const { data, error } = await supabase.storage.from(bucket).createSignedUrl(path, 300);
    if (error || !data?.signedUrl) {
      setErr(error?.message || "No se pudo abrir el comprobante de pago.");
      return;
    }
    const target = window.open(data.signedUrl, "_blank", "noopener,noreferrer");
    if (target) target.opener = null;
  }

  async function releaseBooking(row: Row) {
    const bookingId = asString(row.booking_id) || rowId(row);
    const assignmentId = asString(row.assignment_id || row.booking_assignment_id) || null;
    const providerIdFromRow = asString(row.provider_id);
    if (!bookingId) return;
    if (!providerIdFromRow) {
      setErr("No se puede registrar el pago porque no hay un profesional asignado. Revisa la reserva.");
      return;
    }

    // Abrir el selector DIRECTAMENTE desde el clic del botón. Antes se mostraba un
    // window.prompt primero y el navegador perdía la activación del usuario, por lo que
    // el selector podía no abrirse.
    const receipt = await choosePayoutReceipt();
    if (!receipt) return;

    const fileError = validatePayoutReceipt(receipt);
    if (fileError) { setErr(fileError); return; }

    const note = window.prompt("Nota o referencia de liquidación:", "Liquidado desde admin web");
    if (note === null) return;

    setProcessingId(assignmentId || bookingId);
    setErr("");
    let uploaded: { bucket: string; path: string } | null = null;

    try {
      uploaded = await uploadPayoutReceipt(row, receipt);
      const { data, error } = await supabase.rpc("yt_admin_release_provider_assignment_v65", {
        p_booking_id: bookingId,
        p_assignment_id: assignmentId,
        p_provider_id: providerIdFromRow,
        p_note: note || null,
        p_method: "manual_admin",
        p_receipt_bucket: uploaded.bucket,
        p_receipt_path: uploaded.path,
        p_receipt_name: receipt.name,
        p_receipt_mime: receipt.type || null,
        p_receipt_size: receipt.size,
      });

      if (error) {
        await supabase.storage.from(uploaded.bucket).remove([uploaded.path]);
        if (/could not find the function|schema cache|does not exist|PGRST202/i.test(error.message)) {
          throw new Error("No se pudo registrar la liquidación. Contacta a soporte si el problema continúa.");
        }
        throw new Error(error.message);
      }

      const result = (data || {}) as Row;
      const providerId = asString(result.provider_id) || providerIdFromRow;
      const pushLogId = asString(result.push_log_id) || null;
      const payoutId = asString(result.payout_id) || null;
      const releasedTitle = asString(result.title);
      const releasedBody = asString(result.body);
      const releasedScreen = asString(result.screen);
      const pushTitle = releasedTitle && releasedTitle !== "Pago liquidado" ? releasedTitle : "Liquidación registrada";
      const pushBody = releasedBody && !releasedBody.toLowerCase().includes("administraci")
        ? releasedBody
        : "Wissa registró tu liquidación. Revisa Finanzas para ver el monto y el comprobante.";

      if (!providerId) throw new Error("La liquidación fue procesada sin destinatario válido. Revisa la asignación del profesional.");

      try {
        const push = await supabase.functions.invoke("send-push", {
          body: {
            userId: providerId,
            title: pushTitle,
            body: pushBody,
            type: "payout_released_admin",
            screen: releasedScreen || "/(provider-tabs)/earnings",
            relatedBookingId: bookingId,
            data: { booking_id: bookingId, payout_id: payoutId, push_log_id: pushLogId, sent_from: "admin-web" },
          },
        });
        const pushData = (push.data || {}) as Row;
        if (push.error || pushData.ok === false) {
          const message = push.error?.message || String(pushData.error || pushData.reason || "No se pudo enviar la notificación.");
          await updatePushLog(pushLogId, { status: pushData.skipped ? "skipped" : "failed", error_message: message, response: pushData });
          setErr(`La liquidación y el comprobante quedaron registrados. No se pudo notificar al profesional.`);
        } else {
          await updatePushLog(pushLogId, { status: "sent", error_message: null, response: pushData, sent_at: new Date().toISOString() });
        }
      } catch (pushError) {
        const message = pushError instanceof Error ? pushError.message : "No se pudo enviar la notificación.";
        await updatePushLog(pushLogId, { status: "failed", error_message: message, response: { error: message } });
        setErr(`La liquidación y el comprobante quedaron registrados. No se pudo notificar al profesional.`);
      }

      await load();
    } catch (error) {
      setErr(error instanceof Error ? error.message : "No se pudo registrar la liquidación.");
    } finally {
      setProcessingId(null);
    }
  }

  async function act(action: string, id: string, note?: string) {
    setProcessingId(id);
    setErr("");
    const { error } = await supabase.rpc("yt_admin_action", { p_action: action, p_id: id, p_note: note || null });
    if (error) setErr(error.message);
    else await load();
    setProcessingId(null);
  }

  async function markNotification(row: Row, isRead: boolean) {
    const members = notificationMembers(row);
    if (members.length === 0) return;

    setProcessingId(rowId(row));
    setErr("");
    for (const member of members) {
      const { error } = await supabase.rpc("yt_admin_mark_notification_read", {
        p_source: member.source,
        p_id: member.id,
        p_is_read: isRead,
      });
      if (error) {
        setErr(error.message);
        setProcessingId(null);
        return;
      }
    }
    window.dispatchEvent(new Event("yt-admin-notifications-changed"));
    await load();
    setProcessingId(null);
  }

  async function markVisibleNotificationsRead() {
    const unreadRows = rows.filter((row) => !isArchived(row) && !isNotificationRead(row) && rowId(row) && asString(row.source));
    if (unreadRows.length === 0) return;

    setProcessingId("notifications-visible");
    setErr("");
    for (const row of unreadRows) {
      for (const member of notificationMembers(row)) {
        const { error } = await supabase.rpc("yt_admin_mark_notification_read", {
          p_source: member.source,
          p_id: member.id,
          p_is_read: true,
        });
        if (error) {
          setErr(error.message);
          setProcessingId(null);
          return;
        }
      }
    }
    window.dispatchEvent(new Event("yt-admin-notifications-changed"));
    await load();
    setProcessingId(null);
  }

  async function archiveNotification(row: Row, archived: boolean) {
    const members = notificationMembers(row);
    if (members.length === 0) return;

    setProcessingId(rowId(row));
    setErr("");
    for (const member of members) {
      const { error } = await supabase.rpc("yt_admin_archive_notification", {
        p_source: member.source,
        p_id: member.id,
        p_is_archived: archived,
      });
      if (error) {
        setErr(error.message);
        setProcessingId(null);
        return;
      }
    }
    window.dispatchEvent(new Event("yt-admin-notifications-changed"));
    await load();
    setProcessingId(null);
  }

  async function archiveVisibleNotifications() {
    const visibleRows = rows.filter((row) => !isArchived(row) && rowId(row) && asString(row.source));
    if (visibleRows.length === 0) return;
    const ok = window.confirm(`Archivar ${visibleRows.length} notificaciones visibles? Quedaran disponibles en el filtro Archivadas.`);
    if (!ok) return;

    setProcessingId("notifications-archive-visible");
    setErr("");
    for (const row of visibleRows) {
      for (const member of notificationMembers(row)) {
        const { error } = await supabase.rpc("yt_admin_archive_notification", {
          p_source: member.source,
          p_id: member.id,
          p_is_archived: true,
        });
        if (error) {
          setErr(error.message);
          setProcessingId(null);
          return;
        }
      }
    }
    window.dispatchEvent(new Event("yt-admin-notifications-changed"));
    await load();
    setProcessingId(null);
  }

  async function deleteNotification(row: Row, deleted: boolean) {
    const members = notificationMembers(row);
    if (members.length === 0) return;

    if (deleted) {
      const ok = window.confirm("Eliminar esta notificacion del centro admin? Quedara oculta en el filtro Eliminadas.");
      if (!ok) return;
    }

    setProcessingId(rowId(row));
    setErr("");
    for (const member of members) {
      const { error } = await supabase.rpc("yt_admin_delete_notification", {
        p_source: member.source,
        p_id: member.id,
        p_is_deleted: deleted,
      });
      if (error) {
        setErr(error.message);
        setProcessingId(null);
        return;
      }
    }
    window.dispatchEvent(new Event("yt-admin-notifications-changed"));
    await load();
    setProcessingId(null);
  }

  async function deleteVisibleNotifications() {
    const visibleRows = rows.filter((row) => !isDeleted(row) && rowId(row) && asString(row.source));
    if (visibleRows.length === 0) return;
    const ok = window.confirm(`Eliminar ${visibleRows.length} notificaciones visibles del centro admin? Quedaran disponibles en el filtro Eliminadas.`);
    if (!ok) return;

    setProcessingId("notifications-delete-visible");
    setErr("");
    for (const row of visibleRows) {
      for (const member of notificationMembers(row)) {
        const { error } = await supabase.rpc("yt_admin_delete_notification", {
          p_source: member.source,
          p_id: member.id,
          p_is_deleted: true,
        });
        if (error) {
          setErr(error.message);
          setProcessingId(null);
          return;
        }
      }
    }
    window.dispatchEvent(new Event("yt-admin-notifications-changed"));
    await load();
    setProcessingId(null);
  }

  function applyFilters() {
    const nextSearch = searchDraft.trim();
    if (nextSearch !== search) setSearch(nextSearch);
    else void load();
  }

  function resetFilters() {
    setSearchDraft("");
    setSearch("");
    setStatus("all");
    setDateFrom("");
    setDateTo("");
    setFacetValues({});
    for (const facet of facetFilters) onFacetValueChange?.(facet.key, "all");
  }

  async function withdrawPlatformCommission(row: Row) {
    const maxAmount = asNumber(row.amount);
    if (maxAmount <= 0) return;

    const amountText = window.prompt("Monto a retirar para Wissa (comisión 20% + kits):", maxAmount.toFixed(2));
    if (amountText === null) return;

    const amount = Number(String(amountText).replace(/[^0-9.]/g, ""));
    if (!Number.isFinite(amount) || amount <= 0) {
      setErr("Ingresa un monto válido para el retiro de ingresos Wissa.");
      return;
    }

    const note = window.prompt("Nota o referencia del retiro:", "Retiro manual de comisión + kits Wissa");
    if (note === null) return;

    setProcessingId(rowId(row));
    setErr("");

    const { error } = await supabase.rpc("yt_admin_withdraw_wissa_marketplace_revenue", {
      p_amount: amount,
      p_note: note,
      p_method: "manual_admin",
      p_period_start: dateFrom || null,
      p_period_end: dateTo || null,
    });

    if (error) setErr(error.message);
    else await load();
    setProcessingId(null);
  }

  function canRelease(row: Row) {
    const paymentStatus = String(row.payment_status || "").toLowerCase();
    const bookingStatus = String(row.status || "").toLowerCase();
    const releaseStatus = String(row.payout_release_status || row.release_status || row.payout_status || "not_released").toLowerCase();
    const required = Math.max(1, asNumber(row.required_professionals) || 1);
    const hasAssignment = Boolean(asString(row.assignment_id || row.booking_assignment_id));
    const hasProvider = Boolean(asString(row.provider_id));
    if (!hasProvider) return false;
    if (required > 1 && !hasAssignment) return false;
    return paymentStatus === "paid" && ["completed", "completed_pending_release"].includes(bookingStatus) && !["released", "paid"].includes(releaseStatus);
  }

  function canWithdrawPlatformCommission(row: Row) {
    return actions === "platform_commissions" && asString(row.source) === "platform_commission_pending" && asNumber(row.amount) > 0;
  }

  function canLiquidateCompany(row: Row) {
    const releaseStatus = String(row.release_status || row.payout_release_status || "not_released").toLowerCase();
    const paymentStatus = String(row.payment_status || "").toLowerCase();
    const status = String(row.status || "").toLowerCase();
    return actions === "company_liquidations" && paymentStatus === "paid" && ["completed", "completed_pending_release", "accepted", "paid_pending_acceptance"].includes(status) && releaseStatus !== "released";
  }

  async function liquidateCompanyBooking(row: Row) {
    const bookingId = rowId(row);
    if (!bookingId) return;

    const note = window.prompt("Referencia o nota de pago a la empresa:", "Liquidación empresa desde admin web");
    if (note === null) return;

    setProcessingId(bookingId);
    setErr("");

    const { error } = await supabase.rpc("yt_admin_liquidate_company_booking", {
      p_booking_id: bookingId,
      p_note: note,
      p_method: "manual_admin",
    });

    if (error) setErr(error.message);
    else await load();
    setProcessingId(null);
  }

  function canReviewRefund(row: Row) {
    return actions === "refunds" && asString(row.status).toLowerCase() === "refund_pending";
  }

  function canCompleteRefund(row: Row) {
    const status = asString(row.status).toLowerCase();
    return actions === "refunds" && ["refund_pending", "refund_processing"].includes(status);
  }

  function canRejectRefund(row: Row) {
    const status = asString(row.status).toLowerCase();
    return actions === "refunds" && ["refund_pending", "refund_processing"].includes(status);
  }

  async function markRefund(row: Row, action: "refund_processing" | "refunded" | "refund_rejected") {
    const refundId = rowId(row);
    if (!refundId) return;

    const note: string | null = action === "refund_processing" ? "Revision iniciada desde admin web" : window.prompt(action === "refunded" ? "Nota de devolucion manual:" : "Motivo para rechazar la devolucion:", "");
    if (note === null) return;

    let reference: string | null = null;
    if (action === "refunded") {
      reference = window.prompt("Referencia de la devolucion manual:", `WISSA-REF-${refundId.slice(0, 8).toUpperCase()}`);
      if (reference === null) return;
    }

    setProcessingId(refundId);
    setErr("");

    const { error } = await supabase.rpc("yt_admin_mark_booking_refund", {
      p_refund_id: refundId,
      p_action: action,
      p_note: note || null,
      p_reference: reference || null,
    });

    if (error) setErr(error.message);
    else await load();
    setProcessingId(null);
  }

  function exportExcel() {
    downloadTextFile(`${fileSafe(title)}-${todayStamp()}.xls`, buildExcelHtml(title, columns, displayRows), "application/vnd.ms-excel;charset=utf-8");
  }

  function exportPdf() {
    const html = buildPrintHtml(title, columns, displayRows, {
      search,
      status,
      dateFrom,
      dateTo,
    });
    const frame = document.createElement("iframe");
    frame.title = `${title} PDF`;
    frame.style.position = "fixed";
    frame.style.right = "0";
    frame.style.bottom = "0";
    frame.style.width = "0";
    frame.style.height = "0";
    frame.style.border = "0";
    frame.style.opacity = "0";
    frame.style.pointerEvents = "none";
    document.body.appendChild(frame);

    const printWindow = frame.contentWindow;
    const doc = printWindow?.document;
    if (!printWindow || !doc) {
      frame.remove();
      setErr("No se pudo preparar el PDF. Intenta nuevamente.");
      return;
    }

    doc.open();
    doc.write(html);
    doc.close();

    window.setTimeout(() => {
      try {
        printWindow.focus();
        printWindow.print();
      } catch {
        setErr("No se pudo abrir el diálogo de impresión. Usa Excel mientras revisamos el navegador.");
      } finally {
        window.setTimeout(() => frame.remove(), 1500);
      }
    }, 300);
  }

  return (
    <div className="admin-page ui2-admin-table-page" data-admin-module={actions || rpc}>
      <section className="hero ui2-module-hero">
        <div className="hero-row">
          <div>
            <div className="eyebrow">{eyebrow}</div>
            <h1>{title}</h1>
            <p className="subtitle">{description}</p>
          </div>
          <div className="hero-actions">
            {actions === "notifications" ? (
              <>
                <button className="btn btn-soft" disabled={processingId === "notifications-visible" || rows.every(isNotificationRead)} onClick={() => void markVisibleNotificationsRead()}>
                  <CheckCheck size={17} />
                  {processingId === "notifications-visible" ? "Marcando..." : "Marcar visibles leídas"}
                </button>
                <button className="btn btn-soft" disabled={processingId === "notifications-archive-visible" || rows.length === 0 || rows.every(isArchived)} onClick={() => void archiveVisibleNotifications()}>
                  <Archive size={17} />
                  {processingId === "notifications-archive-visible" ? "Archivando..." : "Archivar visibles"}
                </button>
                <button className="btn btn-soft" disabled={processingId === "notifications-delete-visible" || rows.length === 0 || rows.every(isDeleted)} onClick={() => void deleteVisibleNotifications()}>
                  <Trash2 size={17} />
                  {processingId === "notifications-delete-visible" ? "Eliminando..." : "Eliminar visibles"}
                </button>
              </>
            ) : null}
            {actions === "platform_commissions" && rows.some(canWithdrawPlatformCommission) ? (
              <button
                className="btn btn-green"
                disabled={processingId === rowId(rows.find(canWithdrawPlatformCommission) || {})}
                onClick={() => { const pendingRow = rows.find(canWithdrawPlatformCommission); if (pendingRow) void withdrawPlatformCommission(pendingRow); }}
              >
                <CheckCircle2 size={17} />Retirar saldo Wissa
              </button>
            ) : null}
            <button className="btn btn-primary" onClick={() => load(false)}><RefreshCcw size={17} />Actualizar</button>
          </div>
        </div>
      </section>

      <section className="stats ui2-module-stats">
        {stats.map((item) => (
          <Stat key={item.label} label={item.label} value={item.value} helper={item.helper} danger={item.tone === "danger"} />
        ))}
      </section>

      <section className={`card toolbar filter-panel ui2-module-filters ${enableDateFilter ? "date-toolbar" : ""} ${rpc === "yt_admin_wissa_finance_v66_json" ? "finance-premium-filters" : ""}`}>
        <div style={{ position: "relative" }}>
          <Search size={19} style={{ position: "absolute", left: 14, top: 14, color: "var(--muted2)" }} />
          <input className="input" style={{ paddingLeft: 45 }} value={searchDraft} onChange={(e) => setSearchDraft(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") applyFilters(); }} placeholder={searchPlaceholder} />
        </div>
        <select className="select" value={status} onChange={(e) => setStatus(e.target.value)}>
          {(statusOptions || defaultStatusOpts).map((s) => <option key={`${s}-${title}`} value={s}>{s === "all" ? "Todos los estados" : statusLabel(s)}</option>)}
        </select>
        {facetFilters.filter((facet) => !hiddenFacetKeys.includes(facet.key)).map((facet) => (
          <select
            key={`${title}-${facet.key}`}
            className="select"
            value={facetValues[facet.key] || "all"}
            onChange={(e) => updateFacetValue(facet.key, e.target.value)}
            aria-label={facet.label}
          >
            <option value="all">{facet.allLabel || `Todas: ${facet.label}`}</option>
            {(facetOptions[facet.key] || []).map((option) => <option key={`${facet.key}-${option}`} value={option}>{option}</option>)}
          </select>
        ))}
        {enableDateFilter ? (
          <>
            <input className="input" type="date" value={dateFrom} onChange={(e) => setDateFrom(e.target.value)} aria-label="Fecha desde" />
            <input className="input" type="date" value={dateTo} onChange={(e) => setDateTo(e.target.value)} aria-label="Fecha hasta" />
          </>
        ) : null}
        <button className="btn btn-soft" onClick={applyFilters}>Buscar</button>
        <button className="btn btn-soft" onClick={resetFilters}>Limpiar</button>
        <button className="btn btn-soft" onClick={exportExcel} disabled={displayRows.length === 0}><Download size={16} />Excel</button>
        <button className="btn btn-soft" onClick={exportPdf} disabled={displayRows.length === 0}><FileText size={16} />PDF</button>
      </section>

      {quickStatusOptions.length > 0 ? (
        <div className="filter-chips ui2-segmented-status">
          {quickStatusOptions.map((option) => (
            <button
              key={`${title}-${option}`}
              className={`filter-chip ${status === option ? "active" : ""}`}
              onClick={() => setStatus(option)}
            >
              {option === "all" ? "Todos" : statusLabel(option)}
            </button>
          ))}
        </div>
      ) : null}

      {(search || status !== "all" || dateFrom || dateTo || Object.values(facetValues).some((value) => value && value !== "all")) ? (
        <div className="filter-summary">
          {search ? <span>Búsqueda: {search}</span> : null}
          {status !== "all" ? <span>Estado: {statusLabel(status)}</span> : null}
          {dateFrom ? <span>Desde: {dateFrom}</span> : null}
          {dateTo ? <span>Hasta: {dateTo}</span> : null}
          {facetFilters.map((facet) => { const value = facetValues[facet.key]; return value && value !== "all" ? <span key={`summary-${facet.key}`}>{facet.label}: {value}</span> : null; })}
        </div>
      ) : null}

      {err ? <div className="error" style={{ marginBottom: 18 }}>{adminMessage(err)}</div> : null}

      <div className="admin-freshness-row" role="status" aria-live="polite">
        <span className={`admin-live-dot ${loading ? "syncing" : ""}`} />
        <span>{loading && rows.length ? "Actualizando en segundo plano…" : "Datos sincronizados automáticamente"}</span>
        {lastUpdatedAt ? <small>Última actualización: {new Date(lastUpdatedAt).toLocaleTimeString("es-PA", { hour: "2-digit", minute: "2-digit" })}</small> : null}
      </div>

      <section className="card table-card ui2-data-card">
        <div className="table-wrap">
          <table className="table responsive-table">
            <thead>
              <tr>{columns.map((c) => <th key={c.key}>{c.label}</th>)}<th>Acciones</th></tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={columns.length + 1} className="empty">Cargando datos...</td></tr>
              ) : displayRows.length === 0 ? (
                <tr><td colSpan={columns.length + 1} className="empty">No hay datos para mostrar.</td></tr>
              ) : displayRows.map((row, i) => (
                <tr key={rowId(row) || i}>
                  {columns.map((c) => <td key={c.key} data-label={c.label} data-column={c.key}>{render(c, row, actions)}</td>)}
                  <td data-label="Acciones" className="table-actions-cell">
                    <div className="actions">
                      <button className="btn btn-soft btn-small" onClick={() => setView(row)}><Eye size={14} />Ver</button>
                      {actions === "withdrawals" && asString(row.provider_id) ? (
                        <a className="btn btn-soft btn-small" href={`/dashboard/ofrecer/${encodeURIComponent(asString(row.provider_id))}`}><UserRound size={14} />Profesional</a>
                      ) : null}
                      {actions === "withdrawals" && asString(row.payout_receipt_path || row.receipt_path) ? (
                        <button className="btn btn-soft btn-small" onClick={() => void openPayoutReceipt(row)}><FileText size={14} />Comprobante</button>
                      ) : null}
                      {(actions === "bookings" || actions === "withdrawals") && canRelease(row) ? (
                        <button className="btn btn-primary btn-small" disabled={processingId === rowId(row)} onClick={() => releaseBooking(row)}><Upload size={14} />{processingId === rowId(row) || processingId === asString(row.assignment_id) ? "Procesando..." : actions === "withdrawals" ? "Liquidar + comprobante" : "Liberar"}</button>
                      ) : null}
                      {canWithdrawPlatformCommission(row) ? (
                        <button className="btn btn-green btn-small" disabled={processingId === rowId(row)} onClick={() => withdrawPlatformCommission(row)}><CheckCircle2 size={14} />{processingId === rowId(row) ? "Registrando..." : "Registrar retiro"}</button>
                      ) : null}
                      {canLiquidateCompany(row) ? (
                        <button className="btn btn-green btn-small" disabled={processingId === rowId(row)} onClick={() => void liquidateCompanyBooking(row)}><CheckCircle2 size={14} />{processingId === rowId(row) ? "Liquidando..." : "Liquidar empresa"}</button>
                      ) : null}
                      {canReviewRefund(row) ? (
                        <button className="btn btn-soft btn-small" disabled={processingId === rowId(row)} onClick={() => void markRefund(row, "refund_processing")}><Clock size={14} />{processingId === rowId(row) ? "Revisando..." : "Revisar"}</button>
                      ) : null}
                      {canCompleteRefund(row) ? (
                        <button className="btn btn-green btn-small" disabled={processingId === rowId(row)} onClick={() => void markRefund(row, "refunded")}><RotateCcw size={14} />{processingId === rowId(row) ? "Guardando..." : "Marcar devuelta"}</button>
                      ) : null}
                      {canRejectRefund(row) ? (
                        <button className="btn btn-danger btn-small" disabled={processingId === rowId(row)} onClick={() => void markRefund(row, "refund_rejected")}><XCircle size={14} />Rechazar</button>
                      ) : null}
                      {actions === "notifications" ? (
                        <>
                          {isNotificationRead(row) ? (
                            <button className="btn btn-soft btn-small" disabled={processingId === rowId(row)} onClick={() => void markNotification(row, false)}><CheckCheck size={14} />Marcar sin leer</button>
                          ) : (
                            <button className="btn btn-green btn-small" disabled={processingId === rowId(row)} onClick={() => void markNotification(row, true)}><CheckCheck size={14} />Marcar leída</button>
                          )}
                          {isArchived(row) ? (
                            <button className="btn btn-soft btn-small" disabled={processingId === rowId(row)} onClick={() => void archiveNotification(row, false)}><ArchiveRestore size={14} />Restaurar</button>
                          ) : (
                            <button className="btn btn-soft btn-small" disabled={processingId === rowId(row)} onClick={() => void archiveNotification(row, true)}><Archive size={14} />Archivar</button>
                          )}
                          {isDeleted(row) ? (
                            <button className="btn btn-green btn-small" disabled={processingId === rowId(row)} onClick={() => void deleteNotification(row, false)}><ArchiveRestore size={14} />Restaurar</button>
                          ) : (
                            <button className="btn btn-danger btn-small" disabled={processingId === rowId(row)} onClick={() => void deleteNotification(row, true)}><Trash2 size={14} />Eliminar</button>
                          )}
                        </>
                      ) : null}
                      {actions === "users" && (row.is_suspended || row.status === "suspended" ? (
                        <button className="btn btn-green btn-small" onClick={() => void act("unsuspend_user", rowId(row))}><Unlock size={14} />Activar</button>
                      ) : (
                        <button className="btn btn-danger btn-small" disabled={row.role === "admin" || Boolean(row.is_admin)} onClick={() => { const note = prompt("Motivo de suspension:", "Suspendido desde Wissa"); if (note !== null) void act("suspend_user", rowId(row), note); }}><Ban size={14} />Suspender</button>
                      ))}
                      {actions === "payments" && row.status === "pending" ? (
                        <>
                          <button className="btn btn-green btn-small" onClick={() => void act("approve_payment", rowId(row))}><CheckCircle2 size={14} />Aprobar</button>
                          <button className="btn btn-danger btn-small" onClick={() => void act("reject_payment", rowId(row))}><Ban size={14} />Rechazar</button>
                        </>
                      ) : null}
                      {actions === "plans" && row.status === "pending" ? (
                        <>
                          <button className="btn btn-green btn-small" onClick={() => void act("approve_plan", rowId(row))}><CheckCircle2 size={14} />Aprobar</button>
                          <button className="btn btn-danger btn-small" onClick={() => void act("reject_plan", rowId(row))}><Ban size={14} />Rechazar</button>
                        </>
                      ) : null}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {view ? <DetailModal title={title} row={view} columns={columns} onClose={() => setView(null)} /> : null}
    </div>
  );
}

function buildStats(rows: Row[], actions: Props["actions"], rpc: string): StatItem[] {
  if (actions === "refunds") {
    const pending = rows.filter((row) => normalizedStatus(row) === "refund_pending");
    const processing = rows.filter((row) => normalizedStatus(row) === "refund_processing");
    const refunded = rows.filter((row) => normalizedStatus(row) === "refunded");
    const pendingAmount = sumRows(pending, "amount");
    const processingAmount = sumRows(processing, "amount");
    const refundedAmount = sumRows(refunded, "amount");

    return [
      { label: "Por devolver", value: money(pendingAmount), helper: `${pending.length} solicitudes`, tone: pendingAmount > 0 ? "danger" : "default" },
      { label: "En revision", value: money(processingAmount), helper: `${processing.length} en proceso`, tone: processing.length > 0 ? "danger" : "default" },
      { label: "Devuelto", value: money(refundedAmount), helper: `${refunded.length} cerradas` },
      { label: "Solicitudes visibles", value: rows.length, helper: "Segun filtros" },
    ];
  }

  if (actions === "company_liquidations") {
    const paid = rows.filter((row) => asString(row.payment_status).toLowerCase() === "paid");
    const pendingRelease = rows.filter((row) => asString(row.release_status || row.payout_release_status).toLowerCase() !== "released");
    const total = rows.reduce((sum, row) => sum + asNumber(row.amount), 0);
    const net = rows.reduce((sum, row) => sum + asNumber(row.company_net), 0);
    return [
      { label: "Total cobrado", value: money(total), helper: `${paid.length} pagos aprobados` },
      { label: "Monto a empresas", value: money(net), helper: "Monto a liquidar" },
      { label: "Pendientes", value: pendingRelease.length, helper: "Por liquidar", tone: pendingRelease.length > 0 ? "danger" : "default" },
      { label: "Registros", value: rows.length, helper: "Según filtros" },
    ];
  }

  if (actions === "platform_commissions") {
    const earnedRows = rows.filter((row) => asString(row.source) === "platform_commission_earned");
    const withdrawalRows = rows.filter((row) => asString(row.source) === "platform_commission_withdrawal");
    const pendingAmount = sumRows(rows.filter((row) => asString(row.source) === "platform_commission_pending"), "amount");
    const commissionAmount = sumRows(earnedRows, "commission_amount");
    const kitAmount = sumRows(earnedRows, "kit_amount");
    const earnedAmount = sumRows(earnedRows, "amount");
    const withdrawnAmount = sumRows(withdrawalRows, "amount");

    return [
      { label: "Comisión 20% generada", value: money(commissionAmount), helper: "Solo servicio profesional" },
      { label: "Kits y materiales generados", value: money(kitAmount), helper: "100% ingreso Wissa" },
      { label: "Ingresos por servicios", value: money(earnedAmount), helper: "Comisión + kits" },
      { label: "Disponible por retirar", value: money(pendingAmount), helper: "Comisión + kits menos retiros", tone: pendingAmount > 0 ? "danger" : "default" },
      { label: "Retirado", value: money(withdrawnAmount), helper: `${withdrawalRows.length} retiros registrados` },
    ];
  }

  if (actions === "withdrawals") {
    const pendingProvider = rows.filter((row) => asString(row.source) === "provider_pending");
    const paidProvider = rows.filter((row) => asString(row.source) === "provider_payout" && ["paid", "approved", "collected"].includes(normalizedStatus(row)));
    const requests = rows.filter((row) => asString(row.source).includes("request"));
    const pendingAmount = sumRows(pendingProvider, "amount");
    const providerPaid = sumRows(paidProvider, "amount");

    return [
      { label: "Por pagar a profesionales", value: money(pendingAmount), helper: `${pendingProvider.length} servicios completados`, tone: pendingAmount > 0 ? "danger" : "default" },
      { label: "Pagado a profesionales", value: money(providerPaid), helper: `${paidProvider.length} liquidaciones registradas` },
      { label: "Solicitudes manuales", value: requests.length, helper: "Solicitudes de retiro visibles" },
      { label: "Movimientos visibles", value: rows.length, helper: "Pendientes, solicitudes y pagos" },
    ];
  }

  if (actions === "notifications" || rpc === "yt_admin_notifications_json") {
    const archived = rows.filter(isArchived).length;
    const activeRows = rows.filter((row) => !isArchived(row) && !isDeleted(row));
    const businessRows = activeRows.filter(isBusinessNotification);
    const unread = businessRows.filter((row) => !isNotificationRead(row)).length;
    const read = businessRows.length - unread;
    const pushPending = activeRows.filter((row) => asString(row.source) === "push_notification_logs" && ["pending", "queued"].includes(asString(row.push_status))).length;

    return [
      { label: "Sin leer", value: unread, helper: "Avisos pendientes", tone: unread > 0 ? "danger" : "default" },
      { label: "Leídas", value: read, helper: "Ya revisadas" },
      { label: "Entregas en proceso", value: pushPending, helper: "Pendientes o en cola de entrega", tone: pushPending > 0 ? "danger" : "default" },
      { label: "Archivadas visibles", value: archived, helper: "Fuera de operación diaria" },
    ];
  }

  if (rpc === "yt_admin_payments_json" || rpc === "yt_admin_wissa_finance_json" || rpc === "yt_admin_wissa_finance_v66_json" || actions === "payments") {
    const approvedRows = rows.filter((row) => ["approved", "paid"].includes(normalizedStatus(row)));
    const totalAmount = sumRows(approvedRows, "amount") || sumRows(approvedRows, "amount_total");
    const commission = sumRows(approvedRows, "platform_fee");
    const kits = sumRows(approvedRows, "kit_amount");
    const wissaMarketplace = sumRows(approvedRows, "wissa_total_revenue") || (commission + kits);
    const approved = approvedRows.length;

    return [
      { label: "Monto procesado", value: money(totalAmount), helper: `${approved} pagos aprobados` },
      { label: "Comisión Wissa 20%", value: money(commission), helper: "Solo servicio profesional" },
      { label: "Kits y materiales", value: money(kits), helper: "100% ingreso Wissa" },
      { label: "Ingresos Wissa por servicios", value: money(wissaMarketplace), helper: "Comisión + kits" },
      { label: "Pagos aprobados", value: approved, helper: "Movimientos incluidos" },
    ];
  }

  if (rpc === "yt_admin_reports_json") {
    const byMetric = (needle: string) => rows.find((row) => asString(row.metric).toLowerCase().includes(needle));
    const paidOrders = byMetric("orden");
    const commission = byMetric("comision plataforma ganada") || byMetric("comisión plataforma ganada") || byMetric("comision wissa ganada") || byMetric("comisión wissa ganada") || byMetric("comision yourtime ganada") || byMetric("comisión yourtime ganada");
    const pendingCommission = byMetric("retiro de comision pendiente") || byMetric("retiro de comisión pendiente");
    const providerNet = byMetric("neto proveedor");

    return [
      { label: "Ingresos aprobados", value: money(paidOrders?.amount), helper: text(paidOrders?.value, "0") + " órdenes" },
      { label: "Comisión ganada", value: money(commission?.amount), helper: "Plataforma 20%" },
      { label: "Por retirar", value: money(pendingCommission?.amount), helper: "Saldo plataforma", tone: asNumber(pendingCommission?.amount) > 0 ? "danger" : "default" },
      { label: "Pago profesional", value: money(providerNet?.amount), helper: "A pagar/liquidado" },
    ];
  }

  if (rpc === "yt_admin_services_json") {
    const active = rows.filter((row) => normalizedStatus(row) === "active" || row.is_active === true).length;
    const bookings = rows.reduce((total, row) => total + asNumber(row.bookings_count), 0);

    return [
      { label: "Servicios creados", value: rows.length, helper: "Según filtros aplicados" },
      { label: "Servicios activos", value: active, helper: "Visibles en la app" },
      { label: "Traslado por mapa", value: "Configurable por km", helper: "Origen: ubicación configurada del servicio/Ofrecer; perfil como respaldo" },
      { label: "Reservas generadas", value: bookings, helper: "Desde estos servicios" },
    ];
  }

  const pending = rows.filter((r) => ["pending", "not_released", "completed_pending_release"].includes(String(r.status || r.release_status || r.payout_release_status || r.push_status || ""))).length;
  const approved = rows.filter((r) => ["approved", "paid", "released", "active", "sent", "earned", "collected"].includes(String(r.status || r.payment_status || r.payout_release_status || r.push_status || ""))).length;
  const rejected = rows.filter((r) => ["rejected", "failed", "cancelled", "suspended", "skipped"].includes(String(r.status || r.push_status || ""))).length;

  return [
    { label: "Total visible", value: rows.length },
    { label: "Pendientes", value: pending },
    { label: "Aprobados/activos", value: approved },
    { label: "Alertas", value: rejected, tone: rejected > 0 ? "danger" : "default" },
  ];
}

function buildQuickStatusOptions(options: string[], actions: Props["actions"]) {
  const preferred = actions === "platform_commissions"
    ? ["all", "platform_commission_pending", "platform_commission_earned", "platform_commission_withdrawal"]
    : actions === "notifications"
      ? ["all", "unread", "read", "pending", "sent", "failed", "archived", "deleted"]
    : actions === "company_liquidations"
      ? ["all", "paid", "completed", "not_released", "released", "failed", "cancelled"]
    : actions === "refunds"
      ? ["all", "refund_pending", "refund_processing", "refunded", "refund_rejected"]
    : actions === "withdrawals"
      ? ["all", "provider_pending", "pending", "paid", "provider_payout", "payout_request", "withdrawal_request"]
    : actions === "payments"
      ? ["all", "approved", "released", "not_released"]
        : options.includes("missing_location")
          ? ["all", "active", "inactive", "ready", "missing_location"]
          : options.includes("active") && options.includes("inactive")
            ? ["all", "active", "inactive"]
            : ["all", "pending", "approved", "paid", "released", "rejected", "cancelled"];

  return preferred.filter((item) => options.includes(item)).slice(0, actions === "notifications" ? 8 : 7);
}

function Stat({ label, value, helper, danger }: { label: string; value: ReactNode; helper?: string; danger?: boolean }) {
  return (
    <div className="stat ui2-stat-card">
      <span>{label}</span>
      <strong style={danger ? { color: "var(--red)" } : {}}>{value}</strong>
      {helper ? <small>{helper}</small> : null}
    </div>
  );
}

function render(column: Column, row: Row, actions?: Props["actions"]) {
  const value = row[column.key];
  const avatarUrl = asString(row.avatar_url);
  if (column.type === "user") return <div className="user-cell"><div className="avatar">{avatarUrl ? <span aria-label="avatar" role="img" style={{ display: "block", width: "100%", height: "100%", backgroundImage: `url(${JSON.stringify(avatarUrl)})`, backgroundPosition: "center", backgroundSize: "cover" }} /> : <UserRound size={18} />}</div><div><div className="primary">{text(row.full_name || row.name || row.email)}</div><div className="secondary">{text(row.email, "Sin correo")}</div></div></div>;
  if (column.type === "money") return <strong>{value == null ? "Sin desglose" : money(value)}</strong>;
  if (column.type === "date") return <span>{formatPanamaDate(value)}</span>;
  if (column.type === "datetime") return <span>{datetime(value)}</span>;
  if (column.type === "time") return <span>{formatPanamaTime(value)}</span>;
  if (column.type === "status") return <Status value={statusValueForCell(column, row, actions)} />;
  if (column.type === "plan") return <span className="badge cyan"><ShieldCheck size={13} />{text(value || row.plan_name || row.subscription_plan, "Sin plan")}</span>;
  if (typeof value === "boolean") return <Status value={value ? "read" : "unread"} />;
  if (["pricing_breakdown", "pricing_summary", "message", "description", "notes"].includes(column.key)) {
    return <span className="admin-cell-long" title={text(value, "")}>{text(value)}</span>;
  }
  return <span>{text(value)}</span>;
}

function normalizeModuleRows(rows: Row[], actions: Props["actions"], rpc: string) {
  if (actions === "notifications" || rpc === "yt_admin_notifications_json") {
    return normalizeAdminNotificationRows(rows);
  }
  if (rpc !== "yt_admin_payments_json" && actions !== "payments") return rows;
  return rows.filter((row) => {
    const status = normalizedStatus(row);
    const label = asString(row.status_label).toLowerCase();
    return status === "approved" || status === "paid" || label.includes("aprobado") || label.includes("pagado");
  });
}

function statusValueForCell(column: Column, row: Row, actions?: Props["actions"]) {
  const value = row[column.key] || row.status_label || row.payment_status_label || row.status || row.payment_status || "pending";
  if (actions === "platform_commissions" && column.key === "source") {
    const source = asString(value);
    if (source === "platform_commission_pending") return "pending";
    if (source === "platform_commission_withdrawal") return "collected";
    if (source === "platform_commission_earned") return "earned";
  }
  return String(value);
}

function Status({ value }: { value: string }) {
  const n = value.toLowerCase();
  let cls = "badge";
  if (["refunded", "reembolsado", "devuelta"].some((k) => n.includes(k))) cls += " green";
  else if (["refund_rejected"].some((k) => n.includes(k))) cls += " red";
  else if (["refund_pending", "refund_processing"].some((k) => n.includes(k))) cls += " yellow";
  else if (["approved", "paid", "released", "active", "ready", "liquidado", "pagado", "sent", "enviada", "earned", "ganada", "collected", "retirada", "read", "leida"].some((k) => n.includes(k))) cls += " green";
  else if (["rejected", "failed", "cancelled", "suspended", "deleted", "eliminada", "fallido", "rechazado", "cancelado"].some((k) => n.includes(k))) cls += " red";
  else if (["pending", "missing_location", "falta ubicacion", "falta ubicación", "por liberar", "pendiente", "processing", "unread"].some((k) => n.includes(k))) cls += " yellow";
  else cls += " cyan";
  return <span className={cls}>{statusLabel(value)}</span>;
}

function DetailModal({ title, row, columns, onClose }: { title: string; row: Row; columns: Column[]; onClose: () => void }) {
  const base = [
    ...columns.map((c) => c.key),
    "status_label",
    "payment_status_label",
    "payout_release_status",
    "finance_status",
    "refund_status",
    "refund_reason",
    "refund_note",
    "refund_method",
    "refund_reference",
    "service_title",
    "buyer_name",
    "provider_name",
    "amount",
    "platform_fee",
    "provider_net",
    "booking_date",
    "booking_time",
    "created_at",
    "paid_at",
    "completed_at",
    "payout_released_at",
    "provider_paid_out_at",
    "released_at",
    "admin_release_note",
    "location",
    "notes",
    "push_status",
    "error_message",
    "source",
  ];
  const keys = Array.from(new Set(base.concat(Object.keys(row))))
    .filter((k) => shouldShowDetailKey(k, row))
    .slice(0, 42);
  const summary = detailSummary(row, title);

  return (
    <div className="modal-backdrop">
      <div className="modal">
        <div className="modal-head">
          <div>
            <strong>Detalle de {title}</strong>
            <p style={{ margin: "4px 0 0", color: "var(--muted)", fontSize: 13 }}>Información organizada del registro seleccionado.</p>
          </div>
          <button className="btn btn-soft btn-small" onClick={onClose}>Cerrar</button>
        </div>
        <div className="modal-body">
          <div className="detail-summary">
            <div className="detail-summary-main">
              <span>{summary.eyebrow}</span>
              <strong>{summary.title}</strong>
              <p>{summary.subtitle}</p>
            </div>
            <div className="detail-summary-side">
              {summary.status ? <Status value={summary.status} /> : null}
              {summary.amount ? <strong>{summary.amount}</strong> : null}
            </div>
          </div>

          <div className="detail-sections">
            {detailSections(keys, row).map((section) => (
              <section className="detail-section" key={section.title}>
                <div className="detail-section-head">
                  <strong>{section.title}</strong>
                  <span>{section.description}</span>
                </div>
                <div className="detail-grid">
                  {section.keys.map((k) => (
                    <div key={k} className="detail-tile">
                      <div>{labels[k] || human(k)}</div>
                      <strong>{formatValue(k, row[k])}</strong>
                    </div>
                  ))}
                </div>
              </section>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}


function detailSections(keys: string[], row: Row) {
  const groups = [
    { title: "Reserva", description: "Servicio, fecha, ubicación y estado.", match: (key: string) => ["service_title","category","service_category","booking_date","booking_time","location","status_label","payment_status_label","pricing_summary","duration_minutes"].includes(key) },
    { title: "Cliente y profesionales", description: "Personas y equipo relacionados con el servicio.", match: (key: string) => key.includes("buyer") || key.includes("provider") || key.includes("professional") || key.includes("team") || key.includes("assignment") },
    { title: "Finanzas", description: "Cobros, comisiones, materiales y liquidaciones.", match: (key: string) => /(amount|fee|price|net|commission|payout|tip|kit|material|subtotal|total|refund|payment)/.test(key) },
    { title: "Seguimiento", description: "Fechas y notas relevantes de la operación.", match: (key: string) => /(_at$|notes|note|reason|reference|push_status|source)/.test(key) },
  ];
  const used = new Set<string>();
  const sections = groups.map((group) => {
    const sectionKeys = keys.filter((key) => !used.has(key) && group.match(key));
    sectionKeys.forEach((key) => used.add(key));
    return { title: group.title, description: group.description, keys: sectionKeys };
  }).filter((section) => section.keys.length > 0);
  const other = keys.filter((key) => !used.has(key) && row[key] !== undefined);
  if (other.length) sections.push({ title: "Información adicional", description: "Otros datos útiles del registro.", keys: other });
  return sections;
}

function detailSummary(row: Row, moduleTitle: string) {
  const title = text(row.service_title || row.title || row.metric || row.full_name || row.name || row.party_name || row.buyer_name || moduleTitle);
  const subtitle = [
    row.buyer_name ? `Cliente: ${text(row.buyer_name)}` : "",
    row.provider_name ? `Profesional: ${text(row.provider_name)}` : "",
    row.party_name ? `Cuenta: ${text(row.party_name)}` : "",
    row.created_at ? `Creado: ${datetime(row.created_at)}` : "",
  ].filter(Boolean).join(" · ");

  return {
    eyebrow: moduleTitle,
    title,
    subtitle: subtitle || "Registro administrativo Wissa",
    status: text(row.status_label || row.payment_status_label || row.status || row.payment_status || row.read_status || row.push_status, ""),
    amount: row.amount !== undefined || row.amount_total !== undefined || row.platform_fee !== undefined
      ? money(row.amount ?? row.amount_total ?? row.platform_fee)
      : "",
  };
}

function shouldShowDetailKey(key: string, row: Row) {
  const value = row[key];
  if (!(key in row) || hiddenDetailFields.has(key) || isInternalDetail(key)) return false;
  if (/_id$/.test(key)) return false;
  if (value === null || value === undefined) return false;
  const raw = typeof value === "object" ? JSON.stringify(value) : String(value);
  return raw.trim() !== "" && raw !== "{}" && raw !== "[]";
}

function isNotificationRead(row: Row) {
  const raw = asString(row.is_read).toLowerCase();
  return row.is_read === true || raw === "true" || asString(row.read_status).toLowerCase() === "read" || Boolean(row.admin_read_at);
}

function isArchived(row: Row) {
  const raw = asString(row.is_archived).toLowerCase();
  return row.is_archived === true || raw === "true" || Boolean(row.admin_archived_at);
}

function isDeleted(row: Row) {
  const raw = asString(row.is_deleted).toLowerCase();
  return row.is_deleted === true || raw === "true" || Boolean(row.admin_deleted_at);
}

function normalizedStatus(row: Row) {
  return asString(row.status || row.payment_status || row.payout_release_status || row.release_status || row.push_status).toLowerCase();
}

function sumRows(rows: Row[], key: string) {
  return rows.reduce((total, row) => total + asNumber(row[key]), 0);
}

function formatValue(key: string, value: unknown): string {
  if (typeof value === "boolean") return value ? "Si" : "No";
  if (key === "source" || key === "read_status") return statusLabel(value);
  if (key.includes("amount") || key.includes("fee") || key.includes("price") || key.includes("net")) return money(value);
  if (key.includes("_at") || key.includes("created") || key.includes("paid") || key.includes("released")) return datetime(value);
  if (key.includes("date")) return formatPanamaDate(value);
  if (key.includes("time")) return formatPanamaTime(value);
  if (key.includes("status")) return statusLabel(value);
  if (typeof value === "object" && value !== null) return formatObjectValue(value);
  return text(value);
}

function formatObjectValue(value: object): string {
  if (Array.isArray(value)) {
    if (value.length === 0) return "Sin datos";
    return value.slice(0, 4).map((item) => typeof item === "object" && item !== null ? formatObjectValue(item) : text(item)).join(" · ");
  }

  const parts = Object.entries(value)
    .filter(([, item]) => item !== null && item !== undefined && typeof item !== "object" && String(item).trim() !== "")
    .slice(0, 8)
    .map(([key, item]) => `${human(key)}: ${text(item)}`);

  return parts.length ? parts.join(" · ") : "Dato estructurado";
}

function human(key: string) {
  return key.replaceAll("_", " ").replace(/\b\w/g, (l) => l.toUpperCase());
}

function asString(value: unknown): string {
  if (value === null || value === undefined) return "";
  return typeof value === "string" ? value : String(value);
}

function asNumber(value: unknown): number {
  const raw = typeof value === "number" ? value : Number(String(value ?? "0").replace(/[^0-9.-]/g, ""));
  return Number.isFinite(raw) ? raw : 0;
}

function rowId(row: Row): string {
  return asString(row.id || row.booking_id || row.payment_order_id || row.company_id || row.profile_id);
}

function exportValue(column: Column, row: Row): string {
  const value = row[column.key];
  if (column.type === "money") return value == null ? "Sin desglose" : money(value);
  if (column.type === "date") return formatPanamaDate(value);
  if (column.type === "datetime") return datetime(value);
  if (column.type === "time") return formatPanamaTime(value);
  if (column.type === "status") return statusLabel(value || row.status_label || row.payment_status_label || row.status || row.payment_status);
  if (column.type === "plan") return text(value || row.plan_name || row.subscription_plan, "Sin plan");
  if (typeof value === "boolean") return value ? "Si" : "No";
  if (typeof value === "object" && value !== null) return formatObjectValue(value);
  return text(value);
}

function buildExcelHtml(title: string, columns: Column[], rows: Row[]) {
  const header = columns.map((column) => `<th>${escapeHtml(column.label)}</th>`).join("");
  const body = rows.map((row) => `<tr>${columns.map((column) => `<td>${escapeHtml(exportValue(column, row))}</td>`).join("")}</tr>`).join("");

  return `<!doctype html><html><head><meta charset="utf-8" /></head><body><table><caption>${escapeHtml(title)}</caption><thead><tr>${header}</tr></thead><tbody>${body}</tbody></table></body></html>`;
}

function buildPrintHtml(title: string, columns: Column[], rows: Row[], filters: { search: string; status: string; dateFrom: string; dateTo: string }) {
  const filterLine = [
    filters.search ? `Búsqueda: ${filters.search}` : "",
    filters.status !== "all" ? `Estado: ${statusLabel(filters.status)}` : "",
    filters.dateFrom ? `Desde: ${filters.dateFrom}` : "",
    filters.dateTo ? `Hasta: ${filters.dateTo}` : "",
  ].filter(Boolean).join(" | ");

  const header = columns.map((column) => `<th>${escapeHtml(column.label)}</th>`).join("");
  const body = rows.map((row) => `<tr>${columns.map((column) => `<td>${escapeHtml(exportValue(column, row))}</td>`).join("")}</tr>`).join("");

  return `<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8" />
  <title>${escapeHtml(title)} - Wissa</title>
  <style>
    @page{size:landscape;margin:12mm}
    *{box-sizing:border-box}
    body{font-family:Inter,Arial,sans-serif;color:#0f172a;margin:0;background:#f8fbff}
    .sheet{padding:22px}
    .header{display:flex;align-items:flex-start;justify-content:space-between;gap:18px;margin-bottom:18px;padding:18px 20px;border:1px solid #cbdced;border-radius:18px;background:white}
    .brand{font-size:13px;font-weight:900;letter-spacing:.16em;text-transform:uppercase;color:#0f6edb}
    h1{margin:5px 0 6px;font-size:28px;line-height:1.1}
    p{margin:0;color:#526277}
    .stamp{text-align:right;color:#526277;font-size:12px;line-height:1.45}
    .meta{margin-bottom:14px;padding:12px 14px;border:1px solid #cbdced;border-radius:14px;background:#eff6ff;color:#334155;font-size:12px;font-weight:700}
    table{width:100%;border-collapse:separate;border-spacing:0;font-size:11px;background:white;border:1px solid #cbdced;border-radius:16px;overflow:hidden}
    thead{display:table-header-group}
    th{background:#0f172a;color:white;text-align:left;padding:10px 9px;border-bottom:1px solid #cbd5e1;text-transform:uppercase;letter-spacing:.07em;font-size:10px}
    td{padding:9px;border-bottom:1px solid #e2e8f0;vertical-align:top;line-height:1.32}
    tr:nth-child(even) td{background:#f8fafc}
    tr:last-child td{border-bottom:0}
    .empty{padding:24px;text-align:center;color:#64748b}
    @media print{body{background:white}.sheet{padding:0}.header,.meta,table{break-inside:avoid}}
  </style>
</head>
<body>
  <main class="sheet">
    <section class="header">
      <div>
        <div class="brand">Wissa Admin Web</div>
        <h1>${escapeHtml(title)}</h1>
        <p>${rows.length} registros visibles</p>
      </div>
      <div class="stamp">Generado en Panamá<br />${escapeHtml(datetime(new Date().toISOString()))}</div>
    </section>
    <div class="meta">${escapeHtml(filterLine || "Sin filtros adicionales")}</div>
    <table><thead><tr>${header}</tr></thead><tbody>${body || `<tr><td class="empty" colspan="${columns.length}">No hay datos para mostrar.</td></tr>`}</tbody></table>
  </main>
</body>
</html>`;
}

function downloadTextFile(filename: string, content: string, type: string) {
  const blob = new Blob([content], { type });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

function fileSafe(value: string) {
  return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9]+/gi, "-").replace(/^-+|-+$/g, "").toLowerCase() || "wissa";
}

function todayStamp() {
  const now = new Date();
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, "0");
  const d = String(now.getDate()).padStart(2, "0");
  return `${y}${m}${d}`;
}

function escapeHtml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}
