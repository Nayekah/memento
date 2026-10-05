import { useEffect, useState } from "react";
import { DEFAULT_CONFIG, loadConfig } from "../lib/config";
import type { Config } from "../lib/types";

const RELOAD_MS = 60_000;

export interface ConfigState {
  config: Config;
  loaded: boolean;
  failed: boolean;
}

/** Reads /config/config.json now and every minute so organizers can edit it live. */
export function useConfig(): ConfigState {
  const [state, setState] = useState<ConfigState>({ config: DEFAULT_CONFIG, loaded: false, failed: false });

  useEffect(() => {
    let stopped = false;
    const load = async () => {
      try {
        const next = await loadConfig();
        if (stopped) return;
        setState((current) =>
          current.loaded && JSON.stringify(current.config) === JSON.stringify(next)
            ? current.failed ? { ...current, failed: false } : current
            : { config: next, loaded: true, failed: false },
        );
      } catch {
        if (!stopped) setState((current) => ({ ...current, loaded: true, failed: true }));
      }
    };
    void load();
    const timer = window.setInterval(() => void load(), RELOAD_MS);
    return () => {
      stopped = true;
      window.clearInterval(timer);
    };
  }, []);

  return state;
}
