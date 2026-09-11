// ScanRejectAudit — refused-scan audit for the door (Stage 3).
//
// exos_scan_rejects has been written by the scanner since phase 2 (one row per
// refusal, with reason / source / attempted id) but nothing ever read it back.
// This panel polls the log for the event so door staff and the organizer can
// see, live: how many refusals, which reasons dominate (a spike of 'used' =
// screenshots being passed around; 'wrong-event' = a multi-event night with
// the wrong door), and the most recent attempts with the id that was tried.
//
// Read-only (staff RLS on exos_scan_rejects: owner/manager/finance/scanner/
// content). CSV export for after-show review. 15s poll, same cadence as
// ScanReport; cleared on unmount.

import { useEffect, useMemo, useState } from 'react';
import { Download, ShieldAlert } from 'lucide-react';
import { listEventScanRejects, type ScanRejectRow } from '../lib/tickets';
import { csvFileName, downloadCsv, toCsv } from '../lib/csv';

const REASON_LABEL: Record<string, string> = {
  'wrong-event': 'Wrong event',
  voided: 'Voided / refunded',
  used: 'Already used',
  'in-transfer': 'In transfer',
  'invalid-barcode': 'Bad signature',
  'not-found': 'Not found',
  'expired-code': 'Expired code',
};

const RECENT = 25;

export default function ScanRejectAudit({ eventId, eventTitle }: { eventId: string; eventTitle?: string }) {
  const [rows, setRows] = useState<ScanRejectRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!eventId) return undefined;
    let cancelled = false;
    const load = async () => {
      try {
        const next = await listEventScanRejects(eventId);
        if (cancelled) return;
        setRows(next);
        setError(null);
      } catch (err) {
        if (!cancelled) {
          console.warn('listEventScanRejects failed:', err);
          setError('Could not load the reject log.');
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    };
    void load();
    const poll = setInterval(load, 15000);
    return () => {
      cancelled = true;
      clearInterval(poll);
    };
  }, [eventId]);

  const byReason = useMemo(() => {
    const m = new Map<string, number>();
    for (const r of rows) m.set(r.reason, (m.get(r.reason) ?? 0) + 1);
    return Array.from(m.entries())
      .map(([reason, count]) => ({ reason, count }))
      .sort((a, b) => b.count - a.count);
  }, [rows]);

  const exportCsv = () => {
    const csv = toCsv(
      ['rejected_at', 'reason', 'source', 'ticket_id_attempted', 'wrong_event_id', 'wrong_event_title', 'detail'],
      rows.map((r) => [
        r.rejectedAt.toDate(),
        r.reason,
        r.source,
        r.ticketIdAttempted ?? '',
        r.wrongEventId ?? '',
        r.wrongEventTitle ?? '',
        r.reasonDetail ?? '',
      ]),
    );
    downloadCsv(csvFileName(['scan-rejects', eventTitle]), csv);
  };

  return (
    <div className="bg-white rounded-2xl border border-slate-200 shadow-sm overflow-hidden">
      <div className="px-5 py-4 border-b border-slate-100 flex items-center justify-between gap-2">
        <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest flex items-center gap-2">
          <ShieldAlert className="w-4 h-4 text-rose-500" aria-hidden="true" /> Refused scans
        </h2>
        <div className="flex items-center gap-2">
          <span className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">{rows.length} total</span>
          <button
            type="button"
            onClick={exportCsv}
            disabled={rows.length === 0}
            aria-label="Export refused scans as CSV"
            className="inline-flex items-center gap-1 px-2 py-1 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest text-slate-600 hover:bg-slate-50 disabled:opacity-40"
          >
            <Download className="w-3 h-3" aria-hidden="true" /> CSV
          </button>
        </div>
      </div>

      {loading ? (
        <p className="px-5 py-6 text-xs text-slate-300 font-bold uppercase tracking-widest animate-pulse">Loading…</p>
      ) : error ? (
        <p className="px-5 py-6 text-xs text-rose-500">{error}</p>
      ) : rows.length === 0 ? (
        <p className="px-5 py-6 text-xs text-slate-400 font-bold uppercase tracking-widest">No refusals yet.</p>
      ) : (
        <>
          <ul className="px-5 py-3 border-b border-slate-100 flex flex-wrap gap-2">
            {byReason.map((r) => (
              <li
                key={r.reason}
                className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-rose-50 text-rose-700 border border-rose-200 text-[10px] font-bold uppercase tracking-widest"
              >
                {REASON_LABEL[r.reason] ?? r.reason} <span className="font-mono">{r.count}</span>
              </li>
            ))}
          </ul>
          <ul className="divide-y divide-slate-50 max-h-[320px] overflow-y-auto">
            {rows.slice(0, RECENT).map((r) => (
              <li key={r.id} className="px-5 py-3">
                <div className="flex items-center justify-between gap-3">
                  <p className="text-xs font-bold text-slate-800 truncate">{REASON_LABEL[r.reason] ?? r.reason}</p>
                  <span className="text-[10px] font-mono text-slate-300 shrink-0">
                    {r.rejectedAt.toDate().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                  </span>
                </div>
                <p className="text-[11px] text-slate-400 font-mono truncate">
                  {r.ticketIdAttempted || '—'}
                  <span className="uppercase tracking-tighter"> · {r.source}</span>
                </p>
                {(r.wrongEventTitle || r.reasonDetail) && (
                  <p className="text-[10px] text-slate-400 italic truncate">{r.wrongEventTitle ?? r.reasonDetail}</p>
                )}
              </li>
            ))}
          </ul>
          {rows.length > RECENT && (
            <p className="px-5 py-2 text-[10px] text-slate-400 text-center">
              Showing {RECENT} of {rows.length} — export the CSV for the full log.
            </p>
          )}
        </>
      )}
    </div>
  );
}
