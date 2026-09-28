"use client";

import { FormEvent, useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { CheckCircle2, CreditCard, KeyRound, Moon, ShieldCheck, Sun } from "lucide-react";
import { ensureCompanyFromCurrentUser } from "@/lib/company-web";
import { supabase } from "@/lib/supabase";

type ThemeMode = "light" | "dark";
type PlanProvider = "yappy" | "paguelofacil";

export default function CompanyRegisterPage() {
  const router = useRouter();
  const [ownerName, setOwnerName] = useState("");
  const [companyName, setCompanyName] = useState("");
  const [legalName, setLegalName] = useState("");
  const [ruc, setRuc] = useState("");
  const [phone, setPhone] = useState("");
  const [city, setCity] = useState("Panamá");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [provider, setProvider] = useState<PlanProvider>("yappy");
  const [acceptedLegal, setAcceptedLegal] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const [theme, setTheme] = useState<ThemeMode>("light");
  const [themeLoaded, setThemeLoaded] = useState(false);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      const saved = window.localStorage.getItem("yt-company-web-theme");
      if (saved === "dark" || saved === "light") setTheme(saved);
      setThemeLoaded(true);
    }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  useEffect(() => {
    if (themeLoaded) window.localStorage.setItem("yt-company-web-theme", theme);
  }, [theme, themeLoaded]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError("");
    setSuccess("");

    if (!acceptedLegal) {
      setError("Debes aceptar la Política de privacidad y los Términos para crear la empresa.");
      return;
    }

    if (!ownerName.trim() || !companyName.trim() || !email.trim() || password.length < 6) {
      setError("Completa propietario, empresa, correo y una contraseña de al menos 6 caracteres.");
      return;
    }

    setLoading(true);
    const normalizedEmail = email.trim().toLowerCase();
    const redirectTo = `${window.location.origin}/empresa/login`;

    const { data, error: signUpError } = await supabase.auth.signUp({
      email: normalizedEmail,
      password,
      options: {
        emailRedirectTo: redirectTo,
        data: {
          full_name: ownerName.trim(),
          phone: phone.trim(),
          city: city.trim(),
          role: "company",
          app_role: "company",
          account_type: "company",
          mode_preference: "company",
          theme_preference: "light",
          company_name: companyName.trim(),
          company_legal_name: legalName.trim(),
          company_ruc: ruc.trim(),
          company_plan_provider: provider,
          accepted_terms: true,
          accepted_terms_at: new Date().toISOString(),
          accepted_privacy: true,
          accepted_privacy_at: new Date().toISOString(),
        },
      },
    });

    if (signUpError) {
      setError(signUpError.message);
      setLoading(false);
      return;
    }

    try {
      if (data.session) {
        await ensureCompanyFromCurrentUser({
          ownerName,
          companyName,
          legalName,
          ruc,
          phone,
          email: normalizedEmail,
          city,
        });
        router.replace("/empresa");
        return;
      }

      setSuccess("Empresa creada. Confirma tu correo y luego entra al portal para activar la membresía.");
    } catch (ensureError) {
      setError(ensureError instanceof Error ? ensureError.message : "La cuenta fue creada, pero no se pudo vincular la empresa.");
    } finally {
      setLoading(false);
    }
  }

  return (
    <main className={`company-web-bg company-theme-${theme} login-wrap company-register-wrap`}>
      <button className="btn btn-soft btn-small auth-theme-toggle" onClick={() => setTheme(theme === "light" ? "dark" : "light")}>
        {theme === "light" ? <Moon size={16} /> : <Sun size={16} />}
        {theme === "light" ? "Oscuro" : "Claro"}
      </button>

      <section className="login-card company-register-card">
        <div className="brand-row auth-brand-row">
          <img src="/brand/wissa-icon.png" alt="Wissa" className="auth-brand-logo" />
          <div>
            <div className="eyebrow">Wissa Empresas</div>
            <strong>Soluciones para tu hogar</strong>
          </div>
        </div>

        <h1 className="title">Activa tu empresa en Wissa</h1>
        <p className="subtitle">
          Registra tu empresa, confirma el correo y activa el plan con Yappy o PagueloFácil
          para gestionar sedes, personal, reservas y pagos.
        </p>

        <div className="company-auth-benefits">
          <span><ShieldCheck size={16} /> Gestión empresarial</span>
          <span><CreditCard size={16} /> Membresía protegida</span>
          <span><CheckCircle2 size={16} /> Personal y servicios</span>
        </div>

        <div className="company-register-steps" aria-label="Flujo de activación empresarial">
          <span><strong>1</strong> Cuenta</span>
          <span><strong>2</strong> Pago</span>
          <span><strong>3</strong> Gestión</span>
        </div>

        {error ? <div className="error" style={{ marginTop: 18 }}>{error}</div> : null}
        {success ? <div className="success" style={{ marginTop: 18 }}>{success}</div> : null}

        <form className="form company-register-form" onSubmit={submit}>
          <label>
            <div className="label">Propietario</div>
            <input className="input" value={ownerName} onChange={(event) => setOwnerName(event.target.value)} placeholder="Nombre completo" required />
          </label>
          <label>
            <div className="label">Empresa</div>
            <input className="input" value={companyName} onChange={(event) => setCompanyName(event.target.value)} placeholder="Nombre comercial" required />
          </label>
          <label>
            <div className="label">Razón social</div>
            <input className="input" value={legalName} onChange={(event) => setLegalName(event.target.value)} placeholder="Opcional" />
          </label>
          <label>
            <div className="label">RUC</div>
            <input className="input" value={ruc} onChange={(event) => setRuc(event.target.value)} placeholder="Opcional" />
          </label>
          <label>
            <div className="label">Teléfono</div>
            <input className="input" value={phone} onChange={(event) => setPhone(event.target.value)} placeholder="Número de contacto" />
          </label>
          <label>
            <div className="label">Ciudad</div>
            <input className="input" value={city} onChange={(event) => setCity(event.target.value)} placeholder="Panamá" />
          </label>
          <label>
            <div className="label">Correo</div>
            <input className="input" type="email" value={email} onChange={(event) => setEmail(event.target.value)} required />
          </label>
          <label>
            <div className="label">Contraseña</div>
            <input className="input" type="password" value={password} onChange={(event) => setPassword(event.target.value)} minLength={6} required />
          </label>

          <div className="company-payment-choice" role="group" aria-label="Método de pago preferido">
            {(["yappy", "paguelofacil"] as PlanProvider[]).map((method) => (
              <button
                className={`company-payment-chip ${provider === method ? "active" : ""}`}
                key={method}
                type="button"
                onClick={() => setProvider(method)}
              >
                <strong>{method === "yappy" ? "Yappy" : "PagueloFácil"}</strong>
                <small>{method === "yappy" ? "Pago móvil rápido" : "Tarjeta o enlace web"}</small>
              </button>
            ))}
          </div>

          <label className="legal-check-row">
            <input type="checkbox" checked={acceptedLegal} onChange={(event) => setAcceptedLegal(event.target.checked)} />
            <span>
              Acepto la <Link href="/legal/privacy" target="_blank">Política de privacidad</Link> y los <Link href="/legal/terms" target="_blank">Términos y condiciones</Link>.
            </span>
          </label>

          <button className="btn btn-primary" disabled={loading || !acceptedLegal}>{loading ? "Creando..." : "Crear empresa y continuar"}</button>
        </form>

        <div className="auth-footer-actions">
          <Link className="btn btn-soft" href="/empresa/login"><KeyRound size={16} /> Ya tengo cuenta</Link>
        </div>
      </section>
    </main>
  );
}
