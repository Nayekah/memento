import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { createRef } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { PlayerState } from "../hooks/usePlayer";
import { PlayerCard } from "./PlayerCard";

afterEach(cleanup);

function player(overrides: Partial<PlayerState> = {}): PlayerState {
  return {
    audioRef: createRef<HTMLAudioElement>(),
    track: { title: "Constant Moderato", artist: "Mitsukiyo", src: "/config/music/constant-moderato.mp3" },
    index: 0,
    count: 8,
    playing: false,
    failed: false,
    time: 0,
    duration: Number.NaN,
    seek: vi.fn(),
    volume: 0.6,
    shuffle: false,
    toggle: vi.fn(),
    next: vi.fn(),
    previous: vi.fn(),
    setVolume: vi.fn(),
    toggleShuffle: vi.fn(),
    ...overrides,
  };
}

const slider = () => screen.getByLabelText("Seek") as HTMLInputElement;

describe("PlayerCard", () => {
  it("shows the track title, artist, and position in the playlist", () => {
    render(<PlayerCard player={player()} />);
    expect(screen.getByText("Constant Moderato")).toBeTruthy();
    expect(screen.getByText(/Mitsukiyo · 1\/8/)).toBeTruthy();
  });

  it("disables the time slider until the track has loaded", () => {
    render(<PlayerCard player={player()} />);
    expect(slider().disabled).toBe(true);
    expect(screen.getByText("0:00")).toBeTruthy();
    expect(screen.getByText("--:--")).toBeTruthy();
  });

  it("shows elapsed and total time once loaded", () => {
    render(<PlayerCard player={player({ time: 42.4, duration: 137.37, playing: true })} />);
    expect(slider().disabled).toBe(false);
    expect(screen.getByText("0:42")).toBeTruthy();
    expect(screen.getByText("2:17")).toBeTruthy();
    expect(slider().getAttribute("aria-valuetext")).toBe("0:42 of 2:17");
  });

  it("seeks immediately on keyboard or click changes", () => {
    const seek = vi.fn();
    render(<PlayerCard player={player({ time: 10, duration: 137.37, seek })} />);
    fireEvent.change(slider(), { target: { value: "90" } });
    expect(seek).toHaveBeenCalledWith(90);
  });

  it("seeks once, on release, while dragging", () => {
    const seek = vi.fn();
    render(<PlayerCard player={player({ time: 10, duration: 137.37, seek })} />);
    fireEvent.pointerDown(slider());
    fireEvent.change(slider(), { target: { value: "50" } });
    fireEvent.change(slider(), { target: { value: "75" } });
    expect(seek).not.toHaveBeenCalled();
    expect(screen.getByText("1:15")).toBeTruthy();
    fireEvent.pointerUp(slider());
    expect(seek).toHaveBeenCalledTimes(1);
    expect(seek).toHaveBeenCalledWith(75);
  });
});
