// AddToCalendar — offers the two export paths (Google Calendar + Apple/Outlook
// .ics) for an event. Pure frontend (lib/calendar.ts): no backend, no SDK.
//
// Two visual variants so it drops into different surfaces:
//   • 'list'   — a flat action-list row that expands inline (event page action
//                column, alongside Share / SMS / Instagram).
//   • 'button' — a solid button with a popover menu (ticket page, next to the
//                Open Pass action).

import { useState } from 'react';
import { CalendarPlus, ExternalLink, Download } from 'lucide-react';
import type { Event } from '../types';
import { googleCalendarUrl, downloadEventIcs } from '../lib/calendar';

interface Props {
  event: Event;
  variant?: 'list' | 'button';
  className?: string;
}

export default function AddToCalendar({ event, variant = 'list', className }: Props) {
  const [open, setOpen] = useState(false);
  const gcalUrl = googleCalendarUrl(event);

  // No usable start instant → nothing to add. (Matches lib/calendar returning null.)
  if (!gcalUrl) return null;

  const options = (
    <>
      <a
        href={gcalUrl}
        target="_blank"
        rel="noopener noreferrer"
        onClick={() => setOpen(false)}
        className={
          variant === 'button'
            ? 'flex items-center px-4 py-3 text-white/70 hover:text-brand-primary hover:bg-white/5 transition-colors text-xs font-bold uppercase tracking-widest'
            : 'flex items-center text-white/40 hover:text-brand-primary transition-colors'
        }
      >
        <ExternalLink className={variant === 'button' ? 'w-4 h-4 mr-3' : 'w-3.5 h-3.5 mr-3'} />
        Google Calendar
      </a>
      <button
        type="button"
        onClick={() => {
          downloadEventIcs(event);
          setOpen(false);
        }}
        className={
          variant === 'button'
            ? 'w-full flex items-center px-4 py-3 text-white/70 hover:text-brand-primary hover:bg-white/5 transition-colors text-xs font-bold uppercase tracking-widest text-left'
            : 'flex items-center text-white/40 hover:text-brand-primary transition-colors text-left'
        }
      >
        <Download className={variant === 'button' ? 'w-4 h-4 mr-3' : 'w-3.5 h-3.5 mr-3'} />
        Apple / Outlook (.ics)
      </button>
    </>
  );

  if (variant === 'button') {
    return (
      <div className={`relative ${className ?? ''}`}>
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          aria-expanded={open}
          className="w-full flex items-center justify-center bg-white text-black py-4 font-black uppercase tracking-tighter italic text-xs hover:bg-brand-primary transition-all"
        >
          <CalendarPlus className="w-4 h-4 mr-2" />
          Calendar
        </button>
        {open && (
          <>
            {/* click-away backdrop */}
            <div className="fixed inset-0 z-40" onClick={() => setOpen(false)} />
            <div className="absolute left-0 right-0 bottom-full mb-2 z-50 flex flex-col bg-neutral-900 border border-white/10 shadow-2xl">
              {options}
            </div>
          </>
        )}
      </div>
    );
  }

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
      {open && <div className="mt-3 ml-7 flex flex-col space-y-3">{options}</div>}
    </div>
  );
}
