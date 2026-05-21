// EmbedEvent — chromeless event card meant to be loaded in an
// iframe on the venue's own website.
//
// Lives at /embed/event/:eventId. Renders a single card with the
// event title, date, location, and a single "Get Tickets" CTA that
// opens the parent Exos page in a new tab (so the buyer keeps
// the venue's site open behind it).
//
// What this view DOES NOT render:
//   * Navbar, footer, auth modal — chrome is the host site's job.
//   * Toast queue (no transactional UI happens inside the embed).
//
// What it DOES carry:
//   * The org's theme via ThemeProvider, so the embed visually fits
//     the venue's site even without a custom CSS pass on the host.
//   * postMessage("vibepass:resize", height) to the parent so the
//     iframe can self-size. The host snippet listens for it.
//
// Security:
//   * Only published events are rendered — the read rule already
//     blocks drafts/cancelled to anyone but the organizer.
//   * No sign-in required to view.
//   * The CTA opens target=_blank rel=noopener so the host site
//     can't be navigated by Exos code.

import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { Event, Organization } from '../types';
import { getPublicEvent } from '../lib/events';
import { getPublicOrg } from '../lib/orgs';
import { ThemeProvider, useTheme } from '../context/ThemeContext';
import { formatInTz } from '../lib/datetime';

function EmbedInner({ event, org }: { event: Event; org: Organization | null }) {
  const { theme } = useTheme();
  const buyHref = `${window.location.origin}/event/${event.id}?utm_source=embed&utm_medium=iframe&utm_content=${org?.slug ?? 'unknown'}`;

  // Self-resize: tell the parent how tall the embed is so it can set
  // the iframe height. We measure on mount + on every window resize.
  useEffect(() => {
    function postSize() {
      const h = document.documentElement.scrollHeight;
      try {
        window.parent.postMessage({ type: 'vibepass:resize', height: h }, '*');
      } catch {
        /* parent unavailable (e.g., direct visit) — no-op */
      }
    }
    postSize();
    window.addEventListener('resize', postSize);
    // ResizeObserver if available — tracks content reflow more reliably than 'resize' alone.
    let ro: ResizeObserver | undefined;
    if (typeof ResizeObserver !== 'undefined') {
      ro = new ResizeObserver(postSize);
      ro.observe(document.documentElement);
    }
    return () => {
      window.removeEventListener('resize', postSize);
      ro?.disconnect();
    };
  }, []);

  const remaining = Math.max(0, (event.totalTickets || 0) - (event.ticketsSold || 0));
  const soldOut = remaining === 0 && (event.totalTickets || 0) > 0;

  return (
    <div
      className="bg-black text-white p-6 md:p-8 border"
      style={{
        borderColor: theme.primary,
        borderLeftWidth: '4px',
      }}
    >
      <div className="flex items-start justify-between gap-4">
        <div className="flex-1 min-w-0">
          {theme.logoUrl && (
            <img
              src={theme.logoUrl}
              alt={`${org?.name ?? 'Organizer'} logo`}
              className="h-8 mb-3"
            />
          )}
          <h2 className="text-2xl md:text-3xl font-black uppercase italic tracking-tighter text-white mb-2">
            {event.title}
          </h2>
          <p className="text-[10px] text-white/40 font-bold uppercase tracking-widest mb-1">
            {event.date
              ? formatInTz(event.date.toDate(), event.timezone || 'UTC')
              : 'TBA'}
          </p>
          <p className="text-sm text-white/60">{event.location}</p>
        </div>
      </div>

      {soldOut ? (
        <div className="mt-6 px-6 py-3 bg-white/5 text-white/40 text-center font-black uppercase tracking-tighter italic">
          Sold Out
        </div>
      ) : (
        <a
          href={buyHref}
          target="_blank"
          rel="noopener noreferrer"
          className="mt-6 inline-block w-full md:w-auto px-8 py-3 font-black uppercase tracking-tighter italic text-center transition-all"
          style={{ background: theme.primary, color: '#000' }}
        >
          Get Tickets →
        </a>
      )}
    </div>
  );
}

export default function EmbedEvent() {
  const { eventId } = useParams<{ eventId: string }>();
  const [event, setEvent] = useState<Event | null>(null);
  const [org, setOrg] = useState<Organization | null>(null);
  const [status, setStatus] = useState<'loading' | 'found' | 'not-found'>('loading');

  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!eventId) {
        setStatus('not-found');
        return;
      }
      try {
        // Public view returns published-only, so drafts/cancelled → null → not-found.
        const ev = await getPublicEvent(eventId);
        if (cancelled) return;
        if (!ev) {
          setStatus('not-found');
          return;
        }
        setEvent(ev);
        if (ev.orgId) {
          const o = await getPublicOrg(ev.orgId);
          if (!cancelled) setOrg(o);
        }
        setStatus('found');
      } catch (err) {
        console.error('Embed load failed:', err);
        if (!cancelled) setStatus('not-found');
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [eventId]);

  if (status === 'loading') {
    return (
      <div className="bg-black text-white/50 p-8 text-center font-bold uppercase tracking-[0.3em] animate-pulse">
        Loading…
      </div>
    );
  }
  if (status === 'not-found') {
    return (
      <div className="bg-black text-white/50 p-8 text-center text-sm">
        Event unavailable.
      </div>
    );
  }

  return (
    <ThemeProvider org={org}>
      <EmbedInner event={event!} org={org} />
    </ThemeProvider>
  );
}
