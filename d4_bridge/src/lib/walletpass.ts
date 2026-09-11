// Exos (Bridge / D4) — Apple Wallet + Google Wallet pass builders.
//
// Scope: this module builds the pass PAYLOADS (the JSON structures + the Apple
// manifest hashes) and exposes a *seam* for the actual cryptographic signing.
// It deliberately does NOT embed signing certificates, because a real,
// installable pass needs credentials that are provisioned OUTSIDE this repo:
//
//   * Apple `.pkpass`  — a Pass Type ID certificate + the Apple WWDR
//     intermediate, used to PKCS#7-sign `manifest.json`. Issued from the Apple
//     Developer portal; the private key never lives in the frontend bundle.
//   * Google Wallet    — a service-account key that RS256-signs the "Save to
//     Google Wallet" JWT. Also a server-side secret.
//   * NFC tap-to-enter — Apple VAS / Google Smart Tap. These require Apple's
//     NFC pass certificate + a CERTIFIED READER; a phone camera cannot read an
//     encrypted wallet-pass NFC tap. The `nfc` block is built here but is inert
//     until those entitlements exist. See buildNfcBlock().
//
// So the honest split is: optical wallet passes (a QR/PDF417 barcode inside the
// pass) work with the phone-camera scanner Exos already has; NFC tap needs
// certified hardware. Both payload shapes are produced here; the caller injects
// a PassSigner when it has the credentials.

/** A detached signer for the Apple `manifest.json` (PKCS#7) — injected by the
 *  server/edge layer that holds the Pass Type certificate. Frontend builds the
 *  manifest; only a trusted context signs it. */
export interface PassSigner {
  /** PKCS#7 detached signature over the exact manifest.json bytes. */
  signManifest(manifestJson: Uint8Array): Promise<Uint8Array>;
}

/** A signer for the Google Wallet "Save" JWT — injected server-side. */
export interface WalletJwtSigner {
  /** RS256-sign the JWT signing input (`${b64url(header)}.${b64url(claims)}`). */
  signJwt(signingInput: string): Promise<string>;
}

export type BarcodeFormat = 'PKBarcodeFormatQR' | 'PKBarcodeFormatPDF417' | 'PKBarcodeFormatAztec';

export interface TicketPassInput {
  /** The signed barcode payload (v1 `T-…` or v2 `T2-…`) shown in the pass. */
  barcode: string;
  ticketId: string;
  eventTitle: string;
  tierName: string;
  attendeeName: string;
  /** Venue / location line. */
  venue?: string;
  /** Event start, ISO-8601 — drives the pass's lock-screen relevance. */
  startsAtIso?: string;
  /** Optional doors time, ISO-8601. */
  doorsAtIso?: string;
  organizationName?: string;
  /** Hex brand colors, e.g. '#0B0B0B'. */
  backgroundColorHex?: string;
  foregroundColorHex?: string;
}

/** Apple-config the caller supplies from provisioned credentials. */
export interface ApplePassConfig {
  passTypeIdentifier: string;
  teamIdentifier: string;
  /** Where an updatable pass polls for refreshes (APNs web service). */
  webServiceURL?: string;
  authenticationToken?: string;
}

// ---------------------------------------------------------------------------
// A caveat encoded in the type system: a wallet pass barcode is effectively
// STATIC between pass updates (APNs pushes are minutes-scale, not 30s). Putting
// a 30s-rotating v2/v1 barcode in a pass loses the anti-screenshot property.
// For the wallet channel, prefer an Ed25519-signed barcode with a real `exp`
// (long bucket window) so it can't be replayed AFTER expiry, and lean on the
// atomic single-use flip at the door for true single-use. This function flags
// the mismatch so a caller can't silently ship a screenshot-forgeable pass.
// ---------------------------------------------------------------------------
export function passBarcodeIsRotating(barcode: string): boolean {
  // Both formats carry a 30s bucket; inside a wallet pass that will be stale by
  // scan time. The caller should mint a wallet-specific longer-lived code.
  return barcode.startsWith('T-') || barcode.startsWith('T2-');
}

