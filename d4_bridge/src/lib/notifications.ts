// Notifications — the aggregation layer for the alerts feed
// (/alerts, views/Notifications.tsx).
//
// Exos has no dedicated notifications table; the feed is DERIVED from signals
// that already exist and that the viewer can already read under RLS:
//
//   tickets  — inbound + outbound ticket transfers (exos_transfers)
//   events   — upcoming-event reminders (the viewer's own active tickets whose
//              event starts within 24h / 2h — mirrors the server-side mail cron
//              exos_send_event_reminders, mig 20260911051000, so the in-app
//              alert and the email say the same thing),
//              cancellations (ticketed events with status = 'cancelled'),
//              organizer announcements (exos_event_announcements — holder policy),
//              reschedules (exos_event_reschedules — holder policy),
//              price-step nudges for SAVED events (exos_event_saves +
//              exos_public_tiers.price_schedule via lib/pricing nextPriceStep).
//
// Each resolver is a PURE function over already-fetched rows (unit-tested in
// notifications.test.ts); listNotifications() does the fetching and merges.
// Every fetch is best-effort: a failing source contributes nothing rather than
// throwing, so one missing table never blanks the feed.
//
// Read-state is server-side (exos_notification_reads, mig 20260709120000, keyed
// by the stable ids below) unioned with anything cleared locally this session.
// Ids are deterministic per signal + window so a reminder read once stays read.

import { listInboundTransfers, listOutboundTransfers, listMyTickets } from './tickets';
import { supabase } from './supabase';
import { listSavedEvents } from './saves';
import { nextPriceStep } from './pricing';
import { formatInTz } from './datetime';
import { formatCurrency } from './utils';
import { Event, Ticket, Transfer } from '../types';

export type NotificationCategory = 'tickets' | 'events';
export type NotificationIcon = 'transfer' | 'ticket' | 'reminder' | 'drop' | 'price' | 'announce' | 'cancel';

export interface NotificationItem {
  id: string;
  category: NotificationCategory;
  icon: NotificationIcon;
  /** Tone colour (hex) for the icon chip / accents. */
  tone: string;
  title: string;
  body: string;
  /** Epoch ms for sorting + relative-time rendering. */
  ts: number;
  unread: boolean;
  /** In-app route to open when tapped. */
  to: string;
}

const GREEN = '#00FF00';
const MAGENTA = '#FF00FF';
const RED = '#FF3B3B';
const AMBER = '#FFB000';

const HOUR = 3600_000;
const DAY = 24 * HOUR;
/** Announcements / reschedules older than this are shown but not unread. */
const FRESH_WINDOW_MS = 14 * DAY;
/** Price-step nudges only for steps landing within this window. */
const PRICE_STEP_WINDOW_MS = 7 * DAY;

function tsMs(t: Transfer['createdAt']): number {
  try {
    return t?.toDate ? t.toDate().getTime() : 0;
  } catch {
    return 0;
  }
}

function inboundToItem(t: Transfer): NotificationItem {
  const who = t.senderEmail ? t.senderEmail.split('@')[0] : 'Someone';
  const evt = t.eventTitle ? ` to ${t.eventTitle}` : '';
  if (t.status === 'pending') {
    return {
      id: `in-${t.id}`,
      category: 'tickets',
      icon: 'transfer',
      tone: GREEN,
      title: `${who} sent you a ticket`,
      body: `${t.tierName || '1 ticket'}${evt} · tap to add it to your vault`,
      ts: tsMs(t.createdAt),
      unread: true,
      to: `/claim/${t.id}`,
    };
  }
  return {
    id: `in-${t.id}`,
    category: 'tickets',
    icon: 'ticket',
    tone: GREEN,
    title: `You claimed a ticket`,
    body: `${t.tierName || 'Ticket'}${evt} is in your vault`,
    ts: tsMs(t.updatedAt || t.createdAt),
    unread: false,
    to: '/my-tickets',
  };
}

