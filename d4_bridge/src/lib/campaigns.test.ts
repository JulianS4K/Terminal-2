import { describe, it, expect } from 'vitest';
import { audienceNeedsEvent, describeCampaignStatus, mapCampaign } from './campaignsModel';

describe('mapCampaign', () => {
  it('maps a row and defaults missing fields', () => {
    const c = mapCampaign({
      id: 'c1', org_id: 'o1', event_id: null, name: 'Blast', channel: 'email',
      audience: { kind: 'followers' }, subject: 's', body: 'b', status: 'sent',
      scheduled_at: null, sent_at: '2026-09-11T10:00:00Z', recipient_count: '12', error: null,
      created_at: '2026-09-10T10:00:00Z',
    });
    expect(c.audience.kind).toBe('followers');
    expect(c.recipientCount).toBe(12);
    expect(c.sentAt?.toISOString()).toBe('2026-09-11T10:00:00.000Z');
    expect(mapCampaign({ id: 'x', org_id: 'o' }).audience.kind).toBe('holders');
  });
});

describe('audienceNeedsEvent', () => {
  it('event-scoped kinds need an event, org kinds do not', () => {
    expect(audienceNeedsEvent('holders')).toBe(true);
    expect(audienceNeedsEvent('no_shows')).toBe(true);
    expect(audienceNeedsEvent('waitlist')).toBe(true);
    expect(audienceNeedsEvent('followers')).toBe(false);
    expect(audienceNeedsEvent('all_buyers')).toBe(false);
  });
});

describe('describeCampaignStatus', () => {
  const base = mapCampaign({ id: 'c', org_id: 'o', status: 'draft' });
  it('describes each status', () => {
    expect(describeCampaignStatus(base)).toBe('Draft');
    expect(describeCampaignStatus({ ...base, status: 'sent', recipientCount: 3, sentAt: null })).toBe('Sent to 3');
    expect(describeCampaignStatus({ ...base, status: 'failed', error: 'boom' })).toBe('Failed: boom');
    expect(describeCampaignStatus({ ...base, status: 'scheduled', scheduledAt: null })).toBe('Scheduled');
  });
});
