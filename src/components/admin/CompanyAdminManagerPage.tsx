"use client";

import { adminMessage } from "@/lib/admin-copy";

import { Children, cloneElement, FormEvent, isValidElement, ReactElement, ReactNode, useCallback, useEffect, useMemo, useState } from "react";
import {
  AlertTriangle,
  BadgeCheck,
  Ban,
  BriefcaseBusiness,
  Building2,
  CalendarClock,
  CheckCircle2,
  ChevronRight,
  CircleDollarSign,
  Clock3,
  CreditCard,
  FileText,
  Mail,
  MapPin,
  Pencil,
  Phone,
  ReceiptText,
  RefreshCcw,
  Search,
  ShieldCheck,
  Sparkles,
  UserRoundCog,
  Users,
  WalletCards,
  X,
} from "lucide-react";
import { supabase } from "@/lib/supabase";
import { formatPanamaDate, formatPanamaDateTime, money, statusLabel } from "@/lib/utils";

type JsonRow = Record<string, unknown>;
type CompanyTab = "resumen" | "datos" | "personal" | "servicios" | "reservas" | "finanzas" | "plan";

type CompanySummary = {
  total?: number;
  active?: number;
  pending?: number;
  suspended?: number;
  expiring_7d?: number;
  expired?: number;
  active_subscriptions?: number;
  plan_revenue?: number;
  booked_total?: number;
};

type CompanyRow = {
  id: string;
  name?: string | null;
  legal_name?: string | null;
  ruc?: string | null;
  email?: string | null;
  phone?: string | null;
  contact_name?: string | null;
  contact_email?: string | null;
  contact_phone?: string | null;
  city?: string | null;
  status?: string | null;
  verification_status?: string | null;
  plan_name?: string | null;
  subscription_status?: string | null;
  subscription_expires_at?: string | null;
  plan_expires_at?: string | null;
  days_remaining?: number | null;
  members_count?: number | null;
  active_members_count?: number | null;
  services_count?: number | null;
  active_services_count?: number | null;
  bookings_count?: number | null;
  completed_bookings_count?: number | null;
  booked_total?: number | null;
  plan_paid_total?: number | null;
  created_at?: string | null;
};

type OverviewPayload = {
  summary?: CompanySummary;
  companies?: CompanyRow[];
};

type CompanyDetail = {
  company?: JsonRow;
  members?: JsonRow[];
  services?: JsonRow[];
  bookings?: JsonRow[];
  plan_orders?: JsonRow[];
  payments?: JsonRow[];
  invoices?: JsonRow[];
  subscription_events?: JsonRow[];
  alerts?: Array<{ tone?: string; title?: string; body?: string }>;
  stats?: JsonRow;
};

const filterOptions = [
  ["all", "Todas"],
  ["active", "Activas"],
  ["pending", "Pendientes"],
  ["suspended", "Suspendidas"],
  ["expiring", "Por vencer"],
  ["expired", "Plan vencido"],
  ["pending_payment", "Pendiente de pago"],
] as const;

const tabs: Array<[CompanyTab, string]> = [
  ["resumen", "Resumen"],
  ["datos", "Datos de empresa"],
  ["personal", "Personal"],
  ["servicios", "Servicios"],
  ["reservas", "Reservas"],
  ["finanzas", "Finanzas"],
  ["plan", "Plan y suscripción"],
];

