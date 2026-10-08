import { beforeEach, describe, expect, it, vi } from "vitest";

let mock: typeof import("./mock");

// The mock keeps its boards between calls and simulates progress on later
// calls, so each test loads it afresh and sees the board its seed produces.
beforeEach(async () => {
  vi.resetModules();
  mock = await import("./mock");
});

async function board(id: string) {
  const result = await mock.mockLeaderboard(id);
  if (result.status !== "ok") throw new Error(`expected a board for ${id}`);
  return result.entries;
}

describe("mockLeaderboard", () => {
  it("gives every student challenge results that add up to the score", async () => {
    const entries = await board("datalab");
    expect(entries).toHaveLength(130);
    for (const entry of entries) {
      const challenges = entry.challenges ?? [];
      expect(challenges).toHaveLength(7);
      expect(challenges.reduce((sum, challenge) => sum + challenge.points, 0)).toBe(entry.score);
      expect(challenges.reduce((sum, challenge) => sum + challenge.max, 0)).toBe(entry.max_score);
    }
  });

  it("has five challenges in the second practicum", async () => {
    const entries = await board("bomblab");
    expect(entries.every((entry) => entry.challenges?.length === 5)).toBe(true);
  });

  it("shows solved, partly earned, and untouched challenges", async () => {
    const states = new Set((await board("datalab")).flatMap((entry) => entry.challenges ?? []).map((c) => (c.points === 0 ? "empty" : c.points === c.max ? "solved" : "partial")));
    expect([...states].sort()).toEqual(["empty", "partial", "solved"]);
  });

  it("keeps the board in rank order with ties sharing a rank", async () => {
    const entries = await board("datalab");
    for (let i = 1; i < entries.length; i++) {
      expect(entries[i].score).toBeLessThanOrEqual(entries[i - 1].score);
      expect(entries[i].rank === entries[i - 1].rank).toBe(entries[i].score === entries[i - 1].score);
    }
  });

  it("moves students forward on later calls without ever lowering a score", async () => {
    const first = new Map((await board("datalab")).map((entry) => [entry.name, entry.score]));
    const later = await board("datalab");
    for (const entry of later) expect(entry.score).toBeGreaterThanOrEqual(first.get(entry.name) ?? Infinity);
  });

  it("has no board for an unknown practicum", async () => {
    expect(await mock.mockLeaderboard("nope")).toEqual({ status: "closed" });
  });
});
