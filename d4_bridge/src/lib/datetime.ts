// Tiny timezone helpers built on Intl.DateTimeFormat.
//
// We intentionally don't pull in date-fns-tz here — the install in this
// project's sandbox is fragile, and we only need two operations:
//
//   1. Convert a wall-clock datetime-local input ("2026-04-28T19:00"),
//      interpreted in a given IANA timezone, to a real UTC instant. This
//      is what we store in Firestore.
//
//   2. Format a UTC instant back into the event's timezone, regardless of
//      the viewer's local zone, so an "8pm show in NY" reads "8pm" to
//      everyone — which is what an organizer means when they pick a
//      time.
//
// Both rely on Intl.DateTimeFormat.formatToParts to read the wall-clock
// components of a UTC moment as observed in a target timezone. DST is
// handled because Intl is doing the offset math for us; we double-check
// after our shift to catch the rare DST-boundary case where the local
// offset and the target offset cross over.

/** Returns the user's current IANA timezone (e.g. "America/New_York"). */
export function getBrowserTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  } catch {
    return 'UTC';
  }
}

/**
 * True once we're within `hours` of `date` (i.e. now >= date − hours).
 * A missing date returns true so we never lock a holder out when the event
 * time is unknown. Used to gate the scannable entry QR to ~24h before doors.
 */
export function isWithinHoursBefore(date: Date | null | undefined, hours: number): boolean {
  if (!date) return true;
  return Date.now() >= date.getTime() - hours * 60 * 60 * 1000;
}

/** Cheap structural check on an IANA timezone string. */
export function isValidTimezone(tz: string): boolean {
  if (!tz) return false;
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/**
 * UTC offset in minutes for the given timezone at the given UTC instant.
 * Positive = ahead of UTC, negative = behind. Differs from
 * Date.prototype.getTimezoneOffset which is the inverse sign.
 */
function offsetMinutes(date: Date, tz: string): number {
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone: tz,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });
  const parts = dtf.formatToParts(date).reduce<Record<string, string>>(
    (acc, p) => {
      if (p.type !== 'literal') acc[p.type] = p.value;
      return acc;
    },
    {},
  );
  const asIfUtc = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(parts.hour),
    Number(parts.minute),
    Number(parts.second),
  );
  return Math.round((asIfUtc - date.getTime()) / 60_000);
}

/**
 * Interpret a `<input type="datetime-local">` string as wall-clock time in
 * the given timezone, and return the UTC instant it refers to.
 *
 * Returns null if the input doesn't parse — caller decides how to surface.
 */
export function zonedWallClockToUtc(
  wallClock: string,
  tz: string,
): Date | null {
  if (!wallClock) return null;
  // Parse as if it were UTC ("2026-04-28T19:00:00Z"); this gives us a Date
  // whose UTC parts match the wall-clock numbers the user typed.
  const m = wallClock.match(
    /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/,
  );
  if (!m) return null;
  const naive = new Date(
    Date.UTC(
      Number(m[1]),
      Number(m[2]) - 1,
      Number(m[3]),
      Number(m[4]),
      Number(m[5]),
      Number(m[6] || '0'),
    ),
  );
  // The actual UTC moment is naive shifted by the negative target offset.
  // First pass:
  let offset = offsetMinutes(naive, tz);
  let utc = new Date(naive.getTime() - offset * 60_000);
  // DST boundary correction: recompute and apply once more if it changed.
  const offset2 = offsetMinutes(utc, tz);
  if (offset2 !== offset) {
    utc = new Date(naive.getTime() - offset2 * 60_000);
  }
  return utc;
}

/**
 * Format a UTC instant in the given timezone. `format` mirrors a couple
 * of the date-fns-tz conveniences we actually use; for richer formatting
 * pass an Intl.DateTimeFormatOptions object via `formatInTz`.
 */
export function formatInTz(
  date: Date | null | undefined,
  tz: string | undefined,
  options: Intl.DateTimeFormatOptions = {
    dateStyle: 'medium',
    timeStyle: 'short',
  },
): string {
  if (!date) return '';
  const zone = tz && isValidTimezone(tz) ? tz : getBrowserTimezone();
  try {
    return new Intl.DateTimeFormat('en-US', { ...options, timeZone: zone }).format(
      date,
    );
  } catch {
    return date.toLocaleString();
  }
}

/**
 * For populating `<input type="datetime-local">` from a UTC Date in a way
 * that matches the wall-clock the organizer originally entered.
 */
