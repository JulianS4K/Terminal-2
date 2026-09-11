// CreateSeries — make an event recurring, or lay out timed-entry slots
// (D4-OPS-27, create flow). Lives at /dashboard/event/:eventId/series.
//
// The current event is the TEMPLATE (it stays as member 0). The organizer
// picks a rule, previews the generated dates in the event's timezone, prunes
// any they don't want, and one RPC call clones the template — tiers included —
// once per date. Running it again on the same event extends the series.
//
// Owner / manager / admin; the RPC re-checks server-side.

import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { motion } from 'motion/react';
import { ArrowLeft, CalendarRange, Loader2, Repeat, Trash2 } from 'lucide-react';
import { getEventForEdit } from '../lib/events';
import {
  createEventSeries,
  generateOccurrences,
  listSeriesEvents,
  localDateRange,
  occurrenceLabel,
  MAX_OCCURRENCES,
  type RecurringRule,
  type SeriesKind,
  type SeriesRule,
  type TimedEntryRule,
  type Weekday,
} from '../lib/series';
import { utcToZonedWallClock } from '../lib/datetime';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import type { Event } from '../types';

const WEEKDAYS: { d: Weekday; label: string }[] = [
  { d: 1, label: 'Mon' }, { d: 2, label: 'Tue' }, { d: 3, label: 'Wed' }, { d: 4, label: 'Thu' },
  { d: 5, label: 'Fri' }, { d: 6, label: 'Sat' }, { d: 0, label: 'Sun' },
];

const LBL = 'block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1';
const INPUT = 'px-2 py-1.5 border border-slate-200 rounded text-sm bg-white';

