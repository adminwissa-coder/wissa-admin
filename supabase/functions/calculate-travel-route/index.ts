import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const DEFAULT_TRAVEL_RATE_PER_KM = 0.60;
const MAX_CANDIDATES = 15;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

function safeCoordinate(value: unknown, min: number, max: number) {
  const n = Number(value);
  return Number.isFinite(n) && n >= min && n <= max ? n : null;
}

function normalizeCategory(value: unknown) {
  return String(value ?? "")
    .trim()
    .toLocaleLowerCase("es")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "");
}

type CandidateRequest = { providerId: string; serviceId: string };
type ResolvedCandidate = CandidateRequest & {
  category: string;
  originLatitude: number;
  originLongitude: number;
  originLabel: string;
  originSource: "service_offer_location" | "provider_profile_location";
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ ok: false, message: "Método no permitido." }, 405);

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SERVICE_ROLE_KEY") ?? "";
    const googleKey =
      Deno.env.get("GOOGLE_MAPS_SERVER_API_KEY") ??
      Deno.env.get("GOOGLE_ROUTES_API_KEY") ??
      Deno.env.get("GOOGLE_MAPS_API_KEY") ??
      "";

    if (!supabaseUrl || !anonKey || !serviceRoleKey || !googleKey) {
      return jsonResponse({ ok: false, message: "Falta la configuración privada de Google Maps/Supabase del servidor." }, 500);
    }

    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: authData } = await userClient.auth.getUser();
    if (!authData?.user) return jsonResponse({ ok: false, message: "No autenticado." }, 401);

    const body = await req.json().catch(() => ({}));
    const destinationLatitude = safeCoordinate(body.latitude ?? body.destinationLatitude, -90, 90);
    const destinationLongitude = safeCoordinate(body.longitude ?? body.destinationLongitude, -180, 180);
    if (destinationLatitude === null || destinationLongitude === null) {
      return jsonResponse({ ok: false, message: "La ubicación destino es obligatoria." }, 400);
    }

    const rawCandidates = Array.isArray(body.candidates)
      ? body.candidates
      : [{ providerId: body.providerId ?? body.provider_id, serviceId: body.serviceId ?? body.service_id }];

    const seenProviders = new Set<string>();
    const candidates: CandidateRequest[] = [];
    for (const item of rawCandidates) {
      const providerId = String(item?.providerId ?? item?.provider_id ?? "").trim();
      const serviceId = String(item?.serviceId ?? item?.service_id ?? "").trim();
      if (!providerId || seenProviders.has(providerId)) continue;
      seenProviders.add(providerId);
      candidates.push({ providerId, serviceId });
      if (candidates.length >= MAX_CANDIDATES) break;
    }
    if (!candidates.length) return jsonResponse({ ok: false, message: "No hay profesionales disponibles para evaluar cobertura." }, 400);

    const providerIds = candidates.map((item) => item.providerId);
    const serviceIds = candidates.map((item) => item.serviceId).filter(Boolean);

    const [{ data: profiles, error: profilesError }, { data: services, error: servicesError }] = await Promise.all([
      admin.from("profiles").select("id,latitude,longitude,lat,lng,location_label,city").in("id", providerIds),
      serviceIds.length
        ? admin.from("services").select("id,provider_id,category,offer_location_address,offer_latitude,offer_longitude").in("id", serviceIds)
        : Promise.resolve({ data: [], error: null }),
    ]);
    if (profilesError) throw profilesError;
    if (servicesError) throw servicesError;

    const profileMap = new Map((profiles || []).map((row: any) => [String(row.id), row]));
    const serviceMap = new Map((services || []).map((row: any) => [String(row.id), row]));
    const resolved: ResolvedCandidate[] = [];

    for (const candidate of candidates) {
      const profile: any = profileMap.get(candidate.providerId);
      if (!profile) continue;
      const service: any = candidate.serviceId ? serviceMap.get(candidate.serviceId) : null;
      if (service?.provider_id && String(service.provider_id) !== candidate.providerId) continue;

      const serviceLat = safeCoordinate(service?.offer_latitude, -90, 90);
      const serviceLng = safeCoordinate(service?.offer_longitude, -180, 180);
      const profileLat = safeCoordinate(profile.latitude ?? profile.lat, -90, 90);
      const profileLng = safeCoordinate(profile.longitude ?? profile.lng, -180, 180);
      const useServiceOrigin = serviceLat !== null && serviceLng !== null;
      const originLatitude = useServiceOrigin ? serviceLat : profileLat;
      const originLongitude = useServiceOrigin ? serviceLng : profileLng;
      if (originLatitude === null || originLongitude === null) continue;

      resolved.push({
        providerId: candidate.providerId,
        serviceId: candidate.serviceId,
        category: String(service?.category ?? body.category ?? ""),
        originLatitude,
        originLongitude,
        originLabel: String(
          (useServiceOrigin ? service?.offer_location_address : null) ||
          profile.location_label ||
          profile.city ||
          "Ubicación base del profesional",
        ),
        originSource: useServiceOrigin ? "service_offer_location" : "provider_profile_location",
      });
    }

    if (!resolved.length) {
      return jsonResponse({
        ok: false,
        code: "PROVIDER_BASE_LOCATION_REQUIRED",
        message: "Los profesionales disponibles deben tener una ubicación de trabajo válida.",
      }, 409);
    }

    const requestedTeamSize = Math.max(1, Math.min(MAX_CANDIDATES, Number(body.requiredProfessionals ?? body.required_professionals ?? 1) || 1));
    if (resolved.length < requestedTeamSize) {
      return jsonResponse({ ok: false, message: `Solo ${resolved.length} profesional(es) tienen una ubicación válida para este horario.` }, 409);
    }

    const categoryKey = normalizeCategory(resolved[0]?.category || body.category);
    const pricingKey = categoryKey.includes("plomer")
      ? "plumbing_pricing"
      : categoryKey.includes("exterior")
        ? "exterior_cleaning_pricing"
        : "cleaning_pricing";
    const { data: pricingRow } = await admin.from("app_settings").select("value").eq("key", pricingKey).maybeSingle();
    const configuredRate = Number((pricingRow?.value as Record<string, unknown> | null)?.travel_rate_per_km);
    const travelRatePerKm = Number.isFinite(configuredRate) && configuredRate >= 0 ? configuredRate : DEFAULT_TRAVEL_RATE_PER_KM;

    const matrixParams = new URLSearchParams({
      origins: resolved.map((item) => `${item.originLatitude},${item.originLongitude}`).join("|"),
      destinations: `${destinationLatitude},${destinationLongitude}`,
      mode: "driving",
      language: "es",
      region: "pa",
      key: googleKey,
    });
    const matrixResponse = await fetch(`https://maps.googleapis.com/maps/api/distancematrix/json?${matrixParams.toString()}`);
    if (!matrixResponse.ok) return jsonResponse({ ok: false, message: "Google Maps no respondió correctamente." }, 502);
    const matrixPayload = await matrixResponse.json();
    if (matrixPayload?.status !== "OK") {
      const denied = matrixPayload?.status === "REQUEST_DENIED";
      return jsonResponse({
        ok: false,
        message: denied
          ? "La clave privada de Google Maps no está autorizada para calcular rutas."
          : "No se pudo calcular la matriz de rutas por carretera.",
      }, denied ? 502 : 422);
    }

    const evaluated = resolved.flatMap((candidate, index) => {
      const element = matrixPayload?.rows?.[index]?.elements?.[0];
      const meters = Number(element?.distance?.value);
      if (element?.status !== "OK" || !Number.isFinite(meters) || meters < 0) return [];
      return [{
        ...candidate,
        distanceKm: Math.round((meters / 1000) * 100) / 100,
        durationSeconds: Number(element?.duration?.value || 0),
        durationText: String(element?.duration?.text || ""),
      }];
    }).sort((a, b) => a.distanceKm - b.distanceKm);

    if (evaluated.length < requestedTeamSize) {
      return jsonResponse({ ok: false, message: "No hay suficientes rutas válidas por carretera para completar el equipo." }, 422);
    }

    const selected = evaluated.slice(0, requestedTeamSize);

    const routes = await Promise.all(selected.map(async (candidate) => {
      try {
        const directionsParams = new URLSearchParams({
          origin: `${candidate.originLatitude},${candidate.originLongitude}`,
          destination: `${destinationLatitude},${destinationLongitude}`,
          mode: "driving",
          language: "es",
          region: "pa",
          key: googleKey,
        });
        const directionsResponse = await fetch(`https://maps.googleapis.com/maps/api/directions/json?${directionsParams.toString()}`);
        if (!directionsResponse.ok) return { ...candidate, polyline: "" };
        const directionsPayload = await directionsResponse.json();
        return { ...candidate, polyline: String(directionsPayload?.routes?.[0]?.overview_polyline?.points || "") };
      } catch {
        return { ...candidate, polyline: "" };
      }
    }));

    const quoteRows = routes.map((candidate) => ({
      buyer_id: authData.user.id,
      provider_id: candidate.providerId,
      latitude: destinationLatitude,
      longitude: destinationLongitude,
      origin_latitude: candidate.originLatitude,
      origin_longitude: candidate.originLongitude,
      distance_km: candidate.distanceKm,
    }));
    const { data: quotes, error: quoteError } = await admin.from("travel_quotes").insert(quoteRows).select("id,provider_id");
    if (quoteError) throw quoteError;
    const quoteMap = new Map((quotes || []).map((row: any) => [String(row.provider_id), String(row.id)]));

    const matches = routes.map((candidate) => ({
      providerId: candidate.providerId,
      serviceId: candidate.serviceId || null,
      distanceKm: candidate.distanceKm,
      quoteId: quoteMap.get(candidate.providerId) || "",
      ratePerKm: travelRatePerKm,
      travelFee: Math.round(candidate.distanceKm * travelRatePerKm * 100) / 100,
      durationSeconds: candidate.durationSeconds,
      durationText: candidate.durationText,
      originLatitude: candidate.originLatitude,
      originLongitude: candidate.originLongitude,
      originLabel: candidate.originLabel,
      originSource: candidate.originSource,
      polyline: candidate.polyline,
    }));

    const evaluatedCandidates = evaluated.slice(0, MAX_CANDIDATES).map((candidate) => ({
      providerId: candidate.providerId,
      serviceId: candidate.serviceId || null,
      distanceKm: candidate.distanceKm,
      quoteId: quoteMap.get(candidate.providerId) || "",
      ratePerKm: travelRatePerKm,
      travelFee: Math.round(candidate.distanceKm * travelRatePerKm * 100) / 100,
      durationSeconds: candidate.durationSeconds,
      durationText: candidate.durationText,
      originLatitude: candidate.originLatitude,
      originLongitude: candidate.originLongitude,
      originLabel: candidate.originLabel,
      originSource: candidate.originSource,
      polyline: routes.find((route) => route.providerId === candidate.providerId)?.polyline || "",
    }));

    const totalDistanceKm = Math.round(matches.reduce((sum, item) => sum + item.distanceKm, 0) * 100) / 100;
    const totalTravelFee = Math.round(totalDistanceKm * travelRatePerKm * 100) / 100;
    const first = matches[0];

    return jsonResponse({
      ok: true,
      mode: candidates.length > 1 ? "nearest_available_team" : "single_professional",
      evaluatedCount: evaluated.length,
      requiredProfessionals: requestedTeamSize,
      matches,
      evaluatedCandidates,
      totalDistanceKm,
      totalTravelFee,
      ratePerKm: travelRatePerKm,
      destination: { latitude: destinationLatitude, longitude: destinationLongitude },
      // Backward-compatible single-provider fields.
      distanceKm: first?.distanceKm ?? totalDistanceKm,
      quoteId: first?.quoteId ?? "",
      originLatitude: first?.originLatitude ?? null,
      originLongitude: first?.originLongitude ?? null,
      originLabel: first?.originLabel ?? null,
      originSource: first?.originSource ?? null,
      source: "google_road_distance",
    });
  } catch (error) {
    console.error("[calculate-travel-route]", error);
    return jsonResponse({ ok: false, message: error instanceof Error ? error.message : "No se pudo comprobar la cobertura de los profesionales." }, 500);
  }
});
