// Sold-out waitlist call-to-action (Hi.Events parity).
//
// Rendered on EventDetails in place of the disabled "Buy Tickets" button when an
// event/tier is sold out. Collects email (+ optional name) and joins the
// waitlist via the anon-callable exos_join_waitlist RPC, so a signed-out buyer
// can register interest. On success it shows the queue position; the organizer
// releases spots later (exos_notify_waitlist) which emails the joiner.

import { useState } from 'react';
import { Bell, Check } from 'lucide-react';
import { joinWaitlist } from '../lib/waitlist';
import { useToast } from '../context/ToastContext';

interface Props {
  eventId: string;
  tierId?: string | null;
  /** Prefill from the signed-in user when available. */
  defaultEmail?: string | null;
  defaultName?: string | null;
  /** Optional brand accent for the submit button. */
  accentStyle?: React.CSSProperties;
}

export default function WaitlistCTA({ eventId, tierId, defaultEmail, defaultName, accentStyle }: Props) {
  const { toast } = useToast();
  const [open, setOpen] = useState(false);
  const [email, setEmail] = useState(defaultEmail || '');
  const [name, setName] = useState(defaultName || '');
  const [quantity, setQuantity] = useState(1);
  const [submitting, setSubmitting] = useState(false);
  const [position, setPosition] = useState<number | null>(null);

  const submit = async () => {
    const trimmed = email.trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(trimmed)) {
      toast({ kind: 'error', message: 'Enter a valid email so we can notify you.' });
      return;
    }
    setSubmitting(true);
    try {
      const params = new URLSearchParams(window.location.search);
      const meta: Record<string, string> = {};
      const promoter = params.get('promoter');
      const utm = params.get('utm_source');
      if (promoter) meta.promoter = promoter;
      if (utm) meta.channel = utm;
      const res = await joinWaitlist({
        eventId,
        email: trimmed,
        tierId: tierId ?? null,
        name: name.trim() || null,
        quantity,
        meta: Object.keys(meta).length ? meta : null,
      });
      setPosition(res.position);
      toast({ kind: 'success', title: "You're on the list", message: `We'll email ${trimmed} the moment a spot opens.` });
    } catch (err: any) {
      console.error('Waitlist join failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not join the waitlist. Please try again.' });
    } finally {
      setSubmitting(false);
    }
  };

  if (position !== null) {
    return (
      <div className="w-full border-2 border-brand-primary/40 bg-brand-primary/10 p-5 text-center">
        <Check className="w-6 h-6 mx-auto mb-2 text-brand-primary" />
        <p className="uppercase tracking-tighter italic text-sm font-black">You're on the waitlist</p>
        <p className="text-white/50 text-xs font-bold mt-1">Position #{position} — we'll email you if a spot opens.</p>
      </div>
    );
  }

  if (!open) {
    return (
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="w-full flex items-center justify-center space-x-3 border-2 border-white/20 hover:border-brand-primary hover:text-brand-primary text-white/70 py-4 font-black uppercase italic tracking-tighter text-sm transition-all"
      >
        <Bell className="w-5 h-5" />
        <span>Join the Waitlist</span>
      </button>
    );
  }

  return (
    <div className="w-full border-2 border-white/15 p-5 space-y-3">
      <p className="uppercase tracking-tighter italic text-xs font-black text-white/60">
        Sold out — get notified if a spot opens
      </p>
      <input
        type="email"
        value={email}
        onChange={(e) => setEmail(e.target.value)}
        placeholder="you@email.com"
        autoComplete="email"
        className="w-full bg-black border-2 border-white/15 focus:border-brand-primary outline-none px-3 py-2 text-sm font-bold"
      />
      <input
        type="text"
        value={name}
        onChange={(e) => setName(e.target.value)}
        placeholder="Name (optional)"
        autoComplete="name"
        className="w-full bg-black border-2 border-white/15 focus:border-brand-primary outline-none px-3 py-2 text-sm font-bold"
      />
      <div className="flex items-center space-x-3">
        <label className="text-[10px] font-black uppercase tracking-[0.2em] text-white/40">Qty</label>
        <input
          type="number"
          min={1}
          max={50}
          value={quantity}
          onChange={(e) => setQuantity(Math.max(1, Math.min(50, parseInt(e.target.value, 10) || 1)))}
          className="w-20 bg-black border-2 border-white/15 focus:border-brand-primary outline-none px-3 py-2 text-sm font-bold"
        />
      </div>
      <button
        type="button"
        disabled={submitting}
        onClick={submit}
        style={accentStyle}
        className="primary-button w-full flex items-center justify-center space-x-3 disabled:opacity-50"
      >
        <Bell className="w-5 h-5" />
        <span className="uppercase tracking-tighter italic text-sm font-black">
          {submitting ? 'Joining…' : 'Notify Me'}
        </span>
      </button>
    </div>
  );
}
