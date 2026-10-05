import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Actions } from "./Actions";

afterEach(cleanup);

describe("Actions", () => {
  it("labels the toggle VIEW ART normally and VIEW SCORES while the art is shown", () => {
    const { rerender } = render(<Actions canShuffleBackground onLucky={() => {}} hidden={false} onToggleHidden={() => {}} credit="" />);
    const toggle = screen.getByRole("button", { name: /VIEW ART/ });
    expect(toggle.getAttribute("aria-pressed")).toBe("false");
    rerender(<Actions canShuffleBackground onLucky={() => {}} hidden onToggleHidden={() => {}} credit="" />);
    const pressed = screen.getByRole("button", { name: /VIEW SCORES/ });
    expect(pressed.getAttribute("aria-pressed")).toBe("true");
  });

  it("calls the handlers and hides the lucky button with fewer than two backgrounds", () => {
    const onLucky = vi.fn();
    const onToggle = vi.fn();
    const { rerender } = render(<Actions canShuffleBackground onLucky={onLucky} hidden={false} onToggleHidden={onToggle} credit="Art credit" />);
    fireEvent.click(screen.getByRole("button", { name: /I FEEL LUCKY/ }));
    fireEvent.click(screen.getByRole("button", { name: /VIEW ART/ }));
    expect(onLucky).toHaveBeenCalledOnce();
    expect(onToggle).toHaveBeenCalledOnce();
    expect(screen.getByText("Art credit")).toBeTruthy();
    rerender(<Actions canShuffleBackground={false} onLucky={onLucky} hidden={false} onToggleHidden={onToggle} credit="" />);
    expect(screen.queryByRole("button", { name: /I FEEL LUCKY/ })).toBeNull();
  });
});
