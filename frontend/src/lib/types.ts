/** A student's result for one challenge: the points earned out of the points available. */
export interface Challenge {
  name: string;
  points: number;
  max: number;
}

export interface Entry {
  rank: number;
  name: string;
  score: number;
  max_score: number;
  /** One result per challenge. Absent when the backend cannot break the score down. */
  challenges?: Challenge[];
}

export interface KeyedEntry extends Entry {
  key: string;
}

export interface Practicum {
  id: string;
  name: string;
  endpoint: string;
  scoreLabel: string;
}

export interface Background {
  src: string;
  pos: string;
  credit: string;
}

export interface Track {
  title: string;
  artist: string;
  src: string;
}

export interface Config {
  title: string;
  motd: string;
  deadline: string | null;
  pageSize: number;
  refreshSeconds: number;
  /** The single practicum whose leaderboard is shown, chosen by the `practicum` field. */
  practicum: Practicum;
  practicums: Practicum[];
  backgrounds: Background[];
  music: Track[];
}
