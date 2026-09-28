"use client";

import { type ReactNode, useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import {
  BriefcaseBusiness,
  CalendarClock,
  CreditCard,
  Download,
  Edit3,
  FileBarChart,
  LayoutDashboard,
  Building2,
  LogOut,
  Menu,
  Moon,
  Plus,
  RefreshCcw,
  Save,
  Search,
  Settings2,
  ShieldCheck,
  Sun,
  UserRound,
  Users,
  X,
} from "lucide-react";
import CategoryPricingManagerPage from "@/components/admin/CategoryPricingManagerPage";
import { supabase } from "@/lib/supabase";
import { datetime, formatPanamaDate, formatPanamaTime, money, statusLabel, text } from "@/lib/utils";
import {
  createCompanyMember,
  createCompanyPlanCheckout,
  createCompanyService,
  getCompanyWebContext,
  removeCompanyService,
  setCompanyMemberStatus,
  setCompanyServiceActive,
  updateCompanyMember,
  updateCompanyProfile,
  updateCompanyService,
  type CompanyBookingRow,
  type CompanyContext,
  type CompanyFinanceRow,
  type CompanyMemberRow,
  type CompanyServiceRow,
} from "@/lib/company-web";

type PortalTab = "resumen" | "reservas" | "personal" | "servicios" | "precios" | "finanzas" | "perfil";
type ThemeMode = "light" | "dark";
type ModalType = "member" | "service" | null;
type RowValue = string | number | boolean | null | undefined;
type ExportRow = Record<string, RowValue>;

const tabs: Array<{ key: PortalTab; label: string; icon: ReactNode }> = [
  { key: "resumen", label: "Dashboard", icon: <LayoutDashboard size={18} /> },
  { key: "reservas", label: "Reservas", icon: <CalendarClock size={17} /> },
  { key: "personal", label: "Personal", icon: <Users size={17} /> },
  { key: "servicios", label: "Servicios", icon: <BriefcaseBusiness size={17} /> },
  { key: "precios", label: "Categorías y precios", icon: <Settings2 size={17} /> },
  { key: "finanzas", label: "Cobros y finanzas", icon: <CreditCard size={17} /> },
  { key: "perfil", label: "Perfil de empresa", icon: <UserRound size={17} /> },
];

const companyNavGroups: Array<{ label: string; keys: PortalTab[] }> = [
  { label: "RESUMEN", keys: ["resumen"] },
  { label: "OPERACIÓN", keys: ["reservas", "personal", "servicios"] },
  { label: "GESTIÓN", keys: ["precios", "finanzas", "perfil"] },
];

const COMPANY_SERVICE_CATEGORIES = ["Limpieza", "Limpieza de exteriores", "Plomería"] as const;

const initialServiceForm = {
  companyMemberId: "",
  title: "",
  category: "Limpieza",
  description: "",
};

const initialMemberForm = {
  fullName: "",
  email: "",
  phone: "",
  position: "",
  password: "",
  internalRole: "company_staff",
};


export default function CompanyWebPortal() {
  const router = useRouter();
  const [context, setContext] = useState<CompanyContext | null>(null);
  const [activeTab, setActiveTab] = useState<PortalTab>("resumen");
  const [searchDraft, setSearchDraft] = useState("");
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("all");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [modal, setModal] = useState<ModalType>(null);
  const [paying, setPaying] = useState<"yappy" | "paguelofacil" | null>(null);
  const [yappyPhone, setYappyPhone] = useState("");
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const [redirectingToLogin, setRedirectingToLogin] = useState(false);
  const [theme, setTheme] = useState<ThemeMode>("light");
  const [themeLoaded, setThemeLoaded] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [memberForm, setMemberForm] = useState(initialMemberForm);
  const [serviceForm, setServiceForm] = useState(initialServiceForm);
  const [editingMember, setEditingMember] = useState<CompanyMemberRow | null>(null);
  const [editingService, setEditingService] = useState<CompanyServiceRow | null>(null);
  const [profileForm, setProfileForm] = useState({ name: "", legalName: "", email: "", phone: "", city: "" });

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    setRedirectingToLogin(false);
    try {
      const next = await getCompanyWebContext({ search, status, limit: 120 });
      setContext(next);
    } catch (err) {
      const message = err instanceof Error ? err.message : "No se pudo cargar la empresa.";
      if (isAuthErrorMessage(message)) {
        setContext(null);
        setRedirectingToLogin(true);
        router.replace("/empresa/login");
        return;
      }
      setError(message);
      if (message.toLowerCase().includes("sesión") || message.toLowerCase().includes("sesion") || message.toLowerCase().includes("iniciar")) {
        router.replace("/empresa/login");
      }
    } finally {
      setLoading(false);
    }
  }, [router, search, status]);

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

  useEffect(() => {
    const timer = window.setTimeout(() => {
      void load();
    }, 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  const active = Boolean(context?.subscription?.is_access_active);
  const isAdmin = Boolean(context?.is_company_admin || context?.role === "company_admin");
  const price = Number(context?.subscription?.current_plan_price ?? context?.subscription?.subscription_price ?? 0);
  const days = Number(context?.subscription?.current_plan_days ?? context?.subscription?.subscription_days ?? 30);

  useEffect(() => {
    if (!context?.company) return;
    setProfileForm({
      name: text(context.company.name),
      legalName: text(context.company.legal_name),
      email: text(context.company.email),
      phone: text(context.company.phone),
      city: text(context.company.city),
    });
  }, [context?.company]);

  const subscriptionExpired = useMemo(() => {
    const planStatus = String(context?.subscription?.subscription_status ?? context?.company.subscription_status ?? "").toLowerCase();
    if (planStatus === "expired") return true;
    const raw = context?.subscription?.subscription_expires_at ?? context?.company.subscription_expires_at;
    if (!raw) return false;
    const value = String(raw);
    const time = new Date(value.length <= 10 ? `${value}T23:59:59-05:00` : value).getTime();
    return Number.isFinite(time) && time < Date.now();
  }, [context]);

  const statusText = useMemo(() => {
    if (active && !subscriptionExpired) return "Plan activo";
    const planStatus = context?.subscription?.subscription_status ?? context?.company.subscription_status;
    if (subscriptionExpired || planStatus === "expired") return "Inactivo";
    if (planStatus === "pending_payment") return "Pago pendiente";
    if (planStatus === "suspended") return "Plan suspendido";
    return "Plan requerido";
  }, [active, context, subscriptionExpired]);

  const serviceMembers = useMemo(() => {
    return (context?.members ?? []).filter((member) => member.status !== "removed" && member.status !== "inactive");
  }, [context?.members]);

  const linkedServiceMembers = useMemo(() => {
    return serviceMembers.filter((member) => Boolean(member.user_id));
  }, [serviceMembers]);

  const visibleTabs = useMemo(
    () => tabs.filter((tab) => isAdmin || !["precios", "perfil"].includes(tab.key)),
    [isAdmin],
  );

  const activeTabLabel = useMemo(() => visibleTabs.find((item) => item.key === activeTab)?.label || "Dashboard", [activeTab, visibleTabs]);

  const activeRows = useMemo(() => {
    if (!context) return [];
    if (activeTab === "reservas") return bookingExportRows(context.bookings);
    if (activeTab === "personal") return memberExportRows(context.members);
    if (activeTab === "servicios") return serviceExportRows(context.services);
    if (activeTab === "finanzas") return financeExportRows(context.finance);
    return summaryExportRows(context);
  }, [activeTab, context]);

  function applyFilters() {
    setSearch(searchDraft.trim());
  }

  function clearFilters() {
    setSearchDraft("");
    setSearch("");
    setStatus("all");
  }

  function openModal(next: Exclude<ModalType, null>) {
    setError("");
    setSuccess("");
    setEditingMember(null);
    setEditingService(null);
    if (next === "member") setMemberForm(initialMemberForm);
    if (next === "service") setServiceForm({ ...initialServiceForm, companyMemberId: linkedServiceMembers[0]?.id ?? "" });
    setModal(next);
  }

  function closeModal() {
    if (saving) return;
    setModal(null);
    setEditingMember(null);
    setEditingService(null);
  }

  function editMember(member: CompanyMemberRow) {
    setError("");
    setSuccess("");
    setEditingMember(member);
    setMemberForm({
      fullName: text(member.full_name),
      email: text(member.email),
      phone: text(member.phone),
      position: text(member.position),
      password: "",
      internalRole: member.internal_role === "company_admin" ? "company_admin" : "company_staff",
    });
    setModal("member");
  }

  function editService(service: CompanyServiceRow) {
    setError("");
    setSuccess("");
    setEditingService(service);
    setServiceForm({
      companyMemberId: service.company_member_id || "",
      title: text(service.title),
      category: text(service.category, "Limpieza"),
      description: text(service.description),
    });
    setModal("service");
  }

  async function saveMember() {
    if (!context?.company.id) return;
    if (!isAdmin) return setError("Solo el Admin Empresa puede administrar personal.");
    if (!memberForm.fullName.trim() || !memberForm.email.trim()) return setError("Nombre y correo son obligatorios.");
    if (!editingMember && (!memberForm.password.trim() || memberForm.password.trim().length < 8)) return setError("Coloca una contraseña temporal de mínimo 8 caracteres.");
    if (editingMember && memberForm.password.trim() && memberForm.password.trim().length < 8) return setError("Si vas a cambiar la contraseña, debe tener mínimo 8 caracteres.");

    setSaving(true);
    setError("");
    try {
      if (editingMember?.id) {
        await updateCompanyMember({
          memberId: editingMember.id,
          companyId: context.company.id,
          fullName: memberForm.fullName,
          email: memberForm.email,
          phone: memberForm.phone,
          position: memberForm.position,
          password: memberForm.password,
          internalRole: memberForm.internalRole,
        });
        setSuccess("Personal actualizado correctamente.");
      } else {
        await createCompanyMember({
          companyId: context.company.id,
          fullName: memberForm.fullName,
          email: memberForm.email,
          phone: memberForm.phone,
          position: memberForm.position,
          password: memberForm.password,
          internalRole: memberForm.internalRole,
        });
        setSuccess("Personal creado correctamente. Ya puede entrar al app con ese correo y contraseña temporal.");
      }
      setModal(null);
      setEditingMember(null);
      setActiveTab("personal");
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo guardar el personal.");
    } finally {
      setSaving(false);
    }
  }

  async function saveService() {
    if (!context?.company.id) return;
    if (!isAdmin) return setError("Solo el Admin Empresa puede administrar servicios.");
    if (!serviceForm.companyMemberId) return setError("Selecciona un personal con cuenta app vinculada.");
    const selectedMember = serviceMembers.find((member) => member.id === serviceForm.companyMemberId);
    if (!selectedMember?.user_id) return setError("Ese personal todavía no tiene cuenta app vinculada. Créalo desde Personal o revisa que haya entrado al app.");
    if (!serviceForm.title.trim() || !serviceForm.category.trim()) return setError("Completa el nombre y la categoría base del servicio.");

    setSaving(true);
    setError("");
    try {
      if (editingService?.id) {
        await updateCompanyService({
          serviceId: editingService.id,
          companyId: context.company.id,
          companyMemberId: serviceForm.companyMemberId,
          title: serviceForm.title,
          description: serviceForm.description,
          category: serviceForm.category,
          price: 0,
          durationMinutes: 60,
        });
        setSuccess("Servicio actualizado correctamente.");
      } else {
        await createCompanyService({
          companyId: context.company.id,
          companyMemberId: serviceForm.companyMemberId,
          title: serviceForm.title,
          description: serviceForm.description,
          category: serviceForm.category,
          price: 0,
          durationMinutes: 60,
        });
        setSuccess("Servicio empresarial creado correctamente.");
      }
      setModal(null);
      setEditingService(null);
      setActiveTab("servicios");
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo guardar el servicio.");
    } finally {
      setSaving(false);
    }
  }

  async function saveProfile() {
    if (!context?.company.id) return;
    if (!isAdmin) return setError("Solo el Admin Empresa puede editar el perfil empresarial.");
    if (!profileForm.name.trim()) return setError("El nombre comercial es obligatorio.");

    setSaving(true);
    setError("");
    setSuccess("");
    try {
      await updateCompanyProfile({
        companyId: context.company.id,
        name: profileForm.name.trim(),
        legalName: profileForm.legalName.trim(),
        email: profileForm.email.trim(),
        phone: profileForm.phone.trim(),
        city: profileForm.city.trim(),
      });
      setSuccess("Perfil empresarial actualizado. El nuevo nombre ya está disponible en la app.");
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo actualizar la empresa.");
    } finally {
      setSaving(false);
    }
  }

  async function toggleService(service: CompanyServiceRow) {
    setError("");
    try {
      await setCompanyServiceActive(service.id, service.is_active === false);
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo actualizar el servicio.");
    }
  }


  async function changeMemberStatus(member: CompanyMemberRow, status: "active" | "inactive" | "removed") {
    const label = status === "removed" ? "eliminar" : status === "inactive" ? "desactivar" : "activar";
    if (status === "removed" && !window.confirm(`¿Seguro que quieres eliminar a ${text(member.full_name, "este personal")}?`)) return;
    setError("");
    try {
      await setCompanyMemberStatus(member.id, status);
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : `No se pudo ${label} el personal.`);
    }
  }

  async function removeService(service: CompanyServiceRow) {
    if (!window.confirm(`¿Seguro que quieres eliminar el servicio ${text(service.title)}?`)) return;
    setError("");
    try {
      await removeCompanyService(service.id);
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo eliminar el servicio.");
    }
  }

  async function pay(provider: "yappy" | "paguelofacil") {
    if (!context?.company.id) return;
    let phone: string | null = null;
    if (provider === "yappy") {
      phone = yappyPhone.replace(/\D/g, "");
      if (!phone || phone.length !== 8) {
        setError("Ingresa un numero Yappy valido de 8 digitos.");
        return;
      }
    }

    setPaying(provider);
    setError("");
    try {
      const checkout = await createCompanyPlanCheckout(context.company.id, provider, phone);
      window.location.assign(checkout.checkoutUrl);
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo iniciar el pago.");
      setPaying(null);
    } finally {
      if (document.visibilityState === "visible") setPaying(null);
    }
  }

  async function signOut() {
    await supabase.auth.signOut();
    router.replace("/empresa/login");
  }

  if ((loading && !context) || redirectingToLogin) {
    return (
      <main className={`company-web-bg company-theme-${theme}`}>
        <div className="loading"><div><div className="spinner" /><p className="subtitle" style={{ marginTop: 14 }}>{redirectingToLogin ? "Redirigiendo al login..." : "Cargando empresa..."}</p></div></div>
      </main>
    );
  }

  return (
    <div className={`company-web-bg company-theme-${theme} company-admin-shell`}>
      <aside className={`company-admin-sidebar ${menuOpen ? "open" : ""}`}>
        <div className="company-sidebar-head">
          <button className="company-sidebar-brand" type="button" onClick={() => { setActiveTab("resumen"); setMenuOpen(false); }}>
            <img src="/brand/wissa-icon.png" alt="Wissa" className="company-sidebar-logo" />
            <div>
              <strong>Wissa</strong>
              <span>SOLUCIONES PARA TU HOGAR</span>
            </div>
          </button>
        </div>

        <div className="company-sidebar-company">
          <span className="company-sidebar-company-icon"><Building2 size={18} /></span>
          <div>
            <small>EMPRESA</small>
            <strong>{context?.company.name || "Empresa Wissa"}</strong>
          </div>
        </div>

        <nav className="company-sidebar-nav" aria-label="Menú de empresa">
          {companyNavGroups.map((group) => {
            const groupTabs = visibleTabs.filter((tab) => group.keys.includes(tab.key));
            if (!groupTabs.length) return null;
            return (
              <div className="company-nav-section" key={group.label}>
                <div className="company-nav-section-label">{group.label}</div>
                <div className="company-nav-section-links">
                  {groupTabs.map((tab) => (
                    <button
                      key={tab.key}
                      type="button"
                      className={`company-sidebar-link ${activeTab === tab.key ? "active" : ""}`}
                      disabled={!active && tab.key !== "resumen"}
                      title={!active && tab.key !== "resumen" ? "Activa tu plan para acceder a este módulo" : undefined}
                      onClick={() => { setActiveTab(tab.key); setMenuOpen(false); }}
                    >
                      {tab.icon}
                      <span>{tab.label}</span>
                    </button>
                  ))}
                </div>
              </div>
            );
          })}
        </nav>

        <div className="company-sidebar-footer">
          <div className={`company-sidebar-plan ${active ? "active" : "inactive"}`}>
            <ShieldCheck size={16} />
            <div><span>Estado del plan</span><strong>{statusText}</strong></div>
          </div>
          <div className="company-sidebar-caption">Portal Wissa · Empresa</div>
          <button className="btn btn-danger company-sidebar-logout" onClick={signOut}><LogOut size={17} />Cerrar sesión</button>
        </div>
      </aside>

      {menuOpen ? <button type="button" className="company-sidebar-backdrop" aria-label="Cerrar menú" onClick={() => setMenuOpen(false)} /> : null}

      <main className="company-admin-main">
        <header className="company-admin-topbar">
          <div className="company-admin-title">
            <button className="btn btn-soft btn-small company-mobile-menu" onClick={() => setMenuOpen(true)} aria-label="Abrir menú"><Menu size={20} /></button>
            <div>
              <div className="eyebrow">PORTAL DE EMPRESA</div>
              <h2>{activeTabLabel}</h2>
            </div>
          </div>
          <div className="company-web-actions">
            <button className="btn btn-soft btn-small" onClick={() => setTheme(theme === "light" ? "dark" : "light")}>
              {theme === "light" ? <Moon size={16} /> : <Sun size={16} />}
              {theme === "light" ? "Oscuro" : "Claro"}
            </button>
            <button className="btn btn-soft btn-small" onClick={load}><RefreshCcw size={16} />Actualizar</button>
            <div className="company-admin-pill">
              <span className="company-admin-pill-icon"><Building2 size={18} /></span>
              <div><strong>{context?.company.name || "Empresa Wissa"}</strong><span>{active ? "Acceso activo" : "Acceso bloqueado"}</span></div>
            </div>
          </div>
        </header>

        <section className="company-web-content">
        {error ? <div className="error" style={{ marginBottom: 18 }}>{error}</div> : null}
        {success ? <div className="notice" style={{ marginBottom: 18 }}>{success}</div> : null}

        {activeTab === "resumen" ? (
          <section className="hero company-web-hero company-dashboard-hero">
            <div>
              <div className="eyebrow">PANEL EMPRESARIAL</div>
              <h1>{context?.company.name || "Empresa Wissa"}</h1>
              <p className="subtitle">Vista general de tu operación, personal, servicios, reservas y finanzas.</p>
            </div>
            <div className="company-dashboard-hero-status">
              <span className={active ? "badge green" : "badge red"}><ShieldCheck size={14} />{statusText}</span>
              <small>{active ? "La empresa tiene acceso habilitado." : "El acceso administrativo está bloqueado hasta activar o renovar el plan."}</small>
            </div>
          </section>
        ) : null}


        {activeTab === "resumen" && isAdmin ? (
          <section className="company-create-strip card">
            <div>
              <strong>Administración rápida</strong>
              <span>Agrega personal, crea servicios, revisa dinero por liquidar y controla la operación de esta empresa.</span>
            </div>
            <div>
              <button className="btn btn-soft" onClick={() => openModal("member")}><Plus size={16} />Agregar personal</button>
              <button className="btn btn-primary" onClick={() => openModal("service")}><Plus size={16} />Crear servicio</button>
            </div>
          </section>
        ) : null}

        {activeTab === "resumen" ? (
          <>
            <section className="card company-dashboard-block">
              <div className="company-dashboard-section-head">
                <span className="company-dashboard-step">1</span>
                <div><h2>Resumen ejecutivo</h2><p>Estado general de la operación de {context?.company.name || "tu empresa"}.</p></div>
              </div>
              <div className="company-dashboard-kpis">
                <CompanyDashboardMetric tone={active ? "green" : "red"} icon={<ShieldCheck size={21} />} label="Estado del plan" value={active ? "Activo" : "Inactivo"} helper={active ? "Acceso empresarial habilitado" : "Acceso empresarial bloqueado"} />
                <CompanyDashboardMetric tone="blue" icon={<Users size={21} />} label="Personal activo" value={String(context?.dashboard.active_members ?? 0)} helper={`${context?.members?.length ?? 0} registrados`} />
                <CompanyDashboardMetric tone="cyan" icon={<BriefcaseBusiness size={21} />} label="Servicios activos" value={String(context?.dashboard.active_services ?? context?.services?.filter((service) => service.is_active !== false).length ?? 0)} helper={`${context?.services?.length ?? 0} servicios configurados`} />
                <CompanyDashboardMetric tone="purple" icon={<CalendarClock size={21} />} label="Reservas" value={String(context?.dashboard.active_bookings ?? context?.bookings?.length ?? 0)} helper="Actividad registrada" />
              </div>
            </section>

            <section className="card company-dashboard-block">
              <div className="company-dashboard-section-head">
                <span className="company-dashboard-step">2</span>
                <div><h2>Plan y acceso</h2><p>Vigencia de la membresía empresarial.</p></div>
              </div>
              <div className="company-dashboard-plan-grid">
                <div><span>Plan</span><strong>{price > 0 ? money(price) : "Pendiente"}</strong></div>
                <div><span>Duración</span><strong>{days} días</strong></div>
                <div><span>Vencimiento</span><strong>{formatPanamaDate(context?.subscription?.subscription_expires_at)}</strong></div>
                <div><span>Acceso</span><strong className={active ? "company-access-active" : "company-access-blocked"}>{active ? "Activo" : "Bloqueado"}</strong></div>
              </div>
            </section>

            <section className="card company-dashboard-block">
              <div className="company-dashboard-section-head">
                <span className="company-dashboard-step">3</span>
                <div><h2>Finanzas de la empresa</h2><p>Movimiento real generado por reservas y liquidaciones.</p></div>
              </div>
              <div className="company-dashboard-kpis company-dashboard-finance-kpis">
                <CompanyDashboardMetric tone="blue" icon={<CreditCard size={21} />} label="Cobrado a clientes" value={money(context?.dashboard.total_charged ?? context?.dashboard.total_spent ?? 0)} helper="Cobros aprobados" />
                <CompanyDashboardMetric tone="green" icon={<CreditCard size={21} />} label="Neto empresa" value={money(context?.dashboard.company_net ?? 0)} helper="Ingreso neto empresarial" />
                <CompanyDashboardMetric tone="orange" icon={<CalendarClock size={21} />} label="Por liquidar" value={money(context?.dashboard.company_pending_payout ?? 0)} helper="Pendiente de pago" />
                <CompanyDashboardMetric tone="cyan" icon={<ShieldCheck size={21} />} label="Liquidado" value={money(context?.dashboard.company_paid_out ?? 0)} helper="Total pagado" />
                <CompanyDashboardMetric tone="purple" icon={<CreditCard size={21} />} label="Comisión Wissa" value={money(context?.dashboard.wissa_commission ?? 0)} helper="Comisión de plataforma" />
              </div>
            </section>
          </>
        ) : null}

        {activeTab === "resumen" && !active ? (
          <section className="card company-paywall">
            <div>
              <div className="eyebrow">{subscriptionExpired ? "RENOVACIÓN REQUERIDA" : "ACTIVACIÓN REQUERIDA"}</div>
              <h2>{subscriptionExpired ? "Tu plan empresarial está inactivo" : "Activa el plan empresarial"}</h2>
              <p className="subtitle">{subscriptionExpired ? "El plan venció y el acceso empresarial permanece bloqueado. Renueva la membresía para recuperar la gestión de personal, servicios, reservas y finanzas." : "Activa el plan empresarial para habilitar todas las funciones de gestión. Puedes completar el pago con Yappy o PagueloFácil y actualizar el estado al finalizar."}</p>
              <div className="company-pay-meta">
                <span>Plan actual</span>
                <strong>{price > 0 ? money(price) : "Pendiente"}</strong>
                <span>{days} dias de acceso</span>
              </div>
            </div>
            <div className="company-pay-actions">
              {error ? <div className="company-pay-feedback">{error}</div> : null}
              <div className="company-pay-feedback">
                Pago de membresia empresarial para {context?.company.name || "la empresa"}
              </div>
              <label className="company-pay-field">
                <span>Telefono Yappy para pagar la membresia</span>
                <input
                  className="input"
                  inputMode="numeric"
                  maxLength={8}
                  placeholder="Ej. 61234567"
                  value={yappyPhone}
                  onChange={(event) => setYappyPhone(event.target.value.replace(/\D/g, "").slice(0, 8))}
                />
              </label>
              <button type="button" className="btn btn-primary" disabled={paying !== null} onClick={() => void pay("yappy")}><CreditCard size={17} />{paying === "yappy" ? "Abriendo..." : "Pagar membresia con Yappy"}</button>
              <button type="button" className="btn btn-soft" disabled={paying !== null} onClick={() => void pay("paguelofacil")}><CreditCard size={17} />{paying === "paguelofacil" ? "Abriendo..." : "Pagar membresia con PagueloFacil"}</button>
            </div>
          </section>
        ) : null}

        {!["resumen", "precios", "perfil"].includes(activeTab) ? (
        <section className="card company-toolbar">
          <div className="company-search">
            <Search size={18} />
            <input
              className="input"
              value={searchDraft}
              onChange={(event) => setSearchDraft(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter") applyFilters();
              }}
              placeholder="Buscar en el portal empresa"
            />
          </div>
          <select className="select" value={status} onChange={(event) => setStatus(event.target.value)}>
            {["all", "pending", "active", "approved", "paid", "rejected", "cancelled", "completed", "company_admin", "company_staff"].map((option) => (
              <option key={option} value={option}>{option === "all" ? "Todos" : statusLabel(option)}</option>
            ))}
          </select>
          <button className="btn btn-soft" onClick={applyFilters}>Buscar</button>
          <button className="btn btn-soft" onClick={clearFilters}>Limpiar</button>
          <button className="btn btn-soft" disabled={!activeRows.length} onClick={() => downloadCsv(`wissa-empresa-${activeTab}.csv`, activeRows)}><Download size={16} />Excel</button>
          <button className="btn btn-soft" disabled={!activeRows.length} onClick={() => printRows(`Wissa Empresa - ${activeTab}`, activeRows)}>PDF</button>
        </section>
        ) : null}

        {activeTab === "resumen" ? <SummaryPanel context={context} onTab={setActiveTab} /> : null}
        {activeTab === "reservas" ? <BookingsPanel rows={context?.bookings ?? []} /> : null}
        {activeTab === "personal" ? <MembersPanel rows={context?.members ?? []} canManage={isAdmin} onEdit={editMember} onStatus={(member, nextStatus) => void changeMemberStatus(member, nextStatus)} /> : null}
        {activeTab === "servicios" ? (
          <>
            <div className="notice" style={{ marginBottom: 14 }}>
              <strong>Materiales e insumos empresariales.</strong> Wissa no entrega kits a empresas. Para Limpieza y Limpieza de exteriores, la empresa contratante proporciona los materiales e insumos; en Plomería, Wissa cobra únicamente el diagnóstico y la reparación posterior se coordina directamente con quien ofrece.
            </div>
            <ServicesPanel rows={context?.services ?? []} canManage={isAdmin} onCreate={() => openModal("service")} onEdit={editService} onToggle={(service) => void toggleService(service)} onRemove={(service) => void removeService(service)} />
          </>
        ) : null}
        {activeTab === "precios" && isAdmin && context?.company.id ? <CategoryPricingManagerPage companyId={context.company.id} embedded /> : null}
        {activeTab === "finanzas" ? <FinancePanel rows={context?.finance ?? []} context={context} /> : null}
        {activeTab === "perfil" && isAdmin ? (
          <CompanyProfilePanel form={profileForm} saving={saving} onChange={setProfileForm} onSave={() => void saveProfile()} />
        ) : null}
        </section>
      </main>

      {modal ? (
        <CompanyModal title={modalTitle(modal)} onClose={closeModal}>
          {error ? <div className="error" style={{ marginBottom: 14 }}>{error}</div> : null}
          {modal === "member" ? (
            <div className="company-form-grid">
              <Field label="Nombre completo" value={memberForm.fullName} onChange={(v) => setMemberForm((f) => ({ ...f, fullName: v }))} placeholder="Ej. Laura Mendoza" />
              <Field label="Correo" value={memberForm.email} onChange={(v) => setMemberForm((f) => ({ ...f, email: v }))} placeholder="correo@empresa.com" />
              <Field label="Teléfono" value={memberForm.phone} onChange={(v) => setMemberForm((f) => ({ ...f, phone: v }))} placeholder="Ej. 60000000" />
              <Field label="Cargo / posición" value={memberForm.position} onChange={(v) => setMemberForm((f) => ({ ...f, position: v }))} placeholder="Ej. Técnico, supervisor, limpieza" />
              <Field label={editingMember ? "Nueva contraseña opcional" : "Contraseña temporal"} value={memberForm.password} type="password" onChange={(v) => setMemberForm((f) => ({ ...f, password: v }))} placeholder={editingMember ? "Dejar vacío para no cambiar" : "Mínimo 8 caracteres"} />
              <label className="company-field">
                <span>Rol</span>
                <select className="select" value={memberForm.internalRole} onChange={(e) => setMemberForm((f) => ({ ...f, internalRole: e.target.value }))}>
                  <option value="company_staff">Personal empresa</option>
                  <option value="company_admin">Admin empresa</option>
                </select>
              </label>
              <div className="notice span-2">La empresa crea o vincula el acceso del personal. Si esa persona también usa Wissa como Ofrecer independiente, conserva la misma cuenta y podrá elegir entre “Ofrecer por mi cuenta” y “Trabajar para empresa”. Los servicios, reservas, disponibilidad y liquidaciones empresariales permanecen separados del modo personal.</div>
              <button className="btn btn-primary span-2" disabled={saving} onClick={() => void saveMember()}><Save size={16} />{saving ? "Guardando..." : editingMember ? "Guardar cambios" : "Crear personal y acceso app"}</button>
            </div>
          ) : null}

          {modal === "service" ? (
            <div className="company-form-grid">
              <label className="company-field span-2">
                <span>Personal responsable</span>
                <select className="select" value={serviceForm.companyMemberId} onChange={(e) => setServiceForm((f) => ({ ...f, companyMemberId: e.target.value }))}>
                  <option value="">Seleccionar personal con cuenta app</option>
                  {serviceMembers.map((member) => (
                    <option key={member.id} value={member.id} disabled={!member.user_id}>
                      {text(member.full_name)} · {text(member.email)}{member.user_id ? "" : " · pendiente de entrar al app"}
                    </option>
                  ))}
                </select>
              </label>
              <label className="company-field">
                <span>Categoría base</span>
                <select className="select" value={serviceForm.category} onChange={(event) => setServiceForm((form) => ({ ...form, category: event.target.value }))}>
                  {COMPANY_SERVICE_CATEGORIES.map((category) => <option key={category} value={category}>{category}</option>)}
                </select>
              </label>
              <Field label="Nombre del servicio" value={serviceForm.title} onChange={(v) => setServiceForm((f) => ({ ...f, title: v }))} placeholder="Ej. Limpieza de oficina mensual" />
              <Field className="span-2" label="Descripción / alcance" value={serviceForm.description} onChange={(v) => setServiceForm((f) => ({ ...f, description: v }))} placeholder="Qué incluye el servicio, condiciones, herramientas, horario o notas para el cliente" textarea />
              <div className="notice span-2">El precio se calcula con las tarifas de Categorías y precios. El servicio solo define qué ofrece la empresa y quién lo realizará.</div>
              {!linkedServiceMembers.length ? <div className="error span-2">Todavía no hay personal con cuenta app vinculada. Agrega el correo aquí y pídele a la persona crear/iniciar sesión en la app con ese mismo correo.</div> : null}
              <button className="btn btn-primary span-2" disabled={saving || !linkedServiceMembers.length} onClick={() => void saveService()}><Save size={16} />{saving ? "Guardando..." : editingService ? "Guardar cambios" : "Crear servicio empresarial"}</button>
            </div>
          ) : null}
        </CompanyModal>
      ) : null}
    </div>
  );
}

function modalTitle(modal: Exclude<ModalType, null>) {
  if (modal === "member") return "Agregar / editar personal";
  return "Crear / editar servicio empresarial";
}

function SummaryPanel({ context, onTab }: { context: CompanyContext | null; onTab: (tab: PortalTab) => void }) {
  const totalCharged = context?.dashboard.total_charged ?? context?.dashboard.total_spent ?? 0;
  const pendingPayout = context?.dashboard.company_pending_payout ?? 0;
  const paidOut = context?.dashboard.company_paid_out ?? 0;
  const wissaCommission = context?.dashboard.wissa_commission ?? 0;

  return (
    <>
      <section className="company-dashboard-money card company-dashboard-money-hidden">
        <div>
          <div className="eyebrow">Contabilidad empresa</div>
          <h2>Dinero y liquidaciones</h2>
          <p className="subtitle">Los clientes pagan a Wissa. Desde Admin Web Wissa se liquida el neto a la empresa; este panel muestra lo cobrado, comisión y pendiente.</p>
        </div>
        <div className="company-money-grid">
          <Stat label="Cobrado" value={money(totalCharged)} />
          <Stat label="Comisión Wissa" value={money(wissaCommission)} />
          <Stat label="Por liquidar" value={money(pendingPayout)} />
          <Stat label="Liquidado" value={money(paidOut)} />
        </div>
      </section>
      <section className="grid">
        <Module icon={<CalendarClock size={22} />} title="Reservas" description={`${context?.bookings.length ?? 0} registros visibles`} onClick={() => onTab("reservas")} />
        <Module icon={<Users size={22} />} title="Personal" description={`${context?.members.length ?? 0} usuarios vinculados`} onClick={() => onTab("personal")} />
        <Module icon={<BriefcaseBusiness size={22} />} title="Servicios" description={`${context?.services.length ?? 0} servicios propios`} onClick={() => onTab("servicios")} />
        <Module icon={<CreditCard size={22} />} title="Finanzas" description={`${context?.finance.length ?? 0} movimientos visibles`} onClick={() => onTab("finanzas")} />
      </section>
    </>
  );
}

function BookingsPanel({ rows }: { rows: CompanyBookingRow[] }) {
  return (
    <DataCard>
      <table className="table">
        <thead><tr><th>Servicio y configuración</th><th>Proveedor</th><th>Solicitante</th><th>Lugar</th><th>Estado</th><th>Pago</th><th>Fecha</th><th>Desglose</th></tr></thead>
        <tbody>
          {rows.length ? rows.map((row) => (
            <tr key={row.id}>
              <td>
                <strong>{text(row.service_title)}</strong>
                <div className="secondary">{text(row.pricing_summary, "Configuración no disponible")}</div>
                <div className="secondary">{text(row.pricing_source_label, "Tarifa aplicada al reservar")}</div>
                {row.pricing_breakdown ? <div className="secondary">{String(row.pricing_breakdown).replace(/cotizaci[oó]n/gi, "precio no disponible")}</div> : null}
              </td>
              <td>{text(row.provider_name)}</td>
              <td>{text(row.requested_by_name)}</td>
              <td>{text(row.location_name)}</td>
              <td>
                <Status value={row.company_request_status || row.status} />
                {row.quote_status ? <div className="secondary"><Status value={row.quote_status} /></div> : null}
              </td>
              <td><Status value={row.payment_status} /></td>
              <td>{formatPanamaDate(row.booking_date)} {formatPanamaTime(row.booking_time)}</td>
              <td>
                {row.requires_quote ? (
                  <strong>Precio no disponible</strong>
                ) : (
                  <>
                    <strong>Total {money(row.total_amount ?? 0)}</strong>
                    <div className="secondary">Subtotal {money(row.subtotal_amount ?? row.total_amount ?? 0)}</div>
                    <div className="secondary">Comisión Wissa {money(row.platform_fee ?? 0)}</div>
                    <div className="secondary">Neto empresa {money(row.provider_net ?? 0)}</div>
                  </>
                )}
              </td>
            </tr>
          )) : <Empty colSpan={8} />}
        </tbody>
      </table>
    </DataCard>
  );
}

function MembersPanel({ rows, canManage, onEdit, onStatus }: { rows: CompanyMemberRow[]; canManage: boolean; onEdit: (member: CompanyMemberRow) => void; onStatus: (member: CompanyMemberRow, status: "active" | "inactive" | "removed") => void }) {
  return (
    <DataCard>
      <table className="table">
        <thead><tr><th>Nombre</th><th>Correo</th><th>Teléfono</th><th>Cargo</th><th>Rol</th><th>Cuenta app</th><th>Estado</th><th>Creado</th><th>Acciones</th></tr></thead>
        <tbody>
          {rows.length ? rows.map((row) => (
            <tr key={row.id}>
              <td>{text(row.full_name)}</td>
              <td>{text(row.email)}</td>
              <td>{text(row.phone)}</td>
              <td>{text(row.position)}</td>
              <td><Status value={row.internal_role} /></td>
              <td>{row.user_id ? <Status value="active" /> : <Status value="invited" />}</td>
              <td><Status value={row.status} /></td>
              <td>{datetime(row.created_at)}</td>
              <td>
                {canManage ? (
                  <div className="row-actions">
                    <button className="btn btn-soft btn-small" onClick={() => onEdit(row)}><Edit3 size={13} />Editar</button>
                    {row.status === "inactive" ? (
                      <button className="btn btn-soft btn-small" onClick={() => onStatus(row, "active")}>Activar</button>
                    ) : (
                      <button className="btn btn-soft btn-small" onClick={() => onStatus(row, "inactive")}>Desactivar</button>
                    )}
                    <button className="btn btn-danger btn-small" onClick={() => onStatus(row, "removed")}>Eliminar</button>
                  </div>
                ) : "—"}
              </td>
            </tr>
          )) : <Empty colSpan={9} />}
        </tbody>
      </table>
    </DataCard>
  );
}

function ServicesPanel({ rows, canManage, onCreate, onEdit, onToggle, onRemove }: { rows: CompanyServiceRow[]; canManage: boolean; onCreate: () => void; onEdit: (service: CompanyServiceRow) => void; onToggle: (service: CompanyServiceRow) => void; onRemove: (service: CompanyServiceRow) => void }) {
  return (
    <DataCard>
      <div className="table-actions-row">
        <div>
          <strong>Servicios empresariales</strong>
          <span>Catálogo propio de esta empresa, separado del módulo Ofrecer normal.</span>
        </div>
        {canManage ? <button className="btn btn-primary" onClick={onCreate}><Plus size={16} />Crear servicio</button> : null}
      </div>
      <table className="table">
        <thead><tr><th>Servicio</th><th>Categoría base</th><th>Personal</th><th>Precio</th><th>Duración</th><th>Estado</th><th>Creado</th><th>Acciones</th></tr></thead>
        <tbody>
          {rows.length ? rows.map((row) => (
            <tr key={row.id}>
              <td><strong>{text(row.title)}</strong><div className="secondary">{text(row.description, "Sin descripción")}</div></td>
              <td>{text(row.category)}</td>
              <td>{text(row.staff_name)}<div className="secondary">{text(row.staff_email)}</div></td>
              <td><strong>{money(row.price ?? 0)}</strong></td>
              <td>{row.duration_minutes ?? 60} min</td>
              <td><Status value={row.is_active === false ? "inactive" : "active"} /></td>
              <td>{datetime(row.created_at)}</td>
              <td>
                {canManage ? (
                  <div className="row-actions">
                    <button className="btn btn-soft btn-small" onClick={() => onEdit(row)}><Edit3 size={13} />Editar</button>
                    <button className="btn btn-soft btn-small" onClick={() => onToggle(row)}>{row.is_active === false ? "Activar" : "Pausar"}</button>
                    <button className="btn btn-danger btn-small" onClick={() => onRemove(row)}>Eliminar</button>
                  </div>
                ) : "—"}
              </td>
            </tr>
          )) : <Empty colSpan={8} />}
        </tbody>
      </table>
    </DataCard>
  );
}

function CompanyMoneyOverview({ context }: { context: CompanyContext | null }) {
  const totalCharged = context?.dashboard.total_charged ?? context?.dashboard.total_spent ?? 0;
  const pendingPayout = context?.dashboard.company_pending_payout ?? 0;
  const paidOut = context?.dashboard.company_paid_out ?? 0;
  const wissaCommission = context?.dashboard.wissa_commission ?? 0;

  return (
    <section className="company-dashboard-money card">
      <div>
        <div className="eyebrow">Contabilidad empresa</div>
        <h2>Dinero y liquidaciones</h2>
        <p className="subtitle">Los clientes pagan a Wissa. Este módulo muestra lo cobrado, la comisión de la plataforma y el neto pendiente de liquidación.</p>
      </div>
      <div className="company-money-grid">
        <Stat label="Cobrado" value={money(totalCharged)} />
        <Stat label="Comisión Wissa" value={money(wissaCommission)} />
        <Stat label="Por liquidar" value={money(pendingPayout)} />
        <Stat label="Liquidado" value={money(paidOut)} />
      </div>
    </section>
  );
}

type CompanyProfileForm = {
  name: string;
  legalName: string;
  email: string;
  phone: string;
  city: string;
};

function CompanyProfilePanel({
  form,
  saving,
  onChange,
  onSave,
}: {
  form: CompanyProfileForm;
  saving: boolean;
  onChange: (next: CompanyProfileForm) => void;
  onSave: () => void;
}) {
  const update = (key: keyof CompanyProfileForm, value: string) => onChange({ ...form, [key]: value });

  return (
    <section className="card company-profile-card">
      <div className="company-profile-heading">
        <div>
          <div className="eyebrow">Identidad empresarial</div>
          <h2>Perfil de la empresa</h2>
          <p className="subtitle">El nombre comercial es el que verán los clientes en la app, los servicios y las reservas.</p>
        </div>
        <UserRound size={30} />
      </div>
      <div className="company-form-grid">
        <Field label="Nombre comercial" value={form.name} onChange={(value) => update("name", value)} placeholder="Ej. Soluciones Panamá" />
        <Field label="Razón social" value={form.legalName} onChange={(value) => update("legalName", value)} placeholder="Nombre legal opcional" />
        <Field label="Correo de contacto" value={form.email} onChange={(value) => update("email", value)} placeholder="contacto@empresa.com" />
        <Field label="Teléfono" value={form.phone} onChange={(value) => update("phone", value)} placeholder="Ej. 60000000" />
        <Field className="span-2" label="Ciudad" value={form.city} onChange={(value) => update("city", value)} placeholder="Panamá" />
        <button className="btn btn-primary span-2" disabled={saving || !form.name.trim()} onClick={onSave}>
          <Save size={16} />{saving ? "Guardando..." : "Guardar perfil empresarial"}
        </button>
      </div>
    </section>
  );
}

function FinancePanel({ rows, context }: { rows: CompanyFinanceRow[]; context: CompanyContext | null }) {
  return (
    <>
      <CompanyMoneyOverview context={context} />
      <DataCard>
      <table className="table">
        <thead><tr><th>Concepto</th><th>Origen</th><th>Estado</th><th>Método</th><th>Monto</th><th>Fecha</th></tr></thead>
        <tbody>
          {rows.length ? rows.map((row) => (
            <tr key={`${row.source}-${row.id}`}>
              <td>{text(row.concept)}</td>
              <td><Status value={row.source} /></td>
              <td><Status value={row.status} /></td>
              <td>{text(row.method)}</td>
              <td><strong>{money(row.amount ?? 0, row.currency || "USD")}</strong></td>
              <td>{datetime(row.created_at)}</td>
            </tr>
          )) : <Empty colSpan={6} />}
        </tbody>
      </table>
      </DataCard>
    </>
  );
}

function CompanyModal({ title, children, onClose }: { title: string; children: ReactNode; onClose: () => void }) {
  return (
    <div className="modal-backdrop">
      <section className="modal company-modal">
        <div className="modal-head">
          <div>
            <div className="eyebrow">Wissa Empresas</div>
            <h2>{title}</h2>
          </div>
          <button className="btn btn-soft btn-small" onClick={onClose}><X size={16} />Cerrar</button>
        </div>
        <div className="modal-body">{children}</div>
      </section>
    </div>
  );
}

function Field({ label, value, onChange, placeholder, textarea, type = "text", className = "" }: { label: string; value: string; onChange: (value: string) => void; placeholder?: string; textarea?: boolean; type?: string; className?: string }) {
  return (
    <label className={`company-field ${className}`}>
      <span>{label}</span>
      {textarea ? (
        <textarea className="textarea" rows={4} value={value} placeholder={placeholder} onChange={(event) => onChange(event.target.value)} />
      ) : (
        <input className="input" type={type} value={value} placeholder={placeholder} onChange={(event) => onChange(event.target.value)} />
      )}
    </label>
  );
}

function CompanyDashboardMetric({ icon, label, value, helper, tone }: { icon: ReactNode; label: string; value: ReactNode; helper: string; tone: "blue" | "green" | "cyan" | "purple" | "orange" | "red" }) {
  return (
    <div className={`company-dashboard-metric tone-${tone}`}>
      <div className="company-dashboard-metric-icon">{icon}</div>
      <div className="company-dashboard-metric-copy">
        <span>{label}</span>
        <strong>{value}</strong>
        <small>{helper}</small>
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: ReactNode }) {
  return <div className="stat"><span>{label}</span><strong>{value}</strong></div>;
}

function Module({ icon, title, description, onClick }: { icon: ReactNode; title: string; description: string; onClick: () => void }) {
  return (
    <button className="module company-module-button" onClick={onClick}>
      <div className="module-icon">{icon}</div>
      <h3>{title}</h3>
      <p>{description}</p>
    </button>
  );
}

function DataCard({ children }: { children: ReactNode }) {
  return <section className="card table-card"><div className="table-wrap">{children}</div></section>;
}

function Empty({ colSpan }: { colSpan: number }) {
  return <tr><td colSpan={colSpan} className="empty">No hay datos para mostrar.</td></tr>;
}

function Status({ value }: { value: unknown }) {
  const normalized = String(value || "pending").toLowerCase();
  let cls = "badge";
  if (["approved", "paid", "released", "active", "company_admin", "booking_payment"].some((key) => normalized.includes(key))) cls += " green";
  else if (["failed", "rejected", "cancelled", "suspended", "inactive", "removed"].some((key) => normalized.includes(key))) cls += " red";
  else if (["pending", "processing", "company_staff", "invited", "company_plan"].some((key) => normalized.includes(key))) cls += " yellow";
  else cls += " cyan";
  return <span className={cls}>{statusLabel(value)}</span>;
}

function summaryExportRows(context: CompanyContext | null): ExportRow[] {
  if (!context) return [];
  return [
    { metric: "Personal", value: context.dashboard.active_members ?? 0 },
    { metric: "Servicios", value: context.services.length ?? 0 },
    { metric: "Reservas pendientes", value: context.dashboard.pending_requests ?? 0 },
    { metric: "Cobrado a clientes", value: context.dashboard.total_charged ?? context.dashboard.total_spent ?? 0 },
    { metric: "Comisión Wissa", value: context.dashboard.wissa_commission ?? 0 },
    { metric: "Neto empresa", value: context.dashboard.company_net ?? 0 },
    { metric: "Por liquidar", value: context.dashboard.company_pending_payout ?? 0 },
    { metric: "Liquidado", value: context.dashboard.company_paid_out ?? 0 },
  ];
}

function bookingExportRows(rows: CompanyBookingRow[]): ExportRow[] {
  return rows.map((row) => ({
    servicio: row.service_title,
    configuracion_reservada: row.pricing_summary,
    fuente_del_precio: row.pricing_source_label,
    desglose: row.pricing_breakdown,
    proveedor: row.provider_name,
    solicitante: row.requested_by_name,
    lugar: row.location_name,
    estado: statusLabel(row.company_request_status || row.status),
    estado_del_precio: row.requires_quote ? "Precio no disponible" : statusLabel(row.quote_status),
    pago: statusLabel(row.payment_status),
    fecha: row.booking_date,
    hora: row.booking_time,
    subtotal: row.subtotal_amount ?? 0,
    comision_wissa_12: row.platform_fee ?? 0,
    neto_empresa: row.provider_net ?? 0,
    total: row.requires_quote ? "Precio no disponible" : row.total_amount ?? 0,
  }));
}

function memberExportRows(rows: CompanyMemberRow[]): ExportRow[] {
  return rows.map((row) => ({
    nombre: row.full_name,
    correo: row.email,
    teléfono: row.phone,
    cargo: row.position,
    rol: statusLabel(row.internal_role),
    estado: statusLabel(row.status),
    creado: datetime(row.created_at),
  }));
}

function serviceExportRows(rows: CompanyServiceRow[]): ExportRow[] {
  return rows.map((row) => ({
    servicio: row.title,
    categoria: row.category,
    personal: row.staff_name,
    correo_personal: row.staff_email,
    precio: row.price ?? 0,
    duracion_minutos: row.duration_minutes ?? 0,
    estado: row.is_active === false ? "Inactivo" : "Activo",
    creado: datetime(row.created_at),
  }));
}

function financeExportRows(rows: CompanyFinanceRow[]): ExportRow[] {
  return rows.map((row) => ({
    concepto: row.concept,
    origen: statusLabel(row.source),
    estado: statusLabel(row.status),
    método: row.method,
    monto: row.amount ?? 0,
    fecha: datetime(row.created_at),
  }));
}

function downloadCsv(filename: string, rows: ExportRow[]) {
  if (!rows.length) return;
  const headers = Object.keys(rows[0]);
  const csv = [
    headers.join(","),
    ...rows.map((row) => headers.map((header) => csvCell(row[header])).join(",")),
  ].join("\n");
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

function printRows(title: string, rows: ExportRow[]) {
  if (!rows.length) return;
  const headers = Object.keys(rows[0]);
  const body = rows.map((row) => `<tr>${headers.map((header) => `<td>${escapeHtml(String(row[header] ?? ""))}</td>`).join("")}</tr>`).join("");
  const win = window.open("", "_blank", "noopener,noreferrer,width=980,height=720");
  if (!win) return;
  win.document.open();
  win.document.write(`<!doctype html><html lang="es"><head><meta charset="utf-8" /><title>${escapeHtml(title)}</title><style>body{font-family:Arial,sans-serif;color:#0f172a;margin:28px}table{width:100%;border-collapse:collapse;font-size:12px}th{background:#0f172a;color:white;text-align:left;padding:9px}td{padding:8px;border:1px solid #cbd5e1}</style></head><body><h1>${escapeHtml(title)}</h1><p>${escapeHtml(datetime(new Date().toISOString()))}</p><table><thead><tr>${headers.map((header) => `<th>${escapeHtml(header)}</th>`).join("")}</tr></thead><tbody>${body}</tbody></table></body></html>`);
  win.document.close();
  win.focus();
  window.setTimeout(() => win.print(), 250);
}

function csvCell(value: RowValue) {
  const raw = String(value ?? "");
  return `"${raw.replaceAll('"', '""')}"`;
}

function escapeHtml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function isAuthErrorMessage(message: string) {
  const normalized = message
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase();

  return (
    normalized.includes("auth session") ||
    normalized.includes("session missing") ||
    normalized.includes("sesion") ||
    normalized.includes("iniciar sesion") ||
    normalized.includes("login")
  );
}
