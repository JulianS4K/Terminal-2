import { describe, it, expect } from 'vitest';
import {
  canonicalManifestBytes,
  verifyRevocationManifest,
  revokedSet,
  buildBloomFilter,
  bloomMayContain,
  bloomParams,
  type RevocationManifest,
} from './offlineManifest';

const MANIFEST: RevocationManifest = {
  eventId: '11111111-2222-3333-4444-555555555555',
  issuedAt: 1_800_000_000_000,
  revoked: ['ccc', 'aaa', 'bbb'],
};

function bytesToB64url(bytes: Uint8Array): string {
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

describe('canonical manifest', () => {
  it('is deterministic regardless of revoked order', () => {
    const a = canonicalManifestBytes(MANIFEST);
    const b = canonicalManifestBytes({ ...MANIFEST, revoked: ['bbb', 'ccc', 'aaa'] });
    expect(new TextDecoder().decode(a)).toBe(new TextDecoder().decode(b));
  });
});

describe('signed manifest verification (ed25519)', () => {
  it('accepts a good signature and rejects a tampered manifest', async () => {
    let pair: CryptoKeyPair;
    try {
      pair = (await crypto.subtle.generateKey({ name: 'Ed25519' } as any, true, [
        'sign',
        'verify',
      ])) as CryptoKeyPair;
    } catch {
      return; // no Ed25519 in this engine — skip
    }
    const bytes = canonicalManifestBytes(MANIFEST);
    const sig = new Uint8Array(await crypto.subtle.sign('Ed25519' as any, pair.privateKey, bytes));
    const signed = { manifest: MANIFEST, signature: bytesToB64url(sig) };

    const good = await verifyRevocationManifest(signed, pair.publicKey);
    expect(good.ok).toBe(true);
    expect(revokedSet(good.manifest!).has('aaa')).toBe(true);

    const tampered = { ...signed, manifest: { ...MANIFEST, revoked: ['aaa'] } };
    const bad = await verifyRevocationManifest(tampered, pair.publicKey);
    expect(bad.ok).toBe(false);
  });
});

describe('bloom filter', () => {
  it('never yields a false negative for members', () => {
    const ids = Array.from({ length: 500 }, (_, i) => `ticket-${i}`);
    const bf = buildBloomFilter(ids, 0.001);
    for (const id of ids) expect(bloomMayContain(bf, id)).toBe(true);
  });

  it('reports clear non-members as absent (bounded false positives)', () => {
    const ids = ['a', 'b', 'c'];
    const bf = buildBloomFilter(ids, 0.001);
    // With 3 items in a filter sized for p=0.001, a specific unrelated key is
    // overwhelmingly absent.
    expect(bloomMayContain(bf, 'definitely-not-present-zzz')).toBe(false);
  });

  it('sizes larger for lower false-positive targets', () => {
    expect(bloomParams(1000, 0.001).m).toBeGreaterThan(bloomParams(1000, 0.05).m);
  });
});
