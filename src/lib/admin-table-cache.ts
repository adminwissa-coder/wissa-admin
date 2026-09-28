export type AdminTableCacheEnvelope<T> = {
  value: T;
  storedAt: number;
  expiresAt: number;
};

const PREFIX = 'wissa:admin-table:v66.6:';
const FRESH_MS = 2 * 60 * 1000;
const STALE_MAX_MS = 15 * 60 * 1000;

export function adminTableCacheKey(parts: Array<string | number | null | undefined>) {
  return PREFIX + parts.map((part) => String(part ?? '')).join('|');
}

export function readAdminTableCache<T>(key: string): { value: T; isFresh: boolean } | null {
  if (typeof window === 'undefined') return null;
  try {
    const raw = window.sessionStorage.getItem(key);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as AdminTableCacheEnvelope<T>;
    if (!parsed || typeof parsed.storedAt !== 'number') return null;
    const now = Date.now();
    if (now - parsed.storedAt > STALE_MAX_MS) {
      window.sessionStorage.removeItem(key);
      return null;
    }
    return { value: parsed.value, isFresh: parsed.expiresAt > now };
  } catch {
    return null;
  }
}

export function writeAdminTableCache<T>(key: string, value: T) {
  if (typeof window === 'undefined') return;
  try {
    const now = Date.now();
    const payload: AdminTableCacheEnvelope<T> = {
      value,
      storedAt: now,
      expiresAt: now + FRESH_MS,
    };
    window.sessionStorage.setItem(key, JSON.stringify(payload));
  } catch {
    // La caché es una mejora de experiencia; nunca debe bloquear la operación.
  }
}