export default function CompanyAdminManagerPage() {
  const [summary, setSummary] = useState<CompanySummary>({});
  const [rows, setRows] = useState<CompanyRow[]>([]);
  const [searchDraft, setSearchDraft] = useState("");
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("all");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [detail, setDetail] = useState<CompanyDetail | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [tab, setTab] = useState<CompanyTab>("resumen");
  const [actionLoading, setActionLoading] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    const { data, error: rpcError } = await supabase.rpc("yt_admin_companies_overview_v40", {
      p_search: search,
      p_status: status,
      p_limit: 250,
    });
    if (rpcError) {
      setError(rpcError.message);
      setSummary({});
      setRows([]);
    } else {
      const payload = (data || {}) as OverviewPayload;
      setSummary(payload.summary || {});
      setRows(Array.isArray(payload.companies) ? payload.companies : []);
    }
    setLoading(false);
  }, [search, status]);

  useEffect(() => {
    void load();
  }, [load]);

  const openCompany = useCallback(async (companyId: string, initialTab: CompanyTab = "resumen") => {
    setSelectedId(companyId);
    setTab(initialTab);
    setDetailLoading(true);
    setError("");
    const { data, error: rpcError } = await supabase.rpc("yt_admin_company_detail_v40", { p_company_id: companyId });
    if (rpcError) {
      setError(rpcError.message);
      setDetail(null);
    } else {
      setDetail((data || {}) as CompanyDetail);
    }
    setDetailLoading(false);
  }, []);

  const refreshDetail = useCallback(async () => {
    if (!selectedId) return;
    await openCompany(selectedId, tab);
  }, [openCompany, selectedId, tab]);

  const totalVisible = rows.length;
  const effectiveActiveCompanies = useMemo(() => {
    if (status !== "all" || search) return Number(summary.active ?? 0);
    return rows.filter((row) => String(row.status || "").toLowerCase() === "active" && !isCompanySubscriptionExpired(row)).length;
  }, [rows, search, status, summary.active]);
  const effectiveActiveSubscriptions = useMemo(() => {
    if (status !== "all" || search) return Number(summary.active_subscriptions ?? 0);
    return rows.filter((row) => ["active", "paid"].includes(String(row.subscription_status || "").toLowerCase()) && !isCompanySubscriptionExpired(row)).length;
  }, [rows, search, status, summary.active_subscriptions]);

  return (
    <div className="ui2-companies-page">
      <section className="hero company-hero ui2-module-hero">
        <div className="hero-row">
          <div>
            <div className="eyebrow">ADMINISTRACIÓN COMERCIAL</div>
            <h1>Empresas</h1>
            <p className="subtitle">
              Control integral de empresas, personal, servicios por categorías oficiales, reservas, facturación y estado de suscripción.
            </p>
          </div>
          <div className="hero-actions">
            <button className="btn btn-primary" onClick={() => void load()} disabled={loading}>
              <RefreshCcw size={16} /> {loading ? "Actualizando..." : "Actualizar"}
            </button>
          </div>
        </div>
      </section>

      {error ? <div className="error" style={{ marginBottom: 18 }}>{adminMessage(error)}</div> : null}

      <section className="stats company-stats ui2-module-stats">
        <CompanyStat icon={<Building2 size={18} />} label="Total empresas" value={String(summary.total ?? 0)} helper={`${effectiveActiveCompanies} activas`} />
        <CompanyStat icon={<CheckCircle2 size={18} />} label="Activas" value={String(effectiveActiveCompanies)} helper={`${effectiveActiveSubscriptions} con suscripción activa`} />
        <CompanyStat icon={<Clock3 size={18} />} label="Pendientes" value={String(summary.pending ?? 0)} helper="Registro o verificación pendiente" />
        <CompanyStat icon={<Ban size={18} />} label="Suspendidas" value={String(summary.suspended ?? 0)} helper="Requieren revisión administrativa" />
        <CompanyStat icon={<CalendarClock size={18} />} label="Planes por vencer" value={String(summary.expiring_7d ?? 0)} helper={`${summary.expired ?? 0} ya vencidos`} />
        <CompanyStat icon={<CircleDollarSign size={18} />} label="Ingresos por planes" value={money(Number(summary.plan_revenue ?? 0))} helper={`${money(Number(summary.booked_total ?? 0))} reservado por empresas`} />
      </section>

      <section className="card company-filter-card ui2-module-filters">
        <form
          className="company-filter-form"
          onSubmit={(event) => {
            event.preventDefault();
            setSearch(searchDraft.trim());
          }}
        >
          <div className="company-search-box">
            <Search size={17} />
            <input
              className="input"
              value={searchDraft}
              onChange={(event) => setSearchDraft(event.target.value)}
              placeholder="Buscar empresa, RUC, correo, contacto o teléfono..."
            />
          </div>
          <button className="btn btn-soft" type="submit">Buscar</button>
          <button
            className="btn btn-soft"
            type="button"
            onClick={() => {
              setSearchDraft("");
              setSearch("");
              setStatus("all");
            }}
          >
            Limpiar
          </button>
        </form>
      </section>

      <div className="filter-chips company-filter-chips ui2-segmented-status">
        {filterOptions.map(([key, label]) => (
          <button key={key} className={`filter-chip ${status === key ? "active" : ""}`} onClick={() => setStatus(key)}>
            {label}
          </button>
        ))}
      </div>

      <div className="company-list-caption">
        <span>{loading ? "Consultando empresas..." : `${totalVisible} empresa${totalVisible === 1 ? "" : "s"} en esta vista`}</span>
        {search ? <span>Filtro: “{search}”</span> : null}
      </div>

      <section className="card table-card company-table-card ui2-data-card">
        <div className="table-wrap">
          <table className="table company-table responsive-table company-responsive-table">
            <thead>
              <tr>
                <th>Empresa</th>
                <th>Contacto</th>
                <th>Plan / suscripción</th>
                <th>Personal</th>
                <th>Servicios</th>
                <th>Reservas</th>
                <th>Actividad</th>
                <th>Estado</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <CompanyTableRow key={row.id} row={row} onOpen={(nextTab) => void openCompany(row.id, nextTab)} />
              ))}
              {!loading && rows.length === 0 ? (
                <tr><td colSpan={9}><div className="empty">No hay empresas que coincidan con los filtros.</div></td></tr>
              ) : null}
              {loading && rows.length === 0 ? (
                <tr><td colSpan={9}><div className="empty">Cargando módulo de empresas...</div></td></tr>
              ) : null}
            </tbody>
          </table>
        </div>
      </section>

      {selectedId ? (
        <CompanyDetailModal
          companyId={selectedId}
          detail={detail}
          loading={detailLoading}
          activeTab={tab}
          setActiveTab={setTab}
          actionLoading={actionLoading}
          onClose={() => {
            setSelectedId(null);
            setDetail(null);
          }}
          onRefresh={refreshDetail}
          onRunAction={async (action, note, days) => {
            setActionLoading(true);
            setError("");
            const { error: actionError } = await supabase.rpc("yt_admin_company_action_v40", {
              p_company_id: selectedId,
              p_action: action,
              p_note: note || null,
              p_days: days || null,
            });
            if (actionError) setError(actionError.message);
            else {
              await Promise.all([load(), refreshDetail()]);
            }
            setActionLoading(false);
          }}
          onSaveCompany={async (payload) => {
            setActionLoading(true);
            setError("");
            const { error: updateError } = await supabase.rpc("yt_admin_company_update_v40", {
              p_company_id: selectedId,
              p_payload: payload,
            });
            if (updateError) setError(updateError.message);
            else await Promise.all([load(), refreshDetail()]);
            setActionLoading(false);
          }}
        />
      ) : null}
    </div>
  );
}

