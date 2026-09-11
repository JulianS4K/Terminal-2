// Organizer event analytics — PURE model (D4-OPS-24).
//
// Types, the jsonb → typed mapper for the `exos_event_analytics` document
// (migration 20260911130000) and the two CSV builders. No Supabase import so
// it unit-tests without a client; the RPC wrapper lives in ./analytics.ts.

import { toCsv, type CsvCell } from './csv';
import type { Ticket } from '../types';

export interface AxisRow {
  key: string;
  label: string;
  sold: number;
  used: number;
  revenue: number;
}

export interface DayRow {
  day: string; // YYYY-MM-DD in the event's timezone
  sold: number;
  revenue: number;
  cumulative: number;
}

export interface EventAnalytics {
  eventId: string;
  generatedAt: Date;
  timezone: string;
  eventStarted: boolean;
  capacity: number;
  sold: number;
  used: number;
  unscanned: number;
  voided: number;
  released: number;
  revenue: number;
  checkinRate: number | null;
  noShowRate: number | null;
  firstSaleAt: Date | null;
  lastSaleAt: Date | null;
  salesByDay: DayRow[];
  byTier: AxisRow[];
  byPromoter: AxisRow[];
  byChannel: AxisRow[];
  scans: {
    total: number;
    firstAt: Date | null;
    lastAt: Date | null;
    bySource: Record<string, number>;
    byVerification: Record<string, number>;
  };
  rejects: {
    total: number;
    lastAt: Date | null;
    byReason: { reason: string; count: number }[];
  };
}

const num = (v: unknown): number => (v === null || v === undefined ? 0 : Number(v) || 0);
const rate = (v: unknown): number | null => (v === null || v === undefined ? null : Number(v));
const date = (v: unknown): Date | null => (v ? new Date(String(v)) : null);

function axis(rows: any[], keyField: string, labelField = keyField): AxisRow[] {
  return (rows ?? []).map((r) => ({
    key: String(r?.[keyField] ?? ''),
    label: String(r?.[labelField] ?? r?.[keyField] ?? ''),
    sold: num(r?.sold),
    used: num(r?.used),
    revenue: num(r?.revenue),
  }));
}

export function mapAnalytics(j: any): EventAnalytics {
  return {
    eventId: String(j?.event_id ?? ''),
    generatedAt: date(j?.generated_at) ?? new Date(),
    timezone: String(j?.timezone ?? 'UTC'),
    eventStarted: !!j?.event_started,
    capacity: num(j?.capacity),
    sold: num(j?.sold),
    used: num(j?.used),
    unscanned: num(j?.unscanned),
    voided: num(j?.voided),
    released: num(j?.released),
    revenue: num(j?.revenue),
    checkinRate: rate(j?.checkin_rate),
    noShowRate: rate(j?.no_show_rate),
    firstSaleAt: date(j?.first_sale_at),
    lastSaleAt: date(j?.last_sale_at),
    salesByDay: (j?.sales_by_day ?? []).map((d: any) => ({
      day: String(d?.day ?? ''),
      sold: num(d?.sold),
      revenue: num(d?.revenue),
      cumulative: num(d?.cumulative),
    })),
    byTier: axis(j?.by_tier, 'tier_id', 'tier'),
    byPromoter: axis(j?.by_promoter, 'promoter'),
    byChannel: axis(j?.by_channel, 'channel'),
    scans: {
      total: num(j?.scans?.total),
      firstAt: date(j?.scans?.first_at),
      lastAt: date(j?.scans?.last_at),
      bySource: j?.scans?.by_source ?? {},
      byVerification: j?.scans?.by_verification ?? {},
    },
    rejects: {
      total: num(j?.rejects?.total),
      lastAt: date(j?.rejects?.last_at),
      byReason: (j?.rejects?.by_reason ?? []).map((r: any) => ({
        reason: String(r?.reason ?? ''),
        count: num(r?.count),
      })),
    },
  };
}

// --- CSV builders (pure — unit-tested) ---------------------------------------

/** Summary export: every rollup in the analytics document as sectioned rows. */
export function analyticsSummaryCsv(a: EventAnalytics, eventTitle: string): string {
  const pct = (r: number | null) => (r === null ? '' : `${Math.round(r * 1000) / 10}%`);
  const rows: CsvCell[][] = [
    ['event', eventTitle, '', '', ''],
    ['generated_at', a.generatedAt, '', '', ''],
    ['timezone', a.timezone, '', '', ''],
    ['capacity', a.capacity, '', '', ''],
    ['sold', a.sold, '', '', ''],
    ['checked_in', a.used, '', '', ''],
    ['not_scanned', a.unscanned, '', '', ''],
    ['voided', a.voided, '', '', ''],
    ['released', a.released, '', '', ''],
    ['revenue', a.revenue, '', '', ''],
    ['checkin_rate', pct(a.checkinRate), '', '', ''],
    ['no_show_rate', pct(a.noShowRate), '', '', ''],
    ['rejected_scans', a.rejects.total, '', '', ''],
  ];
  const section = (name: string, cols: string[]) => {
    rows.push(['', '', '', '', '']);
    rows.push([name, ...cols]);
  };
  section('sales_by_day', ['day', 'sold', 'revenue', 'cumulative']);
  for (const d of a.salesByDay) rows.push(['', d.day, d.sold, d.revenue, d.cumulative]);
  for (const [name, list] of [
    ['by_tier', a.byTier],
    ['by_promoter', a.byPromoter],
    ['by_channel', a.byChannel],
  ] as const) {
    section(name, ['label', 'sold', 'checked_in', 'revenue']);
    for (const r of list) rows.push(['', r.label, r.sold, r.used, r.revenue]);
  }
  section('rejects_by_reason', ['reason', 'count', '', '']);
  for (const r of a.rejects.byReason) rows.push(['', r.reason, r.count, '', '']);
  return toCsv(['section', 'key', 'value', 'value_2', 'value_3'], rows);
}

/** Attendee export: one row per ticket (voided included, flagged). */
export function attendeesCsv(tickets: Ticket[]): string {
  const header = [
    'ticket_id', 'status', 'tier', 'attendee_name', 'buyer_email', 'price_paid', 'channel', 'promoter',
    'order_ref', 'purchased_at', 'checked_in_at', 'voided_at', 'voided_reason',
  ];
  const rows = tickets.map((t) => [
    t.id,
    t.status,
    t.tierName ?? '',
    t.attendeeName ?? '',
    t.buyerEmail ?? '',
    t.pricePaid ?? 0,
    t.channelSource ?? 'vibepass',
    t.promoterId ?? '',
    t.orderId ?? '',
    t.purchaseDate ? t.purchaseDate.toDate() : '',
    t.checkInDate ? t.checkInDate.toDate() : '',
    t.voidedAt ? t.voidedAt.toDate() : '',
    t.voidedReason ?? '',
  ]);
  return toCsv(header, rows);
}
