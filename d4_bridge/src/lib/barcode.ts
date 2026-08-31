// HMAC-signed rotating ticket barcodes.
//
// Why: the previous barcode was `T-{ticketId}:{ownerId}:{timestamp}:{secret}`.
// The 30-second rotation rendered in the buyer's UI was theatrical —
// the OrganizerCheckIn scanner only used the leading `ticketId` and
// ignored the rest. Anyone who saw a screenshot from any time in the
// past could walk in with the same docId.
//
// What we do now:
//
//   1. Each ticket carries a per-ticket secret (`barcodeSecret`). Read
//      access is scoped by Postgres RLS, NOT the app: the ticket's own
//      owner/buyer (to render their pass) and owner/manager/scanner org
//      staff (to verify at the door) may read it — finance/content may
//      NOT. It is served through the gated `exos_ticket_barcode_secrets`
//      view rather than the base table, so a broad ticket read can't leak
//      it (migration 20260702123000).
//
//   2. The barcode is `T-{ticketId}:{ownerId}:{bucket}:{hmac}` where
//      `bucket = floor(now / 30_000)` and `hmac = HMAC-SHA256(secret,
//      "ticketId:ownerId:bucket")`, base64url-encoded.
//
//   3. OrganizerCheckIn parses the barcode, reads the ticket, recomputes
//      the HMAC against the stored secret, and refuses if either the
//      bucket is out of window (more than one bucket old) or the HMAC
//      mismatches. The check-in RPC re-runs the SAME HMAC/owner/bucket
//      check server-side (migration 20260702120000), so the browser check
//      is a fast-fail UX layer, not the security boundary.
//
//   4. Legacy 3-segment barcodes (no HMAC) and bare ticket UUIDs are
//      REJECTED on the camera path (ok:false, legacy:true). A payload with
//      no signature is forgeable from a screenshot of the public ticket id
//      — a check-in downgrade. Holders of a legacy ticket must refresh it
//      in the app to get a signed barcode. The server RPC rejects them too
//      (migration 20260702120000), so client and server agree.
//
// What this still doesn't give us:
//   * Full defense against a malicious organizer. The camera scan is now
//     server-verified, but a door operator can still force a MANUAL
//     override. That path is an explicit, audited check-in (source +
//     verification are recorded in exos_event_checkins), not a silent
//     bypass — but it does trust the operator.
//   * Replay across stations. Two organizers scanning the same barcode in
//     the same 30-second bucket both pass HMAC; the atomic status flip in
//     the check-in RPC (UPDATE ... WHERE status='active') then lets only
//     the first win — the second loses the race and is refused, with both
//     attempts visible in the audit log.

const BUCKET_MS = 30_000;
// Accept barcodes from the current bucket or up to N buckets in either
// direction. The window has to cover:
//   * Modest clock skew between the buyer's phone and the organizer's
//     scanner (typical: <5s after NTP, but manually-set clocks happen).
//   * Bucket-rollover at scan time — the buyer's barcode rendered at
//     second 29 might be scanned at second 31 of the next bucket.
//   * Slow scanner pipeline — the camera frame, decode, then network
//     read of the ticket doc can take several seconds at busy doors.
//
// Tolerance of 2 gives ~60–90s of accepted skew either side, which is
// comfortably above realistic NTP drift but well under "screenshot
// from earlier today" replay. The check-in RPC's atomic status flip
// (UPDATE ... WHERE status='active') is the second line of defence
// against true replay.
const BUCKET_TOLERANCE = 2;

/** Current 30-second time bucket. */
export function currentBucket(now: number = Date.now()): number {
  return Math.floor(now / BUCKET_MS);
}

