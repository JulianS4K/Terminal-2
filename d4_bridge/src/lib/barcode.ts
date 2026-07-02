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
 */
export function extractTicketIdFromAny(payload: string): string | null {
  if (!payload || typeof payload !== 'string') return null;
  const trimmed = payload.startsWith('T-') ? payload.slice(2) : payload;
  const id = trimmed.split(':')[0];
  return id || null;
}
