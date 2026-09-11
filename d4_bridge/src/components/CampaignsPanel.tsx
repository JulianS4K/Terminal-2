// CampaignsPanel — organizer email campaigns (Stage 5, mig 20260911140000).
//
// Lives on the event report. Composer: pick an audience (event-scoped or
// org-wide), see a live recipient count, write subject + body, then send now
// or schedule. History: this event's and the org's recent campaigns with their
// status. SMS can be drafted but the send RPC refuses it until an SMS provider
// is configured — the panel says so instead of hiding the option.
//
// Every mail carries an unsubscribe link; opted-out people drop out of the
// count automatically (server-side, per org).

import { useCallback, useEffect, useMemo, useState } from 'react';
import { CalendarClock, Mail, MessageSquare, Send, Users, XCircle } from 'lucide-react';
import {
  AUDIENCE_LABEL,
  audienceNeedsEvent,
  cancelCampaign,
  countAudience,
  describeCampaignStatus,
  listCampaigns,
  saveCampaign,
  sendCampaign,
  type AudienceKind,
  type Campaign,
  type CampaignChannel,
} from '../lib/campaigns';
import { useToast } from '../context/ToastContext';

const KINDS = Object.keys(AUDIENCE_LABEL) as AudienceKind[];
const INPUT = 'w-full px-3 py-2 border border-slate-200 rounded-lg text-sm disabled:bg-slate-50';
const LBL = 'block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1';

