// AccessDenied — the punk 403 / "not on the guestlist" screen from the Exos
// design set. Reusable for any permission or sign-in gate: shows SIGN IN when
// the viewer is signed out, and always offers a way back to the public floor.

import { Link } from 'react-router-dom';
import { Lock } from 'lucide-react';
import { useAuth } from '../context/AuthContext';

interface Props {
  /** Big glitch code. Defaults to 403. */
  code?: string;
  /** Marker scrawl above the headline. */
  scrawl?: string;
  /** Headline suffix after "ACCESS" (rendered in accent red). */
  title?: string;
  /** Body copy. */
  message?: string;
}

export default function AccessDenied({
  code = '403',
  scrawl = 'not on the guestlist',
  title = 'DENIED',
  message = "You don't have the credentials for this room. Sign in with the right account, or head back to the public floor.",
}: Props) {
  const { user, signIn } = useAuth();

  return (
    <div className="wall min-h-[80vh] flex flex-col items-center justify-center px-6 text-center pb-16">
      <div
        className="w-20 h-20 border-4 border-brand-accent flex items-center justify-center mb-6"
        style={{ transform: 'rotate(-3deg)' }}
      >
        <Lock className="w-10 h-10 text-brand-accent" />
      </div>
      <p
        className="disp glitch text-[22vw] md:text-[160px] leading-[0.8] tracking-tight"
        style={{ transform: 'skewX(-4deg)' }}
      >
        {code}
      </p>
      <span
        className="marker text-brand-secondary text-2xl md:text-3xl -mt-2 mb-6"
        style={{ transform: 'rotate(-4deg)' }}
      >
        {scrawl}
      </span>
      <h1 className="disp text-3xl md:text-5xl tracking-tight mb-4" style={{ transform: 'skewX(-4deg)' }}>
        ACCESS <span className="text-brand-accent">{title}</span>
      </h1>
      <p className="type text-white/55 text-base max-w-md mb-10 leading-relaxed">{message}</p>
      <div className="flex flex-wrap gap-3 justify-center">
        {!user && (
          <button
            onClick={signIn}
            className="disp bg-brand-primary text-black px-7 py-3 text-lg tracking-wide hover:scale-[1.02] transition-transform"
          >
            SIGN IN
          </button>
        )}
        <Link
          to="/"
          className="disp bg-white/5 border border-white/15 text-white px-7 py-3 text-lg tracking-wide hover:border-brand-primary hover:text-brand-primary transition-colors"
        >
          BACK TO EVENTS
        </Link>
      </div>
    </div>
  );
}
