/**
 * tickpick_sync.gs — Apps Script-driven TickPick → Supabase ingest.
 *
 * Why this exists: TickPick's broker API allowlists partner egress IPs.
 * Google Apps Script + the operator's local IPs are on the allowlist;
 * Supabase's pg_net egress is not. Apps Script pulls the orders, then
 * POSTs them to a Supabase RPC for upsert into public.tickpick_orders.
 *
 * Companion migration: 20260515120000_tickpick_orders_ingest_from_apps_script.
 *
 * ============================================================================
 * SETUP — run setTickPickSyncCredentials() ONCE, then installTickPickSyncTrigger()
 * ============================================================================
 *
 * Required script properties (all set inside setTickPickSyncCredentials below):
 *   TICKPICK_API_TOKEN        — Bearer JWT for api.tickpick.com (already in use)
 *   SUPABASE_PROJECT_URL      — https://hzrizjeaxlqcxfrtczpq.supabase.co
 *   SUPABASE_ANON_KEY         — public anon JWT (legacy key shape)
 *   APPSCRIPT_INGEST_SECRET   — shared secret, must match vault.APPSCRIPT_INGEST_SECRET
 *
 * After setup, install the time-driven trigger by running
 * installTickPickSyncTrigger() once. The trigger fires syncTickPickToSupabase
 * every 30 minutes. Operator can adjust cadence via the function below.
 *
 * Manual debugging: run syncTickPickToSupabase() and watch the Execution log.
 * ============================================================================
 */

/* ------------------------------------------------------------------ */
/* 1. CREDENTIAL SETUP (run once, then delete the literal values)     */
/* ------------------------------------------------------------------ */

function setTickPickSyncCredentials() {
  const props = PropertiesService.getScriptProperties();
  props.setProperties({
    'TICKPICK_API_TOKEN'      : 'PASTE_TICKPICK_BEARER_JWT_HERE',
    'SUPABASE_PROJECT_URL'    : 'https://hzrizjeaxlqcxfrtczpq.supabase.co',
    'SUPABASE_ANON_KEY'       : 'PASTE_SUPABASE_ANON_KEY_HERE',
    'APPSCRIPT_INGEST_SECRET' : 'PASTE_APPSCRIPT_INGEST_SECRET_HERE'
  }, false);
  Logger.log('Credentials stored. Now run installTickPickSyncTrigger().');
}

/* ------------------------------------------------------------------ */
/* 2. TRIGGER INSTALL — every 30 min (matches our T2 tier cadence)    */
/* ------------------------------------------------------------------ */

function installTickPickSyncTrigger() {
  // Remove any existing triggers for this handler (idempotent re-install)
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'syncTickPickToSupabase') {
      ScriptApp.deleteTrigger(t);
    }
  });
  ScriptApp.newTrigger('syncTickPickToSupabase').timeBased().everyMinutes(30).create();
  Logger.log('Trigger installed: syncTickPickToSupabase every 30 min.');
}

function uninstallTickPickSyncTrigger() {
  var deleted = 0;
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'syncTickPickToSupabase') {
      ScriptApp.deleteTrigger(t);
      deleted++;
    }
  });
  Logger.log('Removed ' + deleted + ' trigger(s).');
}

/* ------------------------------------------------------------------ */
/* 3. MAIN SYNC                                                       */
/* ------------------------------------------------------------------ */

function syncTickPickToSupabase() {
  var props = PropertiesService.getScriptProperties();
  var TP_TOKEN  = (props.getProperty('TICKPICK_API_TOKEN')      || '').trim();
  var SB_URL    = (props.getProperty('SUPABASE_PROJECT_URL')    || '').trim();
  var SB_ANON   = (props.getProperty('SUPABASE_ANON_KEY')       || '').trim();
  var INGEST_SK = (props.getProperty('APPSCRIPT_INGEST_SECRET') || '').trim();

  if (!TP_TOKEN || !SB_URL || !SB_ANON || !INGEST_SK) {
    throw new Error('Missing one or more script properties — run setTickPickSyncCredentials first.');
  }

  // 3a. Pull from TickPick
  var orders = fetchTickPickOrdersList_(TP_TOKEN, 'unfulfilled');
  Logger.log('TickPick /1.0/orders?status=unfulfilled returned ' + orders.length + ' orders.');

  if (orders.length === 0) {
    Logger.log('Nothing to sync. Exiting cleanly.');
    return;
  }

  // 3b. Push to Supabase RPC (chunk to keep request body well under 5 MB limit)
  var CHUNK = 250;
  var totals = { inserted: 0, updated: 0, skipped: 0, batches: 0 };

  for (var i = 0; i < orders.length; i += CHUNK) {
    var batch = orders.slice(i, i + CHUNK);
    var result = postIngestBatch_(SB_URL, SB_ANON, INGEST_SK, batch);
    totals.inserted += result.inserted;
    totals.updated  += result.updated;
    totals.skipped  += result.skipped;
    totals.batches  += 1;
    Logger.log('Batch ' + totals.batches + ' (' + batch.length + ' orders): ' +
               'inserted=' + result.inserted +
               ' updated=' + result.updated +
               ' skipped=' + result.skipped);
  }

  Logger.log('SYNC COMPLETE — batches=' + totals.batches +
             ', total_inserted=' + totals.inserted +
             ', total_updated=' + totals.updated +
             ', total_skipped=' + totals.skipped);
}

