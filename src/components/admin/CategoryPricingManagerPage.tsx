"use client";

import { adminMessage } from "@/lib/admin-copy";
import { hourlyServicePrice } from "@/lib/hourly-cleaning-price";

import { FormEvent, useCallback, useEffect, useMemo, useState } from "react";
import { CheckCircle2, Plus, RefreshCcw, Save, SlidersHorizontal, Trash2 } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { formatPanamaDateTime, money } from "@/lib/utils";
import AccompanimentPricingCard from "@/components/admin/AccompanimentPricingCard";

const PLATFORM_COMMISSION_RATE = 0.20;
const PLUMBING_COMMISSION_RATE = 0.35;
const TRAVEL_RATE_PER_KM = 0;
const DEFAULT_MOBILITY_FEE_PER_BOOKING = 5;
const ITBMS_RATE = 0.07;

type PricingTab = "cleaning" | "exterior" | "plumbing" | "accompaniment";
type CleaningPlanKey = "basica" | "premium";
type CleaningRangeKey = "0_80" | "81_160" | "161_300";
type CleaningRangePrices = Record<CleaningPlanKey, Record<string, Record<CleaningRangeKey, number>>>;
type ProgressiveSquareMeterRate = {
  minimum: number;
  tier_0_80: number;
  tier_81_160: number;
  tier_161_300: number;
};
type ProgressiveCleaningPrices = Record<CleaningPlanKey, Record<string, ProgressiveSquareMeterRate>>;

type PlanContent = {
  title: string;
  summary: string;
  included: string[];
};

type KitOption = { title: string; description: string; price: number };
type KitSettings = { enabled: boolean; basic: KitOption; premium: KitOption };

type CleaningParametricEngine = {
  minimum_price: number;
  minimum_included_sqm: number;
  tier1_end_sqm: number;
  tier1_rate_per_sqm: number;
  tier2_end_sqm: number;
  tier2_rate_per_sqm: number;
  team_threshold_sqm: number;
  team_base_price: number;
  team_rate_per_sqm: number;
  continuous_team_pricing: boolean;
  quote_threshold_sqm: number;
  deep_cleaning_rate_per_sqm: number;
  professionals_at_team_threshold: number;
  max_professionals: number;
};


type CleaningLargeJobBlock = {
  key: string;
  label: string;
  min_sqm: number;
  max_sqm: number | null;
  professionals: number;
  estimated_hours: number;
  standard_price: number;
  deep_price: number;
  active: boolean;
};

type CleaningHourlyBlock = {
  key: string;
  label: string;
  min_sqm: number;
  max_sqm: number;
  professionals: number;
  hours: number;
  maintenance_hours: number;
  standard_hourly_rate: number;
  deep_hourly_rate: number;
  active: boolean;
};

type CleaningPricing = {
  pricing_version: number;
  currency: string;
  platform_commission_rate: number;
  platform_usage_fee: number;
  itbms_rate: number;
  hourly_service_blocks: CleaningHourlyBlock[];
  deep_hourly_surcharge: number;
  parametric_engine: CleaningParametricEngine; // legacy para snapshots históricos
  large_job_blocks: CleaningLargeJobBlock[]; // legacy para snapshots históricos
  // Compatibilidad: fixed_service_price representa la tarifa principal del servicio.
  fixed_service_price: number;
  fixed_service_prices: Record<CleaningPlanKey, number>;
  // Campos legacy se conservan para clientes anteriores.
  travel_flat_fee: number;
  cleaning_kit_price: number;
  cleaning_kit_enabled: boolean;
  travel_rate_per_km: number;
  mobility_fee_per_professional: number;
  mobility_fee_per_booking: number;
  additional_professional_fees: Record<string, number>;
  maintenance_discount_rate: number;
  mandatory_basic_kit: boolean;
  third_professional_flat_fee: number;
  kits: KitSettings;
  plan_contents: Record<CleaningPlanKey, PlanContent>;
  progressive_prices: ProgressiveCleaningPrices;
  range_prices: CleaningRangePrices;
  plans: Record<CleaningPlanKey, number>;
  included_square_meters: Record<CleaningPlanKey, number>;
  place_rates: Record<string, number>;
};

type PlumbingPricing = {
  pricing_version: number;
  currency: string;
  platform_commission_rate: number;
  platform_usage_fee: number;
  itbms_rate: number;
  travel_flat_fee: number;
  travel_rate_per_km: number;
  mobility_fee_per_professional: number;
  mobility_fee_per_booking: number;
  additional_professional_fees: Record<string, number>;
  inspection_fee: number;
  kits: KitSettings;
  quote_after_inspection: boolean;
  extra_point_price: number;
  job_base: {
    revision: number;
    fuga: number;
    destape: number;
    grifo: number;
    sanitario: number;
    calentador: number;
    exterior: number;
    otro: number;
  };
  complexity_multipliers: { basica: number; media: number; alta: number };
  parts: { sin_repuestos: number; repuestos_basicos: number };
};

type ServiceCategory = {
  name?: string | null;
  description?: string | null;
  is_active?: boolean | null;
  sort_order?: number | null;
};

type PricingPayload = {
  cleaning_pricing?: unknown;
  exterior_cleaning_pricing?: unknown;
  plumbing_pricing?: unknown;
  categories?: unknown;
  updated_at?: unknown;
  pricing_meta?: unknown;
};

type MatchingSettings = {
  primary_radius_km: number;
  extended_radius_km: number;
  response_timeout_minutes: number;
  max_candidates_to_evaluate: number;
};

const defaultMatchingSettings: MatchingSettings = {
  primary_radius_km: 20,
  extended_radius_km: 35,
  response_timeout_minutes: 5,
  max_candidates_to_evaluate: 15,
};

const cleaningPlaces = [
  ["casa", "Casa"],
  ["apartamento", "Apartamento"],
  ["oficina", "Oficina"],
  ["local_comercial", "Local comercial"],
  ["edificio", "Edificio"],
  ["otro", "Otro"],
] as const;

const exteriorPlaces = [
  ["patio", "Patio"],
  ["terraza", "Terraza"],
  ["fachada", "Fachada"],
  ["acera_entrada", "Acera o entrada"],
  ["area_comun", "Área común"],
  ["otro", "Otro"],
] as const;

type ProgressiveTierKey = "tier_0_80" | "tier_81_160" | "tier_161_300";

const cleaningRanges: { key: ProgressiveTierKey; label: string }[] = [
  { key: "tier_0_80", label: "USD/m² · 0 a 80" },
  { key: "tier_81_160", label: "USD/m² · 81 a 160" },
  { key: "tier_161_300", label: "USD/m² · 161 a 300" },
];

const interiorRangePrices: CleaningRangePrices = {
  basica: {
    casa: { "0_80": 65, "81_160": 105, "161_300": 175 },
    apartamento: { "0_80": 72.5, "81_160": 132.5, "161_300": 237.5 },
    oficina: { "0_80": 80, "81_160": 160, "161_300": 300 },
    local_comercial: { "0_80": 95, "81_160": 215, "161_300": 425 },
    edificio: { "0_80": 102.5, "81_160": 242.5, "161_300": 487.5 },
    otro: { "0_80": 80, "81_160": 160, "161_300": 300 },
  },
  premium: {
    casa: { "0_80": 70, "81_160": 110, "161_300": 180 },
    apartamento: { "0_80": 70, "81_160": 130, "161_300": 235 },
    oficina: { "0_80": 70, "81_160": 150, "161_300": 290 },
    local_comercial: { "0_80": 70, "81_160": 190, "161_300": 400 },
    edificio: { "0_80": 70, "81_160": 210, "161_300": 455 },
    otro: { "0_80": 70, "81_160": 150, "161_300": 290 },
  },
};

const exteriorRangePrices: CleaningRangePrices = {
  basica: {
    patio: { "0_80": 74.5, "81_160": 126.5, "161_300": 217.5 },
    terraza: { "0_80": 77.5, "81_160": 137.5, "161_300": 242.5 },
    fachada: { "0_80": 92.5, "81_160": 192.5, "161_300": 367.5 },
    acera_entrada: { "0_80": 73, "81_160": 121, "161_300": 205 },
    area_comun: { "0_80": 80.5, "81_160": 148.5, "161_300": 267.5 },
    otro: { "0_80": 85, "81_160": 165, "161_300": 305 },
  },
  premium: {
    patio: { "0_80": 74.5, "81_160": 126.5, "161_300": 217.5 },
    terraza: { "0_80": 77.5, "81_160": 137.5, "161_300": 242.5 },
    fachada: { "0_80": 92.5, "81_160": 192.5, "161_300": 367.5 },
    acera_entrada: { "0_80": 73, "81_160": 121, "161_300": 205 },
    area_comun: { "0_80": 80.5, "81_160": 148.5, "161_300": 267.5 },
    otro: { "0_80": 85, "81_160": 165, "161_300": 305 },
  },
};

const defaultPlanContents: Record<CleaningPlanKey, PlanContent> = {
  basica: {
    title: "Limpieza estándar",
    summary: "Ideal para el mantenimiento regular de tu espacio.",
    included: ["Balcón", "Cocina y baños", "Habitaciones y áreas seleccionadas"],
  },
  premium: {
    title: "Limpieza profunda",
    summary: "Limpieza más detallada para un nivel superior de cuidado.",
    included: ["Contenido histórico", "Detalle de superficies y bordes", "Áreas históricas seleccionadas"],
  },
};

const defaultHourlyServiceBlocks: CleaningHourlyBlock[] = [
  { key: "1_60", label: "1 a 60 m²", min_sqm: 1, max_sqm: 60, professionals: 1, hours: 4, maintenance_hours: 3, standard_hourly_rate: 12, deep_hourly_rate: 13.5, active: true },
  { key: "61_120", label: "61 a 120 m²", min_sqm: 61, max_sqm: 120, professionals: 1, hours: 5, maintenance_hours: 4, standard_hourly_rate: 12, deep_hourly_rate: 13.5, active: true },
  { key: "121_180", label: "121 a 180 m²", min_sqm: 121, max_sqm: 180, professionals: 1, hours: 6, maintenance_hours: 5, standard_hourly_rate: 12, deep_hourly_rate: 13.5, active: true },
  { key: "181_240", label: "181 a 240 m²", min_sqm: 181, max_sqm: 240, professionals: 1, hours: 7, maintenance_hours: 6, standard_hourly_rate: 12, deep_hourly_rate: 13.5, active: true },
  { key: "241_249", label: "241 a 249 m²", min_sqm: 241, max_sqm: 249, professionals: 1, hours: 8, maintenance_hours: 7, standard_hourly_rate: 12, deep_hourly_rate: 13.5, active: true },
  { key: "250_350", label: "250 a 350 m²", min_sqm: 250, max_sqm: 350, professionals: 2, hours: 8, maintenance_hours: 7, standard_hourly_rate: 12, deep_hourly_rate: 13.5, active: true },
  { key: "351_500", label: "351 a 500 m²", min_sqm: 351, max_sqm: 500, professionals: 2, hours: 8, maintenance_hours: 7, standard_hourly_rate: 15, deep_hourly_rate: 16.5, active: true },
];

