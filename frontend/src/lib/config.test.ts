import { describe, expect, it } from "vitest";
import { DEFAULT_CONFIG, DEFAULT_PRACTICUM, parseConfig, resolveAsset } from "./config";

describe("resolveAsset", () => {
  it("resolves relative paths under /config/", () => {
    expect(resolveAsset("music/a.mp3")).toBe("/config/music/a.mp3");
  });
  it("keeps same-origin absolute paths", () => {
    expect(resolveAsset("/config/bg/x.webp")).toBe("/config/bg/x.webp");
  });
  it.each(["https://evil.example/a.mp3", "//evil.example/a.mp3", "data:audio/mp3;base64,AAAA", "../secret", "music/../../x", "", "  ", 42, null])(
    "refuses %s",
    (value) => {
      expect(resolveAsset(value)).toBeNull();
    },
  );
});

describe("parseConfig", () => {
  it("falls back to defaults for junk input", () => {
    expect(parseConfig(null)).toEqual(DEFAULT_CONFIG);
    expect(parseConfig("nope")).toEqual(DEFAULT_CONFIG);
    expect(parseConfig([])).toEqual(DEFAULT_CONFIG);
  });

  it("ignores an unparseable deadline", () => {
    expect(parseConfig({ deadline: "soon" }).deadline).toBeNull();
    expect(parseConfig({ deadline: "2026-10-16T13:00:00+07:00" }).deadline).toBe("2026-10-16T13:00:00+07:00");
  });

  it("clamps page size and refresh interval", () => {
    const config = parseConfig({ pageSize: 9999, refreshSeconds: 1 });
    expect(config.pageSize).toBe(100);
    expect(config.refreshSeconds).toBe(5);
  });

  it("keeps only valid, unique practicums and falls back to the default when none are valid", () => {
    const config = parseConfig({
      practicums: [
        { id: "datalab", name: "Data Lab", endpoint: "/api/v1/leaderboard", scoreLabel: "pts" },
        { id: "datalab", name: "Duplicate", endpoint: "/api/v1/other" },
        { id: "Bad Id", name: "Bad", endpoint: "/api/x" },
        { id: "remote", name: "Remote", endpoint: "https://evil.example/leaderboard" },
        { id: "bomblab", endpoint: "/api/v1/bomb/leaderboard" },
      ],
    });
    expect(config.practicums.map((p) => p.id)).toEqual(["datalab", "bomblab"]);
    expect(config.practicums[1]).toEqual({ id: "bomblab", name: "bomblab", endpoint: "/api/v1/bomb/leaderboard", scoreLabel: "PTS" });
    expect(parseConfig({ practicums: [{ id: "x" }] }).practicums).toEqual([DEFAULT_PRACTICUM]);
  });

  it("drops media entries that point off-origin or lack a title", () => {
    const config = parseConfig({
      backgrounds: [{ src: "backgrounds/a.webp", pos: "10% 20%", credit: "Someone" }, { src: "https://x.example/a.webp" }, "bad"],
      music: [{ title: "Song", artist: "Band", src: "music/s.mp3" }, { title: "No source" }, { src: "music/x.mp3" }],
    });
    expect(config.backgrounds).toEqual([{ src: "/config/backgrounds/a.webp", pos: "10% 20%", credit: "Someone" }]);
    expect(config.music).toEqual([{ title: "Song", artist: "Band", src: "/config/music/s.mp3" }]);
  });
});

describe("active practicum", () => {
  const practicums = [
    { id: "datalab", name: "Praktikum 1", endpoint: "/api/v1/leaderboard" },
    { id: "bomblab", name: "Praktikum 2", endpoint: "/api/v1/practicums/bomblab/leaderboard" },
  ];
  it("shows only the practicum named by the practicum field", () => {
    expect(parseConfig({ practicum: "bomblab", practicums }).practicum.endpoint).toBe("/api/v1/practicums/bomblab/leaderboard");
    expect(parseConfig({ practicum: "datalab", practicums }).practicum.id).toBe("datalab");
  });
  it("falls back to the first practicum when the field is missing or unknown", () => {
    expect(parseConfig({ practicums }).practicum.id).toBe("datalab");
    expect(parseConfig({ practicum: "nope", practicums }).practicum.id).toBe("datalab");
  });
  it("uses the default leaderboard when nothing is configured", () => {
    expect(parseConfig({}).practicum).toEqual(DEFAULT_PRACTICUM);
  });
});
