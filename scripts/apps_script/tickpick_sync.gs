/**
 * ============================================================================
 * TICKPICK APPS SCRIPT — DUAL-FUNCTION
 * ============================================================================
 *
 * Two independent flows, one credentials store, one set of namespaced
 * helpers (`tp*` prefix to avoid colliding with the SeatGeek checker and
 * lifecycle matcher in the same Apps Script project).
 *
 *   FLOW 1 — checkTickPickOrderStatus() — UNCHANGED from prior v2.
 *     Email-triggered. Walks PEDDLING SALE RECEIVED threads in Inbox,
 *     extracts order IDs, polls /1.0/orders/{id}/details, and labels +
 *     archives based on order_status / fulfillment_date / event_status.
 *
 *   FLOW 2 — syncTickPickToSupabase() — NEW.
 *     Time-triggered (every 30 min). Hits /1.0/orders?status=unfulfilled,
 *     POSTs the result to Supabase RPC
 *     `public.tickpick_orders_ingest_from_apps_script` for upsert into
 *     `public.tickpick_orders`. Closes the gap left by the Supabase-side
 *     pg_net pull (which returns 401 because TickPick allowlists partner
 *     egress IPs and Supabase's AWS range isn't on it; Apps Script's
 *     Google IPs are).
 *
 * Required script properties (set once via setTickPickCredentials):
 *   TICKPICK_API_TOKEN       — Bearer JWT used by BOTH flows
 *   SUPABASE_PROJECT_URL     — https://hzrizjeaxlqcxfrtczpq.supabase.co
 *   SUPABASE_ANON_KEY        — public anon JWT for PostgREST (Flow 2 only)
 *   APPSCRIPT_INGEST_SECRET  — shared secret for the ingest RPC (Flow 2 only)
 *
 * Triggers (install via the two installers below):
 *   - checkTickPickOrderStatus  : your existing trigger (probably onChange
 *                                 or time-based; left untouched).
 *   - syncTickPickToSupabase    : installSupabaseSyncTrigger() → every 30 min.
 *
 * ============================================================================
 */

/* ─────────────────────────────────────────────────────────────────────────
 * CREDENTIAL SETUP — run ONCE, then delete the literal values from this
 * function so they don't sit in source.
 * ───────────────────────────────────────────────────────────────────────── */

function setTickPickCredentials() {
  // Run once. Replace placeholders with the real values, run, then DELETE
  // the literals from this function body before committing back.
  const literals = {
    'TICKPICK_API_TOKEN'      : 'PASTE_TICKPICK_BEARER_TOKEN_HERE',
    'SUPABASE_PROJECT_URL'    : 'https://hzrizjeaxlqcxfrtczpq.supabase.co',
    'SUPABASE_ANON_KEY'       : 'PASTE_SUPABASE_ANON_KEY_HERE',
    'APPSCRIPT_INGEST_SECRET' : 'PASTE_APPSCRIPT_INGEST_SECRET_HERE'
  };

  // Guard against accidental re-run with placeholders intact
  const unresolved = Object.keys(literals).filter(k => /^PASTE_/.test(literals[k]));
  if (unresolved.length > 0) {
    throw new Error('Replace placeholders before running: ' + unresolved.join(', '));
  }

  PropertiesService.getScriptProperties().setProperties(literals, false);
  console.log('Credentials stored: ' + Object.keys(literals).join(', '));
  console.log('Next: run installSupabaseSyncTrigger() to enable the 30-min sync.');
}

/* ─────────────────────────────────────────────────────────────────────────
 * FLOW 1 — Email-triggered status checker (unchanged behavior)
 * ───────────────────────────────────────────────────────────────────────── */

