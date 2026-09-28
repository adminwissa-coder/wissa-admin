"use client";

import { adminMessage } from "@/lib/admin-copy";

import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { useParams, useRouter } from "next/navigation";
import {
  ArrowLeft,
  Banknote,
  CalendarDays,
  CheckCircle2,
  CircleDollarSign,
  Download,
  ExternalLink,
  FileCheck2,
  FileWarning,
  Landmark,
  Mail,
  MessageCircle,
  Phone,
  RefreshCw,
  ShieldCheck,
  Smartphone,
  Star,
  UserRound,
  UserRoundCheck,
  WalletCards,
  XCircle,
} from "lucide-react";
import { supabase } from "@/lib/supabase";
import { formatPanamaDateTime, money } from "@/lib/utils";

type Profile = {
  id: string;
  full_name?: string | null;
  display_name?: string | null;
  email?: string | null;
  phone?: string | null;
  whatsapp_phone?: string | null;
  preferred_contact_method?: string | null;
  city?: string | null;
  bio?: string | null;
  occupation?: string | null;
  languages?: string | null;
  avatar_url?: string | null;
  role?: string | null;
  provider_status?: string | null;
  provider_review_note?: string | null;
  is_verified?: boolean | null;
  is_available?: boolean | null;
  is_suspended?: boolean | null;
  suspended_reason?: string | null;
  rating_avg?: number | null;
  approved_at?: string | null;
  created_at?: string | null;
};

type PayoutMethod = {
  id: string;
  method_type: "yappy" | "bank";
  account_holder?: string | null;
  yappy_phone?: string | null;
  bank_name?: string | null;
  bank_account_type?: string | null;
  bank_account_number?: string | null;
  is_default?: boolean;
  is_active?: boolean;
  is_verified?: boolean;
  verified_at?: string | null;
  updated_at?: string | null;
};

type VerificationDocument = {
  id: string;
  document_type: string;
  storage_path: string;
  storage_bucket?: string | null;
  document_url?: string | null;
  status: "pending" | "approved" | "rejected";
  admin_note?: string | null;
  reviewed_at?: string | null;
  created_at?: string | null;
  is_latest?: boolean;
};

type ProviderPayout = {
  payout_id?: string | null;
  booking_id?: string | null;
  assignment_id?: string | null;
  reservation_code?: string | null;
  service_title?: string | null;
  amount?: number | null;
  tip_amount?: number | null;
  status?: string | null;
  reference?: string | null;
  paid_at?: string | null;
  created_at?: string | null;
  receipt_bucket?: string | null;
  receipt_path?: string | null;
  receipt_name?: string | null;
};

type Detail = {
  profile: Profile;
  payout_methods: PayoutMethod[];
  documents: VerificationDocument[];
  stats: {
    services?: number;
    active_services?: number;
    bookings?: number;
    completed_bookings?: number;
    pending_payout_amount?: number;
    paid_payout_amount?: number;
  };
  readiness: {
    selfie_status?: string;
    police_record_status?: string;
    has_payout_method?: boolean;
    has_contact?: boolean;
    ready?: boolean;
  };
};