const defaultParametricEngine: CleaningParametricEngine = {
  minimum_price: 35,
  minimum_included_sqm: 60,
  tier1_end_sqm: 120,
  tier1_rate_per_sqm: 0.28,
  tier2_end_sqm: 220,
  tier2_rate_per_sqm: 0.38,
  team_threshold_sqm: 250,
  team_base_price: 89.80,
  team_rate_per_sqm: 1.00,
  continuous_team_pricing: true,
  quote_threshold_sqm: 2000,
  deep_cleaning_rate_per_sqm: 0.15,
  professionals_at_team_threshold: 2,
  max_professionals: 5,
};

const STANDARD_TEAM_HOURLY_RATE = 17;
const DEEP_TEAM_HOURLY_RATE = 20.5;

const defaultLargeJobBlocks: CleaningLargeJobBlock[] = [
  { key: "251_350", label: "Más de 250 a 350 m²", min_sqm: 250, max_sqm: 350, professionals: 2, estimated_hours: 4, standard_price: 2 * 4 * STANDARD_TEAM_HOURLY_RATE, deep_price: 2 * 4 * DEEP_TEAM_HOURLY_RATE, active: true },
  { key: "351_500", label: "Más de 350 a 500 m²", min_sqm: 350, max_sqm: 500, professionals: 2, estimated_hours: 6, standard_price: 2 * 6 * STANDARD_TEAM_HOURLY_RATE, deep_price: 2 * 6 * DEEP_TEAM_HOURLY_RATE, active: true },
  { key: "501_700", label: "Más de 500 a 700 m²", min_sqm: 500, max_sqm: 700, professionals: 3, estimated_hours: 6, standard_price: 3 * 6 * STANDARD_TEAM_HOURLY_RATE, deep_price: 3 * 6 * DEEP_TEAM_HOURLY_RATE, active: true },
  { key: "701_900", label: "Más de 700 a 900 m²", min_sqm: 700, max_sqm: 900, professionals: 4, estimated_hours: 6, standard_price: 4 * 6 * STANDARD_TEAM_HOURLY_RATE, deep_price: 4 * 6 * DEEP_TEAM_HOURLY_RATE, active: true },
  { key: "901_1200", label: "Más de 900 a 1,200 m²", min_sqm: 900, max_sqm: 1200, professionals: 5, estimated_hours: 6, standard_price: 5 * 6 * STANDARD_TEAM_HOURLY_RATE, deep_price: 5 * 6 * DEEP_TEAM_HOURLY_RATE, active: true },
  { key: "1201_1500", label: "Más de 1,200 a 1,500 m²", min_sqm: 1200, max_sqm: 1500, professionals: 5, estimated_hours: 8, standard_price: 5 * 8 * STANDARD_TEAM_HOURLY_RATE, deep_price: 5 * 8 * DEEP_TEAM_HOURLY_RATE, active: true },
  { key: "1501_2000", label: "Más de 1,500 a 2,000 m²", min_sqm: 1500, max_sqm: 2000, professionals: 5, estimated_hours: 10, standard_price: 5 * 10 * STANDARD_TEAM_HOURLY_RATE, deep_price: 5 * 10 * DEEP_TEAM_HOURLY_RATE, active: true },
];

const defaultCleaning: CleaningPricing = {
  pricing_version: 65,
  currency: "USD",
  platform_commission_rate: PLATFORM_COMMISSION_RATE,
  platform_usage_fee: 2,
  itbms_rate: ITBMS_RATE,
  hourly_service_blocks: defaultHourlyServiceBlocks.map((item) => ({ ...item })),
  deep_hourly_surcharge: 1.5,
  parametric_engine: { ...defaultParametricEngine },
  large_job_blocks: defaultLargeJobBlocks.map((item) => ({ ...item })),
  fixed_service_price: 30,
  fixed_service_prices: { basica: 30, premium: 30 },
  travel_flat_fee: 0,
  cleaning_kit_price: 15,
  cleaning_kit_enabled: true,
  travel_rate_per_km: 0,
  mobility_fee_per_professional: DEFAULT_MOBILITY_FEE_PER_BOOKING,
  mobility_fee_per_booking: DEFAULT_MOBILITY_FEE_PER_BOOKING,
  additional_professional_fees: { "2": 35, "3": 35, "4": 35, "5": 35 },
  maintenance_discount_rate: 0.07,
  mandatory_basic_kit: true,
  third_professional_flat_fee: 45,
  kits: {
    enabled: true,
    basic: { title: "Kit básico", description: "Jabón, escoba, trapeador, bolsas de basura y paños de limpieza.", price: 15 },
    premium: { title: "Personalizable", description: "El cliente elige productos individuales.", price: 15 },
  },
  plan_contents: defaultPlanContents,
  progressive_prices: buildUniformProgressivePrices(cleaningPlaces),
  range_prices: deriveRangePrices(buildUniformProgressivePrices(cleaningPlaces), cleaningPlaces),
  plans: { basica: 0, premium: 0 },
  included_square_meters: { basica: 50, premium: 80 },
  place_rates: {
    casa: 0.5,
    apartamento: 0.75,
    oficina: 1,
    local_comercial: 1.5,
    edificio: 1.75,
    patio: 0.65,
    terraza: 0.75,
    fachada: 1.25,
    acera_entrada: 0.6,
    area_comun: 0.85,
    otro: 1,
  },
};

const defaultExterior: CleaningPricing = {
  ...defaultCleaning,
  pricing_version: 64,
  hourly_service_blocks: [],
  fixed_service_price: 40,
  fixed_service_prices: { basica: 40, premium: 40 },
  additional_professional_fees: { "2": 30, "3": 30, "4": 30, "5": 30 },
  progressive_prices: buildUniformProgressivePrices(exteriorPlaces),
  range_prices: deriveRangePrices(buildUniformProgressivePrices(exteriorPlaces), exteriorPlaces),
  plans: { basica: 0, premium: 0 },
};

const defaultPlumbing: PlumbingPricing = {
  pricing_version: 64,
  currency: "USD",
  platform_commission_rate: PLUMBING_COMMISSION_RATE,
  platform_usage_fee: 2,
  itbms_rate: ITBMS_RATE,
  travel_flat_fee: 0,
  travel_rate_per_km: 0,
  mobility_fee_per_professional: DEFAULT_MOBILITY_FEE_PER_BOOKING,
  mobility_fee_per_booking: DEFAULT_MOBILITY_FEE_PER_BOOKING,
  additional_professional_fees: { "2": 40, "3": 40, "4": 40, "5": 40 },
  inspection_fee: 25,
  kits: {
    enabled: false,
    basic: { title: "No aplica", description: "No disponible para esta categoría.", price: 0 },
    premium: { title: "No aplica", description: "No disponible para esta categoría.", price: 0 },
  },
  quote_after_inspection: true,
  extra_point_price: 12,
  job_base: {
    revision: 20,
    fuga: 35,
    destape: 40,
    grifo: 45,
    sanitario: 60,
    calentador: 75,
    exterior: 50,
    otro: 0,
  },
  complexity_multipliers: { basica: 1, media: 1.25, alta: 1.5 },
  parts: { sin_repuestos: 0, repuestos_basicos: 15 },
};

const categoryTabs: { key: PricingTab; title: string; subtitle: string; categoryName: string }[] = [
  { key: "cleaning", title: "Limpieza", subtitle: "Interior", categoryName: "Limpieza" },
  { key: "exterior", title: "Limpieza exterior", subtitle: "Exterior", categoryName: "Limpieza de exteriores" },
  { key: "plumbing", title: "Plomería", subtitle: "Hogar", categoryName: "Plomería" },
  { key: "accompaniment", title: "Acompañamiento", subtitle: "Por hora", categoryName: "Acompañamiento" },
];

function readObject(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}

function readPayload(value: unknown): PricingPayload {
  const raw = readObject(value);
  return {
    cleaning_pricing: raw.cleaning_pricing,
    exterior_cleaning_pricing: raw.exterior_cleaning_pricing,
    plumbing_pricing: raw.plumbing_pricing,
    categories: raw.categories,
    updated_at: raw.updated_at,
    pricing_meta: raw.pricing_meta,
  };
}

function toNumber(value: unknown, fallback = 0) {
  const numeric = Number(value);
  return Number.isFinite(numeric) && numeric >= 0 ? numeric : fallback;
}

function toPositiveNumber(value: unknown, fallback: number) {
  const numeric = Number(value);
  return Number.isFinite(numeric) && numeric > 0 ? numeric : fallback;
}

function toRate(value: unknown, fallback: number) {
  const numeric = Number(value);
  return Number.isFinite(numeric) && numeric >= 0 && numeric <= 1 ? numeric : fallback;
}

function toPositiveRate(value: unknown, fallback: number) {
  const numeric = Number(value);
  return Number.isFinite(numeric) && numeric > 0 && numeric <= 1 ? numeric : fallback;
}

function toInteger(value: unknown, fallback: number, min = 1, max = 10000) {
  const numeric = Math.round(Number(value));
  return Number.isFinite(numeric) ? Math.min(max, Math.max(min, numeric)) : fallback;
}