function checkTickPickOrderStatus() {
  // 🛑 TEST MODE SWITCH
  // Set to false when you are ready for it to actually move emails!
  const TEST_MODE = false;

  // Set to true to dump full JSON (diagnostic). Leave off for normal runs.
  const DEBUG_DUMP = false;

  const scriptProperties = PropertiesService.getScriptProperties();
  let API_TOKEN = scriptProperties.getProperty('TICKPICK_API_TOKEN');

  if (!API_TOKEN) {
    console.error("🚨 Missing API credentials. Please run setTickPickCredentials() first.");
    return;
  }

  API_TOKEN = API_TOKEN.trim();

  const labelFilled   = "Filled Sent/Filled-TickPick";  // nested under "Filled Sent" (with space)
  const labelCanceled = "ISSUE/Cancelled";              // nested under "ISSUE" (all caps)
  const labelIssue    = "ISSUE";

  console.log(`--- STARTING TICKPICK API CHECK ${TEST_MODE ? "(TEST MODE ENABLED)" : ""} ---`);

  const query = 'label:*TP -label:"Filled Sent/Filled-TickPick" -label:"Filled Sent" subject:"PEDDLING SALE RECEIVED" label:inbox';
  const threads = GmailApp.search(query, 0, 20);

  if (threads.length === 0) {
    console.log("No active TickPick orders found in Inbox. Exiting.");
    return;
  }

  threads.forEach(thread => {
    const msg = thread.getMessages()[0];
    const body = msg.getPlainBody();

    // Extract order ID — try multiple common patterns
    let orderId = null;
    const patterns = [
      /Site Order\s*#\s*([a-zA-Z0-9]+)/i,
      /Order\s*Number\s*:?\s*([a-zA-Z0-9]+)/i,
      /Order\s*#\s*([a-zA-Z0-9]+)/i,
      /TickPick\s*Order\s*:?\s*([a-zA-Z0-9]+)/i
    ];
    for (const p of patterns) {
      const m = body.match(p);
      if (m) { orderId = m[1].trim(); break; }
    }

    if (!orderId) {
      console.log("-> Could not extract a TickPick Order # from the email body.");
      return;
    }

    console.log(`Checking API for Order ID: ${orderId}`);

    try {
      const url = `https://api.tickpick.com/1.0/orders/${orderId}/details`;
      const options = {
        method: 'get',
        headers: {
          'Authorization': `Bearer ${API_TOKEN}`,
          'Accept': 'application/json'
        },
        muteHttpExceptions: true
      };

      const response = UrlFetchApp.fetch(url, options);
      const responseCode = response.getResponseCode();
      const responseText = response.getContentText();

      if (responseCode === 200) {
        const json = JSON.parse(responseText);

        if (DEBUG_DUMP) {
          console.log(`-> Keys: ${Object.keys(json).join(", ")}`);
          console.log(`-> Body: ${JSON.stringify(json).substring(0, 1500)}`);
        }

        const orderStatus      = json.order_status;       // e.g. "COMPLETED"
        const fulfillmentDate  = json.fulfillment_date;    // present ⇒ transferred
        const eventStatus      = json.status;              // "Scheduled" | "Rescheduled" | "Canceled"

        console.log(`-> ${orderId}: order_status=${orderStatus}, fulfillment_date=${fulfillmentDate || "none"}, event_status=${eventStatus}`);

        // ===== BRANCH 1: EVENT CANCELED =====
        // Check this BEFORE completion — canceled orders are also order_status=COMPLETED,
        // so Canceled must win. Apply label + mark read, but do NOT archive (needs review).
        if (eventStatus && String(eventStatus).toLowerCase() === "canceled") {
          if (TEST_MODE) {
            console.log(`🧪 [TEST MODE]: Would apply [${labelCanceled}] to ${orderId} and mark read. (event canceled)`);
          } else {
            console.log(`-> Order ${orderId} event CANCELED. Applying [${labelCanceled}], marking read.`);
            tpApplyLabel(thread, labelCanceled);
            thread.markRead();
          }
          return;
        }

        // ===== BRANCH 2: ORDER COMPLETED =====
        // order_status=COMPLETED is the definitive "this order is done" signal from TickPick,
        // whether or not fulfillment_date populated.
        if (orderStatus && String(orderStatus).toUpperCase() === "COMPLETED") {
          const fulfillmentNote = fulfillmentDate ? `fulfilled ${fulfillmentDate}` : "no fulfillment_date";
          if (TEST_MODE) {
            console.log(`🧪 [TEST MODE]: Would mark ${orderId} as FILLED (${fulfillmentNote}).`);
            console.log(`🧪 [TEST MODE]: Would apply [${labelFilled}], strip triage, mark read, archive.`);
          } else {
            console.log(`-> Order ${orderId} COMPLETED (${fulfillmentNote}). Tagging, marking read, archiving.`);
            tpApplyLabel(thread, labelFilled);
            tpRemoveLabel(thread, "A_Today");
            tpRemoveLabel(thread, "A_Tomorrow");
            tpRemoveLabel(thread, "A_Soon");
            thread.markRead();
            thread.moveToArchive();
          }
          return;
        }

        // ===== BRANCH 3: EVERYTHING ELSE =====
        // CONFIRMED, pending, or unexpected states — leave alone.
        console.log(`-> Order ${orderId} not yet completed (order_status: ${orderStatus}, event: ${eventStatus}). Doing nothing.`);
      }
      else if (responseCode === 404) {
        console.log(`-> 404 for ${orderId}. Tagging as Issue!`);
        if (TEST_MODE) {
          console.log(`🧪 [TEST MODE]: Would apply [${labelIssue}] to Order ${orderId}.`);
        } else {
          tpApplyLabel(thread, labelIssue);
        }
      }
      else if (responseCode === 401 || responseCode === 403) {
        console.log(`-> Auth failure (${responseCode}) for ${orderId}. Check TICKPICK_API_TOKEN. Halting.`);
        throw new Error("Auth failure — halting run."); // bail out of forEach
      }
      else {
        console.log(`-> API Request failed for ${orderId} with code: ${responseCode}. Response: ${responseText}`);
      }
    } catch (e) {
      console.log(`-> Error for order ${orderId}: ${e.message}`);
      if (e.message.indexOf("Auth failure") !== -1) throw e; // propagate to stop run
    }
  });

  console.log("--- FINISHED TICKPICK API CHECK ---");
}

