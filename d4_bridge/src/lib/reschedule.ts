// Event reschedule seam (Supabase).
//
// Wrappers over exos_event_reschedules + exos_reschedule_event (mig
// 20260703124000). One read function serves both audiences — org staff see
// their events' history, a ticket holder sees reschedules for events they hold a
// ticket for (RLS decides). rescheduleEvent moves the event's timing, logs the
// old→new, and emails holders the new date. Reads swallow errors to [] so the
// surface degrades cleanly before the migration is applied (A1 applies).

import { supabase } from './supabase';

export interface Reschedule {
  id: string;
  eventId: string;
  oldStartsAt: Date | null;
  newStartsAt: Date;
  reason: string | null;
  recipientCount: number;
  createdAt: Date;
}

function mapRow(r: any): Reschedule {
  return {
    id: r.id,
    eventId: r.event_id,
    oldStartsAt: r.old_starts_at ? new Date(r.old_starts_at) : null,
    newStartsAt: r.new_starts_at ? new Date(r.new_starts_at) : new Date(0),
    reason: r.reason ?? null,
    recipientCount: Number(r.recipient_count) || 0,
    createdAt: r.created_at ? new Date(r.created_at) : new Date(0),
  };
}

/** Reschedules for an event, newest first. Visibility is RLS-gated. */
export async function listEventReschedules(eventId: string): Promise<Reschedule[]> {
  const { data, error } = await supabase
    .from('exos_event_reschedules')
    .select('*')
    .eq('event_id', eventId)
    .order('created_at', { ascending: false });
  if (error) {
    console.warn('listEventReschedules failed (non-fatal):', error.message);
    return [];
  }
  return (data ?? []).map(mapRow);
}

/**
 * Org owner/manager (or admin): move an event to a new date/time. Persists the
 * old→new change and emails every non-voided holder the new date. Tickets stay
 * valid. Returns the new reschedule id + how many holders were emailed.
 */
export async function rescheduleEvent(input: {
  eventId: string;
  newStartsAt: string; // ISO
  newDoorsAt?: string | null;
  newEndsAt?: string | null;
  occursAtLocal?: string | null;
  reason?: string | null;
}): Promise<{ id: string; recipientCount: number }> {
  const { data, error } = await supabase.rpc('exos_reschedule_event', {
    p_event_id: input.eventId,
    p_new_starts_at: input.newStartsAt,
    p_new_doors_at: input.newDoorsAt ?? null,
    p_new_ends_at: input.newEndsAt ?? null,
    p_occurs_at_local: input.occursAtLocal ?? null,
    p_reason: input.reason ?? null,
  });
  if (error) throw error;
  const row = Array.isArray(data) ? data[0] : data;
  return {
    id: (row?.reschedule_id as string) ?? '',
    recipientCount: Number(row?.recipient_count) || 0,
  };
}