function normalizeParametricEngine(value: unknown): CleaningParametricEngine {
  const raw = readObject(value);
  const minimumIncluded = toInteger(raw.minimum_included_sqm ?? raw.minimumIncludedSqm, defaultParametricEngine.minimum_included_sqm, 1, 5000);
  const tier1End = Math.max(minimumIncluded, toInteger(raw.tier1_end_sqm ?? raw.tier1EndSqm, defaultParametricEngine.tier1_end_sqm, minimumIncluded, 5000));
  const tier2End = Math.max(tier1End + 1, toInteger(raw.tier2_end_sqm ?? raw.tier2EndSqm, defaultParametricEngine.tier2_end_sqm, tier1End + 1, 5000));
  const teamThreshold = Math.max(tier2End + 1, toInteger(raw.team_threshold_sqm ?? raw.teamThresholdSqm, defaultParametricEngine.team_threshold_sqm, tier2End + 1, 5000));
  const quoteThreshold = Math.max(teamThreshold, toInteger(raw.quote_threshold_sqm ?? raw.quoteThresholdSqm, defaultParametricEngine.quote_threshold_sqm, teamThreshold, 5000));
  return {
    minimum_price: toPositiveNumber(raw.minimum_price ?? raw.minimumPrice, defaultParametricEngine.minimum_price),
    minimum_included_sqm: minimumIncluded,
    tier1_end_sqm: tier1End,
    tier1_rate_per_sqm: toPositiveNumber(raw.tier1_rate_per_sqm ?? raw.tier1RatePerSqm, defaultParametricEngine.tier1_rate_per_sqm),
    tier2_end_sqm: tier2End,
    tier2_rate_per_sqm: toPositiveNumber(raw.tier2_rate_per_sqm ?? raw.tier2RatePerSqm, defaultParametricEngine.tier2_rate_per_sqm),
    team_threshold_sqm: teamThreshold,
    team_base_price: toPositiveNumber(raw.team_base_price ?? raw.teamBasePrice, defaultParametricEngine.team_base_price),
    team_rate_per_sqm: toPositiveNumber(raw.team_rate_per_sqm ?? raw.teamRatePerSqm, defaultParametricEngine.team_rate_per_sqm),
    continuous_team_pricing: typeof (raw.continuous_team_pricing ?? raw.continuousTeamPricing) === 'boolean' ? Boolean(raw.continuous_team_pricing ?? raw.continuousTeamPricing) : true,
    quote_threshold_sqm: quoteThreshold,
    deep_cleaning_rate_per_sqm: toPositiveNumber(raw.deep_cleaning_rate_per_sqm ?? raw.deepCleaningRatePerSqm, defaultParametricEngine.deep_cleaning_rate_per_sqm),
    professionals_at_team_threshold: toInteger(raw.professionals_at_team_threshold ?? raw.professionalsAtTeamThreshold, defaultParametricEngine.professionals_at_team_threshold, 1, 15),
    max_professionals: toInteger(raw.max_professionals ?? raw.maxProfessionals, defaultParametricEngine.max_professionals, 1, 5),
  };
}

function normalizeHourlyServiceBlocks(value: unknown): CleaningHourlyBlock[] {
  const source = Array.isArray(value) && value.length ? value : defaultHourlyServiceBlocks;
  const defaultsByKey = new Map(defaultHourlyServiceBlocks.map((block) => [block.key, block]));
  const parsed = source.flatMap((item) => {
    const raw = readObject(item);
    const key = String(raw.key || "");
    const fallback = defaultsByKey.get(key);
    if (!key || !fallback) return [];
    const min = toInteger(raw.min_sqm ?? raw.minSqm, fallback.min_sqm, 1, 500);
    const max = Math.max(min, toInteger(raw.max_sqm ?? raw.maxSqm, fallback.max_sqm, min, 500));
    return [{
      key,
      label: String(raw.label || fallback.label),
      min_sqm: min,
      max_sqm: max,
      professionals: toInteger(raw.professionals, fallback.professionals, 1, 5),
      hours: Math.min(8, Math.max(1, toNumber(raw.hours ?? raw.estimated_hours ?? raw.estimatedHours, fallback.hours))),
      maintenance_hours: Math.min(8, Math.max(1, toNumber(raw.maintenance_hours ?? raw.maintenanceHours, fallback.maintenance_hours ?? Math.max(1, fallback.hours - 1)))),
      standard_hourly_rate: toPositiveNumber(raw.standard_hourly_rate ?? raw.standardHourlyRate, fallback.standard_hourly_rate),
      deep_hourly_rate: toPositiveNumber(raw.deep_hourly_rate ?? raw.deepHourlyRate, fallback.deep_hourly_rate),
      active: typeof raw.active === "boolean" ? Boolean(raw.active) : true,
    }];
  });
  const byKey = new Map(parsed.map((block) => [block.key, block]));
  return defaultHourlyServiceBlocks.map((fallback) => byKey.get(fallback.key) || { ...fallback });
}

function findHourlyBlock(blocks: CleaningHourlyBlock[], squareMeters: number) {
  return blocks.find((block) => block.active && squareMeters >= block.min_sqm && squareMeters <= block.max_sqm) || null;
}

function normalizeLargeJobBlocks(value: unknown): CleaningLargeJobBlock[] {
  const source = Array.isArray(value) ? value : defaultLargeJobBlocks;
  return source.map((item, index) => {
    const raw = readObject(item);
    const fallback = defaultLargeJobBlocks[Math.min(index, defaultLargeJobBlocks.length - 1)] || defaultLargeJobBlocks[0];
    const min = toInteger(raw.min_sqm ?? raw.minSqm, fallback.min_sqm, 250, 5000);
    const rawMax = raw.max_sqm ?? raw.maxSqm;
    const max = rawMax === null || rawMax === undefined || rawMax === "" ? null : Math.max(min, toInteger(rawMax, fallback.max_sqm || min, min, 5000));
    return {
      key: String(raw.key || fallback.key),
      label: String(raw.label || fallback.label),
      min_sqm: min,
      max_sqm: max,
      professionals: toInteger(raw.professionals, fallback.professionals, 2, 5),
      estimated_hours: Math.max(0.5, toNumber(raw.estimated_hours ?? raw.estimatedHours, fallback.estimated_hours)),
      standard_price: toPositiveNumber(raw.standard_price ?? raw.standardPrice, fallback.standard_price),
      deep_price: toPositiveNumber(raw.deep_price ?? raw.deepPrice, fallback.deep_price),
      active: typeof raw.active === "boolean" ? Boolean(raw.active) : fallback.active,
    };
  }).sort((a, b) => a.min_sqm - b.min_sqm);
}

function toMultiplier(value: unknown, fallback: number) {
  const numeric = Number(value);
  return Number.isFinite(numeric) && numeric >= 1 && numeric <= 3 ? numeric : fallback;
}

function toBoolean(value: unknown, fallback: boolean) {
  return typeof value === "boolean" ? value : fallback;
}

function toStringList(value: unknown, fallback: string[]) {
  if (!Array.isArray(value)) return fallback;
  const result = value.map((item) => String(item).trim()).filter(Boolean);
  return result.length ? result : fallback;
}

function cloneRangePrices(value: CleaningRangePrices): CleaningRangePrices {
  return JSON.parse(JSON.stringify(value)) as CleaningRangePrices;
}

function roundMoney(value: number) {
  return Math.round(value * 100) / 100;
}

function calculateParametricService(engine: CleaningParametricEngine, squareMeters: number, deep = false) {
  const sqm = Math.max(1, squareMeters);
  if (sqm > engine.team_threshold_sqm) return { base: 0, deepSurcharge: 0, total: 0, quoteRequired: true, professionals: 0 };

  let base = engine.minimum_price;
  if (sqm > engine.minimum_included_sqm && sqm <= engine.tier1_end_sqm) {
    base = engine.minimum_price + (sqm - engine.minimum_included_sqm) * engine.tier1_rate_per_sqm;
  } else if (sqm > engine.tier1_end_sqm && sqm <= engine.tier2_end_sqm) {
    const tier1Price = engine.minimum_price + (engine.tier1_end_sqm - engine.minimum_included_sqm) * engine.tier1_rate_per_sqm;
    base = tier1Price + (sqm - engine.tier1_end_sqm) * engine.tier2_rate_per_sqm;
  } else if (sqm > engine.tier2_end_sqm) {
    const tier1Price = engine.minimum_price + (engine.tier1_end_sqm - engine.minimum_included_sqm) * engine.tier1_rate_per_sqm;
    const tier2Price = tier1Price + (engine.tier2_end_sqm - engine.tier1_end_sqm) * engine.tier2_rate_per_sqm;
    base = tier2Price + (sqm - engine.tier2_end_sqm) * engine.team_rate_per_sqm;
  }

  const deepSurcharge = deep ? sqm * engine.deep_cleaning_rate_per_sqm : 0;
  return { base: roundMoney(base), deepSurcharge: roundMoney(deepSurcharge), total: roundMoney(base + deepSurcharge), quoteRequired: false, professionals: 1 };
}

function calculateProgressivePrice(rate: ProgressiveSquareMeterRate, squareMeters: number) {
  const area = Math.max(0, squareMeters);
  const calculated = Math.min(area, 80) * rate.tier_0_80
    + Math.min(Math.max(area - 80, 0), 80) * rate.tier_81_160
    + Math.max(area - 160, 0) * rate.tier_161_300;
  return roundMoney(Math.max(rate.minimum, calculated));
}

function deriveProgressivePrices(
  rangePrices: CleaningRangePrices,
  plans: Record<CleaningPlanKey, number>,
  places: readonly (readonly [string, string])[],
): ProgressiveCleaningPrices {
  return (["basica", "premium"] as CleaningPlanKey[]).reduce<ProgressiveCleaningPrices>((result, plan) => {
    result[plan] = places.reduce<Record<string, ProgressiveSquareMeterRate>>((placeResult, [place]) => {
      const ranges = rangePrices[plan]?.[place] || { "0_80": plans[plan], "81_160": plans[plan], "161_300": plans[plan] };
      placeResult[place] = {
        minimum: roundMoney(plans[plan]),
        tier_0_80: roundMoney(ranges["0_80"] / 80),
        tier_81_160: roundMoney(Math.max(0, ranges["81_160"] - ranges["0_80"]) / 80),
        tier_161_300: roundMoney(Math.max(0, ranges["161_300"] - ranges["81_160"]) / 140),
      };
      return placeResult;
    }, {});
    return result;
  }, { basica: {}, premium: {} });
}

function deriveRangePrices(
  progressive: ProgressiveCleaningPrices,
  places: readonly (readonly [string, string])[],
): CleaningRangePrices {
  return (["basica", "premium"] as CleaningPlanKey[]).reduce<CleaningRangePrices>((result, plan) => {
    result[plan] = places.reduce<Record<string, Record<CleaningRangeKey, number>>>((placeResult, [place]) => {
      const rate = progressive[plan][place];
      placeResult[place] = {
        "0_80": calculateProgressivePrice(rate, 80),
        "81_160": calculateProgressivePrice(rate, 160),
        "161_300": calculateProgressivePrice(rate, 300),
      };
      return placeResult;
    }, {});
    return result;
  }, { basica: {}, premium: {} });
}

function buildUniformProgressivePrices(
  places: readonly (readonly [string, string])[],
): ProgressiveCleaningPrices {
  return (["basica", "premium"] as CleaningPlanKey[]).reduce<ProgressiveCleaningPrices>((result, plan) => {
    result[plan] = places.reduce<Record<string, ProgressiveSquareMeterRate>>((placeResult, [place]) => {
      placeResult[place] = {
        minimum: 0,
        tier_0_80: 0.50,
        tier_81_160: 0.75,
        tier_161_300: 0.95,
      };
      return placeResult;
    }, {});
    return result;
  }, { basica: {}, premium: {} });
}

function normalizePlanContent(value: unknown, fallback: PlanContent): PlanContent {
  const raw = readObject(value);
  return {
    title: String(raw.title || fallback.title),
    summary: String(raw.summary || fallback.summary),
    included: toStringList(raw.included, fallback.included),
  };
}

