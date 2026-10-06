import { useCallback, useEffect, useMemo, useState } from "react";
import { Actions } from "./components/Actions";
import { Backdrop } from "./components/Backdrop";
import { Board } from "./components/Board";
import { CountdownClock } from "./components/CountdownClock";
import { Header } from "./components/Header";
import { PlayerCard } from "./components/PlayerCard";
import { useBackground } from "./hooks/useBackground";
import { useConfig } from "./hooks/useConfig";
import { useLeaderboard } from "./hooks/useLeaderboard";
import { usePlayer } from "./hooks/usePlayer";
import { findMe } from "./lib/board";
import { KEYS, readStored, writeStored } from "./lib/storage";
import type { Config, KeyedEntry } from "./lib/types";

const MOCK = import.meta.env.DEV && new URLSearchParams(window.location.search).has("mock");

function Scoreboard({ config }: { config: Config }) {
  const { practicum } = config;
  const board = useLeaderboard(practicum.endpoint, practicum.id, config.refreshSeconds, MOCK);
  const background = useBackground(config.backgrounds);
  const player = usePlayer(config.music, config.title);
  const [query, setQuery] = useState("");
  const [meName, setMeName] = useState(() => readStored(KEYS.me) ?? "");
  const [hidden, setHidden] = useState(false);

  const me = useMemo(() => findMe(board.entries, meName), [board.entries, meName]);

  const forgetMe = useCallback(() => {
    setMeName("");
    writeStored(KEYS.me, "");
  }, []);

  const togglePin = useCallback(
    (entry: KeyedEntry) => {
      const next = me?.key === entry.key ? "" : entry.name;
      setMeName(next);
      writeStored(KEYS.me, next);
    },
    [me],
  );

  const toggleHidden = useCallback(() => setHidden((value) => !value), []);

  useEffect(() => {
    document.title = player.playing && player.track ? `${player.track.title} - ${config.title}` : config.title;
  }, [player.playing, player.track, config.title]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (event.ctrlKey || event.metaKey || event.altKey) return;
      if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable)) return;
      const key = event.key.toLowerCase();
      if (key === "h") toggleHidden();
      else if (key === "escape" && hidden) setHidden(false);
      else if (key === "b") background.lucky();
      else if (player.track !== null && key === "m") player.toggle();
      else if (player.track !== null && key === "n") player.next();
      else if (player.track !== null && key === "p") player.previous();
      else if (player.track !== null && key === "s") player.toggleShuffle();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [toggleHidden, hidden, background, player]);

  return (
    <>
      <Backdrop layers={background.layers} active={background.active} />
      {/* Hidden with visibility, not display:none, so the scrollbar, layout and scroll position stay put. */}
      <main className={`cab${hidden ? " hidden" : ""}`}>
        <Header
          title={config.title}
          motd={config.motd}
          me={me}
          hi={board.entries[0]?.score ?? null}
          players={board.entries.length}
          updatedAt={board.updatedAt}
          status={board.status}
          stale={board.stale}
        />
        <CountdownClock deadline={config.deadline} />
        <Board
          key={practicum.id}
          board={board}
          query={query}
          onQuery={setQuery}
          me={me}
          onForgetMe={forgetMe}
          onTogglePin={togglePin}
          pageSize={config.pageSize}
          scoreLabel={practicum.scoreLabel}
        />
      </main>
      <PlayerCard player={player} />
      <Actions
        canShuffleBackground={config.backgrounds.length > 1}
        onLucky={background.lucky}
        hidden={hidden}
        onToggleHidden={toggleHidden}
        credit={background.credit}
      />
      <audio ref={player.audioRef} preload="none" />
    </>
  );
}

export function App() {
  const { config, loaded } = useConfig();
  if (!loaded) return <p className="boot blink">INSERT COIN</p>;
  return <Scoreboard config={config} />;
}
