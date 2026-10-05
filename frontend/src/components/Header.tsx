import type { BoardStatus } from "../hooks/useLeaderboard";
import { pad2 } from "../lib/time";
import type { KeyedEntry } from "../lib/types";

interface HeaderProps {
  title: string;
  motd: string;
  me: KeyedEntry | undefined;
  hi: number | null;
  players: number;
  updatedAt: Date | null;
  status: BoardStatus;
  stale: boolean;
}

const clock = (date: Date) => `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;

export function Header({ title, motd, me, hi, players, updatedAt, status, stale }: HeaderProps) {
  let info = "LOADING";
  if (status === "closed") info = "NOT OPEN YET";
  else if (status === "error") info = "OFFLINE // RETRYING";
  else if (updatedAt) info = `${players} PLAYERS // UPDATED ${clock(updatedAt)}`;

  return (
    <header>
      <div className="hud">
        <span>
          1UP <b>{me ? `#${pad2(me.rank)} ${me.name.slice(0, 12)}` : "---"}</b>
        </span>
        <span className={status === "error" || stale ? "warn-text blink" : ""} aria-live="polite">
          {stale && status === "ok" ? "OFFLINE // SHOWING LAST SCORES" : info}
        </span>
        <span>
          HI <b>{hi === null ? "---" : String(hi).padStart(3, "0")}</b>
        </span>
      </div>
      <h1>{title}</h1>
      {motd && (
        <div className="marquee" role="marquee" aria-label="Message of the day">
          <span>{motd}</span>
        </div>
      )}
    </header>
  );
}
