import { describe, it, expect } from 'vitest';
import {
  buildApplePassJson,
  buildApplePassManifest,
  buildGoogleWalletObject,
  buildGoogleWalletJwtInput,
  passBarcodeIsRotating,
  sha1Hex,
} from './walletpass';

const INPUT = {
  barcode: 'T2-hAAAA',
  ticketId: '11111111-2222-3333-4444-555555555555',
  eventTitle: 'Midnight Show',
  tierName: 'GA',
  attendeeName: 'Alex Doe',
  venue: 'The Basement',
  startsAtIso: '2026-08-01T02:00:00Z',
  backgroundColorHex: '#0B0B0B',
};

const APPLE = { passTypeIdentifier: 'pass.com.exos.ticket', teamIdentifier: 'TEAM123' };
const GOOGLE = {
  issuerId: '3388000000000000000',
  issuerEmail: 'exos@exos.iam.gserviceaccount.com',
  classId: '3388000000000000000.exos_event_ticket',
  origins: ['https://exos.example'],
};

describe('Apple pass', () => {
  it('builds a pass.json carrying the barcode in both fields', () => {
    const pass = buildApplePassJson(INPUT, APPLE);
    expect(pass.formatVersion).toBe(1);
    expect(pass.serialNumber).toBe(INPUT.ticketId);
    const barcodes = pass.barcodes as Array<{ message: string; format: string }>;
    expect(barcodes[0].message).toBe(INPUT.barcode);
    expect(barcodes[0].format).toBe('PKBarcodeFormatQR');
    expect((pass.barcode as any).message).toBe(INPUT.barcode);
    expect(pass.backgroundColor).toBe('rgb(11, 11, 11)');
    expect(pass.relevantDate).toBe(INPUT.startsAtIso);
  });

  it('hashes files into a manifest (SHA-1)', async () => {
    const files = { 'pass.json': new TextEncoder().encode('{"a":1}') };
    const { manifest, manifestJson } = await buildApplePassManifest(files);
    expect(manifest['pass.json']).toMatch(/^[0-9a-f]{40}$/);
    // Manifest hash is stable and matches a direct digest of the same bytes.
    expect(manifest['pass.json']).toBe(await sha1Hex(files['pass.json']));
    expect(manifestJson.length).toBeGreaterThan(0);
  });
});

describe('Google Wallet', () => {
  it('builds an EventTicketObject with a QR barcode', () => {
    const obj = buildGoogleWalletObject(INPUT, GOOGLE);
    expect(obj.id).toBe(`${GOOGLE.issuerId}.${INPUT.ticketId}`);
    expect((obj.barcode as any).type).toBe('QR_CODE');
    expect((obj.barcode as any).value).toBe(INPUT.barcode);
    expect(obj.state).toBe('ACTIVE');
  });

  it('builds a signable JWT input with the object embedded', () => {
    const obj = buildGoogleWalletObject(INPUT, GOOGLE);
    const { signingInput, claims } = buildGoogleWalletJwtInput(obj, GOOGLE);
    expect(signingInput.split('.')).toHaveLength(2);
    expect((claims as any).iss).toBe(GOOGLE.issuerEmail);
    expect((claims as any).payload.eventTicketObjects).toHaveLength(1);
  });
});

describe('rotating-barcode guard', () => {
  it('flags rotating codes that would go stale inside a wallet pass', () => {
    expect(passBarcodeIsRotating('T-abc:def:123:sig')).toBe(true);
    expect(passBarcodeIsRotating('T2-hAAAA')).toBe(true);
    expect(passBarcodeIsRotating('STATIC-LONG-LIVED-CODE')).toBe(false);
  });
});