function normalizeKitSettings(value: unknown, fallback: KitSettings, legacyPrice = 0, legacyEnabled = true): KitSettings {
  const raw = readObject(value);
  const basic = readObject(raw.basic);
  const premium = readObject(raw.premium);
  return {
    enabled: toBoolean(raw.enabled, legacyEnabled),
    basic: {
      title: String(basic.title || fallback.basic.title),
      description: String(basic.description || fallback.basic.description),
      price: toNumber(basic.price, legacyPrice || fallback.basic.price),
    },
    premium: {
      title: String(premium.title || fallback.premium.title),
      description: String(premium.description || fallback.premium.description),
      price: toNumber(premium.price, fallback.premium.price),
    },
  };
}

function normalizeCleaning(value: unknown, exterior = false): CleaningPricing {
  const defaults = exterior ? defaultExterior : defaultCleaning;
  const raw = readObject(value);
  const plans = readObject(raw.plans);
  const includedSquareMeters = readObject(raw.included_square_meters);
  const placeRates = readObject(raw.place_rates);
  const rangePrices = readObject(raw.range_prices);
  const progressivePrices = readObject(raw.progressive_prices);
  const planContents = readObject(raw.plan_contents);
  const fixedServicePrices = readObject(raw.fixed_service_prices);
  const legacyFixedServicePrice = toNumber(raw.fixed_service_price, defaults.fixed_service_price);
  const places = exterior ? exteriorPlaces : cleaningPlaces;
  const normalizedPlans = {
    basica: toNumber(plans.basica, defaults.plans.basica),
    premium: toNumber(plans.premium, defaults.plans.premium),
  };
  const normalizedIncludedSquareMeters = {
    basica: toNumber(includedSquareMeters.basica, defaults.included_square_meters.basica),
    premium: toNumber(includedSquareMeters.premium, defaults.included_square_meters.premium),
  };
  const normalizedPlaceRates = Object.keys(defaults.place_rates).reduce<Record<string, number>>((result, key) => {
    result[key] = toNumber(placeRates[key], defaults.place_rates[key]);
    return result;
  }, {});
  const defaultProgressive = buildUniformProgressivePrices(places);
  const normalizedProgressivePrices = (["basica", "premium"] as CleaningPlanKey[]).reduce<ProgressiveCleaningPrices>(
    (planResult, planKey) => {
      const sourcePlan = readObject(progressivePrices[planKey]);
      planResult[planKey] = places.reduce<Record<string, ProgressiveSquareMeterRate>>((placeResult, [placeKey]) => {
        const sourcePlace = readObject(sourcePlan[placeKey]);
        const fallback = defaultProgressive[planKey][placeKey];
        placeResult[placeKey] = {
          minimum: 0,
          tier_0_80: toNumber(sourcePlace.tier_0_80 ?? sourcePlace.tier0To80, fallback.tier_0_80),
          tier_81_160: toNumber(sourcePlace.tier_81_160 ?? sourcePlace.tier81To160, fallback.tier_81_160),
          tier_161_300: toNumber(sourcePlace.tier_161_300 ?? sourcePlace.tier161To300, fallback.tier_161_300),
        };
        return placeResult;
      }, {});
      return planResult;
    },
    { basica: {}, premium: {} },
  );

  const normalizedFixedServicePrices: Record<CleaningPlanKey, number> = {
    basica: toPositiveNumber(fixedServicePrices.basica, legacyFixedServicePrice || defaults.fixed_service_price),
    premium: toPositiveNumber(fixedServicePrices.premium, legacyFixedServicePrice || defaults.fixed_service_price),
  };

  if (exterior) {
    normalizedProgressivePrices.premium = JSON.parse(JSON.stringify(normalizedProgressivePrices.basica)) as Record<string, ProgressiveSquareMeterRate>;
    normalizedPlans.premium = normalizedPlans.basica;
    normalizedFixedServicePrices.premium = normalizedFixedServicePrices.basica;
  }

  // v7: progressive_prices es la única fuente de verdad. range_prices se conserva
  // únicamente como compatibilidad para clientes históricos y reportes antiguos.
  const normalizedRangePrices = deriveRangePrices(normalizedProgressivePrices, places);

  const parametricEngine = exterior ? { ...defaultParametricEngine } : normalizeParametricEngine(raw.parametric_engine);
  const hourlyServiceBlocks = exterior ? [] : normalizeHourlyServiceBlocks(raw.hourly_service_blocks ?? raw.hourly_blocks);
  // Compatibility fields are derived, never an independent charge or scaling anchor.
  if (!exterior) {
    const activeBlocks = hourlyServiceBlocks.filter((block) => block.active);
    const surcharge = Math.max(0, toNumber(raw.deep_hourly_surcharge, defaults.deep_hourly_surcharge));
    normalizedFixedServicePrices.basica = activeBlocks.length ? Math.min(...activeBlocks.map((block) => hourlyServicePrice(block))) : 0;
    normalizedFixedServicePrices.premium = activeBlocks.length ? Math.min(...activeBlocks.map((block) => hourlyServicePrice(block, true, surcharge))) : 0;
  }

  return {
    pricing_version: exterior ? Math.max(64, toInteger(raw.pricing_version, defaults.pricing_version, 1, 999)) : Math.max(65, toInteger(raw.pricing_version, defaults.pricing_version, 1, 999)),
    currency: String(raw.currency || defaults.currency),
    platform_commission_rate: toPositiveRate(raw.platform_commission_rate, PLATFORM_COMMISSION_RATE),
    platform_usage_fee: toPositiveNumber(raw.platform_usage_fee, 2),
    itbms_rate: toPositiveRate(raw.itbms_rate ?? raw.tax_rate, ITBMS_RATE),
    hourly_service_blocks: hourlyServiceBlocks,
    deep_hourly_surcharge: exterior ? 0 : toNumber(raw.deep_hourly_surcharge, defaults.deep_hourly_surcharge),
    parametric_engine: parametricEngine,
    large_job_blocks: exterior ? [] : normalizeLargeJobBlocks(raw.large_job_blocks),
    fixed_service_price: normalizedFixedServicePrices.basica,
    fixed_service_prices: normalizedFixedServicePrices,
    travel_flat_fee: 0,
    cleaning_kit_price: toNumber(raw.cleaning_kit_price, defaults.cleaning_kit_price),
    cleaning_kit_enabled: toBoolean(raw.cleaning_kit_enabled, defaults.cleaning_kit_enabled),
    travel_rate_per_km: 0,
    mobility_fee_per_professional: toPositiveNumber(raw.mobility_fee_per_booking ?? raw.mobility_fee_per_professional, DEFAULT_MOBILITY_FEE_PER_BOOKING),
    mobility_fee_per_booking: toPositiveNumber(raw.mobility_fee_per_booking ?? raw.mobility_fee_per_professional, DEFAULT_MOBILITY_FEE_PER_BOOKING),
    additional_professional_fees: {
      "2": toPositiveNumber(readObject(raw.additional_professional_fees)["2"], defaults.additional_professional_fees["2"]),
      "3": toPositiveNumber(readObject(raw.additional_professional_fees)["3"], defaults.additional_professional_fees["3"]),
      "4": toPositiveNumber(readObject(raw.additional_professional_fees)["4"], defaults.additional_professional_fees["4"]),
      "5": toPositiveNumber(readObject(raw.additional_professional_fees)["5"], defaults.additional_professional_fees["5"]),
    },
    maintenance_discount_rate: exterior ? 0 : toRate(raw.maintenance_discount_rate, defaults.maintenance_discount_rate),
    mandatory_basic_kit: exterior ? false : true,
    third_professional_flat_fee: exterior ? 0 : toNumber(raw.third_professional_flat_fee, defaults.third_professional_flat_fee),
    kits: normalizeKitSettings(
      raw.kits,
      defaults.kits,
      toNumber(raw.cleaning_kit_price, defaults.cleaning_kit_price),
      toBoolean(raw.cleaning_kit_enabled, defaults.cleaning_kit_enabled),
    ),
    plan_contents: {
      basica: normalizePlanContent(planContents.basica, defaultPlanContents.basica),
      premium: normalizePlanContent(planContents.premium, defaultPlanContents.premium),
    },
    progressive_prices: normalizedProgressivePrices,
    range_prices: normalizedRangePrices,
    plans: normalizedPlans,
    included_square_meters: normalizedIncludedSquareMeters,
    place_rates: normalizedPlaceRates,
  };
}

function normalizePlumbing(value: unknown): PlumbingPricing {
  const raw = readObject(value);
  const jobBase = readObject(raw.job_base);
  const complexity = readObject(raw.complexity_multipliers);
  const parts = readObject(raw.parts);
  const legacyInspection = toNumber(jobBase.revision, defaultPlumbing.inspection_fee);
  return {
    pricing_version: 64,
    currency: String(raw.currency || defaultPlumbing.currency),
    platform_commission_rate: toRate(raw.platform_commission_rate, PLUMBING_COMMISSION_RATE),
    platform_usage_fee: toPositiveNumber(raw.platform_usage_fee, 2),
    itbms_rate: toPositiveRate(raw.itbms_rate ?? raw.tax_rate, ITBMS_RATE),
    travel_flat_fee: 0,
    travel_rate_per_km: 0,
    mobility_fee_per_professional: toPositiveNumber(raw.mobility_fee_per_booking ?? raw.mobility_fee_per_professional, DEFAULT_MOBILITY_FEE_PER_BOOKING),
    mobility_fee_per_booking: toPositiveNumber(raw.mobility_fee_per_booking ?? raw.mobility_fee_per_professional, DEFAULT_MOBILITY_FEE_PER_BOOKING),
    additional_professional_fees: {
      "2": toPositiveNumber(readObject(raw.additional_professional_fees)["2"], defaultPlumbing.additional_professional_fees["2"]),
      "3": toPositiveNumber(readObject(raw.additional_professional_fees)["3"], defaultPlumbing.additional_professional_fees["3"]),
      "4": toPositiveNumber(readObject(raw.additional_professional_fees)["4"], defaultPlumbing.additional_professional_fees["4"]),
      "5": toPositiveNumber(readObject(raw.additional_professional_fees)["5"], defaultPlumbing.additional_professional_fees["5"]),
    },
    inspection_fee: toPositiveNumber(raw.inspection_fee, legacyInspection || defaultPlumbing.inspection_fee),
    kits: normalizeKitSettings(raw.kits, defaultPlumbing.kits, 0, true),
    quote_after_inspection: true,
    extra_point_price: toNumber(raw.extra_point_price, defaultPlumbing.extra_point_price),
    job_base: {
      revision: toNumber(jobBase.revision, defaultPlumbing.job_base.revision),
      fuga: toNumber(jobBase.fuga, defaultPlumbing.job_base.fuga),
      destape: toNumber(jobBase.destape, defaultPlumbing.job_base.destape),
      grifo: toNumber(jobBase.grifo, defaultPlumbing.job_base.grifo),
      sanitario: toNumber(jobBase.sanitario, defaultPlumbing.job_base.sanitario),
      calentador: toNumber(jobBase.calentador, defaultPlumbing.job_base.calentador),
      exterior: toNumber(jobBase.exterior, defaultPlumbing.job_base.exterior),
      otro: 0,
    },
    complexity_multipliers: {
      basica: toMultiplier(complexity.basica, defaultPlumbing.complexity_multipliers.basica),
      media: toMultiplier(complexity.media, defaultPlumbing.complexity_multipliers.media),
      alta: toMultiplier(complexity.alta, defaultPlumbing.complexity_multipliers.alta),
    },
    parts: {
      sin_repuestos: 0,
      repuestos_basicos: toNumber(parts.repuestos_basicos, defaultPlumbing.parts.repuestos_basicos),
    },
  };
}


