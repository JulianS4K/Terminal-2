// EventCountdown — inline "Doors in 2d 4h" / "Started 1h ago" line.
//
// Updates every minute. We don't update every second because:
//   * Sub-minute precision doesn't help anyone — "Doors in 0d 0h 47s"
//     is uglier than "Doors in 47 minutes".
//   * Per-second renders churn the React tree more than we need.
//
// Timezone-aware: the countdown is computed against the absolute UTC
// instant, so it's correct for every viewer regardless of their local
// timezone. The displayed *event time* (formatInTz elsewhere) shows
// the venue's wall-clock time; this countdown answers a different
// question (how soon is it from where I am).

import { useEffect, useState } from 'react';

interface Props {
  // The absolute UTC instant the event starts.
  startsAt: Date;
  // Optional doors-open instant; when present we count down to doors,
  // not to the show time, since that's what attendees actually want.
  doorsOpen?: Date | null;
}

export default function EventCountdown({ startsAt, doorsOpen }: Props) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    // Tick once a minute — see the doc comment above.
    const id = setInterval(() => setNow(Date.now()), 60_000);
    return () => clearInterval(id);
  }, []);

  const target = doorsOpen ?? startsAt;
  const diffMs = target.getTime() - now;
  const past = diffMs < 0;
  const absMs = Math.abs(diffMs);

  // Compose human-readable units. Skip days when within 24h, skip
  // hours when within 1h. Always show at least one unit.
  const totalMinutes = Math.floor(absMs / 60_000);
  const days = Math.floor(totalMinutes / (24 * 60));
  const hours = Math.floor((totalMinutes % (24 * 60)) / 60);
  const minutes = totalMinutes % 60;

  let label: string;
  if (totalMinutes < 1) {
    label = past ? 'just now' : 'in less than a minute';
  } else if (days >= 1) {
    label = `${days}d ${hours}h`;
  } else if (hours >= 1) {
    label = `${hours}h ${minutes}m`;
  } else {
    label = `${minutes}m`;
  }

  const verb = past
    ? doorsOpen
      ? 'Doors opened'
      : 'Started'
    : doorsOpen
    ? 'Doors in'
    : 'Starts in';

  return (
    <span className="font-mono">
      {verb} {past ? <>{label} ago</> : label}
    </span>
  );
}
