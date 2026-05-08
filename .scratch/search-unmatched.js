// Batch-call tevo-perf-find for all unmatched teams.
// Output: { league, espn_name, espn_id, tevo_id, tevo_name, venue_id, venue_name, category }

const ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6cml6amVheGxxY3hmcnRjenBxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY5NjE3ODgsImV4cCI6MjA5MjUzNzc4OH0.c-rIrhb-WLzyWAAN1Yf_zJXWnu0E_zZ2XDB_T7urvNc";
const SUPA = "https://hzrizjeaxlqcxfrtczpq.supabase.co";

const targets = [
  // NBA — 18 unmatched
  { league: "NBA", espn_id: "1",  espn_name: "Atlanta Hawks" },
  { league: "NBA", espn_id: "2",  espn_name: "Boston Celtics" },
  { league: "NBA", espn_id: "17", espn_name: "Brooklyn Nets" },
  { league: "NBA", espn_id: "30", espn_name: "Charlotte Hornets" },
  { league: "NBA", espn_id: "4",  espn_name: "Chicago Bulls" },
  { league: "NBA", espn_id: "9",  espn_name: "Golden State Warriors" },
  { league: "NBA", espn_id: "10", espn_name: "Houston Rockets" },
  { league: "NBA", espn_id: "12", espn_name: "LA Clippers" },
  { league: "NBA", espn_id: "29", espn_name: "Memphis Grizzlies" },
  { league: "NBA", espn_id: "14", espn_name: "Miami Heat" },
  { league: "NBA", espn_id: "15", espn_name: "Milwaukee Bucks" },
  { league: "NBA", espn_id: "19", espn_name: "Orlando Magic" },
  { league: "NBA", espn_id: "21", espn_name: "Phoenix Suns" },
  { league: "NBA", espn_id: "22", espn_name: "Portland Trail Blazers" },
  { league: "NBA", espn_id: "23", espn_name: "Sacramento Kings" },
  { league: "NBA", espn_id: "28", espn_name: "Toronto Raptors" },
  { league: "NBA", espn_id: "26", espn_name: "Utah Jazz" },
  { league: "NBA", espn_id: "27", espn_name: "Washington Wizards" },
  // NHL — 9 unmatched
  { league: "NHL", espn_id: "1",      espn_name: "Boston Bruins" },
  { league: "NHL", espn_id: "3",      espn_name: "Calgary Flames" },
  { league: "NHL", espn_id: "29",     espn_name: "Columbus Blue Jackets" },
  { league: "NHL", espn_id: "6",      espn_name: "Edmonton Oilers" },
  { league: "NHL", espn_id: "8",      espn_name: "Los Angeles Kings" },
  { league: "NHL", espn_id: "27",     espn_name: "Nashville Predators" },
  { league: "NHL", espn_id: "18",     espn_name: "San Jose Sharks" },
  { league: "NHL", espn_id: "124292", espn_name: "Seattle Kraken" },
  { league: "NHL", espn_id: "22",     espn_name: "Vancouver Canucks" },
  // MLS — 30 unmatched (entire league missing from home_venues)
  { league: "MLS", espn_id: "18418", espn_name: "Atlanta United FC" },
  { league: "MLS", espn_id: "20906", espn_name: "Austin FC" },
  { league: "MLS", espn_id: "9720",  espn_name: "CF Montréal" },
  { league: "MLS", espn_id: "21300", espn_name: "Charlotte FC" },
  { league: "MLS", espn_id: "182",   espn_name: "Chicago Fire FC" },
  { league: "MLS", espn_id: "184",   espn_name: "Colorado Rapids" },
  { league: "MLS", espn_id: "183",   espn_name: "Columbus Crew" },
  { league: "MLS", espn_id: "193",   espn_name: "D.C. United" },
  { league: "MLS", espn_id: "18267", espn_name: "FC Cincinnati" },
  { league: "MLS", espn_id: "185",   espn_name: "FC Dallas" },
  { league: "MLS", espn_id: "6077",  espn_name: "Houston Dynamo FC" },
  { league: "MLS", espn_id: "20232", espn_name: "Inter Miami CF" },
  { league: "MLS", espn_id: "187",   espn_name: "LA Galaxy" },
  { league: "MLS", espn_id: "18966", espn_name: "LAFC" },
  { league: "MLS", espn_id: "17362", espn_name: "Minnesota United FC" },
  { league: "MLS", espn_id: "18986", espn_name: "Nashville SC" },
  { league: "MLS", espn_id: "189",   espn_name: "New England Revolution" },
  { league: "MLS", espn_id: "12011", espn_name: "Orlando City SC" },
  { league: "MLS", espn_id: "10739", espn_name: "Philadelphia Union" },
  { league: "MLS", espn_id: "9723",  espn_name: "Portland Timbers" },
  { league: "MLS", espn_id: "4771",  espn_name: "Real Salt Lake" },
  { league: "MLS", espn_id: "190",   espn_name: "Red Bull New York" },
  { league: "MLS", espn_id: "22529", espn_name: "San Diego FC" },
  { league: "MLS", espn_id: "191",   espn_name: "San Jose Earthquakes" },
  { league: "MLS", espn_id: "9726",  espn_name: "Seattle Sounders FC" },
  { league: "MLS", espn_id: "186",   espn_name: "Sporting Kansas City" },
  { league: "MLS", espn_id: "21812", espn_name: "St. Louis CITY SC" },
  { league: "MLS", espn_id: "7318",  espn_name: "Toronto FC" },
  { league: "MLS", espn_id: "9727",  espn_name: "Vancouver Whitecaps" },
  // WNBA — 2 unmatched (2026 expansion)
  { league: "WNBA", espn_id: "132052", espn_name: "Portland Fire" },
  { league: "WNBA", espn_id: "131935", espn_name: "Toronto Tempo" },
];

function norm(s) {
  return (s || '').normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase()
    .replace(/\./g, '').replace(/[^\w\s]/g, ' ').replace(/\s+/g, ' ').trim();
}

async function search(q) {
  const url = `${SUPA}/functions/v1/tevo-perf-find?q=${encodeURIComponent(q)}`;
  const r = await fetch(url, { headers: { Authorization: `Bearer ${ANON}` } });
  return r.json();
}

(async () => {
  const out = [];
  for (const t of targets) {
    const r = await search(t.espn_name);
    if (!r.ok || !r.hits || r.hits.length === 0) {
      out.push({ ...t, status: "no-hits", error: r.error || r.body?.slice(0,200) });
      continue;
    }
    // pick best hit: exact normalized name match in correct category, fall back to first
    const targetNorm = norm(t.espn_name);
    const exact = r.hits.find(h => norm(h.name) === targetNorm);
    const best = exact || r.hits.find(h => h.category && t.league.includes(h.category)) || r.hits[0];
    out.push({
      league: t.league,
      espn_id: t.espn_id, espn_name: t.espn_name,
      tevo_id: best.id, tevo_name: best.name, tevo_category: best.category,
      venue_id: best.venue_id, venue_name: best.venue_name, venue_location: best.venue_location,
      match_quality: exact ? "exact" : "category" in (best || {}) ? "category-fallback" : "first-hit",
      all_hits_count: r.hits.length,
      // include alternates if not exact, for manual review
      alternates: exact ? undefined : r.hits.slice(0, 3).map(h => ({ id: h.id, name: h.name, category: h.category })),
    });
    process.stderr.write('.');
  }
  process.stderr.write('\n');
  console.log(JSON.stringify(out, null, 2));
})();
