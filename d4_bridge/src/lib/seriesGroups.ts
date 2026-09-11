// Series grouping for browse surfaces (customer side of D4-OPS-27).
//
// exos_public_events carries series_id / series_index. On a list page a
// recurring run ("Friday Nights", 12 dates) should occupy ONE card pointing at
// the next occurrence with a "12 dates" badge, not twelve near-identical cards.
// Pure helpers; the fetch stays in lib/events.

import type { Event } from '../types';

/** Upcoming-ness grace so a show that started an hour ago still counts as "next". */
const GRACE_MS = 3 * 3600_000;

function eventMs(e: Event): number {
  try {
    return e.date?.toDate ? e.date.toDate().getTime() : 0;
  } catch {
    return 0;
  }
}

export interface CollapsedList {
  /** One entry per standalone event, one per series (its next occurrence). Input order kept. */
  list: Event[];
  /** representative event id → number of upcoming dates in its series (≥ 2 only). */
  dates: Map<string, number>;
}

/**
 * Collapse series members to a single representative each. The representative
 * is the next upcoming occurrence (or the earliest, if all have passed); it
 * takes the list position of the series' first member so ordering by date is
 * preserved. Standalone events pass through untouched.
 */
export function collapseSeries(events: Event[], now: number = Date.now()): CollapsedList {
  const bySeries = new Map<string, Event[]>();
  for (const e of events) {
    if (!e.seriesId) continue;
    const arr = bySeries.get(e.seriesId) ?? [];
    arr.push(e);
    bySeries.set(e.seriesId, arr);
  }
  const dates = new Map<string, number>();
  const rep = new Map<string, Event>();
  for (const [sid, members] of bySeries) {
    const sorted = [...members].sort((a, b) => eventMs(a) - eventMs(b));
    const upcoming = sorted.filter((e) => eventMs(e) + GRACE_MS >= now);
    const next = upcoming[0] ?? sorted[0];
    rep.set(sid, next);
    const n = upcoming.length || sorted.length;
    if (n >= 2) dates.set(next.id, n);
  }
  const placed = new Set<string>();
  const list: Event[] = [];
  for (const e of events) {
    if (!e.seriesId) {
      list.push(e);
      continue;
    }
    if (placed.has(e.seriesId)) continue;
    placed.add(e.seriesId);
    list.push(rep.get(e.seriesId)!);
  }
  return { list, dates };
}

/** Upcoming siblings of an event in its series (excluding itself), soonest first. */
export function seriesSiblings(current: Event, members: Event[], now: number = Date.now()): Event[] {
  if (!current.seriesId) return [];
  return members
    .filter((e) => e.seriesId === current.seriesId && e.id !== current.id && eventMs(e) + GRACE_MS >= now)
    .sort((a, b) => eventMs(a) - eventMs(b));
}
