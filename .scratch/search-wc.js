// Search TEvo for World Cup national teams ESPN has but TEvo home_venues doesn't.
const ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6cml6amVheGxxY3hmcnRjenBxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY5NjE3ODgsImV4cCI6MjA5MjUzNzc4OH0.c-rIrhb-WLzyWAAN1Yf_zJXWnu0E_zZ2XDB_T7urvNc";
const SUPA = "https://hzrizjeaxlqcxfrtczpq.supabase.co";

// 26 ESPN World Cup teams not in TEvo home_venues
const targets = [
  { espn_id:"624",  espn_name:"Algeria" },
  { espn_id:"628",  espn_name:"Australia" },
  { espn_id:"452",  espn_name:"Bosnia-Herzegovina" },
  { espn_id:"2597", espn_name:"Cape Verde" },
  { espn_id:"2850", espn_name:"Congo DR" },
  { espn_id:"11678",espn_name:"Curacao" },
  { espn_id:"450",  espn_name:"Czechia" },
  { espn_id:"2620", espn_name:"Egypt" },
  { espn_id:"4469", espn_name:"Ghana" },
  { espn_id:"2654", espn_name:"Haiti" },
  { espn_id:"469",  espn_name:"Iran" },
  { espn_id:"4375", espn_name:"Iraq" },
  { espn_id:"4789", espn_name:"Ivory Coast" },
  { espn_id:"2917", espn_name:"Jordan" },
  { espn_id:"2869", espn_name:"Morocco" },
  { espn_id:"464",  espn_name:"Norway" },
  { espn_id:"2659", espn_name:"Panama" },
  { espn_id:"4398", espn_name:"Qatar" },
  { espn_id:"655",  espn_name:"Saudi Arabia" },
  { espn_id:"654",  espn_name:"Senegal" },
  { espn_id:"467",  espn_name:"South Africa" },
  { espn_id:"451",  espn_name:"South Korea" },
  { espn_id:"466",  espn_name:"Sweden" },
  { espn_id:"659",  espn_name:"Tunisia" },
  { espn_id:"465",  espn_name:"Türkiye" },
  { espn_id:"2570", espn_name:"Uzbekistan" },
];

async function search(q) {
  const url = `${SUPA}/functions/v1/tevo-perf-find?q=${encodeURIComponent(q)}`;
  const r = await fetch(url, { headers: { Authorization: `Bearer ${ANON}` } });
  return r.json();
}

(async () => {
  const out = [];
  for (const t of targets) {
    // Try several variants: "X National Soccer", "X Soccer", just "X"
    const variants = [
      `${t.espn_name} National Soccer`,
      `${t.espn_name} National`,
      t.espn_name,
    ];
    let pick = null;
    for (const v of variants) {
      const r = await search(v);
      if (r.ok && r.hits && r.hits.length > 0) {
        // filter to soccer-y categories, prefer 'World Cup' or 'Soccer' or 'FIFA'
        const cats = r.hits.filter(h => /soccer|fifa|world\s*cup/i.test(h.category || ''));
        if (cats.length) { pick = { variant: v, hit: cats[0], all: r.hits.slice(0,3) }; break; }
        if (!pick) pick = { variant: v, hit: r.hits[0], all: r.hits.slice(0,3) };
      }
    }
    if (pick) {
      out.push({ espn_id: t.espn_id, espn_name: t.espn_name, tevo_id: pick.hit.id, tevo_name: pick.hit.name, category: pick.hit.category, venue_id: pick.hit.venue_id, venue_name: pick.hit.venue_name, matched_via: pick.variant, alternates: pick.all.map(h=>({id:h.id,name:h.name,cat:h.category})) });
    } else {
      out.push({ espn_id: t.espn_id, espn_name: t.espn_name, status: 'no-hit' });
    }
    process.stderr.write('.');
  }
  process.stderr.write('\n');
  console.log(JSON.stringify(out, null, 2));
})();
