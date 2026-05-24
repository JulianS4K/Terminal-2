// OrgStorefront — the white-label landing page for a Bridge org.
//
// Lives at `/o/:slug`. Resolves the slug via the `slugs/` collection
// (with `org:` prefix), loads the org doc, and renders the org's
// published events with the org's theme applied via ThemeProvider.
//
// What it surfaces today (Sprint 2): logo, primary/accent colors as
// CSS variables, name, slug, list of published events. What's still
// to come: custom-domain handling (Sprint 2.5 if we get to it),
// embed-snippet generator (Sprint 6), distribution-rail badges
// (Sprint 4).

import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { motion } from 'motion/react';
import { Organization, Event } from '../types';
import { getPublicOrgBySlug } from '../lib/orgs';
import { listPublicEventsForOrg } from '../lib/events';
import { ThemeProvider, useTheme } from '../context/ThemeContext';
import { formatInTz } from '../lib/datetime';
import { applyMeta } from '../lib/meta';
import { initOrgPixels, trackPixelEvent } from '../lib/pixels';
import SocialLinks from '../components/SocialLinks';

interface ResolvedOrg {
  org: Organization;
}

function StorefrontInner({ org }: ResolvedOrg) {
  const { theme } = useTheme();
  const [events, setEvents] = useState<Event[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      try {
        // Single root-collection query filtered by orgId. The composite
        // index this requires (orgId asc + status asc + date asc) is a
        // standard Firebase auto-suggest at first run; flag this in the
        // README of the deploy notes when we get to the indexing pass.
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
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="max-w-5xl mx-auto p-6 md:p-12"
    >
      {/* Header — logo + org name with the theme primary as the accent rail. */}
      <div
        className="border-l-4 pl-6 mb-12 flex items-center gap-6"
        style={{ borderColor: theme.primary }}
      >
        {theme.logoUrl && (
          <img
            src={theme.logoUrl}
            alt={`${org.name} logo`}
            className="w-20 h-20 object-contain"
          />
        )}
        <div>
          <h1 className="text-4xl md:text-6xl font-black uppercase italic tracking-tighter text-white">
            {org.name}
          </h1>
          <p className="text-[10px] text-white/40 font-bold uppercase tracking-widest mt-1">
            /o/{org.slug}
          </p>
          <SocialLinks socials={org.marketing?.socials} className="flex items-center gap-4 mt-3" />
        </div>
      </div>

      {loading ? (
        <div className="text-center text-white/50 py-24 font-bold uppercase tracking-[0.3em] animate-pulse">
          Loading events…
        </div>
      ) : events.length === 0 ? (
        <div className="bg-white/5 border border-white/10 p-12 text-center text-white/50">
          No upcoming events from this organizer yet.
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {events.map((ev) => (
            <Link
              key={ev.id}
              to={`/event/${ev.id}`}
              className="group bg-white/5 border border-white/10 hover:border-[var(--bridge-primary)] p-6 transition-all"
            >
              <h3 className="text-2xl font-black uppercase italic tracking-tighter text-white mb-2">
                {ev.title}
              </h3>
              <p className="text-[10px] text-white/40 font-bold uppercase tracking-widest mb-3">
                {ev.date
                  ? formatInTz(ev.date.toDate(), ev.timezone || 'UTC')
                  : 'TBA'}{' '}
                · {ev.location}
              </p>
              <p className="text-sm text-white/60 line-clamp-2">{ev.description}</p>
            </Link>
          ))}
        </div>
      )}
    </motion.div>
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
            canonicalUrl: `${window.location.origin}/o/${org.slug}`,
          });
        } catch {
          /* non-fatal */
        }
        // Marketing: load the org's pixels (consent-gated) + fire a PageView.
        initOrgPixels(org.marketing?.pixels);
        trackPixelEvent('PageView');
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
      <div className="max-w-3xl mx-auto p-24 text-center text-slate-300 font-bold uppercase tracking-[0.3em] animate-pulse">
        Loading…
      </div>
    );
  }

  if (state.status === 'not-found') {
    return (
      <div className="max-w-3xl mx-auto p-12 text-center">
        <h2 className="text-3xl font-black uppercase italic tracking-tighter text-white mb-4">
          Organizer not found
        </h2>
        <p className="text-white/50">
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
