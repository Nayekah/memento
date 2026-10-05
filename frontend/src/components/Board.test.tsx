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

function Harness({ board = ok, meName = "" }: { board?: BoardState; meName?: string }) {
  const [query, setQuery] = useState("");
  return <Board board={board} query={query} onQuery={setQuery} me={findMe(board.entries, meName)} onForgetMe={() => {}} pageSize={20} scoreLabel="PTS" />;
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
    render(<Harness meName="student_099" />);
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
});
