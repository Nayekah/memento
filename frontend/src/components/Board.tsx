import { useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties } from "react";
import type { BoardState } from "../hooks/useLeaderboard";
import { growLimit, page } from "../lib/board";
import type { KeyedEntry } from "../lib/types";
import { PinIcon } from "./icons";

interface BoardProps {
  board: BoardState;
  query: string;
  onQuery: (value: string) => void;
  me: KeyedEntry | undefined;
  onForgetMe: () => void;
  /** Pins the student as "you", or unpins them if they are already pinned. */
  onTogglePin: (entry: KeyedEntry) => void;
  pageSize: number;
  scoreLabel: string;
}

const reducedMotion = () => typeof window.matchMedia === "function" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

const tier = (entry: KeyedEntry) => {
  const ratio = entry.score / entry.max_score;
  return ratio >= 0.75 ? "var(--green)" : ratio >= 0.4 ? "var(--gold)" : "var(--red)";
};

function Score({ value, animate }: { value: number; animate: boolean }) {
  const [shown, setShown] = useState(animate && !reducedMotion() ? 0 : value);
  const done = useRef(!animate);
  useEffect(() => {
    if (done.current || reducedMotion()) {
      setShown(value);
      return undefined;
    }
    done.current = true;
    const started = performance.now();
    let frame = 0;
    const step = (time: number) => {
      const progress = Math.min(1, (time - started) / 700);
      setShown(Math.round(value * progress));
      if (progress < 1) frame = requestAnimationFrame(step);
    };
    frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
  }, [value]);
  return <>{String(shown).padStart(3, "0")}</>;
}

function Bar({ entry }: { entry: KeyedEntry }) {
  return (
    <div className="seg" role="img" aria-label={`${entry.score} of ${entry.max_score}`}>
      <i style={{ width: `${(entry.score / entry.max_score) * 100}%`, "--c": tier(entry) } as CSSProperties} />
    </div>
  );
}

