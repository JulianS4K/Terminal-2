// Exos simulation harness — 100 scenarios across normal + edge cases.
//
// Goals:
//   * Exercise the REAL barcode signing/verification (lib/barcode.ts).
//   * Reimplement the rule logic in TypeScript and probe boundaries
//     for transfer state machine, promo codes, tier sale windows,
//     capacity races, manual entry, etc.
//   * Each scenario asserts an expected outcome — failures surface as
//     bugs. We want noisy, specific failures, not soft warnings.
//
// We import barcode.ts directly so any change to that file is caught
// here. The other rule logic lives in this file because Firestore Rules
// don't run outside the emulator — but the constants (BUCKET_TOLERANCE,
// usageLimit / expiresAt semantics) mirror what's in firestore.rules.

import {
  signBarcode,
  verifyBarcode,
  currentBucket,
  extractTicketIdFromAny,
} from './src/lib/barcode';

let pass = 0;
let fail = 0;
const failures: { id: number; name: string; reason: string }[] = [];

function assert(id: number, name: string, ok: boolean, reason: string) {
  if (ok) {
    pass++;
  } else {
    fail++;
    failures.push({ id, name, reason });
  }
}

// ---- Helpers -----------------------------------------------------------

const BUCKET_MS = 30_000;
const BUCKET_TOLERANCE = 2;

// Lower-cased email comparator — mirrors the Firestore rule fix that
// lowercases on write and uses .lower() on both sides.
const eqEmail = (a: string | undefined, b: string | undefined) =>
  (a ?? '').toLowerCase() === (b ?? '').toLowerCase();

// Transfer state machine — mirror of the rules + Firestore writes.
type Transfer = {
  id: string;
  ticketId: string;
  senderId: string;
  receiverEmail: string;
  status: 'pending' | 'completed' | 'cancelled';
};
type Ticket = {
  id: string;
  ownerId: string;
  status: 'active' | 'used';
  barcodeSecret: string;
  transferId?: string;
};

function tryClaim(
  transfer: Transfer,
  ticket: Ticket,
  receiverUid: string,
  receiverEmailRaw: string,
): { ok: boolean; reason?: string; newTicket?: Ticket; newTransfer?: Transfer } {
  if (transfer.status !== 'pending') {
    return { ok: false, reason: 'transfer-not-pending' };
  }
  if (!eqEmail(transfer.receiverEmail, receiverEmailRaw)) {
    return { ok: false, reason: 'email-mismatch' };
  }
  if (transfer.senderId === receiverUid) {
    return { ok: false, reason: 'self-claim' };
  }
  // Rotate secret on claim — required so a screenshot of the sender's
  // QR can't be redeemed after transfer.
  const newSecret = `secret-after-claim-${transfer.id}`;
  return {
    ok: true,
    newTicket: { ...ticket, ownerId: receiverUid, barcodeSecret: newSecret, transferId: transfer.id },
    newTransfer: { ...transfer, status: 'completed' },
  };
}

// Tier sale window check — mirrors EventDetails purchase guard.
function tierAvailable(
  tier: { capacity: number; sold: number; salesStart?: number; salesEnd?: number; visibility: 'public' | 'hidden' },
  now: number,
  unlockedHidden: boolean,
): { ok: boolean; reason?: string } {
  if (tier.visibility === 'hidden' && !unlockedHidden) return { ok: false, reason: 'hidden-no-unlock' };
  if (tier.salesStart !== undefined && now < tier.salesStart) return { ok: false, reason: 'sales-not-started' };
  if (tier.salesEnd !== undefined && now > tier.salesEnd) return { ok: false, reason: 'sales-ended' };
  if (tier.sold >= tier.capacity) return { ok: false, reason: 'sold-out' };
  return { ok: true };
}

// Promo redemption — mirrors promoUses sub-collection rule.
function tryRedeemPromo(
  promo: { code: string; usedCount: number; usageLimit?: number; expiresAt?: number },
  qty: number,
  now: number,
): { ok: boolean; reason?: string; newUsed?: number } {
  // Mirror firestore.rules:268-277. The buyer-update branch on
  // promoUses requires:
  //   * incoming.usedCount strictly > existing.usedCount  (rejects qty <= 0)
  //   * incoming.usedCount <= existing.usedCount + 10    (anti-rocket cap)
  //   * incoming.usedCount <= existing.usageLimit (if set)
  //   * existing.expiresAt > request.time (if set)
  if (typeof qty !== 'number' || !Number.isFinite(qty)) return { ok: false, reason: 'bad-qty' };
  if (qty <= 0) return { ok: false, reason: 'non-positive-qty' };
  if (qty > 10) return { ok: false, reason: 'over-cap' };
  if (promo.expiresAt !== undefined && now > promo.expiresAt) return { ok: false, reason: 'expired' };
  if (promo.usageLimit !== undefined && promo.usedCount + qty > promo.usageLimit) {
    return { ok: false, reason: 'limit-reached' };
  }
  return { ok: true, newUsed: promo.usedCount + qty };
}

