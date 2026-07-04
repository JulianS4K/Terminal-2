// Event reschedule panel (seller side).
//
// Lives on OrganizerEventReport. Owner/manager postpone/move an event to a new
// date/time — a deliberate, audited action (distinct from a silent EditEvent
// field change): it updates the timing, logs the old→new, and emails every
// non-voided holder the new date. Times are entered in the event's timezone
// (matching the Create/Edit pickers). Light-theme, matches the dashboard.

import { useCallback, useEffect, useState } from 'react';
import { CalendarClock, ArrowRight } from 'lucide-react';
import { Event } from '../types';
import {
  listEventReschedules,
  rescheduleEvent,
  type Reschedule,
} from '../lib/reschedule';
import {
  formatInTz,
  utcToZonedWallClock,
  zonedWallClockToUtc,
  utcToOccursAtLocal,
  getBrowserTimezone,
} from '../lib/datetime';
import { useToast } from '../context/ToastContext';

// Timestamp | ISO string | Date | undefined → Date | null.
function toDate(v: any): Date | null {
  if (!v) return null;
  if (typeof v?.toDate === 'function') return v.toDate();
  if (v instanceof Date) return v;
  if (typeof v === 'string') return new Date(v);
  return null;
}

export default function ReschedulePanel({
  event,
  canManage,
}: {
  event: Event;
  canManage: boolean;
}) {
  const { toast } = useToast();
  const tz = event.timezone || getBrowserTimezone();

  const startDate = toDate(event.date);
  const doorsDate = toDate(event.timing?.doorsOpen);
  const endDate = toDate(event.timing?.endTime);

  const [start, setStart] = useState(() => (startDate ? utcToZonedWallClock(startDate, tz) : ''));
  const [doors, setDoors] = useState(() => (doorsDate ? utcToZonedWallClock(doorsDate, tz) : ''));
  const [end, setEnd] = useState(() => (endDate ? utcToZonedWallClock(endDate, tz) : ''));
  const [reason, setReason] = useState('');
  const [saving, setSaving] = useState(false);
  const [history, setHistory] = useState<Reschedule[]>([]);

  const load = useCallback(async () => {
    setHistory(await listEventReschedules(event.id));
  }, [event.id]);

  useEffect(() => {
    load();
  }, [load]);

  if (!canManage) return null;

  const submit = async () => {
    const startUtc = zonedWallClockToUtc(start, tz);
    if (!startUtc) {
      toast({ kind: 'warn', message: 'Pick a new start date and time first.' });
      return;
    }
    if (
      !window.confirm(
        'Reschedule this event? Every current ticket holder is emailed the new date. Tickets stay valid.',
      )
    )
      return;
    const doorsUtc = doors ? zonedWallClockToUtc(doors, tz) : null;
    const endUtc = end ? zonedWallClockToUtc(end, tz) : null;
    setSaving(true);
    try {
      const { recipientCount } = await rescheduleEvent({
        eventId: event.id,
        newStartsAt: startUtc.toISOString(),
        newDoorsAt: doorsUtc ? doorsUtc.toISOString() : null,
        newEndsAt: endUtc ? endUtc.toISOString() : null,
        occursAtLocal: utcToOccursAtLocal(startUtc, tz) || null,
        reason: reason.trim() || null,
      });
      toast({
        kind: 'success',
        message:
          recipientCount > 0
            ? `Event rescheduled — ${recipientCount} holder${recipientCount === 1 ? '' : 's'} emailed the new date.`
            : 'Event rescheduled. No ticket holders to email yet.',
      });
      setReason('');
      await load();
    } catch (err: any) {
      console.error('reschedule failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not reschedule the event.' });
    } finally {
      setSaving(false);
    }
  };

  const field = (label: string, value: string, onChange: (v: string) => void, required?: boolean) => (
    <label className="flex-1 min-w-[180px]">
      <span className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1">
        {label}
        {required ? ' *' : ''}
      </span>
      <input
        type="datetime-local"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="w-full border-2 border-slate-200 focus:border-slate-900 outline-none px-2 py-1.5 text-xs rounded-lg"
      />
    </label>
  );

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <div className="flex items-center gap-2 mb-1">
        <CalendarClock className="w-4 h-4 text-slate-500" />
        <h3 className="text-sm font-bold text-slate-700">Reschedule event</h3>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Move the event to a new date. Holders keep their tickets and are emailed the new time.
        Times are in the event's timezone (<span className="font-bold text-slate-500">{tz}</span>).
      </p>

      <div className="flex flex-wrap gap-3 mb-3">
        {field('New start', start, setStart, true)}
        {field('New doors', doors, setDoors)}
        {field('New end', end, setEnd)}
      </div>
      <textarea
        value={reason}
        maxLength={500}
        rows={2}
        onChange={(e) => setReason(e.target.value)}
        placeholder="Reason (optional) — shown to holders, e.g. venue conflict"
        className="w-full border-2 border-slate-200 focus:border-slate-900 outline-none px-3 py-2 text-sm rounded-lg resize-y mb-3"
      />
      <div className="flex justify-end">
        <button
          type="button"
          disabled={saving || !start}
          onClick={submit}
          className="bg-slate-900 hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-400 text-white px-4 py-2 rounded-lg font-black uppercase tracking-tighter italic text-xs transition-all"
        >
          {saving ? 'Rescheduling…' : 'Reschedule & notify holders'}
        </button>
      </div>

      {history.length > 0 && (
        <ul className="mt-5 space-y-2 border-t border-slate-100 pt-4">
          {history.map((r) => (
            <li key={r.id} className="text-xs text-slate-500 flex flex-wrap items-center gap-2">
              <span className="text-slate-400 line-through">
                {r.oldStartsAt ? formatInTz(r.oldStartsAt, tz, { dateStyle: 'medium', timeStyle: 'short' }) : 'TBA'}
              </span>
              <ArrowRight size={12} className="text-slate-300" aria-hidden="true" />
              <span className="font-bold text-slate-700">
                {formatInTz(r.newStartsAt, tz, { dateStyle: 'medium', timeStyle: 'short' })}
              </span>
              <span className="text-[10px] font-black text-slate-300 uppercase tracking-widest">
                · {r.recipientCount} emailed
              </span>
              {r.reason ? <span className="italic text-slate-400 basis-full">{r.reason}</span> : null}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
