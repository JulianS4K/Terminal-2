// OrgStorefront — the white-label landing page for a Bridge org.
//
// Lives at `/o/:slug`. Resolves the slug via the `slugs/` collection
// (with `org:` prefix), loads the org doc, and renders the org's
// published events with the org's theme applied via ThemeProvider.
//
// Design: the "Exos Storefront" punk/xerox mockup — org-branded sticky
// nav, xerox-halftone hero banner, and a ransom-type event grid. It
// renders bare (no platform Navbar/Footer — see App.tsx ChromeLayout)
// so the org's own chrome is the only chrome, keeping it truly
// white-label. The org's theme colour drives every accent; where an org
// hasn't set one we fall back to the mockup's neon green so a themeless
// storefront matches the reference design pixel-for-pixel.
//
// What it surfaces today (Sprint 2): logo, primary/accent colors, name,
// slug, follower count, list of published events. Still to come:
// custom-domain handling (Sprint 2.5), embed-snippet generator
// (Sprint 6), distribution-rail badges (Sprint 4).

import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { motion } from 'motion/react';
import { Organization, Event } from '../types';
import { getPublicOrgBySlug } from '../lib/orgs';
import { listPublicEventsForOrg } from '../lib/events';
import { ThemeProvider, useTheme } from '../context/ThemeContext';
import { formatInTz } from '../lib/datetime';
import { applyMeta } from '../lib/meta';
import { initOrgPixels } from '../lib/pixels';
import SocialLinks from '../components/SocialLinks';
import { publicUrl } from '../lib/utils';

interface ResolvedOrg {
  org: Organization;
}

// Neon green — the mockup default. Used for storefront chrome whenever the
// org hasn't set its own brand colour (keeps a themeless page on-design).
const NEON = '#00FF00';

// Demo xerox imagery (from the reference mockup) — used only as a fallback
// when an org/event has no artwork of its own, so the grid never shows a
// blank tile. Cycled by index for visual variety.
const DEMO_HERO =
  'https://images.unsplash.com/photo-1574391884720-bbc3740c59d1?q=80&w=1400';
const DEMO_CARD_IMAGES = [
  'https://images.unsplash.com/photo-1516450360452-9312f5e86fc7?q=80&w=600',
  'https://images.unsplash.com/photo-1574391884720-bbc3740c59d1?q=80&w=600',
  'https://images.unsplash.com/photo-1459749411175-04bf5292ceea?q=80&w=600',
  'https://images.unsplash.com/photo-1493225457124-a3eb161ffa5f?q=80&w=600',
  'https://images.unsplash.com/photo-1533174072545-7a4b6ad7a6c3?q=80&w=600',
  'https://images.unsplash.com/photo-1485872299829-c673f5194813?q=80&w=600',
];