function CompanyStat({ icon, label, value, helper }: { icon: ReactNode; label: string; value: string; helper: string }) {
  return (
    <div className="stat company-stat ui2-stat-card">
      <div className="company-stat-label">{icon}<span>{label}</span></div>
      <strong>{value}</strong>
      <small>{helper}</small>
    </div>
  );
}

function isCompanySubscriptionExpired(row: CompanyRow) {
  const expiresAt = row.subscription_expires_at || row.plan_expires_at;
  const days = row.days_remaining;
  if (typeof days === "number" && days < 0) return true;
  if (!expiresAt) return String(row.subscription_status || "").toLowerCase() === "expired";
  const raw = String(expiresAt);
  const time = new Date(raw.length <= 10 ? `${raw}T23:59:59-05:00` : raw).getTime();
  return Number.isFinite(time) ? time < Date.now() : String(row.subscription_status || "").toLowerCase() === "expired";
}

function CompanyTableRow({ row, onOpen }: { row: CompanyRow; onOpen: (tab: CompanyTab) => void }) {
  const expiresAt = row.subscription_expires_at || row.plan_expires_at;
  const days = Number(row.days_remaining ?? 0);
  const expired = isCompanySubscriptionExpired(row);
  const effectiveSubscriptionStatus = expired ? "inactive" : (row.subscription_status || "inactive");
  const effectiveCompanyStatus = expired ? "inactive" : (row.status || "pending");
  return (
    <tr>
      <td data-label="Empresa">
        <button className="company-name-button" onClick={() => onOpen("resumen")}>
          <span className="company-logo-placeholder"><Building2 size={18} /></span>
          <span>
            <strong>{row.name || "Empresa sin nombre"}</strong>
            <small>{row.legal_name || row.ruc || row.city || "Sin razón social"}</small>
          </span>
        </button>
      </td>
      <td data-label="Contacto">
        <strong>{row.contact_name || "Sin contacto"}</strong>
        <div className="secondary">{row.contact_email || row.email || "Sin correo"}</div>
        <div className="secondary">{row.contact_phone || row.phone || "Sin teléfono"}</div>
      </td>
      <td data-label="Plan / suscripción">
        <strong>{row.plan_name || "Empresa Básica"}</strong>
        <div style={{ marginTop: 6 }}><CompanyStatusBadge value={effectiveSubscriptionStatus} kind="subscription" /></div>
        <div className={`secondary ${days <= 7 && days >= 0 ? "company-expiring" : ""}`}>
          {expiresAt ? `${formatPanamaDate(expiresAt)} · ${expired ? "Vencido" : `${Math.max(days, 0)} día${Math.max(days, 0) === 1 ? "" : "s"}`}` : "Sin vencimiento registrado"}
        </div>
      </td>
      <td data-label="Personal">
        <button className="company-metric-link" onClick={() => onOpen("personal")}>
          <Users size={15} /><strong>{Number(row.active_members_count ?? 0)}</strong><span>activos</span>
        </button>
        <div className="secondary">{Number(row.members_count ?? 0)} registrados</div>
      </td>
      <td data-label="Servicios">
        <button className="company-metric-link" onClick={() => onOpen("servicios")}>
          <BriefcaseBusiness size={15} /><strong>{Number(row.active_services_count ?? 0)}</strong><span>activos</span>
        </button>
        <div className="secondary">{Number(row.services_count ?? 0)} total</div>
      </td>
      <td data-label="Reservas">
        <button className="company-metric-link" onClick={() => onOpen("reservas")}>
          <ReceiptText size={15} /><strong>{Number(row.bookings_count ?? 0)}</strong><span>reservas</span>
        </button>
        <div className="secondary">{Number(row.completed_bookings_count ?? 0)} completadas</div>
      </td>
      <td data-label="Actividad">
        <strong>{money(Number(row.booked_total ?? 0))}</strong>
        <div className="secondary">Reservado</div>
        <div className="secondary">Planes: {money(Number(row.plan_paid_total ?? 0))}</div>
      </td>
      <td data-label="Estado">
        <div className="company-status-stack">
          <CompanyStatusBadge value={effectiveCompanyStatus} kind="company" />
          <CompanyStatusBadge value={row.verification_status || "pending"} kind="verification" />
        </div>
      </td>
      <td data-label="Acción" className="table-actions-cell">
        <button className="btn btn-soft btn-small" onClick={() => onOpen("resumen")}>Ver empresa <ChevronRight size={15} /></button>
      </td>
    </tr>
  );
}

function CompanyStatusBadge({ value, kind }: { value: string; kind: "company" | "verification" | "subscription" }) {
  const normalized = String(value || "").toLowerCase();
  const positive = ["active", "verified", "paid", "approved"].includes(normalized);
  const subscriptionInactive = kind === "subscription" && ["inactive", "expired"].includes(normalized);
  const warning = ["pending", "pending_payment"].includes(normalized) || (normalized === "inactive" && !subscriptionInactive);
  const cls = subscriptionInactive ? "red" : positive ? "green" : warning ? "yellow" : "red";
  let label = statusLabel(normalized);
  if (kind === "verification" && normalized === "verified") label = "Verificada";
  if (kind === "verification" && normalized === "pending") label = "Por verificar";
  if (kind === "subscription" && normalized === "active") label = "Plan activo";
  if (kind === "subscription" && ["expired", "inactive"].includes(normalized)) label = "Inactivo";
  if (kind === "subscription" && normalized === "pending_payment") label = "Plan pendiente";
  return <span className={`badge ${cls}`}>{label}</span>;
}

