import { describe, expect, it } from "vitest";
import { clampIndex, nextIndex, previousIndex, randomIndex } from "./playlist";

describe("playlist", () => {
  it("wraps in order", () => {
    expect(nextIndex(2, 3, false)).toBe(0);
    expect(previousIndex(0, 3, false)).toBe(2);
    expect(nextIndex(0, 3, false)).toBe(1);
  });
  it("handles zero and one track", () => {
    expect(nextIndex(0, 0, false)).toBe(0);
    expect(nextIndex(0, 1, true)).toBe(0);
    expect(previousIndex(0, 1, false)).toBe(0);
  });
  it("shuffle never repeats the current track for any random value", () => {
    for (const length of [2, 3, 5, 10]) {
      for (let current = 0; current < length; current++) {
        for (const random of [0, 0.25, 0.5, 0.999999]) {
          const pick = nextIndex(current, length, true, () => random);
          expect(pick).not.toBe(current);
          expect(pick).toBeGreaterThanOrEqual(0);
          expect(pick).toBeLessThan(length);
        }
      }
    }
  });
  it("covers every other track when shuffling", () => {
    const seen = new Set<number>();
    for (let i = 0; i < 100; i++) seen.add(nextIndex(1, 4, true, () => i / 100));
    expect([...seen].sort()).toEqual([0, 2, 3]);
  });
  it("clamps stored indexes", () => {
    expect(clampIndex(7, 3)).toBe(2);
    expect(clampIndex(-1, 3)).toBe(0);
    expect(clampIndex(Number.NaN, 3)).toBe(0);
    expect(clampIndex(1, 0)).toBe(0);
  });
  it("picks a random index within bounds, including both ends", () => {
    expect(randomIndex(8, () => 0)).toBe(0);
    expect(randomIndex(8, () => 0.999999)).toBe(7);
    expect(randomIndex(8, () => 0.5)).toBe(4);
    expect(randomIndex(0, () => 0.5)).toBe(0);
    expect(randomIndex(1, () => 0.9)).toBe(0);
  });
  it("can reach every index", () => {
    const seen = new Set<number>();
    for (let i = 0; i < 18; i++) seen.add(randomIndex(18, () => i / 18));
    expect(seen.size).toBe(18);
  });
});
