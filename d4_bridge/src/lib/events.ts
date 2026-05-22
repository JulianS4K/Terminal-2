// Exos event seam (Supabase). Events had no single module before — Firestore
// calls were scattered across the views. This is the new seam: public reads go
// through the column-narrowed public VIEWs (anon + buyers), staff reads hit the
// base tables (RLS-gated), and writes go to exos_events / exos_ticket_tiers.
//
// Returns the existing `Event` shape from src/types.ts (mapped from exos_*
// rows) so the event views stay drop-in when they're wired over in step 4.
// Postgres timestamptz strings are converted to Firestore `Timestamp`
// transitionally, same as lib/orgs.ts.

import { Timestamp } from './timestamp';
import { supabase } from './supabase';
import { getCurrentAppUser } from './auth';
import { utcToOccursAtLocal } from './datetime';
import { eventTypeForCategory } from './eventTaxonomy';
import { Event } from '../types';

const toTs = (iso?: string | null): Timestamp => Timestamp.fromDate(iso ? new Date(iso) : new Date(0));

type Tier = NonNullable<Event['ticketTiers']>[number];
type Discount = NonNullable<Event['discountCodes']>[number];

function mapTier(t: any): Tier {
  return {
    id: t.id,
    name: t.name,
    price: Number(t.price),
    description: t.description ?? '',
    capacity: t.capacity ?? 0,
    sold: t.sold ?? 0,
    ticketType: (t.ticket_type ?? 'paid') as Tier['ticketType'],
    visibility: (t.visibility ?? 'public') as Tier['visibility'],
    salesStart: t.sales_start ? toTs(t.sales_start) : null,
    salesEnd: t.sales_end ? toTs(t.sales_end) : null,
  };
}

function mapDiscount(d: any): Discount {
  return {
    code: d.code,
    type: d.type as Discount['type'],
    value: Number(d.value),
    usageLimit: d.usage_limit ?? null,
    expiresAt: d.expires_at ? toTs(d.expires_at) : null,
    unlocksTierIds: d.unlocks_tier_ids ?? undefined,
    usedCount: d.used_count ?? undefined,
  };
}

export function mapEvent(row: any, tiers?: any[], discounts?: any[]): Event {
  const mappedTiers = tiers ? tiers.map(mapTier) : undefined;
  const minPrice = mappedTiers && mappedTiers.length ? Math.min(...mappedTiers.map((t) => t.price)) : 0;
  return {
    id: row.id,
    title: row.name,
    description: row.description ?? '',
    date: toTs(row.starts_at ?? null),
    location: row.venue_name ?? row.venue_location ?? '',
    price: minPrice,
    orgId: row.org_id,
    organizerId: row.created_by ?? '',
    totalTickets: row.total_tickets ?? 0,
    ticketsSold: row.tickets_sold ?? 0,
    image: row.image_url ?? '',
    category: row.category ?? '',
    status: (row.status ?? 'published') as Event['status'],
    cancelledAt: row.cancelled_at ? toTs(row.cancelled_at) : undefined,
    cancelReason: row.cancel_reason ?? undefined,
    timezone: row.timezone ?? undefined,
    currency: row.currency ?? undefined,
    address: row.venue_address ?? undefined,
    genres: row.genres ?? undefined,
    subgenres: row.subgenres ?? undefined,
    performers: row.performer_names ?? undefined,
    timing: row.starts_at
      ? {
          doorsOpen: row.doors_at ? toTs(row.doors_at) : undefined,
          startTime: toTs(row.starts_at),
          endTime: row.ends_at ? toTs(row.ends_at) : undefined,
        }
      : undefined,
    automatiqListingId: row.automatiq_listing_id ?? undefined,
    syncStatus: (row.sync_status ?? undefined) as Event['syncStatus'],
    branding: row.branding ?? undefined,
    ticketTiers: mappedTiers,
    discountCodes: discounts ? discounts.map(mapDiscount) : undefined,
    exclusivity: row.exclusivity ?? undefined,
    distributionNetworks: row.distribution_networks ?? undefined,
    purchaseLimits: row.purchase_limits ?? undefined,
  };
}

// --- Public reads (anon + signed-in buyers) — column-narrowed views --------

export async function listPublicEvents(limit = 50): Promise<Event[]> {
  const { data, error } = await supabase
    .from('exos_public_events')
    .select('*')
    .order('starts_at', { ascending: true })
    .limit(limit);
  if (error) throw error;
  return (data ?? []).map((r: any) => mapEvent(r));
}

// Published events for a specific org (public org storefront).
export async function listPublicEventsForOrg(orgId: string): Promise<Event[]> {
  const { data, error } = await supabase
    .from('exos_public_events')
    .select('*')
    .eq('org_id', orgId)
    .order('starts_at', { ascending: true });
  if (error) throw error;
  return (data ?? []).map((r: any) => mapEvent(r));
}

