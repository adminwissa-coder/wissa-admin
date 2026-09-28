"use client";

import Link from "next/link";
import { ReactNode, useCallback, useEffect, useMemo, useState } from "react";
import {
  ArrowRight,
  BellRing,
  CalendarDays,
  CheckCircle2,
  CircleDollarSign,
  Clock3,
  HandCoins,
  Layers3,
  RefreshCcw,
  Sparkles,
  UserRoundCheck,
  UsersRound,
  WalletCards,
} from "lucide-react";
import { supabase } from "@/lib/supabase";
import { useRealtimeRefresh } from "@/hooks/useRealtimeRefresh";
import { AnimatedCounter } from "@/components/ui/animated-counter";
import { money, statusLabel } from "@/lib/utils";

type Summary = {
  bookings?: number;
  bookings_total?: number;
  users?: number;
  companies?: number;
  active_services?: number;
  approved_amount?: number;
  approved_payments?: number;
  pending_payments?: number;
  release_pending?: number;
  admin_notifications_pending?: number;
  platform_commission?: number;
  platform_commission_pending?: number;
};

type BookingRow = Record<string, unknown>;
type FinanceRow = {
  id?: string;
  booking_id?: string;
  service_title?: string;
  service_category?: string;
  buyer_name?: string;
  provider_name?: string;
  amount?: number;
  service_subtotal?: number;
  extras_amount?: number;
  travel_fee?: number;
  tip_amount?: number;
  platform_fee?: number;
  kit_amount?: number;
  wissa_total_revenue?: number;
  professional_total?: number;
  release_status?: string;
  created_at?: string;
  paid_at?: string;
};

type ServiceCategory = { name: string; sort_order?: number | null };

type BreakdownItem = {
  label: string;
  value: number;
  tone: "blue" | "cyan" | "violet" | "mint" | "soft";
};

const categoryTones: BreakdownItem["tone"][] = ["blue", "cyan", "violet", "mint", "soft"];

