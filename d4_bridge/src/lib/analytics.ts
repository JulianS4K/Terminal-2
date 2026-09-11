// Organizer event analytics (D4-OPS-24) — RPC wrapper.
//
// One round-trip to `exos_event_analytics` (migration 20260911130000) returns
// the whole rollup document — totals, no-show, sales-by-day in the event's
// timezone, tier / promoter / channel attribution WITH scan-in, plus the
// check-in and scan-reject rollups. Role gate (owner / manager / finance /
// admin) is enforced server-side; the report page gates the same way for UX.
// Pure types / mapper / CSV builders: ./analyticsModel.ts.

import { supabase } from './supabase';
import { mapAnalytics, type EventAnalytics } from './analyticsModel';

export * from './analyticsModel';

export async function getEventAnalytics(eventId: string): Promise<EventAnalytics> {
  const { data, error } = await supabase.rpc('exos_event_analytics', { p_event_id: eventId });
  if (error) throw error;
  return mapAnalytics(data);
}
