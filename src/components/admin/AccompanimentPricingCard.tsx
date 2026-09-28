"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Plus, Save, Trash2, UsersRound } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { money } from "@/lib/utils";

type AccompanimentActivity = {
  key: string;
  label_es: string;
  label_en: string;
  active: boolean;
  requires_detail: boolean;
};

type AccompanimentPricing = {
  hourly_rate: number;
  minimum_hours: number;
  maximum_hours: number;
  platform_commission_rate: number;
  platform_usage_fee: number;
  itbms_rate: number;
  detail_max_length: number;
  activities: AccompanimentActivity[];
};

const defaultActivities: AccompanimentActivity[] = [
  { key: "appointment", label_es: "Cita / encuentro", label_en: "Appointment / meetup", active: true, requires_detail: false },
  { key: "coffee_meal", label_es: "Café / comida", label_en: "Coffee / meal", active: true, requires_detail: false },
  { key: "shopping", label_es: "Compras", label_en: "Shopping", active: true, requires_detail: false },
  { key: "errands", label_es: "Diligencias", label_en: "Errands", active: true, requires_detail: false },
  { key: "event", label_es: "Evento / actividad", label_en: "Event / activity", active: true, requires_detail: false },
  { key: "walk_talk", label_es: "Paseo / conversación", label_en: "Walk / conversation", active: true, requires_detail: false },
  { key: "other", label_es: "Otro", label_en: "Other", active: true, requires_detail: true },
];

const defaults: AccompanimentPricing = {
  hourly_rate: 15,
  minimum_hours: 2,
  maximum_hours: 12,
  platform_commission_rate: 0.2,
  platform_usage_fee: 2,
  itbms_rate: 0.07,
  detail_max_length: 400,
  activities: defaultActivities,
};

function numberValue(value: unknown, fallback: number) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

function normalizeActivities(value: unknown): AccompanimentActivity[] {
  if (!Array.isArray(value)) return defaultActivities;
  const rows = value
    .map((item, index) => {
      if (!item || typeof item !== "object" || Array.isArray(item)) return null;
      const row = item as Record<string, unknown>;
      const key = String(row.key || `option_${index + 1}`).trim();
      const labelEs = String(row.label_es || row.label || "").trim();
      const labelEn = String(row.label_en || labelEs).trim();
      if (!key || !labelEs) return null;
      return {
        key,
        label_es: labelEs,
        label_en: labelEn || labelEs,
        active: row.active !== false,
        requires_detail: row.requires_detail === true,
      } satisfies AccompanimentActivity;
    })
    .filter((item): item is AccompanimentActivity => Boolean(item));
  return rows.length ? rows : defaultActivities;
}

function slugActivity(label: string, index: number) {
  const slug = label
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 32);
  return slug || `custom_${index + 1}`;
}

