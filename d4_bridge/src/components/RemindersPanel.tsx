// Organizer pre-event reminders panel (seller side).
//
// Lives on OrganizerEventReport next to Attendee updates. Explains the two
// automatic sends (T-24h / T-2h, cron-driven — nothing to configure) and gives
// owner/manager a "Send reminder now" button for ad-hoc nudges. The RPC enforces
// the role check and a 6h cooldown server-side regardless of `canSend`.

import { useState } from 'react';
import { BellRing, Send } from 'lucide-react';
import { useToast } from '../context/ToastContext';
import { sendEventReminderNow } from '../lib/reminders';

export default function RemindersPanel({
  eventId,
  canSend,
  isPublished,
}: {
  eventId: string;
  canSend: boolean;
  isPublished: boolean;
}) {
  const { toast } = useToast();
  const [sending, setSending] = useState(false);
  const [lastCount, setLastCount] = useState<number | null>(null);

  const send = async () => {
    if (
      !window.confirm(
        'Email a reminder to every current ticket holder now? (Automatic reminders still go out 24h and 2h before the event.)',
      )
    )
      return;
    setSending(true);
    try {
      const n = await sendEventReminderNow(eventId);
      setLastCount(n);
      toast({
        kind: 'success',
        message:
          n > 0
            ? `Reminder queued for ${n} ticket holder${n === 1 ? '' : 's'}.`
            : 'No ticket holders to remind yet.',
      });
    } catch (err: any) {
      console.error('sendEventReminderNow failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not send the reminder.' });
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <div className="flex items-center gap-2 mb-1">
        <BellRing className="w-4 h-4 text-slate-500" />
        <h3 className="text-sm font-bold text-slate-700">Pre-event reminders</h3>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Every ticket holder is emailed automatically 24 hours and again 2 hours before the start
        time, with doors and venue details. Nothing to set up. Need an extra nudge? Send one now
        (once every 6 hours).
      </p>

      {canSend && (
        <button
          type="button"
          disabled={sending || !isPublished}
          onClick={send}
          title={isPublished ? undefined : 'Publish the event first'}
          className="w-full flex items-center justify-center gap-2 bg-slate-900 hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-400 text-white py-2.5 rounded-lg font-black uppercase tracking-tighter italic text-xs transition-all"
        >
          <Send size={14} aria-hidden="true" />
          {sending ? 'Sending…' : 'Send reminder now'}
        </button>
      )}
      {!isPublished && (
        <p className="text-[10px] text-slate-400 mt-2">
          Reminders only go out for published events.
        </p>
      )}
      {lastCount !== null && (
        <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mt-3">
          Last manual send: {lastCount} holder{lastCount === 1 ? '' : 's'}
        </p>
      )}
    </div>
  );
}
