"use client";

import { adminMessage } from "@/lib/admin-copy";

import { FormEvent, useCallback, useEffect, useState } from "react";
import { RefreshCcw, Save, Settings } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { date, money, text } from "@/lib/utils";
import AdminTablePage from "@/components/admin/AdminTablePage";

type PlanSetting = {
  id?: string;
  code?: string;
  name?: string;
  price?: number;
  duration_days?: number;
  is_active?: boolean;
  updated_at?: string;
};

const emptyForm = {
  id: "",
  code: "company_basic",
  name: "Empresa Básica",
  price: 0,
  duration_days: 30,
  is_active: true,
};

export default function CompanyPlansManagerPage() {
  const [settings, setSettings] = useState<PlanSetting[]>([]);
  const [form, setForm] = useState(emptyForm);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    const { data, error } = await supabase.rpc("yt_admin_company_plan_settings_json", {
      p_search: "",
      p_status: "all",
      p_limit: 100,
    });

    if (error) {
      setError(error.message);
      setSettings([]);
    } else {
      const rows = Array.isArray(data) ? (data as PlanSetting[]) : [];
      setSettings(rows);
      const activePlan = rows.find((row) => row.is_active !== false) || rows[0];
      if (activePlan) {
        setForm({
          id: activePlan.id || "",
          code: activePlan.code || "company_basic",
          name: activePlan.name || "Empresa Básica",
          price: Number(activePlan.price ?? 0),
          duration_days: Number(activePlan.duration_days || 30),
          is_active: activePlan.is_active !== false,
        });
      }
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      void load();
    }, 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  function edit(row: PlanSetting) {
    setForm({
      id: row.id || "",
      code: row.code || "company_basic",
      name: row.name || "Empresa Básica",
      price: Number(row.price ?? 0),
      duration_days: Number(row.duration_days || 30),
      is_active: row.is_active !== false,
    });
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSaving(true);
    setError("");

    const { error } = await supabase.rpc("yt_admin_upsert_company_plan_setting", {
      p_plan: {
        id: form.id || null,
        code: form.code.trim(),
        name: form.name.trim(),
        price: Number(form.price || 0),
        duration_days: Number(form.duration_days || 30),
        is_active: Boolean(form.is_active),
      },
    });

    if (error) {
      setError(error.message);
    } else {
      setForm(emptyForm);
      await load();
    }
    setSaving(false);
  }

  return (
    <div>
      <section className="hero">
        <div className="hero-row">
          <div>
            <div className="eyebrow">Empresas</div>
            <h1>Planes empresariales</h1>
            <p className="subtitle">Gestiona precio, duración y estado del plan empresarial. Abajo puedes aprobar o rechazar órdenes de compra.</p>
          </div>
          <button className="btn btn-primary" onClick={() => void load()}><RefreshCcw size={17} />Actualizar</button>
        </div>
      </section>

      {error && <div className="error" style={{ marginBottom: 18 }}>{adminMessage(error)}</div>}

      <section className="card" style={{ padding: 22, marginBottom: 18 }}>
        <div className="eyebrow">Configuración del plan</div>
        <h2 style={{ margin: "8px 0 4px" }}>Plan empresa activo</h2>
        <p className="subtitle">Este precio/duración se usa como base administrativa para planes empresariales.</p>

        <form className="form" onSubmit={save}>
          <div className="admin-form-grid admin-form-grid-plan">
            <label><div className="label">Código</div><input className="input" value={form.code} onChange={(e) => setForm({ ...form, code: e.target.value })} required /></label>
            <label><div className="label">Nombre</div><input className="input" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} required /></label>
            <label><div className="label">Precio USD</div><input className="input" type="number" step="0.01" min="0" value={form.price} onChange={(e) => setForm({ ...form, price: Number(e.target.value) })} required /></label>
            <label><div className="label">Días</div><input className="input" type="number" min="1" value={form.duration_days} onChange={(e) => setForm({ ...form, duration_days: Number(e.target.value) })} required /></label>
            <label><div className="label">Estado</div><select className="select" value={form.is_active ? "true" : "false"} onChange={(e) => setForm({ ...form, is_active: e.target.value === "true" })}><option value="true">Activo</option><option value="false">Inactivo</option></select></label>
          </div>
          <button className="btn btn-primary" disabled={saving} style={{ width: "fit-content" }}><Save size={17} />{saving ? "Guardando..." : "Guardar plan"}</button>
        </form>
      </section>

      <section className="card table-card" style={{ marginBottom: 24 }}>
        <div className="table-wrap">
          <table className="table responsive-table">
            <thead><tr><th>Código</th><th>Nombre</th><th>Precio</th><th>Duración</th><th>Estado</th><th>Actualizado</th><th>Acciones</th></tr></thead>
            <tbody>
              {loading ? <tr><td colSpan={7} className="empty">Cargando configuración...</td></tr> : settings.length === 0 ? <tr><td colSpan={7} className="empty">No hay planes configurados.</td></tr> : settings.map((row) => (
                <tr key={row.id || row.code}>
                  <td data-label="Código"><strong>{text(row.code)}</strong></td>
                  <td data-label="Nombre">{text(row.name)}</td>
                  <td data-label="Precio">{money(row.price)}</td>
                  <td data-label="Duración">{text(row.duration_days)} días</td>
                  <td data-label="Estado"><span className={row.is_active !== false ? "badge green" : "badge red"}>{row.is_active !== false ? "Activo" : "Inactivo"}</span></td>
                  <td data-label="Actualizado">{date(row.updated_at)}</td>
                  <td data-label="Acciones" className="table-actions-cell"><button className="btn btn-soft btn-small" onClick={() => edit(row)}><Settings size={14} />Editar</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <AdminTablePage
        title="Órdenes de planes"
        eyebrow="Pagos empresa"
        description="Compras de planes empresariales, aprobación y activación de cuenta empresa."
        rpc="yt_admin_plans_json"
        actions="plans"
        enableDateFilter
        columns={[
          { key: "company_name", label: "Empresa" },
          { key: "plan_name", label: "Plan", type: "plan" },
          { key: "status", label: "Estado", type: "status" },
          { key: "amount", label: "Monto", type: "money" },
          { key: "method", label: "Método" },
          { key: "created_at", label: "Creado", type: "date" },
        ]}
      />
    </div>
  );
}