function hexToPkColor(hex?: string): string | undefined {
  if (!hex) return undefined;
  const m = /^#?([0-9a-fA-F]{6})$/.exec(hex.trim());
  if (!m) return undefined;
  const n = m[1];
  const r = parseInt(n.slice(0, 2), 16);
  const g = parseInt(n.slice(2, 4), 16);
  const b = parseInt(n.slice(4, 6), 16);
  return `rgb(${r}, ${g}, ${b})`;
}

/**
 * Build the Apple `pass.json` object for an event ticket. The returned object
 * is serialized into the `.pkpass` zip alongside images + the signed manifest.
 */
export function buildApplePassJson(
  input: TicketPassInput,
  config: ApplePassConfig,
  opts: { barcodeFormat?: BarcodeFormat } = {},
): Record<string, unknown> {
  const format = opts.barcodeFormat ?? 'PKBarcodeFormatQR';
  const pass: Record<string, unknown> = {
    formatVersion: 1,
    passTypeIdentifier: config.passTypeIdentifier,
    teamIdentifier: config.teamIdentifier,
    serialNumber: input.ticketId,
    organizationName: input.organizationName ?? 'Exos',
    description: `${input.eventTitle} — ${input.tierName}`,
    // `barcodes` (plural) is the modern field; `barcode` (singular) is kept for
    // iOS < 9 compatibility. Both carry the same message.
    barcodes: [
      {
        format,
        message: input.barcode,
        messageEncoding: 'iso-8859-1',
        altText: input.ticketId.slice(0, 8),
      },
    ],
    barcode: {
      format,
      message: input.barcode,
      messageEncoding: 'iso-8859-1',
      altText: input.ticketId.slice(0, 8),
    },
    eventTicket: {
      primaryFields: [{ key: 'event', label: 'EVENT', value: input.eventTitle }],
      secondaryFields: [
        { key: 'name', label: 'ATTENDEE', value: input.attendeeName },
        { key: 'tier', label: 'TYPE', value: input.tierName },
      ],
      auxiliaryFields: input.venue ? [{ key: 'venue', label: 'VENUE', value: input.venue }] : [],
      backFields: [{ key: 'ticketId', label: 'Ticket ID', value: input.ticketId }],
    },
  };

  if (input.startsAtIso) pass.relevantDate = input.startsAtIso;
  const bg = hexToPkColor(input.backgroundColorHex);
  const fg = hexToPkColor(input.foregroundColorHex);
  if (bg) pass.backgroundColor = bg;
  if (fg) pass.foregroundColor = fg;
  if (config.webServiceURL && config.authenticationToken) {
    pass.webServiceURL = config.webServiceURL;
    pass.authenticationToken = config.authenticationToken;
  }
  return pass;
}

/**
 * Build the NFC block for a tap-to-enter pass. GATED: Apple only honors this
 * for passes signed with an NFC-enabled Pass Type certificate, and it is read
 * by CERTIFIED terminals — never by a plain phone. `encryptionPublicKey` is the
 * base64 (DER/SPIP) key the reader uses. Returned for completeness so the pass
 * builder can include it when the entitlement + reader exist.
 */
export function buildNfcBlock(message: string, encryptionPublicKeyB64: string): Record<string, unknown> {
  return {
    message,
    encryptionPublicKey: encryptionPublicKeyB64,
    // Requires the com.apple.developer.pass-type-identifiers NFC entitlement.
    requiresAuthentication: true,
  };
}

/** SHA-1 hex digest (Apple's manifest uses SHA-1 per file). */
export async function sha1Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-1', bytes));
  let hex = '';
  for (let i = 0; i < digest.length; i++) hex += digest[i].toString(16).padStart(2, '0');
  return hex;
}

/**
 * Build the Apple `manifest.json` (filename → SHA-1) for a set of pass files.
 * The manifest is what the PassSigner signs; tampering with any file changes
 * its hash and invalidates the signature.
 */
