// Venue directions — "how do I actually get there".
//
// An attendee holding a ticket has exactly two questions on the day: when,
// and where. The pass answered the first and printed the venue name for the
// second, which is not an answer — it is a string to retype into a maps app.
//
// This builds a deep link instead. The URL forms are the documented universal
// ones, so they work whether or not the native app is installed:
//   * Apple    — https://maps.apple.com/?daddr=…  (opens Maps on iOS/macOS)
//   * Everyone — https://www.google.com/maps/dir/?api=1&destination=…
//
// Platform detection is deliberately a separate, injectable argument: the URL
// builder stays pure and testable, and a caller can force either form.

import type { Event } from '../types';

export type MapsPlatform = 'apple' | 'other';

/**
 * The venue as one lookup-friendly line: display name first (a maps search
 * resolves "Brooklyn Steel" better than its street number alone), then the
 * structured address parts that disambiguate it.
 *
 * Shared with the calendar exporters so a pass, an .ics and a directions link
 * never disagree about where the event is.
 */
export function venueAddress(event: Pick<Event, 'location' | 'address'>): string {
  return [
    event.location,
    event.address?.street,
    event.address?.city,
    event.address?.region,
    event.address?.postal,
  ]
    .map((s) => (s ?? '').trim())
    .filter(Boolean)
    .join(', ');
}

/**
 * Best-effort platform sniff for choosing the maps host. Apple platforms get
 * Apple Maps because that is the one guaranteed to be installed there; every
 * other platform gets Google, which resolves in a browser when no app is
 * present. Returns 'other' anywhere `navigator` is missing (SSR, tests).
 */
export function detectMapsPlatform(ua?: string): MapsPlatform {
  const s =
    ua ?? (typeof navigator === 'undefined' ? '' : navigator.userAgent || '');
  // iPadOS 13+ reports a desktop Safari UA, so the platform string is checked
  // too — an iPad with a trackpad is still an Apple Maps device.
  const platform =
    typeof navigator === 'undefined'
      ? ''
      : (navigator as { platform?: string }).platform || '';
  if (/iPhone|iPad|iPod|Macintosh/i.test(s) || /Mac|iPhone|iPad/i.test(platform)) {
    return 'apple';
  }
  return 'other';
}

/**
 * A directions deep link for this event's venue, or null when the event
 * carries no location at all (an online-only event, or one the organizer
 * never filled in) — callers should render nothing rather than a dead link.
 */
export function directionsUrl(
  event: Pick<Event, 'location' | 'address'>,
  platform: MapsPlatform = 'other',
): string | null {
  const dest = venueAddress(event);
  if (!dest) return null;
  const q = encodeURIComponent(dest);
  return platform === 'apple'
    ? `https://maps.apple.com/?daddr=${q}`
    : `https://www.google.com/maps/dir/?api=1&destination=${q}`;
}
