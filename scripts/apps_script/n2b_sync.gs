/**
 * ============================================================================
 * N2B (NEED TO BUY) GMAIL SYNC
 * ============================================================================
 *
 * Install in the mailbox that receives "PEDDLING SALE RECEIVED" emails from
 * orders@s4kent.com and labels them Need2Buy/WaitToBuy.
 *
 * Every 5 minutes, syncN2bToSupabase() finds every thread that still carries
 * the WaitToBuy label, parses the sale, and sends the WHOLE labelled set to
 * the Supabase RPC public.n2b_ingest_from_apps_script (mig 20261009180000).
 * Each sale becomes an N2B row in the N2S pipeline: the event is mapped and
 * priced on TEvo / GoTickets / SeatGeek every 4 hours, with no timer, and
 * covers show on the terminal Subs page like N2S ones.
 *
 * A sale stops being priced when:
 *   - the WaitToBuy label is removed (closed ~30 min after it leaves the set),
 *   - the thread carries a cancel label (CANCEL_LABELS) or any message in it
 *     has "CANCEL" in its subject (cancelled, permanently),
 *   - or the event is more than a day past.
 *
 * Read-only on Gmail: this script never adds, removes or changes a label,
 * and never marks or moves a thread.
 *
 * Required script properties (set once via setN2bCredentials):
 *   SUPABASE_PROJECT_URL     — https://hzrizjeaxlqcxfrtczpq.supabase.co
 *   SUPABASE_ANON_KEY        — public anon key (PostgREST)
 *   APPSCRIPT_INGEST_SECRET  — shared secret checked by the RPC (vault)
 *
 * Trigger: installN2bSyncTrigger() → every 5 minutes.
 * Check a parse without sending anything: n2bPreview().
 * ============================================================================
 */

const N2B = {
  // Gmail search for the open book. Nested label "Need2Buy/WaitToBuy".
  QUERY: 'label:need2buy-waittobuy subject:"PEDDLING SALE RECEIVED"',
  // A thread carrying any of these is sent as cancelled.
  CANCEL_LABELS: ['Need2Buy/Cancelled', 'ISSUE/Cancelled'],
  PAGE: 100,
  // Beyond this the run is partial, so it must not close missing sales.
  MAX_THREADS: 1500,
};

/* ─────────────────────────────────────────────────────────────────────────
 * CREDENTIAL SETUP — run ONCE, then delete the literal values from this
 * function so they don't sit in source.
 * ───────────────────────────────────────────────────────────────────────── */

function setN2bCredentials() {
  const literals = {
    'SUPABASE_PROJECT_URL'    : 'https://hzrizjeaxlqcxfrtczpq.supabase.co',
    'SUPABASE_ANON_KEY'       : 'PASTE_SUPABASE_ANON_KEY_HERE',
    'APPSCRIPT_INGEST_SECRET' : 'PASTE_APPSCRIPT_INGEST_SECRET_HERE'
  };
  const unresolved = Object.keys(literals).filter(k => /^PASTE_/.test(literals[k]));
  if (unresolved.length > 0) {
    throw new Error('Replace placeholders before running: ' + unresolved.join(', '));
  }
  PropertiesService.getScriptProperties().setProperties(literals, false);
  console.log('Credentials stored. Next: run n2bPreview(), then installN2bSyncTrigger().');
}

/* ─────────────────────────────────────────────────────────────────────────
 * SYNC
 * ───────────────────────────────────────────────────────────────────────── */

function syncN2bToSupabase() {
  const props = PropertiesService.getScriptProperties();
  const url    = props.getProperty('SUPABASE_PROJECT_URL');
  const anon   = props.getProperty('SUPABASE_ANON_KEY');
  const secret = props.getProperty('APPSCRIPT_INGEST_SECRET');
  if (!url || !anon || !secret) {
    console.error('🚨 Missing credentials. Run setN2bCredentials() first.');
    return;
  }

  // If the search itself fails, send nothing: an empty FULL sync would close
  // every open sale after 30 minutes.
  const book = n2bCollect_();
  console.log(`N2B: ${book.items.length} sale(s) from ${book.threads} thread(s)` +
              `${book.complete ? '' : ' (PARTIAL — will not close missing sales)'}` +
              `${book.unparsed.length ? `; unparsed: ${book.unparsed.join(', ')}` : ''}`);

  const res = UrlFetchApp.fetch(url.replace(/\/+$/, '') + '/rest/v1/rpc/n2b_ingest_from_apps_script', {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: anon.trim(), Authorization: 'Bearer ' + anon.trim() },
    payload: JSON.stringify({
      p_items: book.items,
      p_shared_secret: secret.trim(),
      p_full_sync: book.complete,
    }),
    muteHttpExceptions: true,
  });
  const code = res.getResponseCode();
  if (code < 200 || code >= 300) {
    console.error(`N2B ingest failed: HTTP ${code} ${res.getContentText().slice(0, 500)}`);
    return;
  }
  console.log('N2B ingest: ' + res.getContentText());
}

/** Parse the labelled book and log it. Sends nothing. */
function n2bPreview() {
  const book = n2bCollect_();
  console.log(`${book.items.length} sale(s), complete=${book.complete}, unparsed=${book.unparsed.length}`);
  book.items.slice(0, 25).forEach(it => console.log(JSON.stringify(it)));
  if (book.unparsed.length) console.log('Unparsed thread ids: ' + book.unparsed.join(', '));
}

