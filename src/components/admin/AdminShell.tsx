"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { FormEvent, ReactNode, useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Bell,
  CheckCheck,
  ArrowRight,
  Building2,
  CalendarDays,
  ChevronDown,
  CircleUserRound,
  Command,
  Gift,
  HandCoins,
  Layers3,
  LayoutDashboard,
  LogOut,
  Menu,
  Moon,
  RotateCcw,
  Search,
  Settings2,
  SlidersHorizontal,
  Sun,
  Tags,
  UserRoundCheck,
  UsersRound,
  WalletCards,
  X,
} from "lucide-react";
import { supabase } from "@/lib/supabase";
import { countUnreadBusinessNotifications, isAdminNotificationRead, normalizeAdminNotificationRows, notificationMembers } from "@/lib/admin-notifications";
import { NotificationBell } from "@/components/ui/notification-bell";

type NavItem = {
  label: string;
  href: string;
  icon: typeof LayoutDashboard;
  matches?: string[];
};

type SearchItem = {
  title: string;
  subtitle: string;
  href: string;
  icon: typeof LayoutDashboard;
  keywords: string[];
};

const navItems: NavItem[] = [
  { label: "Dashboard", href: "/dashboard", icon: LayoutDashboard },
  { label: "Reservas", href: "/dashboard/reservas", icon: CalendarDays },
  { label: "Servicios", href: "/dashboard/servicios", icon: Layers3 },
  { label: "Profesionales", href: "/dashboard/ofrecer", icon: UserRoundCheck, matches: ["/dashboard/ofrecer/"] },
  { label: "Empresas", href: "/dashboard/empresas", icon: Building2 },
  { label: "Finanzas", href: "/dashboard/finanzas", icon: WalletCards },
  {
    label: "Liquidaciones",
    href: "/dashboard/liquidaciones",
    icon: HandCoins,
    matches: ["/dashboard/retiros", "/dashboard/empresas-liquidaciones", "/dashboard/retiro-comision", "/dashboard/distribucion"],
  },
  { label: "Devoluciones", href: "/dashboard/devoluciones", icon: RotateCcw },
  { label: "Notificaciones", href: "/dashboard/notificaciones", icon: Bell },
  {
    label: "Configuración",
    href: "/dashboard/configuracion",
    icon: Settings2,
    matches: ["/dashboard/categorias", "/dashboard/catalogo", "/dashboard/planes", "/dashboard/banners", "/dashboard/equipos", "/dashboard/beneficios", "/dashboard/usuarios", "/dashboard/reportes", "/dashboard/casos"],
  },
];

const searchItems: SearchItem[] = [
  { title: "Dashboard", subtitle: "Resumen de operación", href: "/dashboard", icon: LayoutDashboard, keywords: ["inicio", "panel", "metricas"] },
  { title: "Reservas", subtitle: "Seguimiento y estados", href: "/dashboard/reservas", icon: CalendarDays, keywords: ["reserva", "cliente", "booking"] },
  { title: "Servicios", subtitle: "Oferta y configuración", href: "/dashboard/servicios", icon: Layers3, keywords: ["servicios", "limpieza", "acompañamiento"] },
  { title: "Profesionales", subtitle: "Perfiles, disponibilidad y documentos", href: "/dashboard/ofrecer", icon: UserRoundCheck, keywords: ["profesional", "oferente", "proveedor"] },
  { title: "Clientes", subtitle: "Cuentas que contratan", href: "/dashboard/usuarios", icon: UsersRound, keywords: ["cliente", "usuario"] },
  { title: "Empresas", subtitle: "Cuentas corporativas", href: "/dashboard/empresas", icon: Building2, keywords: ["empresa", "corporativo"] },
  { title: "Finanzas", subtitle: "Ingresos, propinas y movimientos", href: "/dashboard/finanzas", icon: WalletCards, keywords: ["finanzas", "pago", "propina", "comision"] },
  { title: "Liquidaciones", subtitle: "Pagos a profesionales", href: "/dashboard/liquidaciones", icon: HandCoins, keywords: ["liquidacion", "retiro", "payout"] },
  { title: "Devoluciones", subtitle: "Reembolsos y seguimiento", href: "/dashboard/devoluciones", icon: RotateCcw, keywords: ["devolucion", "reembolso", "refund"] },
  { title: "Categorías", subtitle: "Categorías del negocio", href: "/dashboard/categorias", icon: Tags, keywords: ["categoria", "catalogo"] },
  { title: "Notificaciones", subtitle: "Centro de avisos", href: "/dashboard/notificaciones", icon: Bell, keywords: ["notificacion", "push", "aviso"] },
  { title: "Promociones", subtitle: "Beneficios y bonos", href: "/dashboard/beneficios", icon: Gift, keywords: ["promo", "beneficio", "bono"] },
  { title: "Configuración", subtitle: "Precios, pagos y ajustes", href: "/dashboard/configuracion", icon: Settings2, keywords: ["configuracion", "precio", "ajuste"] },
  { title: "Reportes", subtitle: "Métricas operativas", href: "/dashboard/reportes", icon: SlidersHorizontal, keywords: ["reporte", "metrica", "estadistica"] },
];

