// Buyer "save event" (wishlist) toggle.
//
// Self-managing: when `initialSaved` is passed the parent controls the state
// (used by list surfaces that fetched the whole saved-set up front); otherwise
// the button fetches its own saved state once on mount. A signed-out click opens
// the auth modal instead of erroring. Optimistic toggle with rollback on failure
// so the heart feels instant and degrades cleanly before the table is applied.

import { useEffect, useState } from 'react';
import { Heart } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { saveEvent, unsaveEvent, listSavedEventIds } from '../lib/saves';

interface Props {
  eventId: string;
  /** When provided, the parent owns the saved state (controlled). */
  initialSaved?: boolean;
  /** 'row' matches the EventDetails buy-box action list; 'chip' is a compact pill. */
  variant?: 'row' | 'chip';
  /** Notified after a successful toggle so lists can update their own state. */
  onChange?: (saved: boolean) => void;
}

export default function SaveEventButton({ eventId, initialSaved, variant = 'row', onChange }: Props) {
  const { user, openAuthModal } = useAuth();
  const { toast } = useToast();
  const [saved, setSaved] = useState(!!initialSaved);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    // Controlled by the parent — mirror its value, no fetch.
    if (initialSaved !== undefined) {
      setSaved(initialSaved);
      return undefined;
    }
    if (!user) {
      setSaved(false);
      return undefined;
    }
    let alive = true;
    listSavedEventIds().then((ids) => {
      if (alive) setSaved(ids.has(eventId));
    });
    return () => {
      alive = false;
    };
  }, [eventId, user, initialSaved]);

  const toggle = async () => {
    if (!user) {
      openAuthModal();
      return;
    }
    if (busy) return;
    const next = !saved;
    setSaved(next); // optimistic
    setBusy(true);
    try {
      if (next) await saveEvent(eventId);
      else await unsaveEvent(eventId);
      onChange?.(next);
    } catch (err: any) {
      setSaved(!next); // rollback
      toast({ kind: 'error', message: err?.message || 'Could not update saved events.' });
    } finally {
      setBusy(false);
    }
  };

  const label = saved ? 'Saved' : 'Save Event';

  if (variant === 'chip') {
    return (
      <button
        type="button"
        onClick={toggle}
        disabled={busy}
        aria-pressed={saved}
        aria-label={saved ? 'Remove from saved events' : 'Save this event'}
        className={`inline-flex items-center gap-2 px-4 py-2 border font-black uppercase tracking-tighter italic text-[10px] transition-all disabled:opacity-50 ${
          saved
            ? 'bg-brand-primary text-black border-brand-primary'
            : 'bg-transparent text-white/60 border-white/20 hover:text-white hover:border-white'
        }`}
      >
        <Heart className="w-3.5 h-3.5" fill={saved ? 'currentColor' : 'none'} aria-hidden="true" />
        {label}
      </button>
    );
  }

  // 'row' — matches the buy-box action list (Share Link / Send via SMS / …).
  return (
    <button
      type="button"
      onClick={toggle}
      disabled={busy}
      aria-pressed={saved}
      aria-label={saved ? 'Remove from saved events' : 'Save this event'}
      className={`flex items-center transition-colors text-left ${
        saved ? 'text-brand-primary' : 'hover:text-brand-primary'
      }`}
    >
      <Heart
        className="w-4 h-4 mr-3 text-brand-primary"
        fill={saved ? 'currentColor' : 'none'}
        aria-hidden="true"
      />
      {label}
    </button>
  );
}
