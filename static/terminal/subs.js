// D0 Terminal — Substitution checker. Enter a sold ticket (event / section /
// row / qty) and find the cheapest acceptable cover from our inventory:
// same-section same-or-better row first, then a better-section fallback.
//
//   GET /api/broker/event/{id}/substitutions
//        ?section=&row=&quantity=&revenue=&source=owned|market
//     -> { target, subs:[...], ambiguous:[...], section_subs:{...},
//          best, counts, captured_at, source }
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
    wireEventSearch();
    wireFeeToggle();
    prefillFromQuery();
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
    const poolLabel = data.source === 'market' ? 'market (buy-in)' : 'owned';
    const rev = (t.revenue_per_ticket != null) ? ` · revenue ${money(t.revenue_per_ticket)}/tix` : '';
    document.getElementById('subsRecap').innerHTML =
      `<div class="recap-line">Cover <strong>${esc(f.quantity)}×</strong> ` +
      `Section <strong>${esc(t.section || f.section)}</strong> ` +
      `Row <strong>${esc(t.row || f.row || '—')}</strong>${rev}</div>` +
      `<div class="muted small">pool: ${esc(poolLabel)} · snapshot: ${esc(T.fmtDate(data.captured_at))}` +
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
      `</div>`;
  }

  function renderRowSubs(data) {
    const subs = data.subs || [];
    document.getElementById('subsRowCount').textContent = subs.length ? `${subs.length}` : '';
    const cols = ['Row', 'Match', 'Δrow', 'Qty', 'Cost/tix', 'P&L total', 'Source'];
    const rows = subs.map(s => [
      esc(s.row), esc(s.match_type), s.row_delta != null ? `+${esc(s.row_delta)}` : '—',
      esc(s.quantity), costDisp(s), pnlCell(s.pnl_total), sourceBadge(s.inv_source),
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
    const cols = ['To section', 'Δquality', 'Row', 'Qty', 'Cost/tix', 'P&L total', 'Source'];
    const rows = subs.map(s => [
      esc(s.to_section), s.section_delta != null ? `+${money(s.section_delta)}` : '—',
      esc(s.row || '—'), esc(s.quantity), costDisp(s), pnlCell(s.pnl_total), sourceBadge(s.inv_source),
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
    const cols = ['Row', 'Qty', 'Cost/tix', 'Source'];
    const rows = amb.map(s => [esc(s.row), esc(s.quantity), money(s.unit_cost), sourceBadge(s.inv_source)]);
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
    const label = { tevo_owned: 'TEvo', sg_seller: 'SG seller', tevo_market: 'market' }[src] || (src || '—');
    return `<span class="badge muted" title="${esc(src || '')}">${esc(label)}</span>`;
  }

  function esc(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"']/g, c => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