export default function CreateSeries() {
  const { eventId } = useParams<{ eventId: string }>();
  const navigate = useNavigate();
  const { user, isAdmin } = useAuth();
  const { activeRole } = useOrganization();
  const { toast } = useToast();

  const [event, setEvent] = useState<Event | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);
  // Start instants already in this series (extend mode) — never regenerated.
  const [existing, setExisting] = useState<Set<number>>(new Set());
  const [kind, setKind] = useState<SeriesKind>('recurring');
  const [name, setName] = useState('');
  const [publish, setPublish] = useState<'copy' | 'draft' | 'published'>('copy');
  const [removed, setRemoved] = useState<Set<number>>(new Set());
  const [busy, setBusy] = useState(false);

  // Recurring inputs.
  const [freq, setFreq] = useState<'daily' | 'weekly'>('weekly');
  const [interval, setInterval] = useState(1);
  const [weekdays, setWeekdays] = useState<Weekday[]>([]);
  const [stop, setStop] = useState<'count' | 'until'>('count');
  const [count, setCount] = useState(4);
  const [until, setUntil] = useState('');

  // Timed-entry inputs.
  const [fromDay, setFromDay] = useState('');
  const [toDay, setToDay] = useState('');
  const [firstSlot, setFirstSlot] = useState('10:00');
  const [slotMinutes, setSlotMinutes] = useState(60);
  const [slotsPerDay, setSlotsPerDay] = useState(6);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      if (!eventId) return;
      setLoading(true);
      setLoadError(null);
      try {
        const ev = await getEventForEdit(eventId);
        if (cancelled) return;
        setEvent(ev);
        if (ev) {
          setName(ev.title);
          // The RPC falls back to UTC when the template has no timezone — use
          // the same fallback here so the preview matches what gets created.
          const wall = utcToZonedWallClock(ev.date.toDate(), ev.timezone || 'UTC');
          const day = wall.slice(0, 10);
          setFromDay(day);
          setToDay(day);
          setFirstSlot(wall.slice(11, 16) || '10:00');
          if (ev.seriesId) {
            const members = await listSeriesEvents(ev.seriesId);
            if (!cancelled) setExisting(new Set(members.map((m) => m.date.toDate().getTime())));
          }
        }
      } catch (err: any) {
        console.error('CreateSeries load failed:', err);
        if (!cancelled) setLoadError(err?.message || 'Could not load the event.');
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [eventId, reloadKey]);

  const tz = event?.timezone || 'UTC';
  const tzMissing = !!event && !event.timezone;
  const templateWall = event ? utcToZonedWallClock(event.date.toDate(), tz) : '';

  const rule: SeriesRule | null = useMemo(() => {
    if (!event) return null;
    if (kind === 'recurring') {
      const r: RecurringRule = {
        kind: 'recurring', start: templateWall, timezone: tz, freq, interval,
        weekdays: freq === 'weekly' ? weekdays : undefined,
        count: stop === 'count' ? count : undefined,
        until: stop === 'until' ? until : undefined,
      };
      return r;
    }
    const r: TimedEntryRule = {
      kind: 'timed-entry', days: localDateRange(fromDay, toDay, 62), timezone: tz,
      firstSlot, slotMinutes, slotsPerDay,
    };
    return r;
  }, [event, kind, templateWall, tz, freq, interval, weekdays, stop, count, until, fromDay, toDay, firstSlot, slotMinutes, slotsPerDay]);

  // Drop dates the series already has (extend mode) — the RPC skips them too.
  const occurrences = useMemo(
    () => (rule ? generateOccurrences(rule).filter((d) => !existing.has(d.getTime())) : []),
    [rule, existing],
  );
  const kept = occurrences.filter((_, i) => !removed.has(i));

  useEffect(() => { setRemoved(new Set()); }, [rule]);

  if (!user) return <div className="max-w-3xl mx-auto p-12 text-center text-slate-500">Sign in to manage events.</div>;
  if (loading) {
    return <div className="max-w-7xl mx-auto p-24 text-center text-slate-300 font-bold uppercase tracking-[0.3em] animate-pulse">Loading…</div>;
  }
  if (loadError) {
    return (
      <div className="max-w-3xl mx-auto p-12 text-center text-slate-500">
        <p className="mb-4">{loadError}</p>
        <button type="button" onClick={() => setReloadKey((k) => k + 1)} className="px-4 py-2 bg-slate-900 text-white rounded-lg text-xs font-black uppercase tracking-widest">
          Retry
        </button>
      </div>
    );
  }
  if (!event) return <div className="max-w-3xl mx-auto p-12 text-center text-slate-500">Event not found.</div>;
  const canManage = isAdmin || activeRole === 'owner' || activeRole === 'manager' || event.organizerId === user.uid;
  if (!canManage) return <div className="max-w-3xl mx-auto p-12 text-center text-slate-500">Only owners and managers can create a series.</div>;

  const submit = async () => {
    if (kept.length === 0) return;
    if (!window.confirm(`Create ${kept.length} more date${kept.length === 1 ? '' : 's'} of "${event.title}"? Tiers are copied; nothing is sold yet on the new dates.`)) return;
    setBusy(true);
    try {
      const rows = await createEventSeries({
        templateEventId: event.id,
        startsAt: kept,
        kind,
        name: name.trim() || null,
        rule,
        publish: publish === 'copy' ? undefined : publish === 'published',
      });
      toast({ kind: 'success', message: `${rows.length} date${rows.length === 1 ? '' : 's'} created${event.seriesId ? ' (series extended)' : ''}.` });
      navigate('/dashboard');
    } catch (err: any) {
      console.error('exos_create_event_series failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not create the series.' });
    } finally {
      setBusy(false);
    }
  };

  const toggleWeekday = (d: Weekday) =>
    setWeekdays((w) => (w.includes(d) ? w.filter((x) => x !== d) : [...w, d].sort()));

  return (
    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} className="bg-[#f2f4f7] min-h-screen">
      <div className="max-w-5xl mx-auto px-4 py-12">
        <Link to={`/dashboard/event/${event.id}`} className="flex items-center gap-2 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6 transition-all">
          <ArrowLeft size={14} /> Back to report
        </Link>
        <div className="mb-8">
          <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">
            {event.seriesId ? 'Extend series' : 'Make it a series'}
          </p>
          <h1 className="text-3xl md:text-4xl font-bold tracking-tight text-slate-900">{event.title}</h1>
          <p className="text-xs text-slate-400 mt-2">
            Template: {templateWall.replace('T', ' ')} ({tz}). This date stays as it is; every generated date is a copy with its own capacity.
          </p>
          {tzMissing && (
            <p className="text-xs text-amber-600 mt-1">
              This event has no timezone set, so dates are generated in UTC. Set the timezone on the event first for local times.
            </p>
          )}
          {existing.size > 1 && (
            <p className="text-xs text-slate-400 mt-1">Dates already in this series are skipped automatically.</p>
          )}
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-5 gap-6">
          {/* Rule */}
          <div className="lg:col-span-3 space-y-6">
            <div className="bg-white rounded-2xl p-6 shadow-sm">
              <div className="flex gap-2 mb-5">
                <button type="button" onClick={() => setKind('recurring')} className={`inline-flex items-center gap-2 px-3 py-2 rounded text-[10px] font-black uppercase tracking-widest border ${kind === 'recurring' ? 'bg-slate-900 text-white border-slate-900' : 'bg-white text-slate-600 border-slate-200'}`}>
                  <Repeat size={12} /> Recurring
                </button>
                <button type="button" onClick={() => setKind('timed-entry')} className={`inline-flex items-center gap-2 px-3 py-2 rounded text-[10px] font-black uppercase tracking-widest border ${kind === 'timed-entry' ? 'bg-slate-900 text-white border-slate-900' : 'bg-white text-slate-600 border-slate-200'}`}>
                  <CalendarRange size={12} /> Timed entry
                </button>
              </div>

              {kind === 'recurring' ? (
                <div className="space-y-4">
                  <div className="flex flex-wrap items-end gap-3">
                    <label><span className={LBL}>Repeat</span>
                      <select value={freq} onChange={(e) => setFreq(e.target.value as 'daily' | 'weekly')} className={INPUT}>
                        <option value="daily">Daily</option>
                        <option value="weekly">Weekly</option>
                      </select>
                    </label>
                    <label><span className={LBL}>Every</span>
                      <input type="number" min={1} max={52} value={interval} onChange={(e) => setInterval(Math.max(1, Number(e.target.value) || 1))} className={`${INPUT} w-16`} />
                    </label>
                    <span className="text-xs text-slate-500 pb-2">{freq === 'daily' ? 'day(s)' : 'week(s)'}</span>
                  </div>
                  {freq === 'weekly' && (
                    <div>
                      <span className={LBL}>On</span>
                      <div className="flex flex-wrap gap-1">
                        {WEEKDAYS.map((w) => (
                          <button key={w.d} type="button" onClick={() => toggleWeekday(w.d)} className={`px-2.5 py-1 rounded text-[10px] font-black uppercase tracking-widest border ${weekdays.includes(w.d) ? 'bg-blue-600 text-white border-blue-600' : 'bg-white text-slate-600 border-slate-200'}`}>
                            {w.label}
                          </button>
                        ))}
                      </div>
                      <p className="text-[10px] text-slate-400 mt-1">Nothing selected = same weekday as the template.</p>
                    </div>
                  )}
                  <div className="flex flex-wrap items-end gap-3">
                    <label><span className={LBL}>Stop</span>
                      <select value={stop} onChange={(e) => setStop(e.target.value as 'count' | 'until')} className={INPUT}>
                        <option value="count">after N dates</option>
                        <option value="until">on a date</option>
                      </select>
                    </label>
                    {stop === 'count' ? (
                      <label><span className={LBL}>Dates</span>
                        <input type="number" min={1} max={MAX_OCCURRENCES} value={count} onChange={(e) => setCount(Math.max(1, Math.min(MAX_OCCURRENCES, Number(e.target.value) || 1)))} className={`${INPUT} w-20`} />
                      </label>
                    ) : (
                      <label><span className={LBL}>Until</span>
                        <input type="date" value={until} onChange={(e) => setUntil(e.target.value)} className={INPUT} />
                      </label>
                    )}
                  </div>
                </div>
              ) : (
                <div className="space-y-4">
                  <div className="flex flex-wrap items-end gap-3">
                    <label><span className={LBL}>From</span>
                      <input type="date" value={fromDay} onChange={(e) => setFromDay(e.target.value)} className={INPUT} />
                    </label>
                    <label><span className={LBL}>To</span>
                      <input type="date" value={toDay} onChange={(e) => setToDay(e.target.value)} className={INPUT} />
                    </label>
                  </div>
                  <div className="flex flex-wrap items-end gap-3">
                    <label><span className={LBL}>First slot</span>
                      <input type="time" value={firstSlot} onChange={(e) => setFirstSlot(e.target.value)} className={INPUT} />
                    </label>
                    <label><span className={LBL}>Every</span>
                      <input type="number" min={5} step={5} value={slotMinutes} onChange={(e) => setSlotMinutes(Math.max(5, Number(e.target.value) || 60))} className={`${INPUT} w-20`} />
                    </label>
                    <span className="text-xs text-slate-500 pb-2">min</span>
                    <label><span className={LBL}>Slots / day</span>
                      <input type="number" min={1} max={48} value={slotsPerDay} onChange={(e) => setSlotsPerDay(Math.max(1, Math.min(48, Number(e.target.value) || 1)))} className={`${INPUT} w-20`} />
                    </label>
                  </div>
                  <p className="text-[10px] text-slate-400">Each slot is its own event with the template's tiers and capacity — the template's own start time is skipped if it coincides.</p>
                </div>
              )}
            </div>

            <div className="bg-white rounded-2xl p-6 shadow-sm space-y-4">
              <label className="block"><span className={LBL}>Series name</span>
                <input type="text" value={name} maxLength={200} onChange={(e) => setName(e.target.value)} className={`${INPUT} w-full`} />
              </label>
              <label className="block"><span className={LBL}>New dates are</span>
                <select value={publish} onChange={(e) => setPublish(e.target.value as typeof publish)} className={INPUT}>
                  <option value="copy">same status as the template ({event.status ?? 'published'})</option>
                  <option value="draft">drafts (review before publishing)</option>
                  <option value="published">published immediately</option>
                </select>
              </label>
            </div>
          </div>

          {/* Preview */}
          <div className="lg:col-span-2">
            <div className="bg-white rounded-2xl p-6 shadow-sm sticky top-6">
              <div className="flex items-center justify-between mb-3">
                <h3 className="text-sm font-bold text-slate-700">Preview</h3>
                <span className="text-[10px] font-black text-slate-400 uppercase tracking-widest">{kept.length} date{kept.length === 1 ? '' : 's'}</span>
              </div>
              {occurrences.length === 0 ? (
                <p className="text-xs text-slate-400">Set a rule to see the dates.</p>
              ) : (
                <ul className="max-h-[360px] overflow-y-auto divide-y divide-slate-50 text-sm">
                  {occurrences.map((d, i) => (
                    <li key={d.toISOString()} className={`flex items-center justify-between py-1.5 ${removed.has(i) ? 'opacity-30 line-through' : ''}`}>
                      <span className="font-mono text-xs text-slate-700">{occurrenceLabel(d, tz)}</span>
                      <button type="button" aria-label={removed.has(i) ? 'Restore date' : 'Remove date'} onClick={() => setRemoved((s) => { const n = new Set(s); if (n.has(i)) n.delete(i); else n.add(i); return n; })} className="p-1 text-slate-300 hover:text-rose-500">
                        <Trash2 size={12} />
                      </button>
                    </li>
                  ))}
                </ul>
              )}
              {occurrences.length >= MAX_OCCURRENCES && (
                <p className="text-[10px] text-amber-600 mt-2">Capped at {MAX_OCCURRENCES} per run — create the rest in a second pass.</p>
              )}
              <button
                type="button"
                onClick={submit}
                disabled={busy || kept.length === 0}
                className="mt-4 w-full flex items-center justify-center gap-2 bg-slate-900 hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-400 text-white py-2.5 rounded-lg font-black uppercase tracking-tighter italic text-xs transition-all"
              >
                {busy ? <Loader2 size={14} className="animate-spin" /> : <Repeat size={14} />}
                {busy ? 'Creating…' : `Create ${kept.length || ''} date${kept.length === 1 ? '' : 's'}`}
              </button>
            </div>
          </div>
        </div>
      </div>
    </motion.div>
  );
}
