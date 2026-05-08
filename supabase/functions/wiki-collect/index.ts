// Supabase Edge Function: wiki-collect
//
// Fetches Wikipedia article summaries for every performer in
// performer_home_venues and upserts to wiki_summary.
// Uses Wikipedia REST API (no auth, no rate limit issues at this scale).
//
// Optional rivalry-summary backfill: for each row in wiki_rivalries with a
// wiki_title, fetch and store the article extract.
//
// POST { performer_id?: bigint, refresh_rivalries?: boolean }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const WIKI_REST = "https://en.wikipedia.org/api/rest_v1";
const USER_AGENT = "Terminal-2/1.0 (s4kentertainment.com; julian@s4kent.com)";

async function fetchWikiSummary(title: string): Promise<any | null> {
  const url = `${WIKI_REST}/page/summary/${encodeURIComponent(title.replace(/ /g, "_"))}`;
  const r = await fetch(url, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" } });
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`wiki ${r.status} on ${title}`);
  return await r.json();
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async (req) => {
  const expected = Deno.env.get("CRON_SECRET");
  if (expected && req.headers.get("x-cron-secret") !== expected) {
    return new Response("unauthorized", { status: 401 });
  }
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  let body: any = {}; try { body = await req.json(); } catch (_) {}
  const performerFilter = body.performer_id as number | undefined;
  const refreshRivalries = body.refresh_rivalries === true;

  const stats = { performers_fetched: 0, summaries_upserted: 0, rivalries_updated: 0, not_found: 0, errors: 0, log: [] as string[] };

  // 1) Performer summaries
  let q = db.from("performer_home_venues").select("performer_id, performer_name, league");
  if (performerFilter) q = q.eq("performer_id", performerFilter);
  const { data: performers } = await q;

  for (const p of (performers ?? []) as any[]) {
    stats.performers_fetched++;
    let summary: any = null;
    try { summary = await fetchWikiSummary(p.performer_name); }
    catch (e) { stats.errors++; stats.log.push(`${p.performer_name}: ${(e as Error).message}`); continue; }
    if (!summary) { stats.not_found++; continue; }
    const meta = summary;
    // Best-effort founded year + championships from extract.
    const foundedMatch = String(summary.extract ?? "").match(/founded in\s+(\d{4})/i)
                       ?? String(summary.extract ?? "").match(/established in\s+(\d{4})/i);
    const champMatch = String(summary.extract ?? "").match(/(\d+)\s+(?:NBA|NFL|MLB|NHL|World Series|Stanley Cup|Super Bowl)\s+championships?/i)
                     ?? String(summary.extract ?? "").match(/winning\s+(\d+)\s+championships?/i);
    const row = {
      performer_id: p.performer_id,
      wiki_title: summary.title ?? p.performer_name,
      wiki_url: summary.content_urls?.desktop?.page ?? null,
      description: summary.description ?? null,
      extract: summary.extract ?? null,
      thumbnail_url: summary.thumbnail?.source ?? null,
      founded_year: foundedMatch ? parseInt(foundedMatch[1]) : null,
      championships: champMatch ? parseInt(champMatch[1]) : null,
      meta: { wikibase_item: meta.wikibase_item, type: meta.type, originalimage: meta.originalimage },
      fetched_at: new Date().toISOString(),
    };
    const { error } = await db.from("wiki_summary").upsert(row, { onConflict: "performer_id" });
    if (error) { stats.errors++; stats.log.push(`upsert ${p.performer_name}: ${error.message}`); }
    else stats.summaries_upserted++;
    await sleep(80); // be polite to wikipedia
  }

  // 2) Optional: enrich rivalries with their wikipedia article extract.
  if (refreshRivalries) {
    const { data: rivs } = await db.from("wiki_rivalries").select("id, rivalry_name, wiki_title");
    for (const r of (rivs ?? []) as any[]) {
      const title = r.wiki_title ?? r.rivalry_name;
      let summary: any = null;
      try { summary = await fetchWikiSummary(title); }
      catch (e) { stats.errors++; stats.log.push(`rivalry ${title}: ${(e as Error).message}`); continue; }
      if (!summary) { stats.not_found++; continue; }
      const update = {
        description: summary.extract ? String(summary.extract).slice(0, 1500) : r.description,
        wiki_title: summary.title ?? title,
        fetched_at: new Date().toISOString(),
      };
      const { error } = await db.from("wiki_rivalries").update(update).eq("id", r.id);
      if (error) stats.errors++; else stats.rivalries_updated++;
      await sleep(80);
    }
  }

  return new Response(JSON.stringify(stats, null, 2), { headers: { "content-type": "application/json" } });
});
