// CompIssuancePanel — bulk comp / guest-list issuance (Stage 3).
//
// Owner / manager paste a list of emails, pick a tier and a quantity per
// person, and `exos_issue_comp_batch` (mig 20260911132000) does the rest in
// one call: account holders get the tickets + a "ticket ready" mail; everyone
// else gets a claim-by-email transfer + an invite mail. The result table shows
// each row's outcome so a sold-out or junk address is visible immediately.
//
// The per-org comp budget (OrgSettings) is enforced server-side: a batch that
// would exceed it is refused whole, and the error text says how much is left.

import { useMemo, useState } from 'react';
import { Gift, Send } from 'lucide-react';
import { issueCompBatch, parseEmailList, summarizeCompBatch, type CompBatchRow } from '../lib/comps';
import { useToast } from '../context/ToastContext';
import type { Event } from '../types';

const OUTCOME_CLS: Record<CompBatchRow['outcome'], string> = {
  issued: 'bg-emerald-50 text-emerald-700 border-emerald-200',
  invited: 'bg-blue-50 text-blue-700 border-blue-200',
  'sold-out': 'bg-amber-50 text-amber-700 border-amber-200',
  invalid: 'bg-rose-50 text-rose-600 border-rose-200',
};

export default function CompIssuancePanel({
  event,
  canIssue,
  onIssued,
}: {
  event: Event;
  canIssue: boolean;
  /** Called with the number of tickets created so the report can refetch. */
  onIssued?: (ticketsCreated: number) => void;
}) {
  const { toast } = useToast();
  const [text, setText] = useState('');
  const [tierId, setTierId] = useState<string>(event.ticketTiers?.[0]?.id ?? '');
  const [qty, setQty] = useState(1);
  const [promoter, setPromoter] = useState('');
  const [busy, setBusy] = useState(false);
  const [rows, setRows] = useState<CompBatchRow[] | null>(null);

  const candidates = useMemo(() => parseEmailList(text), [text]);
  const tiers = event.ticketTiers ?? [];

  if (!canIssue) return null;

  const submit = async () => {
    if (candidates.length === 0) return;
    if (candidates.length > 200) {
      toast({ kind: 'error', message: 'Max 200 recipients per batch — split the list.' });
      return;
    }
    if (
      !window.confirm(
        `Issue ${qty} free ticket${qty === 1 ? '' : 's'} each to ${candidates.length} recipient${candidates.length === 1 ? '' : 's'}? They will be emailed.`,
      )
    )
      return;
    setBusy(true);
    try {
      const result = await issueCompBatch({
        eventId: event.id,
        tierId: tierId || null,
        emails: candidates,
        qtyEach: qty,
        promoterId: promoter.trim() || null,
      });
      setRows(result);
      const s = summarizeCompBatch(result);
      const created = result.reduce((n, r) => n + r.ticketIds.length, 0);
      toast({
        kind: created > 0 ? 'success' : 'info',
        message: `${created} ticket${created === 1 ? '' : 's'} issued — ${s.issued} sent, ${s.invited} invited to claim, ${s['sold-out']} sold out, ${s.invalid} invalid.`,
      });
      if (created > 0) {
        setText('');
        onIssued?.(created);
      }
    } catch (err: any) {
      console.error('exos_issue_comp_batch failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not issue comps.' });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <div className="flex items-center gap-2 mb-1">
        <Gift className="w-4 h-4 text-slate-500" />
        <h3 className="text-sm font-bold text-slate-700">Guest list &amp; comps</h3>
      </div>
      <p className="text-xs text-slate-400 mb-4">
        Paste emails (one per line, or comma-separated). People with an account get their tickets
        straight away; everyone else receives an invite and claims by signing in with that email.
        Comps count against your organization's comp budget.
      </p>

      <textarea
        value={text}
        onChange={(e) => setText(e.target.value)}
        disabled={busy}
        rows={4}
        placeholder={'press@paper.com\nvip@label.com, plus.one@x.com'}
        className="w-full px-3 py-2 border border-slate-200 rounded-lg text-sm font-mono disabled:bg-slate-50"
        aria-label="Recipient emails"
      />

      <div className="flex flex-wrap items-end gap-3 mt-3">
        <label className="text-sm text-slate-700">
          <span className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1">Tier</span>
          <select
            value={tierId}
            onChange={(e) => setTierId(e.target.value)}
            disabled={busy}
            className="px-2 py-1.5 border border-slate-200 rounded text-sm bg-white"
          >
            <option value="">General (no tier)</option>
            {tiers.map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
              </option>
            ))}
          </select>
        </label>
        <label className="text-sm text-slate-700">
          <span className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1">Each</span>
          <input
            type="number"
            min={1}
            max={10}
            value={qty}
            disabled={busy}
            onChange={(e) => setQty(Math.max(1, Math.min(10, Number(e.target.value) || 1)))}
            className="w-16 px-2 py-1.5 border border-slate-200 rounded text-sm"
          />
        </label>
        <label className="text-sm text-slate-700">
          <span className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-1">Attribute to</span>
          <input
            type="text"
            value={promoter}
            disabled={busy}
            maxLength={80}
            onChange={(e) => setPromoter(e.target.value)}
            placeholder="press / sponsor / …"
            className="w-40 px-2 py-1.5 border border-slate-200 rounded text-sm"
          />
        </label>
        <button
          type="button"
          onClick={submit}
          disabled={busy || candidates.length === 0}
          className="ml-auto inline-flex items-center gap-2 px-4 py-2 bg-slate-900 hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-400 text-white rounded-lg font-black uppercase tracking-tighter italic text-xs transition-all"
        >
          <Send size={14} aria-hidden="true" />
          {busy ? 'Issuing…' : `Issue to ${candidates.length || '…'}`}
        </button>
      </div>

      {rows && rows.length > 0 && (
        <div className="mt-5 overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
                <th className="py-2 font-black">Recipient</th>
                <th className="py-2 font-black">Result</th>
                <th className="py-2 font-black text-right">Tickets</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.email} className="border-b border-slate-50 last:border-b-0">
                  <td className="py-2 text-slate-700 font-mono text-xs">{r.email}</td>
                  <td className="py-2">
                    <span className={`inline-block px-2 py-0.5 text-[10px] font-bold uppercase tracking-widest border rounded-full ${OUTCOME_CLS[r.outcome]}`}>
                      {r.outcome}
                    </span>
                    {r.detail && <span className="block text-[10px] text-slate-400 italic mt-1">{r.detail}</span>}
                  </td>
                  <td className="py-2 text-right text-slate-700">{r.ticketIds.length}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
