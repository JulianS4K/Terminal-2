// Product add-ons (merch) — buyer browse + organizer CRUD + free-extras claim.
//
// Catalog lives in exos_event_addons. Buyers read the column-narrowed
// exos_public_addons view (published + public only); org staff read/write the
// base table (RLS-gated). Paid add-ons ride the Stripe checkout (see
// lib/checkout.ts); $0 extras attach to a free claim via exos_claim_free_addons.

import { supabase } from './supabase';

export interface PublicAddon {
  id: string;
  eventId: string;
  name: string;
  description: string | null;
  price: number;
  capacity: number;       // 0 = unlimited
  sold: number;
  maxPerOrder: number | null;
  imageUrl: string | null;
  sortOrder: number;
}

export interface AddonInput {
  id?: string;            // present = update; absent = insert
  name: string;
  description?: string | null;
  price: number;
  capacity?: number;
  maxPerOrder?: number | null;
  visibility?: 'public' | 'hidden';
  imageUrl?: string | null;
  sortOrder?: number;
}

function mapPublic(r: any): PublicAddon {
  return {
    id: r.id,
    eventId: r.event_id,
    name: r.name,
    description: r.description ?? null,
    price: Number(r.price) || 0,
    capacity: Number(r.capacity) || 0,
    sold: Number(r.sold) || 0,
    maxPerOrder: r.max_per_order ?? null,
    imageUrl: r.image_url ?? null,
    sortOrder: Number(r.sort_order) || 0,
  };
}

/** Buyer-facing: public add-ons for a published event. */
export async function listPublicAddons(eventId: string): Promise<PublicAddon[]> {
  const { data, error } = await supabase
    .from('exos_public_addons')
    .select('*')
    .eq('event_id', eventId)
    .order('sort_order', { ascending: true });
  if (error) throw error;
  return (data ?? []).map(mapPublic);
}

/** Organizer: full catalog (incl. hidden) for an event. Staff RLS. */
export async function listEventAddons(eventId: string): Promise<(PublicAddon & { visibility: 'public' | 'hidden' })[]> {
  const { data, error } = await supabase
    .from('exos_event_addons')
    .select('*')
    .eq('event_id', eventId)
    .order('sort_order', { ascending: true });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({ ...mapPublic(r), visibility: r.visibility }));
}

/** Organizer: create or update an add-on. Staff RLS gates the write. */
export async function saveAddon(eventId: string, input: AddonInput): Promise<string> {
  const row = {
    event_id: eventId,
    name: input.name.trim(),
    description: input.description?.trim() || null,
    price: Math.max(0, Number(input.price) || 0),
    capacity: Math.max(0, Number(input.capacity) || 0),
    max_per_order: input.maxPerOrder ?? null,
    visibility: input.visibility ?? 'public',
    image_url: input.imageUrl?.trim() || null,
    sort_order: Number(input.sortOrder) || 0,
  };
  if (input.id) {
    const { error } = await supabase.from('exos_event_addons').update(row).eq('id', input.id);
    if (error) throw error;
    return input.id;
  }
  const { data, error } = await supabase.from('exos_event_addons').insert(row).select('id').single();
  if (error) throw error;
  return data.id as string;
}

/** Organizer: delete an add-on (purchase history is preserved — FK SET NULL). */
export async function deleteAddon(addonId: string): Promise<void> {
  const { error } = await supabase.from('exos_event_addons').delete().eq('id', addonId);
  if (error) throw error;
}

/** Attach $0 extras to a free claim (paid add-ons must go through checkout). */
export async function claimFreeAddons(
  eventId: string,
  orderRef: string | null,
  addons: { addon_id: string; quantity: number }[],
): Promise<number> {
  if (!addons.length) return 0;
  const { data, error } = await supabase.rpc('exos_claim_free_addons', {
    p_event_id: eventId,
    p_order_ref: orderRef,
    p_addons: addons,
  });
  if (error) throw error;
  return Number(data) || 0;
}
