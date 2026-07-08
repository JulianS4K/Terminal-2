// D0 Terminal — Leagues hub (LEAGUES nav tab).
//
// One page across every ESPN-tracked league. Merges the former Racing page:
// racing series (F1 + NASCAR Cup/Xfinity/Truck) keep their full richness
// (schedule + driver standings + race results), while team leagues (NBA/MLB/
// NHL/WNBA/MLS/NFL/World Cup) get a per-team demand ranking + blind-spot view.
//
// Data — all real, no mock rows:
//   team leagues:  GET /api/broker/leagues            -> picker (server-static)
//                  GET /api/broker/performers/by-league/{league}
//                       -> per-team home/road market_tix · owned_tix · medians
//   racing series: get_espn_racing_events(series)      -> race schedule
//                  get_espn_racing_standings(series)    -> driver standings
//                  get_espn_racing_results(event_id)    -> finishing order
//
// A per-league GAME slate for team sports (marquee-slate in the wireframe) has
// no backing RPC yet — deliberately omitted rather than faked; the demand
// ranking + blind-spot panels carry the same "where's demand, where are we
// absent" read off real team aggregates.

(function () {
  'use strict';
  const T = window.Terminal;
  const escapeHtml = window.TermRender.escapeHtml;

  // Racing series live in their own (lowercase, hyphenated) key namespace —
  // no collision with the UPPERCASE team-league codes from /api/broker/leagues.
  const RACING_SERIES = [
    { key: 'nascar-cup',     label: 'NASCAR',  sub: 'Cup' },
    { key: 'nascar-xfinity', label: 'XFINITY', sub: 'NASCAR' },
    { key: 'nascar-truck',   label: 'TRUCK',   sub: 'NASCAR' },
    { key: 'f1',             label: 'F1',      sub: 'Formula 1' },
  ];
  const RACING_KEYS = new Set(RACING_SERIES.map(s => s.key));
  const RACING_NAME = {
    'nascar-cup': 'NASCAR Cup Series', 'nascar-xfinity': 'NASCAR Xfinity Series',
    'nascar-truck': 'NASCAR Truck Series', 'f1': 'Formula 1',
  };
  const RACING_SUB = {
    'nascar-cup': 'Motorsport · NASCAR · driver championship',
    'nascar-xfinity': 'Motorsport · NASCAR Xfinity',
    'nascar-truck': 'Motorsport · NASCAR Truck',
    'f1': 'Motorsport · Formula 1 · driver championship',
  };

  let _teamLeagues = [];   // [{ key, label, teams }] from /api/broker/leagues
  const $ = id => document.getElementById(id);

  function currentLeague() {
    const q = new URLSearchParams(location.search);
    // ?series= kept for backward-compat with old racing.html deep links.
    return (q.get('league') || q.get('series') || '').trim();
  }
  const isRacing = key => RACING_KEYS.has(key);

  async function init() {
    if (window.TerminalAuth) await window.TerminalAuth.requireAuth();
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken()) {
      $('lgPicker').innerHTML = '';
      $('lgPrimaryBody').innerHTML = '<div class="empty">leagues need auth — sign in with @s4kent.com</div>';
      $('lgSecondaryBody').innerHTML = '';
      T.setStatus('Auth required', 'err');
      return;
    }
    // Team-league list is a server-static set (mirrors _ESPN_LEAGUES). If it
    // fails we still show the racing series — the picker degrades, never blanks.
    try {
      const lg = await T.api('/api/broker/leagues');
      _teamLeagues = (lg && lg.leagues) || [];
    } catch (e) {
      console.error('[leagues] list', e);
      _teamLeagues = [];
    }
    buildPicker();
    $('lgResultsClose').addEventListener('click', e => {
      e.preventDefault();
      $('lgResults').setAttribute('hidden', '');
    });
    load(pickInitial(currentLeague()));
  }

  function pickInitial(want) {
    if (want) {
      if (isRacing(want)) return want;
      const hit = _teamLeagues.find(l => String(l.key).toLowerCase() === want.toLowerCase());
      if (hit) return hit.key;
    }
    if (_teamLeagues.length) return _teamLeagues[0].key;
    return RACING_SERIES[0].key;
  }

  function buildPicker() {
    const picker = $('lgPicker');
    const btn = (key, label, sub, kind) =>
      `<button class="lg-btn" data-league="${escapeHtml(key)}" data-kind="${kind}" role="tab">` +
      `${escapeHtml(label)}<span class="sub">${escapeHtml(sub)}</span></button>`;
    const teamBtns = _teamLeagues.map(l =>
      btn(l.key, l.label, (l.teams ? l.teams + ' tm' : 'teams'), 'team')).join('');
    const raceBtns = RACING_SERIES.map(s => btn(s.key, s.label, s.sub, 'racing')).join('');
    picker.innerHTML = teamBtns + (teamBtns && raceBtns ? '<div class="lg-sep"></div>' : '') + raceBtns;
    picker.querySelectorAll('.lg-btn').forEach(b =>
      b.addEventListener('click', () => load(b.dataset.league)));
  }

  function markActive(key) {
    document.querySelectorAll('.lg-btn').forEach(b =>
      b.classList.toggle('active', b.dataset.league === key));
  }

  function load(key) {
    markActive(key);
    const url = new URL(location.href);
    url.searchParams.set('league', key);
    url.searchParams.delete('series');
    history.replaceState(null, '', url);
    $('lgResults').setAttribute('hidden', '');
    if (isRacing(key)) loadRacing(key);
    else loadTeamLeague(key);
  }

  // ------------------------------------------------------------------
  // Shared bits
  // ------------------------------------------------------------------
  function setHero(logo, name, sub) {
    $('lgLogo').textContent = logo;
    $('lgName').textContent = name;
    $('lgSub').textContent = sub;
  }
  function renderStrip(cells) {
    $('lgStrip').innerHTML = cells.map(c =>
      `<div class="kpi-cell"><span class="kpi-num ${c.cls || ''}">${c.n}</span>` +
      `<span class="kpi-lbl">${escapeHtml(c.l)}</span></div>`).join('');
  }
  const num = v => (v == null ? '0' : T.fmtNum(Math.round(+v)));
  const money = v => (v == null ? '—' : '$' + T.fmtNum(Math.round(+v)));

  // ------------------------------------------------------------------
  // Team leagues — /api/broker/performers/by-league/{league}
  // ------------------------------------------------------------------
  async function loadTeamLeague(key) {
    const label = (_teamLeagues.find(l => l.key === key) || {}).label || key;
    setHero(shortCode(key), leagueLongName(key, label), 'Team league · per-team demand & owned position');
    T.setStatus('Loading ' + label + '…');
    $('lgPrimaryTitle').textContent = 'TEAMS — BY DEMAND';
    $('lgSecondaryTitle').textContent = 'BLIND SPOTS — TEAMS WE DON’T OWN';
    $('lgPrimaryMeta').textContent = '';
    $('lgSecondaryMeta').textContent = '';
    $('lgPrimaryBody').innerHTML = '<div class="empty">loading…</div>';
    $('lgSecondaryBody').innerHTML = '<div class="empty">loading…</div>';

    let payload;
    try {
      payload = await T.api('/api/broker/performers/by-league/' + encodeURIComponent(key));
    } catch (e) {
      T.setStatus(e.message, 'err');
      $('lgPrimaryBody').innerHTML = `<div class="empty">${escapeHtml(e.message)}</div>`;
      $('lgSecondaryBody').innerHTML = '';
      renderStrip([{ n: '—', l: 'teams' }]);
      return;
    }

    // Collapse home + road into one per-team line. market_tix ranks demand;
    // owned_tix is our position; a blind spot = demand with zero owned.
    const teams = (payload.performers || []).map(p => {
      const h = p.home || {}, r = p.road || {};
      const demand = (+h.market_tix || 0) + (+r.market_tix || 0);
      const owned  = (+h.owned_tix  || 0) + (+r.owned_tix  || 0);
      const events = (+h.events || 0) + (+r.events || 0);
      const mktMed = h.market_med != null ? +h.market_med
                   : (r.market_med != null ? +r.market_med : null);
      return {
        id: p.performer_id, name: p.performer_name || '—',
        demand, owned, events, mktMed,
        blind: demand > 0 && owned === 0,
      };
    }).sort((a, b) => b.demand - a.demand);

    const totMkt   = teams.reduce((s, t) => s + t.demand, 0);
    const totOwned = teams.reduce((s, t) => s + t.owned, 0);
    const withPos  = teams.filter(t => t.owned > 0).length;
    const blinds   = teams.filter(t => t.blind);

    renderStrip([
      { n: T.fmtNum(teams.length),    l: 'teams' },
      { n: num(totMkt),               l: 'mkt tix' },
      { n: num(totOwned),             l: 'owned tix', cls: totOwned ? 'ours' : '' },
      { n: T.fmtNum(withPos),         l: 'with position' },
      { n: T.fmtNum(blinds.length),   l: 'blind spots', cls: blinds.length ? 'warn' : '' },
    ]);
    T.setStatus('Loaded', 'ok');

    // Primary — full demand ranking with inline bars.
    $('lgPrimaryMeta').textContent = teams.length ? `${teams.length} teams · ranked by market tix` : '';
    if (!teams.length) {
      $('lgPrimaryBody').innerHTML = '<div class="empty">no ESPN-tracked team metrics for this league yet</div>';
    } else {
      const max = Math.max(1, ...teams.map(t => t.demand));
      $('lgPrimaryBody').innerHTML = teams.map((t, i) => {
        const nameHtml = t.id != null
          ? `<a href="performer.html?performer=${t.id}">${escapeHtml(t.name)}</a>`
          : `<span class="nm">${escapeHtml(t.name)}</span>`;
        const dot = t.blind ? '<span class="blind-dot" title="blind spot — open market, we own 0">◇</span>' : '';
        return `<div class="dm-row">
          <span class="dm-rank">${i + 1}</span>
          <span class="dm-name">${nameHtml}${dot}
            <div class="dm-bar"><div class="dm-bar-fill" style="width:${Math.round(t.demand / max * 100)}%"></div></div>
          </span>
          <span class="dm-val" title="market tickets (home+road)">${num(t.demand)}</span>
          <span class="dm-owned ${t.owned ? 'ours' : ''}" title="owned tickets (home+road)">${t.owned ? num(t.owned) : '—'}</span>
        </div>`;
      }).join('') +
        '<div class="lg-note">market/owned tickets aggregate this team’s home + road events. Bar = share of the league’s top team by market tickets. ' +
        'Per-game slate pending a league-slate RPC — click a team for its event-level view.</div>';
    }

    // Secondary — blind spots (demand, zero owned): the actionable gaps.
    $('lgSecondaryMeta').textContent = blinds.length ? `${blinds.length} of ${teams.length}` : '';
    if (!teams.length) {
      $('lgSecondaryBody').innerHTML = '<div class="empty">—</div>';
    } else if (!blinds.length) {
      $('lgSecondaryBody').innerHTML = '<div class="empty">no blind spots — we hold inventory in every ranked team</div>';
    } else {
      const rows = blinds.map(t => {
        const nameHtml = t.id != null
          ? `<a href="performer.html?performer=${t.id}">${escapeHtml(t.name)}</a>`
          : escapeHtml(t.name);
        return `<tr>
          <td>${nameHtml}</td>
          <td class="num">${t.events || '—'}</td>
          <td class="num">${num(t.demand)}</td>
          <td class="num">${money(t.mktMed)}</td>
        </tr>`;
      }).join('');
      $('lgSecondaryBody').innerHTML =
        `<div style="overflow-x:auto"><table class="espn-recent">
          <thead><tr><th>Team</th><th class="num">Events</th>
          <th class="num" title="market tickets, home+road">Mkt tix</th>
          <th class="num" title="market median (home)">Mkt med</th></tr></thead>
          <tbody>${rows}</tbody></table></div>`;
    }
  }

  function shortCode(key) {
    const k = String(key).toUpperCase();
    return k === 'WORLD CUP' ? 'WC' : k.slice(0, 4);
  }
  function leagueLongName(key, label) {
    const LONG = {
      NBA: 'National Basketball Association', MLB: 'Major League Baseball',
      NHL: 'National Hockey League', NFL: 'National Football League',
      MLS: 'Major League Soccer', WNBA: "Women's National Basketball Association",
      'World Cup': 'FIFA World Cup',
    };
    return LONG[key] || LONG[label] || label;
  }

  // ------------------------------------------------------------------
  // Racing series — the merged former Racing page (unchanged behaviour)
  // ------------------------------------------------------------------
  async function loadRacing(series) {
    setHero(series === 'f1' ? 'F1' : 'NASCAR', RACING_NAME[series] || series, RACING_SUB[series] || 'Motorsport');
    T.setStatus('Loading ' + (RACING_NAME[series] || series) + '…');
    $('lgPrimaryTitle').textContent = 'SCHEDULE';
    $('lgSecondaryTitle').textContent = 'DRIVER STANDINGS';
    $('lgPrimaryMeta').textContent = '';
    $('lgSecondaryMeta').textContent = '';
    $('lgPrimaryBody').innerHTML = '<div class="empty">loading…</div>';
    $('lgSecondaryBody').innerHTML = '<div class="empty">loading…</div>';

    const Auth = window.TerminalAuth;
    const [ev, st] = await Promise.all([
      Auth.client.rpc('get_espn_racing_events', { p_series: series, p_limit: 60 }),
      Auth.client.rpc('get_espn_racing_standings', { p_series: series, p_limit: 60 }),
    ]);
    if (ev.error) { T.setStatus(ev.error.message, 'err'); $('lgPrimaryBody').innerHTML = `<div class="empty">${escapeHtml(ev.error.message)}</div>`; }
    else renderSchedule(ev.data || []);
    if (st.error) { T.setStatus(st.error.message, 'err'); $('lgSecondaryBody').innerHTML = `<div class="empty">${escapeHtml(st.error.message)}</div>`; }
    else renderStandings(st.data || []);
    if (!ev.error && !st.error) T.setStatus('Loaded', 'ok');
  }

  function raceStatusBadge(r) {
    if (r.completed || r.status_state === 'post') return '<span class="race-badge done">FINAL</span>';
    if (r.status_state === 'in') return '<span class="race-badge live">LIVE</span>';
    return '<span class="race-badge sched">SCHED</span>';
  }

  function renderSchedule(races) {
    const races_ = races || [];
    const run = races_.filter(r => r.completed).length;
    const upc = races_.filter(r => !r.completed).length;
    const next = races_.filter(r => !r.completed)
      .map(r => T.daysUntil(r.event_date)).filter(d => d != null && d >= 0).sort((a, b) => a - b)[0];
    renderStrip([
      { n: T.fmtNum(races_.length), l: 'races' },
      { n: T.fmtNum(run),           l: 'run' },
      { n: T.fmtNum(upc),           l: 'upcoming' },
      { n: (next != null ? 'T-' + next + 'd' : '—'), l: 'next race' },
    ]);
    $('lgPrimaryMeta').textContent = races_.length ? `${races_.length} races · ${run} run` : '';
    if (!races_.length) { $('lgPrimaryBody').innerHTML = '<div class="empty">no races on file</div>'; return; }
    const rows = races_.map(r => {
      const done = r.completed;
      const attrs = done ? ` class="race-done race-click" data-event="${escapeHtml(String(r.espn_event_id))}" data-name="${escapeHtml(r.short_name || r.name || '')}"` : '';
      return `<tr${attrs}>
        <td class="muted">${r.event_date ? T.fmtDate(r.event_date) : '—'}</td>
        <td>${escapeHtml(r.short_name || r.name || '—')}${done ? ' <span class="race-view">results ▸</span>' : ''}</td>
        <td>${raceStatusBadge(r)}</td>
        <td class="muted small">${escapeHtml(r.venue || '')}</td>
      </tr>`;
    }).join('');
    $('lgPrimaryBody').innerHTML = `<div style="overflow-x:auto"><table class="espn-recent race-tbl">
      <thead><tr><th>Date</th><th>Race</th><th>Status</th><th>Track</th></tr></thead>
      <tbody>${rows}</tbody></table></div>`;
    $('lgPrimaryBody').querySelectorAll('tr.race-click').forEach(tr =>
      tr.addEventListener('click', () => loadResults(tr.dataset.event, tr.dataset.name)));
  }

  function renderStandings(rows) {
    const rows_ = rows || [];
    $('lgSecondaryMeta').textContent = rows_.length ? `${rows_.length} drivers` : '';
    if (!rows_.length) { $('lgSecondaryBody').innerHTML = '<div class="empty">no standings yet</div>'; return; }
    const trs = rows_.map(d => `<tr>
      <td class="num muted">${d.rank ?? '—'}</td>
      <td>${escapeHtml(d.driver_name || '—')}${d.driver_abbr ? ` <span class="muted small">${escapeHtml(d.driver_abbr)}</span>` : ''}</td>
      <td class="muted small">${escapeHtml(d.country || '')}</td>
      <td class="num">${d.points != null ? T.fmtNum(d.points) : '—'}</td>
      <td class="num">${d.wins ?? 0}</td>
    </tr>`).join('');
    $('lgSecondaryBody').innerHTML = `<div style="overflow-x:auto"><table class="espn-recent race-tbl">
      <thead><tr><th>#</th><th>Driver</th><th>Country</th><th>Pts</th><th>W</th></tr></thead>
      <tbody>${trs}</tbody></table></div>`;
  }

  async function loadResults(eventId, name) {
    const sec = $('lgResults');
    const bodyEl = $('lgResultsBody');
    $('lgResultsTitle').textContent = (name || 'RACE') + ' — RESULTS';
    sec.removeAttribute('hidden');
    bodyEl.innerHTML = '<div class="empty">loading…</div>';
    sec.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    const res = await window.TerminalAuth.client.rpc('get_espn_racing_results', { p_event_id: eventId });
    if (res.error) { bodyEl.innerHTML = `<div class="empty">${escapeHtml(res.error.message)}</div>`; return; }
    const rows = (res.data || {}).results || [];
    if (!rows.length) { bodyEl.innerHTML = '<div class="empty">no results on file</div>'; return; }
    const trs = rows.map(r => `<tr class="${r.winner ? 'race-winner' : ''}">
      <td class="num">${r.finish_position ?? '—'}</td>
      <td>${escapeHtml(r.driver_name || '—')}${r.winner ? ' <span class="race-badge live">WIN</span>' : ''}</td>
      <td class="muted small">${escapeHtml(r.country || '')}</td>
    </tr>`).join('');
    bodyEl.innerHTML = `<div style="overflow-x:auto"><table class="espn-recent race-tbl">
      <thead><tr><th>Pos</th><th>Driver</th><th>Country</th></tr></thead><tbody>${trs}</tbody></table></div>`;
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