function CompanyDetailModal({
  companyId,
  detail,
  loading,
  activeTab,
  setActiveTab,
  actionLoading,
  onClose,
  onRefresh,
  onRunAction,
  onSaveCompany,
}: {
  companyId: string;
  detail: CompanyDetail | null;
  loading: boolean;
  activeTab: CompanyTab;
  setActiveTab: (tab: CompanyTab) => void;
  actionLoading: boolean;
  onClose: () => void;
  onRefresh: () => Promise<void>;
  onRunAction: (action: string, note?: string, days?: number) => Promise<void>;
  onSaveCompany: (payload: JsonRow) => Promise<void>;
}) {
  const company = detail?.company || {};
  const stats = detail?.stats || {};
  const name = str(company.name, "Empresa Wissa");
  const status = str(company.status, "pending");
  const subscriptionStatus = str(company.subscription_status, "inactive");
  const verification = str(company.verification_status, "pending");

  return (
    <div className="modal-backdrop company-detail-backdrop" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <div className="modal company-detail-modal">
        <div className="company-detail-header">
          <div className="company-detail-heading">
            <span className="company-detail-logo"><Building2 size={24} /></span>
            <div>
              <div className="eyebrow">FICHA ADMINISTRATIVA</div>
              <h2>{name}</h2>
              <div className="company-heading-badges">
                <CompanyStatusBadge value={status} kind="company" />
                <CompanyStatusBadge value={verification} kind="verification" />
                <CompanyStatusBadge value={subscriptionStatus} kind="subscription" />
              </div>
            </div>
          </div>
          <div className="company-detail-actions">
            <button className="btn btn-soft btn-small" onClick={() => void onRefresh()} disabled={loading}><RefreshCcw size={15} /> Actualizar</button>
            <button className="company-close-button" onClick={onClose} aria-label="Cerrar"><X size={19} /></button>
          </div>
        </div>

        <div className="company-detail-tabs">
          {tabs.map(([key, label]) => (
            <button key={key} className={activeTab === key ? "active" : ""} onClick={() => setActiveTab(key)}>{label}</button>
          ))}
        </div>

        <div className="company-detail-body">
          {loading ? <div className="empty">Cargando información completa de la empresa...</div> : null}
          {!loading && !detail ? <div className="empty">No se pudo cargar la empresa {companyId.slice(0, 8)}…</div> : null}
          {!loading && detail && activeTab === "resumen" ? (
            <CompanyOverviewTab detail={detail} onRunAction={onRunAction} actionLoading={actionLoading} />
          ) : null}
          {!loading && detail && activeTab === "datos" ? (
            <CompanyDataTab company={company} onSave={onSaveCompany} saving={actionLoading} />
          ) : null}
          {!loading && detail && activeTab === "personal" ? <CompanyMembersTab rows={detail.members || []} /> : null}
          {!loading && detail && activeTab === "servicios" ? <CompanyServicesTab rows={detail.services || []} /> : null}
          {!loading && detail && activeTab === "reservas" ? <CompanyBookingsTab rows={detail.bookings || []} /> : null}
          {!loading && detail && activeTab === "finanzas" ? <CompanyFinanceTab detail={detail} /> : null}
          {!loading && detail && activeTab === "plan" ? (
            <CompanyPlanTab detail={detail} onRunAction={onRunAction} actionLoading={actionLoading} />
          ) : null}
        </div>
      </div>
    </div>
  );
}

