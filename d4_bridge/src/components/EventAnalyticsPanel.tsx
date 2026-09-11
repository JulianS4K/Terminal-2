// EventAnalyticsPanel — organizer analytics (D4-OPS-24).
//
// Renders the server-side analytics document from `exos_event_analytics`:
// attendance funnel (sold → scanned → no-show), sales-by-day sparkbars in the
// event's timezone, and the tier / promoter / channel attribution tables with
// scan-in per row. Two CSV exports: the summary (this document) and the
// attendee list (built from the RLS-gated ticket read the report already does).
//
// Read-only. The role gate is server-side; the report page only mounts this for
// owner / manager / finance / admin.

import { ReactNode, useCallback, useEffect, useState } from 'react';
import { BarChart3, Download, Globe, RefreshCw, ShieldAlert, Tag, UserX, Users } from 'lucide-react';
import {
  analyticsSummaryCsv,
  attendeesCsv,
  getEventAnalytics,
  type AxisRow,
  type EventAnalytics,
} from '../lib/analytics';
import { csvFileName, downloadCsv } from '../lib/csv';
import { formatCurrency } from '../lib/utils';
import type { Ticket } from '../types';

interface Props {
  eventId: string;
  eventTitle: string;
  currency: string;
  /** Full ticket list (already loaded by the report) — feeds the attendee CSV. */
  tickets: Ticket[];
  /** Bump to force a refetch (e.g. after a void / release / comp issue). */
  refreshKey?: number;
}

const pct = (r: number | null) => (r === null ? '—' : `${Math.round(r * 100)}%`);