function bytesToBase64Url(bytes: ArrayBuffer): string {
  const arr = new Uint8Array(bytes);
  let bin = '';
  for (let i = 0; i < arr.length; i++) bin += String.fromCharCode(arr[i]);
  return btoa(bin)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

/**
 * Verify SubtleCrypto is reachable. The Web Crypto API is only
 * exposed on secure contexts (HTTPS or localhost). In production we
 * MUST be on HTTPS or every barcode operation throws — see README.
 */
function ensureCryptoSubtleAvailable(): void {
  if (typeof crypto === 'undefined' || !crypto.subtle) {
    throw new Error(
      'Web Crypto API unavailable. Barcode signing requires a secure ' +
        'context (HTTPS or localhost). If you are running over plain HTTP ' +
        'in production, the build will fail at scan time.',
    );
  }
}

async function hmacSha256(secret: string, message: string): Promise<string> {
  ensureCryptoSubtleAvailable();
  const enc = new TextEncoder();
  // An empty secret would still produce a valid HMAC — the verifier
  // would happily compare it against itself — but the only place that
  // happens today is a misconfigured ticket without a barcodeSecret
  // (we now mint one at fulfillment). Refuse early to surface the bug.
  if (!secret) {
    throw new Error(
      'Refusing to sign barcode with empty secret. The ticket doc ' +
        'should carry a barcodeSecret minted at fulfillment time.',
    );
  }
  const key = await crypto.subtle.importKey(
    'raw',
    enc.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(message));
  return bytesToBase64Url(sig);
}

/**
 * Constant-time string compare. Standard `===` short-circuits on the
 * first mismatched byte, which leaks timing information that — over
 * many requests against a stable secret — could be used to recover the
 * expected HMAC byte by byte. The 30-second rotation makes this hard
 * to exploit in practice, but using a constant-time compare is the
 * correct primitive and costs nothing.
 */
function timingSafeEqual(a: string, b: string): boolean {
  // Length difference itself is a timing leak — but if our inputs are
  // both base64url-encoded HMAC-SHA256 outputs they'll always be the
  // same length. We early-exit only on length mismatch (safe) and
  // otherwise XOR every byte.
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/**
 * Compute the signed barcode payload that goes into the QR code shown
 * to the buyer. Pure async — caller is responsible for refreshing every
 * 30 seconds (the bucket boundary).
 */
export async function signBarcode(
  ticketId: string,
  ownerId: string,
  secret: string,
  bucket: number = currentBucket(),
): Promise<string> {
  const message = `${ticketId}:${ownerId}:${bucket}`;
  const sig = await hmacSha256(secret, message);
  return `T-${ticketId}:${ownerId}:${bucket}:${sig}`;
}

export interface VerifyResult {
  ok: boolean;
  reason?:
    | 'malformed'
    | 'bad-bucket'
    | 'bucket-expired'
    | 'signature-mismatch'
    | 'legacy-no-secret';
  legacy: boolean;
  ticketId?: string;
  ownerId?: string;
  bucket?: number;
}

/**
 * Verify a scanned barcode against an expected per-ticket secret.
 *
 * On the legacy 3-segment shape, returns `legacy: true` and lets the
 * caller decide whether to accept. We do NOT compute or compare the
 * "secret" segment for legacy barcodes because there's no integrity
 * guarantee on it — a fresh implementation would have used HMAC.
 */
export async function verifyBarcode(
  payload: string,
  secret: string,
  options: { now?: number } = {},
): Promise<VerifyResult> {
  if (typeof payload !== 'string' || !payload.startsWith('T-')) {
    return { ok: false, reason: 'malformed', legacy: false };
  }
  const parts = payload.slice(2).split(':');
  // 3 segments = legacy ("T-{ticketId}:{ownerId}:{timestamp}"), which carries NO
  // HMAC and is trivially forgeable from a screenshot (the ticket id is public).
  // It is NO LONGER accepted — ok:false. The `legacy` flag is kept only so the
  // UI can show a "refresh your ticket" message. 4 segments = signed. The server
  // RPC (exos_check_in_ticket) rejects legacy payloads too, so this mirrors it.
  if (parts.length === 3) {
    const [ticketId, ownerId, bucketStr] = parts;
    const bucket = parseInt(bucketStr, 10);
    return {
      ok: false,
      reason: 'legacy-no-secret',
      legacy: true,
      ticketId,
      ownerId,
      bucket: Number.isFinite(bucket) ? bucket : undefined,
    };
  }
  if (parts.length !== 4) {
    return { ok: false, reason: 'malformed', legacy: false };
  }
  const [ticketId, ownerId, bucketStr, hmac] = parts;
  const bucket = parseInt(bucketStr, 10);
  if (!Number.isFinite(bucket)) {
    return { ok: false, reason: 'bad-bucket', legacy: false };
  }
  const now = options.now ?? Date.now();
  const cur = currentBucket(now);
  if (Math.abs(cur - bucket) > BUCKET_TOLERANCE) {
    return { ok: false, reason: 'bucket-expired', legacy: false, ticketId, ownerId, bucket };
  }
  const expected = await hmacSha256(secret, `${ticketId}:${ownerId}:${bucket}`);
  if (!timingSafeEqual(expected, hmac)) {
    return {
      ok: false,
      reason: 'signature-mismatch',
      legacy: false,
      ticketId,
      ownerId,
      bucket,
    };
  }
  return { ok: true, legacy: false, ticketId, ownerId, bucket };
}

/**
 * Parse an old-format barcode for the docId. Used when verifyBarcode
 * fails — the OrganizerCheckIn UI wants to surface the docId in the
 * error message and audit log even when the signature didn't validate.
 *
 * Handles v1 (`T-{ticketId}:...`) AND v2 (`T2-{scheme}{b64url}`) shapes so
 * the audit log always records the attempted ticket id, whatever the format.
 */
export function extractTicketIdFromAny(payload: string): string | null {
  if (!payload || typeof payload !== 'string') return null;
  if (payload.startsWith(V2_PREFIX)) {
    // v2 packs the ticket id as the first 16 bytes; decode just those.
    try {
      const bytes = b64urlToBytes(payload.slice(V2_PREFIX.length + 1));
      return bytes.length >= 16 ? bytesToUuid(bytes, 0) : null;
    } catch {
      return null;
    }
  }
  const trimmed = payload.startsWith('T-') ? payload.slice(2) : payload;
  const id = trimmed.split(':')[0];
  return id || null;
}

// ===========================================================================
// v2 barcodes — binary-packed, multi-scheme, offline-verifiable
// ===========================================================================
//
// Why a v2 at all (the limits we're pushing, honestly):
//
//   * Payload size / scan speed. v1 is text: `T-{uuid}:{uuid}:{bucket}:{b64sig}`
//     — two 36-char hex UUIDs carrying only 32 bytes of real entropy, ~120+
//     chars total. A denser symbol focuses/decodes slower under bad stadium
//     lighting. v2 packs the UUIDs to raw 16-byte values + a varint bucket +
//     a truncated/compact signature, roughly HALVING the module count for the
//     HMAC scheme while staying a plain QR any phone camera reads.
//
//   * Offline verification WITHOUT a shared secret (the Ed25519 scheme). v1 is
//     symmetric HMAC, so an offline door device must hold each ticket's
//     `barcode_secret` (the exos_ticket_barcode_secrets registry). A stolen
//     scanner can then FORGE codes. v2's `ed25519` scheme signs with the org's
//     PRIVATE key (held only server-side / in the owner's device) and the
//     scanner verifies with the org PUBLIC key — a leaked scanner can verify
//     but never forge. This is the airline/SafeTix-grade offline model.
//
// Both schemes are offered ("all options"): `hmac` for the smallest symbol and
// drop-in secret compatibility, `ed25519` for no-secret-on-the-scanner offline
// verification. The wire format self-identifies which one it is.
//
// Format:  `T2-{schemeTag}{base64url(binary)}`   schemeTag ∈ { 'h', 'e' }
// Binary:  [16 bytes ticketId][16 bytes ownerId][varint bucket][signature]
//            signature = 16 bytes (hmac, truncated HMAC-SHA256)
//                      | 64 bytes (ed25519)
// The message that is signed is the bytes BEFORE the signature (ticketId ||
// ownerId || bucketVarint), so the layout is self-delimiting: a verifier reads
// the two UUIDs and the varint, and everything left over is the signature.

export type BarcodeScheme = 'hmac' | 'ed25519';

const V2_PREFIX = 'T2-';
const SCHEME_TAG: Record<BarcodeScheme, string> = { hmac: 'h', ed25519: 'e' };
const TAG_SCHEME: Record<string, BarcodeScheme> = { h: 'hmac', e: 'ed25519' };
// Truncate the HMAC to 128 bits. Full SHA-256 (256 bits) is overkill for a
// code that also rotates every 30s and is backstopped by the atomic status
// flip; 128 bits keeps the symbol smaller with no practical forgeability loss.
const HMAC_TRUNC_BYTES = 16;
const ED25519_SIG_BYTES = 64;

const HEX = '0123456789abcdef';

function uuidToBytes(uuid: string): Uint8Array {
  const hex = uuid.replace(/-/g, '').toLowerCase();
  if (hex.length !== 32 || /[^0-9a-f]/.test(hex)) {
    throw new Error(`barcode v2: not a uuid: ${uuid}`);
  }
  const out = new Uint8Array(16);
  for (let i = 0; i < 16; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
  return out;
}

function bytesToUuid(b: Uint8Array, off = 0): string {
  let hex = '';
  for (let i = 0; i < 16; i++) {
    const v = b[off + i];
    hex += HEX[(v >> 4) & 0xf] + HEX[v & 0xf];
  }
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

// Unsigned LEB128. Uses Math (not <<) so a bucket beyond 2^28 still encodes
// correctly — bitwise ops in JS are 32-bit signed and would corrupt large
// buckets decades out.
function writeVarint(n: number): number[] {
  if (n < 0 || !Number.isFinite(n)) throw new Error('barcode v2: bad varint input');
  const out: number[] = [];
  let v = Math.floor(n);
  while (v > 0x7f) {
    out.push((v & 0x7f) | 0x80);
    v = Math.floor(v / 128);
  }
  out.push(v & 0x7f);
  return out;
}

function readVarint(b: Uint8Array, off: number): { value: number; next: number } {
  let shift = 1;
  let result = 0;
  let pos = off;
  for (;;) {
    if (pos >= b.length) throw new Error('barcode v2: truncated varint');
    const byte = b[pos++];
    result += (byte & 0x7f) * shift;
    if ((byte & 0x80) === 0) break;
    shift *= 128;
  }
  return { value: result, next: pos };
}

function bytesToB64url(bytes: Uint8Array): string {
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function b64urlToBytes(s: string): Uint8Array {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4);
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function concatBytes(...parts: Uint8Array[]): Uint8Array {
  const len = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(len);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

/** Constant-time byte compare (see timingSafeEqual for the string version). */
function timingSafeEqualBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/** The bytes that a v2 signature covers: ticketId || ownerId || bucketVarint. */
function v2Message(ticketId: string, ownerId: string, bucket: number): Uint8Array {
  return concatBytes(
    uuidToBytes(ticketId),
    uuidToBytes(ownerId),
    Uint8Array.from(writeVarint(bucket)),
  );
}

/**
 * Probe whether this runtime's Web Crypto exposes Ed25519. Not all engines do
 * yet; callers fall back to the `hmac` scheme when this is false rather than
 * throwing at scan time. Result is cached after the first probe.
 */
let _ed25519Probe: Promise<boolean> | null = null;
export function ed25519Supported(): Promise<boolean> {
  if (_ed25519Probe) return _ed25519Probe;
  _ed25519Probe = (async () => {
    try {
      ensureCryptoSubtleAvailable();
      await crypto.subtle.generateKey({ name: 'Ed25519' } as any, false, ['sign', 'verify']);
      return true;
    } catch {
      return false;
    }
  })();
  return _ed25519Probe;
}

/** Import a raw 32-byte Ed25519 public key (base64url) for verification. */
export async function importEd25519PublicKey(rawB64url: string): Promise<CryptoKey> {
  ensureCryptoSubtleAvailable();
  return crypto.subtle.importKey('raw', b64urlToBytes(rawB64url), { name: 'Ed25519' } as any, false, [
    'verify',
  ]);
}

/** Import a PKCS#8 Ed25519 private key (base64url) for signing. */
export async function importEd25519PrivateKey(pkcs8B64url: string): Promise<CryptoKey> {
  ensureCryptoSubtleAvailable();
  return crypto.subtle.importKey('pkcs8', b64urlToBytes(pkcs8B64url), { name: 'Ed25519' } as any, false, [
    'sign',
  ]);
}

export interface SignV2Options {
  ticketId: string;
  ownerId: string;
  scheme: BarcodeScheme;
  /** Required for the `hmac` scheme — the per-ticket barcode secret. */
  secret?: string;
  /** Required for the `ed25519` scheme — the org's Ed25519 private CryptoKey. */
  privateKey?: CryptoKey;
  bucket?: number;
}

/**
 * Compute a v2 signed barcode. Async; the caller refreshes every 30s at the
 * bucket boundary, exactly like v1's signBarcode.
 */
export async function signBarcodeV2(opts: SignV2Options): Promise<string> {
  const bucket = opts.bucket ?? currentBucket();
  const msg = v2Message(opts.ticketId, opts.ownerId, bucket);
  let sig: Uint8Array;

  if (opts.scheme === 'hmac') {
    if (!opts.secret) throw new Error('barcode v2 hmac: missing per-ticket secret');
    ensureCryptoSubtleAvailable();
    const key = await crypto.subtle.importKey(
      'raw',
      new TextEncoder().encode(opts.secret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign'],
    );
    const full = new Uint8Array(await crypto.subtle.sign('HMAC', key, msg));
    sig = full.slice(0, HMAC_TRUNC_BYTES);
  } else {
    if (!opts.privateKey) throw new Error('barcode v2 ed25519: missing private key');
    ensureCryptoSubtleAvailable();
    sig = new Uint8Array(await crypto.subtle.sign('Ed25519' as any, opts.privateKey, msg));
  }

  return `${V2_PREFIX}${SCHEME_TAG[opts.scheme]}${bytesToB64url(concatBytes(msg, sig))}`;
}

export type VerifyV2Reason =
  | 'malformed'
  | 'unsupported-scheme'
  | 'no-key'
  | 'bucket-expired'
  | 'signature-mismatch';

export interface VerifyResultV2 {
  ok: boolean;
  version: 1 | 2;
  scheme?: BarcodeScheme;
  reason?: VerifyResult['reason'] | VerifyV2Reason;
  legacy: boolean;
  ticketId?: string;
  ownerId?: string;
  bucket?: number;
}

export interface VerifyKeys {
  /** Per-ticket secret — used to verify the `hmac` scheme. */
  secret?: string;
  /** Org Ed25519 public CryptoKey — used to verify the `ed25519` scheme. */
  publicKey?: CryptoKey;
}

/** Verify a v2 (`T2-`) barcode against the supplied keys. */
export async function verifyBarcodeV2(
  payload: string,
  keys: VerifyKeys,
  options: { now?: number } = {},
): Promise<VerifyResultV2> {
  if (typeof payload !== 'string' || !payload.startsWith(V2_PREFIX)) {
    return { ok: false, version: 2, reason: 'malformed', legacy: false };
  }
  const tag = payload.charAt(V2_PREFIX.length);
  const scheme = TAG_SCHEME[tag];
  if (!scheme) return { ok: false, version: 2, reason: 'unsupported-scheme', legacy: false };

  let bytes: Uint8Array;
  let ticketId: string;
  let ownerId: string;
  let bucket: number;
  let sig: Uint8Array;
  let msg: Uint8Array;
  try {
    bytes = b64urlToBytes(payload.slice(V2_PREFIX.length + 1));
    if (bytes.length < 34) throw new Error('short');
    ticketId = bytesToUuid(bytes, 0);
    ownerId = bytesToUuid(bytes, 16);
    const v = readVarint(bytes, 32);
    bucket = v.value;
    sig = bytes.slice(v.next);
    msg = bytes.slice(0, v.next);
  } catch {
    return { ok: false, version: 2, scheme, reason: 'malformed', legacy: false };
  }

  const now = options.now ?? Date.now();
  if (Math.abs(currentBucket(now) - bucket) > BUCKET_TOLERANCE) {
    return { ok: false, version: 2, scheme, reason: 'bucket-expired', legacy: false, ticketId, ownerId, bucket };
  }

  const base = { version: 2 as const, scheme, legacy: false, ticketId, ownerId, bucket };
  try {
    if (scheme === 'hmac') {
      if (!keys.secret) return { ok: false, reason: 'no-key', ...base };
      ensureCryptoSubtleAvailable();
      const key = await crypto.subtle.importKey(
        'raw',
        new TextEncoder().encode(keys.secret),
        { name: 'HMAC', hash: 'SHA-256' },
        false,
        ['sign'],
      );
      const full = new Uint8Array(await crypto.subtle.sign('HMAC', key, msg));
      const expected = full.slice(0, HMAC_TRUNC_BYTES);
      if (sig.length !== HMAC_TRUNC_BYTES || !timingSafeEqualBytes(expected, sig)) {
        return { ok: false, reason: 'signature-mismatch', ...base };
      }
    } else {
      if (!keys.publicKey) return { ok: false, reason: 'no-key', ...base };
      if (sig.length !== ED25519_SIG_BYTES) return { ok: false, reason: 'signature-mismatch', ...base };
      ensureCryptoSubtleAvailable();
      const ok = await crypto.subtle.verify('Ed25519' as any, keys.publicKey, sig, msg);
      if (!ok) return { ok: false, reason: 'signature-mismatch', ...base };
    }
  } catch {
    return { ok: false, reason: 'signature-mismatch', ...base };
  }
  return { ok: true, ...base };
}

/**
 * Unified verifier the scanner should call: dispatches v2 (`T2-`) to
 * verifyBarcodeV2 and everything else to the v1 verifyBarcode, normalizing to
 * one result shape. Back-compatible — a v1 caller that passes only `secret`
 * keeps its exact v1 behavior.
 */
export async function verifyAnyBarcode(
  payload: string,
  keys: VerifyKeys,
  options: { now?: number } = {},
): Promise<VerifyResultV2> {
  if (typeof payload === 'string' && payload.startsWith(V2_PREFIX)) {
    return verifyBarcodeV2(payload, keys, options);
  }
  const r = await verifyBarcode(payload, keys.secret ?? '', options);
  return { ...r, version: 1 };
}
