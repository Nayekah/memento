export type CountdownState = "none" | "normal" | "warn" | "crit" | "over";

export interface Countdown {
  state: CountdownState;
  days: number;
  hours: number;
  minutes: number;
  seconds: number;
  totalSeconds: number;
}

export const WARN_SECONDS = 10 * 60;
export const CRIT_SECONDS = 60;

export const pad2 = (value: number): string => String(value).padStart(2, "0");

export function countdown(deadline: string | null, now: number): Countdown {
  const target = deadline === null ? Number.NaN : Date.parse(deadline);
  if (Number.isNaN(target)) {
    return { state: "none", days: 0, hours: 0, minutes: 0, seconds: 0, totalSeconds: 0 };
  }
  const totalSeconds = Math.max(0, Math.floor((target - now) / 1000));
  const state: CountdownState =
    totalSeconds === 0 ? "over" : totalSeconds < CRIT_SECONDS ? "crit" : totalSeconds < WARN_SECONDS ? "warn" : "normal";
  return {
    state,
    days: Math.floor(totalSeconds / 86400),
    hours: Math.floor((totalSeconds % 86400) / 3600),
    minutes: Math.floor((totalSeconds % 3600) / 60),
    seconds: totalSeconds % 60,
    totalSeconds,
  };
}

export function formatClock(value: Countdown): string {
  return `${pad2(value.hours)}:${pad2(value.minutes)}:${pad2(value.seconds)}`;
}

/** Formats a track position as m:ss; unknown or invalid values show as --:--. */
export function formatTrackTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "--:--";
  const whole = Math.floor(seconds);
  return `${Math.floor(whole / 60)}:${pad2(whole % 60)}`;
}
