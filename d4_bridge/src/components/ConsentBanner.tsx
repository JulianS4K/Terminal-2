// Marketing-cookie consent banner.
//
// Shows once until the visitor accepts or declines. Gates the per-org
// pixels in lib/pixels.ts — nothing tracking loads before a choice is made.
// "Accept" flips consent to granted (queued pixels flush immediately);
// "Decline" is sticky so the banner doesn't nag.

import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { getConsent, setConsent } from '../lib/consent';

export default function ConsentBanner() {
  const [show, setShow] = useState(false);

  useEffect(() => {
    setShow(getConsent() === 'unset');
  }, []);

  if (!show) return null;

  const choose = (granted: boolean) => {
    setConsent(granted);
    setShow(false);
  };

  return (
    <div
      role="dialog"
      aria-label="Cookie consent"
      className="fixed bottom-0 inset-x-0 z-[60] bg-black border-t border-white/10 px-4 py-4 md:py-3"
    >
      <div className="max-w-5xl mx-auto flex flex-col md:flex-row md:items-center gap-3 md:gap-6">
        <p className="text-xs text-white/60 leading-relaxed flex-grow">
          We use analytics and marketing cookies to measure event reach. They
          load only if you accept. See our{' '}
          <Link to="/privacy" className="underline hover:text-white">privacy policy</Link>.
        </p>
        <div className="flex gap-2 flex-shrink-0">
          <button
            onClick={() => choose(false)}
            className="px-4 py-2 text-xs font-black uppercase tracking-tighter italic bg-white/5 text-white/70 hover:bg-white/10 transition-all"
          >
            Decline
          </button>
          <button
            onClick={() => choose(true)}
            className="px-4 py-2 text-xs font-black uppercase tracking-tighter italic bg-brand-primary text-black hover:bg-white transition-all"
          >
            Accept
          </button>
        </div>
      </div>
    </div>
  );
}
