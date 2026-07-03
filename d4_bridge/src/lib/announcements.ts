// Organizer → attendee announcements seam (Supabase).
//
// Thin wrappers over exos_event_announcements + exos_send_event_announcement
// (mig 20260703121000). One read function serves BOTH audiences — the RLS
// policies decide visibility: org staff see their events' history, and a ticket
// holder sees announcements for events they hold a (non-voided) ticket for. The
// read swallows errors to an empty list so both surfaces degrade cleanly before
// the migration is applied to prod (A1 applies).

import { supabase } from './supabase';

export interface Announcement {
  id: string;
  eventId: string;
  subject: string;
  body: string;
  /** How many holder emails were queued when this was sent. */
  recipientCount: number;
  createdAt: Date;
}

function mapRow(r: any): Announcement {
  return {
    id: r.id,
    eventId: r.event_id,
    subject: r.subject ?? '',
    body: r.body ?? '',
    recipientCount: Number(r.recipient_count) || 0,
    createdAt: r.created_at ? new Date(r.created_at) : new Date(0),
  };
}

/** Announcements for an event, newest first. Visibility is RLS-gated. */
export async function listEventAnnouncements(eventId: string): Promise<Announcement[]> {
  const { data, error } = await supabase
    .from('exos_event_announcements')
    .select('*')
    .eq('event_id', eventId)
    .order('created_at', { ascending: false });
  if (error) {
    console.warn('listEventAnnouncements failed (non-fatal):', error.message);
    return [];
  }
  return (data ?? []).map(mapRow);
}

/**
 * Org owner/manager (or admin): broadcast a free-text update to non-voided
 * ticket holders. Persists the announcement AND queues one email per holder.
 * Returns the new announcement id + the number of recipients emailed.
 */
export async function sendAnnouncement(input: {
  eventId: string;
  subject: string;
  body: string;
}): Promise<{ id: string; recipientCount: number }> {
  const { data, error } = await supabase.rpc('exos_send_event_announcement', {
    p_event_id: input.eventId,
    p_subject: input.subject,
    p_body: input.body,
  });
  if (error) throw error;
  // RETURNS TABLE(announcement_id, recipient_count) → one row.
  const row = Array.isArray(data) ? data[0] : data;
  return {
    id: (row?.announcement_id as string) ?? '',
    recipientCount: Number(row?.recipient_count) || 0,
  };
}

/**
 * Org owner/manager (or admin): retract an announcement — removes it from the
 * in-app thread on holders' tickets. Already-sent emails are not recalled.
 * Gated by the staff DELETE RLS policy (mig 20260703123000).
 */
export async function deleteAnnouncement(id: string): Promise<void> {
  const { error } = await supabase.from('exos_event_announcements').delete().eq('id', id);
  if (error) throw error;
}
