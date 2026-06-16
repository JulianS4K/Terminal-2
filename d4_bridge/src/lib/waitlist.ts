// Sold-out event/tier waitlist (Hi.Events parity).
//
// Thin wrappers over the SECDEF RPCs in migration 20260616180000. The buyer
// JOIN path is anon-callable (a sold-out public event captures demand without a
// login); the notify/summary paths are org-staff-gated server-side.

import { supabase } from './supabase';

export interface WaitlistJoinResult {
  id: string;
  /** 1-based queue position among still-waiting joiners for this event/tier. */
  position: number;
}

export interface WaitlistSummary {
  waiting: number;
  notified: number;
  converted: number;
  totalQuantity: number;
}

/** Join a sold-out event (optionally a specific tier). Works signed-out. */
export async function joinWaitlist(input: {
  eventId: string;
  email: string;
  tierId?: string | null;
  name?: string | null;
  quantity?: number;
  meta?: Record<string, unknown> | null;
}): Promise<WaitlistJoinResult> {
  const { data, error } = await supabase.rpc('exos_join_waitlist', {
    p_event_id: input.eventId,
    p_email: input.email,
    p_tier_id: input.tierId ?? null,
    p_name: input.name ?? null,
    p_quantity: input.quantity ?? 1,
    p_meta: input.meta ?? null,
  });
  if (error) throw error;
  // SETOF (id, position) → one row.
  const row = Array.isArray(data) ? data[0] : data;
  if (!row?.id) throw new Error('joinWaitlist: no row returned');
  return { id: row.id as string, position: Number(row.position) || 1 };
}

/** Cancel a waitlist entry. Pass the email for signed-out (anon-created) rows. */
export async function leaveWaitlist(id: string, email?: string | null): Promise<boolean> {
  const { data, error } = await supabase.rpc('exos_leave_waitlist', {
    p_id: id,
    p_email: email ?? null,
  });
  if (error) throw error;
  return data === true;
}

/** Org staff: release N spots — flips the oldest waiting rows to 'notified' and
 *  queues a "spot opened" email to each. Returns the number notified. */
export async function notifyWaitlist(input: {
  eventId: string;
  limit?: number;
  tierId?: string | null;
}): Promise<number> {
  const { data, error } = await supabase.rpc('exos_notify_waitlist', {
    p_event_id: input.eventId,
    p_limit: input.limit ?? 10,
    p_tier_id: input.tierId ?? null,
  });
  if (error) throw error;
  return Number(data) || 0;
}

/** Org staff: waiting/notified/converted counts for the event dashboard. */
export async function waitlistSummary(eventId: string): Promise<WaitlistSummary> {
  const { data, error } = await supabase.rpc('exos_waitlist_summary', { p_event_id: eventId });
  if (error) throw error;
  const row = Array.isArray(data) ? data[0] : data;
  return {
    waiting: Number(row?.waiting) || 0,
    notified: Number(row?.notified) || 0,
    converted: Number(row?.converted) || 0,
    totalQuantity: Number(row?.total_quantity) || 0,
  };
}
