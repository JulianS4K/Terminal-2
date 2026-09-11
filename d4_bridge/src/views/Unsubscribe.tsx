// Unsubscribe — public opt-out landing for organizer campaign emails.
//
// Reached from the footer link in every campaign mail (/unsubscribe/:token).
// Calls the anon-callable exos_marketing_optout(token) which records the
// (organizer, email) pair; that email is then excluded from every later
// campaign audience for that organizer. Transactional mail (tickets, reminders,
// transfers) is unaffected. No sign-in required — the token is the proof.

import { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { MailX, CheckCircle2, Loader2 } from 'lucide-react';
import { marketingOptOut } from '../lib/campaigns';

export default function Unsubscribe() {
  const { token } = useParams<{ token: string }>();
  const [state, setState] = useState<'working' | 'done' | 'error'>('working');
  const [masked, setMasked] = useState('');
  const [error, setError] = useState('');

  useEffect(() => {
    let cancelled = false;
    if (!token) { setState('error'); setError('Missing link.'); return undefined; }
    marketingOptOut(token)
      .then((m) => { if (!cancelled) { setMasked(m); setState('done'); } })
      .catch((err: any) => { if (!cancelled) { setError(err?.message || 'This link is not valid.'); setState('error'); } });
    return () => { cancelled = true; };
  }, [token]);

  return (
    <div className="max-w-md mx-auto px-4 py-20 text-center">
      {state === 'working' && (
        <>
          <Loader2 className="w-8 h-8 mx-auto text-slate-400 animate-spin mb-4" />
          <p className="text-slate-500 text-sm">Updating your preferences…</p>
        </>
      )}
      {state === 'done' && (
        <>
          <CheckCircle2 className="w-10 h-10 mx-auto text-emerald-500 mb-4" />
          <h1 className="text-xl font-bold text-slate-900 mb-2">You're unsubscribed</h1>
          <p className="text-slate-500 text-sm">
            {masked} will no longer receive marketing emails from this organizer. You'll still get
            emails about tickets you hold, such as reminders and transfers.
          </p>
        </>
      )}
      {state === 'error' && (
        <>
          <MailX className="w-10 h-10 mx-auto text-rose-500 mb-4" />
          <h1 className="text-xl font-bold text-slate-900 mb-2">Link not recognised</h1>
          <p className="text-slate-500 text-sm">{error}</p>
        </>
      )}
      <Link to="/" className="inline-block mt-8 text-[10px] font-black uppercase tracking-widest text-slate-400 hover:text-slate-900">
        Back to Bridge
      </Link>
    </div>
  );
}
