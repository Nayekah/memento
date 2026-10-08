import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { useState } from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { BoardState } from "../hooks/useLeaderboard";
import { findMe, withKeys } from "../lib/board";
import { Board } from "./Board";

beforeAll(() => {
  Element.prototype.scrollIntoView = vi.fn();
});
afterEach(cleanup);

const entries = withKeys(
  Array.from({ length: 130 }, (_, i) => ({ rank: i + 1, name: `student_${String(i + 1).padStart(3, "0")}`, score: 130 - i, max_score: 130 })),
);
const ok: BoardState = { status: "ok", entries, updatedAt: new Date(), stale: false, deltas: new Map() };

function Harness({ board = ok, initialMe = "" }: { board?: BoardState; initialMe?: string }) {
  const [query, setQuery] = useState("");
  const [meName, setMeName] = useState(initialMe);
  const me = findMe(board.entries, meName);
  return (
    <Board
      board={board}
      query={query}
      onQuery={setQuery}
      me={me}
      onForgetMe={() => setMeName("")}
      onTogglePin={(entry) => setMeName(me?.key === entry.key ? "" : entry.name)}
      pageSize={20}
      scoreLabel="PTS"
    />
  );
}

const bodyRows = () => document.querySelectorAll("tbody tr").length;

describe("Board with 130 students", () => {
  it("shows the first page, then more, then everything, then collapses", () => {
    render(<Harness />);
    expect(bodyRows()).toBe(20);
    expect(screen.getByText("SHOWING 20 OF 130")).toBeTruthy();
    fireEvent.click(screen.getByText("VIEW MORE"));
    expect(bodyRows()).toBe(40);
    fireEvent.click(screen.getByText("SHOW ALL"));
    expect(bodyRows()).toBe(130);
    expect(screen.getByText("ALL 130 PLAYERS")).toBeTruthy();
    fireEvent.click(screen.getByText("SHOW LESS"));
    expect(bodyRows()).toBe(20);
  });

  it("finds a student who is not on the visible page", () => {
    render(<Harness />);
    fireEvent.change(screen.getByLabelText("Find a name"), { target: { value: "student_127" } });
    expect(bodyRows()).toBe(1);
    expect(screen.getByText("student_127")).toBeTruthy();
    expect(screen.getByText("1 OF 1 MATCHES")).toBeTruthy();
  });

  it("says so when nobody matches", () => {
    render(<Harness />);
    fireEvent.change(screen.getByLabelText("Find a name"), { target: { value: "nobody" } });
    expect(screen.getByText("NO PLAYER FOUND")).toBeTruthy();
  });

  it("pins the YOU strip and expands the list to reach the student's row", () => {
    render(<Harness initialMe="student_099" />);
    expect(screen.getByText("YOU")).toBeTruthy();
    expect(bodyRows()).toBe(20);
    act(() => {
      fireEvent.click(screen.getByTitle("Jump to your row"));
    });
    expect(bodyRows()).toBe(99);
    expect(document.querySelector("tr.me")?.getAttribute("data-key")).toBe("student_099#0");
  });

  it("shows ties with the same rank and a top-3 star", () => {
    const tied = withKeys([
      { rank: 1, name: "a", score: 10, max_score: 10 },
      { rank: 1, name: "b", score: 10, max_score: 10 },
      { rank: 3, name: "c", score: 5, max_score: 10 },
    ]);
    render(<Harness board={{ ...ok, entries: tied }} />);
    const ranks = [...document.querySelectorAll("td.r")].map((cell) => cell.textContent);
    expect(ranks).toEqual(["01", "01", "03"]);
    expect(document.querySelectorAll(".star").length).toBe(3);
  });

  it.each([
    [{ ...ok, status: "loading", entries: [] }, "LOADING SCORES"],
    [{ ...ok, status: "closed", entries: [] }, "THIS PRACTICUM HAS NO SCOREBOARD YET"],
    [{ ...ok, status: "error", entries: [] }, "SCOREBOARD UNREACHABLE. RETRYING."],
    [{ ...ok, entries: [] }, "NO SCORES YET. BE THE FIRST."],
  ] as [BoardState, string][])("renders the %#th status message", (board, message) => {
    render(<Harness board={board} />);
    expect(screen.getByText(message)).toBeTruthy();
  });
  it("pins a student with the row's pin button and unpins with a second click", () => {
    render(<Harness />);
    expect(screen.queryByText("YOU")).toBeNull();
    const pin = screen.getByRole("button", { name: "Pin student_005 as you" });
    expect(pin.getAttribute("aria-pressed")).toBe("false");
    fireEvent.click(pin);
    expect(screen.getByText("YOU")).toBeTruthy();
    expect(document.querySelector("tr.me")?.getAttribute("data-key")).toBe("student_005#0");
    const unpin = screen.getByRole("button", { name: "Unpin student_005" });
    expect(unpin.getAttribute("aria-pressed")).toBe("true");
    fireEvent.click(unpin);
    expect(screen.queryByText("YOU")).toBeNull();
    expect(document.querySelector("tr.me")).toBeNull();
  });

  it("moves the pin when another student is pinned", () => {
    render(<Harness initialMe="student_002" />);
    fireEvent.click(screen.getByRole("button", { name: "Pin student_007 as you" }));
    expect(document.querySelectorAll("tr.me")).toHaveLength(1);
    expect(document.querySelector("tr.me")?.getAttribute("data-key")).toBe("student_007#0");
    expect(screen.getByRole("button", { name: "Pin student_002 as you" }).getAttribute("aria-pressed")).toBe("false");
  });

  it("keeps the pin while searching for someone else", () => {
    render(<Harness initialMe="student_003" />);
    fireEvent.change(screen.getByLabelText("Find a name"), { target: { value: "student_120" } });
    expect(screen.getByText("YOU")).toBeTruthy();
    expect(bodyRows()).toBe(1);
  });
});

