// Self-serve RSVP release — attendee-side eligibility (D4-OPS-22).
//
// Mirrors the gates in exos_release_ticket (mig 20260911131000) so the pass
// only offers "release my seat" when the server would accept it. The RPC is
// the authority; this decides whether to show the button and which reason to
// explain when it is hidden.

import type { Event, Ticket } from '../types';

export type ReleaseBlock =
  | 'not-active'
  | 'in-transfer'
  | 'paid'
  | 'cancelled'
  | 'policy-off'
  | 'started'
  | 'cutoff';

export interface ReleaseEligibility {
  ok: boolean;
  reason?: ReleaseBlock;
  /** When blocked by the cutoff: the instant releases closed. */
  closesAt?: Date;
}

const HOUR = 3600_000;

function eventMs(e: Event | undefined): number {
  try {
    return e?.date?.toDate ? e.date.toDate().getTime() : 0;
  } catch {
    return 0;
  }
}

export function canHolderRelease(ticket: Ticket, event: Event | undefined, now: number = Date.now()): ReleaseEligibility {
  if (ticket.status !== 'active') return { ok: false, reason: 'not-active' };
  if (ticket.pendingTransferId) return { ok: false, reason: 'in-transfer' };
  if ((ticket.pricePaid ?? 0) > 0) return { ok: false, reason: 'paid' };
  if (!event) return { ok: true };
  if (event.status === 'cancelled') return { ok: false, reason: 'cancelled' };
  if (event.allowHolderRelease === false) return { ok: false, reason: 'policy-off' };
  const at = eventMs(event);
  if (at && at <= now) return { ok: false, reason: 'started' };
  const cutoffHours = event.releaseCutoffHours ?? 0;
  if (at && cutoffHours > 0) {
    const closesAt = at - cutoffHours * HOUR;
    if (closesAt <= now) return { ok: false, reason: 'cutoff', closesAt: new Date(closesAt) };
    return { ok: true, closesAt: new Date(closesAt) };
  }
  return { ok: true };
}
