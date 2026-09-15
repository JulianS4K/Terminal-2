/**
 * ============================================================================
 * N2S EMAIL → SUPABASE SYNC
 * ============================================================================
 *
 * Gmail-label-triggered ingest for the D7 "Need to Sub" pipeline
 * (docs/d7_n2s_pipeline.md). Some marketplaces only ever tell us an order
 * needs a substitute by email — those orders never reach n2s_items via the
 * CRM poll (n2s_pull_items(), migration 20260910030000) and are therefore
 * invisible to the whole downstream pipeline (map → poll → match → queue →
 * surface). This script closes that gap:
 *
 *   1. Search Gmail for threads carrying one of the configured "needs sub"
 *      labels (N2S_EMAIL_LABELS script property — comma-separated; one label
 *      per marketplace is typical, e.g. "N2S/Vivid, N2S/GoTickets").
 *   2. Best-effort extract order_number/event/venue/section/row/seats/qty/
 *      price from the subject + body. Email templates differ per
 *      marketplace and this project has no live samples to build an exact
 *      parser from — see n2sExtractFields_() for the generic key:value +
 *      pattern scan, and n2sMarketplaceFromLabel_() for the label→
 *      marketplace mapping. TUNE BOTH against your actual templates before
 *      relying on this for anything but order_number, which is the one
 *      field n2s_map_events() truly needs to resolve the order later.
 *   3. POST the batch to Supabase RPC n2s_items_ingest_from_apps_script
 *      (migration 20260915130000) — upserts into n2s_items, which is itself
 *      the "this order needs a sub" tag; n2s_map_events() and the rest of
 *      the six-stage pipeline pick it up on their next tick with no further
 *      code (they already run against every open n2s_items row, CRM- or
 *      email-sourced alike).
 *   4. On a confirmed write, REMOVE the trigger label (so the same thread is
 *      never re-sent) and apply a "N2S/Synced" label + mark read — mirrors
 *      the tag/strip/archive pattern in tickpick_sync.gs Flow 1.
 *
 * This script never buys, cancels, or replies to anything — it only reads
 * Gmail and writes to our own Supabase project (RULE 2, CLAUDE.md).
 *
 * Required script properties (set once via setN2SEmailCredentials):
 *   SUPABASE_PROJECT_URL       — https://hzrizjeaxlqcxfrtczpq.supabase.co
 *   SUPABASE_ANON_KEY          — public anon JWT for PostgREST
 *   APPSCRIPT_N2S_INGEST_SECRET— shared secret for the ingest RPC (vault:
 *                                 APPSCRIPT_N2S_INGEST_SECRET)
 *   N2S_EMAIL_LABELS           — comma-separated Gmail label names to watch,
 *                                 e.g. "N2S/Vivid, N2S/GoTickets, N2S/TickPick"
 *
 * Trigger: installN2SEmailSyncTrigger() → syncN2SEmailsToSupabase every 5 min.
 * ============================================================================
 */

/* ─────────────────────────────────────────────────────────────────────────
 * CREDENTIAL SETUP — run ONCE, then delete the literal values from this
 * function so they don't sit in source.
 * ───────────────────────────────────────────────────────────────────────── */

function setN2SEmailCredentials() {
  const literals = {
    'SUPABASE_PROJECT_URL'        : 'https://hzrizjeaxlqcxfrtczpq.supabase.co',
    'SUPABASE_ANON_KEY'           : 'PASTE_SUPABASE_ANON_KEY_HERE',
    'APPSCRIPT_N2S_INGEST_SECRET' : 'PASTE_APPSCRIPT_N2S_INGEST_SECRET_HERE',
    'N2S_EMAIL_LABELS'            : 'PASTE_COMMA_SEPARATED_LABEL_NAMES_HERE'
  };

  const unresolved = Object.keys(literals).filter(k => /^PASTE_/.test(literals[k]));
  if (unresolved.length > 0) {
    throw new Error('Replace placeholders before running: ' + unresolved.join(', '));
  }

  PropertiesService.getScriptProperties().setProperties(literals, false);
  console.log('Credentials stored: ' + Object.keys(literals).join(', '));
  console.log('Next: run installN2SEmailSyncTrigger() to enable the 5-min sync.');
}

/* ─────────────────────────────────────────────────────────────────────────
 * MAIN SYNC
 * ───────────────────────────────────────────────────────────────────────── */

