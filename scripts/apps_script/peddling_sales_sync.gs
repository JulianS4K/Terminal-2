/**
 * ============================================================================
 * PEDDLING SALES → GOOGLE SHEET + SUPABASE
 * ============================================================================
 *
 * Install in ANY mailbox that receives "[PACIOLAN] PEDDLING SALE RECEIVED"
 * emails (orders@, support@, a buyer's inbox, ...). It is standalone — it
 * does not need n2b_sync.gs — and several inboxes can run it at once against
 * the SAME sheet + Supabase:
 *   - the sheet is deduped on Invoice # (a sale lands once, whichever inbox
 *     sees it first; a row two inboxes append in the same instant is removed
 *     again by the inbox that wrote it second),
 *   - Supabase upserts on the order number, and records which inbox saw the
 *     sale first (mailbox).
 * If an inbox gets the emails forwarded (so the sender is not orders@), the
 * default query still matches — it keys on the subject only. Override it per
 * inbox with the PEDDLE_QUERY script property if needed.
 *
 * Every 5 minutes, syncPeddlingSales():
 *   1. finds the recent PEDDLING SALE RECEIVED emails (PEDDLE.LOOKBACK),
 *   2. parses each one,
 *   3. appends a row to the Google Sheet for any sale whose Invoice # is not
 *      already in the sheet (so a sale is written once, ever), and
 *   4. tags the Gmail thread of every sale that is in the sheet (written now,
 *      written earlier, or typed in by hand — matched on Invoice #) with the
 *      label PEDDLE_LABEL (default "Peddling/In Sheet"), and
 *   5. upserts every parsed sale into Supabase via the RPC
 *      public.peddling_sales_ingest_from_apps_script (mig 20261109170000).
 *      The upsert is keyed on the order number, so re-sending is harmless.
 *
 * The sheet and Supabase are independent: if one fails, the other still runs,
 * and the next run retries (the sheet skips sales it already has; Supabase
 * upserts).
 *
 * Gmail: the ONLY change this script makes is adding the "In Sheet" label.
 * It never removes a label, marks, moves or deletes a thread. A thread that
 * already carries the label is never appended to the sheet again, so
 * deleting a row by hand keeps it deleted. (Safe to run in the same project
 * as n2b_sync.gs — every name here is prefixed "peddle"/"Peddling".)
 *
 * Sheet columns (A → AC), written by position because City/State appear
 * twice and B–D have no header:
 *   Event Date & Time | | | | Email | Password | URL | Address | City | State |
 *   Zip Code | Event | Venue | Section | Row | Start Seat | End Seat | Quantity |
 *   Price per Ticket | GrandTotal Amount | Total Cost | Profit | Customer Name |
 *   Customer Email | Invoice # | Site Order# | Site | City | State
 * Filled from the email: Event Date & Time, Event, Venue, Section, Row,
 * Start/End Seat, Quantity, Price per Ticket, GrandTotal Amount, Invoice #
 * (our Paciolan order #), Site Order#, Site. Profit is a formula
 * (GrandTotal − Total Cost) that fills in once Total Cost is entered.
 * Everything else is left blank for the buyer to fill in.
 *
 * Setup (once):
 *   1. setPeddlingConfig()  — fill the literals first, run, then blank them.
 *   2. peddlingPreview()    — parses and logs, writes nothing.
 *   3. setupPeddlingSheet() — writes the header row if the tab is empty
 *      (the sheet must have "Invoice #" in column Y, or nothing is written).
 *   4. installPeddlingTrigger() — every 5 minutes.
 *   Optional: backfillPeddlingSales() — same as a sync over 60 days.
 *
 * Script properties:
 *   PEDDLE_SHEET_ID          — spreadsheet id (default: PEDDLE.SHEET_ID)
 *   PEDDLE_SHEET_TAB         — tab name (default: the first tab, gid=0)
 *   PEDDLE_LABEL             — Gmail label for sales in the sheet
 *                              (default "Peddling/In Sheet")
 *   PEDDLE_QUERY             — optional Gmail search override for this inbox
 *                              (default: subject:"PEDDLING SALE RECEIVED")
 *   SUPABASE_PROJECT_URL     — https://hzrizjeaxlqcxfrtczpq.supabase.co
 *   SUPABASE_ANON_KEY        — public anon key (PostgREST)
 *   APPSCRIPT_INGEST_SECRET  — shared secret checked by the RPC (vault)
 * (The last three are the same ones n2b_sync.gs / tickpick_sync.gs use.)
 * ============================================================================
 */