export default function CampaignsPanel({
  orgId,
  eventId,
  eventStarted,
  canSend,
}: {
  orgId: string;
  eventId: string;
  eventStarted: boolean;
  canSend: boolean;
}) {
  const { toast } = useToast();
  const [kind, setKind] = useState<AudienceKind>('holders');
  const [channel, setChannel] = useState<CampaignChannel>('email');
  const [name, setName] = useState('');
  const [subject, setSubject] = useState('');
  const [body, setBody] = useState('');
  const [when, setWhen] = useState<'now' | 'later'>('now');
  const [scheduledAt, setScheduledAt] = useState('');
  const [count, setCount] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [history, setHistory] = useState<Campaign[]>([]);

  const scopedEventId = audienceNeedsEvent(kind) ? eventId : null;

  const refresh = useCallback(async () => {
    try {
      setHistory(await listCampaigns({ orgId }));
    } catch (err) {
      console.warn('listCampaigns failed:', err);
    }
  }, [orgId]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  useEffect(() => {
    if (!canSend) return undefined;
    let cancelled = false;
    setCount(null);
    countAudience({ orgId, eventId: scopedEventId, kind })
      .then((n) => { if (!cancelled) setCount(n); })
      .catch(() => { if (!cancelled) setCount(null); });
    return () => { cancelled = true; };
  }, [orgId, scopedEventId, kind, canSend]);

  const ready = name.trim() && subject.trim() && body.trim() && (when === 'now' || scheduledAt);

  const submit = async () => {
    if (!ready) return;
    const sched = when === 'later' ? new Date(scheduledAt) : null;
    if (sched && Number.isNaN(sched.getTime())) {
      toast({ kind: 'error', message: 'Pick a valid send time.' });
      return;
    }
    if (
      when === 'now' &&
      !window.confirm(`Send "${subject.trim()}" to ${count ?? 'the'} ${AUDIENCE_LABEL[kind].label.toLowerCase()} now?`)
    )
      return;
    setBusy(true);
    try {
      const id = await saveCampaign({
        orgId, eventId: scopedEventId, name: name.trim(), channel, kind,
        subject: subject.trim(), body: body.trim(), scheduledAt: sched,
      });
      if (when === 'now') {
        const n = await sendCampaign(id);
        toast({ kind: 'success', message: `Sent to ${n} recipient${n === 1 ? '' : 's'}.` });
      } else {
        toast({ kind: 'success', message: `Scheduled for ${sched!.toLocaleString()}.` });
      }
      setName(''); setSubject(''); setBody(''); setScheduledAt(''); setWhen('now');
      await refresh();
    } catch (err: any) {
      console.error('campaign failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not send the campaign.' });
      await refresh();
    } finally {
      setBusy(false);
    }
  };

  const cancel = async (c: Campaign) => {
    if (!window.confirm(`Cancel "${c.name}"?`)) return;
    try {
      await cancelCampaign(c.id);
      await refresh();
    } catch (err: any) {
      toast({ kind: 'error', message: err?.message || 'Could not cancel.' });
    }
  };

  const eventHistory = useMemo(() => history.filter((c) => c.eventId === eventId || !c.eventId), [history, eventId]);

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <div className="flex items-center gap-2 mb-1">
        <Mail className="w-4 h-4 text-slate-500" />
        <h3 className="text-sm font-bold text-slate-700">Campaigns</h3>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Email a segment of your audience — this event's holders, no-shows or waitlist, or everyone who follows or
        has bought from you. Every message carries an unsubscribe link and opt-outs are honoured automatically.
      </p>

      {canSend && (
        <div className="space-y-3 mb-6">
          <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
            <label><span className={LBL}>Audience</span>
              <select value={kind} onChange={(e) => setKind(e.target.value as AudienceKind)} disabled={busy} className={INPUT}>
                {KINDS.map((k) => (
                  <option key={k} value={k} disabled={k === 'no_shows' && !eventStarted}>
                    {AUDIENCE_LABEL[k].label}{k === 'no_shows' && !eventStarted ? ' (after start)' : ''}
                  </option>
                ))}
              </select>
              <span className="block text-[10px] text-slate-400 mt-1">{AUDIENCE_LABEL[kind].help}</span>
            </label>
            <label><span className={LBL}>Channel</span>
              <select value={channel} onChange={(e) => setChannel(e.target.value as CampaignChannel)} disabled={busy} className={INPUT}>
                <option value="email">Email</option>
                <option value="sms">SMS (not configured yet)</option>
              </select>
              {channel === 'sms' && (
                <span className="block text-[10px] text-amber-600 mt-1">
                  SMS drafts save but cannot send until an SMS provider is set up.
                </span>
              )}
            </label>
            <div>
              <span className={LBL}>Recipients</span>
              <p className="text-2xl font-bold text-slate-900 leading-tight flex items-center gap-2">
                <Users size={16} className="text-slate-400" /> {count === null ? '…' : count}
              </p>
            </div>
          </div>
          <label><span className={LBL}>Campaign name (internal)</span>
            <input value={name} maxLength={120} onChange={(e) => setName(e.target.value)} disabled={busy} className={INPUT} placeholder="Post-show thank you" />
          </label>
          <label><span className={LBL}>Subject</span>
            <input value={subject} maxLength={160} onChange={(e) => setSubject(e.target.value)} disabled={busy} className={INPUT} />
          </label>
          <label><span className={LBL}>Message</span>
            <textarea value={body} maxLength={4000} rows={5} onChange={(e) => setBody(e.target.value)} disabled={busy} className={INPUT} placeholder="Plain text. Line breaks are kept." />
          </label>
          <div className="flex flex-wrap items-end gap-3">
            <label><span className={LBL}>When</span>
              <select value={when} onChange={(e) => setWhen(e.target.value as 'now' | 'later')} disabled={busy} className="px-3 py-2 border border-slate-200 rounded-lg text-sm bg-white">
                <option value="now">Send now</option>
                <option value="later">Schedule</option>
              </select>
            </label>
            {when === 'later' && (
              <label><span className={LBL}>Send at</span>
                <input type="datetime-local" value={scheduledAt} onChange={(e) => setScheduledAt(e.target.value)} disabled={busy} className="px-3 py-2 border border-slate-200 rounded-lg text-sm" />
              </label>
            )}
            <button
              type="button"
              onClick={submit}
              disabled={busy || !ready || count === 0}
              className="ml-auto inline-flex items-center gap-2 px-4 py-2 bg-slate-900 hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-400 text-white rounded-lg font-black uppercase tracking-tighter italic text-xs transition-all"
            >
              {when === 'now' ? <Send size={14} /> : <CalendarClock size={14} />}
              {busy ? 'Working…' : when === 'now' ? 'Send campaign' : 'Schedule'}
            </button>
          </div>
        </div>
      )}

      <h4 className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Recent</h4>
      {eventHistory.length === 0 ? (
        <p className="text-xs text-slate-400">No campaigns yet.</p>
      ) : (
        <ul className="divide-y divide-slate-50">
          {eventHistory.slice(0, 10).map((c) => (
            <li key={c.id} className="py-2 flex items-center justify-between gap-3">
              <div className="min-w-0">
                <p className="text-sm font-bold text-slate-800 truncate flex items-center gap-2">
                  {c.channel === 'sms' ? <MessageSquare size={12} className="text-slate-400" /> : <Mail size={12} className="text-slate-400" />}
                  {c.name}
                  <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">{AUDIENCE_LABEL[c.audience.kind]?.label ?? c.audience.kind}</span>
                </p>
                <p className="text-[11px] text-slate-400 truncate">{c.subject} · {describeCampaignStatus(c)}</p>
              </div>
              {canSend && (c.status === 'scheduled' || c.status === 'draft') && (
                <button type="button" onClick={() => cancel(c)} aria-label="Cancel campaign" className="p-1 text-slate-300 hover:text-rose-500">
                  <XCircle size={14} />
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
