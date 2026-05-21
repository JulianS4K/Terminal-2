// Org logo upload helper. Used by OrgSettings.
//
// Storage path: `org-logos/{orgId}/logo-{epoch}.{ext}` — the timestamp
// makes URL-cache invalidation trivial when the org rotates their
// logo, and orphan cleanup of old uploads is a backlog item (the
// equivalent of Sprint-1's CreateEvent image-cleanup pattern).
//
// The Storage rule (storage.rules > org-logos) gates writes on
// email_verified + image content-type + 2 MB cap. Firestore rules
// gate the corresponding write to org.theme.logoUrl on owner role.
// Both are required to fully change what the storefront displays.

import { ref as storageRef, uploadBytes, getDownloadURL } from 'firebase/storage';
import { storage } from './firebase';

const MAX_BYTES = 2 * 1024 * 1024;
const ACCEPTED_TYPES = /^image\/(png|jpe?g|webp|svg\+xml)$/;

export async function uploadOrgLogo(orgId: string, file: File): Promise<string> {
  if (!ACCEPTED_TYPES.test(file.type)) {
    throw new Error('Logo must be a PNG, JPG, WebP, or SVG.');
  }
  if (file.size > MAX_BYTES) {
    throw new Error(`Logo must be under ${MAX_BYTES / 1024 / 1024} MB.`);
  }
  const ext = file.name.split('.').pop()?.toLowerCase() || 'png';
  const path = `org-logos/${orgId}/logo-${Date.now()}.${ext}`;
  const ref = storageRef(storage, path);
  await uploadBytes(ref, file, { contentType: file.type });
  return getDownloadURL(ref);
}
