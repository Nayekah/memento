import { describe, expect, it } from "vitest";
import { ApiError, fetchLeaderboard, normalizeLeaderboard } from "./api";

const entry = (rank: number, name: string, score = 50, max = 100) => ({ rank, name, score, max_score: max });
const reply = (status: number, body: unknown): typeof fetch => async () => new Response(JSON.stringify(body), { status });

describe("normalizeLeaderboard", () => {
  it("sorts by rank then name and keeps ties", () => {
    const out = normalizeLeaderboard({ entries: [entry(2, "b"), entry(1, "z"), entry(1, "a")] });
    expect(out.map((e) => e.name)).toEqual(["a", "z", "b"]);
  });
  it("drops malformed entries instead of failing the whole board", () => {
    const out = normalizeLeaderboard({
      entries: [entry(1, "ok"), entry(0, "zero rank"), entry(2, ""), entry(3, "over", 101), entry(4, "neg", -1), entry(5, "nomax", 5, 0), { rank: "1", name: "str" }, null, entry(6, "x".repeat(121))],
    });
    expect(out.map((e) => e.name)).toEqual(["ok"]);
  });
  it("throws when the payload has no entries array", () => {
    expect(() => normalizeLeaderboard({})).toThrow(ApiError);
    expect(() => normalizeLeaderboard(null)).toThrow(ApiError);
    expect(() => normalizeLeaderboard({ entries: "x" })).toThrow(ApiError);
  });
});

describe("fetchLeaderboard", () => {
  it("returns entries on 200", async () => {
    const result = await fetchLeaderboard("/x", undefined, reply(200, { entries: [entry(1, "a")] }));
    expect(result).toEqual({ status: "ok", entries: [entry(1, "a")] });
  });
  it("treats 404 and 501 as a practicum that is not open yet", async () => {
    expect(await fetchLeaderboard("/x", undefined, reply(404, {}))).toEqual({ status: "closed" });
    expect(await fetchLeaderboard("/x", undefined, reply(501, {}))).toEqual({ status: "closed" });
  });
  it("throws on server errors", async () => {
    await expect(fetchLeaderboard("/x", undefined, reply(500, {}))).rejects.toThrow(ApiError);
  });
});
