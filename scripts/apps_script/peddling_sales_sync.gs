/**
 * ============================================================================
 * PEDDLING SALES → GOOGLE SHEET + SUPABASE
 * ============================================================================
 *
 * Install in ANY mailbox that receives "[PACIOLAN] PEDDLING SALE RECEIVED"
 * emails (orders@, support@, a buyer's inbox, ...). It is standalone, and
 * several inboxes can run it at once against the SAME sheet + Supabase: the
 * sheet is deduped on Invoice #, Supabase upserts on the order number.
 * The default Gmail query keys on the subject only (forwarded copies match);
 * override it per inbox with the PEDDLE_QUERY script property.
 *
 * Every 5 minutes, syncPeddlingSales():
 *   1. finds the recent PEDDLING SALE RECEIVED emails (PEDDLE.LOOKBACK) and
 *      parses each one;
 *   2. upserts them into Supabase (public.peddling_sales_ingest_from_apps_script,
 *      migs 20261109172023 + 20261109174437). The reply carries what our
 *      marketplace order books add for each sale: customer name + email
 *      (Vivid Seats), the event's city + state, and the marketplace status;
 *   3. writes each new sale into the first EMPTY row of the sheet (a row with
 *      nothing in any cell). Rows with anything in them are never touched;
 *   4. for every sale already in the sheet (matched on Invoice #), fills only
 *      the cells of our columns that are still EMPTY — it never overwrites a
 *      value someone typed or a formula;
 *   5. tags the Gmail thread of every sale in the sheet "Peddling/In Sheet".
 *
 * Columns are found BY HEADER NAME in row 1, so the order can change. Used:
 *   Event, Venue, Section, Row, Start Seat, End Seat, Quantity,
 *   Price per Ticket, GrandTotal Amount, Profit (formula, only if empty),
 *   Customer Name, Customer Email, Invoice # (required), Site Order#, Site,
 *   City / State (Event)  — the SECOND "City" column, and "State (Event)",
 *   Status, Sale Date, TU Ticket #, TNOW Ticket #,
 *   Event date — a header containing "Event Date", else column A when A1 is
 *   blank.
 * Left for people: Account Name, First/Last Name, Email, Password, Last 4,
 * Confirmation, URL, Address, the first City / State, Zip Code, Total Cost.
 *
 * Gmail: the ONLY change this script makes is adding the "In Sheet" label.
 * A thread that already carries it is never written to the sheet again, so a
 * row deleted by hand stays deleted.
 *
 * Setup (once):
 *   1. setPeddlingConfig()  — stores the sheet settings. Paste the anon key /
 *      secret only if this project doesn't have them yet (left as PASTE_…
 *      the stored value is kept). peddlingShowConfig() shows what's set.
 *   2. peddlingCheckSheet() — logs which column each field maps to and how
 *      many empty rows there are. Writes nothing.
 *   3. peddlingPreview()    — parses the emails and logs them. Writes nothing.
 *   4. installPeddlingTrigger() — every 5 minutes.
 *   5. backfillPeddlingSales() — once, to fill this sheet with the last 60 days
 *      (it also writes sales already tagged for an earlier sheet).
 *   One-off: repairPeddlingSeats() — fixes Vivid Seats rows written before
 *   the parser fix (Start/End Seat held "Site Order # … Seats 23-25").
 *
 * Script properties:
 *   PEDDLE_SHEET_ID          — spreadsheet id (default: PEDDLE.SHEET_ID)
 *   PEDDLE_SHEET_GID         — tab id, the "gid=" in its URL (default: PEDDLE.SHEET_GID)
 *   PEDDLE_SHEET_TAB         — tab NAME; overrides the gid when set
 *   PEDDLE_LABEL             — Gmail label for sales in the sheet
 *   PEDDLE_QUERY             — optional Gmail search override for this inbox
 *   SUPABASE_PROJECT_URL     — https://hzrizjeaxlqcxfrtczpq.supabase.co
 *   SUPABASE_ANON_KEY        — public anon key (PostgREST)
 *   APPSCRIPT_INGEST_SECRET  — shared secret checked by the RPC (vault)
 * ============================================================================
 */

