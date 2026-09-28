import { supabase } from "@/lib/supabase";

export type CompanyRegistrationInput = {
  ownerName?: string | null;
  companyName?: string | null;
  legalName?: string | null;
  ruc?: string | null;
  phone?: string | null;
  email?: string | null;
  city?: string | null;
};

export type CompanyRow = {
  id: string;
  name: string | null;
  legal_name?: string | null;
  owner_id?: string | null;
  email?: string | null;
  phone?: string | null;
  status?: string | null;
  logo_url?: string | null;
  city?: string | null;
  country?: string | null;
  subscription_status?: string | null;
  subscription_expires_at?: string | null;
};

export type CompanySubscriptionRow = {
  company_id: string;
  company_name: string | null;
  subscription_status: string | null;
  subscription_price: number | null;
  subscription_days: number | null;
  subscription_expires_at: string | null;
  days_left: number | null;
  is_access_active: boolean;
  current_plan_price: number | null;
  current_plan_days: number | null;
};

export type CompanyDashboardRow = {
  active_locations?: number | null;
  active_members?: number | null;
  inactive_members?: number | null;
  invited_members?: number | null;
  active_services?: number | null;
  inactive_services?: number | null;
  pending_requests?: number | null;
  active_bookings?: number | null;
  paid_bookings?: number | null;
  completed_bookings?: number | null;
  total_spent?: number | null;
  total_charged?: number | null;
  wissa_commission?: number | null;
  company_net?: number | null;
  company_paid_out?: number | null;
  company_pending_payout?: number | null;
  plan_payments?: number | null;
};

export type CompanyLocationRow = {
  id: string;
  name?: string | null;
  address?: string | null;
  city?: string | null;
  phone?: string | null;
  manager_name?: string | null;
  is_active?: boolean | null;
  created_at?: string | null;
};

export type CompanyMemberRow = {
  id: string;
  user_id?: string | null;
  location_id?: string | null;
  full_name?: string | null;
  email?: string | null;
  phone?: string | null;
  position?: string | null;
  department?: string | null;
  internal_role?: string | null;
  status?: string | null;
  created_at?: string | null;
};

export type CompanyBookingRow = {
  id: string;
  service_title?: string | null;
  provider_name?: string | null;
  requested_by_name?: string | null;
  location_name?: string | null;
  booking_date?: string | null;
  booking_time?: string | null;
  status?: string | null;
  payment_status?: string | null;
  company_request_status?: string | null;
  company_approval_status?: string | null;
  total_amount?: number | null;
  subtotal_amount?: number | null;
  platform_fee?: number | null;
  provider_net?: number | null;
  pricing_summary?: string | null;
  pricing_source_label?: string | null;
  pricing_breakdown?: string | null;
  requires_quote?: boolean | null;
  quote_status?: string | null;
  created_at?: string | null;
};

export type CompanyFinanceRow = {
  id: string;
  source?: string | null;
  concept?: string | null;
  status?: string | null;
  method?: string | null;
  amount?: number | null;
  currency?: string | null;
  created_at?: string | null;
};

export type CompanyPlanOrderRow = {
  id: string;
  provider?: string | null;
  payment_method?: string | null;
  amount?: number | null;
  currency?: string | null;
  duration_days?: number | null;
  status?: string | null;
  checkout_url?: string | null;
  paid_at?: string | null;
  created_at?: string | null;
};


export type CompanyServiceRow = {
  id: string;
  company_id?: string | null;
  company_member_id?: string | null;
  provider_id?: string | null;
  staff_name?: string | null;
  staff_email?: string | null;
  title?: string | null;
  description?: string | null;
  category?: string | null;
  price?: number | null;
  duration_minutes?: number | null;
  is_active?: boolean | null;
  created_at?: string | null;
};

export type CompanyPricingKey = "cleaning_pricing" | "exterior_cleaning_pricing" | "plumbing_pricing";
export type CompanyPricingSettings = Record<CompanyPricingKey, Record<string, unknown>>;

export type UpdateCompanyProfileInput = {
  companyId: string;
  name: string;
  legalName?: string;
  email?: string;
  phone?: string;
  city?: string;
};