function outboundToItem(t: Transfer): NotificationItem {
  const to = t.receiverEmail || 'a friend';
  const evt = t.eventTitle ? ` for ${t.eventTitle}` : '';
  if (t.status === 'pending') {
    return {
      id: `out-${t.id}`,
      category: 'tickets',
      icon: 'transfer',
      tone: MAGENTA,
      title: `Transfer in flight`,
      body: `Waiting for ${to} to claim your ticket${evt}`,
      ts: tsMs(t.createdAt),
      unread: false,
      to: '/my-tickets',
    };
  }
  if (t.status === 'cancelled') {
    return {
      id: `out-${t.id}`,
      category: 'tickets',
      icon: 'transfer',
      tone: RED,
      title: `Transfer returned`,
      body: `The ticket you sent to ${to} wasn't claimed — it's back in your vault`,
      ts: tsMs(t.updatedAt || t.createdAt),
      unread: false,
      to: '/my-tickets',
    };
  }
  return {
    id: `out-${t.id}`,
    category: 'tickets',
    icon: 'ticket',
    tone: GREEN,
    title: `Ticket claimed`,
    body: `${to} claimed the ticket you sent${evt}`,
    ts: tsMs(t.updatedAt || t.createdAt),
    unread: false,
    to: '/my-tickets',
  };
}

// --- Server-side read-state (mig 20260709120000_exos_notification_reads) ----
// Persists which notification ids the viewer has opened/cleared. Until the
// migration is applied to prod these degrade to a no-op: listReadNotificationIds
// returns an empty Set and markNotificationsRead swallows the error, so the
// feed keeps working with client-only read-state in the meantime.

/**
 * Read the set of notification ids the current viewer has marked read.
 * Best-effort: returns an empty Set on ANY error (e.g. table not yet migrated),
 * so callers can safely union it with local state.
 */
export async function listReadNotificationIds(): Promise<Set<string>> {
  try {
    const { data, error } = await supabase.from('exos_notification_reads').select('notif_id');
    if (error) return new Set();
    return new Set((data ?? []).map((r: { notif_id: string }) => r.notif_id));
  } catch {
    return new Set();
  }
}

/**
 * Mark the given notification ids read for the current viewer. No-op on empty
 * input. Errors are swallowed (console.warn only) so a missing table / RPC
 * never breaks the optimistic UI.
 */
export async function markNotificationsRead(ids: string[]): Promise<void> {
  if (ids.length === 0) return;
  try {
    const { error } = await supabase.rpc('exos_mark_notifications_read', { p_ids: ids });
    if (error) console.warn('markNotificationsRead failed', error);
  } catch (err) {
    console.warn('markNotificationsRead failed', err);
  }
}

// --- Event-side resolvers (pure) ---------------------------------------------

export type TicketWithEvent = Ticket & { event?: Event };

/** One holder-visible announcement row (exos_event_announcements). */
export interface AnnouncementRow {
  id: string;
  event_id: string;
  subject: string | null;
  body: string | null;
  created_at: string | null;
}

/** One holder-visible reschedule row (exos_event_reschedules). */
export interface RescheduleRow {
  id: string;
  event_id: string;
  old_starts_at: string | null;
  new_starts_at: string;
  reason: string | null;
  created_at: string | null;
}

/** Minimal tier shape needed for price-step nudges (exos_public_tiers). */
export interface TierRow {
  event_id: string;
  name: string | null;
  price_schedule: unknown;
}

function eventMs(e: Event | undefined): number {
  try {
    return e?.date?.toDate ? e.date.toDate().getTime() : 0;
  } catch {
    return 0;
  }
}

function tsToMs(t: { toDate?: () => Date } | undefined): number {
  try {
    return t?.toDate ? t.toDate().getTime() : 0;
  } catch {
    return 0;
  }
}

function isoMs(iso: string | null | undefined): number {
  const t = iso ? Date.parse(iso) : NaN;
  return Number.isFinite(t) ? t : 0;
}

function truncate(text: string, max = 140): string {
  const one = text.replace(/\s+/g, ' ').trim();
  return one.length > max ? `${one.slice(0, max - 1)}…` : one;
}

/**
 * Group the viewer's tickets by event, keeping the first ticket (the deep-link
 * target) and the event. Voided tickets are excluded — a voided holder gets no
 * reminder (mirrors the mail cron's `status <> 'voided'`).
 */
export function ticketsByEvent(tickets: TicketWithEvent[]): Map<string, { ticket: TicketWithEvent; event?: Event }> {
  const out = new Map<string, { ticket: TicketWithEvent; event?: Event }>();
  for (const t of tickets) {
    if (t.status === 'voided') continue;
    if (!out.has(t.eventId)) out.set(t.eventId, { ticket: t, event: t.event });
  }
  return out;
}