function n2bCollect_() {
  const items = [];
  const unparsed = [];
  const seen = {};
  let start = 0;
  let threads = 0;
  let complete = true;

  while (true) {
    const page = GmailApp.search(N2B.QUERY, start, N2B.PAGE);
    threads += page.length;
    page.forEach(thread => {
      const it = n2bParseThread_(thread);
      if (!it) { unparsed.push(thread.getId()); return; }
      if (seen[it.pos_order]) return;          // one row per sale
      seen[it.pos_order] = true;
      items.push(it);
    });
    if (page.length < N2B.PAGE) break;
    start += N2B.PAGE;
    if (start >= N2B.MAX_THREADS) { complete = false; break; }
  }
  return { items, unparsed, threads, complete };
}

function n2bParseThread_(thread) {
  const msgs = thread.getMessages();
  const sale = msgs.find(m => /PEDDLING SALE RECEIVED/i.test(m.getSubject()));
  if (!sale) return null;

  const it = n2bParseBody_(sale.getPlainBody() || '', sale.getSubject());
  if (!it) return null;

  const labels = thread.getLabels().map(l => l.getName());
  const cancelLabel = labels.some(l => N2B.CANCEL_LABELS.indexOf(l) >= 0);
  const cancelMsg = msgs.some(m => /CANCEL/i.test(m.getSubject()));

  it.sale_at = sale.getDate().toISOString();
  it.thread_id = thread.getId();
  it.labels = labels;
  it.cancelled = cancelLabel || cancelMsg;
  return it;
}

/**
 * The body (once table pipes and line breaks are flattened) reads:
 *   PEDDLING SALE RECEIVED $113.30Order #8581070 Sale Date 8/4/2026 2:07 PM
 *   Site Ticket Evolution Site Order # 7987790-18927831 Ticket Details
 *   TNOW Ticket # 6gzvwp4 TU Ticket # 47754860 Event Date 8/6/2026 1:20 PM
 *   Event Toronto Blue Jays at Chicago Cubs Venue Wrigley Field Section 324 right
 *   Row 9 Seats 500-501 Qty 2 Price Per 56.65 x 2 Total $113.30
 */
function n2bParseBody_(body, subject) {
  const t = String(body).replace(/[|\t\r\n]+/g, ' ').replace(/\s+/g, ' ').trim();
  const get = re => { const m = t.match(re); return m ? m[1].trim() : ''; };

  let pos = get(/Order #\s*(\d+)/);
  if (!pos) { const m = String(subject).match(/RECEIVED\s+(\d+)/i); pos = m ? m[1] : ''; }
  if (!pos) return null;

  const eventDate = get(/Event Date\s+(\d{1,2}\/\d{1,2}\/\d{4}\s+\d{1,2}:\d{2}\s*[AP]M)/i);
  let eventName = get(/ Event\s+(?!Date\b)(.+?)\s+Venue\s/);
  if (!eventName) {
    const m = String(subject).match(/\|\s*(.+?)\/[0-9a-f-]{36}\s*$/i);
    eventName = m ? m[1].trim() : '';
  }

  return {
    pos_order:  pos,
    site:       get(/ Site\s+(.+?)\s+Site Order #/),
    site_order: get(/Site Order #\s*(\S+)/),
    event_name: eventName,
    event_dt:   n2bLocalIso_(eventDate),
    venue:      get(/ Venue\s+(.+?)\s+Section\s/),
    section:    get(/ Section\s+(.+?)\s+Row\s/),
    row:        get(/ Row\s+(.+?)\s+Seats\s/),
    seats:      get(/ Seats\s+(.*?)\s*Qty\s/),
    qty:        get(/ Qty\s+(\d+)/),
    price_each: get(/Price Per\s+\$?([\d,]+(?:\.\d+)?)/).replace(/,/g, ''),
    total:      get(/ Total\s+\$?([\d,]+(?:\.\d+)?)/).replace(/,/g, ''),
  };
}

/** "10/22/2026 7:15 PM" -> "2026-10-22T19:15:00" (venue-local, no zone). */
function n2bLocalIso_(s) {
  const m = String(s || '').match(/(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2})\s*([AP]M)/i);
  if (!m) return '';
  let h = parseInt(m[4], 10) % 12;
  if (/PM/i.test(m[6])) h += 12;
  const p = n => String(n).padStart(2, '0');
  return `${m[3]}-${p(m[1])}-${p(m[2])}T${p(h)}:${m[5]}:00`;
}

/* ─────────────────────────────────────────────────────────────────────────
 * TRIGGER
 * ───────────────────────────────────────────────────────────────────────── */

function installN2bSyncTrigger() {
  uninstallN2bSyncTrigger();
  ScriptApp.newTrigger('syncN2bToSupabase').timeBased().everyMinutes(5).create();
  console.log('Installed: syncN2bToSupabase every 5 minutes.');
}

function uninstallN2bSyncTrigger() {
  ScriptApp.getProjectTriggers().forEach(t => {
    if (t.getHandlerFunction() === 'syncN2bToSupabase') ScriptApp.deleteTrigger(t);
  });
}