export default function Dashboard() {
  const [summary, setSummary] = useState<Summary>({});
  const [professionals, setProfessionals] = useState(0);
  const [recent, setRecent] = useState<BookingRow[]>([]);
  const [financeRows, setFinanceRows] = useState<FinanceRow[]>([]);
  const [categories, setCategories] = useState<ServiceCategory[]>([]);
  const [selectedCategory, setSelectedCategory] = useState("all");
  const [loading, setLoading] = useState(true);
  const [updatedAt, setUpdatedAt] = useState<Date | null>(null);

  const load = useCallback(async (silent = false) => {
    if (!silent) setLoading(true);
    const { from, to } = rollingDateRange(30);

    const [summaryResult, providersResult, bookingsResult, financeResult, categoriesResult] = await Promise.all([
      supabase.rpc("yt_admin_dashboard_summary"),
      supabase.rpc("yt_admin_provider_count_v74"),
      supabase.rpc("yt_admin_bookings_v66_json", {
        p_search: "",
        p_status: "all",
        p_limit: 160,
        p_date_from: null,
        p_date_to: null,
      }),
      supabase.rpc("yt_admin_wissa_finance_v66_json", {
        p_search: "",
        p_status: "all",
        p_limit: 1200,
        p_date_from: from,
        p_date_to: to,
      }),
      supabase.from("service_categories").select("name,sort_order").eq("is_active", true).order("sort_order"),
    ]);

    if (!summaryResult.error && summaryResult.data) setSummary(summaryResult.data as Summary);
    if (!providersResult.error) setProfessionals(Number(providersResult.data ?? 0));
    if (!bookingsResult.error && Array.isArray(bookingsResult.data)) setRecent(bookingsResult.data as BookingRow[]);
    if (!financeResult.error && Array.isArray(financeResult.data)) setFinanceRows(financeResult.data as FinanceRow[]);
    if (!categoriesResult.error && Array.isArray(categoriesResult.data)) {
      setCategories((categoriesResult.data as ServiceCategory[]).filter((item) => item?.name && !isPlumbing(item.name)));
    }

    setUpdatedAt(new Date());
    setLoading(false);
  }, []);

  useEffect(() => { void load(); }, [load]);

  useRealtimeRefresh({
    scope: "admin-dashboard",
    sources: [
      { table: "bookings" },
      { table: "booking_professional_assignments" },
      { table: "payment_orders" },
      { table: "provider_payouts" },
      { table: "booking_tips" },
      { table: "booking_tip_allocations" },
      { table: "services" },
      { table: "profiles" },
      { table: "service_categories" },
      { table: "platform_commission_withdrawals" },
    ],
    onRefresh: () => void load(true),
  });

  const visibleFinance = useMemo(() => {
    if (selectedCategory === "all") return financeRows.filter((row) => !isPlumbing(row.service_category));
    const wanted = normalize(selectedCategory);
    return financeRows.filter((row) => normalize(row.service_category) === wanted);
  }, [financeRows, selectedCategory]);

  const finance = useMemo(() => aggregateFinance(visibleFinance), [visibleFinance]);
  const categoryStats = useMemo(() => buildCategoryStats(financeRows, categories), [financeRows, categories]);
  const chart = useMemo(() => buildRevenueChart(visibleFinance, 14), [visibleFinance]);
  const breakdown = useMemo<BreakdownItem[]>(() => {
    if (selectedCategory === "all") {
      return categoryStats
        .filter((item) => item.revenue > 0)
        .slice(0, 5)
        .map((item, index) => ({ label: item.name, value: item.revenue, tone: categoryTones[index % categoryTones.length] }));
    }
    return [
      { label: "Servicio", value: finance.service, tone: "blue" },
      { label: "Extras", value: finance.extras, tone: "cyan" },
      { label: "Traslado", value: finance.travel, tone: "violet" },
      { label: "Propinas", value: finance.tips, tone: "mint" },
      { label: "Comisión Wissa", value: finance.commission, tone: "soft" },
    ].filter((item) => item.value > 0) as BreakdownItem[];
  }, [selectedCategory, categoryStats, finance]);

  const lastRows = recent.slice(0, 6);
  const reservationChart = useMemo(() => buildBookingChart(recent, 7), [recent]);
  const selectedCategoryLabel = selectedCategory === "all" ? "Todas las categorías" : selectedCategory;
  const todayLabel = useMemo(() => new Intl.DateTimeFormat("es-PA", {
    weekday: "long",
    day: "2-digit",
    month: "long",
    year: "numeric",
  }).format(new Date()), []);
  const sideRows = lastRows.slice(0, 4);

  return (
    <div className="ui2-dashboard">
      <section className="ui2-dashboard-hero v70-dashboard-hero">
        <div className="ui2-dashboard-intro">
          <span className="ui2-eyebrow"><Sparkles size={13}/> Panel ejecutivo Wissa</span>
          <h1>Tu operación, clara y en movimiento.</h1>
          <p>Reservas, profesionales y finanzas conectados en una vista ejecutiva con datos reales de Wissa.</p>
        </div>
        <div className="v70-dashboard-hero-side">
          <div className="v70-today-card"><CalendarDays size={17}/><div><small>Hoy</small><strong>{todayLabel}</strong></div></div>
          <div className="ui2-dashboard-actions">
            <button className="ui2-dashboard-refresh" onClick={() => void load()} disabled={loading}>
              <RefreshCcw size={16} className={loading ? "spin" : ""}/>
              {loading ? "Actualizando" : "Actualizar"}
            </button>
            <Link href="/dashboard/reservas" className="ui2-dashboard-primary">Ver reservas <ArrowRight size={16}/></Link>
          </div>
        </div>
      </section>

      <section className="ui2-kpi-grid" aria-label="Resumen operativo">
        <MetricCard
          icon={<CircleDollarSign size={19}/>}
          label="Ingresos procesados"
          value={summary.approved_amount ?? 0}
          format="money"
          helper="Pagos aprobados"
          tone="cyan"
        />
        <MetricCard
          icon={<CalendarDays size={19}/>}
          label="Reservas activas"
          value={summary.bookings ?? 0}
          helper={`${summary.bookings_total ?? 0} registradas en total`}
          tone="blue"
          chart={reservationChart}
        />
        <MetricCard
          icon={<HandCoins size={19}/>}
          label="Por liquidar"
          value={summary.release_pending ?? 0}
          helper="Servicios completados pendientes"
          tone="violet"
        />
        <MetricCard
          icon={<UserRoundCheck size={19}/>}
          label="Profesionales"
          value={professionals}
          helper="Perfiles registrados"
          tone="mint"
        />
        <MetricCard
          icon={<WalletCards size={19}/>}
          label="Pagos pendientes"
          value={summary.pending_payments ?? 0}
          helper="Órdenes por confirmar"
          tone="rose"
        />
      </section>

      <section className="ui2-dashboard-workspace">
        <div className="ui2-finance-command ui2-glass-panel">
          <div className="ui2-panel-title-row">
            <div>
              <span className="ui2-eyebrow">Finanzas</span>
              <h2>Rendimiento por categoría</h2>
              <p>Selecciona una categoría para ver su comportamiento financiero de los últimos 30 días.</p>
            </div>
            <Link href="/dashboard/finanzas" className="ui2-text-link">Abrir Finanzas <ArrowRight size={14}/></Link>
          </div>

          <div className="ui2-category-switcher" role="tablist" aria-label="Categoría del dashboard">
            <button className={selectedCategory === "all" ? "active" : ""} onClick={() => setSelectedCategory("all")}>Todas</button>
            {categories.map((category) => (
              <button key={category.name} className={selectedCategory === category.name ? "active" : ""} onClick={() => setSelectedCategory(category.name)}>
                {category.name}
              </button>
            ))}
          </div>

          <div className="ui2-finance-summary-strip">
            <div><span>Ingresos</span><strong>{money(finance.total)}</strong><small>{selectedCategoryLabel}</small></div>
            <div><span>Pago profesional</span><strong>{money(finance.professional)}</strong><small>Importe asociado</small></div>
            <div><span>Ingreso Wissa</span><strong>{money(finance.wissa)}</strong><small>Comisión + kits</small></div>
            <div><span>Propinas</span><strong>{money(finance.tips)}</strong><small>100% para profesionales</small></div>
          </div>

          <div className="ui2-finance-visual-grid">
            <div className="ui2-chart-card">
              <div className="ui2-chart-head">
                <div><span>Ingresos pagados</span><strong>Últimos 14 días</strong></div>
                <small>{financeRows.length ? "Datos sincronizados" : "Sin movimientos"}</small>
              </div>
              <RevenueLineChart data={chart}/>
            </div>

            <div className="ui2-distribution-card">
              <div className="ui2-chart-head">
                <div><span>Distribución</span><strong>{selectedCategory === "all" ? "Por categoría" : "Composición"}</strong></div>
              </div>
              <DistributionDonut items={breakdown}/>
            </div>
          </div>
        </div>

        <aside className="ui2-dashboard-side v70-dashboard-side">
          <div className="v70-recent-card ui2-glass-panel">
            <div className="ui2-panel-title-row compact">
              <div><span className="ui2-eyebrow">Actividad</span><h3>Movimiento reciente</h3></div>
              <Link href="/dashboard/reservas" className="ui2-text-link">Ver todas <ArrowRight size={14}/></Link>
            </div>
            <div className="v70-recent-list">
              {sideRows.length === 0 ? <div className="ui2-empty-state compact">Aún no hay actividad reciente.</div> : sideRows.map((row, index) => {
                const client = str(row.buyer_name) || "Cliente";
                const service = str(row.service_title) || "Servicio Wissa";
                const status = str(row.status_label || row.status) || "pending";
                return (
                  <Link href="/dashboard/reservas" className="v70-recent-row" key={str(row.id || row.booking_id) || index}>
                    <span className="v70-recent-avatar">{initials(client)}</span>
                    <span className="v70-recent-copy"><strong>{client}</strong><small>{service}</small></span>
                    <span className={`ui2-activity-status ${tone(status)}`}>{statusLabel(status)}</span>
                  </Link>
                );
              })}
            </div>
          </div>

          <div className="v70-live-card ui2-glass-panel">
            <span className="v70-live-icon"><CheckCircle2 size={20}/></span>
            <div><strong>Operación sincronizada</strong><p>Los módulos administrativos están conectados a los datos en tiempo real.</p></div>
            <span className="v70-live-pulse" aria-hidden="true"/>
          </div>
        </aside>
      </section>

      <section className="ui2-dashboard-lower-grid">
        <div className="ui2-category-panel ui2-glass-panel">
          <div className="ui2-panel-title-row compact">
            <div><span className="ui2-eyebrow">Categorías</span><h3>Actividad comercial</h3></div>
            <Link href="/dashboard/servicios" className="ui2-text-link">Ver servicios <ArrowRight size={14}/></Link>
          </div>
          <div className="ui2-category-cards">
            {categoryStats.length === 0 ? <div className="ui2-empty-state">Aún no hay categorías activas para mostrar.</div> : categoryStats.slice(0, 4).map((item, index) => (
              <button key={item.name} className="ui2-category-card" onClick={() => setSelectedCategory(item.name)}>
                <span className={`ui2-category-icon tone-${categoryTones[index % categoryTones.length]}`}><Layers3 size={18}/></span>
                <span className="ui2-category-copy"><strong>{item.name}</strong><small>{item.bookings} reservas pagadas · {money(item.revenue)}</small></span>
                <ArrowRight size={15}/>
              </button>
            ))}
          </div>
        </div>

        <div className="v70-operations-panel ui2-glass-panel">
          <div className="ui2-panel-title-row compact">
            <div><span className="ui2-eyebrow">Atención</span><h3>Estado operativo</h3></div>
            <BellRing size={18}/>
          </div>
          <div className="v70-status-stack">
            <StatusLine icon={<Clock3 size={15}/>} label="Pagos pendientes" value={summary.pending_payments ?? 0} href="/dashboard/finanzas" />
            <StatusLine icon={<HandCoins size={15}/>} label="Por liquidar" value={summary.release_pending ?? 0} href="/dashboard/liquidaciones" />
            <StatusLine icon={<BellRing size={15}/>} label="Notificaciones" value={summary.admin_notifications_pending ?? 0} href="/dashboard/notificaciones" />
          </div>
          <div className="v70-operation-note"><span className="ui2-live-dot"/><div><strong>Actualización automática</strong><small>Las cifras cambian cuando llegan nuevos movimientos.</small></div></div>
        </div>
      </section>

      <section className="ui2-quick-actions" aria-label="Accesos rápidos">
        <QuickAction href="/dashboard/reservas" icon={<CalendarDays size={18}/>} title="Reservas" copy="Gestiona solicitudes y estados" />
        <QuickAction href="/dashboard/ofrecer" icon={<UsersRound size={18}/>} title="Profesionales" copy="Perfiles, disponibilidad y documentos" />
        <QuickAction href="/dashboard/finanzas" icon={<CircleDollarSign size={18}/>} title="Finanzas" copy="Ingresos, comisiones y movimientos" />
        <QuickAction href="/dashboard/liquidaciones" icon={<CheckCircle2 size={18}/>} title="Liquidaciones" copy="Pagos y comprobantes" />
      </section>

      <div className="ui2-sync-note">
        <span className="ui2-live-dot"/> Datos sincronizados automáticamente
        {updatedAt ? <small>Última actualización {new Intl.DateTimeFormat("es-PA", { hour: "2-digit", minute: "2-digit" }).format(updatedAt)}</small> : null}
      </div>
    </div>
  );
}