function syncN2SEmailsToSupabase() {
  const TEST_MODE = false;   // true = parse + log, never POST, never touch labels
  const DEBUG_DUMP = false;

  const props   = PropertiesService.getScriptProperties();
  const SB_URL  = (props.getProperty('SUPABASE_PROJECT_URL')         || '').trim();
  const SB_ANON = (props.getProperty('SUPABASE_ANON_KEY')            || '').trim();
  const SECRET  = (props.getProperty('APPSCRIPT_N2S_INGEST_SECRET')  || '').trim();
  const LABELS  = (props.getProperty('N2S_EMAIL_LABELS')             || '')
                    .split(',').map(s => s.trim()).filter(Boolean);

  if (!SB_URL || !SB_ANON || !SECRET || LABELS.length === 0) {
    const missing = ['SUPABASE_PROJECT_URL','SUPABASE_ANON_KEY','APPSCRIPT_N2S_INGEST_SECRET','N2S_EMAIL_LABELS']
      .filter(k => !(props.getProperty(k) || '').trim());
    throw new Error('Missing script properties: ' + missing.join(', ') + '. Run setN2SEmailCredentials() first.');
  }

  console.log(`--- STARTING N2S EMAIL SYNC ${TEST_MODE ? "(TEST MODE)" : ""} — labels: ${LABELS.join(', ')} ---`);

  const items = [];         // payload rows for Supabase
  const threadsByRef = {};  // email_thread_id -> {thread, label}

  LABELS.forEach(labelName => {
    // -label:"N2S/Synced" stops a thread being re-picked-up if the trigger
    // label is ever re-applied by a human before the sync removes it.
    const query = `label:"${labelName}" -label:"N2S/Synced" label:inbox`;
    const threads = GmailApp.search(query, 0, 50);
    console.log(`Label "${labelName}": ${threads.length} thread(s).`);

    threads.forEach(thread => {
      const threadId = thread.getId();
      if (threadsByRef[threadId]) return; // already queued under another label this run

      const msg = thread.getMessages()[thread.getMessages().length - 1]; // most recent
      const fields = n2sExtractFields_(msg.getSubject(), msg.getPlainBody());

      if (!fields.order_number) {
        console.log(`-> Thread ${threadId} ("${msg.getSubject()}"): no order number found, skipping. Leaving label in place for manual review.`);
        return;
      }

      if (DEBUG_DUMP) {
        console.log(`-> Thread ${threadId} extracted: ${JSON.stringify(fields)}`);
      }

      items.push(Object.assign({
        email_thread_id : threadId,
        email_label     : labelName,
        marketplace     : fields.marketplace || n2sMarketplaceFromLabel_(labelName)
      }, fields));

      threadsByRef[threadId] = { thread: thread, label: labelName };
    });
  });

  if (items.length === 0) {
    console.log('Nothing new to sync. Exiting cleanly.');
    return;
  }

  if (TEST_MODE) {
    console.log(`🧪 [TEST MODE]: Would POST ${items.length} item(s) to Supabase RPC. Labels left untouched.`);
    items.forEach(it => console.log('  ' + JSON.stringify(it)));
    return;
  }

  // 2. Push to Supabase. One request — N2S volume is nowhere near the
  //    TickPick order-book scale that needed chunking.
  const result = n2sPostIngestBatch_(SB_URL, SB_ANON, SECRET, items);
  console.log(`SYNC RESULT — inserted=${result.inserted} updated=${result.updated} skipped=${result.skipped}`);

  // 3. Only now that Supabase has confirmed the write, take the trigger
  //    label off and mark the thread synced. If the POST above throws, we
  //    fall out before this runs and the label stays — so a failed sync is
  //    retried next cycle instead of silently losing the order.
  items.forEach(it => {
    const ref = threadsByRef[it.email_thread_id];
    if (!ref) return;
    n2sRemoveLabel_(ref.thread, ref.label);
    n2sApplyLabel_(ref.thread, 'N2S/Synced');
    ref.thread.markRead();
  });

  console.log('--- FINISHED N2S EMAIL SYNC ---');
}

/* ─────────────────────────────────────────────────────────────────────────
 * FIELD EXTRACTION — generic, tune against real templates
 *
 * No live email samples were available when this was written, so this is a
 * conservative key:value + labeled-pattern scanner rather than a per-
 * marketplace parser. order_number is the field n2s_map_events() actually
 * needs (it resolves everything else — event, venue, tevo_event_id — via
 * the order books, PROJECT_BIBLE §0); the rest ride straight into n2s_items
 * as a head start for the panel and are NULL-safe if not found.
 * ───────────────────────────────────────────────────────────────────────── */

