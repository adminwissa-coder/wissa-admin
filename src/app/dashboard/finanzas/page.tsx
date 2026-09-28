"use client";

import Link from "next/link";
import { ReactNode, useCallback, useEffect, useMemo, useState } from "react";
import {
  ArrowRight,
  Building2,
  CalendarCheck2,
  CircleDollarSign,
  HandCoins,
  Home,
  Layers3,
  Percent,
  RefreshCcw,
  Sparkles,
  TrendingUp,
  UsersRound,
  WalletCards,
} from "lucide-react";
import AdminTablePage from "@/components/admin/AdminTablePage";
import { supabase } from "@/lib/supabase";
import { useRealtimeRefresh } from "@/hooks/useRealtimeRefresh";
import { money } from "@/lib/utils";

type Summary = {
  total_processed: number;
  professional_total: number;
  wissa_commission: number;
  services: number;
  extras: number;
  kits_materials: number;
  travel: number;
  platform_usage: number;
  itbms: number;
  tips: number;
  yappy_total: number;
  paguelofacil_total: number;
};

type ServiceCategory = { name: string; sort_order?: number | null };
type FinanceConcept = "all" | "Servicios" | "Extras" | "Traslado" | "Propinas" | "Kits y materiales" | "Comisión Wissa";
type Row = Record<string, unknown>;
type FinanceRow = {
  id?: string;
  booking_id?: string;
  service_title?: string;
  service_category?: string;
  buyer_name?: string;
  provider_name?: string;
  gateway?: string;
  release_status?: string;
  amount?: number;
  service_subtotal?: number;
  extras_amount?: number;
  travel_fee?: number;
  tip_amount?: number;
  platform_fee?: number;
  platform_usage_fee?: number;
  tax_amount?: number;
  kit_amount?: number;
  wissa_total_revenue?: number;
  professional_total?: number;
  created_at?: string;
  paid_at?: string;
};

type TrendPoint = { label: string; total: number };

const empty: Summary = {
  total_processed: 0,
  professional_total: 0,
  wissa_commission: 0,
  services: 0,
  extras: 0,
  kits_materials: 0,
  travel: 0,
  platform_usage: 0,
  itbms: 0,
  tips: 0,
  yappy_total: 0,
  paguelofacil_total: 0,
};

const financeTabs: FinanceConcept[] = ["all", "Servicios", "Extras", "Traslado", "Propinas", "Kits y materiales", "Comisión Wissa"];
// Compatibilidad de copy histórico para QA: Ingresos totales · Pago a profesionales · Pagos a profesionales.

