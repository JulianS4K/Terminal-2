// Probe what ESPN actually returns at each endpoint we use.
// Returns PRUNED summaries focused on media/logo/image fields so we can audit
// what we're capturing vs. what's available.
//
// Captured into git 2026-05-08 by code via audit-and-commit. Diagnostic helper
// from copilot — useful for figuring out what fields ESPN exposes that we're
// not yet capturing (e.g. did `pickVenueMap` find a real map URL anywhere?).
//
// Auth: verify_jwt=true. Manual-invocation diagnostic — not on cron.

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('POST only', { status: 405 });
  const body = await req.json().catch(() => ({}));
  const targets: { name: string; url: string }[] = [
    { name: 'team_full',       url: 'https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams/18' },
    { name: 'team_roster',     url: 'https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams/18/roster' },
    { name: 'team_schedule',   url: 'https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams/18/schedule' },
    { name: 'scoreboard',      url: 'https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard' },
    { name: 'standings',       url: 'https://site.api.espn.com/apis/site/v2/sports/basketball/nba/standings' },
    { name: 'athlete_full',    url: 'https://site.web.api.espn.com/apis/common/v3/sports/basketball/nba/athletes/1966' },
    { name: 'athlete_overview', url: 'https://site.web.api.espn.com/apis/common/v3/sports/basketball/nba/athletes/1966/overview' },
    { name: 'athlete_bio',     url: 'https://site.web.api.espn.com/apis/common/v3/sports/basketball/nba/athletes/1966/bio' },
    { name: 'news',            url: 'https://site.api.espn.com/apis/site/v2/sports/basketball/nba/news' },
    { name: 'team_injuries',   url: 'https://site.web.api.espn.com/apis/site/v2/sports/basketball/nba/teams/18/injuries' },
  ];
  const out: any[] = [];
  for (const t of targets) {
    try {
      const r = await fetch(t.url, { headers: { 'User-Agent': 's4k-audit' } });
      const j = await r.json();
      const keys = Object.keys(j);
      const found: any = {};
      function walk(node: any, path: string, depth: number) {
        if (depth > 5 || !node) return;
        if (typeof node === 'string') {
          if (/^https?:\/\/.*\.(png|jpg|jpeg|svg|webp|gif)/i.test(node)) {
            found[path] = node;
          }
        } else if (Array.isArray(node)) {
          for (let i = 0; i < Math.min(node.length, 3); i++) walk(node[i], `${path}[${i}]`, depth+1);
        } else if (typeof node === 'object') {
          for (const k of Object.keys(node)) {
            if (/^(logo|logos|image|images|headshot|flag|alternateLogo|color|alternateColor|primaryColor|secondaryColor|href|link|links)$/i.test(k)) {
              found[`${path}.${k}`] = node[k];
            } else if (typeof node[k] === 'object') {
              walk(node[k], `${path}.${k}`, depth+1);
            }
          }
        }
      }
      walk(j, '$', 0);
      out.push({
        name: t.name, status: r.status, top_keys: keys,
        media_or_link_fields: found,
      });
    } catch (e) { out.push({ name: t.name, error: String((e as Error).message) }); }
    await new Promise(rs => setTimeout(rs, 200));
  }
  return new Response(JSON.stringify(out, null, 2), { headers: { 'content-type': 'application/json' } });
});