function CompanyOverviewTab({ detail, onRunAction, actionLoading }: { detail: CompanyDetail; onRunAction: (action: string, note?: string, days?: number) => Promise<void>; actionLoading: boolean }) {
  const company = detail.company || {};
  const stats = detail.stats || {};
  const alerts = detail.alerts || [];
  return (
    <div className="company-detail-grid">
      <div className="company-main-column">
        <div className="company-mini-stats">
          <MiniMetric label="Personal activo" value={String(num(stats.active_members))} icon={<Users size={17} />} />
          <MiniMetric label="Servicios activos" value={String(num(stats.active_services))} icon={<BriefcaseBusiness size={17} />} />
          <MiniMetric label="Reservas" value={String(num(stats.bookings))} icon={<ReceiptText size={17} />} />
          <MiniMetric label="Total reservado" value={money(num(stats.booked_total))} icon={<CircleDollarSign size={17} />} />
        </div>

        <section className="company-inner-card">
          <div className="company-section-title"><Sparkles size={17} /><div><strong>Actividad y estado</strong><span>Vista rápida de la cuenta empresarial.</span></div></div>
          <div className="company-overview-info-grid">
            <InfoLine label="Plan" value={str(company.plan_name, "Empresa Básica")} />
            <InfoLine label="Vencimiento" value={company.subscription_expires_at || company.plan_expires_at ? formatPanamaDate(company.subscription_expires_at || company.plan_expires_at) : "Sin fecha"} />
            <InfoLine label="Contacto" value={str(company.contact_name, "Sin contacto principal")} />
            <InfoLine label="Ciudad" value={str(company.city, "Panamá")} />
            <InfoLine label="RUC" value={str(company.ruc || company.tax_id, "Sin registrar")} />
            <InfoLine label="Creada" value={company.created_at ? formatPanamaDate(company.created_at) : "Sin dato"} />
          </div>
        </section>

        <section className="company-inner-card">
          <div className="company-section-title"><WalletCards size={17} /><div><strong>Resumen financiero</strong><span>Movimientos registrados para esta empresa.</span></div></div>
          <div className="company-finance-summary">
            <FinanceMetric label="Reservado" value={money(num(stats.booked_total))} />
            <FinanceMetric label="Pagos empresa" value={money(num(stats.company_payments_total))} />
            <FinanceMetric label="Planes pagados" value={money(num(stats.plan_paid_total))} />
            <FinanceMetric label="Facturado" value={money(num(stats.invoiced_total))} />
          </div>
        </section>
      </div>

      <div className="company-side-column">
        <section className="company-inner-card">
          <div className="company-section-title"><AlertTriangle size={17} /><div><strong>Alertas administrativas</strong><span>Situaciones que conviene revisar.</span></div></div>
          <div className="company-alert-list">
            {alerts.length ? alerts.map((alert, index) => (
              <div key={`${alert.title}-${index}`} className={`company-alert company-alert-${alert.tone || "info"}`}>
                <AlertTriangle size={16} />
                <div><strong>{alert.title || "Aviso"}</strong><span>{alert.body || "Revisar información de la empresa."}</span></div>
              </div>
            )) : <div className="company-alert company-alert-success"><CheckCircle2 size={16} /><div><strong>Sin alertas críticas</strong><span>La empresa no presenta advertencias administrativas.</span></div></div>}
          </div>
        </section>

        <section className="company-inner-card">
          <div className="company-section-title"><ShieldCheck size={17} /><div><strong>Acciones administrativas</strong><span>Control de empresa y verificación.</span></div></div>
          <div className="company-admin-actions">
            {str(company.status, "pending") === "suspended" ? (
              <button className="btn btn-green" disabled={actionLoading} onClick={() => void onRunAction("reactivate", "Reactivada desde Admin Wissa")}>Reactivar empresa</button>
            ) : (
              <button className="btn btn-danger" disabled={actionLoading} onClick={() => {
                const note = window.prompt("Motivo de suspensión:", "Revisión administrativa");
                if (note !== null) void onRunAction("suspend", note);
              }}>Suspender empresa</button>
            )}
            {str(company.verification_status, "pending") !== "verified" ? (
              <button className="btn btn-green" disabled={actionLoading} onClick={() => void onRunAction("verify", "Empresa verificada por Admin Wissa")}><BadgeCheck size={16} /> Verificar empresa</button>
            ) : null}
            {str(company.status, "pending") === "pending" ? (
              <button className="btn btn-primary" disabled={actionLoading} onClick={() => void onRunAction("activate", "Empresa activada por Admin Wissa")}>Activar empresa</button>
            ) : null}
          </div>
        </section>
      </div>
    </div>
  );
}

function CompanyDataTab({ company, onSave, saving }: { company: JsonRow; onSave: (payload: JsonRow) => Promise<void>; saving: boolean }) {
  const [form, setForm] = useState(() => companyFormFrom(company));
  useEffect(() => setForm(companyFormFrom(company)), [company]);
  const set = (key: keyof ReturnType<typeof companyFormFrom>, value: string | boolean) => setForm((current) => ({ ...current, [key]: value }));
  async function submit(event: FormEvent) {
    event.preventDefault();
    await onSave(form as unknown as JsonRow);
  }
  return (
    <form onSubmit={submit} className="company-edit-form">
      <div className="company-section-title company-form-heading"><Pencil size={17} /><div><strong>Datos de empresa</strong><span>Información comercial y de facturación visible para Administración Wissa.</span></div></div>
      <div className="company-form-grid">
        <Field label="Nombre comercial"><input className="input" value={form.name} onChange={(e) => set("name", e.target.value)} required /></Field>
        <Field label="Razón social"><input className="input" value={form.legal_name} onChange={(e) => set("legal_name", e.target.value)} /></Field>
        <Field label="RUC"><input className="input" value={form.ruc} onChange={(e) => set("ruc", e.target.value)} /></Field>
        <Field label="Tipo de negocio"><input className="input" value={form.business_type} onChange={(e) => set("business_type", e.target.value)} /></Field>
        <Field label="Correo de empresa"><input className="input" type="email" value={form.email} onChange={(e) => set("email", e.target.value)} /></Field>
        <Field label="Teléfono"><input className="input" value={form.phone} onChange={(e) => set("phone", e.target.value)} /></Field>
        <Field label="Sitio web"><input className="input" value={form.website} onChange={(e) => set("website", e.target.value)} /></Field>
        <Field label="Ciudad"><input className="input" value={form.city} onChange={(e) => set("city", e.target.value)} /></Field>
        <Field label="Dirección" wide><input className="input" value={form.address} onChange={(e) => set("address", e.target.value)} /></Field>
      </div>
      <div className="company-form-divider" />
      <h3 className="company-form-subtitle">Contacto principal</h3>
      <div className="company-form-grid">
        <Field label="Nombre"><input className="input" value={form.contact_name} onChange={(e) => set("contact_name", e.target.value)} /></Field>
        <Field label="Correo"><input className="input" type="email" value={form.contact_email} onChange={(e) => set("contact_email", e.target.value)} /></Field>
        <Field label="Teléfono"><input className="input" value={form.contact_phone} onChange={(e) => set("contact_phone", e.target.value)} /></Field>
      </div>
      <div className="company-form-divider" />
      <h3 className="company-form-subtitle">Facturación</h3>
      <div className="company-form-grid">
        <Field label="Correo de facturación"><input className="input" type="email" value={form.billing_email} onChange={(e) => set("billing_email", e.target.value)} /></Field>
        <Field label="Teléfono de facturación"><input className="input" value={form.billing_phone} onChange={(e) => set("billing_phone", e.target.value)} /></Field>
        <Field label="Dirección de facturación" wide><input className="input" value={form.billing_address} onChange={(e) => set("billing_address", e.target.value)} /></Field>
        <Field label="Modo de facturación">
          <select className="select" value={form.billing_mode} onChange={(e) => set("billing_mode", e.target.value)}>
            <option value="per_booking">Por reserva</option><option value="monthly_invoice">Factura mensual</option><option value="credit">Crédito</option><option value="manual">Manual</option>
          </select>
        </Field>
        <Field label="Ciclo">
          <select className="select" value={form.billing_cycle} onChange={(e) => set("billing_cycle", e.target.value)}>
            <option value="none">Sin ciclo</option><option value="weekly">Semanal</option><option value="biweekly">Quincenal</option><option value="monthly">Mensual</option>
          </select>
        </Field>
        <Field label="Días para pago"><input className="input" type="number" min="0" max="365" value={form.payment_terms_days} onChange={(e) => set("payment_terms_days", e.target.value)} /></Field>
      </div>
      <div className="company-switch-row">
        <label><input type="checkbox" checked={form.requires_approval} onChange={(e) => set("requires_approval", e.target.checked)} /> Requiere aprobación interna</label>
        <label><input type="checkbox" checked={form.auto_approve_bookings} onChange={(e) => set("auto_approve_bookings", e.target.checked)} /> Autoaprobar reservas</label>
      </div>
      <div className="company-form-actions"><button className="btn btn-primary" disabled={saving} type="submit">{saving ? "Guardando..." : "Guardar cambios"}</button></div>
    </form>
  );
}

