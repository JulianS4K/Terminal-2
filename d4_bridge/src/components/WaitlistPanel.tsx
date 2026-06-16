// Organizer waitlist panel (Hi.Events parity).
//
// Shows the per-event waitlist counts (waiting / notified / converted) and lets
// org staff release N spots — exos_notify_waitlist flips the oldest waiting
// rows to 'notified' and emails each joiner. Light-theme, matches the
// OrganizerEventReport dashboard styling.

import { useCallback, useEffect, useState } from 'react';
import { Bell } from 'lucide-react';
import { notifyWaitlist, waitlistSummary, type WaitlistSummary } from '../lib/waitlist';
import { useToast } from '../context/ToastContext';

export default function WaitlistPanel({ eventId }: { eventId: string }) {
  const { toast } = useToast();
  const [summary, setSummary] = useState<WaitlistSummary | null>(null);
  const [loading, setLoading] = useState(true);
  const [releaseN, setReleaseN] = useState(10);
  const [releasing, setReleasing] = useState(false);

  const load = useCallback(async () => {
    try {
      setSummary(await waitlistSummary(eventId));
    } catch (err) {
      console.error('waitlistSummary failed:', err);
    } finally {
      setLoading(false);
    }
  }, [eventId]);

  useEffect(() => { load(); }, [load]);

  const release = async () => {
    setReleasing(true);
    try {
      const n = await notifyWaitlist({ eventId, limit: releaseN });
      toast({
        kind: n > 0 ? 'success' : 'info',
        message: n > 0 ? `Notified ${n} waitlister(s) — emails queued.` : 'No one waiting to notify.',
      });
      await load();
    } catch (err: any) {
      console.error('notifyWaitlist failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not release spots.' });
    } finally {
      setReleasing(false);
    }
  };

  if (loading) return null;
  // Nothing has ever hit the waitlist — keep the report clean.
  if (summary && summary.waiting === 0 && summary.notified === 0 && summary.converted === 0) return null;

  const s = summary!;
  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <div className="flex items-center gap-2 mb-1">
        <Bell className="w-4 h-4 text-slate-500" />
        <h3 className="text-sm font-bold text-slate-700">Waitlist</h3>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Buyers who registered interest after this event (or a tier) sold out.
      </p>

      <div className="grid grid-cols-3 gap-4 mb-5">
        <Stat label="Waiting" value={s.waiting} accent />
        <Stat label="Notified" value={s.notified} />
        <Stat label="Converted" value={s.converted} />
      </div>

      <div className="flex items-center gap-3">
        <input
          type="number"
          min={1}
          max={500}
          value={releaseN}
          onChange={(e) => setReleaseN(Math.max(1, Math.min(500, parseInt(e.target.value, 10) || 1)))}
          className="w-20 border-2 border-slate-200 focus:border-slate-900 outline-none px-3 py-2 text-sm font-bold rounded-lg"
        />
        <button
          type="button"
          disabled={releasing || s.waiting === 0}
          onClick={release}
          className="flex-1 bg-slate-900 hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-400 text-white py-2.5 rounded-lg font-black uppercase tracking-tighter italic text-xs transition-all"
        >
          {releasing ? 'Releasing…' : `Release ${releaseN} spot${releaseN === 1 ? '' : 's'}`}
        </button>
      </div>
    </div>
  );
}

function Stat({ label, value, accent }: { label: string; value: number; accent?: boolean }) {
  return (
    <div className={`rounded-xl p-4 ${accent ? 'bg-slate-900 text-white' : 'bg-slate-50 text-slate-900'}`}>
      <p className={`text-2xl font-bold tracking-tight ${accent ? 'text-white' : 'text-slate-900'}`}>{value}</p>
      <p className={`text-[10px] font-black uppercase tracking-widest mt-1 ${accent ? 'text-white/50' : 'text-slate-400'}`}>{label}</p>
    </div>
  );
}