/* ─────────────────────────────────────────────────────────────────────────
 * FLOW 2 — Bulk TickPick → Supabase sync (NEW)
 *
 * Pulls /1.0/orders?status=unfulfilled, POSTs to the Supabase RPC
 * tickpick_orders_ingest_from_apps_script for upsert into tickpick_orders.
 * Idempotent: re-running with the same orders updates last_seen_at.
 *
 * Use installSupabaseSyncTrigger() to install a 30-min time trigger;
 * use uninstallSupabaseSyncTrigger() to remove it.
 * ───────────────────────────────────────────────────────────────────────── */

function syncTickPickToSupabase() {
  const TEST_MODE = false;
  const DEBUG_DUMP = false;

  const props = PropertiesService.getScriptProperties();
  const TP_TOKEN  = (props.getProperty('TICKPICK_API_TOKEN')      || '').trim();
  const SB_URL    = (props.getProperty('SUPABASE_PROJECT_URL')    || '').trim();
  const SB_ANON   = (props.getProperty('SUPABASE_ANON_KEY')       || '').trim();
  const INGEST_SK = (props.getProperty('APPSCRIPT_INGEST_SECRET') || '').trim();

  if (!TP_TOKEN || !SB_URL || !SB_ANON || !INGEST_SK) {
    const missing = ['TICKPICK_API_TOKEN','SUPABASE_PROJECT_URL','SUPABASE_ANON_KEY','APPSCRIPT_INGEST_SECRET']
      .filter(k => !(props.getProperty(k) || '').trim());
    throw new Error('Missing script properties: ' + missing.join(', ') + '. Run setTickPickCredentials() first.');
  }

  console.log(`--- STARTING TICKPICK→SUPABASE SYNC ${TEST_MODE ? "(TEST MODE)" : ""} ---`);

  // 1. Pull from TickPick (Apps Script egress IS allowlisted by TickPick).
  const orders = tpFetchOrdersList_(TP_TOKEN, 'unfulfilled');
  console.log(`TickPick /1.0/orders?status=unfulfilled → ${orders.length} orders.`);

  if (DEBUG_DUMP && orders.length > 0) {
    console.log('First order keys: ' + Object.keys(orders[0]).join(', '));
    console.log('First order body: ' + JSON.stringify(orders[0]).substring(0, 1500));
  }

  if (orders.length === 0) {
    console.log('Nothing to sync. Exiting cleanly.');
    return;
  }

  if (TEST_MODE) {
    console.log(`🧪 [TEST MODE]: Would POST ${orders.length} orders to Supabase RPC.`);
    return;
  }

  // 2. Push to Supabase RPC in chunks (keep request body well under 5MB).
  const CHUNK = 250;
  const totals = { inserted: 0, updated: 0, skipped: 0, batches: 0 };

  for (let i = 0; i < orders.length; i += CHUNK) {
    const batch = orders.slice(i, i + CHUNK);
    const result = tpPostIngestBatch_(SB_URL, SB_ANON, INGEST_SK, batch);
    totals.inserted += result.inserted;
    totals.updated  += result.updated;
    totals.skipped  += result.skipped;
    totals.batches  += 1;
    console.log(`Batch ${totals.batches} (${batch.length} orders): ` +
                `inserted=${result.inserted} updated=${result.updated} skipped=${result.skipped}`);
  }

  console.log(`SYNC COMPLETE — batches=${totals.batches}, ` +
              `total_inserted=${totals.inserted}, ` +
              `total_updated=${totals.updated}, ` +
              `total_skipped=${totals.skipped}`);
  console.log('--- FINISHED TICKPICK→SUPABASE SYNC ---');
}

