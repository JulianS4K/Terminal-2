// TicketPhaseCountdown — one evolving countdown that walks the ticket's
// milestones in order: entry-code reveal → doors open → show start → set times.
//
// The pass shows a SINGLE countdown that always targets the next milestone still
// in the future and relabels itself as each one passes. In the locked state it
// counts down to the QR reveal; once revealed, the same component (fed the
// post-reveal phases) switches to "Doors open in …", then "Show starts in …",
// then any set times, then a done label ("Enjoy the show").
//
// Purely presentational — it lives outside the QR quiet zone and never touches
// the code, so it can't affect scannability. Ticks every second so the last
// minute before a milestone (especially the reveal) feels live and lands on
// time; formats coarsely (d/h) when far out, mm:ss under an hour.

import { useEffect, useState } from 'react';

export interface CountdownPhase {
  key: string;
  /** Prefix shown above the time, e.g. "Doors open in". */
  label: string;
  at: Date;
}

/**
 * The first phase still in the future, with phases sorted ascending by time so
 * out-of-order input self-corrects. Returns null when every phase is past.
 * Pure — unit-tested.
 */
export function activePhase(phases: CountdownPhase[], now: number): CountdownPhase | null {
  const upcoming = phases
    .filter((p) => p.at instanceof Date && !Number.isNaN(p.at.getTime()))
    .sort((a, b) => a.at.getTime() - b.at.getTime())
    .find((p) => p.at.getTime() > now);
  return upcoming ?? null;
}

/** Human-readable remaining time: "2d 4h", "3h 12m", or ticking "7:04" under an hour. */
export function formatRemaining(ms: number): string {
  const totalSec = Math.max(0, Math.floor(ms / 1000));
  const d = Math.floor(totalSec / 86400);
  const h = Math.floor((totalSec % 86400) / 3600);
  const m = Math.floor((totalSec % 3600) / 60);
  const s = totalSec % 60;
  if (d >= 1) return `${d}d ${h}h`;
  if (h >= 1) return `${h}h ${m}m`;
  return `${m}:${s.toString().padStart(2, '0')}`;
}

interface Props {
  phases: CountdownPhase[];
  /** Shown when all phases are in the past. Omit/empty to render nothing. */
  doneLabel?: string;
  className?: string;
}

export default function TicketPhaseCountdown({ phases, doneLabel, className }: Props) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);

  const phase = activePhase(phases, now);

  if (!phase) {
    if (!doneLabel) return null;
    return (
      <div className={className}>
        <p className="disp text-2xl tracking-tight leading-none text-black">{doneLabel}</p>
      </div>
    );
  }

  return (
    <div className={className}>
      <p className="type text-[9px] uppercase tracking-widest text-black/40 mb-1">{phase.label}</p>
      <p className="disp text-3xl tracking-tight leading-none text-black tabular-nums">
        {formatRemaining(phase.at.getTime() - now)}
      </p>
    </div>
  );
}
