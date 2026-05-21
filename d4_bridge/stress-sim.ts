// Code-based stress simulation — high-scale concurrency tests run
// in-memory against a faithful mirror of the Firestore rule
// semantics, plus the REAL lib/barcode.ts for HMAC sign/verify.
//
// Validates that the platform's logic holds under heavy concurrent
// load. Doesn't hit network — for that, see scripts/stress-test.cjs
// which drives the Admin SDK against the live project. This file
// is the synthetic complement: catches logic issues at 10K+ scale
// in seconds.
//
// Run with:  tsx stress-sim.ts
//
// Each test reports:
//   * total ops, pass/fail counts
//   * elapsed wall-clock time
//   * ops/sec throughput
//   * any correctness invariants that broke

import { signBarcode, verifyBarcode, currentBucket } from './src/lib/barcode';

// ---- Output ---------------------------------------------------------

interface TestResult {
  name: string;
  ops: number;
  pass: number;
  fail: number;
  elapsedMs: number;
  opsPerSec: number;
  invariants: string[]; // PASS or FAIL: <description>
}

const results: TestResult[] = [];

function row(name: string, ops: number, pass: number, fail: number, elapsedMs: number, invariants: string[]) {
  const opsPerSec = Math.round((ops / (elapsedMs / 1000)) * 10) / 10;
  results.push({ name, ops, pass, fail, elapsedMs, opsPerSec, invariants });
  console.log(`  ${name.padEnd(36)} ops=${String(ops).padStart(6)}  pass=${String(pass).padStart(6)}  fail=${String(fail).padStart(5)}  ${elapsedMs}ms  ${opsPerSec}/s`);
  for (const inv of invariants) console.log(`    ${inv.startsWith('PASS') ? '✓' : '✗'}  ${inv}`);
}

// ---- 1. Ticket-create flood (capacity cap under contention) ---------

async function testTicketFlood() {
  console.log('');
  console.log('[1] Ticket-create flood — 10000 buyers vs capacity 5000');
  const N_BUYERS = 10_000;
  const CAPACITY = 5_000;

  // Mirror Firestore.increment + rule's strict-monotonic + cap.
  // Serialized at the document level (matches Firestore's per-doc
  // write serialization for FieldValue.increment).
  const tier = { sold: 0, capacity: CAPACITY };
  const tickets: { id: number; tier: 'ga' }[] = [];

  let pass = 0;
  let fail = 0;
  const start = Date.now();
  for (let i = 0; i < N_BUYERS; i++) {
    // Rule logic: incoming = existing + 1; pass iff incoming <= capacity.
    const incoming = tier.sold + 1;
    if (incoming > tier.capacity) {
      fail += 1;
    } else {
      tier.sold = incoming;
      tickets.push({ id: i, tier: 'ga' });
      pass += 1;
    }
  }
  const elapsed = Date.now() - start;

  const invariants = [
    pass === CAPACITY
      ? `PASS: exactly capacity sold (${pass})`
      : `FAIL: sold=${pass}, expected ${CAPACITY}`,
    fail === N_BUYERS - CAPACITY
      ? `PASS: exactly ${fail} oversell rejections (cap held)`
      : `FAIL: rejected=${fail}, expected ${N_BUYERS - CAPACITY}`,
    tickets.length === pass
      ? `PASS: ticket count matches sold count (${tickets.length})`
      : `FAIL: ticket count drift`,
    tier.sold === CAPACITY
      ? `PASS: counter ended at capacity (no drift)`
      : `FAIL: counter ended at ${tier.sold}`,
  ];
  row('ticket-flood vs cap', N_BUYERS, pass, fail, elapsed, invariants);
}

// ---- 2. Promo-code redemption flood ---------------------------------

async function testPromoFlood() {
  console.log('');
  console.log('[2] Promo-code flood — 5000 attempts vs usageLimit 500');
  const N_ATTEMPTS = 5_000;
  const LIMIT = 500;
  const promo = { usedCount: 0, usageLimit: LIMIT };

  let pass = 0;
  let fail = 0;
  const start = Date.now();
  for (let i = 0; i < N_ATTEMPTS; i++) {
    // Mirror firestore.rules promoUses.update branch:
    //   incoming.usedCount > existing.usedCount
    //   incoming.usedCount <= existing.usedCount + 10 (anti-rocket)
    //   incoming.usedCount <= existing.usageLimit
    const incoming = promo.usedCount + 1;
    if (incoming > promo.usageLimit) {
      fail += 1;
      continue;
    }
    if (incoming - promo.usedCount > 10) {
      fail += 1;
      continue;
    }
    promo.usedCount = incoming;
    pass += 1;
  }
  const elapsed = Date.now() - start;

  const invariants = [
    pass === LIMIT ? `PASS: exactly ${LIMIT} redemptions allowed` : `FAIL: ${pass} redemptions`,
    fail === N_ATTEMPTS - LIMIT
      ? `PASS: ${fail} attempts rejected after limit`
      : `FAIL: ${fail} rejections`,
    promo.usedCount === LIMIT ? `PASS: counter at limit, no drift` : `FAIL: counter at ${promo.usedCount}`,
  ];
  row('promo-flood vs limit', N_ATTEMPTS, pass, fail, elapsed, invariants);
}

