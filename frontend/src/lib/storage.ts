export function readStored(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

export function writeStored(key: string, value: string): void {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* storage can be blocked; preferences just will not persist */
  }
}

export function readNumber(key: string, fallback: number): number {
  const raw = readStored(key);
  const value = raw === null ? Number.NaN : Number(raw);
  return Number.isFinite(value) ? value : fallback;
}

export const KEYS = {
  me: "memento.me",
  background: "memento.bg",
  track: "memento.track",
  volume: "memento.vol",
  shuffle: "memento.shuffle",
  playerMini: "memento.playerMini",
} as const;
