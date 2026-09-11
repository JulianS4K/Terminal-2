// Recurring / timed-entry series — PURE occurrence generator (D4-OPS-27).
//
// Turns an organizer's rule into the list of UTC start instants the
// `exos_create_event_series` RPC clones the template into. All wall-clock
// arithmetic happens in the EVENT's timezone via lib/datetime, so "every
// Friday at 20:00" stays 20:00 across a DST change instead of drifting an hour.
//
// No Supabase import; unit-tested in seriesModel.test.ts. The RPC wrapper is
// in ./series.ts.

import { utcToZonedWallClock, zonedWallClockToUtc } from './datetime';

export type SeriesKind = 'recurring' | 'timed-entry';

/** 0 = Sunday … 6 = Saturday (JS convention). */
export type Weekday = 0 | 1 | 2 | 3 | 4 | 5 | 6;

export interface RecurringRule {
  kind: 'recurring';
  /** Wall-clock start of the template ("YYYY-MM-DDTHH:MM"), in `timezone`. */
  start: string;
  timezone: string;
  freq: 'daily' | 'weekly';
  /** Every N days / weeks (1 = every). */
  interval: number;
  /** For weekly: which weekdays fire. Empty = the start's weekday. */
  weekdays?: Weekday[];
  /** Stop after this many NEW occurrences (template excluded). */
  count?: number;
  /** Or stop at this local date ("YYYY-MM-DD", inclusive). */
  until?: string;
}

export interface TimedEntryRule {
  kind: 'timed-entry';
  /** Local dates ("YYYY-MM-DD") that get slots. */
  days: string[];
  timezone: string;
  /** First slot wall-clock ("HH:MM"). */
  firstSlot: string;
  /** Minutes between slot starts. */
  slotMinutes: number;
  /** Slots per day. */
  slotsPerDay: number;
}

export type SeriesRule = RecurringRule | TimedEntryRule;

export const MAX_OCCURRENCES = 200;

const pad = (n: number) => String(n).padStart(2, '0');

/** Add whole days to a local calendar date string, DST-agnostic. */
export function addLocalDays(ymd: string, days: number): string {
  const [y, m, d] = ymd.split('-').map(Number);
  const t = new Date(Date.UTC(y, m - 1, d + days));
  return `${t.getUTCFullYear()}-${pad(t.getUTCMonth() + 1)}-${pad(t.getUTCDate())}`;
}

/** JS weekday of a local calendar date string. */
export function localWeekday(ymd: string): Weekday {
  const [y, m, d] = ymd.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay() as Weekday;
}

/**
 * Recurring occurrences AFTER the template's start (the template itself is
 * member 0 and is never regenerated). Capped at MAX_OCCURRENCES.
 */
export function generateRecurring(rule: RecurringRule): Date[] {
  const m = rule.start.match(/^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/);
  if (!m) return [];
  const [, startDay, hhmm] = m;
  const interval = Math.max(1, Math.floor(rule.interval || 1));
  const count = rule.count && rule.count > 0 ? Math.min(MAX_OCCURRENCES, Math.floor(rule.count)) : undefined;
  const until = rule.until && /^\d{4}-\d{2}-\d{2}$/.test(rule.until) ? rule.until : undefined;
  if (!count && !until) return [];

  const out: Date[] = [];
  const push = (ymd: string) => {
    const utc = zonedWallClockToUtc(`${ymd}T${hhmm}:00`, rule.timezone);
    if (utc) out.push(utc);
  };

  if (rule.freq === 'daily') {
    let day = startDay;
    for (let guard = 0; guard < 5000 && out.length < MAX_OCCURRENCES; guard++) {
      day = addLocalDays(day, interval);
      if (until && day > until) break;
      push(day);
      if (count && out.length >= count) break;
    }
    return out;
  }

  // weekly: walk day by day from the template, firing on the chosen weekdays;
  // `interval` skips whole weeks (weeks counted from the template's week).
  const weekdays = new Set<Weekday>(rule.weekdays && rule.weekdays.length ? rule.weekdays : [localWeekday(startDay)]);
  const startWd = localWeekday(startDay);
  let day = startDay;
  let dayOffset = 0;
  for (let guard = 0; guard < 5000 && out.length < MAX_OCCURRENCES; guard++) {
    day = addLocalDays(day, 1);
    dayOffset += 1;
    if (until && day > until) break;
    // Week index relative to the template's week (week starts on the template's weekday).
    const weekIdx = Math.floor((dayOffset + startWd - startWd) / 7);
    if (weekIdx % interval !== 0) continue;
    if (!weekdays.has(localWeekday(day))) continue;
    push(day);
    if (count && out.length >= count) break;
  }
  return out;
}

/** Timed-entry slots: every listed day × slotsPerDay, slotMinutes apart. */
export function generateTimedEntry(rule: TimedEntryRule): Date[] {
  const m = rule.firstSlot.match(/^(\d{2}):(\d{2})$/);
  if (!m) return [];
  const [, hh, mm] = m;
  const slots = Math.max(1, Math.floor(rule.slotsPerDay || 1));
  const step = Math.max(5, Math.floor(rule.slotMinutes || 60));
  const out: Date[] = [];
  const days = Array.from(new Set(rule.days.filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d)))).sort();
  for (const day of days) {
    const first = zonedWallClockToUtc(`${day}T${hh}:${mm}:00`, rule.timezone);
    if (!first) continue;
    for (let i = 0; i < slots; i++) {
      if (out.length >= MAX_OCCURRENCES) return out;
      // Slots within a day are a fixed number of minutes apart (a slot that
      // straddles a DST change keeps its interval — that is what a museum
      // entry grid means).
      out.push(new Date(first.getTime() + i * step * 60_000));
    }
  }
  return out;
}

export function generateOccurrences(rule: SeriesRule): Date[] {
  return rule.kind === 'recurring' ? generateRecurring(rule) : generateTimedEntry(rule);
}

/** Local calendar dates between two "YYYY-MM-DD" strings, inclusive. */
export function localDateRange(from: string, to: string, max = MAX_OCCURRENCES): string[] {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to) || to < from) return [];
  const out: string[] = [];
  let d = from;
  while (d <= to && out.length < max) {
    out.push(d);
    d = addLocalDays(d, 1);
  }
  return out;
}

/** Wall-clock label for a preview row. */
export function occurrenceLabel(at: Date, timezone: string): string {
  return utcToZonedWallClock(at, timezone).replace('T', ' ');
}
