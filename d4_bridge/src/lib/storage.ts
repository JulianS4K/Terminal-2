// Supabase Storage seam — replaces Firebase Storage for event images + org
// logos. One PUBLIC bucket `exos-media`; paths:
//   * event-images/{uid}/{uuid}.{ext}
//   * org-logos/{orgId}/logo-{epoch}.{ext}
// Public bucket → getPublicUrl yields a stable CDN URL (the analogue of
// Firebase getDownloadURL) that we store on the event/org row. Bucket + RLS
// live in migration 20260520150000_exos_storage.sql.

import { supabase } from './supabase';

export const MEDIA_BUCKET = 'exos-media';

export interface UploadResult {
  path: string; // storage object key (for later delete)
  url: string;  // public CDN URL (store this on the row)
}

function publicUrl(path: string): string {
  return supabase.storage.from(MEDIA_BUCKET).getPublicUrl(path).data.publicUrl;
}

function extOf(name: string, fallback = 'bin'): string {
  return name.includes('.') ? (name.split('.').pop() || fallback).toLowerCase() : fallback;
}

/** Upload an event image under the uploader's own folder. */
export async function uploadEventImage(uid: string, file: File): Promise<UploadResult> {
  const path = `event-images/${uid}/${crypto.randomUUID()}.${extOf(file.name)}`;
  const { error } = await supabase.storage
    .from(MEDIA_BUCKET)
    .upload(path, file, { contentType: file.type, upsert: false });
  if (error) throw error;
  return { path, url: publicUrl(path) };
}

/** Upload an org logo under the org's folder (timestamped key = trivial cache-bust). */
export async function uploadOrgLogo(orgId: string, file: File): Promise<UploadResult> {
  const path = `org-logos/${orgId}/logo-${Date.now()}.${extOf(file.name, 'png')}`;
  const { error } = await supabase.storage
    .from(MEDIA_BUCKET)
    .upload(path, file, { contentType: file.type, upsert: true });
  if (error) throw error;
  return { path, url: publicUrl(path) };
}

/** Best-effort delete by storage path. Never throws — orphan cleanup is non-fatal. */
export async function deleteStorageObject(path: string): Promise<void> {
  if (!path) return;
  const { error } = await supabase.storage.from(MEDIA_BUCKET).remove([path]);
  if (error) console.warn('deleteStorageObject failed (non-fatal):', error.message);
}
