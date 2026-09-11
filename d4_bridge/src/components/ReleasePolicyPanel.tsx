// ReleasePolicyPanel — organizer controls for self-serve RSVP release
// (D4-OPS-22, mig 20260911131000).
//
// A holder may give a FREE ticket back on their own (the seat returns to the
// tier and the waitlist auto-offers it). The organizer can switch that off per
// event, or close it N hours before the start. Both are plain event columns
// (staff RLS on exos_events) saved through updateEvent; the release RPC reads
// them server-side, so this panel is a convenience, not the gate.

import { useEffect, useState } from 'react';
import { Undo2 } from 'lucide-react';
import { updateEvent } from '../lib/events';
import { useToast } from '../context/ToastContext';
import type { Event } from '../types';

export default function ReleasePolicyPanel({
  event,
  canManage,
  onSaved,
}: {
  event: Event;
  canManage: boolean;
  onSaved?: (next: { allowHolderRelease: boolean; releaseCutoffHours: number }) => void;
}) {
  const { toast } = useToast();
  const [allow, setAllow] = useState(event.allowHolderRelease ?? true);
  const [cutoff, setCutoff] = useState(event.releaseCutoffHours ?? 0);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    setAllow(event.allowHolderRelease ?? true);
    setCutoff(event.releaseCutoffHours ?? 0);
  }, [event.id, event.allowHolderRelease, event.releaseCutoffHours]);

  const dirty = allow !== (event.allowHolderRelease ?? true) || cutoff !== (event.releaseCutoffHours ?? 0);

  const save = async () => {
    const hours = Math.max(0, Math.min(720, Math.round(Number(cutoff) || 0)));
    setSaving(true);
    try {
      await updateEvent(event.id, { allowHolderRelease: allow, releaseCutoffHours: hours });
      setCutoff(hours);
      onSaved?.({ allowHolderRelease: allow, releaseCutoffHours: hours });
      toast({ kind: 'success', message: 'Release policy saved.' });
    } catch (err: any) {
      console.error('updateEvent(release policy) failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not save the release policy.' });
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <div className="flex items-center gap-2 mb-1">
        <Undo2 className="w-4 h-4 text-slate-500" />
        <h3 className="text-sm font-bold text-slate-700">Self-serve release</h3>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Holders of <strong>free</strong> tickets can give their seat back from their wallet. The seat
        returns to the tier immediately and the next person on the waitlist is offered it. Paid
        tickets always go through a refund instead.
      </p>

      <div className="flex flex-col md:flex-row md:items-end gap-4">
        <label className="flex items-center gap-3 text-sm text-slate-700">
          <input
            type="checkbox"
            checked={allow}
            disabled={!canManage || saving}
            onChange={(e) => setAllow(e.target.checked)}
            className="h-4 w-4 rounded border-slate-300"
          />
          Allow holders to release their own ticket
        </label>
        <label className="flex items-center gap-2 text-sm text-slate-700">
          <span className="text-[10px] font-black text-slate-400 uppercase tracking-widest">Closes</span>
          <input
            type="number"
            min={0}
            max={720}
            value={cutoff}
            disabled={!canManage || saving || !allow}
            onChange={(e) => setCutoff(Number(e.target.value))}
            className="w-20 px-2 py-1.5 border border-slate-200 rounded text-sm disabled:bg-slate-50 disabled:text-slate-400"
            aria-label="Hours before start when self-serve release closes"
          />
          <span className="text-xs text-slate-500">hours before start (0 = until it starts)</span>
        </label>
        {canManage && (
          <button
            type="button"
            onClick={save}
            disabled={!dirty || saving}
            className="md:ml-auto px-4 py-2 bg-slate-900 hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-400 text-white rounded-lg font-black uppercase tracking-tighter italic text-xs transition-all"
          >
            {saving ? 'Saving…' : 'Save policy'}
          </button>
        )}
      </div>
    </div>
  );
}
