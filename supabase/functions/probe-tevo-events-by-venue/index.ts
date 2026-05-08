import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const HOST = 'api.ticketevolution.com'; const BASE = `https://${HOST}`;
async function hmac(secret: string, msg: string) {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey('raw', enc.encode(secret), { name:'HMAC', hash:'SHA-256' }, false, ['sign']);
  const s = await crypto.subtle.sign('HMAC', k, enc.encode(msg));
  let bin=''; for (const b of new Uint8Array(s)) bin += String.fromCharCode(b); return btoa(bin);
}
Deno.serve(async (req) => {
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: settings } = await db.from('settings').select('key,value').in('key',['tevo_token','tevo_secret']);
  const m: Record<string,string> = {}; for (const r of settings ?? []) m[r.key] = r.value;
  const body = await req.json();
  const venue_id = body?.venue_id ?? 896;
  const variants = [
    `/v9/events?venue_id=${venue_id}`,
    `/v9/events?only_with_available_tickets=true&order_by=events.occurs_at_local%20ASC&per_page=10&venue_id=${venue_id}`,
    `/v9/events?only_with_available_tickets=true&per_page=10&venue_id=${venue_id}`,
    `/v9/events?per_page=10&venue_id=${venue_id}`,
  ];
  const out: any[] = [];
  for (const v of variants) {
    const u = new URL(BASE + v);
    const path = u.pathname;
    const qs = u.searchParams.toString();
    const sig = await hmac(m.tevo_secret, `GET ${HOST}${path}?${qs}`);
    const r = await fetch(`${BASE}${path}?${qs}`, { headers: { 'X-Token': m.tevo_token, 'X-Signature': sig, 'Accept': 'application/vnd.ticketevolution.api+json; version=9' }});
    const txt = await r.text();
    out.push({ variant: v, status: r.status, body_head: txt.slice(0, 400) });
  }
  return new Response(JSON.stringify(out, null, 2), { headers: { 'content-type':'application/json' } });
});
