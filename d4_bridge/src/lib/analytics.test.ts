import { describe, it, expect } from 'vitest';
import { mapAnalytics, analyticsSummaryCsv, attendeesCsv } from './analyticsModel';
import { Timestamp } from './timestamp';
import type { Ticket } from '../types';

const doc = {
  event_id: 'e1',
  generated_at: '2026-09-11T12:00:00Z',
  timezone: 'America/New_York',
  event_started: true,
  capacity: 50,
  sold: 4,
  used: 3,
  unscanned: 1,
  voided: 1,
  revenue: '20',
  checkin_rate: '0.75',
  no_show_rate: '0.25',
  first_sale_at: '2026-09-08T12:00:00Z',
  last_sale_at: '2026-09-10T12:00:00Z',
  sales_by_day: [
    { day: '2026-09-08', sold: 2, revenue: 20, cumulative: 2 },
    { day: '2026-09-10', sold: 2, revenue: 0, cumulative: 4 },
  ],
  by_tier: [{ tier_id: 't1', tier: 'GA', sold: 4, used: 3, revenue: 20 }],
  by_promoter: [{ promoter: 'promoA', sold: 2, used: 2, revenue: 20 }],
  by_channel: [
    { channel: 'vibepass', sold: 2, used: 2, revenue: 20 },
    { channel: 'boxoffice', sold: 2, used: 1, revenue: 0 },
  ],
  scans: { total: 3, first_at: null, last_at: '2026-09-11T11:00:00Z', by_source: { camera: 2, manual: 1 }, by_verification: {} },
  rejects: { total: 3, last_at: null, by_reason: [{ reason: 'used', count: 2 }, { reason: 'wrong-event', count: 1 }] },
};

describe('mapAnalytics', () => {
  it('coerces numerics + dates and keeps null rates as null', () => {
    const a = mapAnalytics(doc);
    expect(a.sold).toBe(4);
    expect(a.revenue).toBe(20);
    expect(a.checkinRate).toBe(0.75);
    expect(a.noShowRate).toBe(0.25);
    expect(a.released).toBe(0); // absent until the release migration lands
    expect(a.scans.lastAt?.toISOString()).toBe('2026-09-11T11:00:00.000Z');
    expect(a.scans.firstAt).toBeNull();
    expect(a.byTier[0]).toEqual({ key: 't1', label: 'GA', sold: 4, used: 3, revenue: 20 });
    expect(a.byPromoter[0].label).toBe('promoA');
    expect(a.rejects.byReason[0]).toEqual({ reason: 'used', count: 2 });
  });

  it('tolerates an empty / malformed document', () => {
    const a = mapAnalytics(null);
    expect(a.sold).toBe(0);
    expect(a.noShowRate).toBeNull();
    expect(a.salesByDay).toEqual([]);
    expect(a.rejects.byReason).toEqual([]);
  });

  it('keeps no_show_rate null before the event starts', () => {
    const a = mapAnalytics({ ...doc, event_started: false, no_show_rate: null });
    expect(a.noShowRate).toBeNull();
    expect(a.checkinRate).toBe(0.75);
  });
});

describe('analyticsSummaryCsv', () => {
  it('emits the headline rows and every section', () => {
    const csv = analyticsSummaryCsv(mapAnalytics(doc), 'Big, Show');
    const lines = csv.split('\r\n');
    expect(lines[0]).toBe('section,key,value,value_2,value_3');
    expect(lines[1]).toBe('event,"Big, Show",,,');
    expect(csv).toContain('checkin_rate,75%');
    expect(csv).toContain('no_show_rate,25%');
    expect(csv).toContain('sales_by_day,day,sold,revenue,cumulative');
    expect(csv).toContain(',2026-09-10,2,0,4');
    expect(csv).toContain('by_channel,label,sold,checked_in,revenue');
    expect(csv).toContain(',boxoffice,2,1,0');
    expect(csv).toContain(',wrong-event,1,,');
  });
});

describe('attendeesCsv', () => {
  it('writes one row per ticket with dates as ISO', () => {
    const t: Ticket = {
      id: 'tk1',
      eventId: 'e1',
      buyerId: 'b',
      ownerId: 'o',
      organizerId: '',
      status: 'used',
      purchaseDate: Timestamp.fromDate(new Date('2026-09-08T12:00:00Z')),
      checkInDate: Timestamp.fromDate(new Date('2026-09-11T10:30:00Z')),
      barcodeValue: '',
      tierName: 'GA',
      attendeeName: 'Ada Lovelace',
      buyerEmail: 'a@x.com',
      pricePaid: 10,
      promoterId: '=evil',
      orderId: 'ord1',
    };
    const csv = attendeesCsv([t]);
    const lines = csv.split('\r\n');
    expect(lines[0].startsWith('ticket_id,status,tier,attendee_name,buyer_email')).toBe(true);
    expect(lines[1]).toBe(
      "tk1,used,GA,Ada Lovelace,a@x.com,10,vibepass,'=evil,ord1,2026-09-08T12:00:00.000Z,2026-09-11T10:30:00.000Z,,",
    );
  });
});