const titleByPath: Record<string, string> = {
  "/dashboard": "Dashboard",
  "/dashboard/reservas": "Reservas",
  "/dashboard/servicios": "Servicios",
  "/dashboard/ofrecer": "Profesionales",
  "/dashboard/usuarios": "Clientes",
  "/dashboard/empresas": "Empresas",
  "/dashboard/finanzas": "Finanzas",
  "/dashboard/liquidaciones": "Liquidaciones",
  "/dashboard/devoluciones": "Devoluciones",
  "/dashboard/categorias": "Categorías",
  "/dashboard/beneficios": "Promociones",
  "/dashboard/reportes": "Reportes",
  "/dashboard/configuracion": "Configuración",
  "/dashboard/notificaciones": "Notificaciones",
};

function normalize(value: string) {
  return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim();
}

export default function AdminShell({ children }: { children: ReactNode }) {
  const path = usePathname();
  const router = useRouter();
  const searchRef = useRef<HTMLInputElement>(null);
  const searchWrapRef = useRef<HTMLDivElement>(null);
  const profileRef = useRef<HTMLDivElement>(null);
  const notificationRef = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(true);
  const [name, setName] = useState("Admin");
  const [notificationCount, setNotificationCount] = useState(0);
  const [notificationRows, setNotificationRows] = useState<Array<Record<string, unknown>>>([]);
  const [notificationOpen, setNotificationOpen] = useState(false);
  const [notificationFilter, setNotificationFilter] = useState<"all" | "unread" | "system">("all");
  const [notificationBusy, setNotificationBusy] = useState(false);
  const [globalSearch, setGlobalSearch] = useState("");
  const [searchOpen, setSearchOpen] = useState(false);
  const [profileOpen, setProfileOpen] = useState(false);
  const [theme, setTheme] = useState<"light" | "dark">("light");
  const [themeReady, setThemeReady] = useState(false);

  const title = useMemo(() => {
    if (titleByPath[path]) return titleByPath[path];
    if (path.startsWith("/dashboard/ofrecer/")) return "Profesional";
    const matched = navItems.find((item) => item.matches?.some((prefix) => path.startsWith(prefix)));
    return matched?.label || "Administración Wissa";
  }, [path]);

  const searchResults = useMemo(() => {
    const query = normalize(globalSearch);
    if (!query) return searchItems.slice(0, 6);
    return searchItems.filter((item) => {
      const haystack = normalize([item.title, item.subtitle, ...item.keywords].join(" "));
      return haystack.includes(query);
    }).slice(0, 7);
  }, [globalSearch]);

  const loadNotifications = useCallback(async () => {
    const { data, error } = await supabase.rpc("yt_admin_notifications_json", {
      p_search: "",
      p_status: "all",
      p_limit: 40,
      p_date_from: null,
      p_date_to: null,
    });
    if (error || !Array.isArray(data)) {
      setNotificationCount(0);
      setNotificationRows([]);
      return;
    }
    const rows = normalizeAdminNotificationRows(data as Array<Record<string, unknown>>);
    setNotificationRows(rows);
    setNotificationCount(countUnreadBusinessNotifications(rows));
  }, []);

  useEffect(() => {
    const saved = window.localStorage.getItem("yt-admin-theme");
    const systemDark = window.matchMedia?.("(prefers-color-scheme: dark)").matches;
    const initial = saved === "dark" || saved === "light" ? saved : systemDark ? "dark" : "light";
    setTheme(initial);
    document.documentElement.dataset.adminTheme = initial;
    document.documentElement.style.colorScheme = initial;
    setThemeReady(true);
  }, []);

  useEffect(() => {
    if (!themeReady) return;
    window.localStorage.setItem("yt-admin-theme", theme);
    document.documentElement.dataset.adminTheme = theme;
    document.documentElement.style.colorScheme = theme;
  }, [theme, themeReady]);

  useEffect(() => {
    (async () => {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session?.user) {
        router.replace("/login");
        return;
      }
      const { data, error } = await supabase.rpc("yt_admin_is_current_admin");
      if (error || data !== true) {
        await supabase.auth.signOut();
        router.replace("/login");
        return;
      }
      const { data: profile } = await supabase
        .from("profiles")
        .select("full_name,email")
        .eq("id", session.user.id)
        .maybeSingle();
      setName(profile?.full_name || profile?.email || session.user.email || "Admin");
      await loadNotifications();
      setLoading(false);
    })();
  }, [loadNotifications, router]);

  useEffect(() => {
    if (loading) return;
    const timer = window.setInterval(() => void loadNotifications(), 60000);
    return () => window.clearInterval(timer);
  }, [loadNotifications, loading]);

  useEffect(() => {
    if (loading) return;
    const refresh = () => void loadNotifications();
    window.addEventListener("yt-admin-notifications-changed", refresh);
    return () => window.removeEventListener("yt-admin-notifications-changed", refresh);
  }, [loadNotifications, loading]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        searchRef.current?.focus();
        setSearchOpen(true);
      }
      if (event.key === "Escape") {
        setSearchOpen(false);
        setProfileOpen(false);
        setNotificationOpen(false);
        setOpen(false);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  useEffect(() => {
    const onPointerDown = (event: MouseEvent) => {
      const target = event.target as Node;
      if (profileRef.current && !profileRef.current.contains(target)) setProfileOpen(false);
      if (notificationRef.current && !notificationRef.current.contains(target)) setNotificationOpen(false);
      if (searchWrapRef.current && !searchWrapRef.current.contains(target)) setSearchOpen(false);
    };
    document.addEventListener("mousedown", onPointerDown);
    return () => document.removeEventListener("mousedown", onPointerDown);
  }, []);

  const visibleNotifications = useMemo(() => {
    const active = notificationRows.filter((row) => !row.admin_archived_at && !row.admin_deleted_at);
    if (notificationFilter === "unread") return active.filter((row) => !isAdminNotificationRead(row)).slice(0, 6);
    if (notificationFilter === "system") return active.filter((row) => {
      const source = String(row.source ?? "").toLowerCase();
      const type = String(row.type ?? "").toLowerCase();
      return source.includes("push") || source.includes("system") || type.includes("system");
    }).slice(0, 6);
    return active.slice(0, 6);
  }, [notificationFilter, notificationRows]);

  async function markAllNotificationsRead() {
    const unread = notificationRows.filter((row) => !isAdminNotificationRead(row));
    if (!unread.length) return;
    setNotificationBusy(true);
    try {
      for (const row of unread) {
        for (const member of notificationMembers(row)) {
          await supabase.rpc("yt_admin_mark_notification_read", {
            p_source: member.source,
            p_id: member.id,
            p_is_read: true,
          });
        }
      }
      window.dispatchEvent(new Event("yt-admin-notifications-changed"));
      await loadNotifications();
    } finally {
      setNotificationBusy(false);
    }
  }

  function notificationTitle(row: Record<string, unknown>) {
    return String(row.title ?? row.type ?? "Notificación").trim() || "Notificación";
  }

  function notificationBody(row: Record<string, unknown>) {
    return String(row.message ?? row.body ?? row.description ?? "").trim();
  }

  function notificationTime(row: Record<string, unknown>) {
    const value = String(row.created_at ?? row.sent_at ?? row.updated_at ?? "");
    if (!value) return "";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "";
    return new Intl.DateTimeFormat("es-PA", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" }).format(date);
  }

  function isActive(item: NavItem) {
    if (item.href === "/dashboard") return path === "/dashboard";
    if (path === item.href) return true;
    return item.matches?.some((prefix) => path.startsWith(prefix)) || false;
  }

  async function logout() {
    await supabase.auth.signOut();
    router.replace("/login");
  }

  function goTo(href: string) {
    router.push(href);
    setGlobalSearch("");
    setSearchOpen(false);
    setOpen(false);
  }

  function submitGlobalSearch(event: FormEvent) {
    event.preventDefault();
    if (searchResults[0]) goTo(searchResults[0].href);
  }

  if (loading) {
    return (
      <div className={`loading admin-theme-${theme} ui2-loading`}>
        <div className="simple-loader-card ui2-loader-card">
          <span className="ui2-loader-logo"><img src="/brand/wissa-icon.png" alt="Wissa" /></span>
          <div className="spinner" />
          <p>Preparando Wissa Admin…</p>
        </div>
      </div>
    );
  }

  const firstName = name.split(" ")[0] || "Admin";

  return (
    <div className={`app-bg shell admin-theme-${theme} wissa-simple-shell wissa-ui2-shell wissa-v70-shell`}>
      <span className="ui2-ambient ui2-ambient-one" aria-hidden="true" />
      <span className="ui2-ambient ui2-ambient-two" aria-hidden="true" />

      <aside className={`sidebar simple-sidebar ui2-sidebar ${open ? "open" : ""}`}>
        <div className="simple-side-brand ui2-side-brand">
          <Link href="/dashboard" onClick={() => setOpen(false)} aria-label="Ir al Dashboard de Wissa">
            <span className="ui2-brand-mark"><img src="/brand/wissa-icon.png" alt="" /></span>
            <span className="ui2-brand-copy"><strong>Wissa</strong><small>Centro de gestión</small></span>
          </Link>
          <button className="ui2-side-close" onClick={() => setOpen(false)} aria-label="Cerrar menú"><X size={18}/></button>
        </div>

        <div className="ui2-side-label">GESTIÓN</div>
        <nav className="simple-nav ui2-nav" aria-label="Navegación principal">
          {navItems.map((item) => {
            const Icon = item.icon;
            return (
              <Link
                key={item.href}
                href={item.href}
                className={`simple-nav-link ui2-nav-link ${isActive(item) ? "active" : ""}`}
                onClick={() => setOpen(false)}
              >
                <span className="ui2-nav-icon"><Icon size={18} strokeWidth={1.9} /></span>
                <span>{item.label}</span>
                {item.label === "Notificaciones" && notificationCount > 0 ? (
                  <span className="ui2-nav-count" aria-label={`${notificationCount} avisos pendientes`}>{notificationCount > 99 ? "99+" : notificationCount}</span>
                ) : item.label === "Finanzas" ? <span className="ui2-nav-dot" aria-hidden="true" /> : null}
              </Link>
            );
          })}
        </nav>

        <div className="ui2-side-status">
          <span className="ui2-status-orb"><span /></span>
          <div><strong>Operación conectada</strong><small>{notificationCount > 0 ? `${notificationCount} avisos por revisar` : "Todo sincronizado"}</small></div>
        </div>

        <div className="simple-side-footer ui2-side-footer">
          <button onClick={logout} className="simple-logout ui2-logout">
            <LogOut size={17} />
            <span>Cerrar sesión</span>
          </button>
        </div>
      </aside>

      {open ? <button aria-label="Cerrar menú" className="simple-overlay ui2-overlay" onClick={() => setOpen(false)} /> : null}

      <main className="main simple-main ui2-main">
        <header className="topbar simple-topbar ui2-topbar">
          <div className="ui2-topbar-left">
            <button className="simple-mobile-menu ui2-mobile-menu" onClick={() => setOpen(true)} aria-label="Abrir menú">
              <Menu size={21} />
            </button>
            <div className="ui2-page-context">
              <small>Wissa Admin</small>
              <strong>{title}</strong>
            </div>
          </div>

          <div className={`ui2-search-wrap ${searchOpen ? "open" : ""}`} ref={searchWrapRef}>
            <form className="simple-global-search ui2-global-search" onSubmit={submitGlobalSearch}>
              <Search size={18} />
              <input
                ref={searchRef}
                value={globalSearch}
                onChange={(e) => { setGlobalSearch(e.target.value); setSearchOpen(true); }}
                onFocus={() => setSearchOpen(true)}
                placeholder="Buscar reservas, profesionales, empresas…"
                aria-label="Buscar en Wissa Admin"
                autoComplete="off"
              />
              <span className="ui2-search-shortcut"><Command size={12}/> K</span>
            </form>
            {searchOpen ? (
              <div className="ui2-search-panel" role="listbox" aria-label="Resultados de búsqueda">
                <div className="ui2-search-panel-head"><span>{globalSearch ? "Resultados" : "Accesos rápidos"}</span><small>Enter abre el primero</small></div>
                {searchResults.length ? searchResults.map((item) => {
                  const Icon = item.icon;
                  return (
                    <button key={item.href} type="button" onMouseDown={(event) => event.preventDefault()} onClick={() => goTo(item.href)}>
                      <span className="ui2-search-result-icon"><Icon size={17}/></span>
                      <span><strong>{item.title}</strong><small>{item.subtitle}</small></span>
                    </button>
                  );
                }) : <div className="ui2-search-empty">No encontramos un módulo con ese nombre.</div>}
              </div>
            ) : null}
          </div>

          <div className="simple-top-actions ui2-top-actions">
            <button
              className="simple-icon-button simple-theme-toggle ui2-icon-button ui2-theme-toggle"
              type="button"
              aria-label={theme === "dark" ? "Cambiar a modo claro" : "Cambiar a modo oscuro"}
              title={theme === "dark" ? "Modo claro" : "Modo oscuro"}
              onClick={() => setTheme((current) => current === "dark" ? "light" : "dark")}
            >
              {theme === "dark" ? <Sun size={18} /> : <Moon size={18} />}
            </button>

            <div className="ui2-notification-wrap" ref={notificationRef}>
              <NotificationBell
                count={notificationCount}
                max={9}
                size={41}
                color="red"
                className={`simple-icon-button ui2-icon-button ui2-notification-button ${notificationCount > 0 ? "has-notifications" : ""}`}
                aria-label={notificationCount > 0 ? `Notificaciones, ${notificationCount} sin leer` : "Notificaciones"}
                title="Notificaciones"
                aria-expanded={notificationOpen}
                onClick={() => { setNotificationOpen((current) => !current); setProfileOpen(false); }}
              />

              {notificationOpen ? (
                <div className="ui2-notification-popover" role="dialog" aria-label="Centro rápido de notificaciones">
                  <div className="ui2-notification-head">
                    <div>
                      <strong>Notificaciones</strong>
                      <small>{notificationCount > 0 ? `${notificationCount} sin leer` : "Todo al día"}</small>
                    </div>
                    <button type="button" onClick={() => void markAllNotificationsRead()} disabled={notificationBusy || notificationCount === 0}>
                      <CheckCheck size={15}/>
                      <span>{notificationBusy ? "Marcando…" : "Marcar leídas"}</span>
                    </button>
                  </div>

                  <div className="ui2-notification-tabs" role="tablist" aria-label="Filtrar notificaciones">
                    {[
                      ["all", "Todas"],
                      ["unread", "No leídas"],
                      ["system", "Sistema"],
                    ].map(([value, label]) => (
                      <button
                        key={value}
                        type="button"
                        role="tab"
                        aria-selected={notificationFilter === value}
                        className={notificationFilter === value ? "active" : ""}
                        onClick={() => setNotificationFilter(value as "all" | "unread" | "system")}
                      >
                        {label}
                      </button>
                    ))}
                  </div>

                  <div className="ui2-notification-list">
                    {visibleNotifications.length ? visibleNotifications.map((row, index) => {
                      const unread = !isAdminNotificationRead(row);
                      const id = String(row.id ?? `${index}`);
                      return (
                        <button
                          type="button"
                          key={`${String(row.source ?? "notification")}-${id}`}
                          className={`ui2-notification-item ${unread ? "unread" : ""}`}
                          onClick={() => { setNotificationOpen(false); router.push("/dashboard/notificaciones"); }}
                        >
                          <span className="ui2-notification-item-icon"><Bell size={16}/></span>
                          <span className="ui2-notification-item-copy">
                            <span className="ui2-notification-item-title">{notificationTitle(row)}</span>
                            {notificationBody(row) ? <span className="ui2-notification-item-body">{notificationBody(row)}</span> : null}
                            <span className="ui2-notification-item-time">{notificationTime(row)}</span>
                          </span>
                          {unread ? <span className="ui2-notification-unread-dot" aria-label="Sin leer"/> : null}
                        </button>
                      );
                    }) : (
                      <div className="ui2-notification-empty">
                        <Bell size={20}/>
                        <strong>Sin avisos en esta vista</strong>
                        <small>Cuando haya novedades aparecerán aquí.</small>
                      </div>
                    )}
                  </div>

                  <button
                    type="button"
                    className="ui2-notification-footer"
                    onClick={() => { setNotificationOpen(false); router.push("/dashboard/notificaciones"); }}
                  >
                    <span>Ver todas las notificaciones</span>
                    <ArrowRight size={15}/>
                  </button>
                </div>
              ) : null}
            </div>

            <div className="ui2-profile-wrap" ref={profileRef}>
              <button className="simple-admin-profile ui2-admin-profile" type="button" onClick={() => setProfileOpen((current) => !current)} aria-expanded={profileOpen}>
                <div className="simple-admin-avatar ui2-admin-avatar">{firstName.slice(0, 1).toUpperCase()}</div>
                <div><strong>{firstName}</strong><small>Administrador</small></div>
                <ChevronDown size={15} className={profileOpen ? "rotated" : ""}/>
              </button>
              {profileOpen ? (
                <div className="ui2-profile-menu">
                  <div className="ui2-profile-menu-head"><span className="ui2-mini-avatar"><CircleUserRound size={18}/></span><div><strong>{name}</strong><small>Cuenta administrativa</small></div></div>
                  <Link href="/dashboard/configuracion" onClick={() => setProfileOpen(false)}><Settings2 size={16}/><span>Configuración</span></Link>
                  <button type="button" onClick={() => void logout()}><LogOut size={16}/><span>Cerrar sesión</span></button>
                </div>
              ) : null}
            </div>
          </div>
        </header>

        <section className="content simple-content ui2-content" data-page-title={title}>{children}</section>
      </main>
    </div>
  );
}
