// Recurring / timed-entry series (D4-OPS-27) — RPC wrappers.
//
// `exos_create_event_series` (mig 20260911133000) clones a template event
// (+ tiers, + discount codes) once per occurrence and links them via
// exos_events.series_id. Owner / manager / admin, enforced server-side. The
// pure occurrence generator lives in ./seriesModel.ts.

import { supabase } from './supabase';
import { mapEvent } from './events';
import type { Event } from '../types';
import type { SeriesKind, SeriesRule } from './seriesModel';

export * from './seriesModel';

export interface CreatedOccurrence {
  eventId: string;
  startsAt: Date;
  seriesIndex: number;
}

export async function createEventSeries(input: {
  templateEventId: string;
  startsAt: Date[];
  kind: SeriesKind;
  name?: string | null;
  rule?: SeriesRule | null;
  /** true = publish clones, false = drafts, undefined = copy the template's status. */
  publish?: boolean;
}): Promise<CreatedOccurrence[]> {
  const { data, error } = await supabase.rpc('exos_create_event_series', {
    p_template_event_id: input.templateEventId,
    p_starts_at: input.startsAt.map((d) => d.toISOString()),
    p_kind: input.kind,
    p_name: input.name ?? null,
    p_rule: input.rule ?? null,
    p_publish: input.publish ?? null,
  });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    eventId: String(r.event_id),
    startsAt: new Date(r.starts_at),
    seriesIndex: Number(r.series_index) || 0,
  }));
}

export interface EventSeries {
  id: string;
  orgId: string;
  name: string;
  kind: SeriesKind;
  templateEventId: string | null;
  timezone: string | null;
  rule: SeriesRule | null;
  createdAt: Date;
}

export async function getEventSeries(seriesId: string): Promise<EventSeries | null> {
  const { data, error } = await supabase.from('exos_event_series').select('*').eq('id', seriesId).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  return {
    id: data.id,
    orgId: data.org_id,
    name: data.name,
    kind: data.kind as SeriesKind,
    templateEventId: data.template_event_id ?? null,
    timezone: data.timezone ?? null,
    rule: (data.rule ?? null) as SeriesRule | null,
    createdAt: new Date(data.created_at),
  };
}

/** Members of a series, in index order (staff RLS on exos_events). */
export async function listSeriesEvents(seriesId: string): Promise<Event[]> {
  const { data, error } = await supabase
    .from('exos_events')
    .select('*')
    .eq('series_id', seriesId)
    .order('series_index', { ascending: true });
  if (error) throw error;
  return (data ?? []).map((r: any) => mapEvent(r));
}
