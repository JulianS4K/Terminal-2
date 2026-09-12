// My Tickets grouping helpers — pure, unit-tested.
//
// A "group" is one event's worth of the viewer's tickets. The wallet shows two
// tabs: ACTIVE (something here can still get you in) and ARCHIVE (the event is
// over, or every pass is used / voided). Rules are deliberately simple and
// event-time based so they hold offline and need no server flag.

import type { Event, Ticket } from '../types';

export type TicketWithEvent = Ticket & { event?: Event };

/** How long after the start time an event still counts as "on" (late shows). */
export const EVENT_GRACE_MS = 6 * 3600_000;

function eventMs(e: Event | undefined): number {
  try {
    return e?.date?.toDate ? e.date.toDate().getTime() : 0;
  } catch {
    return 0;
  }
}

/** Passes in this group that can still be scanned (active, not in transfer). */
export function activeCount(tickets: TicketWithEvent[]): number {
  return tickets.filter((t) => t.status === 'active' && !t.pendingTransferId).length;
}

/** True when the group belongs in the ARCHIVE tab. */
export function isArchived(tickets: TicketWithEvent[], now: number = Date.now()): boolean {
  if (tickets.length === 0) return true;
  const ev = tickets[0].event;
  if (ev?.status === 'cancelled') return true;
  const at = eventMs(ev);
  if (at && at + EVENT_GRACE_MS < now) return true;
  return tickets.every((t) => t.status === 'used' || t.status === 'voided');
}

/** Short status word for the card stamp. */
export function groupStamp(tickets: TicketWithEvent[], now: number = Date.now()): 'active' | 'used' | 'voided' | 'past' | 'transfer' {
  const ev = tickets[0]?.event;
  if (ev?.status === 'cancelled') return 'voided';
  const at = eventMs(ev);
  if (at && at + EVENT_GRACE_MS < now) return 'past';
  if (activeCount(tickets) > 0) return 'active';
  if (tickets.some((t) => t.pendingTransferId)) return 'transfer';
  if (tickets.every((t) => t.status === 'voided')) return 'voided';
  return 'used';
}

/** Split grouped tickets into the two tabs, active first by soonest event. */
export function splitGroups<T extends TicketWithEvent>(
  grouped: Record<string, T[]>,
  now: number = Date.now(),
): { active: [string, T[]][]; archive: [string, T[]][] } {
  const active: [string, T[]][] = [];
  const archive: [string, T[]][] = [];
  for (const [id, list] of Object.entries(grouped)) {
    (isArchived(list, now) ? archive : active).push([id, list]);
  }
  active.sort((a, b) => (eventMs(a[1][0]?.event) || Infinity) - (eventMs(b[1][0]?.event) || Infinity));
  archive.sort((a, b) => (eventMs(b[1][0]?.event) || 0) - (eventMs(a[1][0]?.event) || 0));
  return { active, archive };
}
