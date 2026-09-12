// DirectionsLink — one tap from a pass to turn-by-turn navigation.
//
// Renders nothing when the event has no venue (online-only, or an organizer
// who left the field blank): a dead maps link is worse than no link. The
// platform is sniffed once per mount so an iPhone gets Apple Maps and
// everything else gets Google (lib/directions).

import { useMemo } from 'react';
import { Navigation } from 'lucide-react';
import type { Event } from '../types';
import { directionsUrl, detectMapsPlatform } from '../lib/directions';
import type { DictKey } from '../lib/i18n/dict';

interface Props {
  event: Pick<Event, 'location' | 'address'>;
  /** The `useT()` translator from the calling view. */
  t: (key: DictKey, vars?: Record<string, string | number>) => string;
  /** `button` is a full-width bar (pass actions); `inline` is a quiet text link. */
  variant?: 'button' | 'inline';
  className?: string;
}

export default function DirectionsLink({ event, t, variant = 'inline', className = '' }: Props) {
  const href = useMemo(() => directionsUrl(event, detectMapsPlatform()), [event]);
  if (!href) return null;

  const base =
    variant === 'button'
      ? 'type flex items-center justify-center gap-2 bg-white/5 border border-white/10 text-white/60 py-3.5 text-[11px] uppercase tracking-widest hover:bg-white hover:text-black transition-colors'
      : 'type inline-flex items-center gap-1.5 text-[11px] uppercase tracking-widest text-white/50 hover:text-brand-primary transition-colors';

  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className={`${base} ${className}`.trim()}
    >
      <Navigation className="w-3.5 h-3.5 text-brand-primary" aria-hidden="true" />
      {t('event.directions')}
    </a>
  );
}
