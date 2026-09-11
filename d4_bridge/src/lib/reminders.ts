// Pre-event reminders (seller side).
//
// Automatic reminders are queued server-side by the `exos_send_event_reminders`
// cron (T-24h and T-2h before `starts_at`, once each per event — migration
// 20260911051000). This module only exposes the manual "send now" path used by
// the organizer event report; the RPC re-checks owner/manager + a 6h cooldown
// server-side, so the button is a convenience, not the gate.

import { supabase } from './supabase';

/**
 * Queue an `event-reminder` mail to every current (non-voided) ticket holder
 * right now. Returns the number of recipients queued. Throws with the server's
 * message on cooldown / unpublished / not-authorized.
 */
export async function sendEventReminderNow(eventId: string): Promise<number> {
  const { data, error } = await supabase.rpc('exos_send_event_reminder_now', {
    p_event_id: eventId,
  });
  if (error) throw error;
  return Number(data) || 0;
}
