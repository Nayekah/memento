import { DiceIcon, EyeIcon } from "./icons";

interface ActionsProps {
  canShuffleBackground: boolean;
  onLucky: () => void;
  hidden: boolean;
  onToggleHidden: () => void;
  credit: string;
}

export function Actions({ canShuffleBackground, onLucky, hidden, onToggleHidden, credit }: ActionsProps) {
  return (
    <div className="actions">
      {credit && <p className="credit">{credit}</p>}
      <div className="buttons">
        {canShuffleBackground && (
          <button type="button" onClick={onLucky} title="New random background (B)">
            <DiceIcon />
            <span>I FEEL LUCKY</span>
          </button>
        )}
        <button type="button" onClick={onToggleHidden} aria-pressed={hidden} title={hidden ? "Show the scoreboard again (H or Esc)" : "Hide the scoreboard to see the art (H)"}>
          <EyeIcon />
          <span>{hidden ? "VIEW SCORES" : "VIEW ART"}</span>
        </button>
      </div>
    </div>
  );
}