/* ─────────────────────────────────────────────────────────────────────────
 * TRIGGER INSTALLERS (Flow 2 only — Flow 1's trigger is left untouched)
 * ───────────────────────────────────────────────────────────────────────── */

function installSupabaseSyncTrigger() {
  // Idempotent: remove any existing triggers for syncTickPickToSupabase first.
  let removed = 0;
  ScriptApp.getProjectTriggers().forEach(t => {
    if (t.getHandlerFunction() === 'syncTickPickToSupabase') {
      ScriptApp.deleteTrigger(t);
      removed++;
    }
  });
  ScriptApp.newTrigger('syncTickPickToSupabase').timeBased().everyMinutes(30).create();
  console.log(`Trigger installed: syncTickPickToSupabase every 30 min (removed ${removed} prior).`);
}

function uninstallSupabaseSyncTrigger() {
  let deleted = 0;
  ScriptApp.getProjectTriggers().forEach(t => {
    if (t.getHandlerFunction() === 'syncTickPickToSupabase') {
      ScriptApp.deleteTrigger(t);
      deleted++;
    }
  });
  console.log(`Removed ${deleted} trigger(s).`);
}

/* ─────────────────────────────────────────────────────────────────────────
 * FLOW 2 INTERNAL HELPERS (tp-prefixed for namespace hygiene)
 * ───────────────────────────────────────────────────────────────────────── */

/** GET https://api.tickpick.com/1.0/orders?status=<status> with Bearer auth. */
function tpFetchOrdersList_(token, status) {
  const url = 'https://api.tickpick.com/1.0/orders?status=' + encodeURIComponent(status);
  const resp = UrlFetchApp.fetch(url, {
    method: 'get',
    headers: {
      'Authorization': 'Bearer ' + token,
      'Accept': 'application/json'
    },
    muteHttpExceptions: true
  });
  const code = resp.getResponseCode();
  if (code !== 200) {
    const body = resp.getContentText() || '';
    throw new Error(`TickPick list fetch failed: HTTP ${code} — ${body.substring(0, 400)}`);
  }
  const json = JSON.parse(resp.getContentText());
  // /1.0/orders returns a top-level array; some shapes wrap as {orders:[...]}
  if (Array.isArray(json)) return json;
  if (json && Array.isArray(json.orders)) return json.orders;
  console.log('Unexpected TickPick shape: ' + JSON.stringify(json).substring(0, 200));
  return [];
}