function MetricCard({
  icon,
  label,
  value,
  helper,
  tone: cardTone,
  chart,
  format = "number",
}: {
  icon: ReactNode;
  label: string;
  value: number;
  helper: string;
  tone: string;
  chart?: Array<{ label: string; value: number }>;
  format?: "number" | "money";
}) {
  return (
    <article className={`ui2-metric-card tone-${cardTone}`}>
      <div className="ui2-metric-top"><span className="ui2-metric-icon">{icon}</span><span className="ui2-live-pill">En vivo</span></div>
      <span className="ui2-metric-label">{label}</span>
      <strong className="ui2-metric-value">
        <AnimatedCounter
          value={Number.isFinite(value) ? value : 0}
          decimals={format === "money" ? 2 : 0}
          prefix={format === "money" ? "$" : undefined}
          duration={0.7}
          separator=","
          decimalSeparator="."
          aria-label={format === "money" ? money(value) : String(value)}
        />
      </strong>
      <div className="ui2-metric-foot"><small>{helper}</small>{chart ? <MiniSparkline data={chart}/> : <span className="ui2-metric-pulse"/>}</div>
    </article>
  );
}

function MiniSparkline({ data }: { data: Array<{ label: string; value: number }> }) {
  const values = data.map((item) => item.value);
  const max = Math.max(1, ...values);
  const points = values.map((value, index) => `${(index / Math.max(1, values.length - 1)) * 84},${28 - (value / max) * 22}`).join(" ");
  return <svg className="ui2-mini-spark" viewBox="0 0 84 30" role="img" aria-label="Tendencia de reservas"><polyline points={points}/></svg>;
}