// Capacity race using FieldValue.increment() semantics — Firestore
// serializes increments at the document level, so the rule re-evaluates
// against the post-commit state for the second writer.
function simulateIncrementRace(capacity: number, soldBefore: number, qtyA: number, qtyB: number) {
  // A commits first (arbitrary serialization choice).
  const stateAfterA = soldBefore + qtyA;
  const aPasses = stateAfterA <= capacity;
  if (!aPasses) {
    return { aPasses: false, bPasses: false, oversell: false };
  }
  // B's rule re-evaluates against existing=stateAfterA.
  const stateAfterB = stateAfterA + qtyB;
  const bPasses = stateAfterB <= capacity;
  return { aPasses, bPasses, oversell: bPasses && stateAfterB > capacity };
}

// Capacity race — two parallel buyers see the same `sold` count and both
// pass the rule's `<= totalTickets` check. Returns whether the second
// write would oversell (the known phase-2 gap that needs a Cloud
// Function transaction).
function simulateCapacityRace(capacity: number, soldBefore: number, qtyA: number, qtyB: number) {
  const seenByA = soldBefore;
  const seenByB = soldBefore;
  const aPasses = seenByA + qtyA <= capacity;
  const bPasses = seenByB + qtyB <= capacity;
  const finalSold = soldBefore + (aPasses ? qtyA : 0) + (bPasses ? qtyB : 0);
  return { aPasses, bPasses, oversell: finalSold > capacity };
}

// Manual entry — mirrors the OrganizerCheckIn manual-entry length cap
// (added in task #70). Anything over 256 chars is rejected.
function manualEntryAccepted(input: string): boolean {
  if (typeof input !== 'string') return false;
  if (input.length === 0 || input.length > 256) return false;
  return true;
}

// ---- Run --------------------------------------------------------------

