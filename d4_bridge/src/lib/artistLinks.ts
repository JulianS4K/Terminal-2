// Artist-link helpers — the single source of truth for which platforms an
// organizer can attach to a performer, how each raw value normalizes to a real
// URL, and how to look up a performer's links by name.
//
// Mirrors the handle-or-URL philosophy of components/SocialLinks.socialHref:
// a value may be a full URL (used as-is) or a bare handle/name (expanded to
// the platform's canonical path, or a platform search URL where a bare handle
// has no stable path — Spotify / Apple Music / Bandsintown). Public
// handles/URLs only; never secrets.

import type { ArtistLink } from '../types';

// The link fields on ArtistLink (everything except `name`).
export type ArtistPlatform = Exclude<keyof ArtistLink, 'name'>;

export interface PlatformMeta {
  key: ArtistPlatform;
  label: string;
  // Placeholder shown in the editor input — communicates URL-vs-handle.
  placeholder: string;
}

// Render + editor order. One list drives both the icon row and the form.
export const ARTIST_PLATFORMS: PlatformMeta[] = [
  { key: 'spotify', label: 'Spotify', placeholder: 'Spotify artist URL' },
  { key: 'appleMusic', label: 'Apple Music', placeholder: 'Apple Music URL' },
  { key: 'bandsintown', label: 'Bandsintown', placeholder: 'Bandsintown URL' },
  { key: 'instagram', label: 'Instagram', placeholder: '@handle or URL' },
  { key: 'x', label: 'X', placeholder: '@handle or URL' },
  { key: 'tiktok', label: 'TikTok', placeholder: '@handle or URL' },
  { key: 'youtube', label: 'YouTube', placeholder: '@handle or URL' },
  { key: 'website', label: 'Website', placeholder: 'example.com or URL' },
];

// Max characters per link value — matches the editor cap; long enough for any
// real URL, short enough to bound row size.
export const ARTIST_LINK_MAX_LEN = 300;

/**
 * Normalize a raw link value to a real destination URL. Full URLs pass
 * through untouched; bare handles expand to the platform path; platforms with
 * no stable bare-handle path (Spotify / Apple Music / Bandsintown) fall back
 * to that platform's search for the typed text. Returns '' for empty input.
 */
export function artistLinkHref(platform: ArtistPlatform, raw: string): string {
  const v = raw.trim();
  if (!v) return '';
  if (/^https?:\/\//i.test(v)) return v;
  const handle = v.replace(/^@/, '');
  const q = encodeURIComponent(v);
  switch (platform) {
    case 'instagram':
      return `https://instagram.com/${handle}`;
    case 'x':
      return `https://x.com/${handle}`;
    case 'tiktok':
      return `https://tiktok.com/@${handle}`;
    case 'youtube':
      return `https://youtube.com/@${handle}`;
    case 'spotify':
      return `https://open.spotify.com/search/${q}`;
    case 'appleMusic':
      return `https://music.apple.com/us/search?term=${q}`;
    case 'bandsintown':
      return `https://www.bandsintown.com/?query=${q}`;
    case 'website':
      return `https://${v}`;
    default:
      return v;
  }
}

// True when a row has at least one non-empty link value.
export function hasAnyLink(entry: ArtistLink): boolean {
  return ARTIST_PLATFORMS.some(({ key }) => Boolean(entry[key]?.trim()));
}

/**
 * Find the link row for a performer name. Case-insensitive, trim-insensitive
 * so an editor rename that only changes case/whitespace still matches. Returns
 * undefined when the artist has no links (or the list is absent).
 */
export function linksForArtist(
  name: string,
  links?: ArtistLink[],
): ArtistLink | undefined {
  if (!links?.length) return undefined;
  const needle = name.trim().toLowerCase();
  return links.find((l) => l.name.trim().toLowerCase() === needle);
}

/**
 * Drop empty rows (no name, or no links) and trim values — the shape we
 * persist. Returns undefined when nothing survives so the caller can omit the
 * field entirely rather than storing `[]`.
 */
export function normalizeArtistLinks(links: ArtistLink[]): ArtistLink[] | undefined {
  const out: ArtistLink[] = [];
  for (const l of links) {
    const name = l.name.trim();
    if (!name || !hasAnyLink(l)) continue;
    const row: ArtistLink = { name };
    for (const { key } of ARTIST_PLATFORMS) {
      const val = l[key]?.trim();
      if (val) row[key] = val.slice(0, ARTIST_LINK_MAX_LEN);
    }
    out.push(row);
  }
  return out.length ? out : undefined;
}
