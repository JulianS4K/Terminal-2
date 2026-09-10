// D0 Terminal — Substitution checker + QUEUE.
//
// The page is push-first: NEED TO SUB lists every open obligation with its
// cover where one exists, refreshing itself every 60s, so work arrives instead
// of being asked for.
//
// The SUB QUEUE panel was removed 2026-09-10 (operator direction: "only keep
// n2s"). That queue hunted OPTIONAL profitable swaps across our own healthy
// order book; this page is now only about orders that already FAILED and must
// be covered. /api/broker/sub-worklist and its 10-minute refresh cron still
// exist server-side but nothing on this page reads them.
//
//   GET /api/broker/n2s-covers?source=&days=&limit=&offset=
//   GET /api/broker/n2s-covers/verify?freshness_minutes=
//   POST /api/broker/n2s-covers/{n2s_id}/buy-intent   (records intent; buys nothing)
//     -> { rows:[...], count, covered, uncovered, by_no_cover_reason,
//          refreshed_at, filters }
//
// A cover row carries only the ALLOCATED listing — it is precomputed state,
// not the last word. The checker below recomputes live per order and carries
// the GA / splits / ambiguous handling a summary row cannot represent.
//
// The order-# lookup and the manual entry form stay: a list is for sweeping
// the book, but covering a specific order someone just called about still has
// to be one box you can paste into.
//
//   GET /api/broker/event/{id}/substitutions
//        ?section=&row=&quantity=&revenue=&source=owned|market
//     -> { target, subs:[...], ambiguous:[...], section_subs:{...},
//          best, counts, captured_at, source, pools, gt_captured_at }
//
// source=market spans both books we can buy from — the TEvo exchange and
// GoTickets — so a sub carries `inv_source` and, for GoTickets, a `buy_url`
// straight to the section page.
//
// Pure read-only; matching/ranking lives server-side in core.substitutions.
// The page can be deep-linked with ?event=&section=&row=&quantity= (e.g. from
// an order strip) and will auto-run when section is present.

