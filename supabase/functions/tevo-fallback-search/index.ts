// TEvo fallback search — when our S4K-filtered local search returns 0, hit
// TEvo's broader marketplace so we don't lose the customer interest. Bridges
// 'we don't own these but can source' workflow.
//
// Captured from prod 2026-05-08 by code via audit-and-commit (cowork/copilot
// deployed v1, no git capture until now).
//
// Modes:
//   POST { mode: 'suggestions', q: 'wallen', entities?: 'events,performers,venues', limit?: 10 }
//   POST { mode: 'events_by_q', q: 'wallen' }
//   POST { mode: 'events_by_performer', performer_id: 16303 }
//   POST { mode: 'events_by_venue', venue_id: 896 }
//   POST { mode: 'events_near', lat: 40.75, lon: -73.99, within: 25 }
//
// All responses normalized to { source: 'tevo_fallback', mode, count, events: [] }
// where each event has: { id, name, occurs_at, occurs_at_local, venue_name,
// venue_location, performer, category, popularity_score, available_count }.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const HOST = 'api.ticketevolution.com'; const BASE = `https://${HOST}`;

async function hmac(secret: string, msg: string) {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey('raw', enc.encode(secret), { name:'HMAC', hash:'SHA-256' }, false, ['sign']);
  const s = await crypto.subtle.sign('HMAC', k, enc.encode(msg));
  let bin=''; for (const b of new Uint8Array(s)) bin += String.fromCharCode(b); return btoa(bin);
}
function canonical(p: Record<string, string|number|boolean|null|undefined>): string {
  const ps: [string,string][] = [];
  for (const [k,v] of Object.entries(p)) {
    if (v === null || v === undefined || v === '') continue;
    ps.push([k, typeof v === 'boolean' ? (v?'true':'false') : String(v)]);
  }
  ps.sort(([a],[b]) => a < b ? -1 : a > b ? 1 : 0);
  return ps.map(([k,v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&');
}
async function tevoGet(token: string, secret: string, path: string, params: Record<string, any> = {}) {
  const q = canonical(params);
  const sig = await hmac(secret, `GET ${HOST}${path}?${q}`);
  const r = await fetch(`${BASE}${path}?${q}`, { headers: { 'X-Token': token, 'X-Signature': sig, 'Accept': 'application/vnd.ticketevolution.api+json; version=9' }});
  if (!r.ok) throw new Error(`${r.status} on ${path}`);
  return r.json();
}
function normalizeEvent(e: any) {
  const primary = (e.performances ?? []).find((p: any) => p.primary)?.performer;
  return {
    id: e.id,
    name: e.name,
    occurs_at: e.occurs_at ?? null,
    occurs_at_local: e.occurs_at_local ?? null,
    venue_id: e.venue?.id ?? null,
    venue_name: e.venue?.name ?? null,
    venue_location: e.venue?.location ?? null,
    performer: primary?.name ?? null,
    performer_id: primary?.id ?? null,
    category: e.category?.name ?? null,
    parent_category: e.category?.parent?.name ?? null,
    popularity_score: typeof e.popularity_score === 'number' ? e.popularity_score : null,
    available_count: e.available_count ?? null,
    products_count: e.products_count ?? null,
    has_seating_chart: !!(e.configuration?.seating_chart?.medium
        && e.configuration.seating_chart.medium !== 'null'
        && String(e.configuration.seating_chart.medium).startsWith('http')),
    seating_chart_url: e.configuration?.seating_chart?.medium
        && e.configuration.seating_chart.medium !== 'null'
        ? e.configuration.seating_chart.medium : null,
    source: 'tevo_fallback',
  };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('POST only', { status: 405 });
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: settings } = await db.from('settings').select('key,value').in('key',['tevo_token','tevo_secret']);
  const m: Record<string,string> = {}; for (const r of settings ?? []) m[r.key] = r.value;
  if (!m.tevo_token || !m.tevo_secret) return new Response(JSON.stringify({error:'no creds'}), { status: 500 });

  const body = await req.json();
  const mode = body?.mode;
  const limit = Math.min(body?.limit ?? 10, 25);

  try {
    if (mode === 'suggestions') {
      const r = await tevoGet(m.tevo_token, m.tevo_secret, '/v9/searches/suggestions', {
        q: body.q,
        entities: body.entities ?? 'events,performers,venues',
        fuzzy: body.fuzzy ?? true,
        limit,
      });
      const sug = r.suggestions ?? {};
      return new Response(JSON.stringify({
        source: 'tevo_fallback', mode, query: body.q,
        events: (sug.events ?? []).map(normalizeEvent),
        performers: (sug.performers ?? []).map((p: any) => ({ id: p.id, name: p.name, slug: p.slug })),
        venues: (sug.venues ?? []).map((v: any) => ({ id: v.id, name: v.name, location: v.location })),
      }, null, 2), { headers: { 'content-type':'application/json' } });
    }

    let path = '/v9/events';
    let params: Record<string, any> = { only_with_available_tickets: true, per_page: limit };
    if (mode === 'events_by_q')          params.q = body.q;
    else if (mode === 'events_by_performer') params.performer_id = body.performer_id;
    else if (mode === 'events_by_venue')     params.venue_id = body.venue_id;
    else if (mode === 'events_near') {
      params.lat = body.lat; params.lon = body.lon;
      params.within = body.within ?? 25;
    } else {
      return new Response(JSON.stringify({error:`unknown mode '${mode}'`}), { status: 400 });
    }
    const r = await tevoGet(m.tevo_token, m.tevo_secret, path, params);
    const events = (r.events ?? []).map(normalizeEvent);
    return new Response(JSON.stringify({
      source: 'tevo_fallback', mode, count: events.length, events,
      total_entries: r.total_entries ?? null,
    }, null, 2), { headers: { 'content-type':'application/json' } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String((e as Error).message), mode }), { status: 500 });
  }
});