export default function AccompanimentPricingCard({ embedded = false }: { embedded?: boolean }) {
  const [pricing, setPricing] = useState<AccompanimentPricing>(defaults);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    const { data, error: loadError } = await supabase.from("app_settings").select("value").eq("key", "accompaniment_pricing").maybeSingle();
    if (loadError) {
      setError("No pudimos cargar la configuración de Acompañamiento.");
      setLoading(false);
      return;
    }
    const raw = (data?.value && typeof data.value === "object" ? data.value : {}) as Record<string, unknown>;
    setPricing({
      hourly_rate: numberValue(raw.hourly_rate, defaults.hourly_rate),
      minimum_hours: Math.max(2, Math.round(numberValue(raw.minimum_hours, defaults.minimum_hours))),
      maximum_hours: Math.max(2, Math.round(numberValue(raw.maximum_hours, defaults.maximum_hours))),
      platform_commission_rate: 0.2,
      platform_usage_fee: numberValue(raw.platform_usage_fee, defaults.platform_usage_fee),
      itbms_rate: numberValue(raw.itbms_rate, defaults.itbms_rate),
      detail_max_length: Math.max(100, Math.min(600, Math.round(numberValue(raw.detail_max_length, defaults.detail_max_length)))),
      activities: normalizeActivities(raw.activities),
    });
    setLoading(false);
  }, []);

  useEffect(() => { void load(); }, [load]);

  async function save() {
    setSaving(true);
    setMessage("");
    setError("");
    const sanitizedActivities = pricing.activities
      .map((item, index) => ({
        ...item,
        key: String(item.key || slugActivity(item.label_es, index)).trim(),
        label_es: item.label_es.trim(),
        label_en: (item.label_en || item.label_es).trim(),
      }))
      .filter((item) => item.key && item.label_es);

    if (!sanitizedActivities.some((item) => item.active)) {
      setError("Debe existir al menos una actividad activa para Acompañamiento.");
      setSaving(false);
      return;
    }

    const value = {
      ...pricing,
      minimum_hours: Math.max(2, Math.round(pricing.minimum_hours)),
      maximum_hours: Math.max(Math.max(2, Math.round(pricing.minimum_hours)), Math.round(pricing.maximum_hours)),
      detail_max_length: Math.max(100, Math.min(600, Math.round(pricing.detail_max_length))),
      platform_commission_rate: 0.2,
      currency: "USD",
      presentation_mode: "single_rate",
      activities: sanitizedActivities,
    };
    const { error: saveError } = await supabase.rpc("yt_admin_update_accompaniment_config_v751", { p_value: value });
    if (saveError) {
      setError("No pudimos guardar Acompañamiento. Revisa los datos e inténtalo nuevamente.");
    } else {
      setPricing(value);
      setMessage("Acompañamiento actualizado. Las nuevas reservas usarán esta configuración.");
    }
    setSaving(false);
  }

  function updateActivity(index: number, patch: Partial<AccompanimentActivity>) {
    setPricing((current) => ({
      ...current,
      activities: current.activities.map((item, itemIndex) => itemIndex === index ? { ...item, ...patch } : item),
    }));
  }

  function addActivity() {
    setPricing((current) => {
      const index = current.activities.length;
      return {
        ...current,
        activities: [...current.activities, {
          key: `custom_${Date.now()}`,
          label_es: "Nueva opción",
          label_en: "New option",
          active: true,
          requires_detail: false,
        }],
      };
    });
  }

  function removeActivity(index: number) {
    setPricing((current) => ({ ...current, activities: current.activities.filter((_, itemIndex) => itemIndex !== index) }));
  }

  const minimumService = pricing.hourly_rate * Math.max(2, pricing.minimum_hours);
  const professionalShare = minimumService * 0.8;
  const wissaShare = minimumService * 0.2;
  const publicMinimumTotal = useMemo(() => {
    const preTax = minimumService + pricing.platform_usage_fee;
    return preTax + preTax * pricing.itbms_rate;
  }, [minimumService, pricing.itbms_rate, pricing.platform_usage_fee]);

  return (
    <section className={`accompaniment-pricing-card ${embedded ? "accompaniment-pricing-embedded" : ""}`}>
      <div className="accompaniment-pricing-head">
        <span className="simple-hub-icon"><UsersRound size={22} /></span>
        <div>
          <span className="accompaniment-eyebrow">Acompañamiento</span>
          <h3>Tarifa y actividades</h3>
          <p>Configura el precio por hora y las opciones que verá el cliente al crear la reserva.</p>
        </div>
      </div>

      {error ? <div className="error">{error}</div> : null}
      {message ? <div className="notice">{message}</div> : null}

      <div className="accompaniment-pricing-grid">
        <label><span>Tarifa por hora</span><div className="price-input"><b>USD</b><input type="number" min="1" step="0.5" value={pricing.hourly_rate} onChange={(e) => setPricing((v) => ({ ...v, hourly_rate: numberValue(e.target.value, v.hourly_rate) }))} /></div></label>
        <label><span>Mínimo de horas</span><input className="input" type="number" min="2" max="12" value={pricing.minimum_hours} onChange={(e) => setPricing((v) => ({ ...v, minimum_hours: Math.max(2, Number(e.target.value) || 2) }))} /></label>
        <label><span>Máximo de horas</span><input className="input" type="number" min="2" max="24" value={pricing.maximum_hours} onChange={(e) => setPricing((v) => ({ ...v, maximum_hours: Math.max(2, Number(e.target.value) || 12) }))} /></label>
        <label><span>Detalle máximo</span><div className="price-input"><input type="number" min="100" max="600" step="25" value={pricing.detail_max_length} onChange={(e) => setPricing((v) => ({ ...v, detail_max_length: Math.max(100, Math.min(600, Number(e.target.value) || 400)) }))} /><b>car.</b></div></label>
      </div>

      <div className="accompaniment-preview">
        <span>Reserva mínima <strong>{money(minimumService)}</strong></span>
        <span>Total cliente aprox. <strong>{money(publicMinimumTotal)}</strong></span>
        <span>Profesional <strong>{money(professionalShare)}</strong></span>
        <span>Wissa <strong>{money(wissaShare)}</strong></span>
      </div>

      <div className="accompaniment-activity-editor">
        <div className="accompaniment-activity-titlebar">
          <div>
            <span className="accompaniment-eyebrow">Opciones del cliente</span>
            <h4>¿Qué te gustaría hacer?</h4>
            <p>Estas opciones aparecen en Mobile. Cambiar el nombre no modifica reservas históricas ya creadas.</p>
          </div>
          <button className="btn" type="button" onClick={addActivity}><Plus size={16} /> Agregar opción</button>
        </div>

        <div className="accompaniment-activity-list">
          {pricing.activities.map((activity, index) => (
            <div className="accompaniment-activity-row" key={activity.key || index}>
              <div className="accompaniment-activity-index">{index + 1}</div>
              <label className="accompaniment-activity-field"><span>Español</span><input className="input" value={activity.label_es} onChange={(e) => updateActivity(index, { label_es: e.target.value })} /></label>
              <label className="accompaniment-activity-field"><span>Inglés</span><input className="input" value={activity.label_en} onChange={(e) => updateActivity(index, { label_en: e.target.value })} /></label>
              <label className="accompaniment-check"><input type="checkbox" checked={activity.active} onChange={(e) => updateActivity(index, { active: e.target.checked })} /><span>Activa</span></label>
              <label className="accompaniment-check"><input type="checkbox" checked={activity.requires_detail} onChange={(e) => updateActivity(index, { requires_detail: e.target.checked })} /><span>Detalle obligatorio</span></label>
              <button className="icon-btn" type="button" aria-label={`Eliminar ${activity.label_es}`} onClick={() => removeActivity(index)} disabled={pricing.activities.length <= 1}><Trash2 size={16} /></button>
            </div>
          ))}
        </div>
      </div>

      <div className="accompaniment-save-row">
        <button className="btn btn-primary" type="button" disabled={loading || saving} onClick={() => void save()}><Save size={16} />{saving ? "Guardando…" : "Guardar Acompañamiento"}</button>
        <span>Reparto fijo: 80% profesional / 20% Wissa.</span>
      </div>
    </section>
  );
}