function companyCleaningWithoutKits(value: CleaningPricing): CleaningPricing {
  return {
    ...value,
    cleaning_kit_price: 0,
    cleaning_kit_enabled: false,
    mandatory_basic_kit: false,
    kits: {
      ...value.kits,
      enabled: false,
      basic: { ...value.kits.basic, title: "Materiales e insumos de la empresa", description: "La empresa contratante proporciona los materiales e insumos. Wissa no entrega kits en servicios empresariales.", price: 0 },
      premium: { ...value.kits.premium, title: "Materiales e insumos de la empresa", description: "La empresa contratante proporciona los materiales e insumos. Wissa no entrega kits en servicios empresariales.", price: 0 },
    },
  };
}

function companyPlumbingWithoutKits(value: PlumbingPricing): PlumbingPricing {
  return {
    ...value,
    kits: {
      ...value.kits,
      enabled: false,
      basic: { ...value.kits.basic, title: "Plomería solo diagnóstico", description: "Solo diagnóstico dentro de Wissa; sin kits, materiales ni reparación cobrada en la app.", price: 0 },
      premium: { ...value.kits.premium, title: "Plomería solo diagnóstico", description: "Solo diagnóstico dentro de Wissa; sin kits, materiales ni reparación cobrada en la app.", price: 0 },
    },
  };
}

type CategoryPricingManagerPageProps = {
  companyId?: string;
  embedded?: boolean;
};