/**
 * Upcoming-event reminders: one item per ticketed event starting within 24h.
 * Inside 2h the item flips to the "starts soon" form with its own id, so a
 * holder who cleared the day-before alert still gets the doors-soon one.
 * Only ACTIVE tickets qualify (a used ticket is already inside).
 */
export function reminderItems(tickets: TicketWithEvent[], now: number = Date.now()): NotificationItem[] {
  const items: NotificationItem[] = [];
  const seen = new Set<string>();
  for (const t of tickets) {
    if (t.status !== 'active' || !t.event || seen.has(t.eventId)) continue;
    const e = t.event;
    if (e.status === 'cancelled') continue;
    const at = eventMs(e);
    if (!at || at <= now || at > now + DAY) continue;
    seen.add(t.eventId);
    const when = formatInTz(new Date(at), e.timezone, { weekday: 'short', hour: 'numeric', minute: '2-digit' });
    const where = e.location ? ` · ${e.location}` : '';
    const soon = at <= now + 2 * HOUR;
    const mins = Math.max(1, Math.round((at - now) / 60_000));
    items.push({
      id: soon ? `rem-2h-${t.eventId}` : `rem-24h-${t.eventId}`,
      category: 'events',
      icon: 'reminder',
      tone: soon ? AMBER : GREEN,
      title: soon
        ? `${e.title} starts in ${mins >= 60 ? `${Math.round(mins / 60)}h` : `${mins}m`}`
        : `Tomorrow: ${e.title}`,
      body: `${when}${where} · open your ticket for the live entry code`,
      ts: soon ? at - 2 * HOUR : at - DAY,
      unread: true,
      to: `/ticket/${t.id}`,
    });
  }
  return items;
}

/** Cancelled events the viewer holds a (non-voided) ticket for. */
export function cancellationItems(tickets: TicketWithEvent[]): NotificationItem[] {
  const items: NotificationItem[] = [];
  for (const [eventId, { ticket, event }] of ticketsByEvent(tickets)) {
    if (!event || event.status !== 'cancelled') continue;
    items.push({
      id: `can-${eventId}`,
      category: 'events',
      icon: 'cancel',
      tone: RED,
      title: `Cancelled: ${event.title}`,
      body: event.cancelReason
        ? truncate(event.cancelReason)
        : 'Open your ticket for details and any refund information.',
      ts: tsToMs(event.cancelledAt) || Date.now(),
      unread: true,
      to: `/ticket/${ticket.id}`,
    });
  }
  return items;
}

/** Organizer announcements for events the viewer holds a ticket for. */
export function announcementItems(
  rows: AnnouncementRow[],
  byEvent: Map<string, { ticket: TicketWithEvent; event?: Event }>,
  now: number = Date.now(),
): NotificationItem[] {
  return rows.map((a) => {
    const hit = byEvent.get(a.event_id);
    const title = hit?.event?.title;
    const ts = isoMs(a.created_at);
    return {
      id: `ann-${a.id}`,
      category: 'events' as const,
      icon: 'announce' as const,
      tone: MAGENTA,
      title: title ? `${title}: ${a.subject ?? 'Update'}` : a.subject ?? 'Organizer update',
      body: truncate(a.body ?? ''),
      ts,
      unread: now - ts < FRESH_WINDOW_MS,
      to: hit ? `/ticket/${hit.ticket.id}` : `/event/${a.event_id}`,
    };
  });
}

/** Reschedules for events the viewer holds a ticket for. */
export function rescheduleItems(
  rows: RescheduleRow[],
  byEvent: Map<string, { ticket: TicketWithEvent; event?: Event }>,
  now: number = Date.now(),
): NotificationItem[] {
  return rows.map((r) => {
    const hit = byEvent.get(r.event_id);
    const tz = hit?.event?.timezone;
    const newAt = isoMs(r.new_starts_at);
    const oldAt = isoMs(r.old_starts_at);
    const fmt = (ms: number) => formatInTz(new Date(ms), tz, { dateStyle: 'medium', timeStyle: 'short' });
    const ts = isoMs(r.created_at);
    const parts = [`Now ${fmt(newAt)}`];
    if (oldAt) parts.push(`was ${fmt(oldAt)}`);
    if (r.reason) parts.push(truncate(r.reason, 80));
    return {
      id: `res-${r.id}`,
      category: 'events' as const,
      icon: 'reminder' as const,
      tone: AMBER,
      title: `Rescheduled: ${hit?.event?.title ?? 'your event'}`,
      body: parts.join(' · '),
      ts,
      unread: now - ts < FRESH_WINDOW_MS,
      to: hit ? `/ticket/${hit.ticket.id}` : `/event/${r.event_id}`,
    };
  });
}

