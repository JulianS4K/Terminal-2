// Buyer-facing organizer updates thread.
//
// Renders on TicketDetail below the pass. Read-only list of the announcements an
// organizer has broadcast for this event (mig 20260703121000) — the in-app
// counterpart to the announcement emails, so a holder who missed the email still
// sees the history. RLS lets a holder read announcements for events they hold a
// non-voided ticket for. Renders nothing until there's at least one update, to
// keep the ticket clean.

import { useEffect, useState } from 'react';
import { Megaphone } from 'lucide-react';
import { formatDistanceToNow } from 'date-fns';
import { listEventAnnouncements, type Announcement } from '../lib/announcements';

export default function OrganizerUpdates({ eventId }: { eventId: string }) {
  const [items, setItems] = useState<Announcement[]>([]);

  useEffect(() => {
    let alive = true;
    listEventAnnouncements(eventId).then((rows) => {
      if (alive) setItems(rows);
    });
    return () => {
      alive = false;
    };
  }, [eventId]);

  if (items.length === 0) return null;

  return (
    <div className="mt-12 bg-[#111111] border border-white/10 p-8">
      <div className="flex items-center gap-3 mb-6">
        <Megaphone className="w-4 h-4 text-brand-primary" aria-hidden="true" />
        <h2 className="text-xs font-black text-brand-primary uppercase tracking-tighter italic">
          Updates from the organizer ({items.length})
        </h2>
      </div>
      <ul className="space-y-6">
        {items.map((a) => (
          <li key={a.id} className="border-l-2 border-brand-primary/40 pl-5">
            <div className="flex items-baseline justify-between gap-4">
              <p className="text-sm font-black uppercase tracking-tighter italic text-white">
                {a.subject}
              </p>
              <span className="text-[9px] font-black text-white/30 uppercase tracking-widest whitespace-nowrap">
                {formatDistanceToNow(a.createdAt, { addSuffix: true })}
              </span>
            </div>
            <p className="text-sm text-white/60 mt-2 whitespace-pre-wrap leading-relaxed">{a.body}</p>
          </li>
        ))}
      </ul>
    </div>
  );
}