function RevenueLineChart({ data }: { data: Array<{ label: string; value: number }> }) {
  const width = 760;
  const height = 230;
  const padX = 20;
  const padY = 22;
  const max = Math.max(1, ...data.map((item) => item.value));
  const usableWidth = width - padX * 2;
  const usableHeight = height - padY * 2;
  const points = data.map((item, index) => {
    const x = padX + (index / Math.max(1, data.length - 1)) * usableWidth;
    const y = padY + usableHeight - (item.value / max) * usableHeight;
    return { ...item, x, y };
  });
  const polyline = points.map((point) => `${point.x},${point.y}`).join(" ");
  const area = points.length ? `${padX},${height - padY} ${polyline} ${width - padX},${height - padY}` : "";

  return (
    <div className="v70-line-chart" aria-label="Ingresos de los últimos 14 días">
      <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Tendencia de ingresos pagados">
        <defs>
          <linearGradient id="wissaRevenueFill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="currentColor" stopOpacity="0.22"/>
            <stop offset="100%" stopColor="currentColor" stopOpacity="0"/>
          </linearGradient>
        </defs>
        <g className="v70-chart-grid-lines">
          {[0.2, 0.4, 0.6, 0.8].map((ratio) => <line key={ratio} x1={padX} x2={width-padX} y1={padY + usableHeight*ratio} y2={padY + usableHeight*ratio}/>) }
        </g>
        {area ? <polygon points={area} fill="url(#wissaRevenueFill)"/> : null}
        {polyline ? <polyline className="v70-revenue-line" points={polyline}/> : null}
        {points.map((point, index) => (
          <circle key={`${point.label}-${index}`} cx={point.x} cy={point.y} r={point.value > 0 ? 4.5 : 2.4}>
            <title>{point.label}: {money(point.value)}</title>
          </circle>
        ))}
      </svg>
      <div className="v70-chart-labels">
        {data.map((item, index) => <span key={`${item.label}-axis-${index}`}>{index % 3 === 0 || index === data.length - 1 ? item.label : ""}</span>)}
      </div>
    </div>
  );
}

