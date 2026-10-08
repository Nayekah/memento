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

interface Problem {
  name: string;
  max: number;
}

interface Student {
  name: string;
  /** Points earned for each problem, in the order of the practicum's problems. */
  points: number[];
}

const SETTINGS: Record<string, { problems: Problem[]; seed: number; students: number }> = {
  // Seven challenges, like a dry run.
  datalab: {
    problems: [
      { name: "bitXor", max: 4 },
      { name: "isTmax", max: 5 },
      { name: "allOddBits", max: 5 },
      { name: "conditional", max: 6 },
      { name: "logicalNeg", max: 6 },
      { name: "howManyBits", max: 8 },
      { name: "floatScale2", max: 8 },
    ],
    seed: 7,
    students: 130,
  },
  // Five challenges.
  bomblab: {
    problems: [
      { name: "phase_1", max: 10 },
      { name: "phase_2", max: 10 },
      { name: "phase_3", max: 15 },
      { name: "phase_4", max: 15 },
      { name: "phase_5", max: 20 },
    ],
    seed: 99,
    students: 126,
  },
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
    const skill = 0.05 + 0.8 * Math.pow(next(), 1.8);
    // A stronger student solves more problems, and some are only partly earned.
    const points = setting.problems.map((problem) => {
      const roll = next();
      if (roll < skill) return problem.max;
      if (roll < skill + 0.15) return Math.max(1, Math.floor(problem.max / 2));
      return 0;
    });
    students.push({ name, points });
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
      if (next() >= 0.12) continue;
      const open = setting.problems.flatMap((problem, i) => (student.points[i] < problem.max ? [i] : []));
      if (open.length === 0) continue;
      const i = open[Math.floor(next() * open.length)];
      const max = setting.problems[i].max;
      student.points[i] = student.points[i] === 0 && next() < 0.5 ? Math.max(1, Math.floor(max / 2)) : max;
    }
  }
  boards.set(id, students);
  const total = (points: readonly number[]) => points.reduce((sum, value) => sum + value, 0);
  const maxScore = total(setting.problems.map((problem) => problem.max));
  const sorted = [...students].sort((a, b) => total(b.points) - total(a.points) || a.name.localeCompare(b.name));
  let rank = 0;
  let previous = -1;
  const entries = sorted.map((student, index) => {
    const score = total(student.points);
    if (score !== previous) rank = index + 1;
    previous = score;
    const challenges = setting.problems.map((problem, i) => ({ name: problem.name, points: student.points[i], max: problem.max }));
    return { rank, name: student.name, score, max_score: maxScore, challenges };
  });
  return { status: "ok", entries: normalizeLeaderboard({ entries }) };
}