export default function CategoryPricingManagerPage({ companyId, embedded = false }: CategoryPricingManagerPageProps = {}) {
  const [active, setActive] = useState<PricingTab>("cleaning");
  const [cleaning, setCleaning] = useState<CleaningPricing>(defaultCleaning);
  const [exterior, setExterior] = useState<CleaningPricing>(defaultExterior);
  const [plumbing, setPlumbing] = useState<PlumbingPricing>(defaultPlumbing);
  const [categories, setCategories] = useState<ServiceCategory[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [updatedAt, setUpdatedAt] = useState<unknown>(null);
  const [matchingSettings, setMatchingSettings] = useState<MatchingSettings>(defaultMatchingSettings);
  const [savingMatching, setSavingMatching] = useState(false);
  const [matchingMessage, setMatchingMessage] = useState("");
  const [categorySaving, setCategorySaving] = useState<string | null>(null);

  const load = useCallback(async (options?: { keepMessage?: boolean }) => {
    setLoading(true);
    setError("");
    if (!options?.keepMessage) setMessage("");

    const [{ data, error: loadError }, categoriesResult, matchingResult] = await Promise.all([
      companyId
        ? supabase.rpc("yt_company_service_pricing_json", { p_company_id: companyId })
        : supabase.rpc("yt_admin_service_pricing_json"),
      supabase.from("service_categories").select("name,description,is_active,sort_order").order("sort_order"),
      companyId
        ? Promise.resolve({ data: null, error: null })
        : supabase.rpc("yt_admin_matching_settings_json"),
    ]);

    if (loadError) {
      console.error(loadError);
      setError('No pudimos cargar las tarifas. Inténtalo nuevamente.');
      setLoading(false);
      return;
    }

    const payload = readPayload(data);

    // Leer las tarifas persistidas; normalizeCleaning deriva «Desde» por horas.
    let directCleaningValue: unknown = null;
    let directCleaningUpdatedAt: unknown = null;
    if (!companyId) {
      const directCleaningResult = await supabase
        .from("app_settings")
        .select("value,updated_at")
        .eq("key", "cleaning_pricing")
        .maybeSingle();
      if (!directCleaningResult.error && directCleaningResult.data?.value) {
        directCleaningValue = directCleaningResult.data.value;
        directCleaningUpdatedAt = directCleaningResult.data.updated_at;
      }
    }

    const nextCleaning = normalizeCleaning(directCleaningValue ?? payload.cleaning_pricing);
    const nextExterior = normalizeCleaning(payload.exterior_cleaning_pricing, true);
    const nextPlumbing = normalizePlumbing(payload.plumbing_pricing);
    setCleaning(companyId ? companyCleaningWithoutKits(nextCleaning) : nextCleaning);
    setExterior(companyId ? companyCleaningWithoutKits(nextExterior) : nextExterior);
    setPlumbing(companyId ? companyPlumbingWithoutKits(nextPlumbing) : nextPlumbing);
    setCategories(
      Array.isArray(categoriesResult.data)
        ? (categoriesResult.data as ServiceCategory[])
        : Array.isArray(payload.categories)
          ? (payload.categories as ServiceCategory[])
          : [],
    );
    setUpdatedAt(directCleaningUpdatedAt || payload.updated_at || readObject(payload.pricing_meta).updated_at || null);
    if (!companyId && !matchingResult.error) {
      const matching = readObject(matchingResult.data);
      setMatchingSettings({
        primary_radius_km: toNumber(matching.primary_radius_km, defaultMatchingSettings.primary_radius_km),
        extended_radius_km: toNumber(matching.extended_radius_km, defaultMatchingSettings.extended_radius_km),
        response_timeout_minutes: Math.max(1, Math.round(toNumber(matching.response_timeout_minutes, defaultMatchingSettings.response_timeout_minutes))),
        max_candidates_to_evaluate: Math.max(3, Math.round(toNumber(matching.max_candidates_to_evaluate, defaultMatchingSettings.max_candidates_to_evaluate))),
      });
    }
    setLoading(false);
  }, [companyId]);

  useEffect(() => {
    void load();
  }, [load]);

  const activePricing = active === "plumbing" ? plumbing : active === "exterior" ? exterior : cleaning;
  const preview = useMemo(() => {
    const pricing = active === "plumbing" ? plumbing : active === "exterior" ? exterior : cleaning;
    const commissionRate = pricing.platform_commission_rate;
    const platformUsage = pricing.platform_usage_fee;
    const taxRate = pricing.itbms_rate;
    const mobilityFee = Number((pricing as CleaningPricing | PlumbingPricing).mobility_fee_per_booking || (pricing as CleaningPricing | PlumbingPricing).mobility_fee_per_professional || DEFAULT_MOBILITY_FEE_PER_BOOKING);

    const cleaningPreviewBlock = findHourlyBlock(cleaning.hourly_service_blocks, 250) || cleaning.hourly_service_blocks[0] || defaultHourlyServiceBlocks[0];
    let serviceSubtotal = active === "plumbing" ? plumbing.inspection_fee : (active === "exterior" ? exterior.fixed_service_prices.basica : hourlyServicePrice(cleaningPreviewBlock, false, cleaning.deep_hourly_surcharge));
    serviceSubtotal = roundMoney(serviceSubtotal + mobilityFee);
    const preTaxSubtotal = roundMoney(serviceSubtotal + platformUsage);
    const tax = roundMoney(preTaxSubtotal * taxRate);
    const total = roundMoney(preTaxSubtotal + tax);
    const platformFee = roundMoney(serviceSubtotal * commissionRate);
    const wissaRevenue = roundMoney(platformFee + platformUsage);
    const providerNet = roundMoney(serviceSubtotal - platformFee);
    return { total, preTaxSubtotal, tax, platformFee, wissaRevenue, providerNet, commissionRate, taxRate, platformUsage, mobilityFee };
  }, [active, cleaning, exterior, plumbing]);

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSaving(true);
    setMessage("");
    setError("");

    const key = active === "plumbing"
      ? "plumbing_pricing"
      : active === "exterior"
        ? "exterior_cleaning_pricing"
        : "cleaning_pricing";
    const rawValue = active === "plumbing"
      ? normalizePlumbing(plumbing)
      : normalizeCleaning(active === "exterior" ? exterior : cleaning, active === "exterior");
    const value = companyId
      ? (active === "plumbing"
          ? companyPlumbingWithoutKits(rawValue as PlumbingPricing)
          : companyCleaningWithoutKits(rawValue as CleaningPricing))
      : rawValue;
    const result = companyId
      ? await supabase.rpc("yt_company_update_service_pricing", { p_company_id: companyId, p_key: key, p_value: value })
      : key === "cleaning_pricing"
        ? await supabase.rpc("yt_admin_update_cleaning_pricing_v65", { p_value: value })
        : await supabase.rpc("yt_admin_update_service_pricing", { p_key: key, p_value: value });

    if (result.error) {
      console.error(result.error);
      setError('No pudimos guardar las tarifas. Revisa los valores e inténtalo nuevamente.');
      setSaving(false);
      return;
    }

    setMessage(
      companyId
        ? "Tarifas de la empresa guardadas. Sus servicios usarán estos valores de inmediato."
        : "Tarifas globales guardadas. Las nuevas reservas usarán esta configuración.",
    );

    // Para Limpieza global verificamos el valor realmente persistido antes de
    // refrescar la pantalla. Así el Admin nunca sustituye visualmente el precio
    // base por el cálculo horario del primer rango.
    if (!companyId && key === "cleaning_pricing") {
      const persistedResult = await supabase
        .from("app_settings")
        .select("value,updated_at")
        .eq("key", "cleaning_pricing")
        .maybeSingle();

      const rpcPayload = readObject(result.data);
      const rpcValue = readObject(rpcPayload.value);
      const persistedSource = !persistedResult.error && persistedResult.data?.value
        ? persistedResult.data.value
        : Object.keys(rpcValue).length
          ? rpcValue
          : value;
      const persistedCleaning = normalizeCleaning(persistedSource);

      setCleaning(persistedCleaning);
      setUpdatedAt((!persistedResult.error && persistedResult.data?.updated_at) || rpcPayload.updated_at || updatedAt);

      if (Math.abs(persistedCleaning.fixed_service_price - (value as CleaningPricing).fixed_service_price) > 0.001) {
        setError("Las tarifas no quedaron guardadas como se indicó. Recarga la página e inténtalo nuevamente.");
        setMessage("");
      }
    } else {
      await load({ keepMessage: true });
    }
    setSaving(false);
  }

  async function saveMatchingSettings() {
    if (companyId) return;
    setSavingMatching(true);
    setMatchingMessage("");
    setError("");
    const result = await supabase.rpc("yt_admin_update_matching_settings", {
      p_primary_radius_km: matchingSettings.primary_radius_km,
      p_extended_radius_km: matchingSettings.extended_radius_km,
      p_response_timeout_minutes: matchingSettings.response_timeout_minutes,
      p_max_candidates_to_evaluate: matchingSettings.max_candidates_to_evaluate,
    });
    if (result.error) {
      console.error(result.error);
      setError('No pudimos guardar la cobertura. Inténtalo nuevamente.');
      setSavingMatching(false);
      return;
    }
    const matching = readObject(result.data);
    setMatchingSettings({
      primary_radius_km: toNumber(matching.primary_radius_km, matchingSettings.primary_radius_km),
      extended_radius_km: toNumber(matching.extended_radius_km, matchingSettings.extended_radius_km),
      response_timeout_minutes: Math.max(1, Math.round(toNumber(matching.response_timeout_minutes, matchingSettings.response_timeout_minutes))),
      max_candidates_to_evaluate: Math.max(3, Math.round(toNumber(matching.max_candidates_to_evaluate, matchingSettings.max_candidates_to_evaluate))),
    });
    setMatchingMessage("Cobertura y tiempo de respuesta guardados.");
    setSavingMatching(false);
  }

  const setCategoryActive = async (categoryName: string, nextActive: boolean) => {
    if (companyId || categorySaving) return;
    setCategorySaving(categoryName);
    setError("");
    setMessage("");
    const { error: toggleError } = await supabase.rpc("yt_admin_set_service_category_active_v754", {
      p_category_name: categoryName,
      p_is_active: nextActive,
    });
    if (toggleError) {
      console.error(toggleError);
      setError("No pudimos cambiar el estado de la categoría.");
      setCategorySaving(null);
      return;
    }
    setCategories((current) => current.map((item) => item.name === categoryName ? { ...item, is_active: nextActive } : item));
    setMessage(`${categoryName} ${nextActive ? "activada" : "desactivada"}. El cambio aplica al cliente y a las opciones de Ofrecer.`);
    setCategorySaving(null);
  };

  return (
    <div className={embedded ? "ui2-pricing-embedded" : "ui2-pricing-page"}>
      {!embedded ? (
        <section className="hero ui2-module-hero">
          <div className="hero-row">
            <div>
              <div className="eyebrow">Precios de servicios</div>
              <h1>Categorías y precios</h1>
              <p className="subtitle">Administra las tarifas y los cargos de cada servicio.</p>
            </div>
            <button className="btn btn-primary" onClick={() => void load()} type="button">
              <RefreshCcw size={17} /> Actualizar
            </button>
          </div>
        </section>
      ) : null}

      {companyId ? (
        <div className="notice" style={{ marginBottom: 16 }}>
          Estos precios aplican únicamente a esta empresa. Los materiales los proporciona la empresa.
        </div>
      ) : null}
      {error ? <div className="error" style={{ marginBottom: 16 }}>{adminMessage(error)}</div> : null}
      {message ? <div className="notice" style={{ marginBottom: 16 }}>{adminMessage(message)}</div> : null}

      <section className="stats ui2-pricing-tabs" style={{ gridTemplateColumns: "repeat(4,minmax(0,1fr))" }}>
        {categoryTabs.map((tab) => {
          const selected = active === tab.key;
          const categoryState = categories.find((item) => item.name === tab.categoryName);
          const categoryEnabled = categoryState?.is_active !== false;
          return (
            <button
              key={tab.key}
              className={`stat ${selected ? "pricing-tab-active" : ""}`}
              style={{ textAlign: "left", borderColor: selected ? "rgba(25,211,230,.7)" : undefined }}
              onClick={() => setActive(tab.key)}
              type="button"
            >
              <span>{tab.subtitle} · {categoryEnabled ? "Activa" : "Inactiva"}</span>
              <strong style={{ fontSize: 22 }}>{tab.title}</strong>
            </button>
          );
        })}
      </section>

      {active === "accompaniment" ? (
        <AccompanimentPricingCard embedded />
      ) : (
      <section className="card ui2-pricing-editor" style={{ padding: 22, marginBottom: 18 }}>
        <div className="hero-row" style={{ alignItems: "flex-start" }}>
          <div style={{ minWidth: 0 }}>
            <div className="eyebrow">Editor</div>
            <h2 style={{ margin: "8px 0 4px" }}>
              {active === "plumbing" ? "Plomería" : active === "exterior" ? "Limpieza de exteriores" : "Limpieza interior"}
            </h2>
            <p className="subtitle">Moneda {activePricing.currency} · comisión Wissa {(activePricing.platform_commission_rate * 100).toFixed(0)}% · ITBMS {(activePricing.itbms_rate * 100).toFixed(0)}% · movilidad fija {money(activePricing.mobility_fee_per_booking)} por reserva</p>
            {updatedAt ? <p className="subtitle" style={{ marginTop: 6 }}>Última actualización: {formatPanamaDateTime(updatedAt)}</p> : null}
          </div>
          <div className="stat" style={{ minWidth: 230, margin: 0 }}>
            <span>Vista previa del precio</span>
            <strong>{money(preview.total)}</strong>
            <small className="field-hint">Subtotal {money(preview.preTaxSubtotal)} · ITBMS {money(preview.tax)} · movilidad incluida {money(preview.mobilityFee)} · Wissa {money(preview.wissaRevenue)} · profesional {money(preview.providerNet)}</small>
          </div>
        </div>

        <form className="form" onSubmit={save}>
          {active === "plumbing" ? (
            companyId ? (
              <CompanyPlumbingEditor value={plumbing} onChange={setPlumbing} />
            ) : (
              <PlumbingEditor value={plumbing} onChange={setPlumbing} />
            )
          ) : (
            companyId ? (
              <CompanyCleaningEditor
                value={active === "exterior" ? exterior : cleaning}
                onChange={active === "exterior" ? setExterior : setCleaning}
                exterior={active === "exterior"}
              />
            ) : (
              <CleaningEditor
                value={active === "exterior" ? exterior : cleaning}
                onChange={active === "exterior" ? setExterior : setCleaning}
                exterior={active === "exterior"}
              />
            )
          )}

          <button className="btn btn-primary" disabled={saving || loading} style={{ width: "fit-content" }}>
            <Save size={17} /> {saving ? "Guardando..." : "Guardar precios"}
          </button>
        </form>
      </section>
      )}

      {!embedded && !companyId ? (
        <section className="card ui2-pricing-editor" style={{ padding: 22, marginBottom: 18 }}>
          <div className="hero-row" style={{ alignItems: "flex-start", marginBottom: 14 }}>
            <div>
              <div className="eyebrow">Cobertura y asignación</div>
              <h2 style={{ margin: "8px 0 4px" }}>Disponibilidad de profesionales</h2>
              <p className="subtitle">Configura la zona de cobertura y el tiempo de respuesta.</p>
            </div>
          </div>
          {matchingMessage ? <div className="notice" style={{ marginBottom: 12 }}>{adminMessage(matchingMessage)}</div> : null}
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(210px,1fr))", gap: 12 }}>
            <NumberField
              label="Cobertura inicial"
              value={matchingSettings.primary_radius_km}
              prefix=""
              suffix="km"
              onChange={(primary_radius_km) => setMatchingSettings((current) => ({ ...current, primary_radius_km }))}
            />
            <NumberField
              label="Cobertura ampliada"
              value={matchingSettings.extended_radius_km}
              prefix=""
              suffix="km"
              onChange={(extended_radius_km) => setMatchingSettings((current) => ({ ...current, extended_radius_km }))}
            />
            <NumberField
              label="Tiempo para confirmar"
              value={matchingSettings.response_timeout_minutes}
              prefix=""
              suffix="min"
              step={1}
              onChange={(response_timeout_minutes) => setMatchingSettings((current) => ({ ...current, response_timeout_minutes: Math.max(1, Math.round(response_timeout_minutes)) }))}
            />
            <NumberField
              label="Máximo de candidatos"
              value={matchingSettings.max_candidates_to_evaluate}
              prefix=""
              step={1}
              onChange={(max_candidates_to_evaluate) => setMatchingSettings((current) => ({ ...current, max_candidates_to_evaluate: Math.max(3, Math.round(max_candidates_to_evaluate)) }))}
            />
          </div>
          <div className="notice" style={{ marginTop: 12, marginBottom: 14 }}>
            El cliente elige entre los profesionales disponibles.
          </div>
          <button className="btn btn-primary" type="button" disabled={savingMatching || loading} onClick={() => void saveMatchingSettings()}>
            <Save size={17} /> {savingMatching ? "Guardando..." : "Guardar cobertura"}
          </button>
        </section>
      ) : null}

      {!embedded ? (
        <section className="card ui2-data-card" style={{ padding: 20 }}>
          <div className="hero-row" style={{ alignItems: "center", marginBottom: 14 }}>
            <div>
              <div className="eyebrow">Disponibilidad</div>
              <h2 style={{ margin: "6px 0 2px" }}>Categorías visibles</h2>
              <p className="subtitle">Al desactivar una categoría deja de aparecer al cliente y en Ofrecer → Crear servicio. No se eliminan datos ni reservas existentes.</p>
            </div>
          </div>
          <div className="stats" style={{ gridTemplateColumns: "repeat(auto-fit,minmax(230px,1fr))" }}>
            {categories.map((category) => {
              const enabled = category.is_active !== false;
              const busy = categorySaving === category.name;
              return (
                <div className="stat" key={category.name || "category"} style={{ margin: 0 }}>
                  <span>{enabled ? "VISIBLE" : "OCULTA"}</span>
                  <strong style={{ fontSize: 18 }}>{category.name || "Sin nombre"}</strong>
                  <small className="field-hint">{category.description || "Sin descripción"}</small>
                  <button
                    type="button"
                    className={`btn ${enabled ? "btn-secondary" : "btn-primary"}`}
                    disabled={busy}
                    onClick={() => void setCategoryActive(String(category.name || ""), !enabled)}
                    style={{ marginTop: 12, width: "100%" }}
                  >
                    {busy ? "Guardando..." : enabled ? "Desactivar categoría" : "Activar categoría"}
                  </button>
                </div>
              );
            })}
          </div>
        </section>
      ) : null}
    </div>
  );
}


