// Exos (Bridge / D4) — optional set-times (lineup schedule) normalization.
//
// Set times are entered in the venue's wall-clock (a `datetime-local` string)
// and stored as UTC ISO instants in the exos_events.set_times jsonb column
// (mig 20260713150000). These pure helpers convert between the editor's row
// shape and the stored shape, and enforce the caps the DB CHECK doesn't
// (non-empty label, valid instant, ordering, count/length limits).

import { zonedWallClockToUtc, utcToZonedWallClock } from './datetime';
import type { Timestamp } from './timestamp';

/** One editor row: a label + a `datetime-local` wall-clock string. */
export interface SetTimeRow {
  label: string;
  local: string;
}

/** One stored set time: a label + a UTC ISO instant. */
export interface StoredSetTime {
  label: string;
  at: string;
}

export const MAX_SET_TIMES = 24;
export const SET_TIME_LABEL_MAX = 80;

/**
 * Editor rows → storable set times. Drops incomplete/invalid rows (missing
 * label or time, unparseable instant), trims + truncates labels, converts venue
 * wall-clock → UTC ISO, sorts chronologically, and caps the count. Pure.
 */
export function normalizeSetTimes(rows: SetTimeRow[], tz: string | undefined): StoredSetTime[] {
  const zone = tz || 'UTC';
  const out: StoredSetTime[] = [];
  for (const r of rows) {
    const label = (r.label ?? '').trim().slice(0, SET_TIME_LABEL_MAX);
    if (!label || !r.local) continue;
    const utc = zonedWallClockToUtc(r.local, zone);
    if (!utc || Number.isNaN(utc.getTime())) continue;
    out.push({ label, at: utc.toISOString() });
  }
  // ISO-8601 is lexicographically chronological, so a string sort orders them.
  out.sort((a, b) => a.at.localeCompare(b.at));
  return out.slice(0, MAX_SET_TIMES);
}

/**
 * Stored set times → editor rows (UTC instant → venue wall-clock string), so the
 * edit form shows the times the organizer originally entered rather than the
 * viewer-local interpretation. Skips entries without a usable Timestamp.
 */
export function setTimesToRows(
  setTimes: { label: string; at: Timestamp }[] | undefined,
  tz: string | undefined,
): SetTimeRow[] {
  if (!setTimes?.length) return [];
  const zone = tz || 'UTC';
  return setTimes
    .filter((s) => s && s.at && typeof s.at.toDate === 'function' && !Number.isNaN(s.at.toDate().getTime()))
    .map((s) => ({ label: s.label ?? '', local: utcToZonedWallClock(s.at.toDate(), zone) }));
}
