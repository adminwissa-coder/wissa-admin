"use client";

import { adminMessage } from "@/lib/admin-copy";

import { FormEvent, useCallback, useEffect, useMemo, useState } from "react";
import { Plus, RefreshCcw, Save, Trash2, Users } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { money } from "@/lib/utils";

type Rule = {
  id?: string;
  category: string;
  cleaning_mode: "any" | "standard" | "deep";
  property_type: string;
  sqm_min: number;
  sqm_max: number;
  min_professionals: number;
  recommended_professionals: number;
  max_professionals: number;
  additional_professional_fee: number;
  additional_professional_fees: Record<string, number>;
  is_active: boolean;
  priority: number;
  metadata?: Record<string, unknown>;
};

const propertyOptions = [
  ["any", "Cualquier propiedad"],
  ["casa", "Casa"],
  ["apartamento", "Apartamento"],
  ["oficina", "Oficina"],
  ["local_comercial", "Local comercial"],
  ["edificio", "Edificio"],
  ["consultorio_clinica", "Consultorio / Clínica"],
] as const;

const emptyRule: Rule = {
  category: "Limpieza",
  cleaning_mode: "standard",
  property_type: "casa",
  sqm_min: 1,
  sqm_max: 149,
  min_professionals: 1,
  recommended_professionals: 1,
  max_professionals: 1,
  additional_professional_fee: 35,
  additional_professional_fees: { '2': 35, '3': 35, '4': 35, '5': 35 },
  is_active: true,
  priority: 100,
};

function integer(value: unknown, fallback: number, min = 0, max = 9999) {
  const parsed = Math.round(Number(value));
  return Number.isFinite(parsed) ? Math.max(min, Math.min(max, parsed)) : fallback;
}

function numeric(value: unknown, fallback: number) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.max(0, parsed) : fallback;
}

function normalizeRule(raw: Partial<Rule>): Rule {
  const min = integer(raw.min_professionals, 1, 1, 5);
  const recommended = Math.max(min, integer(raw.recommended_professionals, min, 1, 5));
  const max = Math.max(recommended, integer(raw.max_professionals, recommended, 1, 5));
  const sqmMin = integer(raw.sqm_min, 1, 0, 5000);
  const sqmMax = Math.max(sqmMin, integer(raw.sqm_max, 2000, sqmMin, 5000));
  return {
    id: raw.id,
    category: String(raw.category || "Limpieza"),
    cleaning_mode: raw.cleaning_mode === "deep" || raw.cleaning_mode === "any" ? raw.cleaning_mode : "standard",
    property_type: String(raw.property_type || "any"),
    sqm_min: sqmMin,
    sqm_max: sqmMax,
    min_professionals: min,
    recommended_professionals: recommended,
    max_professionals: max,
    additional_professional_fee: Math.max(1, numeric(raw.additional_professional_fee, 35)),
    additional_professional_fees: {
      '2': Math.max(1, numeric(raw.additional_professional_fees?.['2'], raw.additional_professional_fee || 35)),
      '3': Math.max(1, numeric(raw.additional_professional_fees?.['3'], raw.additional_professional_fee || 35)),
      '4': Math.max(1, numeric(raw.additional_professional_fees?.['4'], raw.additional_professional_fee || 35)),
      '5': Math.max(1, numeric(raw.additional_professional_fees?.['5'], raw.additional_professional_fee || 35)),
    },
    is_active: raw.is_active !== false,
    priority: integer(raw.priority, 100, 0, 9999),
    metadata: raw.metadata || {},
  };
}

function modeLabel(value: Rule["cleaning_mode"]) {
  if (value === "deep") return "Profunda";
  if (value === "standard") return "Estándar";
  return "Cualquiera";
}

function propertyLabel(value: string) {
  return propertyOptions.find(([key]) => key === value)?.[1] || value.replaceAll("_", " ");
}

