import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "./App";

const config = {
  title: "Praktikum 1 II2130",
  practicum: "datalab",
  practicums: [{ id: "datalab", name: "Data Lab", endpoint: "/api/v1/leaderboard" }],
};
const entries = Array.from({ length: 30 }, (_, i) => ({ rank: i + 1, name: `student_${String(i + 1).padStart(2, "0")}`, score: 100 - i, max_score: 100 }));

beforeEach(() => {
  localStorage.clear();
  Element.prototype.scrollIntoView = vi.fn();
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string) => {
      if (url === "/config/config.json") return new Response(JSON.stringify(config), { status: 200 });
      if (url === "/api/v1/leaderboard") return new Response(JSON.stringify({ entries }), { status: 200 });
      return new Response("", { status: 404 });
    }),
  );
});
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("App pinning", () => {
  it("does not pin when the search matches a name exactly, only the pin button pins", async () => {
    render(<App />);
    await screen.findByText("student_01");
    fireEvent.change(screen.getByLabelText("Find a name"), { target: { value: "student_12" } });
    expect(screen.queryByText("YOU")).toBeNull();
    expect(localStorage.getItem("memento.me")).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: "Pin student_12 as you" }));
    expect(screen.getByText("YOU")).toBeTruthy();
    expect(screen.getByText(/1UP/).textContent).toContain("#12 student_12");
    expect(localStorage.getItem("memento.me")).toBe("student_12");

    fireEvent.click(screen.getByRole("button", { name: "Forget my name" }));
    expect(screen.queryByText("YOU")).toBeNull();
    expect(localStorage.getItem("memento.me")).toBe("");
  });

  it("restores a pin saved in an earlier visit", async () => {
    localStorage.setItem("memento.me", "student_07");
    render(<App />);
    await screen.findByText("YOU");
    expect(screen.getByRole("button", { name: "Unpin student_07" }).getAttribute("aria-pressed")).toBe("true");
  });
});