export default function ProviderAdminDetail() {
  const params = useParams<{ id: string }>();
  const router = useRouter();
  const providerId = String(params?.id || "");
  const [detail, setDetail] = useState<Detail | null>(null);
  const [loading, setLoading] = useState(true);
  const [processing, setProcessing] = useState<string | null>(null);
  const [profilePhotoUrl, setProfilePhotoUrl] = useState("");
  const [payouts, setPayouts] = useState<ProviderPayout[]>([]);
  const [payoutsLoading, setPayoutsLoading] = useState(false);
  const [err, setErr] = useState("");

  const load = useCallback(async () => {
    if (!providerId) return;
    setLoading(true);
    setErr("");
    const { data, error } = await supabase.rpc("yt_admin_provider_detail_json", { p_provider_id: providerId });
    if (error) {
      setErr(error.message);
      setDetail(null);
    } else {
      setDetail((data || null) as Detail | null);
    }
    setLoading(false);
  }, [providerId]);

  const loadPayouts = useCallback(async () => {
    if (!providerId) return;
    setPayoutsLoading(true);
    const { data, error } = await supabase.rpc("yt_admin_provider_payouts_v65", { p_provider_id: providerId });
    if (!error && Array.isArray(data)) setPayouts(data as ProviderPayout[]);
    else if (error && !/could not find the function|schema cache|does not exist|PGRST202/i.test(error.message)) setErr(error.message);
    setPayoutsLoading(false);
  }, [providerId]);

  useEffect(() => {
    void load();
    void loadPayouts();
  }, [load, loadPayouts]);

  const latestDocuments = useMemo(() => {
    return (detail?.documents || []).filter((document) => document.is_latest !== false);
  }, [detail?.documents]);

  const latestSelfie = useMemo(() => {
    return latestDocuments.find((document) => document.document_type === "selfie") || null;
  }, [latestDocuments]);

  useEffect(() => {
    let cancelled = false;

    async function resolveProfilePhoto() {
      const directAvatar = detail?.profile?.avatar_url?.trim() || "";
      if (directAvatar) {
        if (!cancelled) setProfilePhotoUrl(directAvatar);
        return;
      }

      const storagePath = latestSelfie?.storage_path?.trim() || "";
      if (!storagePath) {
        if (!cancelled) setProfilePhotoUrl("");
        return;
      }

      const bucket = latestSelfie?.storage_bucket?.trim() || "provider-verification";
      const { data, error } = await supabase.storage.from(bucket).createSignedUrl(storagePath, 3600);
      if (cancelled) return;

      if (error || !data?.signedUrl) {
        setProfilePhotoUrl("");
        return;
      }

      setProfilePhotoUrl(data.signedUrl);
    }

    void resolveProfilePhoto();
    return () => {
      cancelled = true;
    };
  }, [detail?.profile?.avatar_url, latestSelfie?.storage_bucket, latestSelfie?.storage_path]);

  const activePayoutMethods = useMemo(
    () => (detail?.payout_methods || []).filter((method) => method.is_active),
    [detail?.payout_methods],
  );

  async function openDocument(document: VerificationDocument, download = false) {
    setProcessing(`open:${document.id}`);
    setErr("");

    const target = download ? null : window.open("about:blank", "_blank");
    if (target) {
      target.opener = null;
      target.document.title = "Abriendo documento…";
    }

    try {
      // v37: resolver SIEMPRE el archivo por el ID de identity_documents en el servidor.
      // Así cada botón queda ligado a su fila/bucket/path exactos y no reutiliza rutas del UI.
      const { data: descriptorData, error: descriptorError } = await supabase.rpc(
        "yt_admin_document_descriptor_v37",
        { p_document_id: document.id },
      );

      if (descriptorError || !descriptorData) {
        throw new Error(descriptorError?.message || "No se pudo resolver el documento solicitado.");
      }

      const descriptor = descriptorData as {
        document_type: string;
        storage_bucket: string;
        storage_path: string;
        original_filename?: string | null;
      };

      const bucket = String(descriptor.storage_bucket || "").trim();
      const storagePath = String(descriptor.storage_path || "").trim();
      if (!bucket || !storagePath) throw new Error("El documento no está disponible. Solicita que se cargue nuevamente.");

      if (!download) {
        const { data, error } = await supabase.storage.from(bucket).createSignedUrl(storagePath, 300);
        if (error || !data?.signedUrl) {
          throw new Error(error?.message || `No se pudo abrir el documento. Inténtalo nuevamente.`);
        }
        if (target) target.location.href = data.signedUrl;
        else window.location.href = data.signedUrl;
        return;
      }

      // Para descargar usamos Storage.download sobre el path exacto, no una URL reutilizable.
      // Esto evita caché del navegador, redirects o referencias cruzadas entre botones.
      const { data: blob, error: downloadError } = await supabase.storage.from(bucket).download(storagePath);
      if (downloadError || !blob) {
        throw new Error(downloadError?.message || `No se pudo descargar el documento. Inténtalo nuevamente.`);
      }
      const originalName = String(descriptor.original_filename || storagePath.split("/").pop() || "archivo");
      const extensionMatch = originalName.match(/\.[A-Za-z0-9]{1,8}$/);
      const extension = extensionMatch?.[0] || extensionForMime(blob.type);
      const fileName = `${safeDownloadName(documentLabel(descriptor.document_type || document.document_type))}-${document.id.slice(0, 8)}${extension}`;
      const objectUrl = URL.createObjectURL(blob);
      const link = window.document.createElement("a");
      link.href = objectUrl;
      link.download = fileName;
      link.rel = "noopener";
      window.document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(objectUrl);
    } catch (error) {
      if (target) target.close();
      setErr(error instanceof Error ? error.message : "No se pudo abrir o descargar el documento.");
    } finally {
      setProcessing(null);
    }
  }

  async function reviewDocument(document: VerificationDocument, decision: "approved" | "rejected") {
    let note: string | null = null;
    if (decision === "rejected") {
      note = window.prompt("Motivo del rechazo. El profesional verá esta observación:", document.admin_note || "")?.trim() || null;
      if (!note) return;
    }

    const confirmed = window.confirm(
      decision === "approved"
        ? `¿Aprobar ${documentLabel(document.document_type)}?`
        : `¿Rechazar ${documentLabel(document.document_type)}?`,
    );
    if (!confirmed) return;

    setProcessing(`review:${document.id}`);
    setErr("");
    const { error } = await supabase.rpc("yt_admin_provider_review_document", {
      p_document_id: document.id,
      p_decision: decision,
      p_note: note,
    });
    if (error) setErr(error.message);
    await load();
    setProcessing(null);
  }

  async function finalizeVerification() {
    if (!detail?.readiness?.ready) return;
    if (!window.confirm("¿Aprobar definitivamente esta cuenta de Ofrecer? Después podrá activar su disponibilidad y recibir servicios.")) return;

    setProcessing("finalize");
    setErr("");
    const { error } = await supabase.rpc("yt_admin_finalize_provider_verification", { p_provider_id: providerId });
    if (error) setErr(error.message);
    await load();
    setProcessing(null);
  }

  async function openPayoutReceipt(payout: ProviderPayout) {
    const bucket = String(payout.receipt_bucket || "provider-payout-receipts").trim();
    const path = String(payout.receipt_path || "").trim();
    if (!path) return;
    setProcessing(`payout-receipt:${payout.payout_id || path}`);
    setErr("");
    const { data, error } = await supabase.storage.from(bucket).createSignedUrl(path, 300);
    if (error || !data?.signedUrl) setErr(error?.message || "No se pudo abrir el comprobante de liquidación.");
    else {
      const target = window.open(data.signedUrl, "_blank", "noopener,noreferrer");
      if (target) target.opener = null;
    }
    setProcessing(null);
  }

  async function togglePayoutVerification(method: PayoutMethod) {
    setProcessing(`payout:${method.id}`);
    setErr("");
    const { error } = await supabase.rpc("yt_admin_verify_provider_payout_method", {
      p_method_id: method.id,
      p_verified: !method.is_verified,
    });
    if (error) setErr(error.message);
    await load();
    setProcessing(null);
  }

  if (loading && !detail) {
    return <div className="card provider-v254-loading"><div className="empty">Cargando perfil de Ofrecer...</div></div>;
  }

  if (!detail) {
    return (
      <>
        <button className="btn btn-soft" onClick={() => router.push("/dashboard/ofrecer")}><ArrowLeft size={15} /> Volver</button>
        {err ? <div className="error" style={{ marginTop: 18 }}>{adminMessage(err)}</div> : null}
      </>
    );
  }

  const profile = detail.profile;
  const name = profile.display_name?.trim() || profile.full_name?.trim() || "Profesional Wissa";
  const approved = Boolean(profile.is_verified) && profile.provider_status === "approved";
  const whatsappDigits = whatsappLinkDigits(profile.whatsapp_phone || profile.phone || "");
  const initials = getInitials(name);
  const providerEmail = profile.email?.trim() || "";

  return (
    <div className="provider-v254-page">
      <section className="provider-v254-hero">
        <div className="provider-v254-hero-main">
          <button className="btn btn-soft provider-v254-back" onClick={() => router.push("/dashboard/ofrecer")} aria-label="Volver a Ofrecer">
            <ArrowLeft size={17} />
          </button>

          <div className={`provider-v254-avatar ${profilePhotoUrl ? "has-photo" : ""}`} aria-label={profilePhotoUrl ? `Foto de ${name}` : `Iniciales de ${name}`}>
            {profilePhotoUrl ? <img src={profilePhotoUrl} alt={`Foto de ${name}`} /> : initials}
          </div>

          <div className="provider-v254-identity">
            <div className="eyebrow">PERFIL DE OFRECER</div>
            <div className="provider-v254-name-row">
              <h1>{name}</h1>
              <span className={`badge ${approved ? "green" : profile.provider_status === "rejected" ? "red" : "yellow"}`}>
                <ShieldCheck size={14} /> {approved ? "Verificado" : profile.provider_status === "rejected" ? "Rechazado" : "Pendiente"}
              </span>
            </div>
            <div className="provider-v254-meta">
              <span><Mail size={14} /> {providerEmail || "Correo no indicado"}</span>
              <span><UserRound size={14} /> {profile.city || "Panamá"}</span>
              <span className={profile.is_available ? "provider-v254-online" : ""}>
                <span className="provider-v254-dot" /> {profile.is_available ? "Disponible" : "No disponible"}
              </span>
            </div>
          </div>

          <button className="btn btn-soft provider-v254-refresh" onClick={() => { void load(); void loadPayouts(); }} disabled={loading || payoutsLoading}>
            <RefreshCw size={15} className={loading || payoutsLoading ? "provider-v254-spin" : ""} /> Actualizar
          </button>
        </div>

        <div className="provider-v254-metrics">
          <Metric icon={<WalletCards size={18} />} label="Servicios" value={String(Number(detail.stats.services || 0))} helper={`${Number(detail.stats.active_services || 0)} activos`} />
          <Metric icon={<CalendarDays size={18} />} label="Reservas" value={String(Number(detail.stats.bookings || 0))} helper={`${Number(detail.stats.completed_bookings || 0)} completadas`} />
          <Metric icon={<CircleDollarSign size={18} />} label="Pendiente por pagar" value={money(Number(detail.stats.pending_payout_amount || 0))} tone="warning" />
          <Metric icon={<Banknote size={18} />} label="Pagado al profesional" value={money(Number(detail.stats.paid_payout_amount || 0))} tone="success" />
        </div>
      </section>

      {err ? <div className="error provider-v254-alert">{adminMessage(err)}</div> : null}
      {profile.provider_review_note ? <div className="notice provider-v254-alert"><strong>Observación administrativa:</strong> {profile.provider_review_note}</div> : null}

      <div className="provider-v254-control-grid">
        <section className="card provider-v254-card provider-v254-contact-card">
          <div className="provider-v254-section-head">
            <div>
              <div className="eyebrow">CONTACTO Y PERFIL</div>
              <h2>Información del profesional</h2>
              <p>Datos operativos para contactar y reconocer al profesional.</p>
            </div>
            <div className="provider-v254-contact-actions">
              {providerEmail ? (
                <a className="btn btn-soft btn-small" href={`mailto:${providerEmail}`}><Mail size={14} /> Correo</a>
              ) : null}
              {profile.phone ? (
                <a className="btn btn-soft btn-small" href={`tel:${digits(profile.phone)}`}><Phone size={14} /> Llamar</a>
              ) : null}
              {whatsappDigits ? (
                <a className="btn btn-green btn-small" href={`https://wa.me/${whatsappDigits}`} target="_blank" rel="noreferrer"><MessageCircle size={14} /> WhatsApp</a>
              ) : null}
            </div>
          </div>

          <div className="provider-v254-info-grid">
            <InfoTile label="Correo" value={providerEmail || "No indicado"} />
            <InfoTile label="Teléfono" value={profile.phone || "No indicado"} />
            <InfoTile label="WhatsApp" value={profile.whatsapp_phone || "No indicado"} />
            <InfoTile label="Contacto preferido" value={profile.preferred_contact_method === "phone" ? "Llamada" : "WhatsApp"} />
            <InfoTile label="Ocupación" value={profile.occupation || "No indicada"} />
            <InfoTile label="Calificación" value={`${Number(profile.rating_avg || 0).toFixed(1)} / 5.0`} icon={<Star size={14} />} />
            <InfoTile label="Cuenta creada" value={profile.created_at ? formatPanamaDateTime(profile.created_at) : "—"} />
          </div>
        </section>

        <section className="card provider-v254-card provider-v254-verification-card">
          <div className="provider-v254-section-head">
            <div>
              <div className="eyebrow">CONTROL DE ACCESO</div>
              <h2>Requisitos para trabajar</h2>
              <p>El profesional solo se habilita cuando cumple todos los requisitos.</p>
            </div>
            <div className={`provider-v254-readiness ${approved ? "is-approved" : detail.readiness.ready ? "is-ready" : "is-pending"}`}>
              {approved ? "APROBADO" : detail.readiness.ready ? "LISTO PARA APROBAR" : "INCOMPLETO"}
            </div>
          </div>

          <div className="provider-v254-requirements">
            <RequirementCard label="Foto personal" status={detail.readiness.selfie_status} />
            <RequirementCard label="Récord policivo" status={detail.readiness.police_record_status} />
            <RequirementCard label="Contacto" ok={Boolean(detail.readiness.has_contact)} value={detail.readiness.has_contact ? "Configurado" : "Falta teléfono/WhatsApp"} />
            <RequirementCard label="Método de cobro" ok={Boolean(detail.readiness.has_payout_method)} value={detail.readiness.has_payout_method ? "Configurado" : "Falta Yappy/banco"} />
          </div>

          {approved ? (
            <div className="provider-v254-approved-box">
              <CheckCircle2 size={18} />
              <div><strong>Profesional habilitado</strong><span>Puede activar disponibilidad y recibir servicios.</span></div>
            </div>
          ) : (
            <button
              className="btn btn-primary provider-v254-finalize"
              disabled={!detail.readiness.ready || processing === "finalize"}
              onClick={() => void finalizeVerification()}
            >
              <UserRoundCheck size={16} /> {processing === "finalize" ? "Aprobando..." : "Aprobar y habilitar profesional"}
            </button>
          )}
        </section>
      </div>

      <section className="card provider-v254-card provider-v254-payout-section">
        <div className="provider-v254-section-head provider-v254-section-head-split">
          <div>
            <div className="eyebrow">DATOS DE COBRO</div>
            <h2>Yappy y cuenta bancaria</h2>
            <p>Información privada usada únicamente para liquidar servicios al profesional.</p>
          </div>
          <span className="provider-v254-private-pill"><ShieldCheck size={14} /> Datos privados</span>
        </div>

        {activePayoutMethods.length ? (
          <div className="provider-v254-payout-grid">
            {activePayoutMethods.map((method) => (
              <article className="provider-v254-payout-card" key={method.id}>
                <div className="provider-v254-payout-top">
                  <div className={`provider-v254-payment-icon ${method.method_type === "yappy" ? "is-yappy" : "is-bank"}`}>
                    {method.method_type === "yappy" ? <Smartphone size={20} /> : <Landmark size={20} />}
                  </div>
                  <div className="provider-v254-payout-title">
                    <div>
                      <h3>{method.method_type === "yappy" ? "Yappy" : "Cuenta bancaria"}</h3>
                      <p>{method.is_default ? "Método predeterminado" : "Método alternativo"}</p>
                    </div>
                    <span className={`badge ${method.is_verified ? "green" : "yellow"}`}>
                      {method.is_verified ? "Validado" : "Sin validar"}
                    </span>
                  </div>
                </div>

                <div className="provider-v254-payment-data">
                  <CompactRow label="Titular" value={method.account_holder || "—"} />
                  {method.method_type === "yappy" ? (
                    <CompactRow label="Número Yappy" value={method.yappy_phone || "—"} emphasize />
                  ) : (
                    <>
                      <CompactRow label="Banco" value={method.bank_name || "—"} />
                      <CompactRow label="Tipo de cuenta" value={method.bank_account_type || "No indicado"} />
                      <CompactRow label="Número de cuenta" value={method.bank_account_number || "—"} emphasize />
                    </>
                  )}
                </div>

                <button
                  className={`btn ${method.is_verified ? "btn-soft" : "btn-green"} btn-small provider-v254-verify-payment`}
                  disabled={processing === `payout:${method.id}`}
                  onClick={() => void togglePayoutVerification(method)}
                >
                  <CheckCircle2 size={14} /> {method.is_verified ? "Quitar validación" : "Validar datos de cobro"}
                </button>
              </article>
            ))}
          </div>
        ) : (
          <div className="provider-v254-empty-payment">
            <WalletCards size={24} />
            <div><strong>Sin método de cobro</strong><span>El profesional todavía no ha configurado Yappy ni cuenta bancaria.</span></div>
          </div>
        )}
      </section>

      <section className="card provider-v254-card" style={{ marginBottom: 18 }}>
        <div className="provider-v254-section-head provider-v254-section-head-split">
          <div>
            <div className="eyebrow">LIQUIDACIONES</div>
            <h2>Historial de pagos al profesional</h2>
            <p>Cada integrante del equipo conserva su liquidación y comprobante de pago individual.</p>
          </div>
          <button className="btn btn-soft btn-small" onClick={() => void loadPayouts()} disabled={payoutsLoading}>
            <RefreshCw size={14} /> {payoutsLoading ? "Actualizando..." : "Actualizar"}
          </button>
        </div>
        {payoutsLoading && payouts.length === 0 ? (
          <div className="empty">Cargando liquidaciones...</div>
        ) : payouts.length ? (
          <div className="table-wrap">
            <table className="table">
              <thead><tr><th>Servicio</th><th>Reserva</th><th>Monto</th><th>Propina</th><th>Estado</th><th>Fecha</th><th>Comprobante</th></tr></thead>
              <tbody>
                {payouts.map((payout, index) => (
                  <tr key={String(payout.payout_id || payout.assignment_id || index)}>
                    <td><div className="primary">{payout.service_title || "Servicio"}</div><div className="secondary">{payout.reference || "Sin referencia"}</div></td>
                    <td>{payout.reservation_code || "—"}</td>
                    <td><strong>{money(Number(payout.amount || 0))}</strong></td>
                    <td>{money(Number(payout.tip_amount || 0))}</td>
                    <td><span className={`badge ${String(payout.status || "").toLowerCase() === "paid" ? "green" : "yellow"}`}>{String(payout.status || "Pendiente")}</span></td>
                    <td>{payout.paid_at || payout.created_at ? formatPanamaDateTime(payout.paid_at || payout.created_at) : "—"}</td>
                    <td>
                      {payout.receipt_path ? (
                        <button className="btn btn-soft btn-small" disabled={processing === `payout-receipt:${payout.payout_id || payout.receipt_path}`} onClick={() => void openPayoutReceipt(payout)}>
                          <ExternalLink size={14} /> Ver comprobante
                        </button>
                      ) : <span className="secondary">Pendiente</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <div className="provider-v254-empty-payment">
            <Banknote size={24} />
            <div><strong>Sin liquidaciones registradas</strong><span>Aún no hay pagos registrados para este profesional.</span></div>
          </div>
        )}
      </section>

      <section className="card provider-v254-card provider-v254-documents-section">
        <div className="provider-v254-section-head provider-v254-section-head-split">
          <div>
            <div className="eyebrow">VERIFICACIÓN DOCUMENTAL</div>
            <h2>Documentos privados</h2>
            <p>Abre, descarga, aprueba o rechaza cada documento desde un solo lugar.</p>
          </div>
          <span className="provider-v254-private-pill"><ShieldCheck size={14} /> Enlace temporal seguro</span>
        </div>

        {latestDocuments.length === 0 ? (
          <div className="provider-v254-empty-payment">
            <FileWarning size={24} />
            <div><strong>No hay documentos enviados</strong><span>Cuando el profesional cargue sus archivos aparecerán aquí.</span></div>
          </div>
        ) : (
          <div className="provider-v254-document-list">
            {latestDocuments.map((document) => (
              <article className="provider-v254-document-row" key={document.id}>
                <div className={`provider-v254-doc-icon status-${document.status}`}>
                  {document.status === "approved" ? <FileCheck2 size={20} /> : <FileWarning size={20} />}
                </div>

                <div className="provider-v254-doc-main">
                  <div className="provider-v254-doc-title-row">
                    <div>
                      <h3>{documentLabel(document.document_type)}</h3>
                      <p>{document.created_at ? `Enviado ${formatPanamaDateTime(document.created_at)}` : "Fecha no disponible"}</p>
                    </div>
                    <DocumentStatus status={document.status} />
                  </div>
                  {document.admin_note ? (
                    <div className="provider-v254-doc-note"><strong>Observación:</strong> {document.admin_note}</div>
                  ) : null}
                </div>

                <div className="provider-v254-doc-actions">
                  <button className="btn btn-soft btn-small" disabled={processing === `open:${document.id}`} onClick={() => void openDocument(document, false)}>
                    <ExternalLink size={14} /> Abrir
                  </button>
                  <button className="btn btn-soft btn-small" disabled={processing === `open:${document.id}`} onClick={() => void openDocument(document, true)}>
                    <Download size={14} /> Descargar
                  </button>
                  <span className="provider-v254-action-divider" />
                  <button className="btn btn-green btn-small" disabled={processing === `review:${document.id}` || document.status === "approved"} onClick={() => void reviewDocument(document, "approved")}>
                    <CheckCircle2 size={14} /> Aprobar
                  </button>
                  <button className="btn btn-danger btn-small" disabled={processing === `review:${document.id}` || document.status === "rejected"} onClick={() => void reviewDocument(document, "rejected")}>
                    <XCircle size={14} /> Rechazar
                  </button>
                </div>
              </article>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

function Metric({
  icon,
  label,
  value,
  helper,
  tone,
}: {
  icon: ReactNode;
  label: string;
  value: string;
  helper?: string;
  tone?: "success" | "warning";
}) {
  return (
    <div className={`provider-v254-metric ${tone ? `is-${tone}` : ""}`}>
      <div className="provider-v254-metric-icon">{icon}</div>
      <div>
        <span>{label}</span>
        <strong>{value}</strong>
        {helper ? <small>{helper}</small> : null}
      </div>
    </div>
  );
}

function InfoTile({ label, value, icon }: { label: string; value: string | number; icon?: ReactNode }) {
  return (
    <div className="provider-v254-info-tile">
      <span>{label}</span>
      <strong>{icon}{value}</strong>
    </div>
  );
}

function CompactRow({ label, value, emphasize = false }: { label: string; value: string; emphasize?: boolean }) {
  return (
    <div className="provider-v254-compact-row">
      <span>{label}</span>
      <strong className={emphasize ? "is-emphasis" : ""}>{value}</strong>
    </div>
  );
}

function RequirementCard({
  label,
  status,
  ok,
  value,
}: {
  label: string;
  status?: string;
  ok?: boolean;
  value?: string;
}) {
  const resolvedOk = typeof ok === "boolean" ? ok : status === "approved";
  const resolvedValue = value || statusText(status);
  const isRejected = status === "rejected";
  const isPending = status === "pending";
  const className = resolvedOk ? "is-ok" : isRejected ? "is-bad" : isPending ? "is-waiting" : "is-missing";

  return (
    <div className={`provider-v254-requirement ${className}`}>
      <div className="provider-v254-requirement-icon">
        {resolvedOk ? <CheckCircle2 size={17} /> : <FileWarning size={17} />}
      </div>
      <div>
        <span>{label}</span>
        <strong>{resolvedValue}</strong>
      </div>
    </div>
  );
}

function DocumentStatus({ status }: { status: VerificationDocument["status"] }) {
  if (status === "approved") return <span className="badge green"><CheckCircle2 size={13} /> Aprobado</span>;
  if (status === "rejected") return <span className="badge red"><XCircle size={13} /> Rechazado</span>;
  return <span className="badge yellow"><FileWarning size={13} /> Pendiente</span>;
}

function statusText(value?: string | null) {
  if (value === "approved") return "Aprobado";
  if (value === "rejected") return "Rechazado";
  if (value === "pending") return "Pendiente de revisión";
  return "Falta cargar";
}

function documentLabel(type: string) {
  if (type === "selfie") return "Foto personal";
  if (type === "police_record" || type === "record_policivo") return "Récord policivo";
  if (type === "cedula" || type === "identity") return "Cédula";
  return type;
}

function safeDownloadName(value: string) {
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^A-Za-z0-9_-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "") || "documento";
}

function extensionForMime(mime: string) {
  const value = String(mime || "").toLowerCase();
  if (value.includes("pdf")) return ".pdf";
  if (value.includes("png")) return ".png";
  if (value.includes("webp")) return ".webp";
  if (value.includes("jpeg") || value.includes("jpg")) return ".jpg";
  return "";
}

function digits(value: string) {
  return value.replace(/\D/g, "");
}

function whatsappLinkDigits(value: string) {
  const raw = digits(value);
  if (raw.length === 8) return `507${raw}`;
  return raw;
}

function getInitials(value: string) {
  const parts = value.trim().split(/\s+/).filter(Boolean).slice(0, 2);
  return parts.map((part) => part[0]?.toUpperCase() || "").join("") || "W";
}