function FinancialRulesEditor({
  commissionRate,
  platformUsageFee,
  taxRate,
  mobilityFee,
  onCommission,
  onPlatformUsage,
  onTax,
  onMobility,
}: {
  commissionRate: number;
  platformUsageFee: number;
  taxRate: number;
  mobilityFee: number;
  onCommission: (value: number) => void;
  onPlatformUsage: (value: number) => void;
  onTax: (value: number) => void;
  onMobility: (value: number) => void;
}) {
  const gridStyle = { display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(210px,1fr))", gap: 12 } as const;
  return (
    <>
      <div style={gridStyle}>
        <NumberField label="Movilidad fija por reserva" value={mobilityFee} prefix="USD " onChange={onMobility} />
        <NumberField label="Uso de plataforma" value={platformUsageFee} prefix="USD " onChange={onPlatformUsage} />
        <NumberField label="Comisión Wissa" value={roundMoney(commissionRate * 100)} prefix="" suffix="%" onChange={(value) => onCommission(Math.min(1, value / 100))} />
        <NumberField label="ITBMS" value={roundMoney(taxRate * 100)} prefix="" suffix="%" onChange={(value) => onTax(Math.min(1, value / 100))} />
      </div>
      <div className="notice" style={{ marginTop: 12 }}>
        El traslado se cobra una sola vez por reserva.
      </div>
    </>
  );
}

function AdditionalProfessionalFeesEditor({
  value,
  onChange,
}: {
  value: Record<string, number>;
  onChange: (value: Record<string, number>) => void;
}) {
  const gridStyle = { display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(185px,1fr))", gap: 12 } as const;
  return (
    <>
      <SectionTitle title="Profesionales adicionales" />
      <div className="notice" style={{ marginBottom: 12 }}>
        Configura el cargo de cada profesional adicional.
      </div>
      <div style={gridStyle}>
        {[2, 3, 4, 5].map((position) => (
          <NumberField
            key={position}
            label={`${position}.º profesional`}
            value={Math.max(1, Number(value[String(position)] || 35))}
            prefix="USD "
            onChange={(amount) => onChange({ ...value, [String(position)]: Math.max(1, roundMoney(amount)) })}
          />
        ))}
      </div>
    </>
  );
}

function LargeJobBlocksEditor({
  value,
  onChange,
}: {
  value: CleaningLargeJobBlock[];
  onChange: (value: CleaningLargeJobBlock[]) => void;
}) {
  const updateBlock = (index: number, patch: Partial<CleaningLargeJobBlock>) => {
    onChange(value.map((item, itemIndex) => itemIndex === index ? { ...item, ...patch } : item));
  };
  const removeBlock = (index: number) => onChange(value.filter((_, itemIndex) => itemIndex !== index));
  const addBlock = () => {
    const last = value[value.length - 1];
    const min = Math.max(250, Number(last?.max_sqm || last?.min_sqm || 250));
    const max = Math.min(5000, min + 149);
    onChange([
      ...value,
      {
        key: `${min}_${max}`,
        label: `Más de ${min} a ${max} m²`,
        min_sqm: min,
        max_sqm: max,
        professionals: Math.max(2, Number(last?.professionals || 2)),
        estimated_hours: Math.max(1, Number(last?.estimated_hours || 4)),
        standard_price: Math.max(35, roundMoney(Number(last?.standard_price || 135) * 1.25)),
        deep_price: Math.max(45, roundMoney(Number(last?.deep_price || 160) * 1.25)),
        active: true,
      },
    ]);
  };

  return (
    <>
      <SectionTitle title="Servicios grandes · equipo + tiempo" />
      <div className="notice" style={{ marginBottom: 14 }}>
        Define el equipo, la duración y el precio para cada tamaño de propiedad.
      </div>
      <div style={{ display: "grid", gap: 14 }}>
        {value.map((block, index) => (
          <div key={`${block.key}-${index}`} className="card" style={{ padding: 18, borderRadius: 20 }}>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12, marginBottom: 14 }}>
              <div>
                <strong>{block.label || `Bloque ${index + 1}`}</strong>
                <div className="secondary">{block.professionals} profesionales · {block.estimated_hours} h estimadas</div>
              </div>
              <button type="button" className="btn btn-danger btn-small" onClick={() => removeBlock(index)} disabled={value.length <= 1}>
                <Trash2 size={15} /> Quitar
              </button>
            </div>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(180px,1fr))", gap: 12 }}>
              <TextField label="Nombre del rango" value={block.label} onChange={(label) => updateBlock(index, { label })} />
              <NumberField label="Desde" value={block.min_sqm} prefix="" suffix=" m²" step="1" onChange={(min_sqm) => updateBlock(index, { min_sqm: Math.max(250, Math.round(min_sqm)), key: `${Math.max(250, Math.round(min_sqm))}_${block.max_sqm || "plus"}` })} />
              <NumberField label="Hasta" value={Number(block.max_sqm || 0)} prefix="" suffix=" m²" step="1" onChange={(max_sqm) => updateBlock(index, { max_sqm: max_sqm > 0 ? Math.max(block.min_sqm, Math.round(max_sqm)) : null })} />
              <NumberField label="Profesionales finales" value={block.professionals} prefix="" step="1" onChange={(professionals) => updateBlock(index, { professionals: Math.max(2, Math.min(5, Math.round(professionals))) })} />
              <NumberField label="Duración estimada" value={block.estimated_hours} prefix="" suffix=" h" step="0.5" onChange={(estimated_hours) => updateBlock(index, { estimated_hours: Math.max(0.5, estimated_hours) })} />
              <NumberField label="Precio estándar" value={block.standard_price} prefix="USD " step="0.01" onChange={(standard_price) => updateBlock(index, { standard_price: roundMoney(standard_price) })} />
              <NumberField label="Precio profunda" value={block.deep_price} prefix="USD " step="0.01" onChange={(deep_price) => updateBlock(index, { deep_price: roundMoney(deep_price) })} />
              <ToggleField label="Bloque activo" checked={block.active} onChange={(active) => updateBlock(index, { active })} />
            </div>
          </div>
        ))}
      </div>
      <button type="button" className="btn btn-soft" style={{ marginTop: 14 }} onClick={addBlock}>
        <Plus size={16} /> Agregar rango
      </button>
    </>
  );
}

function ParametricCleaningEditor({ value, onChange }: { value: CleaningPricing; onChange: (value: CleaningPricing) => void }) {
  const blocks = value.hourly_service_blocks.length ? value.hourly_service_blocks : defaultHourlyServiceBlocks;

  const updateBlock = (key: string, patch: Partial<CleaningHourlyBlock>) => {
    const next = normalizeHourlyServiceBlocks(
      blocks.map((block) => block.key === key ? { ...block, ...patch } : block),
    );
    onChange(normalizeCleaning({
      ...value,
      pricing_version: 65,
      hourly_service_blocks: next,
    }));
  };

  const examples = [60, 120, 180, 240, 250, 400, 500].map((sqm) => {
    const block = findHourlyBlock(blocks, sqm);
    return { sqm, block, price: block ? hourlyServicePrice(block, false, value.deep_hourly_surcharge) : 0 };
  });

  return (
    <>

      <SectionTitle title="Precio por hora" />
      <div className="card" style={{ padding: 18, borderRadius: 20, marginBottom: 18 }}>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(240px,1fr))", gap: 18, alignItems: "end" }}>
          <NumberField
            label="Adicional profunda por hora"
            value={value.deep_hourly_surcharge}
            prefix="USD "
            suffix="/h"
            step="0.25"
            onChange={(deep_hourly_surcharge) => onChange(normalizeCleaning({ ...value, pricing_version: 65, deep_hourly_surcharge: Math.max(0, roundMoney(deep_hourly_surcharge)) }))}
          />
        </div>
        <div className="secondary" style={{ marginTop: 12 }}>Configura las horas, los profesionales y la tarifa por hora para cada tamaño. No se cobra un cargo base adicional. El precio «Desde» se calcula automáticamente con el servicio de menor precio. Guarda los cambios para aplicarlos a nuevas reservas.</div>
      </div>

      <SectionTitle title="Precios por tamaño de propiedad" />

      <div style={{ display: "grid", gap: 14 }}>
        {blocks.map((block) => {
          const servicePrice = hourlyServicePrice(block, false, value.deep_hourly_surcharge);
          const deepServicePrice = hourlyServicePrice(block, true, value.deep_hourly_surcharge);
          return (
            <div key={block.key} className="card" style={{ padding: 18, borderRadius: 20 }}>
              <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: 12, marginBottom: 14 }}>
                <div>
                  <strong>{block.label}</strong>
                  <div className="secondary">
                    {block.professionals} profesional{block.professionals === 1 ? "" : "es"} · {block.hours} h · {money(block.standard_hourly_rate)}/h
                  </div>
                </div>
                <div className="badge">{money(block.standard_hourly_rate)}/h</div>
              </div>

              <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(175px,1fr))", gap: 12 }}>
                <NumberField
                  label="Profesionales"
                  value={block.professionals}
                  prefix=""
                  step="1"
                  onChange={(professionals) =>
                    updateBlock(block.key, {
                      professionals: Math.max(1, Math.min(5, Math.round(professionals))),
                    })
                  }
                />
                <NumberField
                  label="Horas por profesional"
                  value={block.hours}
                  prefix=""
                  suffix=" h"
                  step="1"
                  onChange={(hours) => {
                    const nextHours = Math.max(1, Math.min(8, hours));
                    updateBlock(block.key, {
                      hours: nextHours,
                      maintenance_hours: Math.min(block.maintenance_hours, nextHours),
                    });
                  }}
                />
                <NumberField
                  label="Horas de mantenimiento"
                  value={block.maintenance_hours}
                  prefix=""
                  suffix=" h"
                  step="1"
                  onChange={(maintenance_hours) =>
                    updateBlock(block.key, {
                      maintenance_hours: Math.max(1, Math.min(8, maintenance_hours)),
                    })
                  }
                />
                <NumberField
                  label="Tarifa por hora"
                  value={block.standard_hourly_rate}
                  prefix="USD "
                  suffix="/h"
                  step="0.50"
                  onChange={(standard_hourly_rate) => {
                    const rate = Math.max(0, roundMoney(standard_hourly_rate));
                    updateBlock(block.key, {
                      standard_hourly_rate: rate,
                      deep_hourly_rate: roundMoney(rate + value.deep_hourly_surcharge),
                    });
                  }}
                />
              </div>

              <div className="stats" style={{ gridTemplateColumns: "repeat(auto-fit,minmax(150px,1fr))", marginTop: 14 }}>
                <div className="stat"><span>Precio del servicio</span><strong>{money(servicePrice)}</strong></div>
                <div className="stat"><span>Limpieza profunda</span><strong>{money(deepServicePrice)}</strong></div>
                <div className="stat"><span>Tarifa/hora</span><strong>{money(block.standard_hourly_rate)}/h</strong></div>
                <div className="stat"><span>Horas del equipo</span><strong>{block.professionals * block.hours} h</strong></div>
                <div className="stat"><span>Mantenimiento</span><strong>{block.maintenance_hours} h por profesional</strong></div>
              </div>
            </div>
          );
        })}
      </div>

      <SectionTitle title="Resumen de precios" />
      <div className="stats" style={{ gridTemplateColumns: "repeat(auto-fit,minmax(150px,1fr))", marginTop: 14 }}>
        {examples.map(({ sqm, block, price }) => (
          <div className="stat" key={sqm}>
            <span>{sqm} m²</span>
            <strong>{block ? money(price) : "Cotización"}</strong>
            <small>{block ? `${block.professionals} pro · ${block.hours} h · ${money(block.standard_hourly_rate)}/h` : "Especial"}</small>
          </div>
        ))}
      </div>

      <SectionTitle title="Mantenimiento y adicionales" />
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(210px,1fr))", gap: 12 }}>
        <NumberField
          label="Descuento mantenimiento"
          value={roundMoney(value.maintenance_discount_rate * 100)}
          prefix=""
          suffix="%"
          step="0.5"
          onChange={(percent) => onChange({ ...value, pricing_version: 65, maintenance_discount_rate: Math.max(0, Math.min(1, percent / 100)) })}
        />
        <NumberField
          label="Kit básico opcional"
          value={value.cleaning_kit_price}
          prefix="USD "
          step="0.50"
          onChange={(cleaning_kit_price) => onChange({
            ...value,
            pricing_version: 65,
            cleaning_kit_price: Math.max(0, cleaning_kit_price),
            cleaning_kit_enabled: true,
            mandatory_basic_kit: true,
            kits: {
              ...value.kits,
              enabled: true,
              basic: { ...value.kits.basic, price: Math.max(0, cleaning_kit_price) },
            },
          })}
        />
        <NumberField
          label="Tercer profesional 351–500 m²"
          value={value.third_professional_flat_fee}
          prefix="USD "
          step="0.50"
          onChange={(third_professional_flat_fee) => onChange({ ...value, pricing_version: 65, third_professional_flat_fee: Math.max(0, third_professional_flat_fee) })}
        />
      </div>
    </>
  );
}