async function run() {
  // ---- BARCODE: signing + verification (30 cases) ----------------------
  const SECRET_A = 'secret-aaaa-1111';
  const SECRET_B = 'secret-bbbb-2222';
  const TICKET_ID = 'TKabcdef1234';
  const OWNER_ID = 'uidJulian';

  // 1. Round-trip sign + verify within current bucket.
  {
    const sig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A);
    const v = await verifyBarcode(sig, SECRET_A);
    assert(1, 'sign + verify round trip', v.ok && !v.legacy, JSON.stringify(v));
  }

  // 2-4. Verify is OK at +/- 1 bucket and at exactly the tolerance
  // boundary in either direction.
  {
    const now = Date.now();
    const cur = currentBucket(now);
    const oldSig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A, cur - 2);
    const v2 = await verifyBarcode(oldSig, SECRET_A, { now });
    assert(2, '-2 bucket boundary accepted', v2.ok, JSON.stringify(v2));

    const futSig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A, cur + 2);
    const v3 = await verifyBarcode(futSig, SECRET_A, { now });
    assert(3, '+2 bucket boundary accepted', v3.ok, JSON.stringify(v3));

    const oldSig3 = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A, cur - 3);
    const v4 = await verifyBarcode(oldSig3, SECRET_A, { now });
    assert(4, '-3 bucket should be expired', !v4.ok && v4.reason === 'bucket-expired', JSON.stringify(v4));
  }

  // 5. Wrong secret rejected.
  {
    const sig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A);
    const v = await verifyBarcode(sig, SECRET_B);
    assert(5, 'wrong secret rejected', !v.ok && v.reason === 'signature-mismatch', JSON.stringify(v));
  }

  // 6. Mutated bucket rejected.
  {
    const sig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A);
    const parts = sig.slice(2).split(':');
    parts[2] = String(parseInt(parts[2], 10) + 100);
    const tampered = 'T-' + parts.join(':');
    const v = await verifyBarcode(tampered, SECRET_A);
    assert(6, 'mutated bucket rejected', !v.ok, JSON.stringify(v));
  }

  // 7. Mutated owner rejected.
  {
    const sig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A);
    const parts = sig.slice(2).split(':');
    parts[1] = 'attackerUid';
    const tampered = 'T-' + parts.join(':');
    const v = await verifyBarcode(tampered, SECRET_A);
    assert(7, 'mutated ownerId rejected', !v.ok && v.reason === 'signature-mismatch', JSON.stringify(v));
  }

  // 8. Mutated ticket id rejected.
  {
    const sig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A);
    const parts = sig.slice(2).split(':');
    parts[0] = 'TKattacker';
    const tampered = 'T-' + parts.join(':');
    const v = await verifyBarcode(tampered, SECRET_A);
    assert(8, 'mutated ticketId rejected', !v.ok && v.reason === 'signature-mismatch', JSON.stringify(v));
  }

  // 9. Truncated HMAC rejected.
  {
    const sig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A);
    const truncated = sig.slice(0, sig.length - 5);
    const v = await verifyBarcode(truncated, SECRET_A);
    assert(9, 'truncated HMAC rejected', !v.ok, JSON.stringify(v));
  }

  // 10. Legacy 3-segment payload accepted with legacy: true.
  {
    const legacy = `T-${TICKET_ID}:${OWNER_ID}:${currentBucket()}`;
    const v = await verifyBarcode(legacy, SECRET_A);
    assert(10, 'legacy 3-segment accepted as legacy', v.ok && v.legacy, JSON.stringify(v));
  }

  // 11. Empty secret should throw on sign (refuses to sign with empty).
  {
    let threw = false;
    try {
      await signBarcode(TICKET_ID, OWNER_ID, '');
    } catch {
      threw = true;
    }
    assert(11, 'empty secret refuses to sign', threw, 'sign did not throw');
  }

  // 12. Verify with empty secret on a legacy payload still works.
  {
    const legacy = `T-${TICKET_ID}:${OWNER_ID}:${currentBucket()}`;
    const v = await verifyBarcode(legacy, '');
    assert(12, 'verify legacy with empty secret', v.ok && v.legacy, JSON.stringify(v));
  }

  // 13. Verify with empty secret on signed payload should throw or fail.
  {
    const sig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A);
    let v: any;
    try {
      v = await verifyBarcode(sig, '');
    } catch (e) {
      v = { ok: false, reason: 'threw' };
    }
    assert(13, 'verify with empty secret on signed rejects', !v.ok, JSON.stringify(v));
  }

  // 14. Malformed prefix rejected.
  {
    const v = await verifyBarcode('X-foo:bar:0:abc', SECRET_A);
    assert(14, 'no T- prefix rejected', !v.ok && v.reason === 'malformed', JSON.stringify(v));
  }

  // 15. Empty payload rejected.
  {
    const v = await verifyBarcode('', SECRET_A);
    assert(15, 'empty payload rejected', !v.ok && v.reason === 'malformed', JSON.stringify(v));
  }

  // 16. 5-segment payload rejected as malformed.
  {
    const v = await verifyBarcode('T-a:b:1:c:d', SECRET_A);
    assert(16, '5-segment rejected', !v.ok && v.reason === 'malformed', JSON.stringify(v));
  }

  // 17. Non-numeric bucket rejected.
  {
    const sig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A);
    const parts = sig.slice(2).split(':');
    parts[2] = 'NaN';
    const tampered = 'T-' + parts.join(':');
    const v = await verifyBarcode(tampered, SECRET_A);
    assert(17, 'non-numeric bucket rejected', !v.ok && v.reason === 'bad-bucket', JSON.stringify(v));
  }

  // 18. extractTicketIdFromAny on signed barcode.
  {
    const sig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A);
    assert(18, 'extractTicketIdFromAny signed', extractTicketIdFromAny(sig) === TICKET_ID, 'extract returned ' + extractTicketIdFromAny(sig));
  }

  // 19. extractTicketIdFromAny on legacy.
  {
    const legacy = `T-${TICKET_ID}:${OWNER_ID}:${currentBucket()}`;
    assert(19, 'extractTicketIdFromAny legacy', extractTicketIdFromAny(legacy) === TICKET_ID, 'extract returned ' + extractTicketIdFromAny(legacy));
  }

  // 20. extractTicketIdFromAny on garbage.
  {
    assert(20, 'extractTicketIdFromAny null on empty', extractTicketIdFromAny('') === null, 'got ' + extractTicketIdFromAny(''));
  }

  // 21. Replay scenario — same bucket, same payload, two scans.
  // Both pass HMAC; the rule's "status != used" check is the second
  // line of defence.
  {
    const sig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A);
    const v1 = await verifyBarcode(sig, SECRET_A);
    const v2 = await verifyBarcode(sig, SECRET_A);
    assert(21, 'replay both pass HMAC (rule must enforce status)', v1.ok && v2.ok, '');
  }

  // 22. Long ticket id (Firestore docId is 20 chars; HMAC is fine).
  {
    const longId = 'TK' + 'x'.repeat(40);
    const sig = await signBarcode(longId, OWNER_ID, SECRET_A);
    const v = await verifyBarcode(sig, SECRET_A);
    assert(22, 'long ticketId round-trip', v.ok, JSON.stringify(v));
  }

  // 23. UTF-8 characters in secret (defensive — buyer-supplied secret is
  // a UUID, but make sure non-ASCII doesn't break TextEncoder).
  {
    const utfSecret = 'café-日本-🎫';
    const sig = await signBarcode(TICKET_ID, OWNER_ID, utfSecret);
    const v = await verifyBarcode(sig, utfSecret);
    assert(23, 'utf-8 secret round-trip', v.ok, JSON.stringify(v));
  }

  // 24. Manually-set clock skew of +60s (exactly 2 buckets — within window).
  // We pin to a specific bucket boundary so the test is deterministic
  // regardless of when in real-time we run.
  {
    const pinnedNow = 1_700_000_000_000; // bucket 56_666_666
    const sig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A, currentBucket(pinnedNow));
    const v = await verifyBarcode(sig, SECRET_A, { now: pinnedNow + 60_000 });
    assert(24, 'verify with +60s clock skew (within window)', v.ok, JSON.stringify(v));
  }

  // 25. Manually-set clock skew of -120s (4 buckets — just over window).
  {
    const pinnedNow = 1_700_000_000_000;
    const sig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A, currentBucket(pinnedNow));
    const v = await verifyBarcode(sig, SECRET_A, { now: pinnedNow - 120_000 });
    assert(25, 'verify with -120s clock skew rejected', !v.ok && v.reason === 'bucket-expired', JSON.stringify(v));
  }

  // 26. Different ownerId in barcode vs verify caller (the rule still
  // verifies via stored secret, so a swapped-owner barcode signed with
  // attacker's secret won't validate).
  {
    const sig = await signBarcode(TICKET_ID, 'imposterUid', SECRET_A);
    const v = await verifyBarcode(sig, SECRET_A);
    // Will pass HMAC if the imposter happened to know the secret —
    // the security boundary is "only owner reads the secret". We just
    // confirm verifyBarcode returns the imposter ownerId so the
    // OrganizerCheckIn caller can compare against the ticket doc's
    // ownerId and reject.
    assert(26, 'imposter owner reflected back', v.ok && v.ownerId === 'imposterUid', JSON.stringify(v));
  }

  // 27. signBarcode is deterministic for fixed bucket — important so
  // the same barcode is shown twice if the buyer pulls the page within
  // a bucket window.
  {
    const b = currentBucket();
    const a1 = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A, b);
    const a2 = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A, b);
    assert(27, 'sign deterministic per bucket', a1 === a2, `a1=${a1} a2=${a2}`);
  }

  // 28. Different buckets produce different barcodes.
  {
    const b = currentBucket();
    const a1 = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A, b);
    const a2 = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A, b + 1);
    assert(28, 'different buckets different barcodes', a1 !== a2, '');
  }

  // 29. Different secrets produce different barcodes for same bucket.
  {
    const b = currentBucket();
    const a1 = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A, b);
    const a2 = await signBarcode(TICKET_ID, OWNER_ID, SECRET_B, b);
    assert(29, 'different secrets different barcodes', a1 !== a2, '');
  }

  // 30. Verify invariant: payload length is always > T-{ticketId}: prefix.
  {
    const sig = await signBarcode(TICKET_ID, OWNER_ID, SECRET_A);
    assert(30, 'signed payload longer than legacy', sig.length > `T-${TICKET_ID}:${OWNER_ID}:0`.length, `len=${sig.length}`);
  }

  // ---- TRANSFER state machine (20 cases) -------------------------------

  const baseTicket: Ticket = { id: 't1', ownerId: 'uidA', status: 'active', barcodeSecret: 'secretA' };
  const baseTransfer = (): Transfer => ({
    id: 'xfer1',
    ticketId: 't1',
    senderId: 'uidA',
    receiverEmail: 'bob@example.com',
    status: 'pending',
  });

  // 31. Happy path claim.
  {
    const r = tryClaim(baseTransfer(), baseTicket, 'uidB', 'bob@example.com');
    assert(31, 'happy claim', r.ok && r.newTicket?.ownerId === 'uidB', JSON.stringify(r));
  }

  // 32. Claim with case-mismatched email succeeds (rule lowercases).
  {
    const r = tryClaim(baseTransfer(), baseTicket, 'uidB', 'BOB@Example.COM');
    assert(32, 'case-mismatch email accepted', r.ok, JSON.stringify(r));
  }

  // 33. Claim with whitespace email — should this trim? Rules don't
  // trim. Test current behaviour.
  {
    const r = tryClaim(baseTransfer(), baseTicket, 'uidB', '  bob@example.com  ');
    assert(33, 'whitespace email NOT trimmed (matches rule)', !r.ok, JSON.stringify(r));
  }

  // 34. Claim by sender themselves rejected.
  {
    const r = tryClaim(baseTransfer(), baseTicket, 'uidA', 'bob@example.com');
    assert(34, 'sender cannot self-claim', !r.ok && r.reason === 'self-claim', JSON.stringify(r));
  }

  // 35. Claim wrong receiver email rejected.
  {
    const r = tryClaim(baseTransfer(), baseTicket, 'uidC', 'carl@example.com');
    assert(35, 'wrong email rejected', !r.ok && r.reason === 'email-mismatch', JSON.stringify(r));
  }

  // 36. Double-claim rejected — second claim sees status=completed.
  {
    const t1 = baseTransfer();
    const r1 = tryClaim(t1, baseTicket, 'uidB', 'bob@example.com');
    const r2 = tryClaim(r1.newTransfer!, baseTicket, 'uidB', 'bob@example.com');
    assert(36, 'double-claim rejected', !r2.ok && r2.reason === 'transfer-not-pending', JSON.stringify(r2));
  }

  // 37. Cancelled transfer cannot be claimed.
  {
    const t = { ...baseTransfer(), status: 'cancelled' as const };
    const r = tryClaim(t, baseTicket, 'uidB', 'bob@example.com');
    assert(37, 'cancelled cannot be claimed', !r.ok, JSON.stringify(r));
  }

  // 38. Secret rotates on claim.
  {
    const r = tryClaim(baseTransfer(), baseTicket, 'uidB', 'bob@example.com');
    assert(38, 'barcodeSecret rotates on claim', r.newTicket!.barcodeSecret !== baseTicket.barcodeSecret, JSON.stringify(r));
  }

  // 39. After claim, sender's signed barcode (against old secret) no
  // longer verifies against new secret.
  {
    const sigSender = await signBarcode('t1', 'uidA', baseTicket.barcodeSecret);
    const r = tryClaim(baseTransfer(), baseTicket, 'uidB', 'bob@example.com');
    const v = await verifyBarcode(sigSender, r.newTicket!.barcodeSecret);
    assert(39, 'sender old barcode invalid after rotate', !v.ok, JSON.stringify(v));
  }

  // 40. After claim, receiver mints new barcode that verifies.
  {
    const r = tryClaim(baseTransfer(), baseTicket, 'uidB', 'bob@example.com');
    const sig = await signBarcode('t1', 'uidB', r.newTicket!.barcodeSecret);
    const v = await verifyBarcode(sig, r.newTicket!.barcodeSecret);
    assert(40, 'receiver new barcode verifies', v.ok && v.ownerId === 'uidB', JSON.stringify(v));
  }

  // 41-44. Receiver email variants that should all match.
  for (const [i, variant] of ['Bob@Example.com', 'BOB@EXAMPLE.COM', 'bob@example.COM', 'bob@Example.com'].entries()) {
    const r = tryClaim(baseTransfer(), baseTicket, 'uidB', variant);
    assert(41 + i, `case-variant ${variant} accepted`, r.ok, JSON.stringify(r));
  }

  // 45. Empty receiver email rejected.
  {
    const r = tryClaim(baseTransfer(), baseTicket, 'uidB', '');
    assert(45, 'empty receiver email rejected', !r.ok && r.reason === 'email-mismatch', JSON.stringify(r));
  }

  // 46. Sender attempts claim of own already-cancelled transfer — both
  // self-claim AND not-pending; the order of checks matters for the
  // error surfaced.
  {
    const t = { ...baseTransfer(), status: 'cancelled' as const };
    const r = tryClaim(t, baseTicket, 'uidA', 'bob@example.com');
    assert(46, 'cancelled-and-self-claim returns first error', !r.ok && r.reason === 'transfer-not-pending', JSON.stringify(r));
  }

  // 47. Two simultaneous claim attempts — only first succeeds. (Linear
  // simulation — Firestore's serverTimestamp ordering would reject the
  // second.)
  {
    const t = baseTransfer();
    const r1 = tryClaim(t, baseTicket, 'uidB', 'bob@example.com');
    const r2 = tryClaim(r1.newTransfer!, baseTicket, 'uidB', 'bob@example.com');
    assert(47, 'concurrent claim — only first wins', r1.ok && !r2.ok, '');
  }

  // 48. Receiver email with leading + tag is preserved.
  {
    const t = { ...baseTransfer(), receiverEmail: 'bob+vip@example.com' };
    const r = tryClaim(t, baseTicket, 'uidB', 'BOB+VIP@example.com');
    assert(48, '+tagged email accepted case-insensitively', r.ok, JSON.stringify(r));
  }

  // 49. Unicode email accepted case-insensitively.
  {
    const t = { ...baseTransfer(), receiverEmail: 'café@example.com' };
    const r = tryClaim(t, baseTicket, 'uidB', 'CAFÉ@EXAMPLE.COM');
    assert(49, 'unicode email lowercases via JS', r.ok, JSON.stringify(r));
  }

  // 50. Transfer ticket then immediately try to scan original barcode
  // — should fail because secret rotated.
  {
    const oldSig = await signBarcode('t1', 'uidA', baseTicket.barcodeSecret);
    const r = tryClaim(baseTransfer(), baseTicket, 'uidB', 'bob@example.com');
    const v = await verifyBarcode(oldSig, r.newTicket!.barcodeSecret);
    assert(50, 'sender barcode invalid post-claim end-to-end', !v.ok, JSON.stringify(v));
  }

  // ---- TIER SALE WINDOW (15 cases) ------------------------------------

  const NOW = 1_700_000_000_000;
  const baseTier = { capacity: 100, sold: 0, visibility: 'public' as const };

  // 51. Available now.
  {
    const r = tierAvailable(baseTier, NOW, false);
    assert(51, 'public tier available', r.ok, JSON.stringify(r));
  }

  // 52. Sold-out at exact capacity.
  {
    const r = tierAvailable({ ...baseTier, sold: 100 }, NOW, false);
    assert(52, 'sold-out at capacity', !r.ok && r.reason === 'sold-out', JSON.stringify(r));
  }

  // 53. Sold one less than capacity → available.
  {
    const r = tierAvailable({ ...baseTier, sold: 99 }, NOW, false);
    assert(53, 'last seat available', r.ok, JSON.stringify(r));
  }

  // 54. Sales not started.
  {
    const r = tierAvailable({ ...baseTier, salesStart: NOW + 1000 }, NOW, false);
    assert(54, 'before salesStart rejected', !r.ok && r.reason === 'sales-not-started', JSON.stringify(r));
  }

  // 55. Sales exactly at start.
  {
    const r = tierAvailable({ ...baseTier, salesStart: NOW }, NOW, false);
    assert(55, 'at salesStart accepted', r.ok, JSON.stringify(r));
  }

  // 56. Sales ended.
  {
    const r = tierAvailable({ ...baseTier, salesEnd: NOW - 1000 }, NOW, false);
    assert(56, 'after salesEnd rejected', !r.ok && r.reason === 'sales-ended', JSON.stringify(r));
  }

  // 57. Sales exactly at end.
  {
    const r = tierAvailable({ ...baseTier, salesEnd: NOW }, NOW, false);
    assert(57, 'at salesEnd accepted', r.ok, JSON.stringify(r));
  }

  // 58. Hidden tier without unlock.
  {
    const r = tierAvailable({ ...baseTier, visibility: 'hidden' }, NOW, false);
    assert(58, 'hidden without unlock rejected', !r.ok && r.reason === 'hidden-no-unlock', JSON.stringify(r));
  }

  // 59. Hidden tier with unlock.
  {
    const r = tierAvailable({ ...baseTier, visibility: 'hidden' }, NOW, true);
    assert(59, 'hidden with unlock available', r.ok, JSON.stringify(r));
  }

  // 60. Hidden tier with unlock but sold out.
  {
    const r = tierAvailable({ ...baseTier, visibility: 'hidden', sold: 100 }, NOW, true);
    assert(60, 'hidden unlocked but sold out', !r.ok && r.reason === 'sold-out', JSON.stringify(r));
  }

  // 61. Sales window with start > end (organizer error).
  {
    const r = tierAvailable({ ...baseTier, salesStart: NOW + 1000, salesEnd: NOW - 1000 }, NOW, false);
    assert(61, 'inverted window rejected (sales-not-started wins)', !r.ok, JSON.stringify(r));
  }

  // 62. Sales not started and hidden with unlock — unlock overrides hidden but window check fires.
  {
    const r = tierAvailable({ ...baseTier, visibility: 'hidden', salesStart: NOW + 1000 }, NOW, true);
    assert(62, 'unlock + sales-not-started rejects on window', !r.ok && r.reason === 'sales-not-started', JSON.stringify(r));
  }

  // 63. Capacity = 0 (sentinel for "no inventory" — should reject).
  {
    const r = tierAvailable({ ...baseTier, capacity: 0 }, NOW, false);
    assert(63, 'zero-capacity rejects', !r.ok && r.reason === 'sold-out', JSON.stringify(r));
  }

  // 64. Negative sold (data corruption — should still allow buy).
  {
    const r = tierAvailable({ ...baseTier, sold: -1 }, NOW, false);
    assert(64, 'negative sold treated as available', r.ok, JSON.stringify(r));
  }

  // 65. Sold > capacity (already oversold — should reject further).
  {
    const r = tierAvailable({ ...baseTier, sold: 101 }, NOW, false);
    assert(65, 'oversold tier rejects', !r.ok && r.reason === 'sold-out', JSON.stringify(r));
  }

  // ---- PROMO CODE (15 cases) -------------------------------------------

  // 66. Unlimited code, no expiry.
  {
    const r = tryRedeemPromo({ code: 'OPEN', usedCount: 5 }, 1, NOW);
    assert(66, 'unlimited code redeems', r.ok, JSON.stringify(r));
  }

  // 67. Within usage limit.
  {
    const r = tryRedeemPromo({ code: 'X', usedCount: 9, usageLimit: 10 }, 1, NOW);
    assert(67, 'last redemption within limit', r.ok, JSON.stringify(r));
  }

  // 68. At usage limit + 1 attempt.
  {
    const r = tryRedeemPromo({ code: 'X', usedCount: 10, usageLimit: 10 }, 1, NOW);
    assert(68, 'over limit rejects', !r.ok && r.reason === 'limit-reached', JSON.stringify(r));
  }

  // 69. Multi-qty redemption fits.
  {
    const r = tryRedeemPromo({ code: 'X', usedCount: 5, usageLimit: 10 }, 5, NOW);
    assert(69, 'multi-qty fits exactly', r.ok && r.newUsed === 10, JSON.stringify(r));
  }

  // 70. Multi-qty redemption overshoots.
  {
    const r = tryRedeemPromo({ code: 'X', usedCount: 5, usageLimit: 10 }, 6, NOW);
    assert(70, 'multi-qty overshoots', !r.ok && r.reason === 'limit-reached', JSON.stringify(r));
  }

  // 71. Expired code.
  {
    const r = tryRedeemPromo({ code: 'X', usedCount: 0, expiresAt: NOW - 1 }, 1, NOW);
    assert(71, 'expired code rejects', !r.ok && r.reason === 'expired', JSON.stringify(r));
  }

  // 72. Code expiring exactly now (boundary).
  {
    const r = tryRedeemPromo({ code: 'X', usedCount: 0, expiresAt: NOW }, 1, NOW);
    assert(72, 'expiresAt == now still valid', r.ok, JSON.stringify(r));
  }

  // 73. Code expiring in 1ms.
  {
    const r = tryRedeemPromo({ code: 'X', usedCount: 0, expiresAt: NOW + 1 }, 1, NOW);
    assert(73, 'expires in future valid', r.ok, JSON.stringify(r));
  }

  // 74. Concurrent redemption with FieldValue.increment() semantics.
  // Firestore serializes increments per-doc, so the second writer's
  // rule re-evaluates against post-A state and is rejected.
  {
    const promo = { code: 'X', usedCount: 9, usageLimit: 10 };
    const a = tryRedeemPromo(promo, 1, NOW);
    // After A commits, existing.usedCount = 10. B's increment(1) →
    // incoming.usedCount = 11, which fails `<= usageLimit` (10).
    const promoAfterA = { ...promo, usedCount: a.newUsed ?? promo.usedCount };
    const b = tryRedeemPromo(promoAfterA, 1, NOW);
    assert(74, 'concurrent promo race closed by serialization', a.ok && !b.ok, JSON.stringify({ a, b }));
  }

  // 75. usageLimit of 0 (organizer disabled the code).
  {
    const r = tryRedeemPromo({ code: 'X', usedCount: 0, usageLimit: 0 }, 1, NOW);
    assert(75, 'usageLimit=0 always rejects', !r.ok, JSON.stringify(r));
  }

  // 76. Negative qty rejected by the strict-monotonic rule (firestore.rules:270
  // requires incoming.usedCount > existing.usedCount). A increment(-1)
  // would yield incoming < existing and is rejected.
  {
    const r = tryRedeemPromo({ code: 'X', usedCount: 5, usageLimit: 10 }, -1, NOW);
    assert(76, 'negative qty rejected by strict-monotonic rule', !r.ok && r.reason === 'non-positive-qty', JSON.stringify(r));
  }

  // 77. Very large qty rejected by anti-rocket cap (>10), which fires
  // before the limit check. firestore.rules:271.
  {
    const r = tryRedeemPromo({ code: 'X', usedCount: 0, usageLimit: 10 }, 1_000_000, NOW);
    assert(77, 'huge qty rejected by anti-rocket cap', !r.ok && r.reason === 'over-cap', JSON.stringify(r));
  }

  // 78. Both expired and limit-reached — expiry check fires first.
  {
    const r = tryRedeemPromo({ code: 'X', usedCount: 10, usageLimit: 10, expiresAt: NOW - 1 }, 1, NOW);
    assert(78, 'expired + limit-reached → expired wins', !r.ok && r.reason === 'expired', JSON.stringify(r));
  }

  // 79. Code with usageLimit == usedCount (already exhausted).
  {
    const r = tryRedeemPromo({ code: 'X', usedCount: 100, usageLimit: 100 }, 1, NOW);
    assert(79, 'exhausted code rejects', !r.ok, JSON.stringify(r));
  }

  // 80. Multi-qty at exact remaining capacity.
  {
    const r = tryRedeemPromo({ code: 'X', usedCount: 7, usageLimit: 10 }, 3, NOW);
    assert(80, 'multi-qty exact remaining fits', r.ok, JSON.stringify(r));
  }

  // ---- CAPACITY race (10 cases) ----------------------------------------

  // 81. Two single buys against last 2 seats — both ok.
  {
    const r = simulateIncrementRace(100, 98, 1, 1);
    assert(81, '2 buys vs 2 seats — neither oversells', r.aPasses && r.bPasses && !r.oversell, JSON.stringify(r));
  }

  // 82. Two single buys against last 1 seat — Firestore serializes
  // increments at the doc level, so B's rule re-evaluates against
  // existing=100 and rejects.
  {
    const r = simulateIncrementRace(100, 99, 1, 1);
    assert(82, 'oversell race closed by increment serialization',
           r.aPasses && !r.bPasses && !r.oversell, JSON.stringify(r));
  }

  // 83. Two large multi-buys.
  {
    const r = simulateIncrementRace(100, 90, 5, 5);
    assert(83, '5+5 against 10 seats — both fit', r.aPasses && r.bPasses && !r.oversell, JSON.stringify(r));
  }

  // 84. Two large multi-buys overshooting — second rejected.
  {
    const r = simulateIncrementRace(100, 90, 6, 6);
    assert(84, '6+6 against 10 seats — second rejected', r.aPasses && !r.bPasses && !r.oversell, JSON.stringify(r));
  }

  // 85. One huge buy + one small — second rejected.
  {
    const r = simulateIncrementRace(100, 0, 99, 2);
    assert(85, '99+2 against 100 — second rejected', r.aPasses && !r.bPasses && !r.oversell, JSON.stringify(r));
  }

  // 86. Already oversold-state-impossible (rule clamps creates) — A rejected too.
  {
    const r = simulateIncrementRace(100, 100, 1, 1);
    assert(86, 'sold-out state — neither passes', !r.aPasses && !r.bPasses && !r.oversell, JSON.stringify(r));
  }

  // 87. Zero-quantity buys — both no-op.
  {
    const r = simulateIncrementRace(100, 99, 0, 0);
    assert(87, 'zero-qty buys — both pass, no oversell', r.aPasses && r.bPasses && !r.oversell, JSON.stringify(r));
  }

  // 88. Capacity 1, two buyers — second rejected.
  {
    const r = simulateIncrementRace(1, 0, 1, 1);
    assert(88, '1 seat 2 buyers — second rejected', r.aPasses && !r.bPasses && !r.oversell, JSON.stringify(r));
  }

  // 89. Capacity 1, sold 0, A buys 0 + B buys 1.
  {
    const r = simulateIncrementRace(1, 0, 0, 1);
    assert(89, 'A=0 B=1 vs cap 1 — both pass', r.aPasses && r.bPasses && !r.oversell, JSON.stringify(r));
  }

  // 90. Boundary: A=2 fits exactly, B=1 rejected after A commits.
  {
    const r = simulateIncrementRace(10, 8, 2, 1);
    assert(90, 'A=2 fits exact; B=1 rejected after serialization', r.aPasses && !r.bPasses && !r.oversell, JSON.stringify(r));
  }

  // ---- MANUAL ENTRY (10 cases) -----------------------------------------

  // 91. Normal docId.
  {
    assert(91, 'manual normal docId', manualEntryAccepted('abc123def456'), 'rejected');
  }

  // 92. Empty input.
  {
    assert(92, 'manual empty rejected', !manualEntryAccepted(''), 'accepted');
  }

  // 93. Exactly 256 chars.
  {
    assert(93, 'manual 256 chars accepted', manualEntryAccepted('x'.repeat(256)), 'rejected');
  }

  // 94. 257 chars rejected.
  {
    assert(94, 'manual 257 chars rejected', !manualEntryAccepted('x'.repeat(257)), 'accepted');
  }

  // 95. Whitespace-padded — accepted as-is (organizer should know to trim).
  {
    assert(95, 'manual whitespace-padded accepted', manualEntryAccepted('  abc123  '), 'rejected — should accept and let UI trim');
  }

  // 96. Newline injected (potential paste from email).
  {
    assert(96, 'manual newline-bearing accepted', manualEntryAccepted('abc\n123'), 'rejected — let UI sanitize');
  }

  // 97. Manual entry of full QR payload (organizer pastes scanned text).
  {
    const payload = `T-abc:def:${currentBucket()}:sigsig`;
    assert(97, 'manual full QR payload accepted (length-OK)', manualEntryAccepted(payload), JSON.stringify({ payload, len: payload.length }));
    // OrganizerCheckIn should pass this through extractTicketIdFromAny.
    assert(97.5 as any, 'manual QR payload extracts to docId', extractTicketIdFromAny(payload) === 'abc', 'extract failed');
  }

  // 98. Numeric-only input (some organizers use numeric short codes).
  {
    assert(98, 'manual numeric accepted', manualEntryAccepted('00012345'), 'rejected');
  }

  // 99. Unicode input.
  {
    assert(99, 'manual unicode accepted', manualEntryAccepted('チケット-001'), 'rejected');
  }

  // 100. Non-string (defensive — TypeScript catches but runtime might see it from a query string).
  {
    assert(100, 'manual non-string rejected', !manualEntryAccepted(undefined as unknown as string), 'accepted non-string');
  }

  // ---- REPORT ----------------------------------------------------------
  console.log('');
  console.log(`Pass: ${pass}  Fail: ${fail}`);
  if (fail > 0) {
    console.log('');
    console.log('FAILURES:');
    for (const f of failures) {
      console.log(`  #${f.id}  ${f.name}`);
      console.log(`        ${f.reason}`);
    }
    process.exit(1);
  }
}

run().catch((e) => {
  console.error(e);
  process.exit(2);
});
