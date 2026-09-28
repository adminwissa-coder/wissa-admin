"use client";

import { FormEvent, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import {
  ArrowRight,
  BarChart3,
  CalendarDays,
  Eye,
  EyeOff,
  LockKeyhole,
  Mail,
  Moon,
  ShieldCheck,
  Sparkles,
  Sun,
  UsersRound,
} from "lucide-react";
import { supabase } from "@/lib/supabase";

type ThemeMode = "dark" | "light";

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [theme, setTheme] = useState<ThemeMode>("light");
  const [themeLoaded, setThemeLoaded] = useState(false);

  useEffect(() => {
    const saved = window.localStorage.getItem("yt-admin-theme");
    const systemDark = window.matchMedia?.("(prefers-color-scheme: dark)").matches;
    const initial: ThemeMode = saved === "dark" || saved === "light" ? saved : systemDark ? "dark" : "light";
    setTheme(initial);
    document.documentElement.dataset.adminTheme = initial;
    document.documentElement.style.colorScheme = initial;
    setThemeLoaded(true);
  }, []);

  useEffect(() => {
    if (!themeLoaded) return;
    window.localStorage.setItem("yt-admin-theme", theme);
    document.documentElement.dataset.adminTheme = theme;
    document.documentElement.style.colorScheme = theme;
  }, [theme, themeLoaded]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLoading(true);
    setError("");

    const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });
    if (signInError) {
      setError("No pudimos iniciar sesión. Verifica tu correo y contraseña e inténtalo nuevamente.");
      setLoading(false);
      return;
    }

    const { data: isAdmin, error: adminError } = await supabase.rpc("yt_admin_is_current_admin");
    if (adminError || isAdmin !== true) {
      await supabase.auth.signOut();
      setError("Esta cuenta no tiene acceso al centro de gestión Wissa.");
      setLoading(false);
      return;
    }

    router.replace("/dashboard");
  }

  return (
    <main className={`wissa-auth admin-theme-${theme}`}>
      <div className="wissa-auth-ambient auth-ambient-one" aria-hidden="true" />
      <div className="wissa-auth-ambient auth-ambient-two" aria-hidden="true" />

      <button
        type="button"
        className="wissa-auth-theme"
        onClick={() => setTheme((current) => current === "dark" ? "light" : "dark")}
        aria-label={theme === "dark" ? "Cambiar a modo claro" : "Cambiar a modo oscuro"}
        title={theme === "dark" ? "Modo claro" : "Modo oscuro"}
      >
        {theme === "dark" ? <Sun size={18} /> : <Moon size={18} />}
        <span>{theme === "dark" ? "Claro" : "Oscuro"}</span>
      </button>

      <section className="wissa-auth-shell">
        <aside className="wissa-auth-story">
          <div className="wissa-auth-brand">
            <span className="wissa-auth-logo"><img src="/brand/wissa-icon.png" alt="" /></span>
            <div><strong>Wissa</strong><small>Centro de gestión</small></div>
          </div>

          <div className="wissa-auth-copy">
            <span className="wissa-auth-kicker"><Sparkles size={14}/> Wissa Admin</span>
            <h1>Gestiona mejor.<br/><span>Decide más rápido.</span></h1>
            <p>Reservas, profesionales, empresas y finanzas en un entorno ejecutivo diseñado para mantener toda la operación bajo control.</p>
          </div>

          <div className="wissa-auth-features" aria-label="Capacidades del centro de gestión">
            <div><span><CalendarDays size={18}/></span><div><strong>Reservas en tiempo real</strong><small>Seguimiento claro de estados y actividad.</small></div></div>
            <div><span><UsersRound size={18}/></span><div><strong>Operación centralizada</strong><small>Profesionales, empresas y clientes conectados.</small></div></div>
            <div><span><BarChart3 size={18}/></span><div><strong>Finanzas visibles</strong><small>Ingresos, liquidaciones y movimientos en contexto.</small></div></div>
          </div>

          <div className="wissa-auth-foot"><span className="wissa-auth-live"><i/> Operación conectada</span><small>Wissa · Administración</small></div>
        </aside>

        <section className="wissa-auth-panel">
          <div className="wissa-auth-panel-head">
            <span className="wissa-auth-security"><ShieldCheck size={16}/> Acceso administrativo</span>
            <h2>Bienvenido de vuelta</h2>
            <p>Ingresa con tu cuenta autorizada para continuar al panel de Wissa.</p>
          </div>

          {error ? <div className="wissa-auth-error" role="alert">{error}</div> : null}

          <form className="wissa-auth-form" onSubmit={submit}>
            <label className="wissa-auth-field">
              <span>Correo electrónico</span>
              <div className="wissa-auth-input-wrap">
                <Mail size={18}/>
                <input
                  type="email"
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  placeholder="admin@wissa.com"
                  autoComplete="email"
                  required
                />
              </div>
            </label>

            <label className="wissa-auth-field">
              <span>Contraseña</span>
              <div className="wissa-auth-input-wrap">
                <LockKeyhole size={18}/>
                <input
                  type={showPassword ? "text" : "password"}
                  value={password}
                  onChange={(event) => setPassword(event.target.value)}
                  placeholder="Tu contraseña"
                  autoComplete="current-password"
                  required
                />
                <button type="button" onClick={() => setShowPassword((current) => !current)} aria-label={showPassword ? "Ocultar contraseña" : "Mostrar contraseña"}>
                  {showPassword ? <EyeOff size={18}/> : <Eye size={18}/>}
                </button>
              </div>
            </label>

            <button className="wissa-auth-submit" disabled={loading}>
              <span>{loading ? "Validando acceso…" : "Entrar al centro de gestión"}</span>
              {!loading ? <ArrowRight size={18}/> : <span className="wissa-auth-spinner" aria-hidden="true"/>}
            </button>
          </form>

          <div className="wissa-auth-help"><ShieldCheck size={15}/><span>Acceso exclusivo para cuentas administrativas autorizadas.</span></div>
        </section>
      </section>
    </main>
  );
}
