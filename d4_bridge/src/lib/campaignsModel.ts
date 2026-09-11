// Organizer campaigns — PURE model (Stage 5, mig 20260911140000).
//
// Types + labels + row mapper. No Supabase import so it unit-tests without a
// client; the RPC wrappers live in ./campaigns.ts.

export type CampaignChannel = 'email' | 'sms';
export type CampaignStatus = 'draft' | 'scheduled' | 'sending' | 'sent' | 'cancelled' | 'failed';
export type AudienceKind = 'holders' | 'no_shows' | 'waitlist' | 'followers' | 'past_attendees' | 'all_buyers';

export interface Campaign {
  id: string;
  orgId: string;
  eventId: string | null;
  name: string;
  channel: CampaignChannel;
  audience: { kind: AudienceKind };
  subject: string;
  body: string;
  status: CampaignStatus;
  scheduledAt: Date | null;
  sentAt: Date | null;
  recipientCount: number;
  error: string | null;
  createdAt: Date;
}

/** Audience kinds that need an event; the rest are org-wide. */
export const EVENT_AUDIENCES: AudienceKind[] = ['holders', 'no_shows', 'waitlist'];

export const AUDIENCE_LABEL: Record<AudienceKind, { label: string; help: string }> = {
  holders: { label: 'Ticket holders', help: 'Everyone holding a live ticket for this event.' },
  no_shows: { label: 'No-shows', help: 'Holders who never scanned in. Available once the event has started.' },
  waitlist: { label: 'Waitlist', help: 'People still waiting or holding an unclaimed offer for this event.' },
  followers: { label: 'Followers', help: 'Everyone following your organization.' },
  past_attendees: { label: 'Past attendees', help: 'Anyone scanned in at any of your events.' },
  all_buyers: { label: 'All buyers', help: 'Anyone holding a live ticket to any of your events.' },
};

export function audienceNeedsEvent(kind: AudienceKind): boolean {
  return EVENT_AUDIENCES.includes(kind);
}

export function mapCampaign(r: any): Campaign {
  return {
    id: String(r.id),
    orgId: String(r.org_id),
    eventId: r.event_id ?? null,
    name: String(r.name ?? ''),
    channel: (r.channel ?? 'email') as CampaignChannel,
    audience: { kind: (r.audience?.kind ?? 'holders') as AudienceKind },
    subject: String(r.subject ?? ''),
    body: String(r.body ?? ''),
    status: (r.status ?? 'draft') as CampaignStatus,
    scheduledAt: r.scheduled_at ? new Date(r.scheduled_at) : null,
    sentAt: r.sent_at ? new Date(r.sent_at) : null,
    recipientCount: Number(r.recipient_count) || 0,
    error: r.error ?? null,
    createdAt: r.created_at ? new Date(r.created_at) : new Date(0),
  };
}

/** One-line status for a list row. */
export function describeCampaignStatus(c: Campaign): string {
  switch (c.status) {
    case 'sent':
      return `Sent to ${c.recipientCount}${c.sentAt ? ` · ${c.sentAt.toLocaleString()}` : ''}`;
    case 'scheduled':
      return c.scheduledAt ? `Scheduled for ${c.scheduledAt.toLocaleString()}` : 'Scheduled';
    case 'sending':
      return 'Sending…';
    case 'failed':
      return `Failed${c.error ? `: ${c.error}` : ''}`;
    case 'cancelled':
      return 'Cancelled';
    default:
      return 'Draft';
  }
}