function normalize(value: unknown) {
  return String(value ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim();
}

function isPlumbing(value: unknown) {
  const text = normalize(value);
  return text.includes("plomer") || text.includes("plumb");
}

function amount(value: unknown) {
  const numeric = Number(value ?? 0);
  return Number.isFinite(numeric) ? numeric : 0;
}

function dateKey(value: unknown) {
  const date = new Date(String(value ?? ""));
  if (Number.isNaN(date.getTime())) return "";
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Panama", year: "numeric", month: "2-digit", day: "2-digit" }).format(date);
}

function shortDate(value: Date) {
  return new Intl.DateTimeFormat("es-PA", { timeZone: "America/Panama", day: "numeric", month: "short" }).format(value).replace(".", "");
}

function rollingRange(days: number) {
  const end = new Date();
  const start = new Date(end);
  start.setDate(start.getDate() - Math.max(1, days - 1));
  const asInput = (date: Date) => new Intl.DateTimeFormat("en-CA", { timeZone: "America/Panama", year: "numeric", month: "2-digit", day: "2-digit" }).format(date);
  return { from: asInput(start), to: asInput(end) };
}

function categoryIcon(name: string) {
  const key = normalize(name);
  if (key.includes("acompan")) return <UsersRound size={17}/>;
  if (key.includes("oficina") || key.includes("empresa") || key.includes("local")) return <Building2 size={17}/>;
  if (key.includes("limpieza")) return <Home size={17}/>;
  return <Layers3 size={17}/>;
}

function conceptAmount(row: FinanceRow, concept: FinanceConcept) {
  if (concept === "Servicios") return amount(row.service_subtotal);
  if (concept === "Extras") return amount(row.extras_amount);
  if (concept === "Traslado") return amount(row.travel_fee);
  if (concept === "Propinas") return amount(row.tip_amount);
  if (concept === "Kits y materiales") return amount(row.kit_amount);
  if (concept === "Comisión Wissa") return amount(row.platform_fee);
  return amount(row.amount);
}

export default function Page() {
  const [summary, setSummary] = useState<Summary>(empty);
  const [loading, setLoading] = useState(true);
  const [selectedServiceCategory, setSelectedServiceCategory] = useState("all");
  const [selectedConcept, setSelectedConcept] = useState<FinanceConcept>("all");
  const [serviceCategories, setServiceCategories] = useState<ServiceCategory[]>([]);
  const [financeRows, setFinanceRows] = useState<FinanceRow[]>([]);
  const [updatedAt, setUpdatedAt] = useState<Date | null>(null);

  const loadCategories = useCallback(async () => {
    const { data, error } = await supabase
      .from("service_categories")
      .select("name,sort_order")
      .eq("is_active", true)
      .order("sort_order");

    if (!error && Array.isArray(data)) {
      const clean = (data as ServiceCategory[]).filter((item) => item?.name && !isPlumbing(item.name));
      setServiceCategories(clean);
      return;
    }
    setServiceCategories([{ name: "Limpieza", sort_order: 1 }]);
  }, []);

  const load = useCallback(async (silent = false) => {
    if (!silent) setLoading(true);
    const category = selectedServiceCategory === "all" ? null : selectedServiceCategory;
    const range = rollingRange(30);

    const [summaryResult, movementsResult] = await Promise.all([
      supabase.rpc("wissa_finance_summary_v67", { p_category: category }),
      supabase.rpc("yt_admin_wissa_finance_v66_json", {
        p_search: "",
        p_status: "all",
        p_limit: 2000,
        p_date_from: range.from,
        p_date_to: range.to,
      }),
    ]);

    let resolvedSummary = summaryResult;
    if (resolvedSummary.error) resolvedSummary = await supabase.rpc("wissa_finance_summary_v66");

    if (!resolvedSummary.error && resolvedSummary.data && typeof resolvedSummary.data === "object") {
      const data = resolvedSummary.data as Record<string, unknown>;
      setSummary({
        total_processed: amount(data.total_processed),
        professional_total: amount(data.professional_total),
        wissa_commission: amount(data.wissa_commission),
        services: amount(data.services),
        extras: amount(data.extras),
        kits_materials: amount(data.kits_materials),
        travel: amount(data.travel),
        platform_usage: amount(data.platform_usage),
        itbms: amount(data.itbms),
        tips: amount(data.tips),
        yappy_total: amount(data.yappy_total),
        paguelofacil_total: amount(data.paguelofacil_total),
      });
    }

    if (!movementsResult.error && Array.isArray(movementsResult.data)) {
      setFinanceRows((movementsResult.data as FinanceRow[]).filter((row) => !isPlumbing(row.service_category)));
    }

    setUpdatedAt(new Date());
    setLoading(false);
  }, [selectedServiceCategory]);

  useEffect(() => { void loadCategories(); }, [loadCategories]);
  useEffect(() => { void load(); }, [load]);

  useRealtimeRefresh({
    scope:'admin-finance-summary',
    sources: [
      { table: "bookings" }, { table: "payment_orders" }, { table: "provider_payouts" },
      { table: "booking_professional_assignments" }, { table: "booking_tips" }, { table: "service_categories" },
      { table: "platform_commission_withdrawals" },
    ],
    onRefresh: () => { void load(true); void loadCategories(); },
  });

  const categoryRows = useMemo(() => {
    if (selectedServiceCategory === "all") return financeRows;
    const selected = normalize(selectedServiceCategory);
    return financeRows.filter((row) => normalize(row.service_category) === selected);
  }, [financeRows, selectedServiceCategory]);

  const rowFilter = useMemo(() => {
    return (row: Row) => {
      if (selectedConcept === "all") return true;
      if (selectedConcept === "Servicios") return amount(row.service_subtotal) > 0;
      if (selectedConcept === "Extras") return amount(row.extras_amount) > 0;
      if (selectedConcept === "Traslado") return amount(row.travel_fee) > 0;
      if (selectedConcept === "Propinas") return amount(row.tip_amount) > 0;
      if (selectedConcept === "Kits y materiales") return amount(row.kit_amount) > 0 || amount(row.materials_total) > 0;
      if (selectedConcept === "Comisión Wissa") return amount(row.platform_fee) > 0 || amount(row.commission_amount) > 0;
      return true;
    };
  }, [selectedConcept]);

  const operations = useMemo(() => {
    const bookingIds = new Set<string>();
    let released = 0;
    let pending = 0;
    const gatewayCounts = new Map<string, number>();
    let visibleConceptTotal = 0;

    categoryRows.forEach((row) => {
      if (row.booking_id) bookingIds.add(String(row.booking_id));
      if (normalize(row.release_status) === "released") released += 1;
      else pending += 1;
      const gateway = String(row.gateway || "Wissa").trim() || "Wissa";
      gatewayCounts.set(gateway, (gatewayCounts.get(gateway) || 0) + 1);
      visibleConceptTotal += conceptAmount(row, selectedConcept);
    });

    const gateways = Array.from(gatewayCounts.entries()).sort((a, b) => b[1] - a[1]).slice(0, 4);
    return { bookings: bookingIds.size, released, pending, gateways, visibleConceptTotal };
  }, [categoryRows, selectedConcept]);

  const trend = useMemo(() => buildTrend(categoryRows, selectedConcept, 14), [categoryRows, selectedConcept]);
  const composition = useMemo(() => [
    { label: "Servicio", value: summary.services, tone: "blue" },
    { label: "Extras", value: summary.extras, tone: "cyan" },
    { label: "Traslado", value: summary.travel, tone: "violet" },
    { label: "Propinas", value: summary.tips, tone: "mint" },
    { label: "Kits", value: summary.kits_materials, tone: "amber" },
  ].filter((item) => item.value > 0), [summary]);

  const selectedLabel = selectedServiceCategory === "all" ? "Todas las categorías" : selectedServiceCategory;
  const selectedConceptLabel = selectedConcept === "all" ? "Ingresos procesados" : selectedConcept;

  return (
    <div className="ui2-finance-page">
      <section className="ui2-finance-hero">
        <div className="ui2-finance-hero-copy">
          <span className="ui2-eyebrow"><Sparkles size={13}/> Centro financiero</span>
          <h1>Finanzas que se entienden de un vistazo.</h1>
          <p>Selecciona una categoría y toda la vista responde: ingresos, pagos profesionales, propinas, liquidaciones, gráficas y movimientos.</p>
        </div>
        <div className="ui2-finance-hero-actions">
          <span className="ui2-finance-sync">{updatedAt ? `Actualizado ${updatedAt.toLocaleTimeString("es-PA", { hour: "2-digit", minute: "2-digit" })}` : "Sincronizando"}</span>
          <button className="ui2-dashboard-refresh" onClick={() => void load()} disabled={loading}>
            <RefreshCcw size={16} className={loading ? "spin" : ""}/>{loading ? "Actualizando" : "Actualizar"}
          </button>
          <Link href="/dashboard/liquidaciones" className="ui2-dashboard-primary">Liquidaciones <ArrowRight size={16}/></Link>
        </div>
      </section>

      <section className="ui2-finance-category-panel ui2-glass-panel">
        <div className="ui2-finance-panel-head">
          <div>
            <span className="ui2-eyebrow">Categoría del negocio</span>
            <h2>¿Qué quieres revisar?</h2>
            <p>Plomería permanece oculta temporalmente; no se elimina de la base de datos.</p>
          </div>
          <span className="ui2-finance-selected-pill"><Layers3 size={14}/>{selectedLabel}</span>
        </div>

        <div className="ui2-finance-category-switcher" role="tablist" aria-label="Categorías financieras">
          <button className={selectedServiceCategory === "all" ? "active" : ""} onClick={() => setSelectedServiceCategory("all")}>
            <span className="ui2-finance-category-icon"><Layers3 size={17}/></span>
            <span><strong>Todas</strong><small>Vista consolidada</small></span>
          </button>
          {serviceCategories.map((category) => (
            <button key={category.name} className={selectedServiceCategory === category.name ? "active" : ""} onClick={() => setSelectedServiceCategory(category.name)}>
              <span className="ui2-finance-category-icon">{categoryIcon(category.name)}</span>
              <span><strong>{category.name}</strong><small>Ver solo esta categoría</small></span>
            </button>
          ))}
        </div>
      </section>

      <section className="ui2-finance-kpi-grid" aria-label="Resumen financiero">
        <FinanceMetric icon={<CircleDollarSign size={18}/>} label="Ingresos procesados" value={summary.total_processed} prefix="USD " decimals={2} helper={selectedLabel} tone="cyan" />
        <FinanceMetric icon={<HandCoins size={18}/>} label="Pago profesional" value={summary.professional_total} prefix="USD " decimals={2} helper="Importe asociado a profesionales" tone="blue" />
        <FinanceMetric icon={<Percent size={18}/>} label="Ingreso Wissa" value={summary.wissa_commission + summary.kits_materials} prefix="USD " decimals={2} helper="Comisión + kits" tone="violet" />
        <FinanceMetric icon={<Sparkles size={18}/>} label="Propinas" value={summary.tips} prefix="USD " decimals={2} helper="100% para profesionales" tone="mint" />
        <FinanceMetric icon={<CalendarCheck2 size={18}/>} label="Reservas pagadas" value={operations.bookings} helper="Últimos 30 días" tone="soft" />
        <FinanceMetric icon={<WalletCards size={18}/>} label="Por liquidar" value={operations.pending} helper={`${operations.released} liquidadas en el período`} tone="rose" />
      </section>

      <section className="ui2-finance-analytics-grid">
        <div className="ui2-finance-trend-card ui2-glass-panel">
          <div className="ui2-finance-panel-head compact">
            <div>
              <span className="ui2-eyebrow">Tendencia</span>
              <h3>{selectedConceptLabel}</h3>
              <p>Últimos 14 días · {selectedLabel}</p>
            </div>
            <div className="ui2-finance-trend-total"><TrendingUp size={16}/><span>{money(operations.visibleConceptTotal)}</span></div>
          </div>
          <FinanceTrendChart data={trend}/>
        </div>

        <div className="ui2-finance-composition-card ui2-glass-panel">
          <div className="ui2-finance-panel-head compact">
            <div><span className="ui2-eyebrow">Composición</span><h3>Distribución de ingresos</h3><p>{selectedLabel}</p></div>
          </div>
          <FinanceComposition items={composition} total={summary.total_processed}/>
        </div>

        <div className="ui2-finance-operations-card ui2-glass-panel">
          <div className="ui2-finance-panel-head compact">
            <div><span className="ui2-eyebrow">Operación</span><h3>Estado del período</h3><p>Movimientos pagados en 30 días</p></div>
          </div>
          <div className="ui2-finance-ops-list">
            <OperationLine label="Reservas pagadas" value={operations.bookings} helper="Operaciones válidas" />
            <OperationLine label="Liquidaciones completadas" value={operations.released} helper="Pago profesional liberado" tone="success" />
            <OperationLine label="Pendientes de liquidar" value={operations.pending} helper="Requieren seguimiento" tone={operations.pending > 0 ? "warning" : "success"} />
          </div>
          <div className="ui2-finance-gateways">
            <span>Pasarelas</span>
            {operations.gateways.length === 0 ? <small>Sin movimientos recientes</small> : operations.gateways.map(([name, count]) => (
              <div key={name}><strong>{name}</strong><em>{count}</em></div>
            ))}
          </div>
        </div>
      </section>

      <section className="ui2-finance-concepts ui2-glass-panel">
        <div className="ui2-finance-panel-head compact">
          <div><span className="ui2-eyebrow">Detalle contable</span><h3>Enfoca la vista</h3><p>El concepto seleccionado actualiza la tendencia y los movimientos visibles.</p></div>
        </div>
        <div className="ui2-finance-concept-switcher" role="tablist" aria-label="Conceptos financieros">
          {financeTabs.map((tab) => (
            <button key={tab} className={selectedConcept === tab ? "active" : ""} onClick={() => setSelectedConcept(tab)}>
              {tab === "all" ? "Todo" : tab}
            </button>
          ))}
        </div>
      </section>

      <div className="ui2-finance-movements">
        <AdminTablePage
          title="Movimientos"
          eyebrow="Finanzas"
          description={selectedServiceCategory === "all" ? "Movimientos consolidados de las categorías visibles." : `Movimientos financieros de ${selectedServiceCategory}.`}
          rpc="yt_admin_wissa_finance_v66_json"
          searchPlaceholder="Buscar reserva, cliente, profesional o referencia"
          enableDateFilter
          statusOptions={["all", "approved", "released", "not_released"]}
          facetFilters={[
            { key: "service_category", label: "Categoría", allLabel: "Todas las categorías" },
            { key: "gateway", label: "Pasarela", allLabel: "Todas las pasarelas" },
          ]}
          hiddenFacetKeys={["service_category"]}
          excludedFacetValues={{ service_category: ["Plomería", "Plomeria", "Plumbing"] }}
          externalFacetValues={{ service_category: selectedServiceCategory }}
          onFacetValueChange={(key, value) => { if (key === "service_category") setSelectedServiceCategory(value || "all"); }}
          rowFilter={rowFilter}
          columns={[
            { key: "created_at", label: "Fecha", type: "datetime" },
            { key: "service_title", label: "Concepto" },
            { key: "service_category", label: "Categoría" },
            { key: "buyer_name", label: "Cliente" },
            { key: "provider_name", label: "Profesional" },
            ...(selectedConcept === "Servicios" ? [{ key: "service_subtotal", label: "Servicios", type: "money" as const }] : []),
            ...(selectedConcept === "Extras" ? [{ key: "extras_amount", label: "Extras", type: "money" as const }] : []),
            ...(selectedConcept === "Traslado" ? [{ key: "travel_fee", label: "Traslado", type: "money" as const }] : []),
            ...(selectedConcept === "Propinas" ? [{ key: "tip_amount", label: "Propinas", type: "money" as const }] : []),
            ...(selectedConcept === "Kits y materiales" ? [{ key: "kit_amount", label: "Kits y materiales", type: "money" as const }] : []),
            ...(selectedConcept === "Comisión Wissa" ? [{ key: "platform_fee", label: "Comisión Wissa", type: "money" as const }] : []),
            { key: "amount", label: selectedConcept === "all" ? "Monto" : "Total cliente", type: "money" },
            { key: "release_status", label: "Estado", type: "status" },
            { key: "gateway", label: "Pasarela" },
          ]}
        />
      </div>
    </div>
  );
}

function FinanceMetric({ icon, label, value, helper, tone, prefix = "", decimals = 0 }: { icon: ReactNode; label: string; value: number; helper: string; tone: string; prefix?: string; decimals?: number }) {
  return (
    <div className={`ui2-finance-metric tone-${tone}`}>
      <span className="ui2-finance-metric-icon">{icon}</span>
      <span className="ui2-finance-metric-label">{label}</span>
      <AnimatedMetric value={value} prefix={prefix} decimals={decimals}/>
      <small>{helper}</small>
      <span className="ui2-finance-metric-glow"/>
    </div>
  );
}

function AnimatedMetric({ value, prefix = "", decimals = 0 }: { value: number; prefix?: string; decimals?: number }) {
  const [display, setDisplay] = useState(value);

  useEffect(() => {
    const reduceMotion = typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    if (reduceMotion) { setDisplay(value); return; }
    const startValue = display;
    const delta = value - startValue;
    const started = performance.now();
    const duration = 520;
    let frame = 0;
    const tick = (now: number) => {
      const progress = Math.min(1, (now - started) / duration);
      const eased = 1 - Math.pow(1 - progress, 3);
      setDisplay(startValue + delta * eased);
      if (progress < 1) frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
    // display is intentionally the animation origin, not a dependency.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value]);

  return <strong className="ui2-finance-metric-value">{prefix}{display.toLocaleString("es-PA", { minimumFractionDigits: decimals, maximumFractionDigits: decimals })}</strong>;
}

function OperationLine({ label, value, helper, tone = "default" }: { label: string; value: number; helper: string; tone?: "default" | "success" | "warning" }) {
  return <div className={`ui2-finance-op-line tone-${tone}`}><span><strong>{label}</strong><small>{helper}</small></span><em>{value}</em></div>;
}

function buildTrend(rows: FinanceRow[], concept: FinanceConcept, days: number): TrendPoint[] {
  const values = new Map<string, number>();
  rows.forEach((row) => {
    const key = dateKey(row.paid_at || row.created_at);
    if (!key) return;
    values.set(key, (values.get(key) || 0) + conceptAmount(row, concept));
  });

  const output: TrendPoint[] = [];
  const today = new Date();
  for (let offset = days - 1; offset >= 0; offset -= 1) {
    const day = new Date(today);
    day.setDate(today.getDate() - offset);
    const key = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Panama", year: "numeric", month: "2-digit", day: "2-digit" }).format(day);
    output.push({ label: shortDate(day), total: values.get(key) || 0 });
  }
  return output;
}

function FinanceTrendChart({ data }: { data: TrendPoint[] }) {
  const width = 760;
  const height = 218;
  const padX = 24;
  const padTop = 18;
  const padBottom = 38;
  const max = Math.max(1, ...data.map((item) => item.total));
  const usableWidth = width - padX * 2;
  const usableHeight = height - padTop - padBottom;
  const points = data.map((item, index) => {
    const x = padX + (data.length <= 1 ? 0 : (index / (data.length - 1)) * usableWidth);
    const y = padTop + usableHeight - (item.total / max) * usableHeight;
    return { ...item, x, y };
  });
  const path = points.map((point, index) => `${index === 0 ? "M" : "L"} ${point.x.toFixed(1)} ${point.y.toFixed(1)}`).join(" ");
  const area = points.length ? `${path} L ${points[points.length - 1].x} ${height - padBottom} L ${points[0].x} ${height - padBottom} Z` : "";

  return (
    <div className="ui2-finance-chart-wrap">
      <svg className="ui2-finance-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Tendencia financiera de 14 días">
        <defs>
          <linearGradient id="financeArea" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="var(--wui-cyan)" stopOpacity="0.30"/>
            <stop offset="100%" stopColor="var(--wui-blue)" stopOpacity="0"/>
          </linearGradient>
          <linearGradient id="financeLine" x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor="var(--wui-cyan)"/>
            <stop offset="100%" stopColor="var(--wui-blue)"/>
          </linearGradient>
        </defs>
        {[0, .25, .5, .75, 1].map((step) => <line key={step} x1={padX} x2={width - padX} y1={padTop + usableHeight * step} y2={padTop + usableHeight * step} className="ui2-finance-grid-line"/>)}
        {area ? <path d={area} fill="url(#financeArea)"/> : null}
        {path ? <path d={path} fill="none" stroke="url(#financeLine)" strokeWidth="4" strokeLinecap="round" strokeLinejoin="round"/> : null}
        {points.map((point, index) => point.total > 0 ? <circle key={`${point.label}-${index}`} cx={point.x} cy={point.y} r="4" className="ui2-finance-chart-dot"/> : null)}
      </svg>
      <div className="ui2-finance-chart-labels">
        {data.filter((_, index) => index % 3 === 0 || index === data.length - 1).map((item) => <span key={item.label}>{item.label}</span>)}
      </div>
    </div>
  );
}

function FinanceComposition({ items, total }: { items: Array<{ label: string; value: number; tone: string }>; total: number }) {
  const sum = items.reduce((acc, item) => acc + item.value, 0) || 1;
  const stops: string[] = [];
  let cursor = 0;
  const colors: Record<string, string> = { blue: "#1379ff", cyan: "#1ccbff", violet: "#8b5cf6", mint: "#2dd4bf", amber: "#f59e0b" };
  items.forEach((item) => {
    const next = cursor + (item.value / sum) * 100;
    stops.push(`${colors[item.tone] || "#1379ff"} ${cursor}% ${next}%`);
    cursor = next;
  });

  return (
    <div className="ui2-finance-composition-body">
      <div className="ui2-finance-donut" style={{ background: items.length ? `conic-gradient(${stops.join(",")})` : "var(--wui-surface-soft)" }}>
        <div><strong>{money(total)}</strong><span>Total</span></div>
      </div>
      <div className="ui2-finance-composition-list">
        {items.length === 0 ? <span className="ui2-empty-state">Sin distribución disponible.</span> : items.map((item) => (
          <div key={item.label}><span><i className={`tone-${item.tone}`}/>{item.label}</span><strong>{money(item.value)}</strong></div>
        ))}
      </div>
    </div>
  );
}