export default function TeamRulesManagerPage() {
  const [rules, setRules] = useState<Rule[]>([]);
  const [editing, setEditing] = useState<Rule>(emptyRule);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    const { data, error: loadError } = await supabase.rpc("yt_admin_team_rules_v62");
    if (loadError) { console.error(loadError); setError('No pudimos cargar la configuración de equipos.'); }
    setRules(Array.isArray(data) ? (data as Rule[]).map(normalizeRule) : []);
    setLoading(false);
  }, []);

  useEffect(() => { void load(); }, [load]);

  const grouped = useMemo(() => {
    return [...rules].sort((a, b) => a.priority - b.priority || a.sqm_min - b.sqm_min);
  }, [rules]);

  async function save(event: FormEvent) {
    event.preventDefault();
    setError("");
    setMessage("");
    const payload = normalizeRule(editing);
    if (payload.min_professionals > payload.recommended_professionals || payload.recommended_professionals > payload.max_professionals) {
      setError("La regla debe cumplir mínimo ≤ recomendado ≤ máximo.");
      return;
    }
    setSaving(true);
    const { error: saveError } = await supabase.rpc("yt_admin_upsert_team_rule_v62", { p_rule: payload });
    setSaving(false);
    if (saveError) { console.error(saveError); setError('No pudimos guardar la regla. Revisa los datos e inténtalo nuevamente.'); return; }
    setMessage("Regla guardada. Las nuevas solicitudes usarán esta configuración.");
    setEditing(emptyRule);
    await load();
  }

  async function remove(rule: Rule) {
    if (!rule.id || !window.confirm(`¿Eliminar regla ${modeLabel(rule.cleaning_mode)} · ${propertyLabel(rule.property_type)} · ${rule.sqm_min}-${rule.sqm_max} m²?`)) return;
    setError("");
    const { error: deleteError } = await supabase.rpc("yt_admin_delete_team_rule_v62", { p_rule_id: rule.id });
    if (deleteError) { console.error(deleteError); setError('No pudimos eliminar la regla. Inténtalo nuevamente.'); return; }
    if (editing.id === rule.id) setEditing(emptyRule);
    await load();
  }

  const patch = (value: Partial<Rule>) => setEditing((current) => normalizeRule({ ...current, ...value }));

  return (
    <div>
      <section className="hero">
        <div className="hero-row">
          <div>
            <div className="eyebrow">Configuración Wissa</div>
            <h1>Reglas de equipo</h1>
            <p className="subtitle">Define cuántos profesionales necesita cada reserva y el valor de cada integrante adicional. Para trabajos grandes, el precio cerrado del bloque incluye al equipo completo.</p>
          </div>
          <button className="btn btn-primary" type="button" onClick={() => void load()}><RefreshCcw size={17}/> Actualizar</button>
        </div>
      </section>

      {error ? <div className="error" style={{ marginBottom: 16 }}>{adminMessage(error)}</div> : null}
      {message ? <div className="notice" style={{ marginBottom: 16 }}>{adminMessage(message)}</div> : null}

      <section className="card" style={{ padding: 22, marginBottom: 18 }}>
        <div style={{display:"flex",gap:12,alignItems:"center",marginBottom:16}}>
          <div className="module-icon" style={{margin:0}}><Users size={21}/></div>
          <div><h2 style={{margin:0}}>{editing.id ? "Editar regla" : "Nueva regla"}</h2><p className="subtitle">Define reglas operativas de equipo para categorías compatibles. En Limpieza interior, el equipo y las horas provienen del rango horario configurado en Categorías y precios.</p></div>
        </div>
        <form onSubmit={save} className="form">
          <div className="grid" style={{gridTemplateColumns:"repeat(auto-fit,minmax(185px,1fr))"}}>
            <Field label="Categoría"><input className="input" value={editing.category} onChange={(e)=>patch({category:e.target.value})}/></Field>
            <Field label="Modalidad"><select className="select" value={editing.cleaning_mode} onChange={(e)=>patch({cleaning_mode:e.target.value as Rule["cleaning_mode"]})}><option value="standard">Estándar</option><option value="deep">Profunda</option><option value="any">Cualquiera</option></select></Field>
            <Field label="Tipo de propiedad"><select className="select" value={editing.property_type} onChange={(e)=>patch({property_type:e.target.value})}>{propertyOptions.map(([key,label])=><option key={key} value={key}>{label}</option>)}</select></Field>
            <NumberField label="m² desde" value={editing.sqm_min} onChange={(sqm_min)=>patch({sqm_min})}/>
            <NumberField label="m² hasta" value={editing.sqm_max} onChange={(sqm_max)=>patch({sqm_max})}/>
            <NumberField label="Mínimo" value={editing.min_professionals} min={1} max={5} onChange={(min_professionals)=>patch({min_professionals})}/>
            <NumberField label="Recomendado" value={editing.recommended_professionals} min={1} max={5} onChange={(recommended_professionals)=>patch({recommended_professionals})}/>
            <NumberField label="Máximo" value={editing.max_professionals} min={1} max={5} onChange={(max_professionals)=>patch({max_professionals})}/>
            {[2,3,4,5].map((position)=><NumberField key={position} label={`${position}.º profesional adicional`} value={editing.additional_professional_fees[String(position)] || 35} min={1} step="0.01" onChange={(amount)=>patch({additional_professional_fee: position===2 ? amount : editing.additional_professional_fee, additional_professional_fees:{...editing.additional_professional_fees,[String(position)]:Math.max(1,amount)}})}/>)}
            <NumberField label="Prioridad" value={editing.priority} onChange={(priority)=>patch({priority})}/>
            <Field label="Estado"><select className="select" value={editing.is_active ? "active" : "inactive"} onChange={(e)=>patch({is_active:e.target.value==="active"})}><option value="active">Activa</option><option value="inactive">Inactiva</option></select></Field>
          </div>
          <div className="actions">
            <button className="btn btn-primary" disabled={saving}><Save size={17}/> {saving ? "Guardando..." : "Guardar regla"}</button>
            {editing.id ? <button type="button" className="btn btn-soft" onClick={()=>setEditing(emptyRule)}><Plus size={17}/> Nueva regla</button> : null}
          </div>
        </form>
      </section>

      <section className="card table-card">
        <div className="table-wrap">
          <table className="table responsive-table">
            <thead><tr><th>Modalidad</th><th>Propiedad</th><th>Metraje</th><th>Equipo</th><th>2.º</th><th>3.º</th><th>4.º</th><th>5.º</th><th>Estado</th><th>Acciones</th></tr></thead>
            <tbody>
              {loading ? <tr><td colSpan={10} className="empty">Cargando reglas...</td></tr> : grouped.length ? grouped.map((rule)=>(
                <tr key={rule.id || `${rule.cleaning_mode}-${rule.property_type}-${rule.sqm_min}`}>
                  <td><div className="primary">{modeLabel(rule.cleaning_mode)}</div><div className="secondary">{rule.category}</div></td>
                  <td>{propertyLabel(rule.property_type)}</td>
                  <td>{rule.sqm_min}–{rule.sqm_max} m²</td>
                  <td><span className="badge cyan">{rule.min_professionals} mín · {rule.recommended_professionals} recomendado · {rule.max_professionals} máx</span></td>
                  <td>{money(rule.additional_professional_fees['2'])}</td>
                  <td>{money(rule.additional_professional_fees['3'])}</td>
                  <td>{money(rule.additional_professional_fees['4'])}</td>
                  <td>{money(rule.additional_professional_fees['5'])}</td>
                  <td><span className={`badge ${rule.is_active ? "green" : "red"}`}>{rule.is_active ? "Activa" : "Inactiva"}</span></td>
                  <td><div className="actions"><button className="btn btn-soft btn-small" onClick={()=>setEditing(rule)}>Editar</button><button className="btn btn-danger btn-small" onClick={()=>void remove(rule)}><Trash2 size={14}/></button></div></td>
                </tr>
              )) : <tr><td colSpan={10} className="empty">No hay reglas configuradas.</td></tr>}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}

function Field({label,children}:{label:string;children:React.ReactNode}) { return <label><span className="label">{label}</span>{children}</label>; }
function NumberField({label,value,onChange,min=0,max=9999,step="1"}:{label:string;value:number;onChange:(value:number)=>void;min?:number;max?:number;step?:string}) {
  return <Field label={label}><input className="input" type="number" min={min} max={max} step={step} value={value} onChange={(e)=>onChange(Number(e.target.value))}/></Field>;
}
