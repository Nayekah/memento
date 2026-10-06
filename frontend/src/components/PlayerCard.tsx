import { useState } from "react";
import type { CSSProperties } from "react";
import type { PlayerState } from "../hooks/usePlayer";
import { KEYS, readStored, writeStored } from "../lib/storage";
import { formatTrackTime } from "../lib/time";
import { NextIcon, NoteIcon, PauseIcon, PlayIcon, PrevIcon, ShuffleIcon, SpeakerIcon } from "./icons";

export function PlayerCard({ player }: { player: PlayerState }) {
  const [mini, setMini] = useState(() => readStored(KEYS.playerMini) === "1");
  // While the thumb is being dragged, show the drag position and seek once on release.
  const [scrub, setScrub] = useState<number | null>(null);
  if (player.track === null) return null;
  const ready = Number.isFinite(player.duration) && player.duration > 0;
  const position = scrub ?? player.time;
  const release = () => {
    if (scrub !== null) player.seek(scrub);
    setScrub(null);
  };
  const { track } = player;
  const toggleMini = () => {
    writeStored(KEYS.playerMini, mini ? "0" : "1");
    setMini(!mini);
  };
  return (
    <section className={`player${player.playing ? " playing" : ""}${mini ? " mini" : ""}`} aria-label="Music player">
      <button
        type="button"
        className="logo"
        onClick={toggleMini}
        aria-expanded={!mini}
        aria-label={mini ? "Show music player" : "Minimise music player"}
        title={mini ? `Music: ${track.title}` : "Minimise"}
      >
        <NoteIcon className="pix note" />
      </button>
      {mini ? null : (
        <>
      <div className="np" aria-live="polite">
        <b className={player.failed ? "err" : ""} title={track.artist ? `${track.title} - ${track.artist}` : track.title}>
          {player.failed ? `CANNOT LOAD ${track.title}` : track.title}
        </b>
        <small>
          {track.artist}
          {track.artist && player.count > 1 ? " · " : ""}
          {player.count > 1 ? `${player.index + 1}/${player.count}` : ""}
        </small>
      </div>
      <div className="ctl">
        <button type="button" onClick={player.previous} aria-label="Previous track" title="Previous (P)" disabled={player.count < 2}>
          <PrevIcon />
        </button>
        <button type="button" className="main" onClick={player.toggle} aria-label={player.playing ? "Pause music" : "Play music"} aria-pressed={player.playing} title="Play or pause (M)">
          {player.playing ? <PauseIcon /> : <PlayIcon />}
        </button>
        <button type="button" onClick={player.next} aria-label="Next track" title="Next (N)" disabled={player.count < 2}>
          <NextIcon />
        </button>
        <button type="button" onClick={player.toggleShuffle} aria-label="Shuffle" aria-pressed={player.shuffle} title="Shuffle (S)" disabled={player.count < 3}>
          <ShuffleIcon />
        </button>
        <label className="vol" title="Volume">
          <SpeakerIcon />
          <input
            type="range"
            min={0}
            max={100}
            step={1}
            value={Math.round(player.volume * 100)}
            aria-label="Volume"
            onChange={(event) => player.setVolume(Number(event.target.value) / 100)}
          />
        </label>
      </div>
      <div className="seek">
        <span className="t">{ready ? formatTrackTime(position) : "0:00"}</span>
        <input
          type="range"
          min={0}
          max={ready ? player.duration : 1}
          step={0.1}
          value={ready ? Math.min(position, player.duration) : 0}
          disabled={!ready}
          aria-label="Seek"
          aria-valuetext={ready ? `${formatTrackTime(position)} of ${formatTrackTime(player.duration)}` : "Not loaded"}
          title={ready ? "Seek" : "Press play to load the track"}
          onPointerDown={() => setScrub(player.time)}
          onPointerUp={release}
          onPointerCancel={release}
          onBlur={release}
          onChange={(event) => {
            const value = Number(event.target.value);
            if (scrub !== null) setScrub(value);
            else player.seek(value);
          }}
          style={{ "--fill": ready ? `${(Math.min(position, player.duration) / player.duration) * 100}%` : "0%" } as CSSProperties}
        />
        <span className="t">{formatTrackTime(player.duration)}</span>
      </div>
        </>
      )}
    </section>
  );
}