const PEDDLE = {
  QUERY: 'subject:"PEDDLING SALE RECEIVED"',
  LOOKBACK: '3d',          // regular sync window
  BACKFILL: '60d',         // backfillPeddlingSales() window
  PAGE: 100,
  MAX_THREADS: 2000,
  SHEET_ID: '15BPX6ZLB0uCGfzVYVPm63tvnG_1HbH37OVfaMPHIlHU',
  SHEET_GID: 1691718237,
  LABEL: 'Peddling/In Sheet',
  RPC: 'peddling_sales_ingest_from_apps_script',
  DATE_FMT: 'm/d/yyyy h:mm AM/PM',
  // written only when the tab is completely empty
  HEADER: [
    'Event Date & Time', 'Account Name', 'First Name', 'Last Name', 'Email',
    'Password', 'Last 4', 'Confirmation', 'URL', 'Address', 'City', 'State',
    'Zip Code', 'Event', 'Venue', 'Section', 'Row', 'Start Seat', 'End Seat',
    'Quantity', 'Price per Ticket', 'GrandTotal Amount', 'Total Cost', 'Profit',
    'Customer Name', 'Customer Email', 'Invoice #', 'Site Order#', 'Site',
    'City', 'State (Event)', 'Status', 'Sale Date', 'TU Ticket #', 'TNOW Ticket #',
  ],
};

/* ─────────────────────────────────────────────────────────────────────────
 * CONFIG — run ONCE, then blank the literal values so they don't sit in source.
 * ───────────────────────────────────────────────────────────────────────── */

function setPeddlingConfig() {
  const literals = {
    'PEDDLE_SHEET_ID'         : '15BPX6ZLB0uCGfzVYVPm63tvnG_1HbH37OVfaMPHIlHU',
    'PEDDLE_SHEET_GID'        : '1691718237',
    'PEDDLE_LABEL'            : 'Peddling/In Sheet',
    'PEDDLE_QUERY'            : 'subject:"PEDDLING SALE RECEIVED"',
    'SUPABASE_PROJECT_URL'    : 'https://hzrizjeaxlqcxfrtczpq.supabase.co',
    'SUPABASE_ANON_KEY'       : 'PASTE_SUPABASE_ANON_KEY_HERE',
    'APPSCRIPT_INGEST_SECRET' : 'PASTE_APPSCRIPT_INGEST_SECRET_HERE',
  };
  // A placeholder left as PASTE_… keeps the value already stored, so moving to
  // a new sheet needs no keys re-pasted. (Projects with 50+ properties can't
  // edit them in Project Settings — this is the way to change them.)
  const props = PropertiesService.getScriptProperties();
  const set = {};
  const missing = [];
  Object.keys(literals).forEach(k => {
    if (!/^PASTE_/.test(literals[k])) set[k] = literals[k];
    else if (!(props.getProperty(k) || '').trim()) missing.push(k);
  });
  if (missing.length) throw new Error('Not stored yet — replace these placeholders and run again: ' + missing.join(', '));
  props.setProperties(set, false);
  props.deleteProperty('PEDDLE_SHEET_TAB');   // the gid picks the tab now
  console.log('Stored: ' + Object.keys(set).join(', ') + '. Kept existing: ' +
              Object.keys(literals).filter(k => !set[k]).join(', ') + '.');
  peddlingShowConfig();
}

/** Logs this script's peddling settings (keys masked). Writes nothing. */
function peddlingShowConfig() {
  const props = PropertiesService.getScriptProperties();
  ['PEDDLE_SHEET_ID', 'PEDDLE_SHEET_GID', 'PEDDLE_SHEET_TAB', 'PEDDLE_LABEL', 'PEDDLE_QUERY',
   'SUPABASE_PROJECT_URL', 'SUPABASE_ANON_KEY', 'APPSCRIPT_INGEST_SECRET'].forEach(k => {
    let v = props.getProperty(k);
    if (v && /KEY|SECRET/.test(k)) v = v.slice(0, 4) + '… (' + v.length + ' chars)';
    console.log(`  ${k.padEnd(24)} ${v == null ? '(not set)' : v}`);
  });
}

/* ─────────────────────────────────────────────────────────────────────────
 * ENTRY POINTS
 * ───────────────────────────────────────────────────────────────────────── */

function syncPeddlingSales() { peddleRun_(PEDDLE.LOOKBACK); }

/**
 * Same as a sync over 60 days, except it also writes sales whose thread is
 * already tagged: use it to fill a NEW sheet (every thread tagged for the old
 * one would otherwise be skipped). Still only empty rows / empty cells, and
 * still never a second row for an Invoice # the sheet already has.
 */
function backfillPeddlingSales() { peddleRun_(PEDDLE.BACKFILL, { ignoreTag: true }); }