export type CreateCompanyLocationInput = {
  companyId: string;
  name: string;
  address?: string;
  city?: string;
  phone?: string;
  contactName?: string;
  contactPhone?: string;
  notes?: string;
};

export type CreateCompanyMemberInput = {
  companyId: string;
  fullName: string;
  email: string;
  phone?: string;
  position?: string;
  password?: string;
  internalRole?: string;
};

export type CreateCompanyServiceInput = {
  companyId: string;
  companyMemberId: string;
  title: string;
  description?: string;
  category: string;
  price: number;
  durationMinutes: number;
};

export type UpdateCompanyMemberInput = CreateCompanyMemberInput & {
  memberId: string;
};

export type UpdateCompanyServiceInput = CreateCompanyServiceInput & {
  serviceId: string;
};

export type CompanyContext = {
  company: CompanyRow;
  subscription: CompanySubscriptionRow | null;
  role: string;
  is_company_admin: boolean;
  dashboard: CompanyDashboardRow;
  locations: CompanyLocationRow[];
  members: CompanyMemberRow[];
  bookings: CompanyBookingRow[];
  finance: CompanyFinanceRow[];
  plan_orders: CompanyPlanOrderRow[];
  services: CompanyServiceRow[];
  pricing: CompanyPricingSettings | null;
};

function clean(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function metadataValue(metadata: Record<string, unknown>, ...keys: string[]): string {
  for (const key of keys) {
    const value = clean(metadata[key]);
    if (value) return value;
  }
  return "";
}

function isCompanyIntent(metadata: Record<string, unknown>, input?: CompanyRegistrationInput) {
  const role = metadataValue(metadata, "role", "app_role", "mode_preference", "account_type").toLowerCase();
  return Boolean(clean(input?.companyName) || metadataValue(metadata, "company_name") || role === "company" || role === "empresa");
}

type CompanyProfileIntent = {
  full_name?: string | null;
  display_name?: string | null;
  email?: string | null;
  phone?: string | null;
  city?: string | null;
  role?: string | null;
  account_type?: string | null;
  mode_preference?: string | null;
  company_enabled?: boolean | null;
  is_company_owner?: boolean | null;
  active_company_id?: string | null;
};

function isCompanyProfileIntent(profile?: CompanyProfileIntent | null) {
  if (!profile) return false;

  const role = clean(profile.role).toLowerCase();
  const accountType = clean(profile.account_type).toLowerCase();
  const mode = clean(profile.mode_preference).toLowerCase();

  return Boolean(
    profile.company_enabled ||
      profile.is_company_owner ||
      profile.active_company_id ||
      role === "company" ||
      role === "empresa" ||
      accountType === "company" ||
      accountType === "empresa" ||
      mode === "company" ||
      mode === "empresa",
  );
}

function normalizeRegistrationInput(
  user: { email?: string | null; user_metadata?: Record<string, unknown> },
  input?: CompanyRegistrationInput,
  profile?: CompanyProfileIntent | null,
) {
  const metadata = user.user_metadata ?? {};
  const email = clean(input?.email) || clean(profile?.email) || clean(user.email) || metadataValue(metadata, "email");
  const ownerName =
    clean(input?.ownerName) ||
    clean(profile?.full_name) ||
    clean(profile?.display_name) ||
    metadataValue(metadata, "full_name", "name", "display_name") ||
    email ||
    "Admin empresa";
  const companyName = clean(input?.companyName) || metadataValue(metadata, "company_name", "business_name") || ownerName;

  return {
    ownerName,
    companyName,
    legalName: clean(input?.legalName) || metadataValue(metadata, "company_legal_name", "legal_name"),
    ruc: clean(input?.ruc) || metadataValue(metadata, "company_ruc", "ruc", "tax_id"),
    phone: clean(input?.phone) || clean(profile?.phone) || metadataValue(metadata, "phone", "company_phone"),
    email,
    city: clean(input?.city) || metadataValue(metadata, "city", "company_city") || "Panamá",
  };
}

export async function claimCompanyMembershipForCurrentUser() {
  try {
    await supabase.rpc("yt_claim_company_membership_for_current_user");
  } catch {
    // Older databases may not have this helper yet. Owner/company checks still run below.
  }
}

export async function ensureCompanyFromCurrentUser(input?: CompanyRegistrationInput) {
  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError) throw userError;
  if (!user?.id) throw new Error("Debes iniciar sesion.");

  await claimCompanyMembershipForCurrentUser();

  const { data: existingProfile, error: existingProfileError } = await supabase
    .from("profiles")
    .select("full_name, display_name, email, phone, city, role, account_type, mode_preference, company_enabled, is_company_owner, active_company_id")
    .eq("id", user.id)
    .maybeSingle();

  if (existingProfileError) throw existingProfileError;

  const metadata = user.user_metadata ?? {};
  if (!isCompanyIntent(metadata, input) && !isCompanyProfileIntent(existingProfile)) {
    throw new Error("Este correo no tiene una empresa vinculada. Usa Crear empresa o solicita acceso al administrador de la empresa.");
  }

  const normalized = normalizeRegistrationInput(user, input, existingProfile);

  const profilePayload = {
    id: user.id,
    full_name: normalized.ownerName,
    display_name: normalized.ownerName,
    email: normalized.email,
    phone: normalized.phone || null,
    city: normalized.city || null,
    role: "company",
    account_type: "company",
    mode_preference: "company",
    theme_preference: "light",
    company_enabled: true,
    is_company_owner: true,
    status: "active",
    is_active: true,
    updated_at: new Date().toISOString(),
  };

  const { data: profile, error: profileError } = await supabase
    .from("profiles")
    .upsert(profilePayload, { onConflict: "id" })
    .select("active_company_id")
    .single();

  if (profileError) throw profileError;
  if (profile?.active_company_id) return { companyId: String(profile.active_company_id), created: false };

  const { data: existingCompany, error: existingError } = await supabase
    .from("companies")
    .select("id")
    .eq("owner_id", user.id)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (existingError) throw existingError;

  if (existingCompany?.id) {
    await supabase
      .from("profiles")
      .update({
        active_company_id: existingCompany.id,
        company_role: "company_admin",
        company_enabled: true,
        is_company_owner: true,
        updated_at: new Date().toISOString(),
      })
      .eq("id", user.id);

    return { companyId: String(existingCompany.id), created: false };
  }

  const { data: companyId, error: createError } = await supabase.rpc("yt_create_company", {
    p_name: normalized.companyName,
    p_legal_name: normalized.legalName || null,
    p_ruc: normalized.ruc || null,
    p_phone: normalized.phone || null,
    p_email: normalized.email || null,
  });

  if (createError) throw createError;
  if (!companyId) throw new Error("No se pudo crear la empresa.");

  return { companyId: String(companyId), created: true };
}

