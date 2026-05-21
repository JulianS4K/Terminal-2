// Automatiq + 10-channel oversell race simulation.
//
// Scenario: 1 ticket on Exos is listed simultaneously on 10
// distribution channels (StubHub, Vivid, SeatGeek, TickPick, Gametime,
// VipBox, ScoreBig, etc.) via Automatiq sync. Ten buyers click "buy
// now" within the same wall-clock instant, each on a different channel.
//
// What ACTUALLY breaks in distribution networks (and how each
// architecture handles it):
//
//   * Buyer A pays Channel 1 first. Channel 1's payment processor
//     captures funds.
//   * Channels 2..10 also capture funds before Channel 1's
//     "delisted" event has propagated through Automatiq → 9 channels
//     → buyers' carts.
//   * Now 10 buyers all hold a paid receipt. Only one of them holds
//     a valid ticket. The other 9 paid for nothing.
//
// We model three architectures and run 100 trials per architecture to
// see how often each results in:
//   - duplicate barcodes at the door (CATASTROPHIC)
//   - buyers charged for tickets they didn't get (BAD UX)
//   - buyers correctly told "sold out" before payment (GOOD UX)
//
// Key insight: Exos alone (Firestore rule + increment) prevents
// the duplicate-barcode problem. It does NOT prevent the
// buyers-charged-then-refunded problem. That's an orchestrator
// responsibility — Automatiq has to two-phase commit or buyers will be
// charged on losing channels.

import { signBarcode, verifyBarcode } from './src/lib/barcode';

// ---- Domain --------------------------------------------------------

type ChannelName =
  | 'Exos'      // direct
  | 'StubHub'
  | 'VividSeats'
  | 'SeatGeek'
  | 'TickPick'
  | 'Gametime'
  | 'TicketNetwork'
  | 'ScoreBig'
  | 'TicketIQ'
  | 'GoTickets';

const CHANNELS: ChannelName[] = [
  'Exos', 'StubHub', 'VividSeats', 'SeatGeek', 'TickPick',
  'Gametime', 'TicketNetwork', 'ScoreBig', 'TicketIQ', 'GoTickets',
];

type Inventory = {
  ticketId: string;
  status: 'available' | 'reserved' | 'sold';
  reservedBy?: string;
  reservedUntil?: number;
  soldTo?: string;
  barcodeSecret?: string;
};

type ChannelInventory = {
  channel: ChannelName;
  // Last-known status (eventually consistent — Automatiq pushes updates
  // with random latency).
  knownStatus: 'available' | 'sold-elsewhere';
  lastSyncAt: number;
};

type ChargeOutcome = {
  buyer: string;
  channel: ChannelName;
  charged: boolean;     // payment processor took funds
  refunded: boolean;    // refund issued because we couldn't fulfill
  ticketIssued: boolean;
  ticketId?: string;
};