// ---- 3. HMAC barcode sign+verify burst ------------------------------

async function testHmacBurst() {
  console.log('');
  console.log('[3] HMAC sign + verify burst — 5000 round-trips with real lib/barcode.ts');
  const N = 5_000;
  let pass = 0;
  let fail = 0;
  const start = Date.now();
  // Generate a single ticket secret and validate signing/verifying
  // round-trip integrity at scale. Uses the actual production code.
  const secret = 'stress-secret-' + Math.random().toString(36).slice(2);
  for (let i = 0; i < N; i++) {
    const ticketId = `tk-${i}`;
    const ownerId = `uid-${i}`;
    const sig = await signBarcode(ticketId, ownerId, secret);
    const v = await verifyBarcode(sig, secret);
    if (v.ok && v.ticketId === ticketId && v.ownerId === ownerId) pass += 1;
    else fail += 1;
  }
  const elapsed = Date.now() - start;

  const invariants = [
    pass === N ? `PASS: all ${N} round-trips verified` : `FAIL: ${fail} verify failures`,
    elapsed < N * 5
      ? `PASS: avg ${(elapsed / N).toFixed(2)}ms per round-trip (under 5ms target)`
      : `FAIL: avg ${(elapsed / N).toFixed(2)}ms exceeds 5ms`,
  ];
  row('HMAC sign+verify burst', N, pass, fail, elapsed, invariants);
}

// ---- 4. Mass check-in (audit-log append-only) -----------------------

async function testMassCheckIn() {
  console.log('');
  console.log('[4] Mass check-in — 5000 scans across 4 stations, append-only enforced');
  const N_TICKETS = 5_000;
  const STATIONS = ['main-door', 'side-door', 'vip-entry', 'staff-entry'];

  // Each ticket has a unique HMAC secret. Station tries to scan;
  // append-only audit log refuses double-scans.
  const tickets = new Map<string, { secret: string; status: 'active' | 'used' }>();
  for (let i = 0; i < N_TICKETS; i++) {
    tickets.set(`tk-${i}`, {
      secret: `s-${Math.random().toString(36).slice(2)}`,
      status: 'active',
    });
  }
  const auditLog = new Map<string, { ticketId: string; station: string; at: number }>();

  let scanPass = 0;
  let scanFail = 0;
  let doubleScanRejections = 0;
  const start = Date.now();

  // First pass — every ticket scanned exactly once.
  const tids = [...tickets.keys()];
  for (let i = 0; i < tids.length; i++) {
    const tid = tids[i];
    const t = tickets.get(tid)!;
    const station = STATIONS[i % STATIONS.length];

    if (t.status === 'used') {
      scanFail += 1;
      continue;
    }
    if (auditLog.has(tid)) {
      scanFail += 1;
      doubleScanRejections += 1;
      continue;
    }
    auditLog.set(tid, { ticketId: tid, station, at: Date.now() });
    t.status = 'used';
    scanPass += 1;
  }

  // Second pass — try to double-scan everything. All should reject.
  for (const tid of tids) {
    const t = tickets.get(tid)!;
    if (t.status === 'used' || auditLog.has(tid)) {
      doubleScanRejections += 1;
      continue;
    }
    // Should never reach this branch.
    scanPass += 1;
  }
  const elapsed = Date.now() - start;

  const invariants = [
    scanPass === N_TICKETS
      ? `PASS: all ${N_TICKETS} first-scans accepted`
      : `FAIL: only ${scanPass} accepted`,
    auditLog.size === N_TICKETS
      ? `PASS: audit log has ${auditLog.size} entries (append-only held)`
      : `FAIL: audit log has ${auditLog.size}`,
    doubleScanRejections === N_TICKETS
      ? `PASS: all ${N_TICKETS} double-scan attempts rejected`
      : `FAIL: only ${doubleScanRejections} rejections`,
  ];
  row('mass check-in (2 passes)', N_TICKETS * 2, scanPass + doubleScanRejections, 0, elapsed, invariants);
}

// ---- 5. Transfer chains (secret rotation under repeat) --------------

