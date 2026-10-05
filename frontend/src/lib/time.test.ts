import { describe, expect, it } from "vitest";
import { countdown, formatClock } from "./time";

const NOW = Date.parse("2026-10-16T00:00:00Z");
const at = (seconds: number) => new Date(NOW + seconds * 1000).toISOString();

describe("countdown", () => {
  it("is 'none' without a usable deadline", () => {
    expect(countdown(null, NOW).state).toBe("none");
    expect(countdown("not a date", NOW).state).toBe("none");
  });
  it("splits days, hours, minutes and seconds", () => {
    const value = countdown(at(2 * 86400 + 3 * 3600 + 4 * 60 + 5), NOW);
    expect(value).toMatchObject({ days: 2, hours: 3, minutes: 4, seconds: 5, state: "normal" });
    expect(formatClock(value)).toBe("03:04:05");
  });
  it.each([
    [601, "normal"],
    [600, "normal"],
    [599, "warn"],
    [60, "warn"],
    [59, "crit"],
    [1, "crit"],
    [0, "over"],
    [-30, "over"],
  ])("%i seconds left is %s", (seconds, state) => {
    expect(countdown(at(seconds), NOW).state).toBe(state);
  });
  it("never goes negative after the deadline", () => {
    expect(countdown(at(-500), NOW)).toMatchObject({ totalSeconds: 0, hours: 0, minutes: 0, seconds: 0 });
  });
});
