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

  // Additional leagues carried over from the D0 wireframe that have no ESPN
  // performer mapping ingested yet. Shown in the picker (so the full slate is
  // present + navigable) but their panels honestly report "ingest pending"
  // rather than faking rows — get_performers_by_league returns empty for them,
  // and the render path degrades to the pending state. If a league is later
  // ingested, it lights up automatically (no code change).
  const EXTRA_LEAGUES = [
    { key: 'CFB',    label: 'CFB',    sub: 'College' },
    { key: 'CBB',    label: 'CBB',    sub: 'College' },
    { key: 'CFL',    label: 'CFL',    sub: 'Pro' },
    { key: 'NWSL',   label: 'NWSL',   sub: 'Pro' },
    { key: 'Tennis', label: 'TENNIS', sub: 'ATP·WTA' },
    { key: 'PBR',    label: 'PBR',    sub: 'Tour' },
    { key: 'PGA',    label: 'PGA',    sub: 'Tour' },
  ];
  const EXTRA_KEYS = new Set(EXTRA_LEAGUES.map(l => l.key));

  // Broadway is a performer CATEGORY, not a home/road league — it gets a show
  // roster + a performance slate, but not the sports-only demand/blind panels.
  const BROADWAY_KEY = 'Broadway';

  // Tournament/series leagues whose "performers" are events (tournaments, Grands
  // Prix) rather than home/road teams. Their inventory is seasonal + months out,
  // so the slate spans a year and the panels use tournament (not team) wording.
  // Mapped into performer_home_venues by mig 20260708150000, so the same
  // get_performers_by_league / get_league_slate seam drives them.
  const TOURNAMENT_LEAGUES = new Set(['Tennis', 'F1']);
  // Racing series key -> the performer_home_venues league that carries its
  // ticketed performers + future-events slate. Only F1 has TEvo ticket
  // inventory (N.A. Grands Prix); NASCAR series stay ESPN-schedule-only and are
  // deliberately absent, so their ticket panels stay hidden.
  const RACING_TICKET_LEAGUE = { 'f1': 'F1' };

  let _teamLeagues = [];   // [{ key, label, teams }] from /api/broker/leagues
  let _perfIndex = null;   // cached get_broker_performer_index payload (Broadway roster)
  let _leagueKpis = null;  // { LEAGUE: {total_revenue, tickets_sold, ...} } from get_d0_league_kpis
  let _curLeague = null;   // active league key (so a late KPI load can paint its strip)
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
    // League sales KPIs — one call for all leagues, cached; paints the active
    // league's strip when it lands (fire-and-forget, non-blocking).
    loadLeagueKpis().catch(e => console.error('[leagueKpis]', e));
    load(pickInitial(currentLeague()));
  }

  // Realized-sales KPIs per league (get_d0_league_kpis, mig 20260708120100).
  // Read-only; hidden honestly if the RPC isn't deployed yet.
  async function loadLeagueKpis() {
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client) return;
    const res = await Auth.client.rpc('get_d0_league_kpis');
    if (res.error) return;   // 42883 (not deployed) / forbidden → strip stays hidden
    _leagueKpis = {};
    (res.data || []).forEach(r => { _leagueKpis[r.league] = r; });
    if (_curLeague) renderSalesStrip(_curLeague);
  }

  function renderSalesStrip(key) {
    const sec = $('lgSales');
    const k = _leagueKpis && _leagueKpis[key];
    if (!k) { sec.hidden = true; return; }
    sec.hidden = false;
    const usdBig = v => v == null ? '—'
      : (Math.abs(+v) >= 1e6 ? '$' + (+v / 1e6).toFixed(1) + 'M' : '$' + T.fmtNum(Math.round(+v)));
    const usd = v => v == null ? '—' : '$' + T.fmtNum(Math.round(+v));
    $('lgSalesStrip').innerHTML = [
      { n: usdBig(k.total_revenue),          l: 'revenue' },
      { n: T.fmtNum(k.tickets_sold),         l: 'tickets sold' },
      { n: usd(k.median_price),              l: 'median px' },
      { n: usd(k.weighted_median_price),     l: 'wtd median' },
      { n: T.fmtNum(k.sale_lines),           l: 'sale lines' },
    ].map(c => `<div class="kpi-cell"><span class="kpi-num">${c.n}</span>` +
               `<span class="kpi-lbl">${escapeHtml(c.l)}</span></div>`).join('');
  }

  // Per-league GAME SLATE — upcoming games (get_league_slate, mig 20260708130000),
  // each row deep-linking to the event page (EVO data). Fire-and-forget; guards
  // against a stale render if the operator switches leagues mid-flight.
  const SLATE_DAYS = 30;
  async function loadSlate(key, days) {
    const sec = $('lgSlate');
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client) { sec.hidden = true; return; }
    sec.hidden = false;
    const isBway = key === BROADWAY_KEY;
    const isTourn = TOURNAMENT_LEAGUES.has(key);
    // Tournament/racing inventory is months out — span a year so the GPs/majors
    // actually appear; weekly team leagues stay at 30 days.
    const win = days || (isTourn ? 365 : SLATE_DAYS);
    const unit = isBway ? 'performances' : (isTourn ? 'events' : 'games');
    const titleWord = isBway ? 'UPCOMING PERFORMANCES' : (isTourn ? 'UPCOMING EVENTS' : 'GAME SLATE');
    const winLbl = win >= 300 ? 'NEXT 12 MONTHS' : ('NEXT ' + win + ' DAYS');
    $('lgSlateTitle').textContent = titleWord + ' — ' + winLbl;
    $('lgSlateMeta').textContent = '';
    $('lgSlateBody').innerHTML = '<div class="empty">loading…</div>';
    const res = await Auth.client.rpc('get_league_slate',
      { p_league: key, p_days: win, p_limit: 200 });
    if (_curLeague !== key) return;                 // switched away mid-fetch
    if (res.error) { sec.hidden = true; return; }   // 42883 / forbidden → hide honestly
    const rows = res.data || [];
    if (!rows.length) {
      $('lgSlateBody').innerHTML = `<div class="empty">no upcoming ${unit} in the ${winLbl.toLowerCase()}</div>`;
      return;
    }
    const evCol = isBway ? 'Show' : (isTourn ? 'Event' : 'Game');
    const money = v => (v == null ? '—' : '$' + T.fmtNum(Math.round(+v)));
    const blind = r => (+r.tickets_count || 0) > 0 && (+r.owned_tickets_count || 0) === 0;
    $('lgSlateMeta').textContent = `${rows.length} ${unit} · ${rows.filter(blind).length} we own 0`;
    const trs = rows.slice(0, 80).map(r => {
      const d = T.daysUntil(r.occurs_at_local);
      const owned = +r.owned_tickets_count || 0;
      const divTag = r.division
        ? `<span class="slate-div">${escapeHtml(confAbbr(r.conference))} ${escapeHtml(r.division)}</span>`
        : (r.conference ? `<span class="slate-div">${escapeHtml(r.conference)}</span>` : '');
      const blindBadge = blind(r) ? '<span class="slate-blind" title="open market, we own 0">BLIND</span>' : '';
      const ownPct = r.owned_share != null ? T.fmtPct(+r.owned_share * 100, 0) : '—';
      return `<tr class="slate-row" data-event="${r.event_id}">
        <td class="muted small">${r.occurs_at_local ? escapeHtml(T.fmtDate(r.occurs_at_local)) : '—'}</td>
        <td><a href="event.html?event=${r.event_id}" onclick="event.stopPropagation()">${escapeHtml(r.event_name || ('Event ' + r.event_id))}</a>${blindBadge}${divTag}
            ${r.venue_name ? `<div class="muted small">${escapeHtml(r.venue_name)}</div>` : ''}</td>
        <td class="num">${d === null ? '—' : d}</td>
        <td class="num">${r.tickets_count ? T.fmtNum(r.tickets_count) : '—'}</td>
        <td class="num">${money(r.getin_price)}</td>
        <td class="num ${owned ? 'ours' : ''}">${owned ? T.fmtNum(owned) : '—'}</td>
        <td class="num ${owned ? 'ours' : ''}">${ownPct}</td>
      </tr>`;
    }).join('');
    $('lgSlateBody').innerHTML =
      `<div style="overflow-x:auto"><table class="espn-recent">
        <thead><tr><th>Date</th><th>${evCol}</th><th class="num">T-days</th>
        <th class="num" title="market tickets available">Mkt qty</th>
        <th class="num" title="cheapest listing (get-in)">Get-in</th>
        <th class="num" title="tickets we own">Owned</th>
        <th class="num" title="our share of the market">Own%</th></tr></thead>
        <tbody>${trs}</tbody></table></div>` +
      (rows.length > 80 ? `<div class="lg-note">showing the soonest 80 of ${rows.length} ${unit}.</div>` : '');
    $('lgSlateBody').querySelectorAll('tr.slate-row').forEach(tr =>
      tr.addEventListener('click', () => { window.location.href = 'event.html?event=' + tr.dataset.event; }));
  }

  function pickInitial(want) {
    if (want) {
      if (isRacing(want)) return want;
      if (want === BROADWAY_KEY || want.toLowerCase() === 'broadway') return BROADWAY_KEY;
      const hit = _teamLeagues.find(l => String(l.key).toLowerCase() === want.toLowerCase());
      if (hit) return hit.key;
      const ex = EXTRA_LEAGUES.find(l => l.key.toLowerCase() === want.toLowerCase());
      if (ex) return ex.key;
    }
    if (_teamLeagues.length) return _teamLeagues[0].key;
    return RACING_SERIES[0].key;
  }

  function buildPicker() {
    const picker = $('lgPicker');
    const btn = (key, label, sub, kind) =>
      `<button class="lg-btn" data-league="${escapeHtml(key)}" data-kind="${kind}" role="tab">` +
      `${escapeHtml(label)}<span class="sub">${escapeHtml(sub)}</span></button>`;
    // Backend team leagues first, then the wireframe carry-over leagues (dedup
    // by key so a backend-promoted league never doubles), then racing series.
    const extras = EXTRA_LEAGUES.filter(e => !_teamLeagues.some(l => l.key === e.key));
    const teamBtns =
      _teamLeagues.map(l => btn(l.key, l.label, (l.teams ? l.teams + ' tm' : 'teams'), 'team')).join('') +
      extras.map(l => btn(l.key, l.label, l.sub, 'team')).join('') +
      btn(BROADWAY_KEY, 'BROADWAY', 'Theater', 'broadway');
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
    else if (key === BROADWAY_KEY) loadBroadway(key);
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
    _curLeague = key;
    $('lgGrid').hidden = false;      // restore the ranking/blind-spots grid (Broadway hides it)
    renderSalesStrip(key);           // paint from cache if KPIs already loaded
    loadSlate(key).catch(e => console.error('[slate]', e));   // per-game slate, parallel
    const isExtra = EXTRA_KEYS.has(key);
    const isTourn = TOURNAMENT_LEAGUES.has(key);
    const unitCap = isTourn ? 'TOURNAMENTS' : 'TEAMS';
    const label = displayLeagueLabel(key);
    // Tournament leagues (Tennis) carry real performers/venues/events via
    // performer_home_venues, so they're no longer "ingest pending".
    setHero(shortCode(key), leagueLongName(key, label),
      isTourn ? 'Tournament series · upcoming events, venues & market'
              : (isExtra ? 'ESPN league · ingest pending (no performer mapping yet)'
                         : 'Team league · per-team demand & owned position'));
    T.setStatus('Loading ' + label + '…');
    $('lgPerformers').hidden = false;
    $('lgPerformersTitle').textContent = 'PERFORMERS — ' + label;
    $('lgPerformersMeta').textContent = '';
    $('lgPerformersBody').innerHTML = '<div class="empty">loading…</div>';
    $('lgPrimaryTitle').textContent = unitCap + ' — BY DEMAND';
    $('lgSecondaryTitle').textContent = 'BLIND SPOTS — ' + unitCap + ' WE DON’T OWN';
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
      $('lgPerformersBody').innerHTML = `<div class="empty">${escapeHtml(e.message)}</div>`;
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
        conf: p.conference || null, div: p.division || null,
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

    // Performers roster — every team in the league as a linked chip.
    renderPerformers(teams, label, isExtra);

    // Primary — full demand ranking with inline bars.
    const pendingMsg = isExtra
      ? `${escapeHtml(label)} isn’t ingested yet — no ESPN performer mapping. The major leagues + racing are live.`
      : 'no ESPN-tracked team metrics for this league yet';
    $('lgPrimaryMeta').textContent = teams.length ? `${teams.length} ${unitCap.toLowerCase()} · ranked by market tix` : '';
    if (!teams.length) {
      $('lgPrimaryBody').innerHTML = `<div class="empty">${pendingMsg}</div>`;
    } else {
      const max = Math.max(1, ...teams.map(t => t.demand));
      $('lgPrimaryBody').innerHTML = teams.map((t, i) => {
        const nameHtml = t.id != null
          ? `<a href="performer.html?performer=${t.id}">${escapeHtml(t.name)}</a>`
          : `<span class="nm">${escapeHtml(t.name)}</span>`;
        const dot = t.blind ? '<span class="blind-dot" title="blind spot — open market, we own 0">◇</span>' : '';
        const divTag = t.div ? `<span class="dm-div">${escapeHtml(confAbbr(t.conf))} ${escapeHtml(t.div)}</span>`
                     : (t.conf ? `<span class="dm-div">${escapeHtml(t.conf)}</span>` : '');
        return `<div class="dm-row">
          <span class="dm-rank">${i + 1}</span>
          <span class="dm-name">${nameHtml}${dot}${divTag}
            <div class="dm-bar"><div class="dm-bar-fill" style="width:${Math.round(t.demand / max * 100)}%"></div></div>
          </span>
          <span class="dm-val" title="market tickets (home+road)">${num(t.demand)}</span>
          <span class="dm-owned ${t.owned ? 'ours' : ''}" title="owned tickets (home+road)">${t.owned ? num(t.owned) : '—'}</span>
        </div>`;
      }).join('') +
        `<div class="lg-note">market/owned tickets aggregate this ${isTourn ? 'tournament’s' : 'team’s home + road'} events. Bar = share of the league’s top ${isTourn ? 'tournament' : 'team'} by market tickets. ` +
        `Per-event detail is in the slate above; click a ${isTourn ? 'tournament' : 'team'} for its full event history.</div>`;
    }

    // Secondary — blind spots (demand, zero owned): the actionable gaps.
    $('lgSecondaryMeta').textContent = blinds.length ? `${blinds.length} of ${teams.length}` : '';
    if (!teams.length) {
      $('lgSecondaryBody').innerHTML = '<div class="empty">—</div>';
    } else if (!blinds.length) {
      $('lgSecondaryBody').innerHTML = `<div class="empty">no blind spots — we hold inventory in every ranked ${isTourn ? 'tournament' : 'team'}</div>`;
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
          <thead><tr><th>${isTourn ? 'Tournament' : 'Team'}</th><th class="num">Events</th>
          <th class="num" title="market tickets, home+road">Mkt tix</th>
          <th class="num" title="market median (home)">Mkt med</th></tr></thead>
          <tbody>${rows}</tbody></table></div>`;
    }
  }

  // Performers roster — one linked chip per performer in the league (alpha
  // order), each opening its performer page. When the league has no ingested
  // performers it reports the pending state rather than an empty box.
  function renderPerformers(teams, label, isExtra) {
    if (!teams.length) {
      $('lgPerformersMeta').textContent = '';
      $('lgPerformersBody').innerHTML = isExtra
        ? `<div class="empty">${escapeHtml(label)} isn’t ingested yet — no ESPN performer mapping. The major leagues + racing are live.</div>`
        : '<div class="empty">no performers mapped for this league yet</div>';
      return;
    }
    const byName = (a, b) => a.name.localeCompare(b.name);
    const chip = t => {
      const ev = t.events ? `<span class="pc-ev" title="upcoming events tracked">${t.events}</span>` : '';
      return t.id != null
        ? `<a class="perf-chip" href="performer.html?performer=${t.id}" title="Open ${escapeHtml(t.name)} performer page">${escapeHtml(t.name)}${ev}</a>`
        : `<span class="perf-chip plain" title="no performer page mapped">${escapeHtml(t.name)}${ev}</span>`;
    };
    // Split by division — group key is conference+division (e.g. "AFC East",
    // "Eastern Atlantic"), conference alone (MLS), or one flat group when the
    // league isn't divisioned (WNBA / not-yet-ingested extras).
    const groups = new Map();
    teams.forEach(t => {
      const gkey = t.div ? `${t.conf} ${t.div}` : (t.conf || '');
      if (!groups.has(gkey)) groups.set(gkey, []);
      groups.get(gkey).push(t);
    });
    if (groups.size === 1 && groups.has('')) {
      $('lgPerformersMeta').textContent = `${teams.length} linked`;
      $('lgPerformersBody').innerHTML =
        '<div class="perf-chips">' + [...teams].sort(byName).map(chip).join('') + '</div>';
      return;
    }
    const gkeys = [...groups.keys()].sort((a, b) => a.localeCompare(b));
    $('lgPerformersMeta').textContent = `${teams.length} linked · ${gkeys.length} divisions`;
    $('lgPerformersBody').innerHTML = gkeys.map(gk => {
      const list = groups.get(gk).sort(byName);
      return `<div class="perf-group">
        <div class="perf-group-hd">${escapeHtml(gk || 'Other')} <span class="muted small">${list.length}</span></div>
        <div class="perf-chips">${list.map(chip).join('')}</div>
      </div>`;
    }).join('');
  }

  // Short conference label for the inline division tag ("American League" → "AL").
  function confAbbr(c) {
    return c === 'American League' ? 'AL' : c === 'National League' ? 'NL' : (c || '');
  }
  function displayLeagueLabel(key) {
    const bk = _teamLeagues.find(l => l.key === key);
    if (bk) return bk.label || key;
    const ex = EXTRA_LEAGUES.find(l => l.key === key);
    if (ex) return ex.label;
    return key;
  }
  function shortCode(key) {
    const k = String(key).toUpperCase();
    return k === 'WORLD CUP' ? 'WC' : k === 'TENNIS' ? 'TEN' : k.slice(0, 4);
  }
  function leagueLongName(key, label) {
    const LONG = {
      NBA: 'National Basketball Association', MLB: 'Major League Baseball',
      NHL: 'National Hockey League', NFL: 'National Football League',
      MLS: 'Major League Soccer', WNBA: "Women's National Basketball Association",
      'World Cup': 'FIFA World Cup',
      CFB: 'College Football', CBB: 'College Basketball',
      CFL: 'Canadian Football League', NWSL: "National Women's Soccer League",
      Tennis: 'Tennis · ATP & WTA', PBR: 'Professional Bull Riders', PGA: 'PGA Tour',
    };
    return LONG[key] || LONG[label] || label;
  }

  // ------------------------------------------------------------------
  // Broadway — a performer category (shows), not a home/road league.
  // Roster from the performer directory (Broadway bucket) + the shared game
  // slate (show performances). Sports-only panels (demand/blind/sales) hidden.
  // ------------------------------------------------------------------
  async function getPerformerIndex() {
    if (_perfIndex) return _perfIndex;
    const Auth = window.TerminalAuth;
    const res = await Auth.client.rpc('get_broker_performer_index');
    if (res.error) throw new Error(res.error.message || 'performer index error');
    _perfIndex = res.data || {};
    return _perfIndex;
  }

  async function loadBroadway(key) {
    _curLeague = key;
    setHero('BWAY', 'Broadway', 'Theater · shows & upcoming performances');
    T.setStatus('Loading Broadway…');
    $('lgGrid').hidden = true;       // no home/road ranking or blind-spots for theater
    $('lgSales').hidden = true;      // Broadway isn't in d0_league_summary
    $('lgPerformers').hidden = false;
    $('lgPerformersTitle').textContent = 'SHOWS';
    $('lgPerformersMeta').textContent = '';
    $('lgPerformersBody').innerHTML = '<div class="empty">loading…</div>';
    // Upcoming performances reuse the shared slate panel + RPC (Broadway anchor).
    loadSlate(key).catch(e => console.error('[slate]', e));

    let idx;
    try { idx = await getPerformerIndex(); }
    catch (e) {
      if (_curLeague !== key) return;
      renderStrip([{ n: '—', l: 'shows' }]);
      $('lgPerformersBody').innerHTML = `<div class="empty">${escapeHtml(e.message)}</div>`;
      T.setStatus(e.message, 'err');
      return;
    }
    if (_curLeague !== key) return;
    const bucket = (idx.leagues && idx.leagues.Broadway) || [];
    const shows = bucket.map(b => ({
      id: b.tevo_performer_id,
      name: b.display_name || b.performer_name || b.name || '—',
      events: b.events_count_next_90d || 0,
      conf: null, div: null,
    }));
    const upcoming = shows.reduce((s, x) => s + (x.events || 0), 0);
    renderStrip([
      { n: T.fmtNum(shows.length),  l: 'shows' },
      { n: T.fmtNum(upcoming),      l: 'perfs · next 90d' },
    ]);
    renderPerformers(shows, 'Broadway', false);
    T.setStatus('Loaded', 'ok');
  }

  // ------------------------------------------------------------------
  // Racing series — the merged former Racing page (unchanged behaviour)
  // ------------------------------------------------------------------
  async function loadRacing(series) {
    setHero(series === 'f1' ? 'F1' : 'NASCAR', RACING_NAME[series] || series, RACING_SUB[series] || 'Motorsport');
    T.setStatus('Loading ' + (RACING_NAME[series] || series) + '…');
    // Ticketed performers/venues/events exist only for series with TEvo
    // inventory (F1's N.A. Grands Prix); NASCAR is ESPN-schedule-only.
    const ticketLeague = RACING_TICKET_LEAGUE[series] || null;
    // _curLeague gates loadSlate's stale-guard; set to the ticket league for F1
    // (so its slate paints), null for NASCAR. Racing has no d0_sales_fact KPIs.
    _curLeague = ticketLeague;
    $('lgGrid').hidden = false;      // racing uses the grid for SCHEDULE + STANDINGS
    $('lgSales').hidden = true;
    if (ticketLeague) {
      loadRacingTickets(series, ticketLeague).catch(e => console.error('[racing-tix]', e));
    } else {
      $('lgPerformers').hidden = true;
      $('lgSlate').hidden = true;    // NASCAR uses the SCHEDULE panel below instead
    }
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

  // Ticketed-inventory overlay for a racing series that has TEvo events (F1):
  // the Grand Prix performers (linked chips) + a per-event future slate (venue,
  // get-in, market/owned) — the same performer_home_venues / get_league_slate
  // seam the team leagues use, layered above the ESPN schedule/standings grid.
  // NASCAR series never reach here (no ticket league mapped), so their panels
  // stay hidden. Guards on _curLeague so a mid-flight series switch can't paint
  // stale rows.
  async function loadRacingTickets(series, leagueKey) {
    $('lgPerformers').hidden = false;
    $('lgPerformersTitle').textContent = 'GRANDS PRIX — TICKETED';
    $('lgPerformersMeta').textContent = '';
    $('lgPerformersBody').innerHTML = '<div class="empty">loading…</div>';
    // Future-events slate (year window — GPs are months out). Fire-and-forget.
    loadSlate(leagueKey, 365).catch(e => console.error('[racing-slate]', e));

    let payload;
    try {
      payload = await T.api('/api/broker/performers/by-league/' + encodeURIComponent(leagueKey));
    } catch (e) {
      if (_curLeague !== leagueKey) return;
      $('lgPerformersBody').innerHTML = `<div class="empty">${escapeHtml(e.message)}</div>`;
      return;
    }
    if (_curLeague !== leagueKey) return;   // switched series mid-fetch
    const races = (payload.performers || []).map(p => {
      const h = p.home || {}, r = p.road || {};
      return {
        id: p.performer_id, name: p.performer_name || '—',
        events: (+h.events || 0) + (+r.events || 0), conf: null, div: null,
      };
    });
    $('lgPerformersMeta').textContent = races.length ? `${races.length} linked` : '';
    renderPerformers(races, leagueKey, false);
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
