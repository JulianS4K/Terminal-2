// AddToCalendar — a single action-list entry that expands inline to the two
// export paths: Google Calendar (opens a prefilled "add event" tab) and an .ics
// download that Apple Calendar / Outlook / everything else imports. Pure
// frontend (lib/calendar.ts) — no backend, no third-party SDK.

import { useState } from 'react';
import { CalendarPlus, ExternalLink, Download } from 'lucide-react';
import type { Event } from '../types';
import { googleCalendarUrl, downloadEventIcs } from '../lib/calendar';

interface Props {
  event: Event;
  className?: string;
}

export default function AddToCalendar({ event, className }: Props) {
  const [open, setOpen] = useState(false);
  const gcalUrl = googleCalendarUrl(event);

  // No usable start instant → nothing to add. (Matches lib/calendar returning null.)
  if (!gcalUrl) return null;

  return (
    <div className={className}>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        className="flex items-center hover:text-brand-primary transition-colors text-left"
      >
        <CalendarPlus className="w-4 h-4 mr-3 text-brand-primary" />
        Add to Calendar
      </button>

      {open && (
        <div className="mt-3 ml-7 flex flex-col space-y-3">
          <a
            href={gcalUrl}
            target="_blank"
            rel="noopener noreferrer"
            onClick={() => setOpen(false)}
            className="flex items-center text-white/40 hover:text-brand-primary transition-colors"
          >
            <ExternalLink className="w-3.5 h-3.5 mr-3" />
            Google Calendar
          </a>
          <button
            type="button"
            onClick={() => {
              downloadEventIcs(event);
              setOpen(false);
            }}
            className="flex items-center text-white/40 hover:text-brand-primary transition-colors text-left"
          >
            <Download className="w-3.5 h-3.5 mr-3" />
            Apple / Outlook (.ics)
          </button>
        </div>
      )}
    </div>
  );
}