export async function getPublicEvent(id: string): Promise<Event | null> {
  const { data, error } = await supabase.from('exos_public_events').select('*').eq('id', id).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  const { data: tiers } = await supabase
    .from('exos_public_tiers')
    .select('*')
    .eq('event_id', id)
    .order('sort_order', { ascending: true });
  return mapEvent(data, tiers ?? []);
}

export async function getPublicEventBySlug(slug: string): Promise<Event | null> {
  const { data, error } = await supabase.from('exos_public_events').select('*').eq('slug', slug).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  const { data: tiers } = await supabase
    .from('exos_public_tiers')
    .select('*')
    .eq('event_id', data.id)
    .order('sort_order', { ascending: true });
  return mapEvent(data, tiers ?? []);
}

// --- Staff reads (org dashboard / editor) — base tables, RLS-gated ---------

export async function listOrgEvents(orgId: string): Promise<Event[]> {
  const { data, error } = await supabase
    .from('exos_events')
    .select('*')
    .eq('org_id', orgId)
    .order('starts_at', { ascending: true });
  if (error) throw error;
  return (data ?? []).map((r: any) => mapEvent(r));
}

export async function getEventForEdit(eventId: string): Promise<Event | null> {
  const { data, error } = await supabase.from('exos_events').select('*').eq('id', eventId).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  const [{ data: tiers }, { data: discounts }] = await Promise.all([
    supabase.from('exos_ticket_tiers').select('*').eq('event_id', eventId).order('sort_order', { ascending: true }),
    supabase.from('exos_discount_codes').select('*').eq('event_id', eventId),
  ]);
  return mapEvent(data, tiers ?? [], discounts ?? []);
}

// --- Writes ----------------------------------------------------------------

export interface TierInput {
  name: string;
  price: number;
  description?: string;
  capacity?: number;
  ticketType?: 'paid' | 'free' | 'donation';
  visibility?: 'public' | 'hidden';
  salesStart?: string | null;
  salesEnd?: string | null;
  sortOrder?: number;
}

export interface DiscountInput {
  code: string;
  type: 'percentage' | 'fixed';
  value: number;
  usageLimit?: number | null;
  expiresAt?: string | null;
}

export interface EventInput {
  orgId: string;
  name: string;
  description?: string;
  status?: 'draft' | 'published' | 'cancelled';
  slug?: string | null;
  discountCodes?: DiscountInput[];
  startsAt?: string | null;
  doorsAt?: string | null;
  endsAt?: string | null;
  occursAtLocal?: string | null;
  timezone?: string;
  currency?: string;
  venueName?: string;
  venueLocation?: string;
  venueAddress?: Record<string, unknown>;
  primaryPerformerName?: string;
  performerNames?: string[];
  eventType?: string;
  category?: string;
  genres?: string[];
  subgenres?: string[];
  imageUrl?: string;
  totalTickets?: number;
  branding?: Record<string, unknown>;
  exclusivity?: Record<string, unknown>;
  purchaseLimits?: Record<string, unknown>;
  distributionNetworks?: string[];
  tiers?: TierInput[];
}

const EVENT_COL: Array<[keyof EventInput, string]> = [
  ['name', 'name'], ['description', 'description'], ['status', 'status'], ['slug', 'slug'],
  ['startsAt', 'starts_at'], ['doorsAt', 'doors_at'], ['endsAt', 'ends_at'], ['occursAtLocal', 'occurs_at_local'],
  ['timezone', 'timezone'], ['currency', 'currency'], ['venueName', 'venue_name'], ['venueLocation', 'venue_location'],
  ['venueAddress', 'venue_address'], ['primaryPerformerName', 'primary_performer_name'], ['performerNames', 'performer_names'],
  ['eventType', 'event_type'], ['category', 'category'], ['genres', 'genres'], ['subgenres', 'subgenres'],
  ['imageUrl', 'image_url'], ['totalTickets', 'total_tickets'], ['branding', 'branding'], ['exclusivity', 'exclusivity'],
  ['purchaseLimits', 'purchase_limits'], ['distributionNetworks', 'distribution_networks'],
];

function tierInsertRow(eventId: string, t: TierInput, idx: number) {
  return {
    event_id: eventId,
    name: t.name,
    description: t.description ?? null,
    price: t.price,
    capacity: t.capacity ?? 0,
    ticket_type: t.ticketType ?? 'paid',
    visibility: t.visibility ?? 'public',
    sales_start: t.salesStart ?? null,
    sales_end: t.salesEnd ?? null,
    sort_order: t.sortOrder ?? idx,
  };
}