export default function EventAnalyticsPanel({ eventId, eventTitle, currency, tickets, refreshKey = 0 }: Props) {
  const [data, setData] = useState<EventAnalytics | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setData(await getEventAnalytics(eventId));
      setError(null);
    } catch (err: any) {
      console.error('exos_event_analytics failed:', err);
      setError(err?.message || 'Could not load analytics.');
    } finally {
      setLoading(false);
    }
  }, [eventId]);

  useEffect(() => {
    void load();
  }, [load, refreshKey]);

  const exportSummary = () => {
    if (!data) return;
    downloadCsv(csvFileName(['summary', eventTitle]), analyticsSummaryCsv(data, eventTitle));
  };
  const exportAttendees = () => {
    downloadCsv(csvFileName(['attendees', eventTitle]), attendeesCsv(tickets));
  };

  if (loading && !data) {
    return (
      <div className="bg-white rounded-2xl p-6 shadow-sm mb-8 h-[160px] flex items-center justify-center text-slate-300 text-xs font-bold uppercase tracking-widest animate-pulse">
        Loading analytics…
      </div>
    );
  }
  if (error || !data) {
    return (
      <div className="bg-white rounded-2xl p-6 shadow-sm mb-8">
        <h3 className="text-sm font-bold text-slate-700 mb-2">Analytics</h3>
        <p className="text-xs text-rose-500">{error ?? 'No analytics available.'}</p>
      </div>
    );
  }

  const a = data;
  const maxDay = Math.max(1, ...a.salesByDay.map((d) => d.sold));

  return (
    <div className="mb-8 space-y-6">
      {/* Header + exports */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-sm font-bold text-slate-700">Attendance &amp; attribution</h2>
          <p className="text-[10px] text-slate-400 uppercase tracking-widest font-black mt-1">
            Days in {a.timezone} · updated {a.generatedAt.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            onClick={() => void load()}
            disabled={loading}
            aria-label="Refresh analytics"
            className="inline-flex items-center gap-2 px-3 py-2 bg-white text-slate-700 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest hover:bg-slate-50 disabled:opacity-50 transition-all"
          >
            <RefreshCw size={12} className={loading ? 'animate-spin' : ''} aria-hidden="true" /> Refresh
          </button>
          <button
            type="button"
            onClick={exportAttendees}
            disabled={tickets.length === 0}
            className="inline-flex items-center gap-2 px-3 py-2 bg-white text-slate-900 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest hover:bg-slate-50 disabled:opacity-50 shadow-sm transition-all"
          >
            <Download size={12} aria-hidden="true" /> Attendees CSV
          </button>
          <button
            type="button"
            onClick={exportSummary}
            className="inline-flex items-center gap-2 px-3 py-2 bg-slate-900 text-white rounded text-[10px] font-black uppercase tracking-widest hover:bg-slate-800 transition-all"
          >
            <Download size={12} aria-hidden="true" /> Summary CSV
          </button>
        </div>
      </div>

      {/* Funnel */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <Stat label="Checked in" value={pct(a.checkinRate)} sub={`${a.used} of ${a.sold} tickets`} icon={<Users size={16} />} />
        <Stat
          label="No-show"
          value={pct(a.noShowRate)}
          sub={a.eventStarted ? `${a.unscanned} not scanned` : 'Available once the event starts'}
          icon={<UserX size={16} />}
        />
        <Stat
          label="Rejected scans"
          value={String(a.rejects.total)}
          sub={a.rejects.byReason[0] ? `mostly "${a.rejects.byReason[0].reason}"` : 'none refused at the door'}
          icon={<ShieldAlert size={16} />}
        />
        <Stat
          label="Voided · Released"
          value={`${a.voided} · ${a.released}`}
          sub="refunds/voids · holder releases"
          icon={<Tag size={16} />}
        />
      </div>

      {/* Sales by day */}
      <div className="bg-white rounded-2xl p-6 shadow-sm">
        <h3 className="text-sm font-bold text-slate-700 mb-1">Sales by day</h3>
        {a.salesByDay.length === 0 ? (
          <p className="text-xs text-slate-400">No sales yet.</p>
        ) : (
          <>
            <p className="text-xs text-slate-400 mb-3">
              {a.salesByDay[0].day} → {a.salesByDay[a.salesByDay.length - 1].day} · {a.salesByDay.length} selling day
              {a.salesByDay.length === 1 ? '' : 's'}
            </p>
            <div className="flex items-end gap-[2px] h-16" role="img" aria-label="Tickets sold per day">
              {a.salesByDay.map((d) => (
                <div
                  key={d.day}
                  title={`${d.day}: ${d.sold} sold (${d.cumulative} total)`}
                  className="flex-1 bg-blue-600 rounded-t-sm min-w-[3px]"
                  style={{ height: `${Math.max(6, (d.sold / maxDay) * 100)}%` }}
                />
              ))}
            </div>
          </>
        )}
      </div>

      {/* Attribution axes */}
      <AxisTable title="By tier" rows={a.byTier} currency={currency} empty="No tier breakdown yet — first sale populates this." />
      <AxisTable
        title="By promoter"
        rows={a.byPromoter}
        currency={currency}
        empty="No promoter-attributed sales yet. Buyers who arrive via ?promoter=X are counted here."
      />
      <AxisTable
        title="By channel"
        rows={a.byChannel}
        currency={currency}
        icon={<Globe size={14} />}
        empty="All sales are direct so far."
      />
    </div>
  );
}

function AxisTable({
  title,
  rows,
  currency,
  empty,
  icon,
}: {
  title: string;
  rows: AxisRow[];
  currency: string;
  empty: string;
  icon?: ReactNode;
}) {
  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm">
      <h3 className="text-sm font-bold text-slate-700 mb-3 flex items-center gap-2">
        {icon ?? <BarChart3 size={14} />} {title}
      </h3>
      {rows.length === 0 ? (
        <p className="text-xs text-slate-400">{empty}</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
                <th className="py-2 font-black">{title.replace('By ', '')}</th>
                <th className="py-2 font-black text-right">Sold</th>
                <th className="py-2 font-black text-right">Scanned</th>
                <th className="py-2 font-black text-right">Scan rate</th>
                <th className="py-2 font-black text-right">Revenue</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.key || r.label} className="border-b border-slate-50 last:border-b-0">
                  <td className="py-2 text-slate-700">{r.label}</td>
                  <td className="py-2 text-slate-700 text-right">{r.sold}</td>
                  <td className="py-2 text-slate-700 text-right">{r.used}</td>
                  <td className="py-2 text-slate-500 text-right">{r.sold > 0 ? `${Math.round((r.used / r.sold) * 100)}%` : '—'}</td>
                  <td className="py-2 text-slate-700 text-right">{formatCurrency(r.revenue, currency)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function Stat({ label, value, sub, icon }: { label: string; value: string; sub?: string; icon?: ReactNode }) {
  return (
    <div className="bg-white p-5 rounded border border-slate-200 shadow-sm">
      <div className="flex justify-between items-start mb-3">
        <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest leading-none">{label}</p>
        {icon && <span className="text-slate-400">{icon}</span>}
      </div>
      <p className="text-2xl font-bold text-slate-900 tracking-tight">{value}</p>
      {sub && <p className="text-[10px] text-slate-400 mt-1">{sub}</p>}
    </div>
  );
}