/** Parse recent emails and log them. Writes nothing anywhere. */
function peddlingPreview() {
  const got = peddleCollect_(PEDDLE.LOOKBACK);
  console.log(`${got.items.length} sale(s) from ${got.threads} thread(s); unparsed: ${got.unparsed.length}`);
  console.log(`Already tagged "${peddleLabelName_()}": ${got.items.filter(it => it.in_sheet_tag).length}`);
  got.items.slice(0, 25).forEach(it => console.log(JSON.stringify(it)));
  if (got.unparsed.length) console.log('Unparsed message ids: ' + got.unparsed.join(', '));
}

/** Log the tab, the column each field maps to, and the empty-row count. Writes nothing. */
function peddlingCheckSheet() {
  const sh = peddleSheet_();
  const ctx = peddleSheetCtx_(sh);
  console.log(`Tab "${sh.getName()}" (gid ${sh.getSheetId()}), ${ctx.width} header column(s), ` +
              `${ctx.rows.length} data row(s) read, ${ctx.rows.filter(r => r.empty).length} empty.`);
  Object.keys(PEDDLE_FIELDS).forEach(k => {
    const c = ctx.cols[k];
    console.log(`  ${k.padEnd(10)} → ${c ? peddleColLetter_(c) + ' "' + ctx.header[c - 1] + '"' : '(no column — not written)'}`);
  });
  if (!ctx.cols.invoice) console.error('No "Invoice #" column: the sync will not write to this tab.');
}

/** Write the header row if the tab is completely empty. */
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

/**
 * One-off fix for rows written before the "Vivid Seats" parser fix: their
 * Start/End Seat cells hold "Site Order # … Seats 23-25". Takes the trailing
 * "Seats X-Y" from such a cell and rewrites Start/End Seat. Touches no other
 * cell and no row whose seats already look right.
 */
function repairPeddlingSeats() {
  const sh = peddleSheet_();
  const ctx = peddleSheetCtx_(sh);
  const cs = ctx.cols.startSeat, ce = ctx.cols.endSeat;
  if (!cs || !ce) { console.error('No Start Seat / End Seat column.'); return; }
  let fixed = 0;
  ctx.rows.forEach(r => {
    const a = String(r.values[cs - 1]), b = String(r.values[ce - 1]);
    if (!/Seats\s/i.test(a) && !/Seats\s/i.test(b)) return;
    const m = (/Seats\s/i.test(a) ? a : b).match(/Seats\s+([A-Za-z]*\d+)(?:\s*-\s*([A-Za-z]*\d+))?\s*$/i);
    if (!m) return;
    const n = v => (/^\d+$/.test(v) ? Number(v) : v);
    sh.getRange(r.row, cs).setValue(n(m[1]));
    sh.getRange(r.row, ce).setValue(n(m[2] || m[1]));
    fixed++;
  });
  console.log(`repairPeddlingSeats: fixed ${fixed} row(s).`);
}

