// Org logo upload helper. Used by OrgSettings.
//
// Validates type/size client-side, then uploads to the `exos-media` bucket via
// the storage seam and returns the public URL to store on org.theme.logoUrl.
// Path convention `org-logos/{orgId}/logo-{epoch}.{ext}` lives in lib/storage.
// RLS (org-member-gated upload) lives in migration 20260520150000.

import { uploadOrgLogo as uploadToBucket } from './storage';

const MAX_BYTES = 2 * 1024 * 1024;
const ACCEPTED_TYPES = /^image\/(png|jpe?g|webp|svg\+xml)$/;

export async function uploadOrgLogo(orgId: string, file: File): Promise<string> {
  if (!ACCEPTED_TYPES.test(file.type)) {
    throw new Error('Logo must be a PNG, JPG, WebP, or SVG.');
  }
  if (file.size > MAX_BYTES) {
    throw new Error(`Logo must be under ${MAX_BYTES / 1024 / 1024} MB.`);
  }
  const { url } = await uploadToBucket(orgId, file);
  return url;
}