/* ------------------------------------------------------------------ */
/* 4. INTERNAL HELPERS                                                */
/* ------------------------------------------------------------------ */

/** GET https://api.tickpick.com/1.0/orders?status=<status> with Bearer auth. */
function fetchTickPickOrdersList_(token, status) {
  var url = 'https://api.tickpick.com/1.0/orders?status=' + encodeURIComponent(status);
  var resp = UrlFetchApp.fetch(url, {
    method: 'get',
    headers: {
      'Authorization': 'Bearer ' + token,
      'Accept': 'application/json'
    },
    muteHttpExceptions: true
  });
  var code = resp.getResponseCode();
  if (code !== 200) {
    var body = resp.getContentText() || '';
    throw new Error('TickPick fetch failed: HTTP ' + code + ' — ' + body.substring(0, 400));
  }
  var json = JSON.parse(resp.getContentText());
  // /1.0/orders returns a top-level array; some shapes wrap as {orders:[...]}
  if (Array.isArray(json)) return json;
  if (json && Array.isArray(json.orders)) return json.orders;
  Logger.log('Unexpected TickPick shape: ' + JSON.stringify(json).substring(0, 200));
  return [];
}

/**
 * POST one batch to the Supabase RPC.
 * Returns { inserted, updated, skipped } from the function's TABLE return.
 */
function postIngestBatch_(sbUrl, sbAnon, sharedSecret, ordersArr) {
  var url = sbUrl + '/rest/v1/rpc/tickpick_orders_ingest_from_apps_script';
  var payload = {
    p_orders        : ordersArr,
    p_shared_secret : sharedSecret
  };
  var resp = UrlFetchApp.fetch(url, {
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
  var code = resp.getResponseCode();
  var body = resp.getContentText();
  if (code !== 200) {
    throw new Error('Supabase RPC failed: HTTP ' + code + ' — ' + body.substring(0, 600));
  }
  // PostgREST returns a JSON array even for single-row table functions.
  var parsed;
  try { parsed = JSON.parse(body); } catch (e) { parsed = []; }
  var row = (Array.isArray(parsed) && parsed.length > 0) ? parsed[0] : {};
  return {
    inserted : Number(row.inserted) || 0,
    updated  : Number(row.updated)  || 0,
    skipped  : Number(row.skipped)  || 0
  };
}

/* ------------------------------------------------------------------ */
/* 5. DIAGNOSTICS                                                     */
/* ------------------------------------------------------------------ */

/** Log the property names + lengths (NOT values) so you can confirm setup. */
function diagnoseTickPickSync() {
  var props = PropertiesService.getScriptProperties().getProperties();
  ['TICKPICK_API_TOKEN','SUPABASE_PROJECT_URL','SUPABASE_ANON_KEY','APPSCRIPT_INGEST_SECRET'].forEach(function (k) {
    var v = props[k] || '';
    Logger.log(k + ': ' + (v ? ('SET (' + v.length + ' chars)') : 'MISSING'));
  });
  var trigs = ScriptApp.getProjectTriggers()
    .filter(function (t) { return t.getHandlerFunction() === 'syncTickPickToSupabase'; });
  Logger.log('Active triggers for syncTickPickToSupabase: ' + trigs.length);
}

/** One-shot test that pushes a single fake order so you can confirm wiring. */
function probeIngestPath() {
  var props = PropertiesService.getScriptProperties();
  var SB_URL    = (props.getProperty('SUPABASE_PROJECT_URL')    || '').trim();
  var SB_ANON   = (props.getProperty('SUPABASE_ANON_KEY')       || '').trim();
  var INGEST_SK = (props.getProperty('APPSCRIPT_INGEST_SECRET') || '').trim();
  if (!SB_URL || !SB_ANON || !INGEST_SK) throw new Error('Missing properties — run setTickPickSyncCredentials.');

  var fake = [{
    order_number : 'APPS_SCRIPT_PROBE_' + Date.now(),
    event_name   : 'Apps Script wire probe',
    event_date   : '2026-06-01T19:00:00Z',
    section      : 'TEST',
    row          : 'A',
    status       : 'unfulfilled',
    quantity     : 1,
    total        : 0
  }];
  var result = postIngestBatch_(SB_URL, SB_ANON, INGEST_SK, fake);
  Logger.log('probe result: inserted=' + result.inserted + ' updated=' + result.updated + ' skipped=' + result.skipped);
  Logger.log('Cleanup: run this SQL in Studio when done — ' +
             'DELETE FROM public.tickpick_orders WHERE tp_order_id LIKE \'APPS_SCRIPT_PROBE_%\';');
}
