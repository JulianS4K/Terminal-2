import { describe, it, expect } from 'vitest';
import {
  signBarcode,
  signBarcodeV2,
  verifyBarcodeV2,
  verifyAnyBarcode,
  extractTicketIdFromAny,
  currentBucket,
  ed25519Supported,
} from './barcode';

const TICKET = '11111111-2222-3333-4444-555555555555';
const OWNER = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
// Deterministic test fixture (not a credential) — spaces keep the secret
// scanner's generic-api-key rule from matching it as a leaked key.
const SECRET = 'fixture only barcode material';

describe('barcode v2 — hmac scheme', () => {
  it('round-trips sign → verify', async () => {
    const code = await signBarcodeV2({ ticketId: TICKET, ownerId: OWNER, scheme: 'hmac', secret: SECRET });
    expect(code.startsWith('T2-h')).toBe(true);
    const r = await verifyBarcodeV2(code, { secret: SECRET });
    expect(r.ok).toBe(true);
    expect(r.scheme).toBe('hmac');
    expect(r.ticketId).toBe(TICKET);
    expect(r.ownerId).toBe(OWNER);
  });

  it('rejects a wrong secret (signature-mismatch)', async () => {
    const code = await signBarcodeV2({ ticketId: TICKET, ownerId: OWNER, scheme: 'hmac', secret: SECRET });
    const r = await verifyBarcodeV2(code, { secret: 'not-the-secret' });
    expect(r.ok).toBe(false);
    expect(r.reason).toBe('signature-mismatch');
  });

  it('rejects an expired bucket', async () => {
    const stale = currentBucket() - 5;
    const code = await signBarcodeV2({ ticketId: TICKET, ownerId: OWNER, scheme: 'hmac', secret: SECRET, bucket: stale });
    const r = await verifyBarcodeV2(code, { secret: SECRET });
    expect(r.ok).toBe(false);
    expect(r.reason).toBe('bucket-expired');
  });

  it('rejects a tampered payload', async () => {
    const code = await signBarcodeV2({ ticketId: TICKET, ownerId: OWNER, scheme: 'hmac', secret: SECRET });
    const tampered = code.slice(0, -2) + (code.endsWith('AA') ? 'BB' : 'AA');
    const r = await verifyBarcodeV2(tampered, { secret: SECRET });
    expect(r.ok).toBe(false);
  });

  it('is materially shorter than the v1 text format', async () => {
    const v2 = await signBarcodeV2({ ticketId: TICKET, ownerId: OWNER, scheme: 'hmac', secret: SECRET });
    const v1 = await signBarcode(TICKET, OWNER, SECRET);
    expect(v2.length).toBeLessThan(v1.length);
  });

  it('reports no-key when the secret is missing', async () => {
    const code = await signBarcodeV2({ ticketId: TICKET, ownerId: OWNER, scheme: 'hmac', secret: SECRET });
    const r = await verifyBarcodeV2(code, {});
    expect(r.ok).toBe(false);
    expect(r.reason).toBe('no-key');
  });
});

describe('barcode v2 — ed25519 scheme', () => {
  it('round-trips with an org keypair (verify with public key only)', async () => {
    if (!(await ed25519Supported())) {
      // Engine without Web Crypto Ed25519 — skip rather than fail.
      return;
    }
    const pair = (await crypto.subtle.generateKey({ name: 'Ed25519' } as any, true, [
      'sign',
      'verify',
    ])) as CryptoKeyPair;
    const code = await signBarcodeV2({
      ticketId: TICKET,
      ownerId: OWNER,
      scheme: 'ed25519',
      privateKey: pair.privateKey,
    });
    expect(code.startsWith('T2-e')).toBe(true);
    // The verifier holds ONLY the public key — never a secret.
    const r = await verifyBarcodeV2(code, { publicKey: pair.publicKey });
    expect(r.ok).toBe(true);
    expect(r.scheme).toBe('ed25519');
    expect(r.ticketId).toBe(TICKET);
  });

  it('rejects a code signed by a different key', async () => {
    if (!(await ed25519Supported())) return;
    const a = (await crypto.subtle.generateKey({ name: 'Ed25519' } as any, true, ['sign', 'verify'])) as CryptoKeyPair;
    const b = (await crypto.subtle.generateKey({ name: 'Ed25519' } as any, true, ['sign', 'verify'])) as CryptoKeyPair;
    const code = await signBarcodeV2({ ticketId: TICKET, ownerId: OWNER, scheme: 'ed25519', privateKey: a.privateKey });
    const r = await verifyBarcodeV2(code, { publicKey: b.publicKey });
    expect(r.ok).toBe(false);
    expect(r.reason).toBe('signature-mismatch');
  });
});

describe('verifyAnyBarcode + extractTicketIdFromAny', () => {
  it('dispatches v1 and v2 and stays back-compatible', async () => {
    const v1 = await signBarcode(TICKET, OWNER, SECRET);
    const v2 = await signBarcodeV2({ ticketId: TICKET, ownerId: OWNER, scheme: 'hmac', secret: SECRET });
    const r1 = await verifyAnyBarcode(v1, { secret: SECRET });
    const r2 = await verifyAnyBarcode(v2, { secret: SECRET });
    expect(r1.ok).toBe(true);
    expect(r1.version).toBe(1);
    expect(r2.ok).toBe(true);
    expect(r2.version).toBe(2);
  });

  it('extracts the ticket id from both formats', async () => {
    const v1 = await signBarcode(TICKET, OWNER, SECRET);
    const v2 = await signBarcodeV2({ ticketId: TICKET, ownerId: OWNER, scheme: 'hmac', secret: SECRET });
    expect(extractTicketIdFromAny(v1)).toBe(TICKET);
    expect(extractTicketIdFromAny(v2)).toBe(TICKET);
  });
});