export async function getCompanyWebContext(filters?: {
  search?: string;
  status?: string;
  limit?: number;
}): Promise<CompanyContext> {
  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError) throw userError;
  if (!user?.id) throw new Error("Debes iniciar sesión.");

  const { data, error } = await supabase.rpc("yt_company_web_portal_json", {
    p_search: filters?.search ?? "",
    p_status: filters?.status ?? "all",
    p_limit: filters?.limit ?? 100,
  });

  if (error) throw error;
  if (!data || typeof data !== "object") throw new Error("No se pudo cargar el portal empresa.");

  const payload = data as Partial<CompanyContext>;
  if (!payload.company?.id) throw new Error("No encontramos una empresa asociada a este usuario.");

  const [companyAccessResult, profileAccessResult] = await Promise.all([
    supabase.from("companies").select("owner_id").eq("id", payload.company.id).maybeSingle(),
    supabase
      .from("profiles")
      .select("active_company_id,company_role,is_company_owner")
      .eq("id", user.id)
      .maybeSingle(),
  ]);

  const companyAccess = companyAccessResult.data;
  const profileAccess = profileAccessResult.data;

  const isCompanyAdmin = Boolean(
    payload.is_company_admin
    || payload.role === "company_admin"
    || payload.company.owner_id === user.id
    || companyAccess?.owner_id === user.id
    || (
      profileAccess?.active_company_id === payload.company.id
      && (profileAccess?.is_company_owner || profileAccess?.company_role === "company_admin")
    ),
  );

  let pricing: CompanyPricingSettings | null = null;
  let services: CompanyServiceRow[] = Array.isArray(payload.services) ? payload.services : [];
  let bookings: CompanyBookingRow[] = Array.isArray(payload.bookings) ? payload.bookings : [];

  const { data: pricingSnapshots, error: pricingSnapshotsError } = await supabase.rpc(
    "yt_company_booking_pricing_snapshots_json",
    { p_company_id: payload.company.id },
  );

  if (!pricingSnapshotsError && Array.isArray(pricingSnapshots)) {
    const snapshotByBooking = new Map(
      (pricingSnapshots as CompanyBookingRow[]).map((row) => [String(row.id), row]),
    );
    bookings = bookings.map((booking) => ({
      ...booking,
      ...(snapshotByBooking.get(String(booking.id)) ?? {}),
    }));
  }

  if (isCompanyAdmin) {
    const { data: pricingData, error: pricingError } = await supabase.rpc("yt_company_service_pricing_json", {
      p_company_id: payload.company.id,
    });
    if (!pricingError && pricingData && typeof pricingData === "object") {
      const value = pricingData as Partial<CompanyPricingSettings>;
      pricing = {
        cleaning_pricing: value.cleaning_pricing ?? {},
        exterior_cleaning_pricing: value.exterior_cleaning_pricing ?? {},
        plumbing_pricing: value.plumbing_pricing ?? {},
      };
    }

    const { data: serviceData, error: serviceError } = await supabase
      .from("services")
      .select(`
        id,
        company_id,
        company_member_id,
        provider_id,
        title,
        description,
        category,
        price,
        duration_minutes,
        is_active,
        created_at
      `)
      .eq("company_id", payload.company.id)
      .order("created_at", { ascending: false });

    if (!serviceError) {
      services = (serviceData ?? []).map((row: Record<string, unknown>) => {
        const member = payload.members?.find((item) => item.id === row.company_member_id);
        return {
          ...row,
          staff_name: member?.full_name ?? null,
          staff_email: member?.email ?? null,
        } as CompanyServiceRow;
      });
    }
  }

  return {
    company: payload.company,
    subscription: payload.subscription ?? null,
    role: payload.role ?? "company_staff",
    is_company_admin: isCompanyAdmin,
    dashboard: payload.dashboard ?? {},
    locations: Array.isArray(payload.locations) ? payload.locations : [],
    members: Array.isArray(payload.members) ? payload.members : [],
    bookings,
    finance: Array.isArray(payload.finance) ? payload.finance : [],
    plan_orders: Array.isArray(payload.plan_orders) ? payload.plan_orders : [],
    services,
    pricing,
  };
}