export function Board({ board, query, onQuery, me, onForgetMe, onTogglePin, pageSize, scoreLabel }: BoardProps) {
  const [limit, setLimit] = useState(pageSize);
  const [intro, setIntro] = useState(true);
  const [jumpTo, setJumpTo] = useState<string | null>(null);
  const top = useRef<HTMLDivElement>(null);
  const result = useMemo(() => page(board.entries, query, limit), [board.entries, query, limit]);
  const rankWidth = Math.max(2, String(board.entries.length).length);

  useEffect(() => setLimit(pageSize), [pageSize]);

  useEffect(() => {
    if (!intro || board.entries.length === 0) return undefined;
    const timer = window.setTimeout(() => setIntro(false), 1500);
    return () => window.clearTimeout(timer);
  }, [intro, board.entries.length]);

  useEffect(() => {
    if (jumpTo === null) return;
    const row = [...document.querySelectorAll<HTMLTableRowElement>("tr[data-key]")].find((r) => r.dataset.key === jumpTo);
    row?.scrollIntoView({ block: "center", behavior: reducedMotion() ? "auto" : "smooth" });
    setJumpTo(null);
  }, [jumpTo, result.rows]);

  const showMe = () => {
    if (!me) return;
    const position = board.entries.findIndex((entry) => entry.key === me.key);
    if (query !== "") onQuery("");
    setLimit((current) => Math.max(current, position + 1));
    setJumpTo(me.key);
  };

  const showLess = () => {
    setLimit(pageSize);
    top.current?.scrollIntoView({ block: "start", behavior: reducedMotion() ? "auto" : "smooth" });
  };

  return (
    <section className="board" aria-label="Leaderboard" ref={top}>
      <div className="tools">
        <input
          type="search"
          value={query}
          maxLength={64}
          placeholder="FIND A NAME"
          aria-label="Find a name"
          autoComplete="off"
          spellCheck={false}
          onChange={(event) => onQuery(event.target.value)}
        />
        {query !== "" && (
          <button type="button" onClick={() => onQuery("")} aria-label="Clear search">
            X
          </button>
        )}
      </div>

      {me && (
        <div className="you">
          <button type="button" className="you-main" onClick={showMe} title="Jump to your row">
            <span className="you-tag">YOU</span>
            <span className="r">#{String(me.rank).padStart(rankWidth, "0")}</span>
            <span className="n">{me.name}</span>
            <Bar entry={me} />
            <span className="s">{String(me.score).padStart(3, "0")}</span>
          </button>
          <button type="button" className="forget" onClick={onForgetMe} aria-label="Forget my name">
            X
          </button>
        </div>
      )}

      {board.status === "loading" && <p className="status blink">LOADING SCORES</p>}
      {board.status === "closed" && <p className="status">THIS PRACTICUM HAS NO SCOREBOARD YET</p>}
      {board.status === "error" && <p className="status warn-text">SCOREBOARD UNREACHABLE. RETRYING.</p>}
      {board.status === "ok" && board.entries.length === 0 && <p className="status">NO SCORES YET. BE THE FIRST.</p>}

      {board.entries.length > 0 && (
        <>
          <table>
            <thead>
              <tr>
                <th scope="col">RNK</th>
                <th scope="col">NAME</th>
                <th scope="col" className="b">
                  <span className="sr-only">Progress</span>
                </th>
                <th scope="col" className="s">
                  {scoreLabel}
                </th>
                <th scope="col" className="p">
                  <span className="sr-only">Pin</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {result.rows.map((entry, i) => {
                const delta = board.deltas.get(entry.key);
                const classes = [
                  intro ? "row intro" : "row",
                  entry.rank <= 3 ? `t${entry.rank}` : "",
                  me?.key === entry.key ? "me" : "",
                  delta?.scoreChanged ? "hit" : "",
                ].filter(Boolean);
                return (
                  <tr key={entry.key} data-key={entry.key} className={classes.join(" ")} style={{ "--i": i % pageSize } as CSSProperties}>
                    <td className="r">
                      {entry.rank <= 3 && <span className="star" aria-hidden="true" />}
                      {String(entry.rank).padStart(rankWidth, "0")}
                      {delta && delta.rank !== 0 && (
                        <span className={delta.rank > 0 ? "d u" : "d dn"} aria-label={delta.rank > 0 ? `up ${delta.rank}` : `down ${-delta.rank}`}>
                          {delta.rank > 0 ? `+${delta.rank}` : delta.rank}
                        </span>
                      )}
                    </td>
                    <td className="n">{entry.name}</td>
                    <td className="b">
                      <Bar entry={entry} />
                    </td>
                    <td className="s">
                      <Score value={entry.score} animate={intro} />
                    </td>
                    <td className="p">
                      <button
                        type="button"
                        className="pin"
                        onClick={() => onTogglePin(entry)}
                        aria-pressed={me?.key === entry.key}
                        aria-label={me?.key === entry.key ? `Unpin ${entry.name}` : `Pin ${entry.name} as you`}
                        title={me?.key === entry.key ? "Unpin" : "Pin as you"}
                      >
                        <PinIcon />
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          {query !== "" && result.matched === 0 && <p className="status">NO PLAYER FOUND</p>}
          <div className="pager">
            <span>
              {query !== ""
                ? `${result.rows.length} OF ${result.matched} MATCHES`
                : result.remaining > 0
                  ? `SHOWING ${result.rows.length} OF ${result.total}`
                  : `ALL ${result.total} PLAYERS`}
            </span>
            {result.remaining > 0 && (
              <>
                <button type="button" onClick={() => setLimit(growLimit(limit, result.matched, pageSize))}>
                  VIEW MORE
                </button>
                <button type="button" onClick={() => setLimit(result.matched)}>
                  SHOW ALL
                </button>
              </>
            )}
            {result.remaining === 0 && limit > pageSize && query === "" && (
              <button type="button" onClick={showLess}>
                SHOW LESS
              </button>
            )}
          </div>
        </>
      )}
    </section>
  );
}
