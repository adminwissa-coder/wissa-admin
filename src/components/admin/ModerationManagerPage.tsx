"use client";

import { adminMessage } from "@/lib/admin-copy";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Ban, CheckCircle2, Flag, RefreshCcw, Search, ShieldAlert, XCircle } from "lucide-react";
import { supabase } from "@/lib/supabase";

type ModerationStats = {
  open?: number;
  resolved?: number;
  dismissed?: number;
  content_reports?: number;
  active_blocks?: number;
  active_terms?: number;
};

type ModerationReport = {
  id: string;
  booking_id?: string | null;
  reporter_id?: string | null;
  reported_id?: string | null;
  reason?: string | null;
  description?: string | null;
  status?: string | null;
  admin_note?: string | null;
  content_type?: string | null;
  reported_chat_message_id?: string | null;
  reported_review_id?: string | null;
  reported_content_excerpt?: string | null;
  created_at?: string | null;
  reporter_name?: string | null;
  reporter_email?: string | null;
  reported_name?: string | null;
  reported_email?: string | null;
  reported_suspended?: boolean | null;
  service_title?: string | null;
  booking_status?: string | null;
};

type Payload = { stats?: ModerationStats; reports?: ModerationReport[] };

const statusOptions = [
  ["open", "Abiertos"],
  ["resolved", "Resueltos"],
  ["dismissed", "Descartados"],
  ["all", "Todos"],
] as const;

