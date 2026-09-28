"use client";

import { useEffect, useMemo, useRef } from "react";
import { supabase } from "@/lib/supabase";

type RealtimeEvent = "*" | "INSERT" | "UPDATE" | "DELETE";

export type RealtimeSource = {
  table: string;
  event?: RealtimeEvent;
  filter?: string;
};

type Options = {
  scope: string;
  sources: RealtimeSource[];
  onRefresh: () => void | Promise<void>;
  debounceMs?: number;
};

/** V66.3: invalida módulos del Admin cuando cambian tablas operativas. */
export function useRealtimeRefresh({ scope, sources, onRefresh, debounceMs = 300 }: Options) {
  const refreshRef = useRef(onRefresh);
  const runningRef = useRef(false);
  const queuedRef = useRef(false);

  useEffect(() => {
    refreshRef.current = onRefresh;
  }, [onRefresh]);

  const sourceKey = useMemo(
    () => sources.map((source) => `${source.table}:${source.event || "*"}:${source.filter || ""}`).join("|"),
    [sources],
  );

  useEffect(() => {
    if (!sources.length) return;

    let disposed = false;
    let timer: number | null = null;
    const safeScope = scope.replace(/[^a-z0-9_-]+/gi, "-").slice(0, 48) || "admin";
    const channel = supabase.channel(`wissa-v663-admin-${safeScope}-${Date.now()}`);

    const schedule = (delay = debounceMs) => {
      if (disposed) return;
      if (timer) window.clearTimeout(timer);
      timer = window.setTimeout(async () => {
        timer = null;
        if (runningRef.current) {
          queuedRef.current = true;
          return;
        }
        runningRef.current = true;
        try {
          await refreshRef.current();
        } catch (error) {
          console.warn(`[Realtime:${safeScope}] refresh failed`, error);
        } finally {
          runningRef.current = false;
          if (queuedRef.current && !disposed) {
            queuedRef.current = false;
            schedule(60);
          }
        }
      }, Math.max(0, delay));
    };

    for (const source of sources) {
      (channel as any).on(
        "postgres_changes",
        {
          event: source.event || "*",
          schema: "public",
          table: source.table,
          ...(source.filter ? { filter: source.filter } : {}),
        },
        () => schedule(),
      );
    }

    channel.subscribe((status) => {
      if (status === "CHANNEL_ERROR") console.warn(`[Realtime:${safeScope}] channel error`);
    });

    const onVisibility = () => {
      if (document.visibilityState === "visible") schedule(80);
    };
    document.addEventListener("visibilitychange", onVisibility);

    return () => {
      disposed = true;
      queuedRef.current = false;
      if (timer) window.clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisibility);
      void supabase.removeChannel(channel);
    };
  }, [debounceMs, scope, sourceKey]);
}