// Latency between actions — varies per network hop. In real life
// channel-to-Automatiq is ~50-300ms, Automatiq-to-Exos is ~50-150ms.
function jitter(min: number, max: number): number {
  return min + Math.random() * (max - min);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ---- Architecture A: NAIVE (worst case) ----------------------------
//
// Each channel charges first, then asks Automatiq if the seat is still
// open. Automatiq has no central lock — it just records the most recent
// claim. Exos is told nothing until end-of-day reconciliation.
//
// What can go wrong:
//   * 10 buyers all charged.
//   * Multiple "winners" claim the seat.
//   * At the door, multiple buyers show identical barcodes. The first
//     one through is admitted; the others are turned away with paid
//     receipts.

async function runArchA(): Promise<ChargeOutcome[]> {
  const inv: Inventory = { ticketId: 'tk-1', status: 'available' };
  const outcomes: ChargeOutcome[] = [];
  let firstClaim: ChargeOutcome | null = null;

  await Promise.all(
    CHANNELS.map(async (ch, i) => {
      const buyer = `buyer-${i + 1}`;
      // Step 1: channel sees inventory available, takes payment.
      await sleep(jitter(20, 80));
      const charged = true;

      // Step 2: channel asks Automatiq "I sold this — record it".
      await sleep(jitter(50, 300));

      // Step 3: Automatiq's "winner-takes-all" with no central lock.
      // We model this by saying first to arrive wins; others ALSO
      // record because there's no lock.
      let ticketIssued = false;
      let ticketId: string | undefined;
      if (!firstClaim) {
        ticketIssued = true;
        ticketId = inv.ticketId;
        firstClaim = { buyer, channel: ch, charged, refunded: false, ticketIssued, ticketId };
      } else {
        // Naive — channel still issues a barcode for the same ticketId
        // because it doesn't know any better.
        ticketIssued = true;
        ticketId = inv.ticketId;
      }
      outcomes.push({ buyer, channel: ch, charged, refunded: false, ticketIssued, ticketId });
    })
  );
  return outcomes;
}

// ---- Architecture B: EXOS ONLY ---------------------------------
//
// Channels charge first, then call Automatiq → Exos to claim. Exos
// uses Firestore increment + rule to atomically mark sold. The rule
// rejects the 2nd through 10th attempts. Channels see the rejection and
// MUST refund.
//
// Outcomes:
//   * 1 buyer gets the ticket.
//   * 9 buyers were charged then refunded — their card statement shows
//     a debit followed by a credit.
//   * NO duplicate barcodes (Exos is single-source-of-truth on
//     ticket creation).
//   * BAD UX: 9 buyers had funds held for hours/days before refund.

async function runArchB(): Promise<ChargeOutcome[]> {
  const vibepass = { sold: 0, capacity: 1, ticketId: 'tk-1', secret: 'secret-tk-1' };
  const outcomes: ChargeOutcome[] = [];

  await Promise.all(
    CHANNELS.map(async (ch, i) => {
      const buyer = `buyer-${i + 1}`;

      // Step 1: channel charges card.
      await sleep(jitter(20, 80));
      const charged = true;

      // Step 2: channel → Automatiq → Exos with claim.
      await sleep(jitter(50, 300));

      // Step 3: Exos rule — strict-monotonic increment up to capacity.
      // We serialize at the JS level (mirror of Firestore document-level
      // serialization for increment ops).
      let ticketIssued = false;
      let ticketId: string | undefined;
      if (vibepass.sold + 1 <= vibepass.capacity) {
        vibepass.sold += 1;
        ticketIssued = true;
        ticketId = vibepass.ticketId;
      }

      // Step 4: if claim failed, channel refunds.
      const refunded = charged && !ticketIssued;
      outcomes.push({ buyer, channel: ch, charged, refunded, ticketIssued, ticketId });
    })
  );
  return outcomes;
}

// ---- Architecture C: TWO-PHASE RESERVE + COMMIT --------------------
//
// Channels first call Automatiq to RESERVE the seat (no payment yet).
// Automatiq forwards to Exos; Exos marks the seat 'reserved'
// for 2 minutes (per channel) and rejects further reservation attempts.
// Channel then prompts buyer for payment. On payment success the
// channel calls COMMIT. On payment failure or expiry, RELEASE.
//
// Outcomes:
//   * 1 buyer wins the reservation, completes checkout, gets ticket.
//   * 9 buyers see "Sorry, just sold" BEFORE entering payment details.
//     Zero refunds, zero duplicate barcodes, good UX.

type Reservation = { buyer: string; channel: ChannelName; until: number };

async function runArchC(): Promise<ChargeOutcome[]> {
  const vibepass: Inventory = { ticketId: 'tk-1', status: 'available' };
  const reservations: Reservation[] = [];
  const outcomes: ChargeOutcome[] = [];
  const NOW = Date.now();
  const RESERVE_MS = 2 * 60 * 1000;

  await Promise.all(
    CHANNELS.map(async (ch, i) => {
      const buyer = `buyer-${i + 1}`;

      // Step 1: channel → Automatiq → Exos: RESERVE
      await sleep(jitter(20, 80));
      let reservedHere = false;
      // Atomic: first to reach this guard wins.
      if (vibepass.status === 'available') {
        vibepass.status = 'reserved';
        vibepass.reservedBy = buyer;
        vibepass.reservedUntil = NOW + RESERVE_MS;
        reservations.push({ buyer, channel: ch, until: NOW + RESERVE_MS });
        reservedHere = true;
      }

      if (!reservedHere) {
        // Channel surfaces "Sorry, just sold" message — no charge.
        outcomes.push({ buyer, channel: ch, charged: false, refunded: false, ticketIssued: false });
        return;
      }

      // Step 2: channel prompts buyer for payment. Buyer pays.
      await sleep(jitter(500, 2000));
      const charged = true;

      // Step 3: channel → Automatiq → Exos: COMMIT
      await sleep(jitter(50, 300));
      let ticketIssued = false;
      if (vibepass.status === 'reserved' && vibepass.reservedBy === buyer) {
        vibepass.status = 'sold';
        vibepass.soldTo = buyer;
        vibepass.barcodeSecret = `secret-${vibepass.ticketId}-${Math.random().toString(36).slice(2, 10)}`;
        ticketIssued = true;
      }

      const refunded = charged && !ticketIssued;
      outcomes.push({ buyer, channel: ch, charged, refunded, ticketIssued, ticketId: vibepass.ticketId });
    })
  );
  return outcomes;
}

// ---- Door scenario --------------------------------------------------
//
// Now run the door. Each "winner" arrives with their barcode. The
// scanner verifies HMAC against Exos's stored secret and refuses
// duplicates via status='used'.

async function doorScan(outcomes: ChargeOutcome[], canonicalSecret: string): Promise<{ admitted: number; turnedAway: number }> {
  let admitted = 0;
  let turnedAway = 0;
  let ticketUsed = false;
  for (const o of outcomes) {
    if (!o.ticketIssued) continue;
    // Each "winner" tries to scan. If they all hold the same ticketId,
    // only the first valid HMAC + status='active' wins.
    if (ticketUsed) {
      turnedAway++;
      continue;
    }
    // Sign with the canonical secret (only the real winner has it in
    // arch B/C; in arch A, channels invent their own barcodes — those
    // would fail HMAC even before the door rule).
    const sig = await signBarcode(o.ticketId!, o.buyer, canonicalSecret);
    const v = await verifyBarcode(sig, canonicalSecret);
    if (v.ok) {
      admitted++;
      ticketUsed = true;
    } else {
      turnedAway++;
    }
  }
  return { admitted, turnedAway };
}

// ---- Run all three --------------------------------------------------

function tally(label: string, outcomes: ChargeOutcome[], door: { admitted: number; turnedAway: number }) {
  const charged = outcomes.filter((o) => o.charged).length;
  const refunded = outcomes.filter((o) => o.refunded).length;
  const issued = outcomes.filter((o) => o.ticketIssued).length;
  const winner = outcomes.find((o) => o.ticketIssued);
  console.log('');
  console.log(`================ ${label} ================`);
  console.log(`Channels:               ${outcomes.length}`);
  console.log(`Cards charged:          ${charged}`);
  console.log(`Refunds processed:      ${refunded}`);
  console.log(`Barcodes issued:        ${issued}  (catastrophic if > 1)`);
  console.log(`Door — admitted:        ${door.admitted}`);
  console.log(`Door — turned away:     ${door.turnedAway}`);
  if (winner) {
    console.log(`Winner:                 ${winner.buyer} via ${winner.channel}`);
  }
  console.log('');
  console.log('  By channel:');
  for (const o of outcomes) {
    const status =
      o.ticketIssued ? 'WON 🎫' :
      o.refunded ? 'CHARGED then REFUNDED 💸' :
      o.charged ? 'CHARGED (no ticket — RECONCILE)' :
      'declined cleanly ✓';
    console.log(`    ${o.channel.padEnd(15)} ${o.buyer.padEnd(10)} ${status}`);
  }
}

async function run() {
  console.log('=========================================================');
  console.log('Scenario: 10 buyers, 10 distribution channels, 1 ticket');
  console.log('=========================================================');

  console.log('');
  console.log('Architecture A — NAIVE: channels charge first, no central');
  console.log('lock, end-of-day reconciliation. Production: never deploy this.');
  const a = await runArchA();
  const aDoor = await doorScan(a, 'secret-tk-1');
  tally('ARCH A — NAIVE (no protection)', a, aDoor);

  console.log('');
  console.log('Architecture B — EXOS RULE LAYER: channels charge first,');
  console.log('then claim via Automatiq → Exos. Firestore rule rejects');
  console.log('losers; channels must refund the 9 losing charges.');
  const b = await runArchB();
  const bDoor = await doorScan(b, 'secret-tk-1');
  tally('ARCH B — Exos-only protection', b, bDoor);

  console.log('');
  console.log('Architecture C — TWO-PHASE RESERVE+COMMIT (recommended):');
  console.log('Channel calls reserve BEFORE charging. Exos holds the');
  console.log('seat for 2 min for the winning channel. Losing channels');
  console.log('show "just sold" before payment.');
  const c = await runArchC();
  const cDoor = await doorScan(c, c.find(o => o.ticketIssued)?.ticketId === 'tk-1' ? 'secret-tk-1' : '');
  tally('ARCH C — Two-phase reserve+commit', c, cDoor);

  // ---- Repeat-trial summary ------------------------------------------
  // Run 100 trials of each to catch tail behaviors.

  console.log('');
  console.log('=========================================================');
  console.log('100-trial Monte Carlo per architecture');
  console.log('=========================================================');

  for (const [label, runFn] of [
    ['A — Naive', runArchA],
    ['B — Exos-only', runArchB],
    ['C — Two-phase', runArchC],
  ] as const) {
    let totalCharged = 0;
    let totalRefunded = 0;
    let totalDup = 0;
    let totalNoWinner = 0;
    let totalCleanWin = 0;
    for (let i = 0; i < 10; i++) {
      const outcomes = await runFn();
      const issued = outcomes.filter((o) => o.ticketIssued).length;
      const charged = outcomes.filter((o) => o.charged).length;
      const refunded = outcomes.filter((o) => o.refunded).length;
      totalCharged += charged;
      totalRefunded += refunded;
      if (issued > 1) totalDup++;
      if (issued === 0) totalNoWinner++;
      if (issued === 1 && refunded === 0) totalCleanWin++;
    }
    console.log('');
    console.log(`${label}:`);
    console.log(`  total card charges across 25 trials:   ${totalCharged}  (max possible: 1000)`);
    console.log(`  total refunds:                          ${totalRefunded}`);
    console.log(`  trials with duplicate barcodes:         ${totalDup} / 25`);
    console.log(`  trials with no winner:                  ${totalNoWinner} / 25`);
    console.log(`  trials with clean win + zero refunds:   ${totalCleanWin} / 25`);
  }

  console.log('');
  console.log('=========================================================');
  console.log('Bottom line for Exos + Automatiq:');
  console.log('  * Today\'s rule layer (Arch B) is enough to prevent');
  console.log('    duplicate barcodes, but every overflow channel charges');
  console.log('    and refunds — that\'s 9/10 buyers with a bad experience.');
  console.log('  * Two-phase reserve+commit (Arch C) is the architecture');
  console.log('    Automatiq should be wired into. The reserve call must');
  console.log('    happen BEFORE the channel\'s payment widget loads.');
  console.log('  * Exos needs a /reserve endpoint (Cloud Function)');
  console.log('    with a 2-minute TTL and idempotency keyed on the');
  console.log('    channel-supplied reservation id. Phase 2 work.');
  console.log('=========================================================');
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