export default function ModerationManagerPage() {
  const [loading, setLoading] = useState(true);
  const [working, setWorking] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState("open");
  const [stats, setStats] = useState<ModerationStats>({});
  const [reports, setReports] = useState<ModerationReport[]>([]);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    const { data, error: rpcError } = await supabase.rpc("yt_admin_moderation_overview_v43", {
      p_status: status,
      p_search: query,
      p_limit: 250,
    });

    if (rpcError) {
      setError(rpcError.message || "No se pudo cargar Moderación.");
      setLoading(false);
      return;
    }

    const payload = (data || {}) as Payload;
    setStats(payload.stats || {});
    setReports(Array.isArray(payload.reports) ? payload.reports : []);
    setLoading(false);
  }, [query, status]);

  useEffect(() => {
    void load();
  }, [load]);

  const cards = useMemo(
    () => [
      ["Reportes abiertos", Number(stats.open || 0), "Requieren revisión"],
      ["Contenido reportado", Number(stats.content_reports || 0), "Chat y reseñas"],
      ["Bloqueos activos", Number(stats.active_blocks || 0), "Protección entre usuarios"],
      ["Términos de filtro", Number(stats.active_terms || 0), "Filtro UGC activo"],
    ],
    [stats],
  );

  async function action(report: ModerationReport, nextAction: "resolve" | "dismiss" | "reopen", suspend = false) {
    const label = nextAction === "resolve" ? "resolver" : nextAction === "dismiss" ? "descartar" : "reabrir";
    if (suspend && !window.confirm(`¿Suspender a ${report.reported_name || "este usuario"} y resolver el reporte?`)) return;

    const note = window.prompt(`Nota de administración para ${label} el reporte:`, report.admin_note || "") ?? "";
    setWorking(report.id);
    setError("");

    const { error: rpcError } = await supabase.rpc("yt_admin_moderation_action_v43", {
      p_report_id: report.id,
      p_action: nextAction,
      p_note: note,
      p_suspend_user: suspend,
    });

    if (rpcError) {
      setError(rpcError.message || "No se pudo actualizar el reporte.");
      setWorking(null);
      return;
    }

    setWorking(null);
    await load();
  }

  return (
    <div>
      <div className="hero">
        <div className="hero-row">
          <div>
            <div className="eyebrow">Confianza y seguridad</div>
            <h1>Moderación</h1>
            <p className="subtitle">
              Revisa reportes de usuarios, mensajes y reseñas. Los bloqueos de usuario se aplican directamente en la app y el filtro UGC protege chat y comentarios.
            </p>
          </div>
          <button className="btn btn-soft" onClick={() => void load()} disabled={loading}>
            <RefreshCcw size={17} /> Actualizar
          </button>
        </div>
      </div>

      <div className="stats">
        {cards.map(([label, value, detail]) => (
          <div className="stat" key={String(label)}>
            <span>{label}</span>
            <strong>{value}</strong>
            <div className="secondary">{detail}</div>
          </div>
        ))}
      </div>

      <div className="card" style={{ padding: 18, marginBottom: 18 }}>
        <div className="admin-filter-grid">
          <div style={{ position: "relative" }}>
            <Search size={17} style={{ position: "absolute", left: 14, top: 14, color: "var(--muted)" }} />
            <input
              className="input"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter") setQuery(search.trim());
              }}
              placeholder="Buscar usuario, correo, motivo o contenido..."
              style={{ paddingLeft: 42 }}
            />
          </div>
          <select className="select" value={status} onChange={(event) => setStatus(event.target.value)}>
            {statusOptions.map(([value, label]) => <option value={value} key={value}>{label}</option>)}
          </select>
          <button className="btn btn-primary" onClick={() => setQuery(search.trim())}>Buscar</button>
          <button className="btn btn-soft" onClick={() => { setSearch(""); setQuery(""); }}>Limpiar</button>
        </div>
      </div>

      {error ? <div className="error" style={{ marginBottom: 16 }}>{adminMessage(error)}</div> : null}

      <div className="card table-card">
        {loading ? (
          <div className="empty"><div className="spinner" style={{ margin: "0 auto 12px" }} />Cargando moderación...</div>
        ) : reports.length === 0 ? (
          <div className="empty">
            <ShieldAlert size={32} style={{ marginBottom: 10 }} />
            <div className="primary">No hay reportes en este filtro.</div>
            <div className="secondary">Cuando un usuario reporte contenido o una incidencia aparecerá aquí.</div>
          </div>
        ) : (
          <div className="table-wrap">
            <table className="table responsive-table moderation-responsive-table">
              <thead>
                <tr>
                  <th>Tipo</th>
                  <th>Reportado por</th>
                  <th>Usuario reportado</th>
                  <th>Motivo / contenido</th>
                  <th>Reserva</th>
                  <th>Estado</th>
                  <th>Fecha</th>
                  <th>Acciones</th>
                </tr>
              </thead>
              <tbody>
                {reports.map((report) => {
                  const busy = working === report.id;
                  return (
                    <tr key={report.id}>
                      <td data-label="Tipo">
                        <span className={`badge ${report.content_type === "chat_message" || report.content_type === "review" ? "yellow" : "cyan"}`}>
                          <Flag size={13} /> {contentTypeLabel(report.content_type)}
                        </span>
                      </td>
                      <td data-label="Reportado por">
                        <div className="primary">{report.reporter_name || "Usuario"}</div>
                        <div className="secondary">{report.reporter_email || "—"}</div>
                      </td>
                      <td data-label="Usuario reportado">
                        <div className="primary">{report.reported_name || "Sin usuario"}</div>
                        <div className="secondary">{report.reported_email || "—"}</div>
                        {report.reported_suspended ? <span className="badge red" style={{ marginTop: 7 }}>Suspendido</span> : null}
                      </td>
                      <td data-label="Motivo / contenido" className="admin-long-content">
                        <div className="primary">{report.reason || "Reporte"}</div>
                        {report.reported_content_excerpt ? (
                          <div style={{ marginTop: 7, padding: 10, borderRadius: 12, background: "rgba(255,255,255,.045)", color: "var(--muted)", lineHeight: 1.45 }}>
                            “{report.reported_content_excerpt}”
                          </div>
                        ) : null}
                        {report.description ? <div className="secondary" style={{ marginTop: 6 }}>{report.description}</div> : null}
                        {report.admin_note ? <div className="secondary" style={{ marginTop: 6 }}><strong>Admin:</strong> {report.admin_note}</div> : null}
                      </td>
                      <td data-label="Reserva">
                        <div className="primary">{report.service_title || "—"}</div>
                        <div className="secondary">{report.booking_id ? "Reserva vinculada" : "Sin reserva"}</div>
                      </td>
                      <td data-label="Estado"><span className={statusBadge(report.status)}>{statusLabel(report.status)}</span></td>
                      <td data-label="Fecha"><div className="secondary">{formatDate(report.created_at)}</div></td>
                      <td data-label="Acciones" className="table-actions-cell">
                        <div className="actions">
                          {report.status !== "resolved" ? (
                            <button className="btn btn-green btn-small" disabled={busy} onClick={() => void action(report, "resolve")}>
                              <CheckCircle2 size={14} /> Resolver
                            </button>
                          ) : (
                            <button className="btn btn-soft btn-small" disabled={busy} onClick={() => void action(report, "reopen")}>
                              <RefreshCcw size={14} /> Reabrir
                            </button>
                          )}
                          {report.status === "open" ? (
                            <button className="btn btn-soft btn-small" disabled={busy} onClick={() => void action(report, "dismiss")}>
                              <XCircle size={14} /> Descartar
                            </button>
                          ) : null}
                          {report.reported_id && !report.reported_suspended ? (
                            <button className="btn btn-danger btn-small" disabled={busy} onClick={() => void action(report, "resolve", true)}>
                              <Ban size={14} /> Suspender
                            </button>
                          ) : null}
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}

function contentTypeLabel(value?: string | null) {
  if (value === "chat_message") return "Mensaje";
  if (value === "review") return "Reseña";
  return "Usuario / caso";
}

function statusLabel(value?: string | null) {
  if (value === "resolved") return "Resuelto";
  if (value === "dismissed") return "Descartado";
  return "Abierto";
}

function statusBadge(value?: string | null) {
  if (value === "resolved") return "badge green";
  if (value === "dismissed") return "badge";
  return "badge yellow";
}


function formatDate(value?: string | null) {
  if (!value) return "—";
  try {
    return new Intl.DateTimeFormat("es-PA", { dateStyle: "medium", timeStyle: "short", timeZone: "America/Panama" }).format(new Date(value));
  } catch {
    return value;
  }
}
