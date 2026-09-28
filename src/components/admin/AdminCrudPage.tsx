"use client";

import { adminMessage } from "@/lib/admin-copy";

import { FormEvent, ReactNode, useCallback, useEffect, useMemo, useState } from "react";
import { RefreshCcw, Search } from "lucide-react";
import { listAdminData, runAdminAction, type AdminJsonRow } from "@/lib/adminApi";
import { dateOnly, dateTime, money, statusLabel, text } from "@/lib/utils";

export type ColumnDef = {
  key: string;
  label: string;
  type?: "text" | "money" | "date" | "datetime" | "status" | "bool";
};

type ActionDef = {
  label: string;
  action: string;
  visible?: (row: AdminJsonRow) => boolean;
  danger?: boolean;
  prompt?: string;
};

type Props = {
  moduleName: string;
  title: string;
  eyebrow?: string;
  description: string;
  columns: ColumnDef[];
  actions?: ActionDef[];
  extraFilters?: ReactNode;
  defaultFilters?: Record<string, unknown>;
};

export default function AdminCrudPage({ moduleName, title, eyebrow = "Gestión Wissa", description, columns, actions = [], extraFilters, defaultFilters }: Props) {
  const [rows, setRows] = useState<AdminJsonRow[]>([]);
  const [searchDraft, setSearchDraft] = useState("");
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [errorMessage, setErrorMessage] = useState("");
  const [actionLoadingId, setActionLoadingId] = useState<string | null>(null);

  const total = rows.length;
  const approved = useMemo(() => rows.filter((r) => ["approved", "paid", "active", "completed", "released"].includes(String(r.status ?? r.payment_status ?? r.plan_status ?? "").toLowerCase())).length, [rows]);
  const pending = useMemo(() => rows.filter((r) => ["pending", "processing", "requested"].includes(String(r.status ?? r.payment_status ?? r.plan_status ?? "").toLowerCase())).length, [rows]);
  const failed = useMemo(() => rows.filter((r) => ["rejected", "cancelled", "failed", "suspended"].includes(String(r.status ?? r.payment_status ?? r.plan_status ?? "").toLowerCase())).length, [rows]);

  const loadRows = useCallback(async () => {
    setLoading(true);
    setErrorMessage("");
    try {
      const data = await listAdminData(moduleName, { ...(defaultFilters ?? {}), search: search.trim() });
      setRows(Array.isArray(data) ? data : []);
    } catch (error) {
      setRows([]);
      setErrorMessage(error instanceof Error ? error.message : "No se pudo cargar la información.");
    } finally {
      setLoading(false);
    }
  }, [defaultFilters, moduleName, search]);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      void loadRows();
    }, 0);
    return () => window.clearTimeout(timer);
  }, [loadRows]);

  async function submitSearch(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setSearch(searchDraft.trim());
  }

  async function handleAction(action: ActionDef, row: AdminJsonRow) {
    const id = row.id || row.booking_id || row.payment_order_id || row.company_id || row.profile_id;
    if (!id) return;
    let note = "";
    if (action.prompt) {
      const entered = window.prompt(action.prompt, "");
      if (entered === null) return;
      note = entered;
    } else {
      const ok = window.confirm(`¿Confirmas la acción: ${action.label}?`);
      if (!ok) return;
    }
    setActionLoadingId(String(id));
    setErrorMessage("");
    try {
      await runAdminAction(action.action, { id, row, note });
      await loadRows();
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : "No se pudo ejecutar la acción.");
    } finally {
      setActionLoadingId(null);
    }
  }

  return (
    <div className="space-y-6">
      <section className="rounded-3xl border border-white/10 bg-white/[0.04] p-6 sm:p-8 shadow-2xl">
        <div className="flex flex-col xl:flex-row xl:items-center xl:justify-between gap-5">
          <div><p className="text-sm uppercase tracking-[0.25em] text-cyan-300 font-bold">{eyebrow}</p><h1 className="mt-2 text-3xl font-black">{title}</h1><p className="mt-2 text-slate-300 max-w-3xl">{description}</p></div>
          <button onClick={loadRows} className="inline-flex items-center justify-center gap-2 rounded-2xl bg-cyan-400 px-5 py-3 text-sm font-black text-[#050816] hover:bg-cyan-300"><RefreshCcw className="h-4 w-4"/>Actualizar</button>
        </div>
      </section>

      <section className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-4">
        <Stat label="Total visible" value={total} />
        <Stat label="Aprobados/activos" value={approved} />
        <Stat label="Pendientes" value={pending} />
        <Stat label="Fallidos/suspendidos" value={failed} danger />
      </section>

      <section className="rounded-3xl border border-white/10 bg-white/[0.04] p-5 shadow-xl">
        <form onSubmit={submitSearch} className="grid grid-cols-1 lg:grid-cols-[1fr_auto] gap-3">
          <div className="relative"><Search className="absolute left-4 top-1/2 -translate-y-1/2 h-5 w-5 text-slate-500"/><input value={searchDraft} onChange={(e) => setSearchDraft(e.target.value)} placeholder="Buscar..." className="w-full rounded-2xl border border-white/10 bg-[#050816] px-12 py-3 text-sm text-white outline-none placeholder:text-slate-500 focus:border-cyan-300" /></div>
          <button className="rounded-2xl bg-white px-5 py-3 text-sm font-black text-[#050816] hover:bg-slate-200">Buscar</button>
        </form>
        {extraFilters && <div className="mt-4">{extraFilters}</div>}
      </section>

      {errorMessage && <div className="rounded-2xl border border-red-400/30 bg-red-500/10 px-5 py-4 text-sm text-red-200">{adminMessage(errorMessage)}</div>}

      <section className="rounded-3xl border border-white/10 bg-white/[0.04] shadow-2xl overflow-hidden">
        <div className="overflow-x-auto">
          <table className="min-w-full text-left">
            <thead className="bg-white/[0.04] border-b border-white/10"><tr>{columns.map((c) => <th key={c.key} className="px-6 py-4 text-xs font-black uppercase tracking-wider text-slate-400">{c.label}</th>)}{actions.length > 0 && <th className="px-6 py-4 text-xs font-black uppercase tracking-wider text-slate-400">Acciones</th>}</tr></thead>
            <tbody>
              {loading ? <tr><td colSpan={columns.length + 1} className="px-6 py-12 text-center text-slate-400">Cargando...</td></tr> : rows.length === 0 ? <tr><td colSpan={columns.length + 1} className="px-6 py-12 text-center text-slate-400">No hay registros para mostrar.</td></tr> : rows.map((row, index) => <tr key={String(row.id ?? row.booking_id ?? row.payment_order_id ?? index)} className="border-b border-white/10 hover:bg-white/[0.03]">{columns.map((c) => <td key={c.key} className="px-6 py-4 align-top text-sm text-slate-200">{renderCell(row[c.key], c.type)}</td>)}{actions.length > 0 && <td className="px-6 py-4 align-top"><div className="flex flex-wrap gap-2">{actions.filter((a) => !a.visible || a.visible(row)).map((a) => { const id = row.id || row.booking_id || row.payment_order_id || row.company_id || row.profile_id; return <button key={a.action} onClick={() => handleAction(a, row)} disabled={actionLoadingId === String(id)} className={a.danger ? "rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs font-bold text-red-200 hover:bg-red-500/20 disabled:opacity-50" : "rounded-xl border border-cyan-300/30 bg-cyan-400/10 px-3 py-2 text-xs font-bold text-cyan-200 hover:bg-cyan-400/20 disabled:opacity-50"}>{actionLoadingId === String(id) ? "Procesando..." : a.label}</button>; })}</div></td>}</tr>)}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}