/**
 * Price-step nudges for SAVED events: the earliest upcoming step across the
 * event's public tiers, if it lands within a week. One item per event.
 */
export function priceStepItems(
  saved: Event[],
  tiers: TierRow[],
  now: number = Date.now(),
): NotificationItem[] {
  const items: NotificationItem[] = [];
  const nowDate = new Date(now);
  for (const e of saved) {
    if (e.status === 'cancelled') continue;
    let best: { at: number; tier: string; price: number } | null = null;
    for (const t of tiers) {
      if (t.event_id !== e.id) continue;
      const step = nextPriceStep(t.price_schedule, nowDate);
      if (!step) continue;
      const at = Date.parse(step.startsAt);
      if (at - now > PRICE_STEP_WINDOW_MS) continue;
      if (!best || at < best.at) best = { at, tier: t.name ?? 'Tickets', price: step.price };
    }
    if (!best) continue;
    const when = formatInTz(new Date(best.at), e.timezone, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
    items.push({
      id: `price-${e.id}-${best.at}`,
      category: 'events',
      icon: 'price',
      tone: MAGENTA,
      title: `Price rises soon: ${e.title}`,
      body: `${best.tier} goes to ${formatCurrency(best.price, e.currency || 'USD')} on ${when} · you saved this event`,
      ts: now,
      unread: true,
      to: `/event/${e.id}`,
    });
  }
  return items;
}

// --- Fetchers (best-effort) ---------------------------------------------------

async function fetchAnnouncements(): Promise<AnnouncementRow[]> {
  try {
    const { data, error } = await supabase
      .from('exos_event_announcements')
      .select('id, event_id, subject, body, created_at')
      .order('created_at', { ascending: false })
      .limit(50);
    if (error) return [];
    return (data ?? []) as AnnouncementRow[];
  } catch {
    return [];
  }
}

async function fetchReschedules(): Promise<RescheduleRow[]> {
  try {
    const { data, error } = await supabase
      .from('exos_event_reschedules')
      .select('id, event_id, old_starts_at, new_starts_at, reason, created_at')
      .order('created_at', { ascending: false })
      .limit(50);
    if (error) return [];
    return (data ?? []) as RescheduleRow[];
  } catch {
    return [];
  }
}

async function fetchPublicTiers(eventIds: string[]): Promise<TierRow[]> {
  if (eventIds.length === 0) return [];
  try {
    const { data, error } = await supabase
      .from('exos_public_tiers')
      .select('event_id, name, price_schedule')
      .in('event_id', eventIds);
    if (error) return [];
    return (data ?? []) as TierRow[];
  } catch {
    return [];
  }
}

/**
 * Build the alerts feed for the signed-in viewer, newest first.
 * Best-effort: a failing source contributes nothing rather than throwing.
 */
export async function listNotifications(now: number = Date.now()): Promise<NotificationItem[]> {
  const [inbound, outbound, tickets, announcements, reschedules, saved] = await Promise.all([
    listInboundTransfers().catch(() => [] as Transfer[]),
    listOutboundTransfers().catch(() => [] as Transfer[]),
    listMyTickets().catch(() => [] as TicketWithEvent[]),
    fetchAnnouncements(),
    fetchReschedules(),
    listSavedEvents().catch(() => [] as Event[]),
  ]);
  const tiers = await fetchPublicTiers(saved.map((e) => e.id));
  const byEvent = ticketsByEvent(tickets);
  const items = [
    ...inbound.map(inboundToItem),
    ...outbound.map(outboundToItem),
    ...reminderItems(tickets, now),
    ...cancellationItems(tickets),
    ...announcementItems(announcements, byEvent, now),
    ...rescheduleItems(reschedules, byEvent, now),
    ...priceStepItems(saved, tiers, now),
  ];
  items.sort((a, b) => b.ts - a.ts);
  return items;
}
