"use client";

import { useCallback, useEffect, useMemo, useState, type ChangeEvent, type KeyboardEvent, type ReactNode } from "react";
import {
  Activity,
  CalendarCheck2,
  CalendarDays,
  CheckCircle2,
  ChevronDown,
  Clock3,
  Copy,
  Download,
  Eye,
  FileSpreadsheet,
  FileText,
  FilterX,
  Flag,
  HandCoins,
  MoreHorizontal,
  RefreshCcw,
  Search,
  Sparkles,
  WalletCards,
  X,
  XCircle,
} from "lucide-react";
import { AnimatedCounter } from "@/components/ui/animated-counter";
import { useRealtimeRefresh } from "@/hooks/useRealtimeRefresh";
import { adminMessage } from "@/lib/admin-copy";
import { supabase } from "@/lib/supabase";
import { formatPanamaDate, formatPanamaTime, money, statusLabel } from "@/lib/utils";
import styles from "./ReservationsPremiumPage.module.css";

type Row = Record<string, unknown>;
type StatusFilter = "all" | "pending" | "approved" | "paid" | "released" | "rejected" | "cancelled";

type RpcParams = {
  p_search: string;
  p_status: string;
  p_limit: number;
  p_date_from: string | null;
  p_date_to: string | null;
};

const statusFilters: Array<{ value: StatusFilter; label: string }> = [
  { value: "all", label: "Todas" },
  { value: "pending", label: "Pendientes" },
  { value: "approved", label: "Aprobadas" },
  { value: "paid", label: "Pagadas" },
  { value: "released", label: "Liquidadas" },
  { value: "rejected", label: "Rechazadas" },
  { value: "cancelled", label: "Canceladas" },
];

const pageSizes = [10, 20, 50];

