// Add-to-calendar helpers — build a Google Calendar "add event" URL and an
// RFC-5545 .ics document from an Event, with no backend or third-party SDK.
//
// Times are emitted in UTC (the compact `YYYYMMDDTHHMMSSZ` form both Google and
// Apple/Outlook accept), so we don't have to ship VTIMEZONE blocks — the wall
// clock the attendee sees is whatever their calendar renders the UTC instant as,
// which matches how the rest of the app stores the event (a single instant).

import type { Event } from '../types';
import { publicUrl } from './utils';

// When an event has no explicit end time, assume this length so the calendar
// block isn't zero-width (most ticketed events run a few hours).
const DEFAULT_DURATION_MS = 2 * 60 * 60 * 1000;

export interface CalendarFields {
  title: string;
  start: Date;
  end: Date;
  location: string;
  description: string;
  url: string;
}

function toDate(v: unknown): Date | null {
  if (!v) return null;
  // Timestamp shim (has toDate) or an ISO string / Date.
  if (typeof (v as { toDate?: () => Date }).toDate === 'function') return (v as { toDate: () => Date }).toDate();
  const d = new Date(v as string | number | Date);
  return isNaN(d.getTime()) ? null : d;
}

// Normalize an Event into the fields both exporters need. Returns null when the
// event has no usable start instant (nothing to add).
export function eventCalendarFields(event: Event): CalendarFields | null {
  const start = toDate(event.timing?.startTime) ?? toDate(event.date);
  if (!start) return null;
  const rawEnd = toDate(event.timing?.endTime);
  const end = rawEnd && rawEnd.getTime() > start.getTime() ? rawEnd : new Date(start.getTime() + DEFAULT_DURATION_MS);

  const location = [
    event.location,
    event.address?.street,
    event.address?.city,
    event.address?.region,
    event.address?.postal,
  ]
    .map((s) => (s ?? '').trim())
    .filter(Boolean)
    .join(', ');

  const url = publicUrl(`event/${event.id}`);
  const description = [event.description?.trim(), url].filter(Boolean).join('\n\n');

  return { title: event.title || 'Event', start, end, location, description, url };
}

const pad = (n: number) => String(n).padStart(2, '0');

// Compact UTC stamp: 20260704T193000Z
function toIcsUtc(d: Date): string {
  return (
    `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}` +
    `T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`
  );
}

// https://calendar.google.com/calendar/render?action=TEMPLATE&text=…&dates=…/…
export function googleCalendarUrl(event: Event): string | null {
  const f = eventCalendarFields(event);
  if (!f) return null;
  const params = new URLSearchParams({
    action: 'TEMPLATE',
    text: f.title,
    dates: `${toIcsUtc(f.start)}/${toIcsUtc(f.end)}`,
    details: f.description,
    location: f.location,
  });
  return `https://calendar.google.com/calendar/render?${params.toString()}`;
}

// Escape a value for an ICS text field (RFC 5545 §3.3.11): backslash, comma,
// semicolon are escaped; newlines become the literal \n sequence.
function icsEscape(s: string): string {
  return s
    .replace(/\\/g, '\\\\')
    .replace(/;/g, '\\;')
    .replace(/,/g, '\\,')
    .replace(/\r?\n/g, '\\n');
}

// Fold a content line to <=75 octets per RFC 5545 §3.1 (continuations start with
// a space). ASCII-approximated by character count — adequate for our fields.
function foldLine(line: string): string {
  if (line.length <= 75) return line;
  const parts: string[] = [];
  let rest = line;
  parts.push(rest.slice(0, 75));
  rest = rest.slice(75);
  while (rest.length > 74) {
    parts.push(' ' + rest.slice(0, 74));
    rest = rest.slice(74);
  }
  if (rest.length) parts.push(' ' + rest);
  return parts.join('\r\n');
}

// Build a single-event VCALENDAR document.
export function icsForEvent(event: Event, stamp: Date = new Date()): string | null {
  const f = eventCalendarFields(event);
  if (!f) return null;
  const lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Vibepass//Bridge//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'BEGIN:VEVENT',
    `UID:${event.id}@bridge.vibepass`,
    `DTSTAMP:${toIcsUtc(stamp)}`,
    `DTSTART:${toIcsUtc(f.start)}`,
    `DTEND:${toIcsUtc(f.end)}`,
    `SUMMARY:${icsEscape(f.title)}`,
    `DESCRIPTION:${icsEscape(f.description)}`,
    `LOCATION:${icsEscape(f.location)}`,
    `URL:${icsEscape(f.url)}`,
    'END:VEVENT',
    'END:VCALENDAR',
  ];
  return lines.map(foldLine).join('\r\n');
}

// A filesystem-safe .ics filename derived from the event title.
export function icsFilename(event: Event): string {
  const base = (event.title || 'event').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60);
  return `${base || 'event'}.ics`;
}

// Trigger a client-side download of the event's .ics. No-op if the event has no
// usable start instant. Returns whether a file was produced.
export function downloadEventIcs(event: Event): boolean {
  const ics = icsForEvent(event);
  if (!ics) return false;
  const blob = new Blob([ics], { type: 'text/calendar;charset=utf-8' });
  const href = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = href;
  a.download = icsFilename(event);
  document.body.appendChild(a);
  a.click();
  a.remove();
  // Release the object URL on the next tick (after the click is handled).
  setTimeout(() => URL.revokeObjectURL(href), 0);
  return true;
}