export async function buildApplePassManifest(
  files: Record<string, Uint8Array>,
): Promise<{ manifest: Record<string, string>; manifestJson: Uint8Array }> {
  const manifest: Record<string, string> = {};
  for (const [name, bytes] of Object.entries(files)) {
    manifest[name] = await sha1Hex(bytes);
  }
  const manifestJson = new TextEncoder().encode(JSON.stringify(manifest));
  return { manifest, manifestJson };
}

/**
 * Assemble the file set for a `.pkpass` (minus the images the caller adds), then
 * hash + sign the manifest via the injected signer. Returns the files ready to
 * zip. Throws only if the signer throws — the payload building never needs
 * credentials.
 */
export async function buildSignedPkpassFiles(
  passJson: Record<string, unknown>,
  extraFiles: Record<string, Uint8Array>,
  signer: PassSigner,
): Promise<Record<string, Uint8Array>> {
  const passBytes = new TextEncoder().encode(JSON.stringify(passJson));
  const files: Record<string, Uint8Array> = { 'pass.json': passBytes, ...extraFiles };
  const { manifestJson } = await buildApplePassManifest(files);
  const signature = await signer.signManifest(manifestJson);
  return { ...files, 'manifest.json': manifestJson, signature };
}

// ---------------------------------------------------------------------------
// Google Wallet
// ---------------------------------------------------------------------------

export interface GoogleWalletConfig {
  issuerId: string;
  /** The service-account email; becomes the JWT `iss`. */
  issuerEmail: string;
  /** e.g. `${issuerId}.exos_event_ticket` */
  classId: string;
  origins?: string[];
}

function b64urlJson(obj: unknown): string {
  const json = JSON.stringify(obj);
  let bin = '';
  const bytes = new TextEncoder().encode(json);
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Build the Google Wallet EventTicketObject carrying the barcode. */
export function buildGoogleWalletObject(
  input: TicketPassInput,
  config: GoogleWalletConfig,
): Record<string, unknown> {
  return {
    id: `${config.issuerId}.${input.ticketId}`,
    classId: config.classId,
    state: 'ACTIVE',
    barcode: { type: 'QR_CODE', value: input.barcode, alternateText: input.ticketId.slice(0, 8) },
    ticketHolderName: input.attendeeName,
    ticketType: { defaultValue: { language: 'en-US', value: input.tierName } },
    eventName: { defaultValue: { language: 'en-US', value: input.eventTitle } },
    venue: input.venue
      ? { name: { defaultValue: { language: 'en-US', value: input.venue } } }
      : undefined,
    dateTime: input.startsAtIso
      ? { start: input.startsAtIso, doorsOpen: input.doorsAtIso }
      : undefined,
  };
}

/**
 * Build the UNSIGNED "Save to Google Wallet" JWT signing input (header +
 * claims). The caller RS256-signs it with the service-account key via the
 * injected WalletJwtSigner and appends the signature. We never hold that key.
 */
export function buildGoogleWalletJwtInput(
  ticketObject: Record<string, unknown>,
  config: GoogleWalletConfig,
): { signingInput: string; header: Record<string, unknown>; claims: Record<string, unknown> } {
  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: config.issuerEmail,
    aud: 'google',
    typ: 'savetowallet',
    origins: config.origins ?? [],
    payload: { eventTicketObjects: [ticketObject] },
  };
  return { signingInput: `${b64urlJson(header)}.${b64urlJson(claims)}`, header, claims };
}

/** Build the full "Save to Google Wallet" link once the JWT is signed. */
export async function buildGoogleWalletSaveUrl(
  ticketObject: Record<string, unknown>,
  config: GoogleWalletConfig,
  signer: WalletJwtSigner,
): Promise<string> {
  const { signingInput } = buildGoogleWalletJwtInput(ticketObject, config);
  const signature = await signer.signJwt(signingInput);
  return `https://pay.google.com/gp/v/save/${signingInput}.${signature}`;
}
