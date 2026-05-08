// Build TEvo↔ESPN match table by joining .scratch/{league}.json against
// the performer_home_venues dump (paste from MCP exec_sql below).
// Reports: matched, unmatched-espn, unmatched-tevo per league.

const fs = require('fs');

const LEAGUES = {
  nfl: { espn: 'football/nfl', league: 'NFL' },
  nba: { espn: 'basketball/nba', league: 'NBA' },
  mlb: { espn: 'baseball/mlb', league: 'MLB' },
  nhl: { espn: 'hockey/nhl', league: 'NHL' },
  mls: { espn: 'soccer/usa.1', league: 'MLS' },
  wnba: { espn: 'basketball/wnba', league: 'WNBA' },
};

// strip diacritics, punctuation, "FC"/"SC"/"CF" suffixes for soccer match
function norm(s) {
  return (s || '')
    .normalize('NFKD').replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/\./g, '')
    .replace(/[^\w\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}
// soccer-friendly: drop trailing fc/sc/cf
function normSoccer(s) {
  return norm(s).replace(/\b(fc|sc|cf)\b/g, '').replace(/\s+/g, ' ').trim();
}

const tevoTeams = JSON.parse(fs.readFileSync('.scratch/tevo-home-venues.json', 'utf8'));

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
    // exclude league-level "events" (NBA Finals, Super Bowl, NHL Draft, etc.)
    .filter(p => !/\b(playoff|finals|series|championship|all\s*star|draft|game|preseason|summer\s*league|hall\s*of\s*fame|home\s*run|winter\s*classic|stadium\s*series|conference|semifinal)/i.test(p.performer_name))
    .map(p => ({
      id: p.performer_id, name: p.performer_name,
      venue_id: p.venue_id, venue_name: p.venue_name,
      norm: cfg.league === 'MLS' ? normSoccer(p.performer_name) : norm(p.performer_name),
    }));

  const matched = [];
  const unmatchedEspn = [];
  const tevoNormSet = new Map();
  for (const t of tevo) {
    if (!tevoNormSet.has(t.norm)) tevoNormSet.set(t.norm, []);
    tevoNormSet.get(t.norm).push(t);
  }
  const usedTevo = new Set();
  for (const e of espn) {
    const cands = tevoNormSet.get(e.norm) || [];
    if (cands.length === 1) {
      matched.push({ espn: e, tevo: cands[0] });
      usedTevo.add(cands[0].id);
    } else if (cands.length > 1) {
      // shouldn't happen, but pick first deterministic
      matched.push({ espn: e, tevo: cands[0], note: 'ambiguous' });
      usedTevo.add(cands[0].id);
    } else {
      unmatchedEspn.push(e);
    }
  }
  const unmatchedTevo = tevo.filter(t => !usedTevo.has(t.id));

  console.log(`\n=== ${cfg.league} (espn=${espn.length}, tevo=${tevo.length}) ===`);
  console.log(`matched: ${matched.length}`);
  for (const m of matched) {
    const note = m.note ? ` [${m.note}]` : '';
    console.log(`  ${m.tevo.id.toString().padEnd(8)} ${m.tevo.name.padEnd(30)} <-> espn:${m.espn.id.padEnd(8)} ${m.espn.name}${note}`);
  }
  if (unmatchedEspn.length) {
    console.log(`unmatched ESPN -> need TEvo search:`);
    for (const e of unmatchedEspn) console.log(`  espn:${e.id} ${e.name}`);
  }
  if (unmatchedTevo.length) {
    console.log(`unmatched TEvo -> no ESPN team (probably defunct/expansion):`);
    for (const t of unmatchedTevo) console.log(`  tevo:${t.id} ${t.name}`);
  }
}