// D0 catalog consistency. TEvo's public.events stores the event's local
// wall-clock in `occurs_at_local` (text, "YYYY-MM-DDTHH:MM:SS") and a coarse
// `event_type`. An Exos row that only has `starts_at` (timestamptz) + `category`
// is shape-compatible but NOT value-consistent with the catalog. Derive both
// from what the form already provides — unless the caller set them explicitly —
// so a unified read across catalog + exos events sees the same keys.
function applyCatalogConsistency(row: Record<string, unknown>, src: Partial<EventInput>): void {
  if (row.occurs_at_local === undefined && src.startsAt && src.timezone) {
    // TEvo format: "YYYY-MM-DDTHH:MM:SS±HH:MM" (local wall-clock + venue offset).
    const local = utcToOccursAtLocal(new Date(src.startsAt), src.timezone);
    if (local) row.occurs_at_local = local;
  }
  if (row.event_type === undefined && src.category) {
    const et = eventTypeForCategory(src.category);
    if (et !== undefined) row.event_type = et;
  }
}

export async function createEvent(input: EventInput): Promise<{ eventId: string }> {
  const row: Record<string, unknown> = { org_id: input.orgId, created_by: getCurrentAppUser()?.uid ?? null };
  for (const [k, col] of EVENT_COL) if (input[k] !== undefined) row[col] = input[k];
  if (row.currency === undefined) row.currency = 'USD';
  applyCatalogConsistency(row, input);
  const { data, error } = await supabase.from('exos_events').insert(row).select('id').single();
  if (error) throw error;
  const eventId = data.id as string;
  if (input.tiers?.length) {
    const { error: tErr } = await supabase
      .from('exos_ticket_tiers')
      .insert(input.tiers.map((t, i) => tierInsertRow(eventId, t, i)));
    if (tErr) throw tErr;
  }
  if (input.discountCodes?.length) {
    // unlocks_tier_ids deferred to phase-2: the form references tiers by
    // client id, but tiers get DB-generated uuids on insert — remapping is a
    // phase-2 concern (hidden-tier unlock matters only at checkout, gated).
    const rows = input.discountCodes.map((d) => ({
      event_id: eventId,
      code: d.code,
      type: d.type,
      value: d.value,
      usage_limit: d.usageLimit ?? null,
      expires_at: d.expiresAt ?? null,
    }));
    const { error: dErr } = await supabase.from('exos_discount_codes').insert(rows);
    if (dErr) throw dErr;
  }
  return { eventId };
}

export async function updateEvent(eventId: string, patch: Partial<EventInput>): Promise<void> {
  const row: Record<string, unknown> = {};
  for (const [k, col] of EVENT_COL) if (patch[k] !== undefined) row[col] = patch[k];
  // Keep occurs_at_local / event_type in sync when the date or category change.
  // EditEvent sends startsAt + timezone + category on every save, so editing
  // the date re-derives the local string rather than leaving it stale.
  applyCatalogConsistency(row, patch);
  if (Object.keys(row).length === 0) return;
  const { error } = await supabase.from('exos_events').update(row).eq('id', eventId);
  if (error) throw error;
}

export async function cancelEvent(eventId: string, reason?: string): Promise<void> {
  const { error } = await supabase
    .from('exos_events')
    .update({ status: 'cancelled', cancelled_at: new Date().toISOString(), cancel_reason: reason ?? null })
    .eq('id', eventId);
  if (error) throw error;
}

// --- Tier CRUD (editor) ----------------------------------------------------

export async function addTier(eventId: string, t: TierInput): Promise<{ tierId: string }> {
  const { data, error } = await supabase
    .from('exos_ticket_tiers')
    .insert(tierInsertRow(eventId, t, t.sortOrder ?? 0))
    .select('id')
    .single();
  if (error) throw error;
  return { tierId: data.id as string };
}

export async function updateTier(tierId: string, patch: Partial<TierInput>): Promise<void> {
  const row: Record<string, unknown> = {};
  if (patch.name !== undefined) row.name = patch.name;
  if (patch.description !== undefined) row.description = patch.description;
  if (patch.price !== undefined) row.price = patch.price;
  if (patch.capacity !== undefined) row.capacity = patch.capacity;
  if (patch.ticketType !== undefined) row.ticket_type = patch.ticketType;
  if (patch.visibility !== undefined) row.visibility = patch.visibility;
  if (patch.salesStart !== undefined) row.sales_start = patch.salesStart;
  if (patch.salesEnd !== undefined) row.sales_end = patch.salesEnd;
  if (patch.sortOrder !== undefined) row.sort_order = patch.sortOrder;
  if (Object.keys(row).length === 0) return;
  const { error } = await supabase.from('exos_ticket_tiers').update(row).eq('id', tierId);
  if (error) throw error;
}

export async function deleteTier(tierId: string): Promise<void> {
  const { error } = await supabase.from('exos_ticket_tiers').delete().eq('id', tierId);
  if (error) throw error;
}
