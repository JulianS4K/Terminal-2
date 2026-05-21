import { useEffect, useState } from 'react';
import { Navigate, useParams } from 'react-router-dom';
import { doc, getDoc } from 'firebase/firestore';
import { db } from '../lib/firebase';

/**
 * Resolves /e/:slug → /event/:eventId.
 *
 * The lookup is a single read against `slugs/{slug}` (publicly readable per
 * the rule). If the slug doesn't exist, we render a "not found" panel
 * instead of bouncing to home, so a typo'd or expired vanity URL gets a
 * helpful message rather than a silent redirect.
 */
export default function SlugRedirect() {
  const { slug } = useParams<{ slug: string }>();
  const [eventId, setEventId] = useState<string | null>(null);
  const [state, setState] = useState<'loading' | 'missing' | 'found'>('loading');

  useEffect(() => {
    let cancelled = false;
    async function resolve() {
      if (!slug) {
        setState('missing');
        return;
      }
      try {
        const snap = await getDoc(doc(db, 'slugs', slug.toLowerCase()));
        if (cancelled) return;
        if (!snap.exists()) {
          setState('missing');
          return;
        }
        const data = snap.data() as { eventId?: string };
        if (!data.eventId) {
          setState('missing');
          return;
        }
        setEventId(data.eventId);
        setState('found');
      } catch (err) {
        console.error('Slug resolution failed', err);
        if (!cancelled) setState('missing');
      }
    }
    resolve();
    return () => {
      cancelled = true;
    };
  }, [slug]);

  if (state === 'loading') {
    return (
      <div className="max-w-7xl mx-auto p-24 text-center text-slate-300 font-bold uppercase tracking-[0.3em] animate-pulse">
        Resolving link…
      </div>
    );
  }
  if (state === 'found' && eventId) {
    // `replace: true` so the slug URL doesn't pollute the back-button history.
    return <Navigate to={`/event/${eventId}`} replace />;
  }
  return (
    <div className="max-w-xl mx-auto px-4 py-24 text-center">
      <h1 className="text-3xl font-bold text-slate-900 mb-4">Link not found</h1>
      <p className="text-slate-500 mb-10">
        The vanity URL <code>/e/{slug}</code> doesn&apos;t point at an active event.
      </p>
      <a
        href="/"
        className="bg-slate-900 text-white px-10 py-4 rounded-2xl font-bold text-xs uppercase tracking-widest shadow-xl"
      >
        Back home
      </a>
    </div>
  );
}