const PEDDLE = {
  QUERY: 'subject:"PEDDLING SALE RECEIVED"',
  LOOKBACK: '3d',          // regular sync window
  BACKFILL: '60d',         // backfillPeddlingSales() window
  PAGE: 100,
  MAX_THREADS: 2000,
  SHEET_ID: '1FqRTKj5Dn1cUqEwqUptUamWm266GPPCTSrMqWeDmzE0',
  LABEL: 'Peddling/In Sheet',
  RPC: 'peddling_sales_ingest_from_apps_script',
  HEADER: [
    'Event Date & Time', '', '', '', 'Email', 'Password', 'URL', 'Address',
    'City', 'State', 'Zip Code', 'Event', 'Venue', 'Section', 'Row',
    'Start Seat', 'End Seat', 'Quantity', 'Price per Ticket',
    'GrandTotal Amount', 'Total Cost', 'Profit', 'Customer Name',
    'Customer Email', 'Invoice #', 'Site Order#', 'Site', 'City', 'State',
  ],
};
// 1-based column numbers used below
const PEDDLE_COL = { EVENT_DT: 1, GRAND_TOTAL: 20, TOTAL_COST: 21, PROFIT: 22, INVOICE: 25 };

/* ─────────────────────────────────────────────────────────────────────────
 * CONFIG — run ONCE, then blank the literal values so they don't sit in source.
 * ───────────────────────────────────────────────────────────────────────── */

function setPeddlingConfig() {
  const literals = {
    'PEDDLE_SHEET_ID'         : '1FqRTKj5Dn1cUqEwqUptUamWm266GPPCTSrMqWeDmzE0',
    'PEDDLE_LABEL'            : 'Peddling/In Sheet',
    'PEDDLE_QUERY'            : 'subject:"PEDDLING SALE RECEIVED"',
    'SUPABASE_PROJECT_URL'    : 'https://hzrizjeaxlqcxfrtczpq.supabase.co',
    'SUPABASE_ANON_KEY'       : 'PASTE_SUPABASE_ANON_KEY_HERE',
    'APPSCRIPT_INGEST_SECRET' : 'PASTE_APPSCRIPT_INGEST_SECRET_HERE',
  };
  const unresolved = Object.keys(literals).filter(k => /^PASTE_/.test(literals[k]));
  if (unresolved.length) throw new Error('Replace placeholders before running: ' + unresolved.join(', '));
  PropertiesService.getScriptProperties().setProperties(literals, false);
  console.log('Config stored. Next: peddlingPreview(), setupPeddlingSheet(), installPeddlingTrigger().');
}

/* ─────────────────────────────────────────────────────────────────────────
 * ENTRY POINTS
 * ───────────────────────────────────────────────────────────────────────── */

function syncPeddlingSales() { peddleRun_(PEDDLE.LOOKBACK); }

function backfillPeddlingSales() { peddleRun_(PEDDLE.BACKFILL); }

/** Parse recent emails and log them. Writes nothing anywhere. */
function peddlingPreview() {
  const got = peddleCollect_(PEDDLE.LOOKBACK);
  console.log(`${got.items.length} sale(s) from ${got.threads} thread(s); unparsed: ${got.unparsed.length}`);
  console.log(`Already tagged "${peddleLabelName_()}": ${got.items.filter(it => it.in_sheet_tag).length}`);
  got.items.slice(0, 25).forEach(it => console.log(JSON.stringify(it)));
  if (got.unparsed.length) console.log('Unparsed message ids: ' + got.unparsed.join(', '));
}