function Stat({ label, value, danger }: { label: string; value: number; danger?: boolean }) {
  return <div className="rounded-3xl border border-white/10 bg-white/[0.04] p-5 shadow-xl"><p className="text-sm text-slate-400">{label}</p><p className={danger ? "mt-2 text-3xl font-black text-red-300" : "mt-2 text-3xl font-black text-white"}>{value.toLocaleString("es-PA")}</p></div>;
}

function renderCell(value: unknown, type?: ColumnDef["type"]) {
  if (type === "money") return <span className="font-bold text-emerald-200">{money(value)}</span>;
  if (type === "date") return dateOnly(value);
  if (type === "datetime") return dateTime(value);
  if (type === "bool") return value ? <Badge tone="success">Sí</Badge> : <Badge>No</Badge>;
  if (type === "status") return <StatusBadge value={value} />;
  if (value === null || value === undefined || value === "") return <span className="text-slate-500">-</span>;
  if (typeof value === "object") return <span>{formatObjectValue(value)}</span>;
  return String(value);
}

function formatObjectValue(value: object): string {
  if (Array.isArray(value)) {
    if (value.length === 0) return "Sin datos";
    return value
      .slice(0, 3)
      .map((item) => (typeof item === "object" && item !== null ? formatObjectValue(item) : text(item)))
      .join(" · ");
  }

  const parts = Object.entries(value)
    .filter(([, item]) => item !== null && item !== undefined && typeof item !== "object" && String(item).trim() !== "")
    .slice(0, 5)
    .map(([key, item]) => `${human(key)}: ${text(item)}`);

  return parts.length ? parts.join(" · ") : "Dato estructurado";
}

function StatusBadge({ value }: { value: unknown }) {
  const text = String(value ?? "-");
  const s = text.toLowerCase();
  const tone = ["approved", "paid", "active", "completed", "released", "accepted"].includes(s) ? "success" : ["rejected", "cancelled", "failed", "suspended"].includes(s) ? "danger" : ["pending", "processing", "requested"].includes(s) ? "warning" : "neutral";
  return <Badge tone={tone}>{statusLabel(text)}</Badge>;
}

function human(key: string) {
  return key.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function Badge({ children, tone = "neutral" }: { children: ReactNode; tone?: "success" | "danger" | "warning" | "neutral" }) {
  const tones = { success: "border-emerald-400/30 bg-emerald-500/10 text-emerald-200", danger: "border-red-400/30 bg-red-500/10 text-red-200", warning: "border-yellow-400/30 bg-yellow-500/10 text-yellow-200", neutral: "border-white/10 bg-white/[0.05] text-slate-300" };
  return <span className={`inline-flex rounded-full border px-3 py-1 text-xs font-bold ${tones[tone]}`}>{children}</span>;
}
