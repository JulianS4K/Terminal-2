// Exos (Bridge / D4) — barcode rollout flags.
//
// v2 (binary, multi-scheme) barcodes are ISSUANCE-gated so nothing breaks
// before the DB half (migration 20260713120000: v2/Ed25519-aware
// exos_check_in_ticket) is applied + validated on a preview branch. While the
// flag is OFF, passes render the v1 `T-…` HMAC code exactly as before, and the
// scanner still ACCEPTS v2 via verifyAnyBarcode (a superset) — so verification
// is forward-compatible even while issuance stays on v1.
//
// Enable by setting VITE_BARCODE_V2=1 (or 'hmac' / 'ed25519') in the build env.
// The `ed25519` scheme additionally requires pgsodium enabled server-side; see
// the migration header. When unset or unrecognized, issuance stays on v1.

import type { BarcodeScheme } from './barcode';

export type BarcodeIssuance = 'v1' | BarcodeScheme;

function readFlag(): BarcodeIssuance {
  const raw = String((import.meta as any).env?.VITE_BARCODE_V2 ?? '').toLowerCase().trim();
  if (raw === 'ed25519') return 'ed25519';
  if (raw === 'hmac' || raw === '1' || raw === 'true' || raw === 'on') return 'hmac';
  return 'v1';
}

/** Which barcode format/scheme this build should ISSUE onto passes. */
export const barcodeIssuance: BarcodeIssuance = readFlag();

/** True when passes should render a v2 (`T2-`) code. */
export const issueV2 = barcodeIssuance !== 'v1';