/** Write the header row if the tab is empty (creates the tab if missing). */
function setupPeddlingSheet() {
  const sh = peddleSheet_();
  if (sh.getLastRow() === 0) {
    sh.getRange(1, 1, 1, PEDDLE.HEADER.length).setValues([PEDDLE.HEADER]).setFontWeight('bold');
    sh.setFrozenRows(1);
    console.log('Header written.');
  } else {
    console.log('Tab already has data; header left as is.');
  }
}

function peddleRun_(window) {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30 * 1000)) { console.warn('Another run is in progress; skipping.'); return; }
  try {
    const got = peddleCollect_(window);
    console.log(`Peddling: ${got.items.length} sale(s) from ${got.threads} thread(s)` +
                (got.unparsed.length ? `; unparsed: ${got.unparsed.join(', ')}` : ''));
    if (!got.items.length) return;

    try {
      const inSheet = peddleWriteSheet_(got.items);
      peddleTag_(got, inSheet);
    } catch (e) { console.error('Sheet write / tagging failed: ' + (e && e.stack || e)); }

    try { peddleSendSupabase_(got.items); }
    catch (e) { console.error('Supabase send failed: ' + (e && e.stack || e)); }
  } finally {
    lock.releaseLock();
  }
}

/* ─────────────────────────────────────────────────────────────────────────
 * GMAIL → ITEMS
 * ───────────────────────────────────────────────────────────────────────── */

function peddleCollect_(window) {
  const base = PropertiesService.getScriptProperties().getProperty('PEDDLE_QUERY') || PEDDLE.QUERY;
  const q = `${base} newer_than:${window}`;
  const mailbox = peddleMailbox_();
  const labelName = peddleLabelName_();
  const threadOf = {};      // pos_order -> GmailThread (kept out of the items)
  const items = [];
  const unparsed = [];
  const seen = {};
  let start = 0, threads = 0;

  while (true) {
    const page = GmailApp.search(q, start, PEDDLE.PAGE);
    threads += page.length;
    page.forEach(thread => {
      const msgs = thread.getMessages();
      const cancelled = msgs.some(m => /CANCEL/i.test(m.getSubject()));
      const tagged = thread.getLabels().some(l => l.getName() === labelName);
      msgs.forEach(m => {
        const subj = m.getSubject();
        if (!/PEDDLING SALE RECEIVED/i.test(subj) || /CANCEL/i.test(subj)) return;
        const it = peddleParseBody_(m.getPlainBody() || '', subj);
        if (!it) { unparsed.push(m.getId()); return; }
        if (seen[it.pos_order]) return;          // one row per sale
        seen[it.pos_order] = true;
        it.email_at = m.getDate().toISOString();
        it.gmail_message_id = m.getId();
        it.gmail_thread_id = thread.getId();
        it.mailbox = mailbox;
        it.in_sheet_tag = tagged;
        threadOf[it.pos_order] = thread;
        it.cancelled = cancelled;
        items.push(it);
      });
    });
    if (page.length < PEDDLE.PAGE) break;
    start += PEDDLE.PAGE;
    if (start >= PEDDLE.MAX_THREADS) { console.warn('MAX_THREADS reached; run is partial.'); break; }
  }
  // oldest first, so sheet rows land in sale order
  items.sort((a, b) => String(a.email_at).localeCompare(String(b.email_at)));
  return { items, unparsed, threads, threadOf };
}

/**
 * Flattened body reads:
 *   [PACIOLAN] PEDDLING SALE RECEIVED $588.27Order #8864926 Sale Date 11/9/2026 11:40 AM
 *   Site Viagogo Site Order # 659264490 Ticket Details TNOW Ticket # 6689b092-...
 *   TU Ticket # 74253206 Event Date 11/28/2026 11:59 PM Event Arizona State Sun
 *   Devils at Arizona Wildcats Football Venue Casino Del Sol Stadium Section 20
 *   Row 43 Seats 3-5 Qty 3 Price Per 196.09 x 3 Total $588.27
 */
