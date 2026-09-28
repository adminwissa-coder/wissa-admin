import { supabase } from "@/lib/supabase";

export type AdminJsonRow = Record<string, unknown>;

export async function adminRpc<T = unknown>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args ?? {});
  if (error) throw new Error(error.message);
  return data as T;
}

export async function listAdminData(moduleName: string, filters?: Record<string, unknown>) {
  return adminRpc<AdminJsonRow[]>("yt_admin_web_list", {
    p_module: moduleName,
    p_filters: filters ?? {},
  });
}

export async function getAdminStats() {
  return adminRpc<Record<string, unknown>>("yt_admin_web_stats", {});
}

export async function runAdminAction(action: string, payload?: Record<string, unknown>) {
  return adminRpc<Record<string, unknown>>("yt_admin_web_action", {
    p_action: action,
    p_payload: payload ?? {},
  });
}