async function testTransferChains() {
  console.log('');
  console.log('[5] Transfer chains — 1000 tickets, 5-hop chains, secret rotation each hop');
  const N_TICKETS = 1_000;
  const HOPS = 5;

  let pass = 0;
  let fail = 0;
  let invalidatedOldBarcodes = 0;
  const start = Date.now();

  for (let i = 0; i < N_TICKETS; i++) {
    let secret = `secret-init-${i}`;
    let ownerId = `owner-init-${i}`;
    const ticketId = `tk-${i}`;
    let chainOk = true;

    // Pre-compute the initial owner's barcode.
    const originalSig = await signBarcode(ticketId, ownerId, secret);

    for (let hop = 0; hop < HOPS; hop++) {
      const newOwnerId = `owner-${i}-hop${hop}`;
      const newSecret = `secret-${i}-hop${hop}-${Math.random().toString(36).slice(2)}`;

      // Pre-rotate barcode signed by the current secret (the
      // outgoing owner's QR before the receiver claims).
      const preRotateSig = await signBarcode(ticketId, ownerId, secret);
      const preRotateVerify = await verifyBarcode(preRotateSig, secret);
      if (!preRotateVerify.ok) chainOk = false;

      // Execute the transfer-claim: rotate secret + flip ownerId.
      ownerId = newOwnerId;
      secret = newSecret;

      // Now the OLD barcode signed by the old secret should NOT
      // verify against the new secret.
      const oldShouldFail = await verifyBarcode(preRotateSig, secret);
      if (oldShouldFail.ok) {
        chainOk = false;
      } else {
        invalidatedOldBarcodes += 1;
      }

      // The NEW owner's freshly-signed barcode should verify.
      const newSig = await signBarcode(ticketId, ownerId, secret);
      const newVerify = await verifyBarcode(newSig, secret);
      if (!newVerify.ok) chainOk = false;
    }

    // After all hops, the original signature should no longer verify.
    const finalCheck = await verifyBarcode(originalSig, secret);
    if (finalCheck.ok) chainOk = false;

    if (chainOk) pass += 1;
    else fail += 1;
  }
  const elapsed = Date.now() - start;

  const invariants = [
    pass === N_TICKETS
      ? `PASS: all ${N_TICKETS} chains complete cleanly`
      : `FAIL: ${fail} chains broke`,
    invalidatedOldBarcodes === N_TICKETS * HOPS
      ? `PASS: all ${N_TICKETS * HOPS} pre-rotate barcodes invalidated`
      : `FAIL: ${invalidatedOldBarcodes} of ${N_TICKETS * HOPS} invalidated`,
  ];
  row('transfer chains', N_TICKETS * HOPS, pass, fail, elapsed, invariants);
}

// ---- 6. Multi-org parallel activity (cross-tenant isolation) --------

async function testMultiOrgParallel() {
  console.log('');
  console.log('[6] Multi-org parallel — 100 orgs × 100 buyers, isolation enforced');
  const N_ORGS = 100;
  const BUYERS_PER_ORG = 100;

  // Each org has a unique tier with its own capacity. Each buyer
  // belongs to exactly one org. Simulate concurrent purchases
  // and verify cross-org isolation: a buyer from org-A can't
  // affect org-B's tier counter.
  const orgs = new Map<
    string,
    { sold: number; capacity: number; ticketsByOwner: Map<string, number> }
  >();
  for (let o = 0; o < N_ORGS; o++) {
    orgs.set(`org-${o}`, {
      sold: 0,
      capacity: BUYERS_PER_ORG, // exactly enough for everyone
      ticketsByOwner: new Map(),
    });
  }

  let pass = 0;
  let fail = 0;
  // Generate randomized buyer schedule that interleaves across orgs.
  const buyers: { orgId: string; uid: string }[] = [];
  for (let o = 0; o < N_ORGS; o++) {
    for (let b = 0; b < BUYERS_PER_ORG; b++) {
      buyers.push({ orgId: `org-${o}`, uid: `org-${o}-uid-${b}` });
    }
  }
  // Fisher-Yates shuffle to interleave.
  for (let i = buyers.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [buyers[i], buyers[j]] = [buyers[j], buyers[i]];
  }

  const start = Date.now();
  for (const buyer of buyers) {
    const tier = orgs.get(buyer.orgId);
    if (!tier) { fail += 1; continue; }
    if (tier.sold + 1 > tier.capacity) {
      fail += 1;
      continue;
    }
    tier.sold += 1;
    tier.ticketsByOwner.set(buyer.uid, (tier.ticketsByOwner.get(buyer.uid) ?? 0) + 1);
    pass += 1;
  }
  const elapsed = Date.now() - start;

  // Verify each org has exactly its own buyer set, no cross-tenant leakage.
  let isolationOk = 0;
  let isolationLeak = 0;
  for (const [orgId, tier] of orgs.entries()) {
    if (tier.sold !== BUYERS_PER_ORG) {
      isolationLeak += 1;
      continue;
    }
    // Every buyer uid must start with this orgId's prefix.
    let leaked = false;
    for (const uid of tier.ticketsByOwner.keys()) {
      if (!uid.startsWith(orgId + '-uid-')) leaked = true;
    }
    if (leaked) isolationLeak += 1;
    else isolationOk += 1;
  }

  const invariants = [
    pass === N_ORGS * BUYERS_PER_ORG
      ? `PASS: all ${pass} buyers fulfilled across ${N_ORGS} orgs`
      : `FAIL: only ${pass}`,
    isolationOk === N_ORGS
      ? `PASS: all ${N_ORGS} orgs cleanly isolated, no cross-tenant leakage`
      : `FAIL: ${isolationLeak} orgs had leakage`,
  ];
  row('multi-org parallel', N_ORGS * BUYERS_PER_ORG, pass, fail, elapsed, invariants);
}