export async function createCompanyPlanCheckout(
  companyId: string,
  provider: "yappy" | "paguelofacil",
  customerPhone?: string | null,
) {
  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (!session?.access_token) throw new Error("Sesión inválida.");

  const baseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL?.replace(/\/$/, "");
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";

  if (!baseUrl) throw new Error("Falta NEXT_PUBLIC_SUPABASE_URL.");

  const response = await fetch(`${baseUrl}/functions/v1/company-plan-checkout`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${session.access_token}`,
      apikey: anonKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      companyId,
      provider,
      customerPhone: customerPhone ?? null,
    }),
  });

  const json = await response.json().catch(() => null);
  if (!response.ok || !json?.ok) throw new Error(json?.message ?? "No se pudo crear el checkout.");
  if (typeof json.checkoutUrl !== "string" || !json.checkoutUrl.trim()) {
    throw new Error("La pasarela no devolvio un enlace de pago.");
  }
  return json as { checkoutUrl: string; amount: number; durationDays: number; provider: string; orderId: string };
}


export async function createCompanyLocation(input: CreateCompanyLocationInput) {
  const { data, error } = await supabase.rpc("yt_company_web_create_location", {
    p_company_id: input.companyId,
    p_name: input.name,
    p_address: input.address || null,
    p_city: input.city || null,
    p_phone: input.phone || null,
    p_contact_name: input.contactName || null,
    p_contact_phone: input.contactPhone || null,
    p_notes: input.notes || null,
  });

  if (error) throw error;
  return String(data);
}

export async function createCompanyMember(input: CreateCompanyMemberInput) {
  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (!session?.access_token) throw new Error("Sesión inválida.");

  const baseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL?.replace(/\/$/, "");
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";

  if (!baseUrl) throw new Error("Falta NEXT_PUBLIC_SUPABASE_URL.");
  if (!input.password || input.password.length < 8) throw new Error("La contraseña debe tener mínimo 8 caracteres.");

  const response = await fetch(`${baseUrl}/functions/v1/company-create-staff-account`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${session.access_token}`,
      apikey: anonKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      companyId: input.companyId,
      fullName: input.fullName,
      email: input.email,
      phone: input.phone || null,
      position: input.position || null,
      password: input.password,
      internalRole: input.internalRole || "company_staff",
    }),
  });

  const json = await response.json().catch(() => null);
  if (!response.ok || !json?.ok) throw new Error(json?.message ?? "No se pudo crear el personal.");
  return String(json.memberId || json.userId || "");
}

