// ArtistLinks — renders one performer's configured streaming + social links as
// a compact icon row. Driven by an ArtistLink row; normalizes each value to a
// real destination via artistLinkHref. Renders nothing when the artist has no
// links, so callers can drop it in unconditionally.

import {
  Music2,
  Music,
  Music4,
  CalendarDays,
  Instagram,
  Twitter,
  Youtube,
  Globe,
} from 'lucide-react';
import type { ArtistLink } from '../types';
import { ARTIST_PLATFORMS, ArtistPlatform, artistLinkHref } from '../lib/artistLinks';

const ICON: Record<ArtistPlatform, typeof Music2> = {
  spotify: Music2,
  appleMusic: Music,
  bandsintown: CalendarDays,
  instagram: Instagram,
  x: Twitter,
  tiktok: Music4,
  youtube: Youtube,
  website: Globe,
};

interface Props {
  artist: ArtistLink;
  className?: string;
  iconClassName?: string;
}

export default function ArtistLinks({ artist, className, iconClassName }: Props) {
  const links = ARTIST_PLATFORMS.map(({ key, label }) => {
    const raw = artist[key];
    if (!raw) return null;
    const href = artistLinkHref(key, raw);
    if (!href) return null;
    const Icon = ICON[key];
    return (
      <a
        key={key}
        href={href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={`${artist.name} on ${label}`}
        title={label}
        className={iconClassName ?? 'text-white/40 hover:text-brand-primary transition-colors'}
      >
        <Icon className="w-4 h-4" />
      </a>
    );
  }).filter(Boolean);

  if (links.length === 0) return null;
  return <div className={className ?? 'flex items-center gap-3'}>{links}</div>;
}
