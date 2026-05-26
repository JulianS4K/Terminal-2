// ScanReport — per-event door-scan analytics with live-ish updates.
//
// Reads the exos_event_checkins audit log (one row per check-in) on a
// short poll so an organizer watching during the show sees scans roll in
// as staff check attendees in. The table is append-only (written only by
// the exos_check_in_ticket RPC), so entries only ever accumulate.
//
// What this surfaces:
//   * Top stat row — total scanned, last scan, peak rate, distinct
//     stations and scanners working the door.
//   * Scan-rate-over-time chart — per-minute buckets across the
//     event's actual scan window (first to last entry), rendered as
//     a small inline SVG bar chart (no chart-lib dep, same pattern
//     as SalesChart).
//   * Per-scanner breakdown — uid + count + first/last scan.
//   * Per-station breakdown — same shape, by station name.
//   * Recent-scans timeline — last N scans with timestamp + scanner
//     + station + ticket id.
//
// What this DOES NOT show:
//   * Failed / rejected scan attempts. The audit log only writes on
//     successful scans (the OrganizerCheckIn flow surfaces failures
//     locally via toast). To track rejects we'd need a separate
//     write path on the scanner side, which is a future addition.
//   * Buyer name / email. We have the ticketId, but the ticket doc
//     would need a join. Skipped for now — the ticketId is enough
//     for cross-referencing with the existing CSV export.

import { ReactNode, useEffect, useMemo, useState } from 'react';
import { listEventCheckins } from '../lib/tickets';
import { Activity, Clock, MapPin, User as UserIcon } from 'lucide-react';

interface CheckIn {
  ticketId: string;
  // Firebase Auth uid of the staff member whose device scanned. We
  // only persist the uid in the audit log (not displayName) — the
  // report displays the trailing slice for visual differentiation.
  scanner: string;
  // Where the scan came from. Maps to the `source` field on the audit
  // doc: 'camera', 'manual', 'offline-camera', 'offline-manual',
  // 'offline-attest'. Used as the "station" axis in the report — most
  // small events run one station per source.
  station: string;
  // Verification mode — 'verified' (HMAC ok), 'legacy' (pre-HMAC
  // ticket), 'offline-cached' (registry-verified offline), or
  // 'attest-admit' (manual override on reconnect).
  verification: string;
  // Door time. Prefer offlineScannedAt when present (offline scans
  // recorded the *real* arrival moment, not the moment WiFi came
  // back); fall back to scannedAt (server-stamped at write).
  at: Date | null;
}

interface Props {
  eventId: string;
  // Capacity for "checked in / capacity" framing. Optional — falls
  // back to just showing the absolute count.
  totalSold?: number;
}

const RECENT_SCANS_DEFAULT = 30;

