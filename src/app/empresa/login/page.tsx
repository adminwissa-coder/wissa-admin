"use client";

import { FormEvent, useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Moon, PlusCircle, Sun } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { claimCompanyMembershipForCurrentUser, ensureCompanyFromCurrentUser, getCompanyWebContext } from "@/lib/company-web";

type ThemeMode = "light" | "dark";

export default function CompanyLoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
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
    setLoading(true);
    setError("");

    const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });
    if (signInError) {
      setError(signInError.message);
      setLoading(false);
      return;
    }

    try {
      await claimCompanyMembershipForCurrentUser();
      await getCompanyWebContext();
      router.replace("/empresa");
    } catch (err) {
      try {
        await ensureCompanyFromCurrentUser();
        await getCompanyWebContext();
        router.replace("/empresa");
      } catch (ensureError) {
        await supabase.auth.signOut();
        setError(ensureError instanceof Error ? ensureError.message : err instanceof Error ? err.message : "Este usuario no tiene una empresa vinculada.");
        setLoading(false);
      }
    }
  }

  return (
    <main className={`company-web-bg company-theme-${theme} login-wrap`}>
      <button className="btn btn-soft btn-small auth-theme-toggle" onClick={() => setTheme(theme === "light" ? "dark" : "light")}>
        {theme === "light" ? <Moon size={16} /> : <Sun size={16} />}
        {theme === "light" ? "Oscuro" : "Claro"}
      </button>
      <section className="login-card">
        <div className="brand-row auth-brand-row">
          <img src="/brand/wissa-icon.png" alt="Wissa" className="auth-brand-logo" />
          <div>
            <div className="eyebrow">Wissa Empresas</div>
            <strong>Soluciones para tu hogar</strong>
          </div>
        </div>
        <h1 className="title">Acceso empresarial</h1>
        <p className="subtitle">Para propietarios y usuarios autorizados de empresa. Mantén tu plan activo para gestionar la operación completa.</p>
        {error ? <div className="error" style={{ marginTop: 18 }}>{error}</div> : null}
        <form className="form" onSubmit={submit}>
          <div>
            <label className="label">Correo</label>
            <input className="input" type="email" value={email} onChange={(event) => setEmail(event.target.value)} required />
          </div>
          <div>
            <label className="label">Contraseña</label>
            <input className="input" type="password" value={password} onChange={(event) => setPassword(event.target.value)} required />
          </div>
          <button className="btn btn-primary" disabled={loading}>{loading ? "Validando..." : "Entrar"}</button>
        </form>
        <div className="auth-footer-actions">
          <Link className="btn btn-soft" href="/empresa/registro"><PlusCircle size={16} /> Crear empresa</Link>
        </div>
      </section>
    </main>
  );
}