export function utcToZonedWallClock(
  date: Date | null | undefined,
  tz: string | undefined,
): string {
  if (!date) return '';
  const zone = tz && isValidTimezone(tz) ? tz : getBrowserTimezone();
  const dtf = new Intl.DateTimeFormat('en-CA', {
    // en-CA gives us yyyy-mm-dd; we then assemble HH:mm.
    timeZone: zone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
  const parts = dtf.formatToParts(date).reduce<Record<string, string>>(
    (acc, p) => {
      if (p.type !== 'literal') acc[p.type] = p.value;
      return acc;
    },
    {},
  );
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}`;
}

/**
 * Format a UTC instant as a TEvo-style `occurs_at_local` string —
 * "YYYY-MM-DDTHH:MM:SS±HH:MM": the local wall-clock in the given timezone with
 * the venue's UTC-offset suffix at that instant. Matches the format stored in
 * the D0 catalog's `public.events.occurs_at_local` (e.g. "2026-05-21T20:00:00-04:00")
 * so Exos primary events are value-consistent with the catalog, not just
 * shape-consistent. Returns '' when `date` is missing.
 */
export function utcToOccursAtLocal(
  date: Date | null | undefined,
  tz: string | undefined,
): string {
  if (!date) return '';
  const zone = tz && isValidTimezone(tz) ? tz : getBrowserTimezone();
  const dtf = new Intl.DateTimeFormat('en-CA', {
    timeZone: zone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });
  const parts = dtf.formatToParts(date).reduce<Record<string, string>>(
    (acc, p) => {
      if (p.type !== 'literal') acc[p.type] = p.value;
      return acc;
    },
    {},
  );
  // Signed minutes ahead of UTC at this instant (DST-correct via Intl).
  const off = offsetMinutes(date, zone);
  const sign = off >= 0 ? '+' : '-';
  const abs = Math.abs(off);
  const oh = String(Math.floor(abs / 60)).padStart(2, '0');
  const om = String(abs % 60).padStart(2, '0');
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}${sign}${oh}:${om}`;
}

/** A short curated list to show in a tz picker without enumerating Intl. */
export const COMMON_TIMEZONES: { value: string; label: string }[] = [
  { value: 'America/New_York', label: 'New York (EST/EDT)' },
  { value: 'America/Chicago', label: 'Chicago (CST/CDT)' },
  { value: 'America/Denver', label: 'Denver (MST/MDT)' },
  { value: 'America/Los_Angeles', label: 'Los Angeles (PST/PDT)' },
  { value: 'America/Phoenix', label: 'Phoenix (no DST)' },
  { value: 'America/Anchorage', label: 'Anchorage' },
  { value: 'Pacific/Honolulu', label: 'Honolulu' },
  { value: 'America/Toronto', label: 'Toronto' },
  { value: 'America/Vancouver', label: 'Vancouver' },
  { value: 'America/Mexico_City', label: 'Mexico City' },
  { value: 'America/Sao_Paulo', label: 'São Paulo' },
  { value: 'Europe/London', label: 'London' },
  { value: 'Europe/Paris', label: 'Paris' },
  { value: 'Europe/Berlin', label: 'Berlin' },
  { value: 'Europe/Madrid', label: 'Madrid' },
  { value: 'Europe/Amsterdam', label: 'Amsterdam' },
  { value: 'Europe/Rome', label: 'Rome' },
  { value: 'Europe/Moscow', label: 'Moscow' },
  { value: 'Africa/Cairo', label: 'Cairo' },
  { value: 'Africa/Johannesburg', label: 'Johannesburg' },
  { value: 'Asia/Dubai', label: 'Dubai' },
  { value: 'Asia/Karachi', label: 'Karachi' },
  { value: 'Asia/Kolkata', label: 'Kolkata' },
  { value: 'Asia/Bangkok', label: 'Bangkok' },
  { value: 'Asia/Singapore', label: 'Singapore' },
  { value: 'Asia/Hong_Kong', label: 'Hong Kong' },
  { value: 'Asia/Shanghai', label: 'Shanghai' },
  { value: 'Asia/Tokyo', label: 'Tokyo' },
  { value: 'Asia/Seoul', label: 'Seoul' },
  { value: 'Australia/Sydney', label: 'Sydney' },
  { value: 'Australia/Melbourne', label: 'Melbourne' },
  { value: 'Pacific/Auckland', label: 'Auckland' },
  { value: 'UTC', label: 'UTC' },
];
