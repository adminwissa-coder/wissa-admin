"use client";

import { adminMessage, isInternalDetail } from "@/lib/admin-copy";

import { useCallback, useEffect, useMemo, useState } from "react";
import { CheckCircle2, Eye, RefreshCcw, Search, ShieldCheck, XCircle } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { dateFmt, dateTime, money, statusLabel, text } from "@/lib/utils";

type Row = Record<string, unknown>;

type Column = { key: string; label: string; type?: "text" | "date" | "money" | "status" | "percent" };

type Props = {
  entity: string;
  title: string;
  eyebrow: string;
  description: string;
  columns: Column[];
  searchPlaceholder?: string;
  primaryAction?: "suspend_user" | "unsuspend_user" | "approve_payment" | "reject_payment" | "approve_plan" | "reject_plan" | "none";
};

const statusOptions = [
  { value: "all", label: "Todos los estados" },
  { value: "pending", label: "Pendientes" },
  { value: "approved", label: "Aprobados" },
  { value: "rejected", label: "Rechazados" },
  { value: "cancelled", label: "Cancelados" },
  { value: "suspended", label: "Suspendidos" },
  { value: "active", label: "Activos" },
];

const hiddenDetailKeys = new Set([
  "id",
  "user_id",
  "buyer_id",
  "provider_id",
  "company_id",
  "booking_id",
  "payment_order_id",
  "metadata",
  "raw_response",
  "pf_response",
  "yappy_response",
  "yappy_ipn_payload",
  "checkout_url",
  "public_checkout_token",
  "push_token",
]);

const detailLabels: Record<string, string> = {
  full_name: "Nombre",
  name: "Nombre",
  email: "Correo",
  phone: "Teléfono",
  role: "Rol",
  status: "Estado",
  payment_status: "Pago",
  plan_status: "Plan",
  amount: "Monto",
  total: "Total",
  price: "Precio",
  platform_amount: "Comisión plataforma",
  created_at: "Creado",
  updated_at: "Actualizado",
  paid_at: "Pagado",
  service_title: "Servicio",
  provider_name: "Profesional",
  buyer_name: "Cliente",
  company_name: "Empresa",
};