function CompanyMembersTab({ rows }: { rows: JsonRow[] }) {
  return <CompanySimpleTable headers={["Personal", "Cargo / departamento", "Rol", "Permisos", "Estado", "Último acceso"]} empty="Esta empresa todavía no tiene personal registrado.">
    {rows.map((row) => <tr key={str(row.id)}>
      <td><strong>{str(row.full_name, "Sin nombre")}</strong><div className="secondary">{str(row.email, "Sin correo")}</div><div className="secondary">{str(row.phone, "Sin teléfono")}</div></td>
      <td><strong>{str(row.position, "Sin cargo")}</strong><div className="secondary">{str(row.department, "Sin departamento")}</div></td>
      <td><span className="badge cyan">{companyRoleLabel(str(row.internal_role || row.role))}</span></td>
      <td><div className="company-permission-list">{bool(row.can_create_bookings) ? <span>Reservar</span> : null}{bool(row.can_approve_bookings) ? <span>Aprobar</span> : null}{bool(row.can_view_finance) ? <span>Finanzas</span> : null}{bool(row.can_manage_staff) ? <span>Personal</span> : null}</div></td>
      <td><CompanyStatusBadge value={str(row.status, "pending")} kind="company" /></td>
      <td>{row.last_login_at ? formatPanamaDateTime(row.last_login_at) : "Sin acceso registrado"}</td>
    </tr>)}
  </CompanySimpleTable>;
}

function CompanyServicesTab({ rows }: { rows: JsonRow[] }) {
  const categoryCounts = useMemo(() => {
    const counts = new Map<string, number>();
    for (const row of rows) counts.set(categoryLabel(str(row.category)), (counts.get(categoryLabel(str(row.category))) || 0) + 1);
    return Array.from(counts.entries());
  }, [rows]);
  return <div>
    <div className="notice" style={{ marginBottom: 14 }}>
      <strong>Materiales e insumos:</strong> Wissa no entrega kits en reservas empresariales. Limpieza y Limpieza exteriores usan insumos proporcionados por la empresa; en Plomería, Wissa cobra únicamente el diagnóstico; cualquier reparación posterior se coordina directamente con quien ofrece.
    </div>
    <div className="company-category-summary">
      {categoryCounts.map(([label, count]) => <div key={label}><span>{label}</span><strong>{count}</strong></div>)}
      {!categoryCounts.length ? <div><span>Categorías oficiales</span><strong>0</strong></div> : null}
    </div>
    <CompanySimpleTable headers={["Servicio", "Categoría", "Personal asignado", "Duración", "Reservas", "Estado"]} empty="Esta empresa todavía no tiene servicios asignados.">
      {rows.map((row) => <tr key={str(row.id)}>
        <td><strong>{str(row.title, "Servicio")}</strong><div className="secondary">{str(row.description, "Sin descripción")}</div></td>
        <td><span className={`badge ${categoryBadgeClass(str(row.category))}`}>{categoryLabel(str(row.category))}</span></td>
        <td><strong>{str(row.member_name || row.provider_name, "Sin asignar")}</strong><div className="secondary">{str(row.member_email || row.provider_email, "")}</div></td>
        <td>{num(row.duration_minutes, 60)} min</td>
        <td>{num(row.bookings_count)} reservas</td>
        <td><span className={`badge ${bool(row.is_active) ? "green" : "red"}`}>{bool(row.is_active) ? "Activo" : "Inactivo"}</span></td>
      </tr>)}
    </CompanySimpleTable>
  </div>;
}

