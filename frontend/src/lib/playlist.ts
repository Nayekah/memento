export function clampIndex(index: number, length: number): number {
  if (length <= 0 || !Number.isFinite(index)) return 0;
  return Math.min(length - 1, Math.max(0, Math.trunc(index)));
}

/** In shuffle mode the result is never the current track (when there is more than one). */
export function nextIndex(current: number, length: number, shuffle: boolean, random: () => number = Math.random): number {
  if (length <= 1) return 0;
  if (shuffle) {
    const pick = Math.min(length - 2, Math.floor(random() * (length - 1)));
    return pick >= current ? pick + 1 : pick;
  }
  return (current + 1) % length;
}

export function previousIndex(current: number, length: number, shuffle: boolean, random: () => number = Math.random): number {
  if (length <= 1) return 0;
  return shuffle ? nextIndex(current, length, true, random) : (current - 1 + length) % length;
}

/** A uniformly random index, used to pick the background and starting track on each page load. */
export function randomIndex(length: number, random: () => number = Math.random): number {
  return length <= 0 ? 0 : Math.min(length - 1, Math.floor(random() * length));
}
