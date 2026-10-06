import { useCallback, useEffect, useRef, useState } from "react";
import type { RefObject } from "react";
import { clampIndex, nextIndex, previousIndex, randomIndex } from "../lib/playlist";
import { KEYS, readNumber, readStored, writeStored } from "../lib/storage";
import type { Track } from "../lib/types";

export interface PlayerState {
  audioRef: RefObject<HTMLAudioElement | null>;
  track: Track | null;
  index: number;
  count: number;
  playing: boolean;
  failed: boolean;
  /** Position and length of the loaded track in seconds; duration is NaN until the track's metadata loads. */
  time: number;
  duration: number;
  seek: (seconds: number) => void;
  volume: number;
  shuffle: boolean;
  toggle: () => void;
  next: () => void;
  previous: () => void;
  setVolume: (value: number) => void;
  toggleShuffle: () => void;
}

const SKIP_DELAY_MS = 900;

/**
 * Playlist over one <audio> element. Nothing is requested until the first play,
 * the starting track is random on every page load, a track that fails to load
 * is skipped, and a fully broken playlist stops.
 */
export function usePlayer(tracks: readonly Track[], title: string): PlayerState {
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const count = tracks.length;
  const [index, setIndex] = useState(() => randomIndex(count));
  const [time, setTime] = useState(0);
  const [duration, setDuration] = useState(Number.NaN);
  const [playing, setPlaying] = useState(false);
  const [failed, setFailed] = useState(false);
  const [volume, setVolumeState] = useState(() => Math.min(1, Math.max(0, readNumber(KEYS.volume, 0.6))));
  const [shuffle, setShuffle] = useState(() => readStored(KEYS.shuffle) === "1");
  const current = clampIndex(index, count);
  const live = useRef({ tracks, index: current, shuffle, want: false, errors: 0, loaded: null as string | null });
  live.current.tracks = tracks;
  live.current.index = current;
  live.current.shuffle = shuffle;

  const start = useCallback((target: number) => {
    const audio = audioRef.current;
    const track = live.current.tracks[target];
    if (!audio || !track) return;
    if (live.current.loaded !== track.src) {
      audio.src = track.src;
      live.current.loaded = track.src;
    }
    live.current.want = true;
    setFailed(false);
    const attempt = audio.play() as Promise<void> | undefined;
    attempt
      ?.then(() => {
        live.current.errors = 0;
        setPlaying(true);
      })
      .catch((error: unknown) => {
        if (error instanceof DOMException && error.name === "NotAllowedError") {
          live.current.want = false;
          setPlaying(false);
        }
      });
  }, []);

  const select = useCallback(
    (target: number) => {
      live.current.index = target;
      setIndex(target);
      setTime(0);
      setDuration(Number.NaN);
      if (live.current.want) {
        start(target);
      } else {
        // Unload the previous track so the slider never shows its position under the new title.
        setFailed(false);
        const audio = audioRef.current;
        if (audio && live.current.loaded !== null) {
          live.current.loaded = null;
          audio.removeAttribute("src");
          audio.load();
        }
      }
    },
    [start],
  );

  const next = useCallback(() => {
    select(nextIndex(live.current.index, live.current.tracks.length, live.current.shuffle));
  }, [select]);

  const previous = useCallback(() => {
    select(previousIndex(live.current.index, live.current.tracks.length, live.current.shuffle));
  }, [select]);

  const toggle = useCallback(() => {
    if (live.current.want) {
      live.current.want = false;
      audioRef.current?.pause();
      setPlaying(false);
    } else {
      start(live.current.index);
    }
  }, [start]);

  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return undefined;
    const onEnded = () => next();
    const onError = () => {
      if (live.current.loaded === null) return;
      live.current.errors += 1;
      setFailed(true);
      const total = live.current.tracks.length;
      if (live.current.want && total > 1 && live.current.errors < total) {
        window.setTimeout(next, SKIP_DELAY_MS);
      } else {
        live.current.want = false;
        setPlaying(false);
      }
    };
    audio.addEventListener("ended", onEnded);
    audio.addEventListener("error", onError);
    return () => {
      audio.removeEventListener("ended", onEnded);
      audio.removeEventListener("error", onError);
    };
  }, [next]);

  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return undefined;
    const onTime = () => setTime(audio.currentTime);
    const onMeta = () => setDuration(audio.duration);
    audio.addEventListener("timeupdate", onTime);
    audio.addEventListener("loadedmetadata", onMeta);
    audio.addEventListener("durationchange", onMeta);
    return () => {
      audio.removeEventListener("timeupdate", onTime);
      audio.removeEventListener("loadedmetadata", onMeta);
      audio.removeEventListener("durationchange", onMeta);
    };
  }, []);

  const seek = useCallback((seconds: number) => {
    const audio = audioRef.current;
    if (!audio || live.current.loaded === null || !Number.isFinite(audio.duration)) return;
    audio.currentTime = Math.min(Math.max(0, seconds), audio.duration);
    setTime(audio.currentTime);
  }, []);

  useEffect(() => {
    if (audioRef.current) audioRef.current.volume = volume;
    writeStored(KEYS.volume, String(volume));
  }, [volume]);

  const track = tracks[current] ?? null;

  useEffect(() => {
    if (!("mediaSession" in navigator) || track === null) return;
    if (typeof MediaMetadata === "function") {
      navigator.mediaSession.metadata = new MediaMetadata({ title: track.title, artist: track.artist, album: title });
    }
    navigator.mediaSession.playbackState = playing ? "playing" : "paused";
  }, [track, playing, title]);

  useEffect(() => {
    if (!("mediaSession" in navigator)) return undefined;
    const session = navigator.mediaSession;
    const handlers: [MediaSessionAction, () => void][] = [
      ["play", () => !live.current.want && toggle()],
      ["pause", () => live.current.want && toggle()],
      ["nexttrack", next],
      ["previoustrack", previous],
    ];
    for (const [action, handler] of handlers) {
      try {
        session.setActionHandler(action, handler);
      } catch {
        /* unsupported action */
      }
    }
    return () => {
      for (const [action] of handlers) {
        try {
          session.setActionHandler(action, null);
        } catch {
          /* unsupported action */
        }
      }
    };
  }, [toggle, next, previous]);

  return {
    audioRef,
    track,
    index: current,
    count,
    playing,
    failed,
    time,
    duration,
    seek,
    volume,
    shuffle,
    toggle,
    next,
    previous,
    setVolume: (value: number) => setVolumeState(Math.min(1, Math.max(0, value))),
    toggleShuffle: () =>
      setShuffle((value) => {
        writeStored(KEYS.shuffle, value ? "0" : "1");
        return !value;
      }),
  };
}
