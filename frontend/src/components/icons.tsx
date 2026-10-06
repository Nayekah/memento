import type { ReactElement } from "react";

/** Draws a pixel-art icon from rows of "#" (filled) and "." (empty), merging horizontal runs into one rect. */
function Pixels({ rows, className = "pix" }: { rows: readonly string[]; className?: string }): ReactElement {
  const width = Math.max(...rows.map((row) => row.length));
  const rects: ReactElement[] = [];
  rows.forEach((row, y) => {
    let x = 0;
    while (x < row.length) {
      if (row[x] !== "#") {
        x += 1;
        continue;
      }
      const startX = x;
      while (row[x] === "#") x += 1;
      rects.push(<rect key={`${y}-${startX}`} x={startX} y={y} width={x - startX} height={1} />);
    }
  });
  return (
    <svg className={className} viewBox={`0 0 ${width} ${rows.length}`} fill="currentColor" shapeRendering="crispEdges" aria-hidden="true" focusable="false">
      {rects}
    </svg>
  );
}

const NOTE = ["..########", "..#......#", "..#......#", "..#......#", "..#......#", ".##.....##", "###....###", ".#......#."];
const PLAY = ["#......", "###....", "#####..", "#######", "#####..", "###....", "#......"];
const PAUSE = ["##...##", "##...##", "##...##", "##...##", "##...##", "##...##", "##...##"];
const NEXT = ["#.....##", "###...##", "#####.##", "########", "#####.##", "###...##", "#.....##"];
const PREV = NEXT.map((row) => [...row].reverse().join(""));
const SHUFFLE = ["......#..", "##...####", "..#.#..#.", "...#.....", "..#.#..#.", "##...####", "......#.."];
const DICE = ["#######", "#.....#", "#.#.#.#", "#.....#", "#.#.#.#", "#.....#", "#######"];
const EYE = ["..#####..", ".#.....#.", "#..###..#", ".#.....#.", "..#####.."];
const PIN = [".#####.", "..###..", "..###..", ".#####.", "#######", "...#...", "...#...", "...#..."];
const SPEAKER = ["...#....", "..##..#.", "####...#", "####.#.#", "####...#", "..##..#.", "...#...."];

export const NoteIcon = (props: { className?: string }) => <Pixels rows={NOTE} {...props} />;
export const PlayIcon = () => <Pixels rows={PLAY} />;
export const PauseIcon = () => <Pixels rows={PAUSE} />;
export const NextIcon = () => <Pixels rows={NEXT} />;
export const PrevIcon = () => <Pixels rows={PREV} />;
export const ShuffleIcon = () => <Pixels rows={SHUFFLE} />;
export const DiceIcon = () => <Pixels rows={DICE} />;
export const EyeIcon = () => <Pixels rows={EYE} />;
export const SpeakerIcon = () => <Pixels rows={SPEAKER} />;
export const PinIcon = () => <Pixels rows={PIN} />;