/** POST one chunk to the Supabase RPC. Returns {inserted, updated, skipped}. */
function tpPostIngestBatch_(sbUrl, sbAnon, sharedSecret, ordersArr) {
  const url = sbUrl + '/rest/v1/rpc/tickpick_orders_ingest_from_apps_script';
  const payload = {
    p_orders        : ordersArr,
    p_shared_secret : sharedSecret
  };
  const resp = UrlFetchApp.fetch(url, {
    method: 'post',
    headers: {
      'apikey'        : sbAnon,
      'Authorization' : 'Bearer ' + sbAnon,
      'Content-Type'  : 'application/json',
      'Prefer'        : 'return=representation'
    },
    payload: JSON.stringify(payload),
    muteHttpExceptions: true
  });
  const code = resp.getResponseCode();
  const body = resp.getContentText();
  if (code !== 200) {
    throw new Error(`Supabase RPC failed: HTTP ${code} — ${body.substring(0, 600)}`);
  }
  let parsed;
  try { parsed = JSON.parse(body); } catch (e) { parsed = []; }
  const row = (Array.isArray(parsed) && parsed.length > 0) ? parsed[0] : {};
  return {
    inserted : Number(row.inserted) || 0,
    updated  : Number(row.updated)  || 0,
    skipped  : Number(row.skipped)  || 0
  };
}

/* ─────────────────────────────────────────────────────────────────────────
 * FLOW 1 LABEL HELPERS (tp-prefixed for namespace hygiene)
 * UNCHANGED from prior code — kept here so the file is self-contained.
 * ───────────────────────────────────────────────────────────────────────── */

// Per-execution label cache — avoids re-fetching getUserLabels() multiple times.
let _tpLabelCache = null;

function tpGetLabel(name) {
  if (!name) return null;

  // First try direct lookup (fast path)
  let label = null;
  try {
    label = GmailApp.getUserLabelByName(name);
    if (label) return label;
  } catch (e) {
    // fall through to iteration
  }

  // Fallback: iterate all user labels. Nested labels sometimes aren't found
  // by getUserLabelByName() even though they exist. This is a known Apps Script quirk.
  try {
    if (!_tpLabelCache) {
      _tpLabelCache = GmailApp.getUserLabels();
    }
    for (let i = 0; i < _tpLabelCache.length; i++) {
      if (_tpLabelCache[i].getName() === name) return _tpLabelCache[i];
    }
  } catch (e) {
    console.log(`tpGetLabel("${name}"): iteration threw: ${e.message}`);
  }

  return null;
}

function tpApplyLabel(thread, name) {
  if (!name) return;
  let label = tpGetLabel(name);

  // Create if truly missing
  if (!label) {
    try {
      label = GmailApp.createLabel(name);
      _tpLabelCache = null; // invalidate cache after create
      console.log(`tpApplyLabel("${name}"): created new label.`);
    } catch (e) {
      console.log(`tpApplyLabel("${name}"): createLabel threw: ${e.message}`);
      // Concurrent create may have won the race — clear cache + retry lookup
      _tpLabelCache = null;
      Utilities.sleep(500);
      label = tpGetLabel(name);
    }
  }

  if (!label) {
    console.log(`⚠️ tpApplyLabel("${name}") — could not get or create label. Run tpDiagnoseLabels() to see what Gmail actually has.`);
    return;
  }

  try {
    thread.addLabel(label);
    Utilities.sleep(200);
    const applied = thread.getLabels().map(l => l.getName());
    if (applied.indexOf(name) === -1) {
      console.log(`⚠️ tpApplyLabel("${name}") — addLabel returned but label not found on thread. Labels present: [${applied.join(", ")}]`);
    }
  } catch (e) {
    console.log(`tpApplyLabel("${name}") addLabel threw: ${e.message}`);
  }
}