export default function AdminDataPage({ entity, title, eyebrow, description, columns, searchPlaceholder, primaryAction = "none" }: Props) {
  const [rows, setRows] = useState<Row[]>([]);
  const [loading, setLoading] = useState(true);
  const [searchDraft, setSearchDraft] = useState("");
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("all");
  const [error, setError] = useState("");
  const [selected, setSelected] = useState<Row | null>(null);
  const [actionLoading, setActionLoading] = useState(false);

  const totals = useMemo(() => {
    const approved = rows.filter((r) => String(r.status || r.payment_status || "").toLowerCase() === "approved" || String(r.payment_status || "").toLowerCase() === "paid").length;
    const pending = rows.filter((r) => String(r.status || r.payment_status || "").toLowerCase() === "pending").length;
    const amount = rows.reduce((sum, r) => sum + Number(r.amount || r.total || r.price || r.platform_amount || 0), 0);
    const commission = amount * 0.20;
    return { total: rows.length, approved, pending, amount, commission };
  }, [rows]);

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    const { data, error } = await supabase.rpc("yt_admin_table_json", {
      p_entity: entity,
      p_search: search.trim(),
      p_status: status,
      p_limit: 200,
    });
    if (error) {
      setRows([]);
      setError(error.message);
    } else {
      setRows(Array.isArray(data) ? (data as Row[]) : []);
    }
    setLoading(false);
  }, [entity, search, status]);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      void load();
    }, 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  async function runAction(action: string, row: Row) {
    const id = String(row.id || row.profile_id || row.company_id || "");
    if (!id) return;
    const ok = window.confirm("¿Confirmas esta acción administrativa?");
    if (!ok) return;
    setActionLoading(true);
    setError("");
    const { error } = await supabase.rpc("yt_admin_action", { p_action: action, p_id: id, p_note: "Acción desde admin web" });
    if (error) setError(error.message);
    await load();
    setActionLoading(false);
  }

  return (
    <div className="space-y-6">
      <section className="yt-card rounded-3xl p-6 sm:p-8">
        <div className="flex flex-col xl:flex-row xl:items-center xl:justify-between gap-5">
          <div><p className="text-sm uppercase tracking-[0.25em] text-cyan-300 font-black">{eyebrow}</p><h1 className="mt-2 text-3xl sm:text-4xl font-black">{title}</h1><p className="mt-2 max-w-3xl text-slate-300">{description}</p></div>
          <button onClick={() => void load()} className="rounded-2xl bg-cyan-400 px-5 py-3 text-sm font-black text-[#050816] hover:bg-cyan-300 flex items-center justify-center gap-2"><RefreshCcw className="h-4 w-4" /> Actualizar</button>
        </div>
      </section>

      <section className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-5 gap-4">
        <Metric label="Total" value={totals.total.toLocaleString("es-PA")} />
        <Metric label="Aprobados / Pagados" value={totals.approved.toLocaleString("es-PA")} />
        <Metric label="Pendientes" value={totals.pending.toLocaleString("es-PA")} />
        <Metric label="Monto visible" value={money(totals.amount)} />
        <Metric label="Comisión plataforma 20%" value={money(totals.commission)} accent />
      </section>

      <section className="yt-card rounded-3xl p-5">
        <form onSubmit={(e) => { e.preventDefault(); setSearch(searchDraft.trim()); }} className="grid grid-cols-1 lg:grid-cols-[1fr_240px_auto] gap-3">
          <div className="relative"><Search className="absolute left-4 top-1/2 -translate-y-1/2 h-5 w-5 text-slate-500" /><input value={searchDraft} onChange={(e) => setSearchDraft(e.target.value)} placeholder={searchPlaceholder || "Buscar..."} className="w-full rounded-2xl border border-white/10 bg-[#050816] px-12 py-3 text-sm text-white outline-none placeholder:text-slate-500 focus:border-cyan-300" /></div>
          <select value={status} onChange={(e) => setStatus(e.target.value)} className="rounded-2xl border border-white/10 bg-[#050816] px-4 py-3 text-sm text-white outline-none focus:border-cyan-300">{statusOptions.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}</select>
          <button className="rounded-2xl bg-white px-6 py-3 text-sm font-black text-[#050816] hover:bg-slate-200">Buscar</button>
        </form>
      </section>

      {error && <div className="rounded-2xl border border-red-400/30 bg-red-500/10 px-5 py-4 text-sm text-red-200">{adminMessage(error)}</div>}

      <section className="yt-card rounded-3xl overflow-hidden">
        <div className="overflow-x-auto yt-scrollbar">
          <table className="min-w-full text-left">
            <thead className="bg-white/[0.05] border-b border-white/10"><tr>{columns.map((c) => <th key={c.key} className="px-5 py-4 text-xs font-black uppercase tracking-wider text-slate-400">{c.label}</th>)}<th className="px-5 py-4 text-xs font-black uppercase tracking-wider text-slate-400">Acciones</th></tr></thead>
            <tbody>
              {loading ? <tr><td colSpan={columns.length + 1} className="px-5 py-12 text-center text-slate-400">Cargando datos...</td></tr> : rows.length === 0 ? <tr><td colSpan={columns.length + 1} className="px-5 py-12 text-center text-slate-400">No hay registros para mostrar.</td></tr> : rows.map((row, idx) => (
                <tr key={String(row.id || idx)} className="border-b border-white/10 hover:bg-white/[0.035]">
                  {columns.map((c) => <td key={c.key} className="px-5 py-4 align-top text-sm text-slate-200">{renderCell(row[c.key], c.type)}</td>)}
                  <td className="px-5 py-4 align-top"><div className="flex flex-wrap gap-2"><button onClick={() => setSelected(row)} className="rounded-xl border border-cyan-300/30 bg-cyan-400/10 px-3 py-2 text-xs font-bold text-cyan-200 hover:bg-cyan-400/20 flex items-center gap-1"><Eye className="h-3 w-3" /> Ver</button>{actionButtons(primaryAction, row, runAction, actionLoading)}</div></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {selected && <DetailModal row={selected} onClose={() => setSelected(null)} />}
    </div>
  );
}

function Metric({ label, value, accent }: { label: string; value: string; accent?: boolean }) {
  return <div className="yt-card rounded-3xl p-5"><p className="text-sm text-slate-400">{label}</p><p className={accent ? "mt-2 text-2xl font-black text-cyan-300" : "mt-2 text-2xl font-black text-white"}>{value}</p></div>;
}

function renderCell(value: unknown, type?: Column["type"]) {
  if (type === "date") return dateFmt(value);
  if (type === "money") return money(value);
  if (type === "percent") return `${Number(value || 0).toFixed(2)}%`;
  if (type === "status") return <StatusBadge value={value} />;
  return text(value);
}

function StatusBadge({ value }: { value: unknown }) {
  const v = String(value || "pending").toLowerCase();
  const good = ["approved", "paid", "active", "completed", "released"].includes(v);
  const bad = ["rejected", "cancelled", "failed", "suspended"].includes(v);
  return <span className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs font-black ${good ? "border-emerald-400/30 bg-emerald-500/10 text-emerald-200" : bad ? "border-red-400/30 bg-red-500/10 text-red-200" : "border-yellow-400/30 bg-yellow-500/10 text-yellow-200"}`}>{good ? <CheckCircle2 className="h-3 w-3" /> : bad ? <XCircle className="h-3 w-3" /> : <ShieldCheck className="h-3 w-3" />}{v}</span>;
}

function actionButtons(primaryAction: Props["primaryAction"], row: Row, runAction: (action: string, row: Row) => void, disabled: boolean) {
  const status = String(row.status || row.payment_status || "").toLowerCase();
  if (primaryAction === "suspend_user") {
    const suspended = row.is_suspended === true || status === "suspended";
    return <button disabled={disabled} onClick={() => runAction(suspended ? "unsuspend_user" : "suspend_user", row)} className={suspended ? "rounded-xl border border-emerald-400/30 bg-emerald-500/10 px-3 py-2 text-xs font-bold text-emerald-200" : "rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs font-bold text-red-200"}>{suspended ? "Quitar suspensión" : "Suspender"}</button>;
  }
  if (primaryAction === "approve_payment" && status === "pending") return <><button disabled={disabled} onClick={() => runAction("approve_payment", row)} className="rounded-xl border border-emerald-400/30 bg-emerald-500/10 px-3 py-2 text-xs font-bold text-emerald-200">Aprobar</button><button disabled={disabled} onClick={() => runAction("reject_payment", row)} className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs font-bold text-red-200">Rechazar</button></>;
  if (primaryAction === "approve_plan" && status === "pending") return <><button disabled={disabled} onClick={() => runAction("approve_plan", row)} className="rounded-xl border border-emerald-400/30 bg-emerald-500/10 px-3 py-2 text-xs font-bold text-emerald-200">Activar plan</button><button disabled={disabled} onClick={() => runAction("reject_plan", row)} className="rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs font-bold text-red-200">Rechazar</button></>;
  return null;
}

function DetailModal({ row, onClose }: { row: Row; onClose: () => void }) {
  const entries = Object.entries(row).filter(([key, value]) => shouldShowDetail(key, value)).slice(0, 36);
  const title = text(row.service_title || row.full_name || row.name || row.company_name || row.email || "Registro");
  const status = text(row.status || row.payment_status || row.plan_status, "");

  return (
    <div className="fixed inset-0 z-50 bg-black/70 p-4 flex items-center justify-center">
      <div className="yt-card w-full max-w-3xl max-h-[85vh] overflow-auto yt-scrollbar rounded-3xl p-6">
        <div className="flex items-start justify-between gap-4 mb-4">
          <div>
            <p className="text-xs uppercase tracking-[0.22em] text-cyan-300 font-black">Detalle administrativo</p>
            <h3 className="mt-1 text-2xl font-black">{title}</h3>
            {status ? <p className="mt-1 text-sm text-slate-400">{statusLabel(status)}</p> : null}
          </div>
          <button onClick={onClose} className="rounded-xl bg-white text-[#050816] px-4 py-2 text-sm font-black">Cerrar</button>
        </div>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
          {entries.map(([key, value]) => (
            <div key={key} className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
              <p className="text-xs uppercase tracking-wider text-slate-500 font-black">{detailLabels[key] || human(key)}</p>
              <p className="mt-1 text-sm text-slate-200 break-words">{formatDetailValue(key, value)}</p>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function shouldShowDetail(key: string, value: unknown) {
  if ((hiddenDetailKeys.has(key) || isInternalDetail(key)) || /_id$/.test(key)) return false;
  if (value === null || value === undefined || value === "") return false;
  if (typeof value === "object") {
    const raw = JSON.stringify(value);
    return raw !== "{}" && raw !== "[]";
  }
  return true;
}

function formatDetailValue(key: string, value: unknown) {
  if (typeof value === "boolean") return value ? "Sí" : "No";
  if (key.includes("amount") || key.includes("price") || key === "total" || key === "platform_amount") return money(value);
  if (key.includes("_at") || key.includes("created") || key.includes("updated") || key.includes("paid")) return dateTime(value);
  if (key.includes("status") || key === "role") return statusLabel(value);
  if (typeof value === "object" && value !== null) return formatObjectValue(value);
  return text(value);
}

function formatObjectValue(value: object): string {
  if (Array.isArray(value)) {
    if (value.length === 0) return "Sin datos";
    return value
      .slice(0, 4)
      .map((item) => (typeof item === "object" && item !== null ? formatObjectValue(item) : text(item)))
      .join(" · ");
  }

  const parts = Object.entries(value)
    .filter(([, item]) => item !== null && item !== undefined && typeof item !== "object" && String(item).trim() !== "")
    .slice(0, 6)
    .map(([key, item]) => `${human(key)}: ${text(item)}`);

  return parts.length ? parts.join(" · ") : "Dato estructurado";
}

function human(key: string) {
  return key.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}
