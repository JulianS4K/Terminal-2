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
import { publicUrl } from '../lib/utils';

function EmbedInner({ event, org }: { event: Event; org: Organization | null }) {
  const { theme } = useTheme();
  const buyHref = `${publicUrl(`event/${event.id}`)}?utm_source=embed&utm_medium=iframe&utm_content=${org?.slug ?? 'unknown'}`;

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
      className="group max-w-md bg-[#0a0a0a] text-white overflow-hidden border"
      style={{
        borderColor: theme.primary,
        borderLeftWidth: '4px',
      }}
    >
      {event.image ? (
        <div className="relative h-44 overflow-hidden">
          <img src={event.image} className="xerox w-full h-full object-cover" alt="" />
          <div className="absolute inset-0 bg-gradient-to-t from-[#0a0a0a] via-transparent to-transparent" />
          {theme.logoUrl && (
            <img
              src={theme.logoUrl}
              alt={`${org?.name ?? 'Organizer'} logo`}
              className="absolute top-3 right-3 h-7"
            />
          )}
          <div className="absolute bottom-3 left-4 right-4">
            <h2 className="disp text-3xl leading-[0.9] tracking-tight text-white">{event.title}</h2>
          </div>
        </div>
      ) : (
        <div className="p-5 pb-0">
          {theme.logoUrl && (
            <img
              src={theme.logoUrl}
              alt={`${org?.name ?? 'Organizer'} logo`}
              className="h-8 mb-3"
            />
          )}
          <h2 className="disp text-3xl leading-[0.9] tracking-tight text-white">{event.title}</h2>
        </div>
      )}

      <div className="p-5">
        <div className="flex items-center justify-between gap-3 mb-4 type text-[11px] uppercase tracking-widest text-white/50">
          <span>
            {event.date
              ? formatInTz(event.date.toDate(), event.timezone || 'UTC')
              : 'TBA'}
          </span>
          <span className="text-right">{event.location}</span>
        </div>

        {soldOut ? (
          <div className="px-6 py-3 bg-white/5 text-white/40 text-center disp text-lg tracking-wide">
            SOLD OUT
          </div>
        ) : (
          <a
            href={buyHref}
            target="_blank"
            rel="noopener noreferrer"
            className="disp block w-full py-3 text-lg tracking-wide text-center hover:scale-[1.01] transition-transform"
            style={{ background: theme.primary, color: '#000' }}
          >
            GET TICKETS →
          </a>
        )}

        <p className="type text-[9px] uppercase tracking-[0.25em] text-white/25 text-center mt-3">▲ secured by exos</p>
      </div>
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
      <div className="bg-black text-white/40 p-8 text-center type text-[11px] uppercase tracking-[0.3em] animate-pulse">
        Loading…
      </div>
    );
  }
  if (status === 'not-found') {
    return (
      <div className="bg-black text-white/40 p-8 text-center type text-xs uppercase tracking-widest">
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
