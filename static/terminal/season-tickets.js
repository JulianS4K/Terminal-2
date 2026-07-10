// D0 Terminal — Season-ticket package value. Is a season package worth buying
// vs. assembling comparable seats game-by-game?
//
//   GET /api/broker/season-ticket-value            -> { packages:[...], computed_at }
//   GET /api/broker/season-ticket-value/{id}?row_band=5
//        -> { event, params, summary, seats:[...] }
//
// The leaderboard is rebuilt daily (season_ticket_package_value); the per-seat
// drill-down is computed live. "Comparable" = same section + row within ±band,
// pair-sellable, at getin (cheapest pair) and VWAP (depth-weighted) baselines.
// Read-only; all valuation logic lives server-side (SECDEF RPCs).

(function () {
  'use strict';
  const T = window.Terminal;
  const esc = window.TermRender.escapeHtml;
  let lastBoard = [];

  function band() {
    const v = parseInt((document.getElementById('stvBand').value || '5'), 10);
    return Number.isFinite(v) ? Math.max(0, Math.min(v, 20)) : 5;
  }
  function setStatus(msg, cls) { T.setStatus(msg, cls || ''); }

  function init() {
    const rb = document.getElementById('stvReload');
    if (rb) rb.addEventListener('click', loadBoard);
    const board = document.getElementById('stvBoard');
    if (board) board.addEventListener('click', onBoardClick);
    loadBoard();
    // Deep-link: ?event=<pkg_event_id> opens that package's breakdown directly
    // (used by the per-team links on the Leagues season-ticket table).
    const deep = parseInt(new URLSearchParams(location.search).get('event'), 10);
    if (Number.isFinite(deep)) loadDetail(deep);
  }

  // ---------- leaderboard ----------

  async function loadBoard() {
    setStatus('loading leaderboard…');
    try {
      const data = await T.api('/api/broker/season-ticket-value');
      lastBoard = (data && data.packages) || [];
      renderBoard(lastBoard, data || {});
      if (data && data.error) {
        setStatus('leaderboard unavailable', 'err');
      } else {
        setStatus(`${lastBoard.length} package${lastBoard.length === 1 ? '' : 's'}`, lastBoard.length ? 'ok' : '');
      }
    } catch (err) {
      console.error('[season-tickets]', err);
      setStatus(String(err.message || err), 'err');
      document.getElementById('stvBoard').innerHTML = emptyHtml(String(err.message || err));
    }
  }

  function renderBoard(pkgs, data) {
    document.getElementById('stvBoardCount').textContent = pkgs.length ? `${pkgs.length}` : '';
    const meta = document.getElementById('stvMeta');
    if (data.error) {
      meta.innerHTML = `<span class="neg">leaderboard not available yet — ${esc(String(data.error))}</span>`;
    } else if (data.computed_at) {
      meta.innerHTML = `leaderboard rebuilt ${esc(T.fmtDate(data.computed_at))}`;
    } else {
      meta.innerHTML = '<span class="neg">no leaderboard yet — daily refresh has not run</span>';
    }
    if (!pkgs.length) {
      document.getElementById('stvBoard').innerHTML =
        emptyHtml('No major-league season-ticket packages valued yet.');
      return;
    }
    const cols = ['Verdict', 'League', 'Team', 'Gms', 'Pkg ask/seat', 'Season @getin',
                  'Season @VWAP', 'Δ/seat @VWAP', '% cheaper', 'Seats'];
    const rows = pkgs.map(p => ({
      attr: `data-pkg="${esc(p.pkg_event_id)}"`,
      cells: [
        verdictBadge(p.verdict),
        esc(p.league || '—'),
        esc(p.team || '—'),
        esc(p.home_games),
        money(p.pkg_ask_med),
        money(p.comp_getin_med),
        money(p.comp_vwap_med),
        signedCell(p.med_savings_vwap),
        pctCell(p.pct_cheaper_vwap),
        esc(p.seats_valued),
      ],
    }));
    document.getElementById('stvBoard').innerHTML = clickTableHtml(cols, rows);
  }

  function onBoardClick(e) {
    const tr = e.target.closest('tr[data-pkg]');
    if (!tr) return;
    const id = parseInt(tr.dataset.pkg, 10);
    if (Number.isFinite(id)) loadDetail(id);
  }

  // ---------- per-package drill-down (live) ----------

  async function loadDetail(id) {
    const panel = document.getElementById('stv-detail-panel');
    panel.hidden = false;
    document.getElementById('stvDetailTitle').textContent = 'PACKAGE DETAIL';
    document.getElementById('stvDetailVerdict').textContent = '';
    document.getElementById('stvDetailSummary').innerHTML = '<div class="muted small">computing…</div>';
    document.getElementById('stvSeatCount').textContent = '';
    document.getElementById('stvSeatTable').innerHTML = '';
    setStatus('computing package…');
    try {
      const data = await T.api(`/api/broker/season-ticket-value/${id}?row_band=${band()}`);
      if (data && data.error) {
        document.getElementById('stvDetailSummary').innerHTML = emptyHtml(String(data.error));
        setStatus('package unavailable', 'err');
        return;
      }
      renderDetail(data || {});
      panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
      setStatus('ok', 'ok');
    } catch (err) {
      console.error('[season-tickets]', err);
      document.getElementById('stvDetailSummary').innerHTML = emptyHtml(String(err.message || err));
      setStatus(String(err.message || err), 'err');
    }
  }

  function renderDetail(data) {
    const ev = data.event || {};
    const s = data.summary || {};
    const seats = data.seats || [];
    const bandN = (data.params && data.params.row_band != null) ? data.params.row_band : band();

    document.getElementById('stvDetailTitle').textContent =
      `${esc(ev.team || 'PACKAGE')} — ${esc(ev.league || '')}`.replace(/ — $/, '');
    document.getElementById('stvDetailVerdict').innerHTML = s.verdict ? verdictBadge(s.verdict) : '';

    if (s.seats_valued == null || s.seats_valued === 0) {
      document.getElementById('stvDetailSummary').innerHTML =
        emptyHtml('Not enough comparable pair inventory across every home game to value this package yet.');
      return;
    }

    document.getElementById('stvDetailSummary').innerHTML =
      `<div class="recap-line"><strong>${esc(ev.venue_name || '')}</strong> · ` +
      `${esc(s.home_games)} home games · ${esc(s.seats_valued)} seats valued · row band ±${esc(bandN)}</div>` +
      `<div class="muted small">Pkg ask <strong>${money(s.pkg_ask_med)}</strong>/seat · ` +
      `comparable season cost — getin <strong>${money(s.comp_getin_med)}</strong>, ` +
      `VWAP <strong>${money(s.comp_vwap_med)}</strong> · ` +
      `median save vs getin ${signed(s.med_savings_getin)}, vs VWAP ${signed(s.med_savings_vwap)} · ` +
      `cheaper than DIY ${pct(s.pct_cheaper_getin)} (getin) / ${pct(s.pct_cheaper_vwap)} (VWAP)</div>`;

    document.getElementById('stvSeatCount').textContent = seats.length ? `${seats.length} seats` : '';
    const cols = ['Section', 'Row', 'Qty', 'Pkg ask', 'Season @getin', 'Season @VWAP', 'Δ @getin', 'Δ @VWAP'];
    const rows = seats.map(r => [
      esc(r.section), esc(r.row), esc(r.quantity),
      money(r.pkg_ask), money(r.season_getin), money(r.season_vwap),
      signedCell(r.savings_getin), signedCell(r.savings_vwap),
    ]);
    document.getElementById('stvSeatTable').innerHTML =
      rows.length ? tableHtml(cols, rows) : emptyHtml('No per-seat rows.');
  }

  // ---------- helpers ----------

  function tableHtml(cols, rows) {
    const head = cols.map(c => `<th>${esc(c)}</th>`).join('');
    const body = rows.map(r => `<tr>${r.map(c => `<td>${c}</td>`).join('')}</tr>`).join('');
    return `<table class="subs-table"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
  }
  function clickTableHtml(cols, rows) {
    const head = cols.map(c => `<th>${esc(c)}</th>`).join('');
    const body = rows.map(r =>
      `<tr ${r.attr} class="stv-clickable">${r.cells.map(c => `<td>${c}</td>`).join('')}</tr>`).join('');
    return `<table class="subs-table stv-board"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
  }
  function emptyHtml(msg) { return `<div class="empty">${esc(msg)}</div>`; }

  function money(v) {
    if (v === null || v === undefined || v === '' || Number.isNaN(+v)) return '—';
    return '$' + Number(v).toLocaleString(undefined, { maximumFractionDigits: 0 });
  }
  function signed(v) {
    if (v === null || v === undefined || Number.isNaN(+v)) return '—';
    const n = Number(v);
    return (n >= 0 ? '+$' : '−$') + Math.abs(n).toLocaleString(undefined, { maximumFractionDigits: 0 });
  }
  function signedCell(v) {
    if (v === null || v === undefined || Number.isNaN(+v)) return '—';
    return `<span class="${+v >= 0 ? 'pos' : 'neg'}">${signed(v)}</span>`;
  }
  function pct(v) {
    if (v === null || v === undefined || Number.isNaN(+v)) return '—';
    return `${Number(v).toFixed(0)}%`;
  }
  function pctCell(v) {
    if (v === null || v === undefined || Number.isNaN(+v)) return '—';
    return `<span class="${+v >= 50 ? 'pos' : (+v >= 25 ? '' : 'neg')}">${pct(v)}</span>`;
  }
  function verdictBadge(verdict) {
    const v = String(verdict || '').toUpperCase();
    const cls = v === 'BUY' ? 'pos' : (v === 'FAIR' ? 'muted' : (v === 'SKIP' ? 'neg' : 'muted'));
    return `<span class="badge ${cls}">${esc(v || '—')}</span>`;
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
