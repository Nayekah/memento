import { useCallback, useEffect, useRef, useState } from "react";
import { clampIndex, nextIndex, randomIndex } from "../lib/playlist";
import type { Background } from "../lib/types";

export interface Layer {
  src: string;
  pos: string;
}

export interface BackgroundState {
  layers: [Layer, Layer];
  active: 0 | 1;
  credit: string;
  lucky: () => void;
}

const BLANK: Layer = { src: "", pos: "50% 50%" };

/** Two stacked layers so a new image fades in over the old one. A random image is picked on every page load. */
export function useBackground(backgrounds: readonly Background[]): BackgroundState {
  const count = backgrounds.length;
  const [index, setIndex] = useState(() => randomIndex(count));
  const [layers, setLayers] = useState<[Layer, Layer]>([BLANK, BLANK]);
  const [active, setActive] = useState<0 | 1>(0);
  const activeRef = useRef<0 | 1>(0);
  const indexRef = useRef(index);
  const shown = useRef(false);
  indexRef.current = index;

  useEffect(() => {
    for (const background of backgrounds) {
      const image = new Image();
      image.src = background.src;
    }
  }, [backgrounds]);

  useEffect(() => {
    const target = backgrounds[clampIndex(index, count)];
    if (target === undefined) {
      shown.current = false;
      setLayers([BLANK, BLANK]);
      return;
    }
    const layer: Layer = { src: target.src, pos: target.pos };
    if (!shown.current) {
      shown.current = true;
      activeRef.current = 0;
      setLayers([layer, BLANK]);
      setActive(0);
      return;
    }
    const next: 0 | 1 = activeRef.current === 0 ? 1 : 0;
    activeRef.current = next;
    setLayers((existing) => (next === 0 ? [layer, existing[1]] : [existing[0], layer]));
    setActive(next);
  }, [index, backgrounds, count]);

  const lucky = useCallback(() => {
    if (count < 2) return;
    setIndex(nextIndex(clampIndex(indexRef.current, count), count, true));
  }, [count]);

  return { layers, active, credit: backgrounds[clampIndex(index, count)]?.credit ?? "", lucky };
}