export default function ReservationsPremiumPage() {
  const [rows, setRows] = useState<Row[]>([]);
  const [searchDraft, setSearchDraft] = useState("");
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState<StatusFilter>("all");
  const [category, setCategory] = useState("all");
  const [professional, setProfessional] = useState("all");
  const [client, setClient] = useState("all");
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [lastUpdatedAt, setLastUpdatedAt] = useState<Date | null>(null);
  const [selected, setSelected] = useState<Row | null>(null);
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(10);
  const [exportOpen, setExportOpen] = useState(false);
  const [notice, setNotice] = useState("");

  const load = useCallback(async (silent = false) => {
    if (!silent) setLoading(true);
    setError("");

    const params: RpcParams = {
      p_search: search,
      p_status: "all",
      p_limit: 200,
      p_date_from: dateFrom || null,
      p_date_to: dateTo || null,
    };

    const { data, error: rpcError } = await supabase.rpc("yt_admin_bookings_v66_json", params);

    if (rpcError) {
      setRows([]);
      setError(rpcError.message);
    } else {
      setRows(Array.isArray(data) ? (data as Row[]) : []);
      setLastUpdatedAt(new Date());
    }

    setLoading(false);
  }, [dateFrom, dateTo, search]);

  useEffect(() => {
    void load();
  }, [load]);

  useRealtimeRefresh({
    scope: "admin-reservations-premium",
    sources: [
      { table: "bookings" },
      { table: "booking_professional_assignments" },
      { table: "payment_orders" },
      { table: "provider_payouts" },
      { table: "booking_tips" },
      { table: "booking_tip_allocations" },
    ],
    onRefresh: () => void load(true),
  });

  useEffect(() => {
    setPage(1);
  }, [status, category, professional, client, search, dateFrom, dateTo, pageSize]);

  useEffect(() => {
    if (!notice) return;
    const timer = window.setTimeout(() => setNotice(""), 3600);
    return () => window.clearTimeout(timer);
  }, [notice]);

  const categories = useMemo(() => uniqueValues(rows, "service_category"), [rows]);
  const professionals = useMemo(() => uniqueValues(rows, "provider_name"), [rows]);
  const clients = useMemo(() => uniqueValues(rows, "buyer_name"), [rows]);

  const counts = useMemo(() => ({
    all: rows.length,
    pending: rows.filter((row) => matchesStatusFilter(row, "pending")).length,
    approved: rows.filter((row) => matchesStatusFilter(row, "approved")).length,
    paid: rows.filter((row) => matchesStatusFilter(row, "paid")).length,
    released: rows.filter((row) => matchesStatusFilter(row, "released")).length,
    rejected: rows.filter((row) => matchesStatusFilter(row, "rejected")).length,
    cancelled: rows.filter((row) => matchesStatusFilter(row, "cancelled")).length,
  }), [rows]);

  const visibleRows = useMemo(() => {
    return rows.filter((row) => {
      if (!matchesStatusFilter(row, status)) return false;
      if (category !== "all" && normalize(row.service_category) !== normalize(category)) return false;
      if (professional !== "all" && normalize(row.provider_name) !== normalize(professional)) return false;
      if (client !== "all" && normalize(row.buyer_name) !== normalize(client)) return false;
      return true;
    });
  }, [rows, status, category, professional, client]);

  const stats = useMemo(() => {
    const pending = rows.filter((row) => matchesStatusFilter(row, "pending")).length;
    const active = rows.filter(isActiveBooking).length;
    const releasePending = rows.filter(isReleasePending).length;
    const cancelled = rows.filter((row) => normalizedBookingStatus(row) === "cancelled").length;
    return { total: rows.length, pending, active, releasePending, cancelled };
  }, [rows]);

  const todayKey = useMemo(() => panamaDateKey(new Date()), []);
  const todayRows = useMemo(() => rows
    .filter((row) => rowDateKey(row) === todayKey)
    .sort((a, b) => asString(a.booking_time).localeCompare(asString(b.booking_time))), [rows, todayKey]);

  const paymentPending = useMemo(() => rows.filter((row) => {
    const payment = normalize(row.payment_status || row.payment_status_label);
    return payment.includes("pending") || payment.includes("pendiente") || payment.includes("failed") || payment.includes("fallido");
  }).length, [rows]);

  const totalPages = Math.max(1, Math.ceil(visibleRows.length / pageSize));
  const safePage = Math.min(page, totalPages);
  const pageRows = visibleRows.slice((safePage - 1) * pageSize, safePage * pageSize);

  function applySearch() {
    setSearch(searchDraft.trim());
  }

  function resetFilters() {
    setSearchDraft("");
    setSearch("");
    setStatus("all");
    setCategory("all");
    setProfessional("all");
    setClient("all");
    setDateFrom("");
    setDateTo("");
  }

  function copyReservation(row: Row) {
    const code = reservationCode(row);
    if (!code) return;
    void navigator.clipboard?.writeText(code);
    setNotice(`Reserva ${code} copiada.`);
  }

  function exportExcel() {
    if (!visibleRows.length) return;
    const headers = ["Reserva", "Cliente", "Servicio", "Categoría", "Fecha", "Hora", "Profesional", "Estado", "Pago", "Total"];
    const body = visibleRows.map((row) => [
      reservationCode(row),
      asString(row.buyer_name),
      asString(row.service_title),
      asString(row.service_category),
      formatPanamaDate(row.booking_date),
      bookingTime(row),
      asString(row.provider_name),
      bookingStatusLabel(row),
      paymentStatusLabel(row),
      money(row.amount),
    ]);
    const lines = [headers, ...body].map((line) => line.map(csvEscape).join("\t")).join("\n");
    downloadBlob(`wissa-reservas-${fileStamp()}.xls`, `\ufeff${lines}`, "application/vnd.ms-excel;charset=utf-8");
    setExportOpen(false);
  }

  function exportPdf() {
    if (!visibleRows.length) return;
    const frame = document.createElement("iframe");
    frame.style.position = "fixed";
    frame.style.width = "0";
    frame.style.height = "0";
    frame.style.border = "0";
    frame.style.opacity = "0";
    frame.title = "Exportación de reservas";
    document.body.appendChild(frame);
    const doc = frame.contentDocument;
    if (!doc || !frame.contentWindow) {
      frame.remove();
      return;
    }
    doc.open();
    doc.write(buildPrintHtml(visibleRows));
    doc.close();
    window.setTimeout(() => {
      frame.contentWindow?.focus();
      frame.contentWindow?.print();
      window.setTimeout(() => frame.remove(), 1200);
    }, 250);
    setExportOpen(false);
  }

  return (
    <div className={styles.page}>
      {notice ? <div className={styles.toast} role="status"><Sparkles size={16}/><span>{notice}</span><button onClick={() => setNotice("")} aria-label="Cerrar"><X size={15}/></button></div> : null}

      <section className={styles.hero}>
        <div>
          <div className={styles.eyebrow}>GESTIÓN Y SEGUIMIENTO</div>
          <h1>Reservas</h1>
          <p>Gestiona, filtra y supervisa todas las reservas en tiempo real.</p>
        </div>
        <div className={styles.heroActions}>
          <div className={styles.liveBlock}>
            <span className={styles.livePill}><i className={loading ? styles.syncing : ""}/> {loading ? "Sincronizando" : "Sincronizado en tiempo real"}</span>
            <small>{lastUpdatedAt ? `Última actualización: ${lastUpdatedAt.toLocaleTimeString("es-PA", { hour: "2-digit", minute: "2-digit" })}` : "Preparando datos"}</small>
          </div>
          <button className={styles.secondaryButton} type="button" onClick={() => void load()} disabled={loading}><RefreshCcw size={17} className={loading ? styles.spin : ""}/>{loading ? "Actualizando" : "Actualizar"}</button>
          <div className={styles.exportWrap}>
            <button className={styles.secondaryButton} type="button" onClick={() => setExportOpen((current) => !current)} disabled={!visibleRows.length}><Download size={17}/>Exportar<ChevronDown size={15}/></button>
            {exportOpen ? <div className={styles.exportMenu}><button onClick={exportExcel}><FileSpreadsheet size={16}/>Excel</button><button onClick={exportPdf}><FileText size={16}/>PDF / imprimir</button></div> : null}
          </div>
        </div>
      </section>

      <section className={styles.kpiGrid} aria-label="Resumen de reservas">
        <KpiCard tone="blue" icon={<CalendarDays size={21}/>} label="Total de reservas" value={stats.total} helper="Registros cargados" />
        <KpiCard tone="amber" icon={<Clock3 size={21}/>} label="Pendientes" value={stats.pending} helper="Requieren revisión" />
        <KpiCard tone="green" icon={<CheckCircle2 size={21}/>} label="Confirmadas / activas" value={stats.active} helper="En curso o próximas" />
        <KpiCard tone="violet" icon={<Flag size={21}/>} label="Finalizadas por liberar" value={stats.releasePending} helper="Pendientes de liquidación" />
        <KpiCard tone="rose" icon={<XCircle size={21}/>} label="Canceladas" value={stats.cancelled} helper="Reservas canceladas" />
      </section>

      <div className={styles.workspace}>
        <main className={styles.mainColumn}>
          <section className={styles.filterCard}>
            <div className={styles.searchRow}>
              <Search size={18}/>
              <input
                value={searchDraft}
                onChange={(event: ChangeEvent<HTMLInputElement>) => setSearchDraft(event.target.value)}
                onKeyDown={(event: KeyboardEvent<HTMLInputElement>) => { if (event.key === "Enter") applySearch(); }}
                placeholder="Buscar por reserva, cliente, servicio o profesional..."
                aria-label="Buscar reservas"
              />
              <button type="button" onClick={applySearch}>Buscar</button>
            </div>

            <div className={styles.filtersGrid}>
              <FilterSelect label="Estado" value={status} onChange={(value) => setStatus(value as StatusFilter)} options={statusFilters.map((item) => ({ value: item.value, label: item.label === "Todas" ? "Todos los estados" : item.label }))} />
              <FilterSelect label="Categoría" value={category} onChange={setCategory} options={[{ value: "all", label: "Todas las categorías" }, ...categories.map((value) => ({ value, label: value }))]} />
              <DateFilter label="Fecha desde" value={dateFrom} onChange={setDateFrom} />
              <DateFilter label="Fecha hasta" value={dateTo} onChange={setDateTo} />
              <FilterSelect label="Profesional" value={professional} onChange={setProfessional} options={[{ value: "all", label: "Todos los profesionales" }, ...professionals.map((value) => ({ value, label: value }))]} />
              <FilterSelect label="Cliente" value={client} onChange={setClient} options={[{ value: "all", label: "Todos los clientes" }, ...clients.map((value) => ({ value, label: value }))]} />
              <div className={styles.filterActions}>
                <button type="button" onClick={resetFilters}><FilterX size={16}/>Limpiar filtros</button>
                <button type="button" onClick={exportExcel} disabled={!visibleRows.length}><FileSpreadsheet size={16}/>Excel</button>
                <button type="button" onClick={exportPdf} disabled={!visibleRows.length}><FileText size={16}/>PDF</button>
              </div>
            </div>

            <div className={styles.statusTabs}>
              {statusFilters.map((item) => (
                <button key={item.value} type="button" className={status === item.value ? styles.activeTab : ""} onClick={() => setStatus(item.value)}>
                  <span>{item.label}</span><b>{counts[item.value]}</b>
                </button>
              ))}
            </div>
          </section>

          {error ? <div className={styles.error}>{adminMessage(error)}</div> : null}

          <section className={styles.tableCard}>
            <div className={styles.tableMeta}>
              <div><span className={styles.liveDot}/><strong>{loading && rows.length ? "Actualizando datos…" : "Datos sincronizados automáticamente"}</strong></div>
              <small>{lastUpdatedAt ? `Última actualización: ${lastUpdatedAt.toLocaleTimeString("es-PA", { hour: "2-digit", minute: "2-digit" })}` : ""}</small>
            </div>
            <div className={styles.tableWrap}>
              <table className={styles.table}>
                <thead>
                  <tr>
                    <th>Reserva</th><th>Cliente</th><th>Servicio</th><th>Categoría</th><th>Fecha</th><th>Hora</th><th>Profesional</th><th>Estado</th><th>Pago</th><th>Total</th><th>Acciones</th>
                  </tr>
                </thead>
                <tbody>
                  {loading && !rows.length ? (
                    <tr><td colSpan={11}><div className={styles.empty}>Cargando reservas…</div></td></tr>
                  ) : !pageRows.length ? (
                    <tr><td colSpan={11}><div className={styles.empty}>No encontramos reservas con estos filtros.</div></td></tr>
                  ) : pageRows.map((row, index) => {
                    const code = reservationCode(row) || `WISSA-${index + 1}`;
                    const clientName = asString(row.buyer_name) || "Cliente";
                    const providerName = asString(row.provider_name) || "Sin asignar";
                    return (
                      <tr key={asString(row.id || row.booking_id) || code}>
                        <td><button className={styles.codeLink} type="button" onClick={() => setSelected(row)}>{code}</button></td>
                        <td><PersonCell name={clientName}/></td>
                        <td><strong>{asString(row.service_title) || "Servicio Wissa"}</strong></td>
                        <td>{asString(row.service_category) || "—"}</td>
                        <td>{formatPanamaDate(row.booking_date)}</td>
                        <td>{bookingTime(row)}</td>
                        <td><PersonCell name={providerName} compact/></td>
                        <td><StatusPill value={bookingStatusLabel(row)} source={normalizedBookingStatus(row)}/></td>
                        <td><StatusPill value={paymentStatusLabel(row)} source={normalize(row.payment_status || row.payment_status_label)}/></td>
                        <td className={styles.amount}>{money(row.amount)}</td>
                        <td><div className={styles.rowActions}><button type="button" aria-label={`Ver ${code}`} onClick={() => setSelected(row)}><Eye size={16}/></button><button type="button" aria-label={`Copiar ${code}`} onClick={() => copyReservation(row)}><Copy size={15}/></button><button type="button" aria-label="Más opciones" onClick={() => setSelected(row)}><MoreHorizontal size={17}/></button></div></td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            <div className={styles.pagination}>
              <span>Mostrando {pageRows.length} de {visibleRows.length} reservas visibles</span>
              <div className={styles.pageControls}>
                <button type="button" onClick={() => setPage(Math.max(1, safePage - 1))} disabled={safePage <= 1}>‹</button>
                {pageWindow(safePage, totalPages).map((item, index) => item === "…" ? <span key={`ellipsis-${index}`} className={styles.ellipsis}>…</span> : <button key={item} type="button" className={safePage === item ? styles.currentPage : ""} onClick={() => setPage(item as number)}>{item}</button>)}
                <button type="button" onClick={() => setPage(Math.min(totalPages, safePage + 1))} disabled={safePage >= totalPages}>›</button>
                <select value={pageSize} onChange={(event: ChangeEvent<HTMLSelectElement>) => setPageSize(Number(event.target.value))}>{pageSizes.map((size) => <option key={size} value={size}>{size} por página</option>)}</select>
              </div>
            </div>
          </section>
        </main>

        <aside className={styles.sideColumn}>
          <section className={styles.sideCard}>
            <div className={styles.sideTitle}><span><CalendarCheck2 size={18}/><strong>Resumen operativo</strong></span><small>Hoy · {formatPanamaDate(new Date())}</small></div>
            <SummaryLine tone="amber" icon={<Clock3 size={17}/>} value={stats.pending} label="Reservas por confirmar" />
            <SummaryLine tone="orange" icon={<WalletCards size={17}/>} value={paymentPending} label="Pagos pendientes" />
            <SummaryLine tone="violet" icon={<HandCoins size={17}/>} value={stats.releasePending} label="Pendientes de liquidación" />
            <SummaryLine tone="blue" icon={<Activity size={17}/>} value={todayRows.length} label="Reservas programadas hoy" />
          </section>

          <section className={styles.sideCard}>
            <div className={styles.sideTitle}><span><Clock3 size={18}/><strong>Reservas de hoy</strong></span><small>{todayRows.length} programadas</small></div>
            <div className={styles.timeline}>
              {todayRows.length ? todayRows.slice(0, 6).map((row, index) => (
                <button type="button" key={asString(row.id || row.booking_id) || index} className={styles.timelineItem} onClick={() => setSelected(row)}>
                  <span className={`${styles.timelineDot} ${statusToneClass(normalizedBookingStatus(row), styles)}`}/>
                  <time>{bookingTime(row)}</time>
                  <span><strong>{asString(row.service_title) || "Servicio Wissa"}</strong><small>{asString(row.buyer_name) || "Cliente"}</small></span>
                  <StatusPill value={bookingStatusLabel(row)} source={normalizedBookingStatus(row)} small/>
                </button>
              )) : <div className={styles.sideEmpty}>No hay reservas programadas para hoy.</div>}
            </div>
          </section>

          <section className={`${styles.sideCard} ${styles.insightCard}`}>
            <span className={styles.insightIcon}><Activity size={19}/></span>
            <div><strong>Operación en tiempo real</strong><p>{stats.active > 0 ? `${stats.active} reservas están confirmadas o activas en este momento.` : "No hay reservas activas pendientes de seguimiento."}</p></div>
          </section>
        </aside>
      </div>

      {selected ? <ReservationDrawer row={selected} onClose={() => setSelected(null)} onCopy={() => copyReservation(selected)} /> : null}
    </div>
  );
}

function KpiCard({ icon, label, value, helper, tone }: { icon: ReactNode; label: string; value: number; helper: string; tone: "blue" | "amber" | "green" | "violet" | "rose" }) {
  return <article className={`${styles.kpiCard} ${styles[`tone_${tone}`]}`}><span className={styles.kpiIcon}>{icon}</span><div><span className={styles.kpiLabel}>{label}</span><strong><AnimatedCounter value={value} duration={0.55}/></strong><small>{helper}</small></div></article>;
}

function FilterSelect({ label, value, onChange, options }: { label: string; value: string; onChange: (value: string) => void; options: Array<{ value: string; label: string }> }) {
  return <label className={styles.filterField}><span>{label}</span><select value={value} onChange={(event: ChangeEvent<HTMLSelectElement>) => onChange(event.target.value)}>{options.map((option) => <option key={`${label}-${option.value}`} value={option.value}>{option.label}</option>)}</select></label>;
}

function DateFilter({ label, value, onChange }: { label: string; value: string; onChange: (value: string) => void }) {
  return <label className={styles.filterField}><span>{label}</span><input type="date" value={value} onChange={(event: ChangeEvent<HTMLInputElement>) => onChange(event.target.value)}/></label>;
}

function PersonCell({ name, compact = false }: { name: string; compact?: boolean }) {
  return <div className={`${styles.personCell} ${compact ? styles.compactPerson : ""}`}><span>{initials(name)}</span><strong>{name}</strong></div>;
}

function StatusPill({ value, source, small = false }: { value: string; source: string; small?: boolean }) {
  const tone = statusToneClass(source || value, styles);
  return <span className={`${styles.statusPill} ${tone} ${small ? styles.smallPill : ""}`}>{value}</span>;
}

function SummaryLine({ icon, value, label, tone }: { icon: ReactNode; value: number; label: string; tone: "amber" | "orange" | "violet" | "blue" }) {
  return <div className={styles.summaryLine}><span className={`${styles.summaryIcon} ${styles[`summary_${tone}`]}`}>{icon}</span><div><strong><AnimatedCounter value={value} duration={0.45}/></strong><small>{label}</small></div></div>;
}

function ReservationDrawer({ row, onClose, onCopy }: { row: Row; onClose: () => void; onCopy: () => void }) {
  const code = reservationCode(row) || "Reserva Wissa";
  return <div className={styles.drawerLayer} role="dialog" aria-modal="true" aria-label={`Detalle ${code}`}>
    <button className={styles.drawerOverlay} onClick={onClose} aria-label="Cerrar detalle"/>
    <aside className={styles.drawer}>
      <div className={styles.drawerHeader}><div><span>DETALLE DE RESERVA</span><h2>{code}</h2><p>Información operativa sincronizada desde Wissa.</p></div><button onClick={onClose} aria-label="Cerrar"><X size={20}/></button></div>
      <div className={styles.drawerStatus}><StatusPill value={bookingStatusLabel(row)} source={normalizedBookingStatus(row)}/><StatusPill value={paymentStatusLabel(row)} source={normalize(row.payment_status || row.payment_status_label)}/></div>
      <div className={styles.drawerGrid}>
        <Detail label="Cliente" value={asString(row.buyer_name) || "Sin cliente"}/>
        <Detail label="Profesional" value={asString(row.provider_name) || "Sin asignar"}/>
        <Detail label="Servicio" value={asString(row.service_title) || "Servicio Wissa"}/>
        <Detail label="Categoría" value={asString(row.service_category) || "—"}/>
        <Detail label="Fecha" value={formatPanamaDate(row.booking_date)}/>
        <Detail label="Hora" value={bookingTime(row)}/>
        <Detail label="Total" value={money(row.amount)} strong/>
        <Detail label="Liquidación" value={statusLabel(row.payout_release_status || row.release_status || "not_released")}/>
      </div>
      {asString(row.location || row.address || row.service_address) ? <div className={styles.drawerSection}><span>Ubicación</span><p>{asString(row.location || row.address || row.service_address)}</p></div> : null}
      {asString(row.notes || row.description) ? <div className={styles.drawerSection}><span>Notas</span><p>{asString(row.notes || row.description)}</p></div> : null}
      <div className={styles.drawerFooter}><button onClick={onCopy}><Copy size={16}/>Copiar código</button><button className={styles.drawerPrimary} onClick={onClose}>Cerrar</button></div>
    </aside>
  </div>;
}

function Detail({ label, value, strong = false }: { label: string; value: string; strong?: boolean }) {
  return <div className={styles.detailItem}><span>{label}</span><strong className={strong ? styles.detailStrong : ""}>{value}</strong></div>;
}

function uniqueValues(rows: Row[], key: string) {
  const values = new Map<string, string>();
  for (const row of rows) {
    const value = asString(row[key]);
    if (!value) continue;
    const normalized = normalize(value);
    if (!values.has(normalized)) values.set(normalized, value);
  }
  return [...values.values()].sort((a, b) => a.localeCompare(b, "es"));
}

function normalizedBookingStatus(row: Row) {
  return normalize(row.status || row.status_label).replace(/\s+/g, "_");
}

function normalizedReleaseStatus(row: Row) {
  return normalize(row.payout_release_status || row.release_status || row.payout_status).replace(/\s+/g, "_");
}

function matchesStatusFilter(row: Row, filter: StatusFilter) {
  if (filter === "all") return true;
  const booking = normalizedBookingStatus(row);
  const payment = normalize(row.payment_status || row.payment_status_label).replace(/\s+/g, "_");
  const release = normalizedReleaseStatus(row);

  if (filter === "pending") return ["pending", "pending_payment", "paid_pending_acceptance"].includes(booking) || booking.includes("pendiente");
  if (filter === "approved") return ["approved", "accepted", "confirmed", "in_progress", "active"].includes(booking) || booking.includes("aprob");
  if (filter === "paid") return payment === "paid" || payment.includes("pagado") || booking === "paid";
  if (filter === "released") return release === "released" || release === "paid" || booking === "released" || release.includes("liquid");
  if (filter === "rejected") return booking === "rejected" || booking.includes("rechaz");
  if (filter === "cancelled") return booking === "cancelled" || booking === "canceled" || booking.includes("cancel");
  return true;
}

function isActiveBooking(row: Row) {
  const status = normalizedBookingStatus(row);
  return ["approved", "accepted", "confirmed", "in_progress", "active", "paid_pending_acceptance"].includes(status) || status.includes("aprob");
}

function isReleasePending(row: Row) {
  const status = normalizedBookingStatus(row);
  const release = normalizedReleaseStatus(row);
  return ["completed", "completed_pending_release"].includes(status) && !["released", "paid"].includes(release);
}

function bookingStatusLabel(row: Row) {
  const raw = row.status || row.status_label || "pending";
  return statusLabel(raw);
}

function paymentStatusLabel(row: Row) {
  const raw = row.payment_status || row.payment_status_label || "pending";
  return statusLabel(raw);
}

function statusToneClass(value: unknown, classes: typeof styles) {
  const normalized = normalize(value);
  if (/cancel|rechaz|failed|fallido/.test(normalized)) return classes.statusRed;
  if (/pending|pendiente|por liberar|not_released/.test(normalized)) return classes.statusAmber;
  if (/paid|pagado|approved|aprob|accepted|confirm|released|liquid|completed|complet/.test(normalized)) return classes.statusGreen;
  return classes.statusBlue;
}

function reservationCode(row: Row) {
  return asString(row.reservation_code || row.booking_code || row.reference || row.booking_id || row.id);
}

function bookingTime(row: Row) {
  const raw = row.booking_time || row.scheduled_time || row.start_time;
  return raw ? formatPanamaTime(raw) : "—";
}

function rowDateKey(row: Row) {
  const raw = row.booking_date || row.scheduled_at || row.created_at;
  if (!raw) return "";
  const source = String(raw);
  if (/^\d{4}-\d{2}-\d{2}$/.test(source)) return source;
  const date = new Date(source);
  return Number.isNaN(date.getTime()) ? "" : panamaDateKey(date);
}

function panamaDateKey(date: Date) {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Panama", year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(date);
  const get = (type: string) => parts.find((part) => part.type === type)?.value || "";
  return `${get("year")}-${get("month")}-${get("day")}`;
}

function pageWindow(current: number, total: number): Array<number | "…"> {
  if (total <= 7) return Array.from({ length: total }, (_, index) => index + 1);
  if (current <= 4) return [1, 2, 3, 4, 5, "…", total];
  if (current >= total - 3) return [1, "…", total - 4, total - 3, total - 2, total - 1, total];
  return [1, "…", current - 1, current, current + 1, "…", total];
}

function initials(value: string) {
  return value.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "W";
}

function normalize(value: unknown) {
  return asString(value).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim();
}

function asString(value: unknown) {
  if (value === null || value === undefined) return "";
  return String(value).trim();
}

function csvEscape(value: unknown) {
  const text = String(value ?? "").replace(/\t/g, " ").replace(/\r?\n/g, " ");
  return text;
}

function fileStamp() {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Panama", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
}

function downloadBlob(filename: string, content: string, type: string) {
  const blob = new Blob([content], { type });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  window.setTimeout(() => URL.revokeObjectURL(url), 800);
}

function buildPrintHtml(rows: Row[]) {
  const body = rows.map((row) => `<tr><td>${escapeHtml(reservationCode(row))}</td><td>${escapeHtml(asString(row.buyer_name))}</td><td>${escapeHtml(asString(row.service_title))}</td><td>${escapeHtml(asString(row.service_category))}</td><td>${escapeHtml(formatPanamaDate(row.booking_date))}</td><td>${escapeHtml(bookingTime(row))}</td><td>${escapeHtml(asString(row.provider_name))}</td><td>${escapeHtml(bookingStatusLabel(row))}</td><td>${escapeHtml(paymentStatusLabel(row))}</td><td>${escapeHtml(money(row.amount))}</td></tr>`).join("");
  return `<!doctype html><html><head><meta charset="utf-8"><title>Reservas Wissa</title><style>body{font-family:Arial,sans-serif;padding:28px;color:#10243b}h1{margin:0 0 6px}p{color:#60758d;margin:0 0 22px}table{width:100%;border-collapse:collapse;font-size:11px}th,td{padding:9px 7px;border-bottom:1px solid #dbe6f2;text-align:left;vertical-align:top}th{background:#eff6ff;color:#48627e;text-transform:uppercase;font-size:9px}@media print{body{padding:0}}</style></head><body><h1>Reservas Wissa</h1><p>${rows.length} registros visibles</p><table><thead><tr><th>Reserva</th><th>Cliente</th><th>Servicio</th><th>Categoría</th><th>Fecha</th><th>Hora</th><th>Profesional</th><th>Estado</th><th>Pago</th><th>Total</th></tr></thead><tbody>${body}</tbody></table></body></html>`;
}

function escapeHtml(value: unknown) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;" }[char] || char));
}
