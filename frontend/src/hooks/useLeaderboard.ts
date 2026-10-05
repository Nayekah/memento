import { useEffect, useState } from "react";
import { fetchLeaderboard } from "../lib/api";
import type { LeaderboardResult } from "../lib/api";
import { computeDeltas, indexByKey, withKeys } from "../lib/board";
import type { Delta } from "../lib/board";
import type { KeyedEntry } from "../lib/types";

export type BoardStatus = "loading" | "ok" | "closed" | "error";

export interface BoardState {
  status: BoardStatus;
  entries: KeyedEntry[];
  updatedAt: Date | null;
  stale: boolean;
  deltas: Map<string, Delta>;
}

const EMPTY: BoardState = { status: "loading", entries: [], updatedAt: null, stale: false, deltas: new Map() };

async function load(endpoint: string, practicumId: string, mock: boolean, signal: AbortSignal): Promise<LeaderboardResult> {
  if (mock && import.meta.env.DEV) {
    const { mockLeaderboard } = await import("../mock/mock");
    return mockLeaderboard(practicumId);
  }
  return fetchLeaderboard(endpoint, signal);
}

/** Polls one practicum's leaderboard, pausing while the tab is hidden and keeping the last good data on errors. */
export function useLeaderboard(endpoint: string, practicumId: string, refreshSeconds: number, mock: boolean): BoardState {
  const [state, setState] = useState<BoardState>(EMPTY);

  useEffect(() => {
    let stopped = false;
    let timer: number | undefined;
    let previous: Map<string, KeyedEntry> | null = null;
    const controller = new AbortController();
    setState(EMPTY);

    const schedule = () => {
      if (!stopped) timer = window.setTimeout(() => void run(), refreshSeconds * 1000);
    };

    const run = async () => {
      if (document.hidden) {
        schedule();
        return;
      }
      try {
        const result = await load(endpoint, practicumId, mock, controller.signal);
        if (stopped) return;
        if (result.status === "closed") {
          previous = null;
          setState({ status: "closed", entries: [], updatedAt: null, stale: false, deltas: new Map() });
        } else {
          const entries = withKeys(result.entries);
          const deltas = computeDeltas(previous, entries);
          previous = indexByKey(entries);
          setState({ status: "ok", entries, updatedAt: new Date(), stale: false, deltas });
        }
      } catch {
        if (stopped) return;
        setState((current) => ({ ...current, status: current.entries.length > 0 ? "ok" : "error", stale: true }));
      }
      schedule();
    };

    const onVisible = () => {
      if (!document.hidden) {
        window.clearTimeout(timer);
        void run();
      }
    };

    document.addEventListener("visibilitychange", onVisible);
    void run();
    return () => {
      stopped = true;
      controller.abort();
      window.clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [endpoint, practicumId, refreshSeconds, mock]);

  return state;
}
