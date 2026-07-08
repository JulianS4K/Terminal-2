// Notifications — a lightweight aggregation layer for the alerts feed
// (/alerts, views/Notifications.tsx).
//
// Exos has no dedicated notifications table yet, so this derives the feed
// from signals that DO exist today: inbound + outbound ticket transfers.
// Each transfer maps to one notification item with a punk-design category,
// icon key, tone colour, and a deep link. As real event-side signals
// (reminders, price steps, ticket drops from followed orgs) get a backend,
// add resolvers here and merge into listNotifications().
//
// "Unread" has no server-side read-state yet, so we treat still-actionable
// items (a pending inbound transfer you haven't claimed) as unread. Mark-all
// -read is therefore a client-only affordance in the view.

import { listInboundTransfers, listOutboundTransfers } from './tickets';
import { Transfer } from '../types';

export type NotificationCategory = 'tickets' | 'events';
export type NotificationIcon = 'transfer' | 'ticket' | 'reminder' | 'drop' | 'price';

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

/**
 * Build the alerts feed for the signed-in viewer, newest first.
 * Best-effort: a failing source contributes nothing rather than throwing.
 */
export async function listNotifications(): Promise<NotificationItem[]> {
  const [inbound, outbound] = await Promise.all([
    listInboundTransfers().catch(() => [] as Transfer[]),
    listOutboundTransfers().catch(() => [] as Transfer[]),
  ]);
  const items = [...inbound.map(inboundToItem), ...outbound.map(outboundToItem)];
  items.sort((a, b) => b.ts - a.ts);
  return items;
}