function CompanyCleaningEditor({ value, onChange, exterior }: { value: CleaningPricing; onChange: (value: CleaningPricing) => void; exterior: boolean }) {
  if (!exterior) return <ParametricCleaningEditor value={value} onChange={(next) => onChange(companyCleaningWithoutKits(next))} />;
  return <CleaningEditor value={value} onChange={(next) => onChange(companyCleaningWithoutKits(next))} exterior />;
}

function CompanyPlumbingEditor({ value, onChange }: { value: PlumbingPricing; onChange: (value: PlumbingPricing) => void }) {
  return <PlumbingEditor value={value} onChange={(next) => onChange(companyPlumbingWithoutKits(next))} />;
}

function CleaningEditor({ value, onChange, exterior }: { value: CleaningPricing; onChange: (value: CleaningPricing) => void; exterior: boolean }) {
  const gridStyle = { display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(210px,1fr))", gap: 12 } as const;
  if (!exterior) return <ParametricCleaningEditor value={value} onChange={onChange} />;

  const updateServicePrice = (amount: number) => {
    const price = roundMoney(amount);
    onChange({ ...value, pricing_version: 64, fixed_service_price: price, fixed_service_prices: { basica: price, premium: price } });
  };
  return (
    <>
      <div className="notice" style={{ marginBottom: 18 }}>
        Configura el precio y los cargos de la limpieza exterior.
      </div>
      <SectionTitle title="Tarifa del servicio" />
      <div style={gridStyle}>
        <NumberField label="Precio fijo del servicio" value={value.fixed_service_prices.basica} onChange={updateServicePrice} />
      </div>
      <SectionTitle title="Finanzas" />
      <FinancialRulesEditor
        commissionRate={value.platform_commission_rate}
        platformUsageFee={value.platform_usage_fee}
        taxRate={value.itbms_rate}
        mobilityFee={value.mobility_fee_per_booking}
        onCommission={(platform_commission_rate) => onChange({ ...value, pricing_version: 64, platform_commission_rate })}
        onPlatformUsage={(platform_usage_fee) => onChange({ ...value, pricing_version: 64, platform_usage_fee })}
        onTax={(itbms_rate) => onChange({ ...value, pricing_version: 64, itbms_rate })}
        onMobility={(mobility_fee_per_booking) => onChange({ ...value, pricing_version: 64, mobility_fee_per_booking, mobility_fee_per_professional: mobility_fee_per_booking, travel_rate_per_km: 0 })}
      />
      <AdditionalProfessionalFeesEditor
        value={value.additional_professional_fees}
        onChange={(additional_professional_fees) => onChange({ ...value, pricing_version: 64, additional_professional_fees })}
      />
    </>
  );
}

function PricingMatrix({
  plan,
  places,
  value,
  onChange,
}: {
  plan: CleaningPlanKey;
  places: readonly (readonly [string, string])[];
  value: Record<string, ProgressiveSquareMeterRate>;
  onChange: (place: string, key: ProgressiveTierKey, amount: number) => void;
}) {
  return (
    <div style={{ overflowX: "auto", paddingBottom: 4 }}>
      <div style={{ display: "grid", gridTemplateColumns: `minmax(170px,1.1fr) repeat(${cleaningRanges.length},minmax(190px,1fr))`, minWidth: 820, gap: 10, alignItems: "end" }}>
        <div className="label">Tipo</div>
        {cleaningRanges.map((range) => <div className="label" key={range.key}>{range.label}</div>)}
        {places.map(([placeKey, placeLabel]) => (
          <div key={`${plan}-${placeKey}`} style={{ display: "contents" }}>
            <div style={{ minHeight: 58, display: "flex", alignItems: "center", padding: "0 14px", border: "1px solid var(--line)", borderRadius: 8, fontWeight: 800 }}>{placeLabel}</div>
            {cleaningRanges.map((range) => (
              <NumberField
                key={`${plan}-${placeKey}-${range.key}`}
                label={`${placeLabel}, ${range.label}`}
                value={value[placeKey]?.[range.key] ?? 0}
                suffix="/m²"
                onChange={(amount) => onChange(placeKey, range.key, amount)}
              />
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}

function PlumbingEditor({ value, onChange }: { value: PlumbingPricing; onChange: (value: PlumbingPricing) => void }) {
  const gridStyle = { display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(210px,1fr))", gap: 12 } as const;
  return (
    <>
      <div className="notice" style={{ marginBottom: 18 }}>
        El precio incluye el diagnóstico. La reparación se acuerda por separado.
      </div>
      <SectionTitle title="Diagnóstico" />
      <div style={gridStyle}>
        <NumberField label="Precio de inspección y diagnóstico" value={value.inspection_fee} onChange={(inspection_fee) => onChange({ ...value, pricing_version: 64, inspection_fee, job_base: { ...value.job_base, revision: inspection_fee } })} />
      </div>
      <SectionTitle title="Finanzas" />
      <FinancialRulesEditor
        commissionRate={value.platform_commission_rate}
        platformUsageFee={value.platform_usage_fee}
        taxRate={value.itbms_rate}
        mobilityFee={value.mobility_fee_per_booking}
        onCommission={(platform_commission_rate) => onChange({ ...value, pricing_version: 64, platform_commission_rate })}
        onPlatformUsage={(platform_usage_fee) => onChange({ ...value, pricing_version: 64, platform_usage_fee })}
        onTax={(itbms_rate) => onChange({ ...value, pricing_version: 64, itbms_rate })}
        onMobility={(mobility_fee_per_booking) => onChange({ ...value, pricing_version: 64, mobility_fee_per_booking, mobility_fee_per_professional: mobility_fee_per_booking, travel_rate_per_km: 0 })}
      />
      <AdditionalProfessionalFeesEditor
        value={value.additional_professional_fees}
        onChange={(additional_professional_fees) => onChange({ ...value, pricing_version: 64, additional_professional_fees })}
      />
    </>
  );
}

function SectionTitle({ title }: { title: string }) {
  return (
    <div style={{ display: "flex", gap: 9, alignItems: "center", marginTop: 22, marginBottom: 10 }}>
      <div className="brand-icon" style={{ width: 34, height: 34, borderRadius: 13 }}><SlidersHorizontal size={16} /></div>
      <h3 style={{ margin: 0 }}>{title}</h3>
    </div>
  );
}

function NumberField({
  label,
  value,
  onChange,
  prefix = "$",
  suffix,
  disabled = false,
  step = 'any',
}: {
  label: string;
  value: number;
  onChange: (value: number) => void;
  prefix?: string;
  suffix?: string;
  disabled?: boolean;
  step?: number | string;
}) {
  return (
    <label className="field">
      <span className="label">{label}</span>
      <div style={{ display: "flex", minWidth: 0 }}>
        {prefix ? <span className="input-prefix">{prefix}</span> : null}
        <input
          className="input"
          type="number"
          min="0"
          step={step}
          disabled={disabled}
          value={Number.isFinite(value) ? value : 0}
          onChange={(event) => onChange(toNumber(event.target.value, 0))}
          style={{ borderTopLeftRadius: prefix ? 0 : undefined, borderBottomLeftRadius: prefix ? 0 : undefined, borderTopRightRadius: suffix ? 0 : undefined, borderBottomRightRadius: suffix ? 0 : undefined }}
        />
        {suffix ? <span className="input-prefix" style={{ borderLeft: 0, borderRight: "1px solid var(--line)", borderRadius: "0 8px 8px 0" }}>{suffix}</span> : null}
      </div>
    </label>
  );
}

function TextField({ label, value, onChange }: { label: string; value: string; onChange: (value: string) => void }) {
  return (
    <label className="field">
      <span className="label">{label}</span>
      <input className="input" value={value} onChange={(event) => onChange(event.target.value)} />
    </label>
  );
}

function TextAreaField({ label, value, onChange }: { label: string; value: string; onChange: (value: string) => void }) {
  return (
    <label className="field" style={{ marginTop: 12 }}>
      <span className="label">{label}</span>
      <textarea className="input" rows={4} value={value} onChange={(event) => onChange(event.target.value)} style={{ resize: "vertical", minHeight: 92 }} />
    </label>
  );
}

function ToggleField({ label, checked, onChange }: { label: string; checked: boolean; onChange: (value: boolean) => void }) {
  return (
    <label className="field">
      <span className="label">{label}</span>
      <button
        type="button"
        className="input"
        onClick={() => onChange(!checked)}
        style={{ display: "flex", alignItems: "center", justifyContent: "space-between", cursor: "pointer", color: "inherit" }}
      >
        <span>{checked ? "Sí, mostrar en la app" : "No aplica"}</span>
        <CheckCircle2 size={18} style={{ opacity: checked ? 1 : 0.35 }} />
      </button>
    </label>
  );
}
