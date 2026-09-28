"use client";

import { adminMessage } from "@/lib/admin-copy";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { Eye, RefreshCw, Search, ShieldCheck, WalletCards } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { formatPanamaDateTime } from "@/lib/utils";

type ProviderRow = {
  id: string;
  full_name: string;
  email?: string | null;
  phone?: string | null;
  whatsapp_phone?: string | null;
  city?: string | null;
  provider_status?: string | null;
  is_verified?: boolean | null;
  is_available?: boolean | null;
  provider_enabled?: boolean | null;
  latitude?: number | null;
  longitude?: number | null;
  location_label?: string | null;
  rating_avg?: number | null;
  services_count?: number | null;
  bookings_count?: number | null;
  pending_documents?: number | null;
  payout_method?: string | null;
  payout_destination?: string | null;
  created_at?: string | null;
};

const statusOptions = [
  ["all", "Todos"],
  ["pending", "Pendientes"],
  ["approved", "Aprobados"],
  ["rejected", "Rechazados"],
  ["verified", "Verificados"],
  ["unverified", "No verificados"],
  ["available", "Disponibles"],
] as const;

export default function ProviderAdminList() {
  const router = useRouter();
  const [rows, setRows] = useState<ProviderRow[]>([]);
  const [searchDraft, setSearchDraft] = useState("");
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("all");
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setErr("");
    const { data, error } = await supabase.rpc("yt_admin_providers_json", {
      p_search: search,
      p_status: status,
      p_limit: 200,
      p_date_from: null,
      p_date_to: null,
    });

    if (error) {
      setErr(error.message);
      setRows([]);
    } else {
      const baseRows = (Array.isArray(data) ? data : []) as ProviderRow[];
      const ids = baseRows.map((row) => row.id).filter(Boolean);
      if (!ids.length) {
        setRows(baseRows);
      } else {
        const { data: profiles, error: profileError } = await supabase
          .from("profiles")
          .select("id,provider_enabled,is_available,latitude,longitude,lat,lng,location_label")
          .in("id", ids);

        if (profileError) {
          setRows(baseRows);
        } else {
          const profileMap = new Map((profiles || []).map((profile: any) => [profile.id, profile]));
          setRows(baseRows.map((row) => {
            const profile: any = profileMap.get(row.id);
            if (!profile) return row;
            return {
              ...row,
              provider_enabled: profile.provider_enabled,
              is_available: profile.is_available,
              latitude: profile.latitude ?? profile.lat ?? null,
              longitude: profile.longitude ?? profile.lng ?? null,
              location_label: profile.location_label ?? null,
            };
          }));
        }
      }
    }
    setLoading(false);
  }, [search, status]);

  useEffect(() => {
    void load();
  }, [load]);

  const stats = useMemo(() => {
    const pending = rows.filter((row) => row.provider_status === "pending" || !row.is_verified).length;
    const verified = rows.filter((row) => Boolean(row.is_verified)).length;
    const withoutPayout = rows.filter((row) => !row.payout_method || row.payout_method === "Sin método").length;
    const ready = rows.filter((row) => {
      const hasLocation = Number.isFinite(Number(row.latitude)) && Number.isFinite(Number(row.longitude));
      return Boolean(row.is_verified) && row.provider_status === "approved" && row.is_available === true && hasLocation;
    }).length;
    return { total: rows.length, pending, verified, withoutPayout, ready };
  }, [rows]);

  return (
    <div className="admin-page ui2-admin-table-page ui2-providers-page">
      <section className="hero ui2-module-hero">
        <div className="hero-row">
          <div>
            <div className="eyebrow">GESTIÓN DE PROFESIONALES</div>
            <h1>Profesionales</h1>
            <p className="subtitle">
              Revisa perfiles independientes, disponibilidad, verificación, servicios, ubicación de trabajo y métodos de cobro desde una sola vista.
            </p>
          </div>
          <button className="btn btn-soft" onClick={() => void load()} disabled={loading}>
            <RefreshCw size={16} /> Actualizar
          </button>
        </div>

        <div className="stats ui2-module-stats">
          <Stat label="Profesionales" value={stats.total} />
          <Stat label="Por validar" value={stats.pending} danger={stats.pending > 0} />
          <Stat label="Verificados" value={stats.verified} />
          <Stat label="Listos para recibir" value={stats.ready} danger={stats.ready < stats.total} />
          <Stat label="Sin método de cobro" value={stats.withoutPayout} danger={stats.withoutPayout > 0} />
        </div>
      </section>

      <section className="card toolbar ui2-module-filters">
        <div style={{ position: "relative" }}>
          <Search size={16} style={{ position: "absolute", left: 14, top: 14, color: "var(--muted)" }} />
          <input
            className="input"
            style={{ paddingLeft: 40 }}
            placeholder="Buscar profesional, correo, teléfono, Yappy o banco..."
            value={searchDraft}
            onChange={(event) => setSearchDraft(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") setSearch(searchDraft.trim());
            }}
          />
        </div>
        <select className="select" value={status} onChange={(event) => setStatus(event.target.value)}>
          {statusOptions.map(([value, label]) => <option key={value} value={value}>{label}</option>)}
        </select>
        <button className="btn btn-primary" onClick={() => setSearch(searchDraft.trim())}>Buscar</button>
        <button className="btn btn-soft" onClick={() => { setSearchDraft(""); setSearch(""); setStatus("all"); }}>Limpiar</button>
      </section>

      {err ? <div className="error" style={{ marginBottom: 18 }}>{adminMessage(err)}</div> : null}

      <section className="card table-card ui2-data-card">
        <div className="table-wrap">
          <table className="table responsive-table provider-responsive-table">
            <thead>
              <tr>
                <th>Profesional</th>
                <th>Contacto</th>
                <th>Verificación</th>
                <th>Servicios</th>
                <th>Reservas</th>
                <th>Cobro</th>
                <th>Alta</th>
                <th>Acción</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={8}><div className="empty">Actualizando profesionales...</div></td></tr>
              ) : rows.length === 0 ? (
                <tr><td colSpan={8}><div className="empty">No hay profesionales para este filtro.</div></td></tr>
              ) : rows.map((row) => {
                const verified = Boolean(row.is_verified) && row.provider_status === "approved";
                return (
                  <tr key={row.id}>
                    <td data-label="Profesional">
                      <div className="primary">{row.full_name || "Profesional Wissa"}</div>
                      <div className="secondary">{row.email || "Sin correo"}</div>
                      <div className="secondary">{row.city || "Sin ciudad"}</div>
                    </td>
                    <td data-label="Contacto">
                      <div>{row.phone || "Sin teléfono"}</div>
                      <div className="secondary">WhatsApp: {row.whatsapp_phone || "No configurado"}</div>
                    </td>
                    <td data-label="Verificación">
                      <span className={`badge ${verified ? "green" : row.provider_status === "rejected" ? "red" : "yellow"}`}>
                        <ShieldCheck size={13} /> {verified ? "Verificado" : row.provider_status === "rejected" ? "Rechazado" : "Pendiente"}
                      </span>
                      {Number(row.pending_documents || 0) > 0 ? (
                        <div className="secondary">{row.pending_documents} documento(s) por revisar</div>
                      ) : null}
                      <div className="secondary">{row.is_available ? "Disponible" : "No disponible"}</div>
                      <div className="secondary">
                        {Number.isFinite(Number(row.latitude)) && Number.isFinite(Number(row.longitude))
                          ? `Ubicación de trabajo: ${row.location_label || "Configurada"}`
                          : "Ubicación de trabajo pendiente"}
                      </div>
                    </td>
                    <td data-label="Servicios">{Number(row.services_count || 0)}</td>
                    <td data-label="Reservas">{Number(row.bookings_count || 0)}</td>
                    <td data-label="Cobro">
                      <div className="primary" style={{ display: "flex", gap: 7, alignItems: "center" }}>
                        <WalletCards size={14} /> {labelMethod(row.payout_method)}
                      </div>
                      <div className="secondary">{row.payout_destination || "Sin configurar"}</div>
                    </td>
                    <td data-label="Alta">{row.created_at ? formatPanamaDateTime(row.created_at) : "—"}</td>
                    <td data-label="Acción" className="table-actions-cell">
                      <button className="btn btn-primary btn-small" onClick={() => router.push(`/dashboard/ofrecer/${row.id}`)}>
                        <Eye size={14} /> Ver perfil
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}

function Stat({ label, value, danger = false }: { label: string; value: number; danger?: boolean }) {
  return (
    <div className={`stat ui2-stat-card ${danger ? "ui2-stat-warning" : ""}`}>
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function labelMethod(value?: string | null) {
  if (value === "yappy") return "Yappy";
  if (value === "bank") return "Cuenta bancaria";
  return value || "Sin método";
}