(function () {
  'use strict';
  const T = window.Terminal;

  function init() {
    const form = document.getElementById('subsForm');
    if (form) form.addEventListener('submit', onSubmit);
    wireOrderLoad();
    wireN2s();
    wireEventSearch();
    wireFeeToggle();
    prefillFromQuery();
  }

  // ---------- need-to-sub covers (push) ----------
  //
  // Orders that already FAILED and must be covered whether or not it pays.
  // ⚠ cover_cost is signed the OPPOSITE way to margin: positive means honouring
  // the order costs us that much. Sorting is cheapest-cover-first, never by
  // margin — the question is what the obligation settles for, not where the
  // profit is. (The profit-hunting SUB QUEUE that used to sit below was
  // removed; see the file header.)

  // The covers panel is a FEED, not a report you ask for. The pipeline rebuilds
  // n2s_cover_queue every 2 minutes, so a page that only loads on click shows
  // yesterday's answer to someone who left the tab open. Poll at 60s: never
  // more than about a minute behind a refresh, and cheap (one indexed read of
  // a materialised table).
  const N2S_POLL_MS = 60000;
  const n2sFeed = {
    timer: null,
    seen: null,      // n2s_ids from the previous payload; null = first load
    fresh: new Set(),// ids that arrived on the last poll
    verdicts: {},    // n2s_id -> { row, at, fp } from Verify
    claims: {},      // n2s_id -> { intent, fp } from Claim
  };

  // A cover is (order, listing, price). If any of those change the row is a
  // DIFFERENT offer, and anything we remembered about the old one — a verify
  // verdict, a claim — no longer describes what is on screen.
  function coverFp(r) {
    return [r.sub_source || '', r.sub_listing_id || '', r.sub_ea == null ? '' : r.sub_ea].join('|');
  }

  function wireN2s() {
    const btn = document.getElementById('n2sRun');
    if (btn) btn.addEventListener('click', () => loadN2s());
    const vbtn = document.getElementById('n2sVerify');
    if (vbtn) vbtn.addEventListener('click', verifyN2s);
    const pbtn = document.getElementById('n2sPull');
    if (pbtn) pbtn.addEventListener('click', () => pullN2s(pbtn));
    ['n2sSource', 'n2sDays', 'n2sHas', 'n2sLate'].forEach((id) => {
      const el = document.getElementById(id);
      // Changing a filter changes which book you are watching, so the "new
      // since last look" set is meaningless across it — reset rather than
      // flash every row as an arrival.
      if (el) el.addEventListener('change', () => { n2sFeed.seen = null; loadN2s(); });
    });
    if (!document.getElementById('n2sTable')) return;
    loadN2s();
    startN2sFeed();
  }

  // On-demand marketplace pull. The responses are asynchronous, so there is
  // nothing to render on return — report what was dispatched and let the 60s
  // feed pick the covers up. A press that dispatches nothing is the five-minute
  // per-event guard working; say so plainly rather than looking broken.
  async function pullN2s(btn) {
    const label = btn.textContent;
    btn.disabled = true;
    btn.textContent = 'Pulling…';
    try {
      const r = await T.api('/api/broker/n2s-covers/pull', { method: 'POST' });
      const d = r.dispatched || {};
      const sent = (d.tevo || 0) + (d.gotickets || 0) + (d.seatgeek || 0);
      const meta = document.getElementById('n2sMeta');
      if (meta) {
        meta.textContent = sent
          ? `pulling ${sent} request${sent === 1 ? '' : 's'} across ${r.events || 0} event${r.events === 1 ? '' : 's'} — covers update as they land`
          : 'already current — every event was pulled within the last 5 minutes';
      }
    } catch (e) {
      const meta = document.getElementById('n2sMeta');
      if (meta) meta.textContent = `pull failed: ${e && e.message ? e.message : 'unknown error'}`;
    } finally {
      btn.disabled = false;
      btn.textContent = label;
    }
  }

  function startN2sFeed() {
    stopN2sFeed();
    n2sFeed.timer = setInterval(() => loadN2s({ background: true }), N2S_POLL_MS);
    setN2sLive(true);
  }

  function stopN2sFeed() {
    if (n2sFeed.timer) clearInterval(n2sFeed.timer);
    n2sFeed.timer = null;
  }

  // A hidden tab must not keep polling — it is work nobody is looking at, and
  // on wake the browser fires every queued timer at once. Pause, then refresh
  // ONCE on return so what you come back to is current rather than however
  // stale it was when you left.
  document.addEventListener('visibilitychange', () => {
    if (!document.getElementById('n2sTable')) return;
    if (document.hidden) { stopN2sFeed(); setN2sLive(false); }
    else { loadN2s({ background: true }); startN2sFeed(); }
  });

  function setN2sLive(on) {
    const pill = document.getElementById('n2sLive');
    if (!pill) return;
    pill.classList.toggle('on', !!on);
    pill.classList.toggle('off', !on);
    const label = pill.querySelector('.live-label');
    if (label) label.textContent = on ? 'live' : 'paused';
  }

  async function loadN2s(opts) {
    const background = !!(opts && opts.background);
    const wrap = document.getElementById('n2sTable');
    const meta = document.getElementById('n2sMeta');
    if (!wrap) return;
    // Only an explicit refresh may blank the table. A background poll that
    // wiped it would clear a fill sheet someone is reading mid-purchase.
    if (!background) wrap.innerHTML = '<div class="empty">loading…</div>';
    const qs = new URLSearchParams({ limit: '200' });
    const src = (document.getElementById('n2sSource').value || '').trim();
    const days = (document.getElementById('n2sDays').value || '').trim();
    const has = (document.getElementById('n2sHas') || {}).value || '';
    const late = (document.getElementById('n2sLate') || {}).value || '';
    if (src) qs.set('source', src);
    if (days) qs.set('days', days);
    if (has) qs.set('with_sub', has);
    if (late) qs.set('include_late', late);
    try {
      const d = await T.api(`/api/broker/n2s-covers?${qs.toString()}`);
      renderN2s(d);
      if (background) setN2sLive(true);   // recovered from any earlier stall
      if (meta) {
        // refreshed_at is load-bearing: covers are only true while the listing
        // is live, and the matcher only looks an hour back. Always show it.
        const stamp = d.refreshed_at
          ? ` · ${esc(String(d.refreshed_at).slice(0, 16).replace('T', ' '))}`
          : ' · never refreshed';
        const disp = d.displaced ? ` · ${d.displaced} took a dearer cover` : '';
        const arrived = n2sFeed.fresh.size ? ` · ${n2sFeed.fresh.size} new` : '';
        const late = d.hidden_late ? ` · ${d.hidden_late} hidden (timer expired)` : '';
        // Lead with the shape of the book: how many can be acted on versus how
        // many are still open with nothing to act on. The second number is the
        // one that was invisible when this panel showed covers only.
        const why = Object.entries(d.by_no_cover_reason || {})
          .map(([k, n]) => `${n} ${k.replace(/_/g, ' ')}`).join(', ');
        meta.textContent = `${d.count} open · ${d.covered} with a sub`
          + ` · ${d.uncovered} without${why ? ` (${why})` : ''}`
          + ` · ${money(d.total_cover_cost)} to settle${disp}${late}${arrived}${stamp}`;
      }
    } catch (err) {
      const msg = err && err.message ? err.message : err;
      // A blip on a background poll is not a reason to destroy a good table.
      // Say it in the meta line and leave the last known covers on screen.
      if (background) {
        // The interval is still running, so the feed is NOT paused — say
        // stalled and leave the pill live, or one blip mislabels it forever.
        if (meta) meta.textContent = `feed stalled: ${msg}`;
      } else {
        wrap.innerHTML = emptyHtml(`covers unavailable: ${msg}`);
        if (meta) meta.textContent = '';
      }
    }
  }

  function renderN2s(d) {
    const wrap = document.getElementById('n2sTable');
    const rows = (d && d.rows) || [];
    // Which of these are arrivals? On the FIRST load nothing is new — every
    // row would flash, which is noise, not signal.
    const ids = new Set(rows.map((r) => String(r.n2s_id)));
    n2sFeed.fresh = new Set();
    if (n2sFeed.seen) {
      ids.forEach((id) => { if (!n2sFeed.seen.has(id)) n2sFeed.fresh.add(id); });
    }
    n2sFeed.seen = ids;
    forgetStaleN2sState(rows);
    if (!rows.length) {
      // ⚠ An empty page here is almost never "nothing needs covering". The
      // default hides every order whose 15-minute CRM timer lapsed, which is
      // nearly all of them, so saying only "no orders" would report a clear
      // book when the truth is the opposite. Name the count and the way back.
      const hidden = (d && d.hidden_late) || 0;
      wrap.innerHTML = emptyHtml(hidden
        ? `nothing shown — <strong>${hidden}</strong> open obligation${hidden === 1 ? '' : 's'} `
          + 'are hidden because their 15-minute CRM timer expired. '
          + 'Set <em>Timer</em> to “include late” to see them.'
        : 'no open N2S orders match these filters');
      return;
    }
    const body = rows.map((r) => {
      const seat = `${esc(r.section || '')} / ${esc(r.order_row || '')} ×${r.quantity || ''}`;
      // An uncovered row is the WORK, not an empty cell. Say which of the three
      // situations it is: "we never looked" and "we looked and found nothing"
      // call for opposite responses, and a bare dash hides the difference —
      // which is exactly how a mapping outage would go unnoticed here.
      const WHY = {
        unmapped: ['unmapped', 'the event could not be identified, so no source was searched'],
        awaiting_source_pull: ['pulling…', 'the four-source pull is in flight; give it ~2 minutes'],
        no_match: ['no match', 'listings were searched; none had the same section, an equal-or-better row and a usable quantity'],
      };
      // ⚠ A SPLIT TAKE MUST LOOK LIKE ONE. sub_qty is what we buy; sub_avail is
      // the listing's lot size. When the lot is bigger we are buying PART of
      // it — "2 of 4" — and showing only "2" would leave the operator to
      // discover at checkout that the listing is not the size they expected.
      // ⚠ AND SO MUST AN OVER-DELIVERY. The two are exclusive — a split take
      // buys PART of a bigger lot (sub_avail > sub_qty), an over-delivery buys
      // a WHOLE lot that is bigger than the obligation (sub_qty > quantity) —
      // and only the second one spends money on a seat we did not sell. It is
      // the costlier surprise, so it is the louder label.
      const lot = (() => {
        if (!r.has_cover || !r.sub_qty) return '';
        if (r.quantity && r.sub_qty > r.quantity) {
          const spare = r.sub_qty - r.quantity;
          return ` <span class="neg small" title="no listing sells exactly ${esc(String(r.quantity))} here, so the whole ${esc(String(r.sub_qty))}-seat lot is bought and ${esc(String(spare))} spare seat${spare === 1 ? '' : 's'} paid for">buy ${esc(String(r.sub_qty))}</span>`;
        }
        if (r.sub_avail && r.sub_avail > r.sub_qty) {
          return ` <span class="muted small" title="a ${esc(String(r.sub_avail))}-seat listing whose splits allow buying exactly ${esc(String(r.sub_qty))}">of ${esc(String(r.sub_avail))}</span>`;
        }
        return '';
      })();
      const cov = r.has_cover
        ? `${sourceBadge(r.sub_source)} ${esc(r.sub_section || '')} / ${esc(r.sub_row || '')}${lot}`
        : (() => {
            const w = WHY[r.no_cover_reason] || ['no sub', 'no cover allocated'];
            const cls = r.no_cover_reason === 'awaiting_source_pull' ? 'muted' : 'neg';
            return `<span class="${cls} small" title="${esc(w[1])}">${esc(w[0])}</span>`;
          })();
      // cover_rank > 1 means an earlier order claimed the cheaper listing.
      const bumped = (r.cover_rank || 1) > 1
        ? ' <span class="muted small" title="an earlier order claimed the cheaper listing">2nd choice</span>'
        : '';
      const claimed = '';  // shown in the action cell instead, next to the button
      const timer = r.timer_expired
        ? ' <span class="neg small" title="the N2S 15-minute timer has expired">late</span>'
        : '';
      // GoTickets gives us a deep link. TEvo and SeatGeek do not publish a
      // buy URL to us and there is no known console URL pattern, so rather
      // than guess a link that may 404 or point at the wrong listing, show the
      // two ids that locate it: the event and the ticket-group/listing id.
      // A dash here would hide information the row already carries.
      const buy = r.buy_url
        ? `<a href="${esc(r.buy_url)}" target="_blank" rel="noopener">buy</a>`
        : (r.sub_listing_id
            ? `<span class="muted small" title="event ${esc(String(r.tevo_event_id || ''))} · listing ${esc(String(r.sub_listing_id))}">`
              + `ev ${esc(String(r.tevo_event_id || '?'))}<br>lst ${esc(String(r.sub_listing_id))}</span>`
            : '<span class="muted">—</span>');
      // No cover means nothing to claim and nothing to verify. Offering the
      // button anyway would produce a 409 from the server, which is a worse
      // way to learn there is no sub than simply not showing it.
      // An order with an OPEN intent is already someone's. Offering the button
      // anyway would 409 off the one-open-intent-per-order index — the same
      // "learn by error" the no-cover branch above deliberately avoids.
      const action = !r.has_cover
        ? '<span class="muted">—</span>'
        : (r.open_intent_id
            ? `<span class="muted small" title="intent #${esc(String(r.open_intent_id))} by ${esc(r.open_intent_by || 'someone')}">claimed</span>`
            : `<button type="button" class="btn n2s-claim" data-n2s="${esc(String(r.n2s_id))}">claim</button>`);
      const isNew = n2sFeed.fresh.has(String(r.n2s_id));
      const chip = isNew ? ' <span class="n2s-new-chip">NEW</span>' : '';
      const rowCls = [isNew ? 'n2s-row-new' : '', r.has_cover ? '' : 'n2s-row-gap']
        .filter(Boolean).join(' ');
      return `<tr data-n2s="${esc(String(r.n2s_id))}" data-fp="${esc(coverFp(r))}"${rowCls ? ` class="${rowCls}"` : ''}>
        <td>${esc(r.s4k_source || '')}${chip}${timer}${claimed}</td>
        <td>${esc(r.event_name || '')}<div class="muted small">${esc(r.event_date || '')} · ${esc(r.venue || '')}</div></td>
        <td>${seat}</td>
        <td class="num">${money(r.sold_ea)}</td>
        <td>${cov}${bumped}</td>
        <td class="num">${r.has_cover ? money(r.sub_ea) : '<span class="muted">—</span>'}</td>
        <td class="num">${coverCell(r.cover_cost)}</td>
        <td>${buy}</td>
        <td class="n2s-verdict muted small">—</td>
        <td>${action}</td>
      </tr>`;
    }).join('');
    wrap.innerHTML = `<table class="subs-table"><thead><tr>
        <th>Src</th><th>Event</th><th>Failed seat</th><th class="num">Sold ea</th>
        <th>Sub / why not</th><th class="num">Sub ea</th><th class="num">Cost to settle</th><th></th><th>Verify</th><th></th>
      </tr></thead><tbody>${body}</tbody></table>`;
    wrap.querySelectorAll('.n2s-claim').forEach((b) => {
      b.addEventListener('click', () => claimN2s(b.getAttribute('data-n2s'), b));
    });
    restoreN2sState();
  }

  // A repaint every 60s would otherwise wipe a verdict you just asked for and
  // the fill sheet you are working from. Both are re-applied — but only where
  // they still describe what is on screen; see forgetStaleN2sState.
  function restoreN2sState() {
    const wrap = document.getElementById('n2sTable');
    if (!wrap) return;
    Object.entries(n2sFeed.verdicts).forEach(([id, v]) => {
      const tr = wrap.querySelector(`tr[data-n2s="${CSS.escape(id)}"]`);
      if (tr) paintVerdict(tr, v.row, v.at);
    });
    Object.entries(n2sFeed.claims).forEach(([id, c]) => {
      const tr = wrap.querySelector(`tr[data-n2s="${CSS.escape(id)}"]`);
      const btn = tr && tr.querySelector('.n2s-claim');
      if (!btn) return;
      btn.disabled = true;
      btn.textContent = 'claimed';
      btn.classList.add('pos');
      showFillSheet(btn, c.intent, c.moved);
    });
  }

  // ⚠ The queue reallocates. FIFO can hand this order's listing to an older
  // one between polls, and then a remembered verdict describes a listing that
  // is no longer on offer here. Showing it would be worse than showing
  // nothing: it reads as "checked and fine" about the wrong tickets.
  function forgetStaleN2sState(rows) {
    const fp = {};
    rows.forEach((r) => { fp[String(r.n2s_id)] = coverFp(r); });
    Object.keys(n2sFeed.verdicts).forEach((id) => {
      if (fp[id] !== n2sFeed.verdicts[id].fp) delete n2sFeed.verdicts[id];
    });
    Object.keys(n2sFeed.claims).forEach((id) => {
      // A claim is NOT dropped: the intent is frozen server-side against the
      // cover as it was, so it stays true even after the queue moves on. But
      // the row underneath now shows a different offer, and the sheet must say
      // so rather than looking like it describes the row it sits under.
      if (fp[id] !== undefined && fp[id] !== n2sFeed.claims[id].fp) {
        n2sFeed.claims[id].moved = true;
      }
    });
  }

  // Pre-purchase gate. Deliberately a BUTTON, not part of the page load: a
  // cover is only "good to buy" at the moment you ask, so verifying on render
  // would stamp a verdict that goes stale sitting on screen. Ask when acting.
  async function verifyN2s() {
    const meta = document.getElementById('n2sMeta');
    const wrap = document.getElementById('n2sTable');
    if (!wrap) return;
    try {
      const d = await T.api('/api/broker/n2s-covers/verify');
      const by = {};
      (d.rows || []).forEach((r) => { by[r.n2s_id] = r; });
      const at = Date.now();
      n2sFeed.verdicts = {};
      wrap.querySelectorAll('tr[data-n2s]').forEach((tr) => {
        const id = tr.getAttribute('data-n2s');
        const v = by[id];
        const cell = tr.querySelector('.n2s-verdict');
        if (!cell) return;
        if (!v) { cell.textContent = '—'; return; }
        // Remembered against the cover it was about, so the next repaint can
        // re-apply it — or drop it if the queue has moved to another listing.
        n2sFeed.verdicts[id] = { row: v, at: at, fp: rowFpFromTr(tr) };
        paintVerdict(tr, v, at);
      });
      if (meta) {
        const parts = Object.entries(d.by_verdict || {})
          .map(([k, n]) => `${n} ${k}`).join(' · ');
        meta.textContent = `verified ${d.count} · ${d.buyable} buyable`
          + (parts ? ` · ${parts}` : '');
      }
    } catch (err) {
      if (meta) meta.textContent = `verify failed: ${err && err.message ? err.message : err}`;
    }
  }

  // A verdict is only true at the moment it was asked for, so it carries its
  // age once it is no longer fresh. Sitting on screen looking authoritative is
  // exactly the failure the Verify button was made a button to avoid.
  function paintVerdict(tr, v, at) {
    const cell = tr.querySelector('.n2s-verdict');
    if (!cell) return;
    // gone / order_closed are hard blocks; stale_data means "cannot tell",
    // which must not be shown as reassurance.
    const cls = v.buyable ? (v.verdict === 'price_up' ? 'warn' : 'pos') : 'neg';
    const delta = (v.price_delta_ea !== null && v.price_delta_ea !== undefined
                   && Number(v.price_delta_ea) !== 0)
      ? ` ${Number(v.price_delta_ea) > 0 ? '+' : ''}${money(v.price_delta_ea)}` : '';
    const secs = at ? Math.round((Date.now() - at) / 1000) : 0;
    const age = secs >= 90 ? ` <span class="muted">${Math.round(secs / 60)}m ago</span>` : '';
    cell.innerHTML = `<span class="${cls}">${esc(v.verdict || '?')}${delta}</span>${age}`;
  }

  // The fingerprint as the CURRENT row renders it, read back off the DOM so
  // the verdict is tied to the offer the user actually looked at.
  function rowFpFromTr(tr) {
    return tr.getAttribute('data-fp') || '';
  }

  // Records that someone is acting on this cover and hands them the fill
  // sheet. It does NOT buy: nothing in this codebase places an order — the
  // purchase is made by hand in the vendor console, for both TEvo and
  // GoTickets. The intent exists to stop two people covering the same
  // obligation and to keep an audit trail of who committed to what price.
  async function claimN2s(n2sId, btn) {
    if (!n2sId) return;
    btn.disabled = true;
    const prev = btn.textContent;
    btn.textContent = '…';
    try {
      // Without requested_by every intent stores NULL and the row reads
      // "claimed by someone" forever — the audit trail the one-intent-per-order
      // rule exists to provide never actually works.
      const who = (window.TerminalAuth && window.TerminalAuth.getEmail
                   && window.TerminalAuth.getEmail()) || '';
      const qs = who ? `?requested_by=${encodeURIComponent(who)}` : '';
      const d = await T.api(`/api/broker/n2s-covers/${encodeURIComponent(n2sId)}/buy-intent${qs}`,
                            { method: 'POST' });
      btn.textContent = 'claimed';
      btn.classList.add('pos');
      const tr = btn.closest('tr');
      n2sFeed.claims[String(n2sId)] = {
        intent: (d && d.intent) || {},
        fp: tr ? rowFpFromTr(tr) : '',
      };
      showFillSheet(btn, (d && d.intent) || {});
    } catch (err) {
      // A 409 here is a real answer (not buyable / already claimed), not a
      // glitch — show it rather than swallowing it.
      btn.disabled = false;
      btn.textContent = prev;
      const meta = document.getElementById('n2sMeta');
      if (meta) meta.textContent = `claim refused: ${err && err.message ? err.message : err}`;
    }
  }

  // The two absence lists mean opposite things and must not be shown alike.
  // operator_fills is the human's checkout work and is the NORMAL case;
  // payload_gaps is something our side owed and failed to produce. Rendering
  // them the same way would train people to skim past both, and then a real
  // gap — an unmapped event, a source with no purchase path — gets ignored
  // along with "type in your card number".
  function showFillSheet(btn, intent, moved) {
    const tr = btn.closest('tr');
    if (!tr) return;
    // Re-applied on every repaint, so an existing sheet is replaced rather
    // than stacked — otherwise a claimed row grows a new sheet every minute.
    const prior = tr.nextElementSibling;
    if (prior && prior.classList.contains('n2s-sheet')) prior.remove();
    const fills = intent.operator_fills || [];
    const gaps = intent.payload_gaps || [];
    const sheet = document.createElement('tr');
    sheet.className = 'n2s-sheet';
    const cell = document.createElement('td');
    cell.colSpan = tr.children.length;
    cell.className = 'muted small';
    // Built from nodes rather than markup: every piece here is server data,
    // and textContent cannot be talked into being markup.
    cell.appendChild(document.createTextNode(
      `intent #${intent.intent_id || '?'} recorded — nothing was purchased. `));
    const seg = (label, list, cls) => {
      if (!list.length) return;
      if (cell.childNodes.length > 1) cell.appendChild(document.createTextNode(' · '));
      const b = document.createElement('strong');
      b.textContent = label;
      if (cls) b.className = cls;
      cell.appendChild(b);
      cell.appendChild(document.createTextNode(` ${list.join(', ')}`));
    };
    seg('we still owe:', gaps, 'neg');
    seg('you fill at checkout:', fills, '');
    if (!gaps.length && !fills.length) {
      cell.appendChild(document.createTextNode('nothing outstanding'));
    }
    // The intent is frozen server-side against the cover as it was, so it is
    // still valid — but the row above now shows a different listing, and a
    // sheet that silently described the wrong one would be worse than loud.
    if (moved) {
      cell.appendChild(document.createTextNode(' · '));
      const w = document.createElement('strong');
      w.className = 'warn';
      w.textContent = 'the queue has since moved this order to a different listing;';
      cell.appendChild(w);
      cell.appendChild(document.createTextNode(
        ' this sheet is the cover you claimed, not the row above.'));
    }
    sheet.appendChild(cell);
    tr.insertAdjacentElement('afterend', sheet);
  }

  // Signed the opposite way to pnlCell: here a POSITIVE number is money out.
  function coverCell(v) {
    // NULL is "no cover was allocated", NOT zero cost. Rendering it as $0.00
    // would read as a free settlement, which is the opposite of the truth.
    if (v === null || v === undefined) return '<span class="muted">—</span>';
    const cls = v > 0 ? 'neg' : 'pos';
    return `<span class="${cls}">${money(v)}</span>`;
  }

  // ---------- sub queue (push) ----------

  // ---------- order # → auto-fill the sold ticket ----------

  // Order sources: the four we ingest, plus the S4K CRM fallback that fronts
  // six marketplace books (adds StubHub + Gametime, which we ingest nowhere).
  function wireOrderLoad() {
    const btn = document.getElementById('subOrderLoad');
    if (btn) btn.addEventListener('click', loadOrder);
    const inp = document.getElementById('subOrderId');
    if (inp) inp.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); loadOrder(); }
    });
  }

  // Fill-if-present: for prefilling from a query string, where an absent
  // parameter means "leave whatever is there".
  function setVal(id, v) {
    const el = document.getElementById(id);
    if (el && v !== null && v !== undefined && v !== '') el.value = v;
  }

  async function loadOrder() {
    const id = (document.getElementById('subOrderId').value || '').trim();
    const src = document.getElementById('subOrderSource').value;
    const msg = document.getElementById('subOrderMsg');
    if (!id) { msg.innerHTML = '<span class="neg">enter an order number</span>'; return; }
    msg.textContent = 'looking up…';
    try {
      const qs = new URLSearchParams({ order_id: id });
      if (src) qs.set('source', src);
      const o = await T.api(`/api/broker/order-lookup?${qs.toString()}`);
      if (!o.found) { msg.innerHTML = `<span class="neg">${esc(o.note || 'order not found')}</span>`; return; }
      setVal('subEvent', o.tevo_event_id);
      setVal('subSection', o.section);
      setVal('subRow', o.row);
      setVal('subQty', o.quantity || 1);
      setVal('subRevenue', o.revenue);
      if (o.event_name) document.getElementById('subEventSearch').value = o.event_name;
      const multi = (o.line_items && o.line_items > 1)
        ? ` · ⚠ ${esc(o.line_items)} line items — showing the first` : '';
      // A CRM hit identifies its event by name/date/venue only — there's no
      // tevo_event_id to search on, so show what it is and let the operator
      // pick the event from the typeahead (already prefilled with the name).
      const crm = o.via === 's4k_crm';
      const when = o.event_date ? ` · ${esc(o.event_date)}` : '';
      const where = o.venue_name ? ` · ${esc(o.venue_name)}` : '';
      const status = o.order_status ? ` · <strong>${esc(o.order_status)}</strong>` : '';
      msg.innerHTML = `<span class="pos">loaded ${esc(o.source)} order</span>` +
        (crm ? ' <span class="badge muted" title="S4K CRM marketplace book">CRM</span>' : '') +
        ` · ${esc(o.event_name || ('event ' + o.tevo_event_id))}${when}${where}${status}${multi}` +
        (crm && !o.tevo_event_id
          ? `<div class="muted small neg">${esc(o.note || 'pick the event above to run the search')}</div>`
          : '');
      if (crm && !o.tevo_event_id) return;  // nothing to search on yet
      run();  // auto-search subs from the loaded details
    } catch (err) {
      msg.innerHTML = `<span class="neg">${esc(String(err.message || err))}</span>`;
    }
  }

  // ---------- event-name search (typeahead → tevo_event_id) ----------

  function wireEventSearch() {
    const inp = document.getElementById('subEventSearch');
    const box = document.getElementById('subEventResults');
    if (!inp || !box) return;
    let t = 0;
    inp.addEventListener('input', () => {
      clearTimeout(t);
      const q = inp.value.trim();
      if (q.length < 2) { box.hidden = true; box.innerHTML = ''; return; }
      t = setTimeout(() => searchEvents(q), 250);
    });
    document.addEventListener('click', (e) => {
      if (!box.contains(e.target) && e.target !== inp) box.hidden = true;
    });
  }

  async function searchEvents(q) {
    const box = document.getElementById('subEventResults');
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      box.innerHTML = '<div class="ta-empty">search needs @s4kent.com sign-in</div>';
      box.hidden = false; return;
    }
    box.innerHTML = '<div class="ta-empty">searching…</div>'; box.hidden = false;
    try {
      const res = await Auth.client.rpc('terminal_search', { p_q: q, p_limit: 8 });
      if (res.error) { box.innerHTML = `<div class="ta-empty err">${esc(res.error.message || 'search error')}</div>`; return; }
      const evs = (res.data && res.data.events) || [];
      if (!evs.length) { box.innerHTML = '<div class="ta-empty">no events</div>'; return; }
      box.innerHTML = evs.map(e => {
        const meta = [e.venue_name, T.fmtDate(e.occurs_at_local)].filter(Boolean).join(' · ');
        return `<button type="button" class="ta-row" data-eid="${esc(e.tevo_event_id)}" data-name="${esc(e.name || '')}">` +
               `<span class="ta-name">${esc(e.name || '(unnamed)')}</span>` +
               `<span class="ta-meta">${esc(meta)}</span></button>`;
      }).join('');
      box.querySelectorAll('.ta-row').forEach(btn => {
        btn.addEventListener('click', () => {
          document.getElementById('subEvent').value = btn.dataset.eid;
          document.getElementById('subEventSearch').value = btn.dataset.name;
          box.hidden = true;
        });
      });
    } catch (err) {
      box.innerHTML = `<div class="ta-empty err">${esc(String(err.message || err))}</div>`;
    }
  }

  function wireFeeToggle() {
    const src = document.getElementById('subSource');
    const fee = document.getElementById('subFeeField');
    if (!src || !fee) return;
    const sync = () => { fee.hidden = src.value !== 'market'; };
    src.addEventListener('change', sync);
    sync();
  }

  function setStatus(s, cls) { T.setStatus(s, cls); }

  function prefillFromQuery() {
    const q = new URLSearchParams(location.search);
    const map = { event: 'subEvent', section: 'subSection', row: 'subRow',
                  quantity: 'subQty', revenue: 'subRevenue', source: 'subSource' };
    let haveSection = false;
    Object.entries(map).forEach(([k, id]) => {
      const v = q.get(k);
      if (v === null || v === '') return;
      const el = document.getElementById(id);
      if (el) { el.value = v; if (k === 'section') haveSection = true; }
    });
    // Auto-run when deep-linked with enough to search.
    const ev = document.getElementById('subEvent').value;
    if (ev && haveSection) run();
  }

  function onSubmit(e) {
    e.preventDefault();
    run();
  }

  function readForm() {
    const val = (id) => (document.getElementById(id).value || '').trim();
    return {
      event: parseInt(val('subEvent'), 10),
      section: val('subSection'),
      row: val('subRow'),
      quantity: parseInt(val('subQty'), 10) || 1,
      revenue: val('subRevenue'),
      source: val('subSource') || 'owned',
      fee_pct: val('subFee'),
    };
  }

  async function run() {
    const f = readForm();
    if (!Number.isFinite(f.event) || f.event <= 0) { setStatus('enter a valid event id', 'err'); return; }
    if (!f.section) { setStatus('enter a section', 'err'); return; }

    const qs = new URLSearchParams();
    qs.set('section', f.section);
    if (f.row) qs.set('row', f.row);
    qs.set('quantity', String(f.quantity));
    if (f.revenue !== '') qs.set('revenue', f.revenue);
    qs.set('source', f.source);
    if (f.source === 'market' && f.fee_pct !== '') qs.set('fee_pct', f.fee_pct);

    const btn = document.getElementById('subsRun');
    if (btn) btn.disabled = true;
    setStatus('searching…');
    try {
      const data = await T.api(`/api/broker/event/${f.event}/substitutions?${qs.toString()}`);
      render(data, f);
      const n = (data.counts && data.counts.subs) || 0;
      const sn = (data.section_subs && data.section_subs.counts && data.section_subs.counts.section_subs) || 0;
      setStatus(`${n} row sub${n === 1 ? '' : 's'} · ${sn} section sub${sn === 1 ? '' : 's'}`, n + sn ? 'ok' : '');
    } catch (err) {
      console.error('[subs]', err);
      setStatus(String(err.message || err), 'err');
    } finally {
      if (btn) btn.disabled = false;
    }
  }

  // ---------- render ----------

  function render(data, f) {
    document.getElementById('subs-results').hidden = false;
    renderRecap(data, f);
    renderBest(data);
    renderRowSubs(data);
    renderSectionSubs(data);
    renderAmbiguous(data);
  }

  function renderRecap(data, f) {
    const t = data.target || {};
    const poolNames = { tevo_owned: 'TEvo owned', sg_seller: 'SG seller',
                        tevo_market: 'exchange', gotickets: 'GoTickets' };
    const pools = (data.pools || []).map(p => poolNames[p] || p);
    const poolLabel = (data.source === 'market' ? 'market (buy-in)' : 'owned') +
      (pools.length ? ` — ${pools.join(' + ')}` : '');
    const rev = (t.revenue_per_ticket != null) ? ` · revenue ${money(t.revenue_per_ticket)}/tix` : '';
    document.getElementById('subsRecap').innerHTML =
      `<div class="recap-line">Cover <strong>${esc(f.quantity)}×</strong> ` +
      `Section <strong>${esc(t.section || f.section)}</strong> ` +
      `Row <strong>${esc(t.row || f.row || '—')}</strong>${rev}</div>` +
      `<div class="muted small">pool: ${esc(poolLabel)} · snapshot: ${esc(T.fmtDate(data.captured_at))}` +
      (data.gt_captured_at ? ` · GoTickets: ${esc(T.fmtDate(data.gt_captured_at))}` : '') +
      (data.captured_at ? '' : ' (no listings snapshot for this event)') + `</div>`;
  }

  function renderBest(data) {
    const el = document.getElementById('subsBest');
    const b = data.best || (data.section_subs && data.section_subs.best);
    if (!b) {
      el.innerHTML = `<div class="best-none">No acceptable sub found in the ${esc(data.source || 'owned')} pool.</div>`;
      return;
    }
    const isSec = b.match_type === 'section_upgrade';
    const where = isSec
      ? `Section ${esc(b.to_section)} · Row ${esc(b.row || '—')}`
      : `Row ${esc(b.row)} (${esc(b.match_type)}${b.row_delta != null ? `, +${esc(b.row_delta)} rows` : ''})`;
    el.innerHTML =
      `<div class="best-card">` +
      `<span class="best-tag">BEST PICK</span> ` +
      `<span class="best-where">${where}</span> ` +
      `<span class="best-meta">${esc(b.quantity)} avail · cost ${money(b.unit_cost)}/tix · ${sourceBadge(b.inv_source)}</span>` +
      pnlBadge(b.pnl_total, ' total') +
      (b.buy_url ? ` <a class="sub-link" href="${esc(b.buy_url)}" target="_blank" rel="noopener noreferrer">buy ↗</a>` : '') +
      `</div>`;
  }

  function renderRowSubs(data) {
    const subs = data.subs || [];
    document.getElementById('subsRowCount').textContent = subs.length ? `${subs.length}` : '';
    const cols = ['Row', 'Match', 'Δrow', 'Qty', 'Cost/tix', 'P&L total', 'Source', 'Buy'];
    const rows = subs.map(s => [
      esc(s.row), esc(s.match_type), s.row_delta != null ? `+${esc(s.row_delta)}` : '—',
      esc(s.quantity), costDisp(s), pnlCell(s.pnl_total), sourceBadge(s.inv_source),
      buyCell(s),
    ]);
    document.getElementById('subsRowTable').innerHTML =
      rows.length ? tableHtml(cols, rows) : emptyHtml('No same-section same-or-better-row sub.');
  }

  function renderSectionSubs(data) {
    const ss = data.section_subs || {};
    const subs = ss.section_subs || [];
    document.getElementById('subsSecCount').textContent =
      ss.sold_quality != null ? `sold-section median ${money(ss.sold_quality)}` : '';
    if (ss.note) {
      document.getElementById('subsSecTable').innerHTML = emptyHtml(esc(ss.note));
      return;
    }
    const cols = ['To section', 'Δquality', 'Row', 'Qty', 'Cost/tix', 'P&L total', 'Source', 'Buy'];
    const rows = subs.map(s => [
      esc(s.to_section), s.section_delta != null ? `+${money(s.section_delta)}` : '—',
      esc(s.row || '—'), esc(s.quantity), costDisp(s), pnlCell(s.pnl_total), sourceBadge(s.inv_source),
      buyCell(s),
    ]);
    document.getElementById('subsSecTable').innerHTML =
      rows.length ? tableHtml(cols, rows) : emptyHtml('No better-section sub in this pool.');
  }

  function renderAmbiguous(data) {
    const amb = data.ambiguous || [];
    const wrap = document.getElementById('subsAmbiguousWrap');
    wrap.hidden = amb.length === 0;
    document.getElementById('subsAmbCount').textContent = amb.length ? `(${amb.length})` : '';
    if (!amb.length) return;
    const cols = ['Section', 'Row', 'Why', 'Qty', 'Cost/tix', 'Source', 'Buy'];
    const rows = amb.map(s => [
      esc(s.section || '—'), esc(s.row), esc(s.match_type), esc(s.quantity),
      money(s.unit_cost), sourceBadge(s.inv_source), buyCell(s),
    ]);
    document.getElementById('subsAmbTable').innerHTML = tableHtml(cols, rows);
  }

  // ---------- helpers ----------

  function tableHtml(cols, rows) {
    const head = cols.map(c => `<th>${esc(c)}</th>`).join('');
    const body = rows.map(r => `<tr>${r.map(c => `<td>${c}</td>`).join('')}</tr>`).join('');
    return `<table class="subs-table"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
  }

  function emptyHtml(msg) { return `<div class="empty">${esc(msg)}</div>`; }

  function money(v) {
    if (v === null || v === undefined || v === '' || Number.isNaN(+v)) return '—';
    return '$' + Number(v).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  // Display cost = landed (ask + fees). Flag when fees moved it off the ask.
  function costDisp(s) {
    const landed = s.landed_cost, raw = s.unit_cost;
    if (landed === null || landed === undefined) return money(raw);
    if (raw !== null && raw !== undefined && Math.abs(+landed - +raw) > 0.005) {
      return `<span title="ask ${esc(money(raw))} + fee">${money(landed)}*</span>`;
    }
    return money(landed);
  }

  function signedMoney(v) {
    const n = Number(v);
    return (n >= 0 ? '+$' : '-$') + Math.abs(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  function pnlCell(v) {
    if (v === null || v === undefined || Number.isNaN(+v)) return '—';
    return `<span class="${+v >= 0 ? 'pos' : 'neg'}">${signedMoney(v)}</span>`;
  }

  function pnlBadge(v, suffix) {
    if (v === null || v === undefined || Number.isNaN(+v)) return '';
    return ` <span class="badge ${+v >= 0 ? 'pos' : 'neg'}">${signedMoney(v)}${esc(suffix || '')}</span>`;
  }

  function sourceBadge(src) {
    const label = {
      tevo_owned: 'TEvo', sg_seller: 'SG seller', tevo_market: 'exchange',
      gotickets: 'GoTickets',
    }[src] || (src || '—');
    return `<span class="badge muted" title="${esc(src || '')}">${esc(label)}</span>`;
  }

  // Only GoTickets rows carry a buy link (the exchange has no per-listing
  // page). Absent link -> a dash, never a fabricated URL.
  function buyCell(s) {
    if (!s.buy_url) return '—';
    return `<a href="${esc(s.buy_url)}" target="_blank" rel="noopener noreferrer">buy ↗</a>`;
  }

  const esc = window.TermRender.escapeHtml;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
