// Build migration 15 INSERT statement for performer_external_ids (source='espn')
// Combines: 110 name-matches against performer_home_venues + 59 TEvo search results

const fs = require('fs');

// Load the home_venues + ESPN match results (regenerate via match.js logic)
const tevoTeams = JSON.parse(fs.readFileSync('.scratch/tevo-home-venues.json', 'utf8'));
const searchHits = JSON.parse(fs.readFileSync('.scratch/unmatched-results.json', 'utf8'));

const LEAGUES = {
  nfl: { espn: 'football/nfl', league: 'NFL' },
  nba: { espn: 'basketball/nba', league: 'NBA' },
  mlb: { espn: 'baseball/mlb', league: 'MLB' },
  nhl: { espn: 'hockey/nhl', league: 'NHL' },
  mls: { espn: 'soccer/usa.1', league: 'MLS' },
  wnba: { espn: 'basketball/wnba', league: 'WNBA' },
};

function norm(s) {
  return (s || '').normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase()
    .replace(/\./g, '').replace(/[^\w\s]/g, ' ').replace(/\s+/g, ' ').trim();
}
function normSoccer(s) { return norm(s).replace(/\b(fc|sc|cf)\b/g, '').replace(/\s+/g, ' ').trim(); }

const rows = [];

// 1) home_venue exact matches
for (const [k, cfg] of Object.entries(LEAGUES)) {
  const espnFile = `.scratch/${k}.json`;
  if (!fs.existsSync(espnFile)) continue;
  const espnRaw = JSON.parse(fs.readFileSync(espnFile, 'utf8'));
  const espn = espnRaw.sports[0].leagues[0].teams.map(x => x.team).map(t => ({
    id: t.id, name: t.displayName, abbr: t.abbreviation, slug: t.slug,
    norm: cfg.league === 'MLS' ? normSoccer(t.displayName) : norm(t.displayName),
  }));
  const tevo = tevoTeams
    .filter(p => p.league === cfg.league)
    .filter(p => !/\b(playoff|finals|series|championship|all\s*star|draft|game|preseason|summer\s*league|hall\s*of\s*fame|home\s*run|winter\s*classic|stadium\s*series|conference|semifinal|international\s*series)/i.test(p.performer_name))
    .map(p => ({ ...p, norm: cfg.league === 'MLS' ? normSoccer(p.performer_name) : norm(p.performer_name) }));

  const tevoMap = new Map();
  for (const t of tevo) if (!tevoMap.has(t.norm)) tevoMap.set(t.norm, t);
  for (const e of espn) {
    const t = tevoMap.get(e.norm);
    if (t) rows.push({
      tevo_id: t.performer_id, espn_id: e.id, league: cfg.league,
      espn_name: e.name, abbr: e.abbr, slug: e.slug,
      source: 'home_venues',
    });
  }
}

// 2) search hits (one per league/espn_id)
for (const h of searchHits) {
  if (h.status === 'no-hits') continue;
  rows.push({
    tevo_id: h.tevo_id, espn_id: h.espn_id, league: h.league,
    espn_name: h.espn_name, slug: null, abbr: null,
    source: 'tevo-perf-find',
  });
}

// 3) manual fixes for the 2 no-hits
rows.push({ tevo_id: 51427, espn_id: '18418', league: 'MLS', espn_name: 'Atlanta United FC', source: 'manual', notes: 'TEvo lists as "Atlanta United"' });
rows.push({ tevo_id: 16076, espn_id: '9720',  league: 'MLS', espn_name: 'CF Montréal',       source: 'manual', notes: 'TEvo uses ASCII "CF Montreal"' });

// dedupe by (tevo_id) keeping first
const seen = new Set();
const finalRows = [];
for (const r of rows) {
  if (seen.has(r.tevo_id)) continue;
  seen.add(r.tevo_id);
  finalRows.push(r);
}

const byL = {};
for (const r of finalRows) byL[r.league] = (byL[r.league] || 0) + 1;
console.error('league counts:', byL);
console.error('total:', finalRows.length);

// Emit SQL INSERT VALUES
const slugMap = {NBA:'basketball/nba', NFL:'football/nfl', MLB:'baseball/mlb', NHL:'hockey/nhl', MLS:'soccer/usa.1', WNBA:'basketball/wnba'};
const valuesLines = finalRows.map(r => {
  const meta = JSON.stringify({
    espn_slug: r.slug || slugMap[r.league],
    espn_abbr: r.abbr || null,
    espn_display_name: r.espn_name,
    backfilled_from: r.source,
    notes: r.notes || null,
    backfilled_at: '__NOW__',
  }).replace(/'/g, "''");
  const name = r.espn_name.replace(/'/g, "''");
  return `  (${r.tevo_id}, 'espn', '${r.espn_id}', '${name}', '${r.league}', '${meta}'::jsonb)`;
});
console.log(`-- migration 15: extend performer_external_ids ESPN coverage to all big-5 + WNBA`);
console.log(`-- ${finalRows.length} teams total. Idempotent via NOT EXISTS guard.`);
console.log(``);
console.log(`with new_rows(performer_id, source, external_id, external_name, league, meta) as (values`);
console.log(valuesLines.join(',\n'));
console.log(`)`);
console.log(`insert into performer_external_ids (performer_id, source, external_id, external_name, league, meta, set_at)`);
console.log(`select n.performer_id, n.source, n.external_id, n.external_name, n.league,`);
console.log(`       jsonb_set(n.meta, '{backfilled_at}', to_jsonb(now()::text)),`);
console.log(`       now()`);
console.log(`from new_rows n`);
console.log(`where not exists (`);
console.log(`  select 1 from performer_external_ids pei`);
console.log(`  where pei.performer_id = n.performer_id and pei.source = 'espn'`);
console.log(`);`);