function DistributionDonut({ items }: { items: BreakdownItem[] }) {
  const total = items.reduce((sum, item) => sum + item.value, 0);
  const gradient = buildDonutGradient(items, total);
  return (
    <div className="ui2-donut-wrap">
      <div className="ui2-donut" style={{ background: gradient }}>
        <div className="ui2-donut-center"><strong>{money(total)}</strong><span>Total</span></div>
      </div>
      <div className="ui2-donut-legend">
        {items.length === 0 ? <div className="ui2-empty-state compact">Sin movimientos para esta selección.</div> : items.map((item) => (
          <div key={item.label}><span className={`ui2-legend-dot tone-${item.tone}`}/><strong>{item.label}</strong><small>{total > 0 ? `${Math.round((item.value / total) * 100)}%` : "0%"}</small></div>
        ))}
      </div>
    </div>
  );
}

function StatusLine({ icon, label, value, href }: { icon: ReactNode; label: string; value: number; href: string }) {
  return <Link href={href} className="ui2-status-line"><span>{icon}</span><strong>{label}</strong><b>{value}</b><ArrowRight size={14}/></Link>;
}

function QuickAction({ href, icon, title, copy }: { href: string; icon: ReactNode; title: string; copy: string }) {
  return <Link href={href} className="ui2-quick-action"><span>{icon}</span><div><strong>{title}</strong><small>{copy}</small></div><ArrowRight size={15}/></Link>;
}

function aggregateFinance(rows: FinanceRow[]) {
  return rows.reduce((acc, row) => {
    acc.total += num(row.amount);
    acc.service += num(row.service_subtotal);
    acc.extras += num(row.extras_amount);
    acc.travel += num(row.travel_fee);
    acc.tips += num(row.tip_amount);
    acc.commission += num(row.platform_fee);
    acc.kits += num(row.kit_amount);
    acc.professional += num(row.professional_total);
    acc.wissa += num(row.wissa_total_revenue);
    return acc;
  }, { total: 0, service: 0, extras: 0, travel: 0, tips: 0, commission: 0, kits: 0, professional: 0, wissa: 0 });
}

