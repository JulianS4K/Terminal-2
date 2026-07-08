// NotFound — 404 catch-all. Punk "off the door list" treatment from the
// Exos design set (glitch 404, marker scrawl, neon headline). Rendered by
// the `path="*"` route inside the platform chrome, so the global Navbar
// supplies the EXOS mark; this view is just the centred 404 body.

import { Link } from 'react-router-dom';
import { applyMeta } from '../lib/meta';
import { useEffect } from 'react';

export default function NotFound() {
  useEffect(() => {
    try {
      applyMeta({ title: 'Not found', description: 'This page is off the list.' });
    } catch {
      /* non-fatal */
    }
  }, []);

  return (
    <div className="wall min-h-[80vh] flex flex-col items-center justify-center px-6 text-center pb-16">
      <p
        className="disp glitch text-[26vw] md:text-[200px] leading-[0.8] tracking-tight"
        style={{ transform: 'skewX(-4deg)' }}
      >
        404
      </p>
      <span className="marker text-brand-secondary text-2xl md:text-3xl -mt-4 mb-6" style={{ transform: 'rotate(-4deg)' }}>
        not on the door list
      </span>
      <h1 className="disp text-3xl md:text-5xl tracking-tight mb-4" style={{ transform: 'skewX(-4deg)' }}>
        THIS ONE'S <span className="neon">OFF THE LIST</span>
      </h1>
      <p className="type text-white/55 text-base max-w-md mb-10 leading-relaxed">
        The page you're after moved, sold out, or never existed. Head back to the floor and find your next night.
      </p>
      <div className="flex flex-wrap gap-3 justify-center">
        <Link
          to="/"
          className="disp bg-brand-primary text-black px-7 py-3 text-lg tracking-wide hover:scale-[1.02] transition-transform"
        >
          BACK TO EVENTS
        </Link>
        <Link
          to="/my-tickets"
          className="disp bg-white/5 border border-white/15 text-white px-7 py-3 text-lg tracking-wide hover:border-brand-primary hover:text-brand-primary transition-colors"
        >
          MY TICKETS
        </Link>
      </div>
    </div>
  );
}
