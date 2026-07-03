// Buyer-facing reschedule notice.
//
// Renders on TicketDetail. If the organizer has moved the event (mig
// 20260703124000), the holder sees "Rescheduled — was X, now Y" with the reason.
// RLS lets a holder read reschedules for events they hold a non-voided ticket
// for. Shows only the most recent move; renders nothing when there is none.

import { useEffect, useState } from 'react';
import { CalendarClock, ArrowRight } from 'lucide-react';
import { listEventReschedules, type Reschedule } from '../lib/reschedule';
import { formatInTz } from '../lib/datetime';

export default function RescheduleNotice({
  eventId,
  timezone,
}: {
  eventId: string;
  timezone?: string;
}) {
  const [latest, setLatest] = useState<Reschedule | null>(null);

  useEffect(() => {
    let alive = true;
    listEventReschedules(eventId).then((rows) => {
      if (alive) setLatest(rows[0] ?? null);
    });
    return () => {
      alive = false;
    };
  }, [eventId]);

  if (!latest) return null;

  return (
    <div className="mt-12 bg-brand-accent/5 border border-brand-accent/30 p-8">
      <div className="flex items-center gap-3 mb-4">
        <CalendarClock className="w-4 h-4 text-brand-accent" aria-hidden="true" />
        <h2 className="text-xs font-black text-brand-accent uppercase tracking-tighter italic">
          Event rescheduled
        </h2>
      </div>
      <div className="flex flex-wrap items-center gap-3 text-white">
        <span className="text-white/40 line-through font-black uppercase tracking-tighter italic text-sm">
          {latest.oldStartsAt
            ? formatInTz(latest.oldStartsAt, timezone, { dateStyle: 'medium', timeStyle: 'short' })
            : 'TBA'}
        </span>
        <ArrowRight size={16} className="text-white/30" aria-hidden="true" />
        <span className="font-black uppercase tracking-tighter italic text-lg text-brand-primary">
          {formatInTz(latest.newStartsAt, timezone, { dateStyle: 'medium', timeStyle: 'short' })}
        </span>
      </div>
      {latest.reason ? (
        <p className="text-sm text-white/60 mt-3 leading-relaxed">{latest.reason}</p>
      ) : null}
      <p className="text-[10px] font-black text-white/30 uppercase tracking-widest mt-3">
        Your ticket stays valid — no action needed.
      </p>
    </div>
  );
}