export default function ScanReport({ eventId, totalSold }: Props) {
  const [checkIns, setCheckIns] = useState<CheckIn[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!eventId) return undefined;
    let cancelled = false;
    setLoading(true);
    setError(null);
    // Polled load (replaces the Firestore onSnapshot live subscription).
    // Scans roll in on a ~15s cadence while door staff work the event;
    // the interval is cleared on unmount.
    const load = async () => {
      try {
        const rows = await listEventCheckins(eventId);
        if (cancelled) return;
        const next: CheckIn[] = rows.map((r) => ({
          ticketId: r.ticketId,
          scanner: r.scannedBy || 'unknown',
          station: r.source || 'unknown',
          verification: r.verification || 'unknown',
          at: r.scannedAt ? r.scannedAt.toDate() : null,
        }));
        // Newest-first for the timeline; the bucket math is order-agnostic.
        next.sort((a, b) => (b.at?.getTime() ?? 0) - (a.at?.getTime() ?? 0));
        setCheckIns(next);
        setError(null);
      } catch (err) {
        if (!cancelled) {
          console.warn('Scan report load failed:', err);
          setError('Could not load scans — usually means the event has no scans yet.');
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

  const stats = useMemo(() => deriveStats(checkIns), [checkIns]);

  if (loading) {
    return (
      <div className="bg-white rounded-2xl p-6 shadow-sm h-[200px] flex items-center justify-center text-slate-300 text-xs font-bold uppercase tracking-widest animate-pulse">
        Loading scan log…
      </div>
    );
  }

  if (error || checkIns.length === 0) {
    return (
      <div className="bg-white rounded-2xl p-6 shadow-sm">
        <h3 className="text-sm font-bold text-slate-700 mb-2 flex items-center gap-2">
          <Activity size={14} /> Door scans
        </h3>
        <p className="text-xs text-slate-400">
          {error ?? 'No scans yet. As door staff check attendees in, this report fills in live — no refresh needed.'}
        </p>
      </div>
    );
  }

  const checkInRate = totalSold && totalSold > 0
    ? Math.round((checkIns.length / totalSold) * 100)
    : null;

  return (
    <div className="space-y-6">
      {/* Stats row */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <Stat
          label="Total Scanned"
          value={
            checkInRate !== null
              ? `${checkIns.length} / ${totalSold}`
              : `${checkIns.length}`
          }
          sub={checkInRate !== null ? `${checkInRate}% checked in` : undefined}
          icon={<Activity size={16} />}
        />
        <Stat
          label="Last Scan"
          value={stats.lastScan ? formatTimeAgo(stats.lastScan) : '—'}
          sub={stats.lastScan ? formatClockTime(stats.lastScan) : undefined}
          icon={<Clock size={16} />}
        />
        <Stat
          label="Peak Rate"
          value={`${stats.peakPerMinute}/min`}
          sub={stats.peakMinute ? formatClockTime(stats.peakMinute) : undefined}
          icon={<Activity size={16} />}
        />
        <Stat
          label="Stations · Staff"
          value={`${stats.uniqueStations} · ${stats.uniqueScanners}`}
          icon={<MapPin size={16} />}
        />
      </div>

      {/* Scan rate over time */}
      {stats.buckets.length > 0 && (
        <div className="bg-white rounded-2xl p-6 shadow-sm">
          <h3 className="text-sm font-bold text-slate-700 mb-1">Scan rate</h3>
          <p className="text-xs text-slate-400 mb-3">
            {formatClockTime(stats.firstScan!)} → {formatClockTime(stats.lastScan!)} ·
            per-minute buckets
          </p>
          <ScanRateChart buckets={stats.buckets} peak={stats.peakPerMinute} />
        </div>
      )}

      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        {/* Per-station */}
        <div className="bg-white rounded-2xl p-6 shadow-sm">
          <h3 className="text-sm font-bold text-slate-700 mb-3 flex items-center gap-2">
            <MapPin size={14} /> By station
          </h3>
          <table className="w-full text-sm">
            <tbody>
              {stats.stations.map((s) => (
                <tr key={s.name} className="border-b border-slate-50 last:border-b-0">
                  <td className="py-2 text-slate-700 font-bold">{s.name}</td>
                  <td className="py-2 text-slate-500 text-right">{s.count}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Per-scanner */}
        <div className="bg-white rounded-2xl p-6 shadow-sm">
          <h3 className="text-sm font-bold text-slate-700 mb-3 flex items-center gap-2">
            <UserIcon size={14} /> By staff
          </h3>
          <table className="w-full text-sm">
            <tbody>
              {stats.scanners.map((s) => (
                <tr key={s.uid} className="border-b border-slate-50 last:border-b-0">
                  <td className="py-2 text-slate-700 font-mono text-xs truncate max-w-[200px]">{s.uid}</td>
                  <td className="py-2 text-slate-500 text-right">{s.count}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {/* Recent scans timeline */}
      <div className="bg-white rounded-2xl p-6 shadow-sm">
        <h3 className="text-sm font-bold text-slate-700 mb-3 flex items-center gap-2">
          <Clock size={14} /> Recent scans
        </h3>
        <div className="space-y-2">
          {checkIns.slice(0, RECENT_SCANS_DEFAULT).map((c) => (
            <div
              key={c.ticketId}
              className="flex items-center justify-between gap-3 py-2 border-b border-slate-50 last:border-b-0"
            >
              <div className="flex-1 min-w-0">
                <div className="text-xs font-mono text-slate-700 truncate">{c.ticketId}</div>
                <div className="text-[10px] text-slate-400 font-bold uppercase tracking-widest">
                  {c.station} · {c.scanner.slice(0, 12)}{c.scanner.length > 12 ? '…' : ''}
                </div>
              </div>
              <div className="text-xs text-slate-500 font-mono flex-shrink-0">
                {c.at ? formatClockTime(c.at) : '—'}
              </div>
            </div>
          ))}
          {checkIns.length > RECENT_SCANS_DEFAULT && (
            <p className="text-xs text-slate-400 mt-3 text-center">
              Showing {RECENT_SCANS_DEFAULT} of {checkIns.length}. Older scans available via the CSV export on the check-in page.
            </p>
          )}
        </div>
      </div>
    </div>
  );
}

// ---- Helpers --------------------------------------------------------

interface DerivedStats {
  firstScan: Date | null;
  lastScan: Date | null;
  peakPerMinute: number;
  peakMinute: Date | null;
  uniqueStations: number;
  uniqueScanners: number;
  stations: { name: string; count: number }[];
  scanners: { uid: string; count: number }[];
  buckets: { at: Date; count: number }[];
}

function deriveStats(checkIns: CheckIn[]): DerivedStats {
  if (checkIns.length === 0) {
    return {
      firstScan: null,
      lastScan: null,
      peakPerMinute: 0,
      peakMinute: null,
      uniqueStations: 0,
      uniqueScanners: 0,
      stations: [],
      scanners: [],
      buckets: [],
    };
  }
  // Min/max times.
  let first: number | null = null;
  let last: number | null = null;
  for (const c of checkIns) {
    const t = c.at?.getTime();
    if (!t) continue;
    if (first === null || t < first) first = t;
    if (last === null || t > last) last = t;
  }

  // Per-minute buckets across the actual scan window. Cap at 120
  // buckets so a multi-day event doesn't render an unreadable strip.
  const buckets: { at: Date; count: number }[] = [];
  if (first !== null && last !== null) {
    const minuteMs = 60_000;
    const startMin = Math.floor(first / minuteMs);
    const endMin = Math.floor(last / minuteMs);
    const span = Math.min(120, Math.max(1, endMin - startMin + 1));
    const bucketWidthMin = Math.ceil((endMin - startMin + 1) / span);
    for (let i = 0; i < span; i++) {
      buckets.push({
        at: new Date((startMin + i * bucketWidthMin) * minuteMs),
        count: 0,
      });
    }
    for (const c of checkIns) {
      const t = c.at?.getTime();
      if (!t) continue;
      const idx = Math.min(span - 1, Math.floor((Math.floor(t / minuteMs) - startMin) / bucketWidthMin));
      if (idx >= 0 && idx < buckets.length) buckets[idx].count += 1;
    }
  }
  const peakBucket = buckets.reduce(
    (max, b) => (b.count > max.count ? b : max),
    { at: null as Date | null, count: 0 },
  );

  // Per-station and per-scanner.
  const stationMap = new Map<string, number>();
  const scannerMap = new Map<string, number>();
  for (const c of checkIns) {
    stationMap.set(c.station, (stationMap.get(c.station) ?? 0) + 1);
    scannerMap.set(c.scanner, (scannerMap.get(c.scanner) ?? 0) + 1);
  }
  const stations = Array.from(stationMap.entries())
    .map(([name, count]) => ({ name, count }))
    .sort((a, b) => b.count - a.count);
  const scanners = Array.from(scannerMap.entries())
    .map(([uid, count]) => ({ uid, count }))
    .sort((a, b) => b.count - a.count);

  return {
    firstScan: first !== null ? new Date(first) : null,
    lastScan: last !== null ? new Date(last) : null,
    peakPerMinute: peakBucket.count,
    peakMinute: peakBucket.at,
    uniqueStations: stations.length,
    uniqueScanners: scanners.length,
    stations,
    scanners,
    buckets,
  };
}

function formatTimeAgo(d: Date): string {
  const diffSec = Math.floor((Date.now() - d.getTime()) / 1000);
  if (diffSec < 60) return `${diffSec}s ago`;
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)}m ago`;
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}h ago`;
  return `${Math.floor(diffSec / 86400)}d ago`;
}

function formatClockTime(d: Date): string {
  return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}

function Stat({
  label,
  value,
  sub,
  icon,
}: {
  label: string;
  value: string;
  sub?: string;
  icon?: ReactNode;
}) {
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

function ScanRateChart({
  buckets,
  peak,
}: {
  buckets: { at: Date; count: number }[];
  peak: number;
}) {
  // Inline SVG bar chart. Same pattern as SalesChart but simpler —
  // single-series bars, no cumulative line, no axis labels (the
  // surrounding stat cards already carry first/last/peak times).
  const W = 760;
  const H = 100;
  const PAD = 4;
  const innerW = W - PAD * 2;
  const innerH = H - PAD * 2;
  const max = Math.max(1, peak);
  const barW = Math.max(1, innerW / buckets.length - 1);
  return (
    <svg
      role="img"
      aria-label="Scan rate over time"
      viewBox={`0 0 ${W} ${H}`}
      width="100%"
      preserveAspectRatio="xMidYMid meet"
    >
      {buckets.map((b, i) => {
        if (b.count === 0) return null;
        const h = innerH * (b.count / max);
        return (
          <rect
            key={i}
            x={PAD + (innerW / buckets.length) * i}
            y={PAD + innerH - h}
            width={barW}
            height={h}
            fill="#2563eb"
            rx={1}
          />
        );
      })}
    </svg>
  );
}