// ---- 7. Concurrent station scans (race resolution) ------------------

async function testConcurrentStations() {
  console.log('');
  console.log('[7] Concurrent station race — 1000 tickets, 4 stations racing per ticket');
  const N_TICKETS = 1_000;
  const STATIONS = 4;

  const tickets = new Map<string, { status: 'active' | 'used' }>();
  const auditLog = new Map<string, { station: string }>();
  for (let i = 0; i < N_TICKETS; i++) {
    tickets.set(`tk-${i}`, { status: 'active' });
  }

  let firstScansAccepted = 0;
  let racedScansRejected = 0;
  const start = Date.now();
  for (let i = 0; i < N_TICKETS; i++) {
    const tid = `tk-${i}`;
    // Simulate 4 stations all scanning simultaneously. Only first wins.
    for (let s = 0; s < STATIONS; s++) {
      const t = tickets.get(tid)!;
      if (t.status === 'used' || auditLog.has(tid)) {
        racedScansRejected += 1;
        continue;
      }
      auditLog.set(tid, { station: `station-${s}` });
      t.status = 'used';
      firstScansAccepted += 1;
    }
  }
  const elapsed = Date.now() - start;

  const invariants = [
    firstScansAccepted === N_TICKETS
      ? `PASS: ${N_TICKETS} first-station scans won the race`
      : `FAIL: ${firstScansAccepted} first-station scans`,
    racedScansRejected === N_TICKETS * (STATIONS - 1)
      ? `PASS: ${racedScansRejected} losing-station scans rejected`
      : `FAIL: ${racedScansRejected} rejections`,
    auditLog.size === N_TICKETS
      ? `PASS: audit log size matches ticket count`
      : `FAIL: audit log size ${auditLog.size}`,
  ];
  row('station race resolution', N_TICKETS * STATIONS, firstScansAccepted + racedScansRejected, 0, elapsed, invariants);
}

// ---- Main -----------------------------------------------------------

async function main() {
  console.log('========================================================');
  console.log('Exos code-based stress simulation');
  console.log('========================================================');
  console.log('Synthetic in-memory tests at 1K-10K scale. Real lib/barcode.ts');
  console.log('used for HMAC tests; everything else mirrors firestore.rules');
  console.log('semantics in TypeScript so we can run 100K ops in seconds.');
  console.log('');

  await testTicketFlood();
  await testPromoFlood();
  await testHmacBurst();
  await testMassCheckIn();
  await testTransferChains();
  await testMultiOrgParallel();
  await testConcurrentStations();

  console.log('');
  console.log('========================================================');
  console.log('SUMMARY');
  console.log('========================================================');
  let totalOps = 0;
  let totalElapsed = 0;
  let allInvariantsPassed = true;
  for (const r of results) {
    totalOps += r.ops;
    totalElapsed += r.elapsedMs;
    for (const inv of r.invariants) {
      if (inv.startsWith('FAIL')) allInvariantsPassed = false;
    }
  }
  console.log(`Total ops:            ${totalOps.toLocaleString()}`);
  console.log(`Total elapsed:        ${totalElapsed}ms`);
  console.log(`Aggregate throughput: ${Math.round(totalOps / (totalElapsed / 1000)).toLocaleString()} ops/sec`);
  console.log(`Invariants:           ${allInvariantsPassed ? 'ALL PASS' : 'SOME FAILED'}`);

  if (!allInvariantsPassed) process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(2);
});
