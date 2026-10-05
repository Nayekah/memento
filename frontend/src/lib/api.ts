import type { Entry } from "./types";

export type LeaderboardResult = { status: "ok"; entries: Entry[] } | { status: "closed" };

export class ApiError extends Error {}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const isInt = (value: unknown): value is number => typeof value === "number" && Number.isInteger(value);

/** Keeps well-formed entries and drops the rest; throws if the payload has no entries array. */
export function normalizeLeaderboard(payload: unknown): Entry[] {
  if (!isRecord(payload) || !Array.isArray(payload.entries)) {
    throw new ApiError("leaderboard payload has no entries array");
  }
  const entries: Entry[] = [];
  for (const item of payload.entries) {
    if (!isRecord(item)) continue;
    const { rank, name, score, max_score: maxScore } = item;
    if (!isInt(rank) || rank < 1) continue;
    if (typeof name !== "string" || name.trim() === "" || name.length > 120) continue;
    if (!isInt(score) || !isInt(maxScore) || score < 0 || maxScore < 1 || score > maxScore) continue;
    entries.push({ rank, name: name.trim(), score, max_score: maxScore });
  }
  return entries.sort((a, b) => a.rank - b.rank || a.name.localeCompare(b.name));
}

/** 404 and 501 mean the practicum has no leaderboard yet, which is not an error to show students. */
export async function fetchLeaderboard(
  endpoint: string,
  signal?: AbortSignal,
  fetcher: typeof fetch = fetch,
): Promise<LeaderboardResult> {
  const response = await fetcher(endpoint, { cache: "no-store", signal, headers: { Accept: "application/json" } });
  if (response.status === 404 || response.status === 501) return { status: "closed" };
  if (!response.ok) throw new ApiError(`leaderboard returned ${response.status}`);
  return { status: "ok", entries: normalizeLeaderboard(await response.json()) };
}