function tpRemoveLabel(thread, name) {
  if (!name) return;
  try {
    const label = tpGetLabel(name);
    if (label) thread.removeLabel(label);
  } catch (e) {
    console.log(`tpRemoveLabel("${name}") failed: ${e.message}`);
  }
}

/* ─────────────────────────────────────────────────────────────────────────
 * DIAGNOSTICS — run manually from the editor as needed
 * ───────────────────────────────────────────────────────────────────────── */

/**
 * 🔎 Confirm all 4 script properties are set and report char counts (NOT values).
 *    Also list any active triggers and which handler they fire.
 */
function tpDiagnoseSetup() {
  const props = PropertiesService.getScriptProperties().getProperties();
  ['TICKPICK_API_TOKEN','SUPABASE_PROJECT_URL','SUPABASE_ANON_KEY','APPSCRIPT_INGEST_SECRET'].forEach(k => {
    const v = props[k] || '';
    console.log(`${k}: ${v ? `SET (${v.length} chars)` : '!! MISSING'}`);
  });

  console.log('--- TRIGGERS ---');
  const trigs = ScriptApp.getProjectTriggers();
  if (trigs.length === 0) {
    console.log('(no triggers installed)');
  } else {
    trigs.forEach(t => {
      console.log(`  ${t.getHandlerFunction()} — ${t.getEventType()} (${t.getTriggerSource()})`);
    });
  }
}

/**
 * 🔎 Push a single fake order through the Supabase RPC to verify wiring.
 *    Expected log: "probe result: inserted=1 updated=0 skipped=0".
 *    Leaves one row with tp_order_id starting "APPS_SCRIPT_PROBE_" — clean up
 *    via the SQL in the trailing log line.
 */
function tpProbeIngestPath() {
  const props = PropertiesService.getScriptProperties();
  const SB_URL    = (props.getProperty('SUPABASE_PROJECT_URL')    || '').trim();
  const SB_ANON   = (props.getProperty('SUPABASE_ANON_KEY')       || '').trim();
  const INGEST_SK = (props.getProperty('APPSCRIPT_INGEST_SECRET') || '').trim();
  if (!SB_URL || !SB_ANON || !INGEST_SK) throw new Error('Missing properties — run setTickPickCredentials.');

  const fake = [{
    order_number : 'APPS_SCRIPT_PROBE_' + Date.now(),
    event_name   : 'Apps Script wire probe',
    event_date   : '2026-06-01T19:00:00Z',
    section      : 'TEST',
    row          : 'A',
    status       : 'unfulfilled',
    quantity     : 1,
    total        : 0
  }];
  const result = tpPostIngestBatch_(SB_URL, SB_ANON, INGEST_SK, fake);
  console.log(`probe result: inserted=${result.inserted} updated=${result.updated} skipped=${result.skipped}`);
  console.log('Cleanup via Studio SQL: DELETE FROM public.tickpick_orders WHERE tp_order_id LIKE \'APPS_SCRIPT_PROBE_%\';');
}

/**
 * 🔎 List Gmail labels — useful for verifying the exact name (capitalization
 * + nesting separator) the Flow-1 checker is trying to apply.
 */
function tpDiagnoseLabels() {
  const labels = GmailApp.getUserLabels();
  console.log(`--- ${labels.length} USER LABELS ---`);
  labels.forEach(l => console.log(`"${l.getName()}"`));
  console.log(`--- Filter for relevant labels ---`);
  labels.forEach(l => {
    const n = l.getName().toLowerCase();
    if (n.indexOf("fill") !== -1 || n.indexOf("tickpick") !== -1 ||
        n.indexOf("cancel") !== -1 || n.indexOf("issue") !== -1) {
      console.log(`  relevant: "${l.getName()}"`);
    }
  });
}
