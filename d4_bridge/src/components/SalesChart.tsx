// SalesChart — inline SVG sales-over-time chart for OrganizerDashboard.
//
// Reads tickets where organizerId matches the current user (or all
// tickets when admin), buckets purchaseDate by day for the last 30
// days, and renders a stacked line chart: cumulative tickets sold
// (filled area) + daily count (bars beneath).
//
// Why inline SVG instead of recharts/chart.js: avoids an extra ~50KB
// gzipped dep just for one chart on one page. The SVG below is ~150
// lines and renders the only two views we actually need (cumulative
// area + daily bars). When we want richer charts (multiple metrics,
// breakdowns by tier, etc.) we'll evaluate a real chart lib then.

import { useEffect, useMemo, useState } from 'react';
import { Timestamp } from 'firebase/firestore';
import { listEventTickets, listMyOrgTickets, listAllTickets } from '../lib/tickets';
import { Ticket } from '../types';

const DAYS = 30;
const CHART_W = 760;
const CHART_H = 200;
const PAD_T = 16;
const PAD_B = 28;
const PAD_L = 36;
const PAD_R = 12;

interface DayBucket {
  date: Date; // start-of-day in viewer's timezone
  daily: number;
  cumulative: number;
}

interface Props {
  organizerId: string | null; // null = admin / all
  // Drill-in mode: when set, query tickets for this single event and
  // ignore the organizerId+purchaseDate filter (so we see the full
  // sales history of the event, not just the last 30 days). Used by
  // the per-event analytics page.
  eventId?: string;
  // When true, drill-in mode shows the *full* sales lifecycle of the
  // event rather than the last 30 days only. Default: false (rolling
  // 30-day window).
  fullHistory?: boolean;
}

export default function SalesChart({ organizerId, eventId, fullHistory }: Props) {
  const [tickets, setTickets] = useState<Ticket[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      setLoading(true);
      setError(null);
      try {
        // Three scopes, all RLS-gated server-side:
        //   * eventId set      → that event's tickets (staff RLS).
        //   * organizerId null → admin platform-wide sample.
        //   * else             → tickets across the caller's orgs.
        // bucketByDay() windows to the last 30 days client-side regardless,
        // so no server-side purchaseDate filter is needed.
        const ts = eventId
          ? await listEventTickets(eventId)
          : organizerId === null
          ? await listAllTickets()
          : await listMyOrgTickets();
        if (cancelled) return;
        setTickets(ts);
      } catch (err) {
        console.warn('Sales chart query failed:', err);
        if (!cancelled) {
          setError('Sales history not available yet — your first events will populate this chart.');
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [organizerId, eventId, fullHistory]);

  const buckets = useMemo(() => bucketByDay(tickets, DAYS), [tickets]);

  if (loading) {
    return (
      <div className="bg-white rounded-2xl p-6 shadow-sm h-[260px] flex items-center justify-center text-slate-300 text-xs font-bold uppercase tracking-widest animate-pulse">
        Loading chart…
      </div>
    );
  }

  if (error || buckets.every((b) => b.daily === 0)) {
    return (
      <div className="bg-white rounded-2xl p-6 shadow-sm">
        <h3 className="text-sm font-bold text-slate-700 mb-1">Sales — last 30 days</h3>
        <p className="text-xs text-slate-400">
          {error ?? 'No tickets sold in the last 30 days. Once buyers start checking out, this chart fills in automatically.'}
        </p>
      </div>
    );
  }

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm">
      <div className="flex items-baseline justify-between mb-3">
        <div>
          <h3 className="text-sm font-bold text-slate-700">Sales — last 30 days</h3>
          <p className="text-xs text-slate-400">
            {buckets[buckets.length - 1].cumulative} tickets total · peak day {Math.max(...buckets.map((b) => b.daily))}
          </p>
        </div>
      </div>
      <ChartSvg buckets={buckets} />
    </div>
  );
}

function bucketByDay(tickets: Ticket[], days: number): DayBucket[] {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const out: DayBucket[] = [];
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(today);
    d.setDate(today.getDate() - i);
    out.push({ date: d, daily: 0, cumulative: 0 });
  }
  // Map a ticket's purchaseDate to its bucket index.
  for (const t of tickets) {
    const pd = (t.purchaseDate as unknown as Timestamp | undefined)?.toDate?.();
    if (!pd) continue;
    const dayStart = new Date(pd.getFullYear(), pd.getMonth(), pd.getDate());
    const diff = Math.floor(
      (today.getTime() - dayStart.getTime()) / (24 * 60 * 60 * 1000),
    );
    if (diff < 0 || diff >= days) continue;
    out[days - 1 - diff].daily += 1;
  }
  let running = 0;
  for (const b of out) {
    running += b.daily;
    b.cumulative = running;
  }
  return out;
}

