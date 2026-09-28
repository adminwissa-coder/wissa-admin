import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

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

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ ok: false, message: "Método no permitido." }, 405);

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const googleKey =
      Deno.env.get("GOOGLE_MAPS_SERVER_API_KEY") ??
      Deno.env.get("GOOGLE_ROUTES_API_KEY") ??
      Deno.env.get("GOOGLE_MAPS_API_KEY") ??
      "";

    if (!supabaseUrl || !anonKey || !googleKey) {
      return jsonResponse({ ok: false, message: "Falta la clave privada de Google Maps del servidor." }, 500);
    }

    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: authData } = await userClient.auth.getUser();
    if (!authData?.user) return jsonResponse({ ok: false, message: "No autenticado." }, 401);

    const body = await req.json().catch(() => ({}));
    const mode = String(body.mode ?? "").trim().toLowerCase();

    let url = "";
    if (mode === "reverse") {
      const latitude = safeCoordinate(body.latitude, -90, 90);
      const longitude = safeCoordinate(body.longitude, -180, 180);
      if (latitude === null || longitude === null) {
        return jsonResponse({ ok: false, message: "Coordenadas inválidas." }, 400);
      }

      const params = new URLSearchParams({
        latlng: `${latitude},${longitude}`,
        components: "country:PA",
        region: "pa",
        language: "es",
        key: googleKey,
      });
      url = `https://maps.googleapis.com/maps/api/geocode/json?${params.toString()}`;
    } else if (mode === "search") {
      const query = String(body.query ?? "").trim();
      if (query.length < 3) return jsonResponse({ ok: false, message: "Escribe una dirección más completa." }, 400);

      const fullQuery = /panam/i.test(query) ? query : `${query}, Panamá`;
      const params = new URLSearchParams({
        address: fullQuery,
        components: "country:PA",
        region: "pa",
        language: "es",
        key: googleKey,
      });
      url = `https://maps.googleapis.com/maps/api/geocode/json?${params.toString()}`;
    } else {
      return jsonResponse({ ok: false, message: "Modo de geocodificación inválido." }, 400);
    }

    const response = await fetch(url);
    if (!response.ok) return jsonResponse({ ok: false, message: "Google Maps no respondió correctamente." }, 502);

    const payload = await response.json();
    if (payload?.status === "REQUEST_DENIED") {
      return jsonResponse({ ok: false, message: "La clave privada de Google Maps del servidor no está autorizada para Geocoding API." }, 502);
    }

    const rows = Array.isArray(payload?.results) ? payload.results : [];
    if (payload?.status !== "OK" || rows.length === 0) {
      return jsonResponse({ ok: false, message: "No encontramos una dirección para esa ubicación." }, 404);
    }

    const results = rows.slice(0, 5).map((item: any, index: number) => ({
      id: String(item?.place_id || `${mode}-${index}`),
      address: String(item?.formatted_address || "").trim(),
      latitude: Number.isFinite(Number(item?.geometry?.location?.lat)) ? Number(item.geometry.location.lat) : null,
      longitude: Number.isFinite(Number(item?.geometry?.location?.lng)) ? Number(item.geometry.location.lng) : null,
    })).filter((item: any) => item.address);

    return jsonResponse({
      ok: true,
      address: results[0]?.address ?? null,
      results,
      source: "google_geocoding_server",
    });
  } catch (error) {
    console.error("[geocode-location]", error);
    return jsonResponse({ ok: false, message: error instanceof Error ? error.message : "No se pudo resolver la ubicación." }, 500);
  }
});
