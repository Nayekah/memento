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

describe("normalizeLeaderboard challenges", () => {
  const results = [
    { name: "bitAnd", points: 3, max: 3 },
    { name: "negate", points: 2, max: 4 },
    { name: "tmin", points: 0, max: 3 },
  ];

  it("keeps the challenge results of an entry", () => {
    const [out] = normalizeLeaderboard({ entries: [{ ...entry(1, "a"), challenges: results }] });
    expect(out.challenges).toEqual(results);
  });
  it("leaves the key out when the backend sends none", () => {
    const [out] = normalizeLeaderboard({ entries: [entry(1, "a")] });
    expect("challenges" in out).toBe(false);
  });
  it.each([
    ["an empty list", []],
    ["not a list", "bitAnd"],
    ["a null value", null],
    ["an item that is not an object", [results[0], 7]],
    ["a missing name", [{ points: 1, max: 2 }]],
    ["a blank name", [{ name: " ", points: 1, max: 2 }]],
    ["a fractional point", [{ name: "x", points: 1.5, max: 2 }]],
    ["points above the maximum", [{ name: "x", points: 3, max: 2 }]],
    ["negative points", [{ name: "x", points: -1, max: 2 }]],
    ["a maximum of zero", [{ name: "x", points: 0, max: 0 }]],
    ["one bad item among good ones", [results[0], { name: "x", points: "1", max: 2 }]],
    ["more challenges than any problem set", Array.from({ length: 65 }, (_, i) => ({ name: `c${i}`, points: 0, max: 1 }))],
  ])("drops %s but keeps the entry", (_label, challenges) => {
    const [out] = normalizeLeaderboard({ entries: [{ ...entry(1, "a"), challenges }] });
    expect(out).toEqual(entry(1, "a"));
    expect("challenges" in out).toBe(false);
  });
});