function CompanyBookingsTab({ rows }: { rows: JsonRow[] }) {
  return <CompanySimpleTable headers={["Reserva", "Servicio", "Solicitante", "Fecha", "Monto", "Pago", "Estado"]} empty="Esta empresa todavía no registra reservas.">
    {rows.map((row) => <tr key={str(row.id)}>
      <td><strong>{shortId(str(row.id))}</strong><div className="secondary">{str(row.company_reference, "Sin referencia")}</div></td>
      <td><strong>{str(row.service_title, "Servicio")}</strong><div className="secondary">{str(row.company_department, "")}</div></td>
      <td>{str(row.requested_by_name, "Empresa")}</td>
      <td>{row.booking_date ? formatPanamaDate(row.booking_date) : row.created_at ? formatPanamaDate(row.created_at) : "—"}<div className="secondary">{str(row.booking_time, "")}</div></td>
      <td>{money(num(row.total_amount))}</td>
      <td><CompanyStatusBadge value={str(row.payment_status, "pending")} kind="company" /></td>
      <td><CompanyStatusBadge value={str(row.status, "pending")} kind="company" /></td>
    </tr>)}
  </CompanySimpleTable>;
}

function CompanyFinanceTab({ detail }: { detail: CompanyDetail }) {
  const stats = detail.stats || {};
  return <div>
    <div className="company-mini-stats company-finance-mini-stats">
      <MiniMetric label="Reservas" value={money(num(stats.booked_total))} icon={<ReceiptText size={17} />} />
      <MiniMetric label="Pagos empresa" value={money(num(stats.company_payments_total))} icon={<CreditCard size={17} />} />
      <MiniMetric label="Planes" value={money(num(stats.plan_paid_total))} icon={<WalletCards size={17} />} />
      <MiniMetric label="Facturas" value={money(num(stats.invoiced_total))} icon={<FileText size={17} />} />
    </div>
    <h3 className="company-form-subtitle">Pagos de empresa</h3>
    <CompanySimpleTable headers={["Fecha", "Concepto", "Monto", "Método", "Referencia", "Estado"]} empty="No hay pagos empresariales registrados.">
      {(detail.payments || []).map((row) => <tr key={str(row.id)}><td>{row.created_at ? formatPanamaDateTime(row.created_at) : "—"}</td><td>{str(row.concept, "Pago de empresa")}</td><td>{money(num(row.amount))}</td><td>{str(row.method || row.provider, "—")}</td><td>{str(row.external_reference || row.transaction_id, "—")}</td><td><CompanyStatusBadge value={str(row.status, "pending")} kind="company" /></td></tr>)}
    </CompanySimpleTable>
    <h3 className="company-form-subtitle" style={{ marginTop: 24 }}>Facturas</h3>
    <CompanySimpleTable headers={["Factura", "Periodo", "Total", "Emitida", "Vence", "Estado"]} empty="No hay facturas registradas.">
      {(detail.invoices || []).map((row) => <tr key={str(row.id)}><td><strong>{str(row.invoice_number, shortId(str(row.id)))}</strong></td><td>{row.period_start ? formatPanamaDate(row.period_start) : "—"} → {row.period_end ? formatPanamaDate(row.period_end) : "—"}</td><td>{money(num(row.total_amount))}</td><td>{row.issued_at ? formatPanamaDate(row.issued_at) : "—"}</td><td>{row.due_at ? formatPanamaDate(row.due_at) : "—"}</td><td><CompanyStatusBadge value={str(row.status, "draft")} kind="company" /></td></tr>)}
    </CompanySimpleTable>
  </div>;
}

function CompanyPlanTab({ detail, onRunAction, actionLoading }: { detail: CompanyDetail; onRunAction: (action: string, note?: string, days?: number) => Promise<void>; actionLoading: boolean }) {
  const company = detail.company || {};
  const days = num(company.days_remaining);
  return <div className="company-plan-layout">
    <section className="company-plan-card">
      <div className="company-plan-icon"><ShieldCheck size={24} /></div>
      <div>
        <div className="eyebrow">PLAN ACTUAL</div>
        <h3>{str(company.plan_name, "Empresa Básica")}</h3>
        <div className="company-heading-badges"><CompanyStatusBadge value={str(company.subscription_status, "inactive")} kind="subscription" /></div>
        <p>{money(num(company.subscription_price, 10.99))} / {num(company.subscription_days, 30)} días</p>
      </div>
      <div className="company-plan-dates">
        <InfoLine label="Inicio" value={company.subscription_started_at ? formatPanamaDate(company.subscription_started_at) : "Sin fecha"} />
        <InfoLine label="Vence" value={company.subscription_expires_at || company.plan_expires_at ? formatPanamaDate(company.subscription_expires_at || company.plan_expires_at) : "Sin fecha"} />
        <InfoLine label="Días restantes" value={company.subscription_expires_at || company.plan_expires_at ? (days >= 0 ? String(days) : "Vencido") : "—"} />
        <InfoLine label="Último pago" value={company.subscription_last_paid_at ? formatPanamaDate(company.subscription_last_paid_at) : "Sin pago"} />
      </div>
      <div className="company-plan-actions">
        <button className="btn btn-primary" disabled={actionLoading} onClick={() => void onRunAction("extend", "Extensión manual de plan desde Admin Wissa", 30)}>Extender 30 días</button>
        {str(company.status, "pending") === "suspended" ? <button className="btn btn-green" disabled={actionLoading} onClick={() => void onRunAction("reactivate", "Empresa reactivada desde plan")}>Reactivar</button> : null}
      </div>
    </section>

    <section className="company-inner-card">
      <div className="company-section-title"><ReceiptText size={17} /><div><strong>Historial de pagos del plan</strong><span>Órdenes de suscripción registradas.</span></div></div>
      <CompanySimpleTable headers={["Fecha", "Monto", "Pasarela", "Referencia", "Estado"]} empty="No hay pagos de plan registrados.">
        {(detail.plan_orders || []).map((row) => <tr key={str(row.id)}><td>{row.created_at ? formatPanamaDateTime(row.created_at) : "—"}</td><td>{money(num(row.amount))}</td><td>{str(row.payment_method || row.provider, "—")}</td><td>{str(row.yappy_transaction_id || row.pf_transaction_id || row.public_checkout_token, "—")}</td><td><CompanyStatusBadge value={str(row.status, "pending")} kind="company" /></td></tr>)}
      </CompanySimpleTable>
    </section>

    <section className="company-inner-card">
      <div className="company-section-title"><CalendarClock size={17} /><div><strong>Línea de tiempo de suscripción</strong><span>Eventos administrativos y de renovación.</span></div></div>
      <div className="company-timeline">
        {(detail.subscription_events || []).map((row) => <div className="company-timeline-item" key={str(row.id)}><span /><div><strong>{str(row.title, str(row.event_type, "Evento"))}</strong><p>{str(row.body, "")}</p><small>{row.sent_at ? formatPanamaDateTime(row.sent_at) : row.created_at ? formatPanamaDateTime(row.created_at) : "—"}</small></div></div>)}
        {!(detail.subscription_events || []).length ? <div className="empty">No hay eventos de suscripción registrados.</div> : null}
      </div>
    </section>
  </div>;
}

