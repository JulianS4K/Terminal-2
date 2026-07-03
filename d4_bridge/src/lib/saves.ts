// Buyer saved-events (wishlist) seam (Supabase).
//
// Thin wrappers over exos_event_saves (mig 20260703120000). Reads are self-only
// via RLS (user_id = auth.uid()), so no explicit user filter is needed on the
// SELECT — the policy scopes it. Writes are plain RLS-gated INSERT/DELETE (there
// is no denormalized counter to protect, unlike the org follow-graph). Every
// read swallows errors to an empty result so the surface degrades cleanly if the
// table hasn't been applied to prod yet (A1 applies migrations).

import { supabase } from './supabase';
import { getCurrentAppUser } from './auth';
import { mapEvent } from './events';
import { Event } from '../types';

/** The set of event ids the signed-in user has saved. Empty when signed out. */
export async function listSavedEventIds(): Promise<Set<string>> {
  if (!getCurrentAppUser()?.uid) return new Set();
  const { data, error } = await supabase.from('exos_event_saves').select('event_id');
  if (error) {
    console.warn('listSavedEventIds failed (non-fatal):', error.message);
    return new Set();
  }
  return new Set((data ?? []).map((r: any) => r.event_id as string));
}

/** Save an event. Idempotent — a duplicate save is treated as success. */
export async function saveEvent(eventId: string): Promise<void> {
  const uid = getCurrentAppUser()?.uid;
  if (!uid) throw new Error('Sign in to save events.');
  const { error } = await supabase.from('exos_event_saves').insert({ user_id: uid, event_id: eventId });
  // 23505 = unique_violation (already saved). Idempotent: not an error to us.
  if (error && error.code !== '23505' && !/duplicate key/i.test(error.message)) throw error;
}

/** Un-save an event. A no-op when not saved / signed out. */
export async function unsaveEvent(eventId: string): Promise<void> {
  const uid = getCurrentAppUser()?.uid;
  if (!uid) return;
  const { error } = await supabase
    .from('exos_event_saves')
    .delete()
    .eq('user_id', uid)
    .eq('event_id', eventId);
  if (error) throw error;
}

/**
 * The user's saved events, hydrated from the public event view (so drafts the
 * user can no longer see are naturally dropped) and ordered soonest-first.
 * Best-effort — returns [] on any error.
 */
export async function listSavedEvents(): Promise<Event[]> {
  const ids = Array.from(await listSavedEventIds());
  if (ids.length === 0) return [];
  const { data, error } = await supabase
    .from('exos_public_events')
    .select('*')
    .in('id', ids)
    .order('starts_at', { ascending: true });
  if (error) {
    console.warn('listSavedEvents failed (non-fatal):', error.message);
    return [];
  }
  return (data ?? []).map((r: any) => mapEvent(r));
}
