import type { Challenge, Entry } from "./types";

export type LeaderboardResult = { status: "ok"; entries: Entry[] } | { status: "closed" };

export class ApiError extends Error {}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const isInt = (value: unknown): value is number => typeof value === "number" && Number.isInteger(value);

const MAX_CHALLENGES = 64;

/**
 * Reads an entry's challenge results. One malformed item makes the whole list
 * unusable, because drawing part of it would misreport the student's progress.
 */
function normalizeChallenges(value: unknown): Challenge[] | undefined {
  if (!Array.isArray(value) || value.length === 0 || value.length > MAX_CHALLENGES) return undefined;
  const challenges: Challenge[] = [];
  for (const item of value) {
    if (!isRecord(item)) return undefined;
    const { name, points, max } = item;
    if (typeof name !== "string" || name.trim() === "" || name.length > 64) return undefined;
    if (!isInt(points) || !isInt(max) || max < 1 || points < 0 || points > max) return undefined;
    challenges.push({ name: name.trim(), points, max });
  }
  return challenges;
}

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
    const challenges = normalizeChallenges(item.challenges);
    const entry: Entry = { rank, name: name.trim(), score, max_score: maxScore };
    if (challenges !== undefined) entry.challenges = challenges;
    entries.push(entry);
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