function buildCategoryStats(rows: FinanceRow[], categories: ServiceCategory[]) {
  const map = new Map<string, { name: string; revenue: number; bookings: number }>();
  for (const category of categories) map.set(normalize(category.name), { name: category.name, revenue: 0, bookings: 0 });
  for (const row of rows) {
    const name = str(row.service_category) || "Otros";
    if (isPlumbing(name)) continue;
    const key = normalize(name);
    const current = map.get(key) ?? { name, revenue: 0, bookings: 0 };
    current.revenue += num(row.amount);
    current.bookings += 1;
    map.set(key, current);
  }
  return Array.from(map.values()).sort((a, b) => b.revenue - a.revenue || a.name.localeCompare(b.name));
}

function buildRevenueChart(rows: FinanceRow[], length: number) {
  const formatter = new Intl.DateTimeFormat("es-PA", { day: "2-digit", month: "short" });
  const days = Array.from({ length }, (_, idx) => {
    const date = new Date();
    date.setHours(0, 0, 0, 0);
    date.setDate(date.getDate() - (length - 1 - idx));
    return { key: localDateKey(date), label: formatter.format(date), value: 0 };
  });
  const map = new Map(days.map((item) => [item.key, item]));
  for (const row of rows) {
    const raw = row.paid_at || row.created_at;
    if (!raw) continue;
    const date = new Date(raw);
    if (Number.isNaN(date.getTime())) continue;
    const item = map.get(localDateKey(date));
    if (item) item.value += num(row.amount);
  }
  return days;
}

function buildBookingChart(rows: BookingRow[], length: number) {
  const formatter = new Intl.DateTimeFormat("es-PA", { day: "2-digit" });
  const days = Array.from({ length }, (_, idx) => {
    const date = new Date();
    date.setHours(0, 0, 0, 0);
    date.setDate(date.getDate() - (length - 1 - idx));
    return { key: localDateKey(date), label: formatter.format(date), value: 0 };
  });
  const map = new Map(days.map((item) => [item.key, item]));
  for (const row of rows) {
    const raw = str(row.booking_date || row.created_at);
    if (!raw) continue;
    const date = new Date(raw);
    if (Number.isNaN(date.getTime())) continue;
    const item = map.get(localDateKey(date));
    if (item) item.value += 1;
  }
  return days;
}

function buildDonutGradient(items: BreakdownItem[], total: number) {
  if (!items.length || total <= 0) return "conic-gradient(var(--wui-border) 0 100%)";
  let cursor = 0;
  const colors: Record<BreakdownItem["tone"], string> = {
    blue: "var(--wui-blue)",
    cyan: "var(--wui-cyan)",
    violet: "#8b5cf6",
    mint: "#20c997",
    soft: "#7b9cc6",
  };
  const parts = items.map((item) => {
    const start = cursor;
    cursor += (item.value / total) * 100;
    return `${colors[item.tone]} ${start}% ${cursor}%`;
  });
  return `conic-gradient(${parts.join(",")})`;
}

function rollingDateRange(days: number) {
  const to = new Date();
  const from = new Date();
  from.setDate(from.getDate() - Math.max(1, days - 1));
  return { from: localDateKey(from), to: localDateKey(to) };
}

function localDateKey(date: Date) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

function normalize(value: unknown) { return str(value).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase(); }
function isPlumbing(value: unknown) { const text = normalize(value); return text.includes("plomer") || text.includes("plumb"); }
function num(value: unknown) { const output = Number(value ?? 0); return Number.isFinite(output) ? output : 0; }
function str(value: unknown) { return String(value ?? "").trim(); }
function initials(value: string) { return value.split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase(); }
function tone(value: string) {
  const normalized = value.toLowerCase();
  if (/complet|pagad|aprob|finaliz|confirm/.test(normalized)) return "ok";
  if (/cancel|rechaz|fall/.test(normalized)) return "bad";
  if (/curso|camino|servicio|acept/.test(normalized)) return "info";
  return "neutral";
}