function peddleParseBody_(body, subject) {
  const t = ' ' + String(body).replace(/[|\t\r\n]+/g, ' ').replace(/\s+/g, ' ').trim();
  const get = re => { const m = t.match(re); return m ? m[1].trim() : ''; };
  const money = re => get(re).replace(/,/g, '');
  const DT = '(\\d{1,2}\\/\\d{1,2}\\/\\d{4}\\s+\\d{1,2}:\\d{2}\\s*[AP]M)';

  let pos = get(/Order #\s*(\d+)/);
  if (!pos) { const m = String(subject).match(/RECEIVED\s+(\d+)/i); pos = m ? m[1] : ''; }
  if (!pos) return null;

  let eventName = get(/ Event\s+(?!Date\b)(.+?)\s+Venue\s/);
  if (!eventName) {
    const m = String(subject).match(/\|\s*(.+?)\/[0-9a-f-]{36}\s*$/i);
    eventName = m ? m[1].trim() : '';
  }
  const src = get(/\[([A-Z0-9 _-]+)\]\s*PEDDLING/i) ||
              (String(subject).match(/\[([A-Z0-9 _-]+)\]/i) || [])[1] || 'PACIOLAN';

  const seats = get(/ Seats\s+(.*?)\s*Qty\s/);
  const sm = seats.match(/^\s*([A-Za-z]*\d+)\s*-\s*([A-Za-z]*\d+)\s*$/);
  const qty = get(/ Qty\s+(\d+)/);

  return {
    pos_order:   pos,
    source:      src.toUpperCase(),
    sale_dt:     peddleLocalIso_(get(new RegExp('Sale Date\\s+' + DT, 'i'))),
    site:        get(/ Site\s+(.+?)\s+Site Order #/),
    site_order:  get(/Site Order #\s*(\S+)/),
    tnow_ticket: get(/TNOW Ticket #\s*(\S+)/),
    tu_ticket:   get(/TU Ticket #\s*(\S+)/),
    event_dt:    peddleLocalIso_(get(new RegExp('Event Date\\s+' + DT, 'i'))),
    event_name:  eventName,
    venue:       get(/ Venue\s+(.+?)\s+Section\s/),
    section:     get(/ Section\s+(.+?)\s+Row\s/),
    row:         get(/ Row\s+(.+?)\s+Seats\s/),
    seats:       seats,
    seat_start:  sm ? sm[1] : seats,
    seat_end:    sm ? sm[2] : seats,
    qty:         qty,
    price_each:  money(/Price Per\s+\$?([\d,]+(?:\.\d+)?)/),
    total:       money(/ Total\s+\$?([\d,]+(?:\.\d+)?)/),
  };
}

/** Address of the inbox this copy of the script runs in ('' if unavailable). */
function peddleMailbox_() {
  try { return Session.getEffectiveUser().getEmail() || ''; } catch (e) { return ''; }
}

/** "11/28/2026 11:59 PM" -> "2026-11-28T23:59:00" (venue-local, no zone). */
function peddleLocalIso_(s) {
  const m = String(s || '').match(/(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2})\s*([AP]M)/i);
  if (!m) return '';
  let h = parseInt(m[4], 10) % 12;
  if (/PM/i.test(m[6])) h += 12;
  const p = n => String(n).padStart(2, '0');
  return `${m[3]}-${p(m[1])}-${p(m[2])}T${p(h)}:${m[5]}:00`;
}

/* ─────────────────────────────────────────────────────────────────────────
 * GOOGLE SHEET
 * ───────────────────────────────────────────────────────────────────────── */

function peddleSheet_() {
  const props = PropertiesService.getScriptProperties();
  const ss = SpreadsheetApp.openById(props.getProperty('PEDDLE_SHEET_ID') || PEDDLE.SHEET_ID);
  const tab = props.getProperty('PEDDLE_SHEET_TAB');
  if (tab) return ss.getSheetByName(tab) || ss.insertSheet(tab);
  return ss.getSheets().find(sh => sh.getSheetId() === 0) || ss.getSheets()[0];
}

/** Appends new sales; returns the set of Invoice #s now in the sheet. */
function peddleWriteSheet_(items) {
  const sh = peddleSheet_();
  if (sh.getLastRow() === 0) setupPeddlingSheet();
  const head = String(sh.getRange(1, PEDDLE_COL.INVOICE).getValue()).trim();
  if (!/^Invoice\s*#?$/i.test(head)) {
    throw new Error(`Column ${peddleColLetter_(PEDDLE_COL.INVOICE)} header is "${head}", expected ` +
                    '"Invoice #". Nothing written — fix the sheet layout or PEDDLE_SHEET_TAB.');
  }

  // Invoice #s already in the sheet → never write a sale twice.
  const last = sh.getLastRow();
  const have = {};
  if (last > 1) {
    sh.getRange(2, PEDDLE_COL.INVOICE, last - 1, 1).getValues()
      .forEach(r => { const v = String(r[0]).trim(); if (v) have[v] = true; });
  }

  // already tagged = it went to the sheet before; if the row is gone now,
  // someone deleted it on purpose, so don't put it back
  const fresh = items.filter(it => !have[it.pos_order] && !it.cancelled && !it.in_sheet_tag);
  if (!fresh.length) { console.log('Sheet: nothing new.'); return have; }

  const first = sh.getLastRow() + 1;
  const rows = fresh.map((it, i) => peddleRow_(it, first + i));
  sh.getRange(first, 1, rows.length, PEDDLE.HEADER.length).setValues(rows);
  sh.getRange(first, PEDDLE_COL.EVENT_DT, rows.length, 1).setNumberFormat('m/d/yyyy h:mm AM/PM');
  SpreadsheetApp.flush();
  console.log(`Sheet: appended ${rows.length} row(s): ${fresh.map(it => it.pos_order).join(', ')}`);
  peddleDropRaceDupes_(sh, fresh.map(it => String(it.pos_order)));
  fresh.forEach(it => { have[it.pos_order] = true; });
  return have;
}

/* ─────────────────────────────────────────────────────────────────────────
 * GMAIL TAG — label every sale that is in the sheet
 * ───────────────────────────────────────────────────────────────────────── */

function peddleLabelName_() {
  return PropertiesService.getScriptProperties().getProperty('PEDDLE_LABEL') || PEDDLE.LABEL;
}

function peddleLabel_() {
  const name = peddleLabelName_();
  let label = GmailApp.getUserLabelByName(name);
  if (label) return label;
  // create parents first for a nested name like "Peddling/In Sheet"
  const parts = name.split('/');
  for (let i = 1; i < parts.length; i++) {
    const parent = parts.slice(0, i).join('/');
    if (!GmailApp.getUserLabelByName(parent)) GmailApp.createLabel(parent);
  }
  return GmailApp.createLabel(name);
}

function peddleTag_(got, inSheet) {
  const todo = got.items.filter(it => inSheet[it.pos_order] && !it.in_sheet_tag && got.threadOf[it.pos_order]);
  if (!todo.length) return;
  const label = peddleLabel_();
  const threads = todo.map(it => got.threadOf[it.pos_order]);
  for (let i = 0; i < threads.length; i += 100) label.addToThreads(threads.slice(i, i + 100));
  todo.forEach(it => { it.in_sheet_tag = true; });
  console.log(`Tagged "${label.getName()}" on ${todo.length} thread(s): ${todo.map(it => it.pos_order).join(', ')}`);
}

/**
 * Two inboxes can append the same sale in the same instant (each has its own
 * script lock). Re-read Invoice # and delete any row for a sale THIS run wrote
 * that is not the first row for that invoice. Only ever touches invoices this
 * run just appended, never a row someone typed.
 */
function peddleDropRaceDupes_(sh, mine) {
  const want = {};
  mine.forEach(v => { want[v] = true; });
  const last = sh.getLastRow();
  if (last < 2) return;
  const vals = sh.getRange(2, PEDDLE_COL.INVOICE, last - 1, 1).getValues();
  const firstAt = {};
  const drop = [];
  vals.forEach((r, i) => {
    const v = String(r[0]).trim();
    if (!want[v]) return;
    if (firstAt[v] === undefined) firstAt[v] = i; else drop.push([i + 2, v]);
  });
  // bottom-up, and re-check each cell right before deleting it in case the
  // other inbox already removed a row and shifted everything up
  drop.reverse().forEach(([row, v]) => {
    if (String(sh.getRange(row, PEDDLE_COL.INVOICE).getValue()).trim() === v) sh.deleteRow(row);
  });
  if (drop.length) console.log(`Sheet: removed ${drop.length} duplicate row(s) written by another inbox.`);
}

function peddleRow_(it, r) {
  const num = v => (v === '' || v == null || isNaN(Number(v))) ? (v || '') : Number(v);
  const colL = c => peddleColLetter_(c);
  const profit = `=IF(${colL(PEDDLE_COL.TOTAL_COST)}${r}="","",` +
                 `${colL(PEDDLE_COL.GRAND_TOTAL)}${r}-${colL(PEDDLE_COL.TOTAL_COST)}${r})`;
  return [
    peddleDate_(it.event_dt) || '',   // A  Event Date & Time
    '', '', '',                       // B–D
    '', '', '',                       // E Email, F Password, G URL
    '', '', '', '',                   // H Address, I City, J State, K Zip Code
    it.event_name,                    // L  Event
    it.venue,                         // M  Venue
    num(it.section),                  // N  Section
    num(it.row),                      // O  Row
    num(it.seat_start),               // P  Start Seat
    num(it.seat_end),                 // Q  End Seat
    num(it.qty),                      // R  Quantity
    num(it.price_each),               // S  Price per Ticket
    num(it.total),                    // T  GrandTotal Amount
    '',                               // U  Total Cost
    profit,                           // V  Profit
    '', '',                           // W Customer Name, X Customer Email
    String(it.pos_order),             // Y  Invoice #
    String(it.site_order),            // Z  Site Order#
    it.site,                          // AA Site
    '', '',                           // AB City, AC State
  ];
}

/** "2026-11-28T23:59:00" -> Date shown as that wall-clock time in the sheet. */
function peddleDate_(iso) {
  const m = String(iso || '').match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/);
  return m ? new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]) : null;
}

function peddleColLetter_(n) {
  let s = '';
  while (n > 0) { const r = (n - 1) % 26; s = String.fromCharCode(65 + r) + s; n = Math.floor((n - 1) / 26); }
  return s;
}

/* ─────────────────────────────────────────────────────────────────────────
 * SUPABASE
 * ───────────────────────────────────────────────────────────────────────── */

function peddleSendSupabase_(items) {
  const props = PropertiesService.getScriptProperties();
  const url    = props.getProperty('SUPABASE_PROJECT_URL');
  const anon   = props.getProperty('SUPABASE_ANON_KEY');
  const secret = props.getProperty('APPSCRIPT_INGEST_SECRET');
  if (!url || !anon || !secret) {
    console.error('Missing Supabase config. Run setPeddlingConfig() first.');
    return;
  }
  const res = UrlFetchApp.fetch(url.replace(/\/+$/, '') + '/rest/v1/rpc/' + PEDDLE.RPC, {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: anon.trim(), Authorization: 'Bearer ' + anon.trim() },
    payload: JSON.stringify({ p_items: items, p_shared_secret: secret.trim() }),
    muteHttpExceptions: true,
  });
  const code = res.getResponseCode();
  if (code < 200 || code >= 300) {
    console.error(`Supabase ingest failed: HTTP ${code} ${res.getContentText().slice(0, 500)}`);
    return;
  }
  console.log('Supabase ingest: ' + res.getContentText());
}

/* ─────────────────────────────────────────────────────────────────────────
 * TRIGGER
 * ───────────────────────────────────────────────────────────────────────── */

function installPeddlingTrigger() {
  uninstallPeddlingTrigger();
  ScriptApp.newTrigger('syncPeddlingSales').timeBased().everyMinutes(5).create();
  console.log('Installed: syncPeddlingSales every 5 minutes.');
}

function uninstallPeddlingTrigger() {
  ScriptApp.getProjectTriggers().forEach(t => {
    if (t.getHandlerFunction() === 'syncPeddlingSales') ScriptApp.deleteTrigger(t);
  });
}
