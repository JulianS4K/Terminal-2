// v2: drop order_by (422s), also capture event-level category to refine
// events.event_type while we're crawling.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const HOST = "api.ticketevolution.com"; const BASE = `https://${HOST}`;

async function hmac(secret: string, msg: string): Promise<string> {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const s = await crypto.subtle.sign("HMAC", k, enc.encode(msg));
  let bin = ""; for (const b of new Uint8Array(s)) bin += String.fromCharCode(b); return btoa(bin);
}
function canonical(params: Record<string, string|number|boolean>): string {
  const ps: [string,string][] = [];
  for (const [k,v] of Object.entries(params)) ps.push([k, typeof v === 'boolean' ? (v?'true':'false') : String(v)]);
  ps.sort(([a],[b]) => a < b ? -1 : a > b ? 1 : 0);
  return ps.map(([k,v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&');
}
async function tevoGet(token: string, secret: string, path: string, params: Record<string,string|number|boolean> = {}, attempt = 0): Promise<any> {
  const q = canonical(params);
  const sig = await hmac(secret, `GET ${HOST}${path}?${q}`);
  const r = await fetch(`${BASE}${path}?${q}`, { headers: { 'X-Token': token, 'X-Signature': sig, 'Accept': 'application/vnd.ticketevolution.api+json; version=9' } });
  if ((r.status === 429 || r.status >= 500) && attempt < 2) { await new Promise(res => setTimeout(res, 1000 * (attempt+1))); return tevoGet(token, secret, path, params, attempt+1); }
  if (!r.ok) throw new Error(`${r.status} on ${path}`);
  return r.json();
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('POST only', { status: 405 });
  const t0 = Date.now(); const WALL = 50_000;
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: settings } = await db.from('settings').select('key,value').in('key',['tevo_token','tevo_secret']);
  const m: Record<string,string> = {}; for (const r of settings ?? []) m[r.key] = r.value;
  if (!m.tevo_token || !m.tevo_secret) return new Response(JSON.stringify({error:'no creds'}), { status: 500 });

  const body = await req.json().catch(() => ({}));
  const venueLimit = Math.min(body?.venue_limit ?? 5, 30);
  const eventsPerVenue = Math.min(body?.events_per_venue ?? 25, 100);

  const { data: venues } = await db.rpc('next_venues_to_crawl', { p_limit: venueLimit });
  const venuesToCrawl = (venues ?? []) as { venue_id: number; venue_name: string }[];

  let stats = { venues_processed: 0, events_seen: 0, events_categorized: 0, new_performers: 0, performer_metadata_upserts: 0, errors: 0, errs: [] as any[] };

  for (const v of venuesToCrawl) {
    if (Date.now() - t0 > WALL) break;
    let eventsList: any[] = [];
    try {
      const r = await tevoGet(m.tevo_token, m.tevo_secret, '/v9/events', {
        venue_id: v.venue_id, only_with_available_tickets: true, per_page: eventsPerVenue,
      });
      eventsList = r.events ?? [];
    } catch (e) { stats.errors++; stats.errs.push({ venue_id: v.venue_id, stage: 'list_events', error: String((e as Error).message) }); continue; }

    stats.events_seen += eventsList.length;

    for (const ev of eventsList) {
      const cat = ev.category ?? {};
      const parent = cat.parent ?? {};
      const grand = parent.parent ?? {};
      const cat_name = cat.name ?? null;
      const parent_name = parent.name ?? null;
      const grand_name = grand.name ?? null;
      if (!cat_name) continue;
      const { data: mappings } = await db.rpc('classify_performer_categories', { p_cat: cat_name, p_parent: parent_name, p_grand: grand_name });
      const what = mappings?.[0]?.event_type ?? null;
      if (!what) continue;
      try { await db.from('events').update({ event_type: what }).eq('id', ev.id); stats.events_categorized++; } catch (_) {}
    }

    const perfSet = new Map<number, string>();
    for (const ev of eventsList) {
      for (const p of ev.performances ?? []) {
        if (p.performer?.id) perfSet.set(Number(p.performer.id), p.performer.name ?? '');
      }
    }

    for (const [perfId, perfName] of perfSet) {
      if (Date.now() - t0 > WALL) break;
      const { data: existing } = await db.from('performer_metadata').select('performer_id').eq('performer_id', perfId).maybeSingle();
      if (existing) continue;
      try {
        const p = await tevoGet(m.tevo_token, m.tevo_secret, `/v9/performers/${perfId}`);
        const cat = p.category ?? {};
        const parent = cat.parent ?? {};
        const grand = parent.parent ?? {};
        const cat_name = cat.name ?? null;
        const parent_name = parent.name ?? null;
        const grand_name = grand.name ?? null;
        const { data: mappings } = await db.rpc('classify_performer_categories', { p_cat: cat_name, p_parent: parent_name, p_grand: grand_name });
        const top = mappings?.[0]?.top_category ?? null;
        const genre = mappings?.[0]?.genre ?? null;
        const what = mappings?.[0]?.event_type ?? null;
        const popularity = parseFloat(p.popularity_score ?? '0') || null;

        await db.from('performer_metadata').upsert({
          performer_id: perfId, name: p.name ?? perfName, slug: p.slug ?? null,
          popularity_score: popularity, keywords: p.keywords ?? null,
          category_id: cat.id ? String(cat.id) : null,
          category_name: cat_name, parent_category_name: parent_name, top_category_name: top,
          what_event_type: what, genre,
          upcoming_first: p.upcoming_events?.first ?? null,
          upcoming_last: p.upcoming_events?.last ?? null,
          raw: p, fetched_at: new Date().toISOString(),
        }, { onConflict: 'performer_id' });
        stats.performer_metadata_upserts++; stats.new_performers++;

        try {
          await db.rpc('promote_performer_to_aliases', {
            p_performer_id: perfId, p_performer_name: p.name ?? perfName,
            p_league: top === 'Sports' ? (parent_name ?? cat_name) : null, p_city: null,
          });
        } catch (_) {}
      } catch (e) { stats.errors++; stats.errs.push({ performer_id: perfId, stage: 'fetch_performer', error: String((e as Error).message) }); }
      await new Promise(r => setTimeout(r, 200));
    }

    await db.from('venue_crawl_state').update({
      last_crawled_at: new Date().toISOString(),
      events_found: eventsList.length,
      performers_found: perfSet.size, last_error: null,
    }).eq('venue_id', v.venue_id);
    stats.venues_processed++;
  }

  return new Response(JSON.stringify({ ...stats, elapsed_ms: Date.now() - t0, error_sample: stats.errs.slice(0, 5) }, null, 2),
    { headers: { 'content-type': 'application/json' } });
});
