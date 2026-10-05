import type { Entry, KeyedEntry } from "./types";

export interface Page {
  rows: KeyedEntry[];
  total: number;
  matched: number;
  remaining: number;
}

export interface Delta {
  rank: number;
  scoreChanged: boolean;
}

/** Display names are not guaranteed unique, so the key adds an occurrence counter. */
export function withKeys(entries: readonly Entry[]): KeyedEntry[] {
  const seen = new Map<string, number>();
  return entries.map((entry) => {
    const lower = entry.name.toLowerCase();
    const count = seen.get(lower) ?? 0;
    seen.set(lower, count + 1);
    return { ...entry, key: `${lower}#${count}` };
  });
}

export function search(entries: readonly KeyedEntry[], query: string): KeyedEntry[] {
  const needle = query.trim().toLowerCase();
  return needle === "" ? [...entries] : entries.filter((entry) => entry.name.toLowerCase().includes(needle));
}

export function page(entries: readonly KeyedEntry[], query: string, limit: number): Page {
  const matched = search(entries, query);
  const rows = matched.slice(0, Math.max(0, limit));
  return { rows, total: entries.length, matched: matched.length, remaining: matched.length - rows.length };
}

export function findMe(entries: readonly KeyedEntry[], name: string): KeyedEntry | undefined {
  const needle = name.trim().toLowerCase();
  return needle === "" ? undefined : entries.find((entry) => entry.name.toLowerCase() === needle);
}

export function indexByKey(entries: readonly KeyedEntry[]): Map<string, KeyedEntry> {
  return new Map(entries.map((entry) => [entry.key, entry]));
}

/** A positive rank delta means the student moved up. Entries absent from the previous poll have no delta. */
export function computeDeltas(
  previous: ReadonlyMap<string, KeyedEntry> | null,
  next: readonly KeyedEntry[],
): Map<string, Delta> {
  const deltas = new Map<string, Delta>();
  if (previous === null) return deltas;
  for (const entry of next) {
    const before = previous.get(entry.key);
    if (before === undefined) continue;
    const rank = before.rank - entry.rank;
    const scoreChanged = before.score !== entry.score;
    if (rank !== 0 || scoreChanged) deltas.set(entry.key, { rank, scoreChanged });
  }
  return deltas;
}

export function growLimit(limit: number, total: number, pageSize: number): number {
  return Math.min(total, limit + pageSize);
}