function n2sExtractFields_(subject, body) {
  const text = (subject || '') + '\n' + (body || '');

  const orderPatterns = [
    /Order\s*(?:Number|#|No\.?)\s*:?\s*([A-Za-z0-9-]+)/i,
    /Order\s*ID\s*:?\s*([A-Za-z0-9-]+)/i,
    /Confirmation\s*(?:Number|#)\s*:?\s*([A-Za-z0-9-]+)/i
  ];
  const order_number = n2sFirstMatch_(text, orderPatterns);

  const event_name = n2sFirstMatch_(text, [/Event\s*:?\s*(.+)/i, /Show\s*:?\s*(.+)/i]);
  const venue       = n2sFirstMatch_(text, [/Venue\s*:?\s*(.+)/i]);
  const section     = n2sFirstMatch_(text, [/Section\s*:?\s*([A-Za-z0-9-]+)/i]);
  const row         = n2sFirstMatch_(text, [/\bRow\s*:?\s*([A-Za-z0-9]+)/i]);
  const seats       = n2sFirstMatch_(text, [/Seats?\s*:?\s*([A-Za-z0-9,\s-]+)/i]);
  const qtyRaw      = n2sFirstMatch_(text, [/Qty\s*:?\s*(\d+)/i, /Quantity\s*:?\s*(\d+)/i]);
  const priceRaw    = n2sFirstMatch_(text, [/Price\s*(?:\/|\s*per\s*)?\s*ticket\s*:?\s*\$?([\d,]+\.?\d*)/i]);
  const totalRaw    = n2sFirstMatch_(text, [/Grand\s*Total\s*:?\s*\$?([\d,]+\.?\d*)/i, /Total\s*:?\s*\$?([\d,]+\.?\d*)/i]);

  // Event date left to a human/the panel for now — dates in marketing-style
  // emails are too varied (locale, relative phrasing, timezone abbreviation)
  // to parse reliably without real samples; n2s_items.event_dt stays NULL
  // here rather than risk landing a wrong LOCAL wall-clock value (the §3
  // mixed-timezone landmine this column is typed `timestamp`, no zone, to
  // avoid). n2s_map_events() does not need it — it resolves via order id.

  const out = { order_number: order_number ? order_number.trim() : null };
  if (event_name) out.event_name = event_name.trim();
  if (venue)       out.venue = venue.trim();
  if (section)     out.section = section.trim();
  if (row)         out.row = row.trim();
  if (seats)       out.seats = seats.trim();
  if (qtyRaw)       out.qty = parseInt(qtyRaw, 10);
  if (priceRaw)     out.price_per_ticket = parseFloat(priceRaw.replace(/,/g, ''));
  if (totalRaw)     out.grand_total = parseFloat(totalRaw.replace(/,/g, ''));
  return out;
}

function n2sFirstMatch_(text, patterns) {
  for (const p of patterns) {
    const m = text.match(p);
    if (m && m[1]) return m[1].split('\n')[0].trim();
  }
  return null;
}

/** Falls back to reading the marketplace out of the label name itself,
 *  e.g. "N2S/Vivid Seats" -> "Vivid Seats". Purely a convenience default —
 *  the ingest RPC re-normalises whatever string ends up in `marketplace`
 *  against the same vocabulary n2s_order_key expects, so an imperfect guess
 *  here is not load-bearing. */
function n2sMarketplaceFromLabel_(labelName) {
  const parts = labelName.split('/');
  return parts[parts.length - 1].trim();
}

/* ─────────────────────────────────────────────────────────────────────────
 * SUPABASE POST
 * ───────────────────────────────────────────────────────────────────────── */

function n2sPostIngestBatch_(sbUrl, sbAnon, sharedSecret, itemsArr) {
  const url = sbUrl + '/rest/v1/rpc/n2s_items_ingest_from_apps_script';
  const payload = {
    p_items         : itemsArr,
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
 * LABEL HELPERS (n2s-prefixed — same defensive create/cache pattern as
 * tickpick_sync.gs's tp* helpers, kept separate so the two scripts can live
 * in one Apps Script project without colliding)
 * ───────────────────────────────────────────────────────────────────────── */

let _n2sLabelCache = null;

function n2sGetLabel_(name) {
  if (!name) return null;
  try {
    const direct = GmailApp.getUserLabelByName(name);
    if (direct) return direct;
  } catch (e) { /* fall through */ }
  try {
    if (!_n2sLabelCache) _n2sLabelCache = GmailApp.getUserLabels();
    for (let i = 0; i < _n2sLabelCache.length; i++) {
      if (_n2sLabelCache[i].getName() === name) return _n2sLabelCache[i];
    }
  } catch (e) {
    console.log(`n2sGetLabel_("${name}"): iteration threw: ${e.message}`);
  }
  return null;
}

function n2sApplyLabel_(thread, name) {
  if (!name) return;
  let label = n2sGetLabel_(name);
  if (!label) {
    try {
      label = GmailApp.createLabel(name);
      _n2sLabelCache = null;
    } catch (e) {
      _n2sLabelCache = null;
      Utilities.sleep(500);
      label = n2sGetLabel_(name);
    }
  }
  if (!label) {
    console.log(`⚠️ n2sApplyLabel_("${name}") — could not get or create label.`);
    return;
  }
  try { thread.addLabel(label); } catch (e) {
    console.log(`n2sApplyLabel_("${name}") addLabel threw: ${e.message}`);
  }
}

function n2sRemoveLabel_(thread, name) {
  if (!name) return;
  try {
    const label = n2sGetLabel_(name);
    if (label) thread.removeLabel(label);
  } catch (e) {
    console.log(`n2sRemoveLabel_("${name}") failed: ${e.message}`);
  }
}

/* ─────────────────────────────────────────────────────────────────────────
 * TRIGGER INSTALLERS
 * ───────────────────────────────────────────────────────────────────────── */

function installN2SEmailSyncTrigger() {
  let removed = 0;
  ScriptApp.getProjectTriggers().forEach(t => {
    if (t.getHandlerFunction() === 'syncN2SEmailsToSupabase') {
      ScriptApp.deleteTrigger(t);
      removed++;
    }
  });
  ScriptApp.newTrigger('syncN2SEmailsToSupabase').timeBased().everyMinutes(5).create();
  console.log(`Trigger installed: syncN2SEmailsToSupabase every 5 min (removed ${removed} prior).`);
}

function uninstallN2SEmailSyncTrigger() {
  let deleted = 0;
  ScriptApp.getProjectTriggers().forEach(t => {
    if (t.getHandlerFunction() === 'syncN2SEmailsToSupabase') {
      ScriptApp.deleteTrigger(t);
      deleted++;
    }
  });
  console.log(`Removed ${deleted} trigger(s).`);
}

/* ─────────────────────────────────────────────────────────────────────────
 * DIAGNOSTICS
 * ───────────────────────────────────────────────────────────────────────── */

function n2sDiagnoseSetup() {
  const props = PropertiesService.getScriptProperties().getProperties();
  ['SUPABASE_PROJECT_URL','SUPABASE_ANON_KEY','APPSCRIPT_N2S_INGEST_SECRET','N2S_EMAIL_LABELS'].forEach(k => {
    const v = props[k] || '';
    console.log(`${k}: ${v ? `SET (${v.length} chars)` : '!! MISSING'}`);
  });
  console.log('--- TRIGGERS ---');
  const trigs = ScriptApp.getProjectTriggers();
  if (trigs.length === 0) {
    console.log('(no triggers installed)');
  } else {
    trigs.forEach(t => console.log(`  ${t.getHandlerFunction()} — ${t.getEventType()} (${t.getTriggerSource()})`));
  }
}

/** Push a single fake row through the RPC to verify wiring end to end.
 *  Leaves one row with email_thread_id "APPS_SCRIPT_PROBE_<ts>" — clean up
 *  via the SQL in the trailing log line. */
function n2sProbeIngestPath() {
  const props  = PropertiesService.getScriptProperties();
  const SB_URL = (props.getProperty('SUPABASE_PROJECT_URL')        || '').trim();
  const SB_ANON= (props.getProperty('SUPABASE_ANON_KEY')           || '').trim();
  const SECRET = (props.getProperty('APPSCRIPT_N2S_INGEST_SECRET') || '').trim();
  if (!SB_URL || !SB_ANON || !SECRET) throw new Error('Missing properties — run setN2SEmailCredentials.');

  const fake = [{
    email_thread_id : 'APPS_SCRIPT_PROBE_' + Date.now(),
    email_label      : 'N2S/Probe',
    order_number      : 'PROBE-' + Date.now(),
    marketplace       : 'Vivid Seats',
    event_name        : 'Apps Script wire probe',
    venue             : 'Test Venue',
    section           : 'TEST',
    row               : 'A',
    qty               : 1,
    price_per_ticket  : 0
  }];
  const result = n2sPostIngestBatch_(SB_URL, SB_ANON, SECRET, fake);
  console.log(`probe result: inserted=${result.inserted} updated=${result.updated} skipped=${result.skipped}`);
  console.log("Cleanup via Studio SQL: DELETE FROM public.n2s_items WHERE email_thread_id LIKE 'APPS_SCRIPT_PROBE_%';");
}

/** List Gmail labels — useful for getting N2S_EMAIL_LABELS spelled exactly
 *  right (capitalization + nesting separator). */
function n2sDiagnoseLabels() {
  const labels = GmailApp.getUserLabels();
  console.log(`--- ${labels.length} USER LABELS ---`);
  labels.forEach(l => console.log(`"${l.getName()}"`));
}