function StorefrontInner({ org }: ResolvedOrg) {
  const { theme } = useTheme();
  const [events, setEvents] = useState<Event[]>([]);
  const [loading, setLoading] = useState(true);

  // Org-set colour wins; otherwise fall back to the mockup's neon green so a
  // themeless storefront reads exactly like the reference design.
  const accent = org.theme?.primaryColor ? theme.primary : NEON;
  const initial = (org.name || '?').trim().charAt(0).toUpperCase();
  const followers = org.followersCount ?? 0;

  useEffect(() => {
    let cancelled = false;
    async function load() {
      try {
        // Single root-collection query filtered by orgId. The composite
        // index this requires (orgId asc + status asc + date asc) is a
        // standard Firebase auto-suggest at first run.
        const list = await listPublicEventsForOrg(org.id);
        if (cancelled) return;
        setEvents(list);
      } catch (err) {
        console.error('Storefront load failed:', err);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [org.id]);

  return (
    <div className="wall min-h-screen text-white">
      {/* ---- Org-branded nav (white-label) ---- */}
      <nav className="sticky top-0 z-50 bg-black/90 backdrop-blur border-b border-white/10">
        <div className="max-w-6xl mx-auto px-4 sm:px-6">
          <div className="flex justify-between h-20 items-center">
            <div className="flex items-center gap-3">
              {theme.logoUrl ? (
                <img
                  src={theme.logoUrl}
                  alt={`${org.name} logo`}
                  className="w-11 h-11 object-contain"
                />
              ) : (
                <div
                  className="w-11 h-11 flex items-center justify-center disp text-2xl text-black"
                  style={{ background: accent }}
                >
                  {initial}
                </div>
              )}
              <span
                className="disp text-3xl tracking-tight leading-none pt-1 uppercase"
                style={{ transform: 'skewX(-5deg)' }}
              >
                {org.name}
              </span>
            </div>
            <div className="flex items-center gap-6">
              <a
                href="#events"
                className="type text-[11px] uppercase tracking-widest text-white/60 hover:text-brand-primary"
              >
                events
              </a>
              <button
                className="disp text-black px-5 py-1 text-lg tracking-wide uppercase"
                style={{ background: accent }}
              >
                Follow
              </button>
            </div>
          </div>
        </div>
      </nav>

      {/* ---- Hero banner ---- */}
      <header className="relative h-72 overflow-hidden flex items-end border-b border-white/10">
        <img
          src={theme.logoUrl && org.marketing?.shareImageUrl ? org.marketing.shareImageUrl : DEMO_HERO}
          className="xerox absolute inset-0 w-full h-full object-cover opacity-40"
          alt=""
        />
        <div className="absolute inset-0 bg-gradient-to-t from-black to-transparent" />
        <div className="max-w-6xl mx-auto px-4 sm:px-6 w-full relative z-10 pb-8">
          <span
            className="type text-[11px] uppercase tracking-widest"
            style={{ color: accent }}
          >
            powered by exos · {followers.toLocaleString()} followers
          </span>
          <h1
            className="disp text-6xl md:text-8xl tracking-tight leading-[0.82] mt-2 uppercase"
            style={{ transform: 'skewX(-4deg)' }}
          >
            {org.name}
          </h1>
          {org.description && (
            <p className="type text-white/55 text-sm mt-3 max-w-lg">{org.description}</p>
          )}
          <SocialLinks
            socials={org.marketing?.socials}
            className="flex items-center gap-4 mt-4"
          />
        </div>
      </header>

      {/* ---- Event grid ---- */}
      <motion.main
        id="events"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        className="max-w-6xl mx-auto px-4 sm:px-6 py-12"
      >
        <div className="flex items-end justify-between mb-8">
          <h2 className="disp text-3xl tracking-tight uppercase" style={{ transform: 'skewX(-4deg)' }}>
            Upcoming
          </h2>
          {!loading && events.length > 0 && (
            <span className="marker text-white/35 text-lg" style={{ transform: 'rotate(-3deg)' }}>
              {events.length} {events.length === 1 ? 'night' : 'nights'}
            </span>
          )}
        </div>

        {loading ? (
          <div className="text-center text-white/50 py-24 type uppercase tracking-[0.3em] animate-pulse">
            Loading events…
          </div>
        ) : events.length === 0 ? (
          <div className="bg-[#111] border border-white/10 p-12 text-center type text-white/50 uppercase tracking-widest">
            No upcoming events from this organizer yet.
          </div>
        ) : (
          <div className="grid grid-cols-2 lg:grid-cols-3 gap-4">
            {events.map((ev, i) => {
              const genre = (ev.category || ev.genres?.[0] || 'LIVE').toUpperCase();
              const img = ev.image || DEMO_CARD_IMAGES[i % DEMO_CARD_IMAGES.length];
              return (
                <Link
                  key={ev.id}
                  to={`/event/${ev.id}`}
                  className="group flex flex-col bg-[#111] border border-white/10 transition-all"
                  style={{ ['--tw-accent' as string]: accent }}
                  onMouseEnter={(e) => (e.currentTarget.style.borderColor = accent)}
                  onMouseLeave={(e) => (e.currentTarget.style.borderColor = 'rgba(255,255,255,0.1)')}
                >
                  <div className="relative aspect-[3/4] overflow-hidden">
                    <img src={img} className="xerox w-full h-full object-cover" alt="" />
                    <div className="absolute inset-0 bg-gradient-to-t from-[#111] via-transparent to-transparent" />
                    <span
                      className="disp absolute top-2 left-2 text-black px-2 text-sm tracking-wide"
                      style={{ background: accent }}
                    >
                      {genre}
                    </span>
                    <div className="absolute bottom-3 left-3 right-3">
                      <p
                        className="type text-[10px] uppercase tracking-widest mb-0.5"
                        style={{ color: accent }}
                      >
                        {ev.date ? formatInTz(ev.date.toDate(), ev.timezone || 'UTC') : 'TBA'}
                      </p>
                      <h3 className="disp text-2xl leading-[0.9] tracking-tight uppercase">
                        {ev.title}
                      </h3>
                    </div>
                  </div>
                  <div className="p-3 flex items-center justify-between">
                    <span className="type text-[11px] uppercase text-white/50 truncate">
                      {ev.location}
                    </span>
                    <span className="stamp neon text-base shrink-0" style={{ color: accent }}>
                      ${ev.price}+
                    </span>
                  </div>
                </Link>
              );
            })}
          </div>
        )}
      </motion.main>

      {/* ---- Footer ---- */}
      <footer className="border-t border-white/10 py-8 text-center">
        <p className="type text-[10px] uppercase tracking-[0.3em] text-white/30">
          powered by ▲ exos · secure ticketing
        </p>
      </footer>
    </div>
  );
}

export default function OrgStorefront() {
  const { slug } = useParams<{ slug: string }>();
  const [state, setState] = useState<{ status: 'loading' | 'found' | 'not-found'; org?: Organization }>({
    status: 'loading',
  });

  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!slug) return;
      try {
        const org = await getPublicOrgBySlug(slug);
        if (cancelled) return;
        if (!org) {
          setState({ status: 'not-found' });
          return;
        }
        setState({ status: 'found', org });
        // SEO: per-org meta tags. Title is the venue name; description
        // is generic but accurate. No JSON-LD here (we surface
        // schema.org Event tags on the per-event page instead).
        try {
          applyMeta({
            title: org.name,
            description: `Upcoming events from ${org.name}.`,
            imageUrl: org.marketing?.shareImageUrl || org.theme?.logoUrl,
            canonicalUrl: publicUrl(`o/${org.slug}`),
          });
        } catch {
          /* non-fatal */
        }
        // Marketing: load the org's pixels (consent-gated). The loaders emit
        // their own PageView, so we don't fire one here.
        initOrgPixels(org.marketing?.pixels);
      } catch (err) {
        console.error('Org slug lookup failed:', err);
        if (!cancelled) setState({ status: 'not-found' });
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [slug]);

  if (state.status === 'loading') {
    return (
      <div className="wall min-h-screen flex items-center justify-center text-center text-white/50 disp text-2xl uppercase tracking-[0.3em] animate-pulse">
        Loading…
      </div>
    );
  }

  if (state.status === 'not-found') {
    return (
      <div className="wall min-h-screen flex flex-col items-center justify-center text-center p-12">
        <h2 className="disp text-5xl uppercase tracking-tight mb-4" style={{ transform: 'skewX(-4deg)' }}>
          Organizer not found
        </h2>
        <p className="type text-white/50 uppercase tracking-widest text-sm">
          The /o/{slug} page is either unclaimed or the org has been removed.
        </p>
      </div>
    );
  }

  return (
    <ThemeProvider org={state.org!}>
      <StorefrontInner org={state.org!} />
    </ThemeProvider>
  );
}
