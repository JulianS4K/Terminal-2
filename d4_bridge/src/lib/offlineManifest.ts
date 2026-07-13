// Exos (Bridge / D4) — signed offline revocation manifest.
//
// The hardest QR limit is TRUE offline single-use: two copies of a valid,
// unexpired code presented at two OFFLINE doors in the same bucket both pass a
// signature check, and there is no shared state to catch the second. Only the
// online atomic status flip (exos_check_in_ticket) actually closes that.
//
// This module shrinks the window as far as it can go offline: the server
// periodically emits an Ed25519-SIGNED set of ticket ids that are already
// `used` or `voided` as of an `issuedAt`. A door device that has synced the
// manifest can then reject an already-burned ticket with ZERO network, and —
// because the manifest is signed by the org key — it cannot be forged by a
// compromised scanner or a MITM on the sync channel. Between syncs there is
// still a gap; that gap is the honest residual, not a solved problem.
//
// Two membership representations are provided:
//   * exact Set — correct, ~36 bytes/id, fine for most events.
//   * Bloom filter — O(1) membership in a fixed bit budget for very large
//     events, with a bounded false-POSITIVE rate (a Bloom filter never yields
//     false negatives, so it can only ever REJECT a good ticket, never admit a
//     bad one — which is the safe direction for a revocation check, and the UI
//     falls back to an online re-check on a Bloom hit).

export interface RevocationManifest {
  eventId: string;
  /** ms epoch when the server built this manifest. */
  issuedAt: number;
  /** ticket ids that are used or voided as of issuedAt. */
  revoked: string[];
}

export interface SignedRevocationManifest {
  manifest: RevocationManifest;
  /** base64url Ed25519 signature over the canonical manifest bytes. */
  signature: string;
}

function b64urlToBytes(s: string): Uint8Array {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4);
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/**
 * Canonical bytes for signing/verification. Deterministic: revoked ids are
 * sorted so the same logical manifest always hashes identically regardless of
 * row ordering from the DB.
 */
export function canonicalManifestBytes(m: RevocationManifest): Uint8Array {
  const canonical = {
    eventId: m.eventId,
    issuedAt: m.issuedAt,
    revoked: [...m.revoked].sort(),
  };
  return new TextEncoder().encode(JSON.stringify(canonical));
}

/**
 * Verify a signed manifest against the org's Ed25519 public key. Returns the
 * parsed manifest only when the signature checks out — a caller must NOT trust
 * an unverified manifest (that would let a MITM mark good tickets revoked, a
 * denial-of-entry attack).
 */
export async function verifyRevocationManifest(
  signed: SignedRevocationManifest,
  publicKey: CryptoKey,
): Promise<{ ok: boolean; manifest?: RevocationManifest }> {
  try {
    const bytes = canonicalManifestBytes(signed.manifest);
    const ok = await crypto.subtle.verify(
      'Ed25519' as any,
      publicKey,
      b64urlToBytes(signed.signature),
      bytes,
    );
    return ok ? { ok: true, manifest: signed.manifest } : { ok: false };
  } catch {
    return { ok: false };
  }
}

/** Build an exact-membership lookup from a verified manifest. */
export function revokedSet(manifest: RevocationManifest): Set<string> {
  return new Set(manifest.revoked);
}

// ---------------------------------------------------------------------------
// Bloom filter — compact membership for very large events.
// ---------------------------------------------------------------------------

export interface BloomFilter {
  bits: Uint8Array;
  /** number of bits (bits.length * 8). */
  m: number;
  /** number of hash functions. */
  k: number;
}

// FNV-1a 32-bit, seeded — cheap, good enough distribution for a Bloom filter
// (we derive k indices via double hashing from two seeds).
function fnv1a(str: string, seed: number): number {
  let h = (2166136261 ^ seed) >>> 0;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}

/** Size a Bloom filter for `n` items at a target false-positive rate `p`. */
export function bloomParams(n: number, p = 0.001): { m: number; k: number } {
  const nn = Math.max(1, n);
  const m = Math.max(8, Math.ceil((-(nn * Math.log(p)) / (Math.LN2 * Math.LN2)) / 8) * 8);
  const k = Math.max(1, Math.round((m / nn) * Math.LN2));
  return { m, k };
}

export function buildBloomFilter(ids: string[], p = 0.001): BloomFilter {
  const { m, k } = bloomParams(ids.length, p);
  const bits = new Uint8Array(m / 8);
  const filter: BloomFilter = { bits, m, k };
  for (const id of ids) bloomAdd(filter, id);
  return filter;
}

function bloomIndices(filter: BloomFilter, id: string): number[] {
  const h1 = fnv1a(id, 0);
  const h2 = fnv1a(id, 0x9e3779b1) || 1;
  const out: number[] = [];
  for (let i = 0; i < filter.k; i++) {
    out.push(((h1 + Math.imul(i, h2)) >>> 0) % filter.m);
  }
  return out;
}

export function bloomAdd(filter: BloomFilter, id: string): void {
  for (const idx of bloomIndices(filter, id)) {
    filter.bits[idx >> 3] |= 1 << (idx & 7);
  }
}

/** True = POSSIBLY present (verify online); false = DEFINITELY absent. */
export function bloomMayContain(filter: BloomFilter, id: string): boolean {
  for (const idx of bloomIndices(filter, id)) {
    if ((filter.bits[idx >> 3] & (1 << (idx & 7))) === 0) return false;
  }
  return true;
}
