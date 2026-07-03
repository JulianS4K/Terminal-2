// Organizer announcements panel (seller side).
//
// Lives on OrganizerEventReport. Owner/manager compose a free-text update that
// is emailed to every non-voided ticket holder AND shown in-app on each holder's
// ticket. Below the composer is the sent history. Light-theme, matches the
// dashboard styling (mirrors WaitlistPanel). Finance/scanner/content viewers see
// the history read-only (no composer) — `canSend` gates the compose UI; the RPC
// enforces owner/manager server-side regardless.

import { useCallback, useEffect, useState } from 'react';
import { Megaphone, Send, Trash2 } from 'lucide-react';
import { format } from 'date-fns';
import { useToast } from '../context/ToastContext';
import {
  listEventAnnouncements,
  sendAnnouncement,
  deleteAnnouncement,
  type Announcement,
} from '../lib/announcements';

const SUBJECT_MAX = 160;
const BODY_MAX = 4000;

export default function AnnouncementsPanel({
  eventId,
  canSend,
}: {
  eventId: string;
  canSend: boolean;
}) {
  const { toast } = useToast();
  const [items, setItems] = useState<Announcement[]>([]);
  const [loading, setLoading] = useState(true);
  const [subject, setSubject] = useState('');
  const [body, setBody] = useState('');
  const [sending, setSending] = useState(false);
  const [retractingId, setRetractingId] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setItems(await listEventAnnouncements(eventId));
    } finally {
      setLoading(false);
    }
  }, [eventId]);

  useEffect(() => {
    load();
  }, [load]);

  const send = async () => {
    const s = subject.trim();
    const b = body.trim();
    if (!s || !b) {
      toast({ kind: 'warn', message: 'Add a subject and a message first.' });
      return;
    }
    if (
      !window.confirm(
        'Send this update to every current ticket holder? They get an email and an in-app notice on their ticket.',
      )
    )
      return;
    setSending(true);
    try {
      const { recipientCount } = await sendAnnouncement({ eventId, subject: s, body: b });
      toast({
        kind: 'success',
        message:
          recipientCount > 0
            ? `Update sent to ${recipientCount} ticket holder${recipientCount === 1 ? '' : 's'}.`
            : 'Update posted. No ticket holders to email yet — buyers will see it on their ticket.',
      });
      setSubject('');
      setBody('');
      await load();
    } catch (err: any) {
      console.error('sendAnnouncement failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not send the update.' });
    } finally {
      setSending(false);
    }
  };

  const retract = async (a: Announcement) => {
    if (!window.confirm('Retract this update? It disappears from holders’ tickets. Emails already sent are not recalled.'))
      return;
    setRetractingId(a.id);
    try {
      await deleteAnnouncement(a.id);
      setItems((prev) => prev.filter((x) => x.id !== a.id));
      toast({ kind: 'success', message: 'Update retracted.' });
    } catch (err: any) {
      console.error('retract announcement failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not retract the update.' });
    } finally {
      setRetractingId(null);
    }
  };

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <div className="flex items-center gap-2 mb-1">
        <Megaphone className="w-4 h-4 text-slate-500" />
        <h3 className="text-sm font-bold text-slate-700">Attendee updates</h3>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Message everyone holding a ticket — time changes, parking notes, merch drops. Each update
        is emailed to holders and shown on their ticket in the app.
      </p>

      {canSend && (
        <div className="mb-6 space-y-3">
          <div>
            <input
              type="text"
              value={subject}
              maxLength={SUBJECT_MAX}
              onChange={(e) => setSubject(e.target.value)}
              placeholder="Subject — e.g. Doors now open at 7pm"
              className="w-full border-2 border-slate-200 focus:border-slate-900 outline-none px-3 py-2 text-sm font-bold rounded-lg"
            />
          </div>
          <div>
            <textarea
              value={body}
              maxLength={BODY_MAX}
              rows={4}
              onChange={(e) => setBody(e.target.value)}
              placeholder="Your message to ticket holders…"
              className="w-full border-2 border-slate-200 focus:border-slate-900 outline-none px-3 py-2 text-sm rounded-lg resize-y"
            />
            <p className="text-[10px] text-slate-400 text-right mt-1">
              {body.length}/{BODY_MAX}
            </p>
          </div>
          <button
            type="button"
            disabled={sending || !subject.trim() || !body.trim()}
            onClick={send}
            className="w-full flex items-center justify-center gap-2 bg-slate-900 hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-400 text-white py-2.5 rounded-lg font-black uppercase tracking-tighter italic text-xs transition-all"
          >
            <Send size={14} aria-hidden="true" />
            {sending ? 'Sending…' : 'Send update'}
          </button>
        </div>
      )}

      {loading ? (
        <p className="text-xs text-slate-400">Loading updates…</p>
      ) : items.length === 0 ? (
        <p className="text-xs text-slate-400">No updates sent yet.</p>
      ) : (
        <ul className="space-y-3">
          {items.map((a) => (
            <li key={a.id} className="border border-slate-100 rounded-xl p-4">
              <div className="flex items-start justify-between gap-4">
                <p className="text-sm font-bold text-slate-800">{a.subject}</p>
                <div className="flex items-center gap-3 whitespace-nowrap">
                  <span className="text-[10px] font-black text-slate-300 uppercase tracking-widest">
                    {format(a.createdAt, 'MMM d, p')}
                  </span>
                  {canSend && (
                    <button
                      type="button"
                      aria-label="Retract update"
                      disabled={retractingId === a.id}
                      onClick={() => retract(a)}
                      className="p-1 text-slate-300 hover:text-rose-600 transition-colors disabled:opacity-40"
                    >
                      <Trash2 size={14} aria-hidden="true" />
                    </button>
                  )}
                </div>
              </div>
              <p className="text-sm text-slate-600 mt-1 whitespace-pre-wrap">{a.body}</p>
              <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mt-2">
                Emailed {a.recipientCount} holder{a.recipientCount === 1 ? '' : 's'}
              </p>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