export async function updateCompanyMember(input: UpdateCompanyMemberInput) {
  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (!session?.access_token) throw new Error("Sesión inválida.");

  const baseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL?.replace(/\/$/, "");
  const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";

  if (!baseUrl) throw new Error("Falta NEXT_PUBLIC_SUPABASE_URL.");

  const response = await fetch(`${baseUrl}/functions/v1/company-create-staff-account`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${session.access_token}`,
      apikey: anonKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      memberId: input.memberId,
      companyId: input.companyId,
      fullName: input.fullName,
      email: input.email,
      phone: input.phone || null,
      position: input.position || null,
      password: input.password || null,
      internalRole: input.internalRole || "company_staff",
    }),
  });

  const json = await response.json().catch(() => null);
  if (!response.ok || !json?.ok) throw new Error(json?.message ?? "No se pudo actualizar el personal.");
  return String(json.memberId || input.memberId || "");
}

export async function createCompanyService(input: CreateCompanyServiceInput) {
  const { data, error } = await supabase.rpc("yt_company_web_create_service", {
    p_company_id: input.companyId,
    p_company_member_id: input.companyMemberId,
    p_title: input.title,
    p_description: input.description || null,
    p_category: input.category,
    p_price: input.price,
    p_duration_minutes: input.durationMinutes,
  });

  if (error) throw error;
  return String(data);
}

export async function updateCompanyService(input: UpdateCompanyServiceInput) {
  const { data, error } = await supabase.rpc("yt_company_web_update_service", {
    p_service_id: input.serviceId,
    p_company_member_id: input.companyMemberId,
    p_title: input.title,
    p_description: input.description || null,
    p_category: input.category,
    p_price: input.price,
    p_duration_minutes: input.durationMinutes,
  });

  if (error) throw error;
  return String(data);
}

export async function updateCompanyServicePricing(
  companyId: string,
  key: CompanyPricingKey,
  value: Record<string, unknown>,
) {
  const { error } = await supabase.rpc("yt_company_update_service_pricing", {
    p_company_id: companyId,
    p_key: key,
    p_value: value,
  });

  if (error) throw error;
}

export async function updateCompanyProfile(input: UpdateCompanyProfileInput) {
  const { data, error } = await supabase.rpc("yt_company_web_update_profile", {
    p_company_id: input.companyId,
    p_name: input.name,
    p_legal_name: input.legalName || null,
    p_email: input.email || null,
    p_phone: input.phone || null,
    p_city: input.city || null,
  });

  if (error) throw error;
  return data;
}

export async function setCompanyServiceActive(serviceId: string, isActive: boolean) {
  const { error } = await supabase.rpc("yt_company_web_set_service_active", {
    p_service_id: serviceId,
    p_is_active: isActive,
  });

  if (error) throw error;
}

export async function setCompanyMemberStatus(memberId: string, status: "active" | "inactive" | "removed") {
  const { error } = await supabase.rpc("yt_company_web_set_member_status", {
    p_member_id: memberId,
    p_status: status,
  });

  if (error) throw error;
}

export async function removeCompanyService(serviceId: string) {
  const { error } = await supabase.rpc("yt_company_web_remove_service", {
    p_service_id: serviceId,
  });

  if (error) throw error;
}