function peddleRun_(window, opts) {
  opts = opts || {};
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(30 * 1000)) { console.warn('Another run is in progress; skipping.'); return; }
  try {
    const got = peddleCollect_(window);
    console.log(`Peddling: ${got.items.length} sale(s) from ${got.threads} thread(s)` +
                (got.unparsed.length ? `; unparsed: ${got.unparsed.join(', ')}` : ''));
    if (!got.items.length) return;

    // Supabase first: its reply carries customer / event city / status.
    let extra = {};
    try { extra = peddleSendSupabase_(got.items) || {}; }
    catch (e) { console.error('Supabase send failed: ' + (e && e.stack || e)); }

    try {
      const inSheet = peddleWriteSheet_(got.items, extra, opts);
      peddleTag_(got, inSheet);
    } catch (e) { console.error('Sheet write / tagging failed: ' + (e && e.stack || e)); }
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
  // Ticket fields are read only from the part AFTER "Ticket Details": the
  // header part holds the site name, and "Vivid Seats" would otherwise be
  // read as the Seats field (it was, in the first run).
  const td = t.search(/ Ticket Details /i);
  const d = td >= 0 ? t.slice(td) : t;
  const getD = re => { const m = d.match(re); return m ? m[1].trim() : ''; };
  const DT = '(\\d{1,2}\\/\\d{1,2}\\/\\d{4}\\s+\\d{1,2}:\\d{2}\\s*[AP]M)';

  let pos = get(/Order #\s*(\d+)/);
  if (!pos) { const m = String(subject).match(/RECEIVED\s+(\d+)/i); pos = m ? m[1] : ''; }
  if (!pos) return null;

  let eventName = getD(/ Event\s+(?!Date\b)(.+?)\s+Venue\s/);
  if (!eventName) {
    const m = String(subject).match(/\|\s*(.+?)\/[0-9a-f-]{36}\s*$/i);
    eventName = m ? m[1].trim() : '';
  }
  const src = get(/\[([A-Z0-9 _-]+)\]\s*PEDDLING/i) ||
              (String(subject).match(/\[([A-Z0-9 _-]+)\]/i) || [])[1] || 'PACIOLAN';

  const seats = getD(/ Row\s+.+?\s+Seats\s+(.*?)\s+Qty\s/);
  const sm = seats.match(/^\s*([A-Za-z]*\d+)\s*-\s*([A-Za-z]*\d+)\s*$/);
  const qty = getD(/ Qty\s+(\d+)/);

  return {
    pos_order:   pos,
    source:      src.toUpperCase(),
    sale_dt:     peddleLocalIso_(get(new RegExp('Sale Date\\s+' + DT, 'i'))),
    site:        get(/ Site\s+(.+?)\s+Site Order #/),
    site_order:  get(/Site Order #\s*(\S+)/),
    tnow_ticket: getD(/TNOW Ticket #\s*(\S+)/),
    tu_ticket:   getD(/TU Ticket #\s*(\S+)/),
    event_dt:    peddleLocalIso_(getD(new RegExp('Event Date\\s+' + DT, 'i'))),
    event_name:  eventName,
    venue:       getD(/ Venue\s+(.+?)\s+Section\s/),
    section:     getD(/ Section\s+(.+?)\s+Row\s/),
    row:         getD(/ Row\s+(.+?)\s+Seats\s/),
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
 * GOOGLE SHEET — columns by header name, only empty rows / empty cells
 * ───────────────────────────────────────────────────────────────────────── */

// field → header names it answers to (compared lower-case, letters/digits/#/() only)
const PEDDLE_FIELDS = {
  eventDt:    ['eventdatetime', 'eventdate', 'eventdateandtime'],
  event:      ['event'],
  venue:      ['venue'],
  section:    ['section'],
  row:        ['row'],
  startSeat:  ['startseat'],
  endSeat:    ['endseat'],
  qty:        ['quantity', 'qty'],
  price:      ['priceperticket'],
  total:      ['grandtotalamount', 'grandtotal'],
  totalCost:  ['totalcost'],
  profit:     ['profit'],
  custName:   ['customername'],
  custEmail:  ['customeremail'],
  invoice:    ['invoice#', 'invoice'],
  siteOrder:  ['siteorder#', 'siteorder'],
  site:       ['site'],
  eventCity:  ['city(event)', 'eventcity'],
  eventState: ['state(event)', 'eventstate'],
  status:     ['status'],
  saleDate:   ['saledate'],
  tu:         ['tuticket#', 'tuticket'],
  tnow:       ['tnowticket#', 'tnowticket'],
};
// a row counts as already-used if any of these has something in it
const PEDDLE_KEYS = ['event', 'invoice', 'siteOrder', 'site', 'venue'];

function peddleSheet_() {
  const props = PropertiesService.getScriptProperties();
  const ss = SpreadsheetApp.openById(props.getProperty('PEDDLE_SHEET_ID') || PEDDLE.SHEET_ID);
  const tab = props.getProperty('PEDDLE_SHEET_TAB');
  if (tab) {
    const byName = ss.getSheetByName(tab);
    if (!byName) throw new Error(`No tab named "${tab}".`);
    return byName;
  }
  const gid = Number(props.getProperty('PEDDLE_SHEET_GID') || PEDDLE.SHEET_GID);
  const byGid = ss.getSheets().find(sh => sh.getSheetId() === gid);
  if (!byGid) throw new Error(`No tab with gid ${gid}. Set PEDDLE_SHEET_GID or PEDDLE_SHEET_TAB.`);
  return byGid;
}

function peddleNorm_(s) { return String(s || '').toLowerCase().replace(/[^a-z0-9#()]/g, ''); }

/** Header map + every data row's values/formulas. */
function peddleSheetCtx_(sh) {
  const lastCol = Math.max(sh.getLastColumn(), 1);
  const header = sh.getRange(1, 1, 1, lastCol).getValues()[0].map(v => String(v).trim());
  // trailing blank headers are not columns of ours
  let width = header.length;
  while (width > 1 && !header[width - 1]) width--;

  const at = {};                                   // normalised name → [col, col, …]
  header.slice(0, width).forEach((h, i) => { const k = peddleNorm_(h); if (k) (at[k] = at[k] || []).push(i + 1); });
  const cols = {};
  Object.keys(PEDDLE_FIELDS).forEach(f => {
    for (const name of PEDDLE_FIELDS[f]) if (at[name]) { cols[f] = at[name][0]; break; }
  });
  // the SECOND City / State column is the event's (the first is the buyer's address)
  if (!cols.eventCity  && at.city  && at.city.length  > 1) cols.eventCity  = at.city[1];
  if (!cols.eventState && at.state && at.state.length > 1) cols.eventState = at.state[1];
  // event date: column A when its header is blank
  if (!cols.eventDt && !header[0]) cols.eventDt = 1;

  const last = sh.getLastRow();
  const rows = [];
  if (last >= 2) {
    const rng = sh.getRange(2, 1, last - 1, width);
    const vals = rng.getValues(), fx = rng.getFormulas();
    vals.forEach((v, i) => {
      // empty = no value in any column (a formula that shows "" counts as empty)
      const empty = v.every(x => x === '' || x === null);
      rows.push({ row: i + 2, values: v, formulas: fx[i], empty });
    });
  }
  return { header, width, cols, rows };
}

/**
 * Writes new sales into empty rows and fills empty cells of rows already in
 * the sheet. Returns the set of Invoice #s now in the sheet.
 */
function peddleWriteSheet_(items, extra, opts) {
  opts = opts || {};
  const sh = peddleSheet_();
  if (sh.getLastRow() === 0) setupPeddlingSheet();
  const ctx = peddleSheetCtx_(sh);
  if (!ctx.cols.invoice) {
    throw new Error('No "Invoice #" column in row 1 of this tab. Nothing written — run peddlingCheckSheet().');
  }
  const ic = ctx.cols.invoice;
  const byInvoice = {};
  ctx.rows.forEach(r => { const v = String(r.values[ic - 1]).trim(); if (v && !byInvoice[v]) byInvoice[v] = r; });

  // 1. fill the empty cells of sales already in the sheet
  let filled = 0;
  items.forEach(it => {
    const r = byInvoice[it.pos_order];
    if (r) filled += peddleFillRow_(sh, ctx, r, it, extra[it.pos_order]);
  });

  // 2. new sales → first empty rows (never a row with anything in it).
  //    Already tagged = it went to the sheet before; if its row is gone now,
  //    someone deleted it on purpose, so don't put it back.
  const fresh = items.filter(it => !byInvoice[it.pos_order] && !it.cancelled && (opts.ignoreTag || !it.in_sheet_tag));
  const free = ctx.rows.filter(r => r.empty);
  let nextRow = Math.max(sh.getLastRow(), 1) + 1;
  const written = [];
  fresh.forEach(it => {
    let r = free.shift();
    // another inbox may have used it since we read the sheet: re-check
    while (r && !peddleRowStillEmpty_(sh, ctx, r.row)) r = free.shift();
    if (!r) {
      if (nextRow > sh.getMaxRows()) sh.insertRowsAfter(sh.getMaxRows(), 50);
      r = { row: nextRow++, values: new Array(ctx.width).fill(''), formulas: new Array(ctx.width).fill(''), empty: true };
    }
    peddleFillRow_(sh, ctx, r, it, extra[it.pos_order]);
    byInvoice[it.pos_order] = r;
    written.push(it.pos_order + '→row ' + r.row);
  });
  SpreadsheetApp.flush();
  console.log(`Sheet: ${written.length} new sale(s)${written.length ? ': ' + written.join(', ') : ''}; ` +
              `${filled} empty cell(s) filled on existing rows.`);
  if (written.length) peddleUndoRaceDupes_(sh, ctx, fresh.map(it => it.pos_order));

  const have = {};
  Object.keys(byInvoice).forEach(k => { have[k] = true; });
  return have;
}

/** The value each of our fields gets for a sale (undefined = leave alone). */
function peddleFieldValues_(ctx, it, ex, rowNum) {
  const num = v => (v === '' || v == null || isNaN(Number(v))) ? (v || '') : Number(v);
  const L = f => ctx.cols[f] ? peddleColLetter_(ctx.cols[f]) : null;
  ex = ex || {};
  const out = {
    eventDt:    peddleDate_(it.event_dt) || '',
    event:      it.event_name,
    venue:      it.venue,
    section:    num(it.section),
    row:        num(it.row),
    startSeat:  num(it.seat_start),
    endSeat:    num(it.seat_end),
    qty:        num(it.qty),
    price:      num(it.price_each),
    total:      num(it.total),
    custName:   ex.customer_name || '',
    custEmail:  ex.customer_email || '',
    invoice:    String(it.pos_order),
    siteOrder:  String(it.site_order || ''),
    site:       it.site,
    eventCity:  ex.event_city || '',
    eventState: ex.event_state || '',
    status:     ex.status || (it.cancelled ? 'Cancelled' : ''),
    saleDate:   peddleDate_(it.sale_dt) || '',
    tu:         String(it.tu_ticket || ''),
    tnow:       String(it.tnow_ticket || ''),
  };
  if (L('total') && L('totalCost')) {
    out.profit = `=IF(${L('totalCost')}${rowNum}="","",${L('total')}${rowNum}-${L('totalCost')}${rowNum})`;
  }
  return out;
}

/** Writes our fields into the EMPTY cells of one row. Returns cells written. */
function peddleFillRow_(sh, ctx, r, it, ex) {
  const want = peddleFieldValues_(ctx, it, ex, r.row);
  const put = {};                                  // col → value
  Object.keys(want).forEach(f => {
    const c = ctx.cols[f], v = want[f];
    if (!c || v === '' || v == null) return;
    const cur = r.values[c - 1], fx = r.formulas[c - 1];
    if ((cur !== '' && cur !== null) || fx) return; // only empty cells, never a formula
    put[c] = v;
  });
  const cs = Object.keys(put).map(Number).sort((a, b) => a - b);
  // one write per run of adjacent columns
  for (let i = 0; i < cs.length;) {
    let j = i;
    while (j + 1 < cs.length && cs[j + 1] === cs[j] + 1) j++;
    sh.getRange(r.row, cs[i], 1, j - i + 1).setValues([cs.slice(i, j + 1).map(c => put[c])]);
    i = j + 1;
  }
  ['eventDt', 'saleDate'].forEach(f => {
    const c = ctx.cols[f];
    if (c && put[c] instanceof Date) sh.getRange(r.row, c).setNumberFormat(PEDDLE.DATE_FMT);
  });
  cs.forEach(c => { r.values[c - 1] = put[c]; });
  return cs.length;
}

function peddleRowStillEmpty_(sh, ctx, row) {
  return sh.getRange(row, 1, 1, ctx.width).getValues()[0].every(x => x === '' || x === null);
}

/**
 * Two inboxes can write the same sale in the same instant (each has its own
 * script lock). If an invoice this run just wrote now sits in an EARLIER row
 * too, clear the cells of our (later) row again. Only cells that still hold
 * exactly what we wrote are cleared; no row is ever deleted.
 */
function peddleUndoRaceDupes_(sh, ctx, mine) {
  const now = peddleSheetCtx_(sh);
  const ic = now.cols.invoice;
  const seen = {};
  let undone = 0;
  now.rows.forEach(r => {
    const v = String(r.values[ic - 1]).trim();
    if (!v || mine.indexOf(v) < 0) return;
    if (!seen[v]) { seen[v] = true; return; }
    sh.getRange(r.row, 1, 1, now.width).clearContent();
    undone++;
  });
  if (undone) console.log(`Sheet: cleared ${undone} duplicate row(s) written at the same moment by another inbox.`);
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

/* ─────────────────────────────────────────────────────────────────────────
 * SUPABASE
 * ───────────────────────────────────────────────────────────────────────── */

/** Upserts the sales; returns { pos_order: {customer_name, …} } from the reply. */
function peddleSendSupabase_(items) {
  const props = PropertiesService.getScriptProperties();
  const url    = props.getProperty('SUPABASE_PROJECT_URL');
  const anon   = props.getProperty('SUPABASE_ANON_KEY');
  const secret = props.getProperty('APPSCRIPT_INGEST_SECRET');
  if (!url || !anon || !secret) {
    console.error('Missing Supabase config. Run setPeddlingConfig() first.');
    return {};
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
    return {};
  }
  const body = JSON.parse(res.getContentText() || '{}');
  const extra = {};
  (body.rows || []).forEach(r => { extra[String(r.pos_order)] = r; });
  const withCust = (body.rows || []).filter(r => r.customer_email || r.customer_name).length;
  console.log(`Supabase ingest: received ${body.received}, inserted ${body.inserted}, updated ${body.updated}; ` +
              `customer found for ${withCust}, status for ${(body.rows || []).filter(r => r.status).length}.`);
  return extra;
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
