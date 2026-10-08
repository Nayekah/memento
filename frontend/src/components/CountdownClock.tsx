import { useCountdown } from "../hooks/useCountdown";
import { formatClock } from "../lib/time";

export function CountdownClock({ deadline }: { deadline: string | null }) {
  const value = useCountdown(deadline);
  if (value.state === "none") return null;
  const [hh, mm, ss] = formatClock(value).split(":");
  return (
    <div className={`timer ${value.state}`} role="timer" aria-label={value.state === "over" ? "Time is up" : `${formatClock(value)} left`}>
      <small>{value.state === "over" ? "FINAL SCORES" : value.days > 0 ? `TIME LEFT // ${value.days} DAY${value.days > 1 ? "S" : ""} +` : "TIME LEFT"}</small>
      {value.state === "over" ? (
        <b>TIME UP</b>
      ) : (
        <b>
          {hh}
          <i>:</i>
          {mm}
          <i>:</i>
          {ss}
        </b>
      )}
    </div>
  );
}
