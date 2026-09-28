"use client";

import { FormEvent, useState } from "react";
import Link from "next/link";
import { ArrowLeft, CheckCircle2, Mail, Trash2 } from "lucide-react";
import { supabase } from "@/lib/supabase";

export default function DeleteAccountPage() {
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const [reason, setReason] = useState("");
  const [accepted, setAccepted] = useState(false);
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setMessage("");
    setError("");

    if (!email.trim() || !accepted) {
      setError("Escribe tu correo y confirma la solicitud para continuar.");
      return;
    }

    try {
      setLoading(true);
      const { error: rpcError } = await supabase.rpc("yt_public_request_account_deletion", {
        p_email: email.trim().toLowerCase(),
        p_reason: reason.trim() || null,
        p_name: name.trim() || null,
      });

      if (rpcError) throw rpcError;

      setMessage(
        "Solicitud recibida. Si el correo existe en Wissa, completaremos la eliminación o anonimización dentro de 30 días calendario y enviaremos una confirmación.",
      );
      setEmail("");
      setName("");
      setReason("");
      setAccepted(false);
    } catch (submitError) {
      setError(submitError instanceof Error ? submitError.message : "No se pudo registrar la solicitud.");
    } finally {
      setLoading(false);
    }
  };

  return (
    <main className="legal-public-bg">
      <section className="legal-public-shell legal-delete-shell">
        <Link href="/legal" className="legal-back-link">
          <ArrowLeft size={16} /> Legal
        </Link>

        <div className="legal-public-hero legal-delete-hero">
          <div>
            <p className="legal-public-eyebrow">Privacidad y cuenta</p>
            <h1>Solicitar eliminación de cuenta Wissa</h1>
            <p>
              Puedes iniciar esta solicitud desde Wissa o desde este
              formulario público. No compartas contraseñas ni información
              sensible. La solicitud es gratuita.
            </p>
          </div>
          <span className="legal-public-icon legal-delete-icon">
            <Trash2 size={30} />
          </span>
        </div>

        <div className="legal-delete-grid">
          <form className="legal-delete-form" onSubmit={submit}>
            <label>
              Correo de la cuenta
              <input
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                type="email"
                placeholder="tu-correo@ejemplo.com"
                required
              />
            </label>

            <label>
              Nombre opcional
              <input
                value={name}
                onChange={(event) => setName(event.target.value)}
                placeholder="Nombre asociado a la cuenta"
              />
            </label>

            <label>
              Motivo opcional
              <textarea
                value={reason}
                onChange={(event) => setReason(event.target.value)}
                placeholder="Cuéntanos el motivo si deseas agregar contexto"
                rows={5}
              />
            </label>

            <label className="legal-delete-check">
              <input
                checked={accepted}
                onChange={(event) => setAccepted(event.target.checked)}
                type="checkbox"
              />
              <span>
                Confirmo que deseo solicitar eliminación de mi cuenta y datos
                visibles, entendiendo que algunos registros pueden conservarse
                por seguridad, pagos, soporte o cumplimiento.
              </span>
            </label>

            {message ? (
              <div className="legal-success">
                <CheckCircle2 size={18} /> {message}
              </div>
            ) : null}
            {error ? <div className="legal-error">{error}</div> : null}

            <button className="legal-submit" type="submit" disabled={loading}>
              {loading ? "Enviando..." : "Enviar solicitud"}
            </button>
          </form>

          <aside className="legal-delete-aside">
            <h2>Qué pasará después</h2>
            <ul>
              <li>Se registrará una solicitud administrativa.</li>
              <li>La cuenta dejará de estar disponible cuando finalice el proceso.</li>
              <li>Los datos visibles se eliminarán o anonimizarán dentro de 30 días calendario.</li>
              <li>Recibirás una confirmación en el correo asociado cuando termine.</li>
              <li>Reservas, pagos o reportes podrán conservarse solo por obligaciones legales, contables, seguridad o disputas.</li>
            </ul>
            <a className="legal-inline-action" href="mailto:soporte@wissa.app">
              <Mail size={16} /> soporte@wissa.app
            </a>
          </aside>
        </div>
      </section>
    </main>
  );
}
