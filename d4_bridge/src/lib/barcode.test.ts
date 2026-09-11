import { describe, it, expect } from 'vitest';
import { currentBucket, signBarcode, verifyBarcode, extractTicketIdFromAny } from './barcode';

const TICKET = '11111111-2222-3333-4444-555555555555';
const OWNER = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const SECRET = 'per-ticket-secret-minted-at-fulfillment';
const NOW = Date.UTC(2026, 8, 11, 19, 0, 0); // 2026-09-11T19:00:00Z
const BUCKET_MS = 30_000;

describe('currentBucket', () => {
  it('is a 30-second bucket', () => {
    const b = currentBucket(NOW);
    expect(currentBucket(NOW + BUCKET_MS - 1)).toBe(b);
    expect(currentBucket(NOW + BUCKET_MS)).toBe(b + 1);
  });
});

describe('signBarcode / verifyBarcode', () => {
  it('round-trips a freshly signed barcode', async () => {
    const bucket = currentBucket(NOW);
    const payload = await signBarcode(TICKET, OWNER, SECRET, bucket);
    expect(payload.startsWith(`T-${TICKET}:${OWNER}:${bucket}:`)).toBe(true);
    const res = await verifyBarcode(payload, SECRET, { now: NOW });
    expect(res).toMatchObject({ ok: true, legacy: false, ticketId: TICKET, ownerId: OWNER, bucket });
  });

  it('signature is deterministic per (ticket, owner, bucket, secret)', async () => {
    const bucket = currentBucket(NOW);
    const a = await signBarcode(TICKET, OWNER, SECRET, bucket);
    const b = await signBarcode(TICKET, OWNER, SECRET, bucket);
    expect(a).toBe(b);
    const c = await signBarcode(TICKET, OWNER, SECRET, bucket + 1);
    expect(c).not.toBe(a);
  });

  it('accepts up to 2 buckets of skew either side, rejects beyond', async () => {
    const bucket = currentBucket(NOW);
    const payload = await signBarcode(TICKET, OWNER, SECRET, bucket);
    for (const skew of [-2, -1, 0, 1, 2]) {
      const res = await verifyBarcode(payload, SECRET, { now: NOW + skew * BUCKET_MS });
      expect(res.ok, `skew ${skew}`).toBe(true);
    }
    for (const skew of [-3, 3, 120]) {
      const res = await verifyBarcode(payload, SECRET, { now: NOW + skew * BUCKET_MS });
      expect(res.ok, `skew ${skew}`).toBe(false);
      expect(res.reason).toBe('bucket-expired');
    }
  });

  it('rejects a barcode signed with a different secret (rotated on transfer)', async () => {
    const bucket = currentBucket(NOW);
    const payload = await signBarcode(TICKET, OWNER, SECRET, bucket);
    const res = await verifyBarcode(payload, 'rotated-secret', { now: NOW });
    expect(res.ok).toBe(false);
    expect(res.reason).toBe('signature-mismatch');
    expect(res.ticketId).toBe(TICKET);
  });

  it('rejects a barcode whose owner segment was tampered', async () => {
    const bucket = currentBucket(NOW);
    const payload = await signBarcode(TICKET, OWNER, SECRET, bucket);
    const tampered = payload.replace(OWNER, 'ffffffff-0000-0000-0000-000000000000');
    const res = await verifyBarcode(tampered, SECRET, { now: NOW });
    expect(res.ok).toBe(false);
    expect(res.reason).toBe('signature-mismatch');
  });

  it('rejects legacy 3-segment barcodes but reports them as legacy', async () => {
    const res = await verifyBarcode(`T-${TICKET}:${OWNER}:12345`, SECRET, { now: NOW });
    expect(res).toMatchObject({ ok: false, legacy: true, reason: 'legacy-no-secret', ticketId: TICKET });
  });

  it('rejects malformed payloads', async () => {
    for (const bad of ['', TICKET, 'T-', 'T-a:b', 'T-a:b:c:d:e', 'X-a:b:c:d']) {
      const res = await verifyBarcode(bad, SECRET, { now: NOW });
      expect(res.ok, bad).toBe(false);
      expect(res.reason, bad).toBe('malformed');
    }
    const badBucket = await verifyBarcode(`T-${TICKET}:${OWNER}:notanumber:sig`, SECRET, { now: NOW });
    expect(badBucket.reason).toBe('bad-bucket');
  });

  it('refuses to sign with an empty secret', async () => {
    await expect(signBarcode(TICKET, OWNER, '')).rejects.toThrow(/empty secret/);
  });
});

describe('extractTicketIdFromAny', () => {
  it('pulls the ticket id from signed, legacy and bare payloads', () => {
    expect(extractTicketIdFromAny(`T-${TICKET}:${OWNER}:1:sig`)).toBe(TICKET);
    expect(extractTicketIdFromAny(`T-${TICKET}:${OWNER}:1`)).toBe(TICKET);
    expect(extractTicketIdFromAny(TICKET)).toBe(TICKET);
    expect(extractTicketIdFromAny('')).toBeNull();
    expect(extractTicketIdFromAny('T-')).toBeNull();
  });
});