function ChartSvg({ buckets }: { buckets: DayBucket[] }) {
  const innerW = CHART_W - PAD_L - PAD_R;
  const innerH = CHART_H - PAD_T - PAD_B;

  const maxCumulative = Math.max(1, ...buckets.map((b) => b.cumulative));
  const maxDaily = Math.max(1, ...buckets.map((b) => b.daily));

  const xStep = innerW / Math.max(1, buckets.length - 1);
  const xFor = (i: number) => PAD_L + xStep * i;
  const yForCumulative = (v: number) => PAD_T + innerH * (1 - v / maxCumulative);

  // Cumulative area path.
  const linePoints = buckets
    .map((b, i) => `${xFor(i)},${yForCumulative(b.cumulative)}`)
    .join(' ');
  const areaPath =
    `M ${xFor(0)},${PAD_T + innerH} ` +
    buckets.map((b, i) => `L ${xFor(i)},${yForCumulative(b.cumulative)}`).join(' ') +
    ` L ${xFor(buckets.length - 1)},${PAD_T + innerH} Z`;

  // Daily bars sized so the tallest day fills ~50% of innerH.
  const barW = Math.max(2, xStep * 0.6);
  const barMaxH = innerH * 0.5;

  return (
    <svg
      role="img"
      aria-label="Daily and cumulative ticket sales over the last 30 days"
      viewBox={`0 0 ${CHART_W} ${CHART_H}`}
      width="100%"
      preserveAspectRatio="xMidYMid meet"
    >
      {/* Y axis ticks for cumulative — 4 marks. */}
      {[0, 0.25, 0.5, 0.75, 1].map((p) => {
        const v = Math.round(maxCumulative * p);
        const y = yForCumulative(v);
        return (
          <g key={p}>
            <line x1={PAD_L} x2={CHART_W - PAD_R} y1={y} y2={y} stroke="#e2e8f0" strokeDasharray="2 2" />
            <text x={PAD_L - 6} y={y + 4} textAnchor="end" fontSize="10" fill="#94a3b8">
              {v}
            </text>
          </g>
        );
      })}
      {/* Daily bars beneath. */}
      {buckets.map((b, i) => {
        if (b.daily === 0) return null;
        const h = barMaxH * (b.daily / maxDaily);
        return (
          <rect
            key={i}
            x={xFor(i) - barW / 2}
            y={PAD_T + innerH - h}
            width={barW}
            height={h}
            fill="#cbd5e1"
            rx={1}
          />
        );
      })}
      {/* Cumulative area + line. */}
      <path d={areaPath} fill="#2563eb" fillOpacity="0.12" />
      <polyline
        points={linePoints}
        fill="none"
        stroke="#2563eb"
        strokeWidth="2"
        strokeLinejoin="round"
        strokeLinecap="round"
      />
      {/* X axis — first, mid, last labels (avoid overdraw). */}
      {[0, Math.floor(buckets.length / 2), buckets.length - 1].map((i) => {
        const b = buckets[i];
        const lbl = `${b.date.getMonth() + 1}/${b.date.getDate()}`;
        return (
          <text
            key={i}
            x={xFor(i)}
            y={CHART_H - 8}
            textAnchor="middle"
            fontSize="10"
            fill="#94a3b8"
          >
            {lbl}
          </text>
        );
      })}
    </svg>
  );
}
