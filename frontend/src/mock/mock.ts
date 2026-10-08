// Development only: loaded through `?mock` when running `npm run dev`. It is not part of the production bundle.
import type { LeaderboardResult } from "../lib/api";
import { normalizeLeaderboard } from "../lib/api";

const FIRST = ["null", "xor", "tmin", "tmax", "shift", "mask", "neg", "abs", "bit", "byte", "float", "nibble", "carry", "borrow", "parity", "lea", "mov", "push", "pop", "stack", "heap", "rsp", "rip", "cdq", "jmp", "cmp", "test", "nop", "int", "long"];
const SECOND = ["ptr", "fan", "ninja", "wizard", "goblin", "enjoyer", "hacker", "slayer", "tamer", "panda", "fox", "otter", "koala", "gecko", "lynx", "moth", "wasp", "crab", "seal", "hawk"];

function random(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

interface Student {
  name: string;
  score: number;
}

const SETTINGS: Record<string, { max: number; seed: number; students: number }> = {
  datalab: { max: 100, seed: 7, students: 130 },
  bomblab: { max: 70, seed: 99, students: 126 },
};

const boards = new Map<string, Student[]>();

function build(id: string): Student[] | null {
  const setting = SETTINGS[id];
  if (setting === undefined) return null;
  const next = random(setting.seed);
  const used = new Set<string>();
  const students: Student[] = [];
  for (let i = 0; i < setting.students; i++) {
    let name = `${FIRST[i % FIRST.length]}_${SECOND[Math.floor(next() * SECOND.length)]}`;
    if (used.has(name)) name = `${name}${i}`;
    used.add(name);
    const skill = Math.min(1, 0.12 + 0.88 * Math.pow(next(), 1.25));
    students.push({ name, score: Math.round(skill * setting.max) });
  }
  return students;
}

export async function mockLeaderboard(id: string): Promise<LeaderboardResult> {
  const setting = SETTINGS[id];
  if (setting === undefined) return { status: "closed" };
  const existing = boards.get(id);
  const students = existing ?? build(id) ?? [];
  if (existing !== undefined) {
    const next = random(Date.now());
    for (const student of students) {
      if (next() < 0.12) student.score = Math.min(setting.max, student.score + 1 + Math.floor(next() * 6));
    }
  }
  boards.set(id, students);
  const sorted = [...students].sort((a, b) => b.score - a.score || a.name.localeCompare(b.name));
  let rank = 0;
  let previous = -1;
  const entries = sorted.map((student, index) => {
    if (student.score !== previous) rank = index + 1;
    previous = student.score;
    return { rank, name: student.name, score: student.score, max_score: setting.max };
  });
  return { status: "ok", entries: normalizeLeaderboard({ entries }) };
}