describe("Board progress cells", () => {
  const board: BoardState = {
    status: "ok",
    entries: withKeys([
      {
        rank: 1,
        name: "ayu",
        score: 7,
        max_score: 10,
        challenges: [
          { name: "bitAnd", points: 3, max: 3 },
          { name: "negate", points: 2, max: 4 },
          { name: "tmin", points: 0, max: 3 },
        ],
      },
      { rank: 2, name: "budi", score: 5, max_score: 10 },
    ]),
    updatedAt: new Date(),
    stale: false,
    deltas: new Map(),
  };
  const row = (key: string) => document.querySelector(`tr[data-key="${key}"]`) as HTMLElement;

  it("draws one cell per challenge, marked solved, partial, or empty", () => {
    render(<Harness board={board} />);
    expect([...row("ayu#0").querySelectorAll(".cells i")].map((cell) => cell.className)).toEqual(["solved", "partial", "empty"]);
  });

  it("labels the bar with the number of solved challenges", () => {
    render(<Harness board={board} />);
    expect(row("ayu#0").querySelector('[role="img"]')?.getAttribute("aria-label")).toBe("1 of 3 challenges solved");
    expect(row("ayu#0").querySelector(".chal b")?.textContent).toBe("1/3");
  });

  it("names each challenge and its points on the cell", () => {
    render(<Harness board={board} />);
    expect([...row("ayu#0").querySelectorAll(".cells i")].map((cell) => cell.getAttribute("title"))).toEqual(["bitAnd: 3/3", "negate: 2/4", "tmin: 0/3"]);
  });

  it("keeps the score bar for an entry without a breakdown", () => {
    render(<Harness board={board} />);
    expect(row("budi#0").querySelector(".cells")).toBeNull();
    expect(row("budi#0").querySelector('.seg[role="img"]')?.getAttribute("aria-label")).toBe("5 of 10");
  });

  it("draws the pinned student's cells in the YOU strip too", () => {
    render(<Harness board={board} initialMe="ayu" />);
    expect(document.querySelectorAll(".you .cells i")).toHaveLength(3);
  });
});