function CompanySimpleTable({ headers, empty, children }: { headers: string[]; empty: string; children: ReactNode }) {
  const rows = Children.toArray(children);
  const responsiveRows = rows.map((child) => {
    if (!isValidElement(child)) return child;
    const row = child as ReactElement<{ children?: ReactNode }>;
    const cells = Children.toArray(row.props.children).map((cell, index) => {
      if (!isValidElement(cell)) return cell;
      return cloneElement(cell as ReactElement<Record<string, unknown>>, { "data-label": headers[index] || "Dato" });
    });
    return cloneElement(row, {}, cells);
  });
  return <div className="company-inner-table-wrap"><table className="table company-inner-table responsive-table"><thead><tr>{headers.map((header) => <th key={header}>{header}</th>)}</tr></thead><tbody>{responsiveRows}{!rows.length ? <tr><td colSpan={headers.length}><div className="empty">{empty}</div></td></tr> : null}</tbody></table></div>;
}

function MiniMetric({ label, value, icon }: { label: string; value: string; icon: ReactNode }) {
  return <div className="company-mini-metric"><span>{icon}{label}</span><strong>{value}</strong></div>;
}
function FinanceMetric({ label, value }: { label: string; value: string }) { return <div><span>{label}</span><strong>{value}</strong></div>; }
function InfoLine({ label, value }: { label: string; value: string }) { return <div className="company-info-line"><span>{label}</span><strong>{value}</strong></div>; }
function Field({ label, wide, children }: { label: string; wide?: boolean; children: ReactNode }) { return <label className={`company-field ${wide ? "company-field-wide" : ""}`}><span>{label}</span>{children}</label>; }

function companyFormFrom(company: JsonRow) {
  return {
    name: str(company.name, ""), legal_name: str(company.legal_name, ""), ruc: str(company.ruc || company.tax_id, ""), business_type: str(company.business_type, ""),
    email: str(company.email, ""), phone: str(company.phone, ""), website: str(company.website, ""), city: str(company.city, "Panamá"), address: str(company.address, ""),
    contact_name: str(company.contact_name, ""), contact_email: str(company.contact_email, ""), contact_phone: str(company.contact_phone, ""),
    billing_email: str(company.billing_email, ""), billing_phone: str(company.billing_phone, ""), billing_address: str(company.billing_address, ""),
    billing_mode: str(company.billing_mode, "per_booking"), billing_cycle: str(company.billing_cycle, "monthly"), payment_terms_days: String(num(company.payment_terms_days, 15)),
    requires_approval: bool(company.requires_approval, true), auto_approve_bookings: bool(company.auto_approve_bookings, false),
  };
}

function categoryLabel(value: string) {
  const key = value.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  if (key.includes("plomer")) return "Plomería";
  if (key.includes("exterior")) return "Limpieza exteriores";
  if (key.includes("limpieza")) return "Limpieza";
  return value || "Otra categoría";
}
function categoryBadgeClass(value: string) { const label = categoryLabel(value); return label === "Limpieza" ? "cyan" : label === "Plomería" ? "yellow" : label === "Limpieza exteriores" ? "green" : ""; }
function companyRoleLabel(value: string) { const key = value.toLowerCase(); return key.includes("admin") || key === "admin_empresa" ? "Admin Empresa" : key.includes("finanzas") ? "Finanzas" : key.includes("supervisor") ? "Supervisor" : "Personal Empresa"; }
function str(value: unknown, fallback = "—") { const out = value === null || value === undefined ? "" : String(value).trim(); return out && out !== "null" && out !== "undefined" ? out : fallback; }
function num(value: unknown, fallback = 0) { const parsed = Number(value); return Number.isFinite(parsed) ? parsed : fallback; }
function bool(value: unknown, fallback = false) { if (typeof value === "boolean") return value; if (value === "true" || value === 1 || value === "1") return true; if (value === "false" || value === 0 || value === "0") return false; return fallback; }
function shortId(value: string) { if (!value || value === "—") return "—"; return value.length > 10 ? `${value.slice(0, 8)}…` : value; }
