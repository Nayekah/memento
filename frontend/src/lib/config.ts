import type { Background, Config, Practicum, Track } from "./types";

export const CONFIG_URL = "/config/config.json";

export const DEFAULT_PRACTICUM: Practicum = {
  id: "datalab",
  name: "Data Lab",
  endpoint: "/api/v1/leaderboard",
  scoreLabel: "PTS",
};

export const DEFAULT_CONFIG: Config = {
  title: "Memento Scoreboard",
  motd: "",
  deadline: null,
  pageSize: 20,
  refreshSeconds: 15,
  practicum: DEFAULT_PRACTICUM,
  practicums: [DEFAULT_PRACTICUM],
  backgrounds: [],
  music: [],
};

const PRACTICUM_ID = /^[a-z0-9][a-z0-9-]{0,31}$/;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const text = (value: unknown, max: number): string | undefined =>
  typeof value === "string" && value.trim() !== "" ? value.trim().slice(0, max) : undefined;

const clamp = (value: unknown, low: number, high: number, fallback: number): number =>
  typeof value === "number" && Number.isFinite(value)
    ? Math.min(high, Math.max(low, Math.round(value)))
    : fallback;

export function parseDeadline(value: unknown): string | null {
  const raw = text(value, 64);
  return raw !== undefined && !Number.isNaN(Date.parse(raw)) ? raw : null;
}

/**
 * Media paths are relative to /config/ or absolute on this origin. Anything
 * with a scheme or a protocol-relative prefix is refused so the page never
 * contacts a third-party host from the exam network.
 */
export function resolveAsset(value: unknown): string | null {
  const src = text(value, 300);
  if (src === undefined) return null;
  if (src.startsWith("//") || /^[a-z][a-z0-9+.-]*:/i.test(src) || src.includes("..")) return null;
  return src.startsWith("/") ? src : `/config/${src}`;
}

function parsePracticums(value: unknown): Practicum[] {
  const seen = new Set<string>();
  const result: Practicum[] = [];
  if (Array.isArray(value)) {
    for (const item of value) {
      if (!isRecord(item)) continue;
      const id = text(item.id, 32);
      const endpoint = text(item.endpoint, 200);
      if (!id || !PRACTICUM_ID.test(id) || seen.has(id)) continue;
      if (endpoint === undefined || !endpoint.startsWith("/") || resolveAsset(endpoint) === null) continue;
      seen.add(id);
      result.push({ id, name: text(item.name, 60) ?? id, endpoint, scoreLabel: text(item.scoreLabel, 8) ?? "PTS" });
    }
  }
  return result.length > 0 ? result : [DEFAULT_PRACTICUM];
}

function parseBackgrounds(value: unknown): Background[] {
  if (!Array.isArray(value)) return [];
  const result: Background[] = [];
  for (const item of value) {
    if (!isRecord(item)) continue;
    const src = resolveAsset(item.src);
    if (src === null) continue;
    result.push({ src, pos: text(item.pos, 40) ?? "50% 50%", credit: text(item.credit, 120) ?? "" });
  }
  return result;
}

function parseMusic(value: unknown): Track[] {
  if (!Array.isArray(value)) return [];
  const result: Track[] = [];
  for (const item of value) {
    if (!isRecord(item)) continue;
    const src = resolveAsset(item.src);
    const title = text(item.title, 120);
    if (src === null || !title) continue;
    result.push({ src, title, artist: text(item.artist, 120) ?? "" });
  }
  return result;
}

export function parseConfig(raw: unknown): Config {
  const source = isRecord(raw) ? raw : {};
  const practicums = parsePracticums(source.practicums);
  const wanted = text(source.practicum, 32);
  return {
    title: text(source.title, 120) ?? DEFAULT_CONFIG.title,
    motd: text(source.motd, 300) ?? "",
    deadline: parseDeadline(source.deadline),
    pageSize: clamp(source.pageSize, 5, 100, DEFAULT_CONFIG.pageSize),
    refreshSeconds: clamp(source.refreshSeconds, 5, 300, DEFAULT_CONFIG.refreshSeconds),
    practicum: practicums.find((p) => p.id === wanted) ?? practicums[0]!,
    practicums,
    backgrounds: parseBackgrounds(source.backgrounds),
    music: parseMusic(source.music),
  };
}

export async function loadConfig(fetcher: typeof fetch = fetch): Promise<Config> {
  const response = await fetcher(CONFIG_URL, { cache: "no-store" });
  if (!response.ok) throw new Error(`config.json returned ${response.status}`);
  return parseConfig(await response.json());
}
