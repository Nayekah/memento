import { describe, expect, it } from "vitest";
import { challengeState, computeDeltas, countSolved, findMe, growLimit, indexByKey, page, search, withKeys } from "./board";
import type { Entry } from "./types";

const make = (n: number): Entry[] => Array.from({ length: n }, (_, i) => ({ rank: i + 1, name: `student_${String(i + 1).padStart(3, "0")}`, score: 100 - (i % 100), max_score: 100 }));

describe("challengeState and countSolved", () => {
  it("tells solved, partial, and empty challenges apart", () => {
    expect(challengeState({ name: "a", points: 3, max: 3 })).toBe("solved");
    expect(challengeState({ name: "a", points: 2, max: 4 })).toBe("partial");
    expect(challengeState({ name: "a", points: 0, max: 4 })).toBe("empty");
  });
  it("counts only the challenges that are fully solved", () => {
    const challenges = [
      { name: "a", points: 3, max: 3 },
      { name: "b", points: 2, max: 4 },
      { name: "c", points: 0, max: 3 },
      { name: "d", points: 6, max: 6 },
    ];
    expect(countSolved(challenges)).toBe(2);
    expect(countSolved([])).toBe(0);
  });
  it("keeps the challenges when entries get keys", () => {
    const challenges = [{ name: "a", points: 1, max: 2 }];
    const [keyed] = withKeys([{ rank: 1, name: "Sam", score: 1, max_score: 2, challenges }]);
    expect(keyed.challenges).toEqual(challenges);
  });
});

describe("withKeys", () => {
  it("gives duplicate display names distinct keys", () => {
    const keyed = withKeys([{ rank: 1, name: "Sam", score: 9, max_score: 10 }, { rank: 2, name: "sam", score: 8, max_score: 10 }]);
    expect(new Set(keyed.map((e) => e.key)).size).toBe(2);
  });
});

describe("page and search with 130 students", () => {
  const all = withKeys(make(130));
  it("shows only the first page and reports what is hidden", () => {
    const result = page(all, "", 20);
    expect(result.rows).toHaveLength(20);
    expect(result).toMatchObject({ total: 130, matched: 130, remaining: 110 });
  });
  it("searches every student, including those beyond the visible page", () => {
    const result = page(all, "student_129", 20);
    expect(result.rows.map((e) => e.name)).toEqual(["student_129"]);
    expect(result.remaining).toBe(0);
  });
  it("is case-insensitive and trims the query", () => {
    expect(search(all, "  STUDENT_007 ")).toHaveLength(1);
  });
  it("shows everything once the limit reaches the total", () => {
    expect(page(all, "", 130).remaining).toBe(0);
  });
  it("grows by one page and never past the total", () => {
    expect(growLimit(20, 130, 20)).toBe(40);
    expect(growLimit(120, 130, 20)).toBe(130);
  });
});

describe("findMe", () => {
  const all = withKeys(make(130));
  it("matches the exact name regardless of case", () => {
    expect(findMe(all, "STUDENT_128")?.rank).toBe(128);
  });
  it("does not match partial names or an empty name", () => {
    expect(findMe(all, "student_12")).toBeUndefined();
    expect(findMe(all, "  ")).toBeUndefined();
  });
});

describe("computeDeltas", () => {
  const before = withKeys([{ rank: 1, name: "a", score: 90, max_score: 100 }, { rank: 2, name: "b", score: 80, max_score: 100 }, { rank: 3, name: "c", score: 70, max_score: 100 }]);
  it("returns nothing on the first poll", () => {
    expect(computeDeltas(null, before).size).toBe(0);
  });
  it("reports moves up and down and score changes, and ignores new entrants", () => {
    const after = withKeys([{ rank: 1, name: "b", score: 95, max_score: 100 }, { rank: 2, name: "a", score: 90, max_score: 100 }, { rank: 3, name: "c", score: 70, max_score: 100 }, { rank: 4, name: "d", score: 10, max_score: 100 }]);
    const deltas = computeDeltas(indexByKey(before), after);
    expect(deltas.get("b#0")).toEqual({ rank: 1, scoreChanged: true });
    expect(deltas.get("a#0")).toEqual({ rank: -1, scoreChanged: false });
    expect(deltas.has("c#0")).toBe(false);
    expect(deltas.has("d#0")).toBe(false);
  });
});
