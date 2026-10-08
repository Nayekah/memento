import { useEffect, useState } from "react";
import { countdown } from "../lib/time";
import type { Countdown } from "../lib/time";

export function useCountdown(deadline: string | null): Countdown {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    setNow(Date.now());
    if (deadline === null) return undefined;
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [deadline]);
  return countdown(deadline, now);
}
