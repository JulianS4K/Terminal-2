// One-shot probe: takes event_ids, hits /v9/events/{id}, reports configuration
// presence + seating_chart URL HTTP status.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const HOST = "api.ticketevolution.com"; const BASE = `https://${HOST}`;
async function hmac(secret: string, msg: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(msg));
  let bin = ""; for (const b of new Uint8Array(sig)) bin += String.fromCharCode(b); return btoa(bin);
}
async function tevoGet(token: string, secret: string, path: string): Promise<any> {
  const sig = await hmac(secret, `GET ${HOST}${path}?`);
  const r = await fetch(`${BASE}${path}?`, { headers: { "X-Token": token, "X-Signature": sig, "Accept": "application/vnd.ticketevolution.api+json; version=9" } });
  if (!r.ok) throw new Error(`${r.status} on ${path}`);
  return r.json();
}
async function probeUrl(url: string): Promise<{ ok: boolean; status: number; ctype: string|null; len: number }> {
  try {
    const r = await fetch(url, { method: "GET", redirect: "follow" });
    const buf = await r.arrayBuffer();
    return { ok: r.ok, status: r.status, ctype: r.headers.get("content-type"), len: buf.byteLength };
  } catch (e) { return { ok: false, status: -1, ctype: null, len: 0 }; }
}
Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: settings } = await db.from("settings").select("key,value").in("key", ["tevo_token","tevo_secret"]);
  const m: Record<string,string> = {}; for (const r of settings ?? []) m[r.key] = r.value;
  const token = m.tevo_token; const secret = m.tevo_secret;
  if (!token || !secret) return new Response(JSON.stringify({error:"no creds"}), { status: 500 });
  const body = await req.json();
  const ids: number[] = body?.event_ids ?? [];
  const out: any[] = [];
  for (const id of ids) {
    try {
      const ev = await tevoGet(token, secret, `/v9/events/${id}`);
      const cfg = ev.configuration ?? {};
      const sc = cfg.seating_chart ?? {};
      const medium = sc.medium ?? null;
      const large = sc.large ?? null;
      const probeMed = medium ? await probeUrl(medium) : null;
      const probeLg = large ? await probeUrl(large) : null;
      out.push({
        event_id: id, name: ev.name, venue: ev.venue?.name,
        category: ev.category?.parent?.parent?.name ? `${ev.category.parent.parent.name}>${ev.category.parent.name}>${ev.category.name}` : ev.category?.name,
        configuration_id: cfg.id ?? null,
        configuration_name: cfg.name ?? null,
        fanvenues_key: cfg.fanvenues_key ?? null,
        ticket_utils_id: cfg.ticket_utils_id ?? null,
        medium_url: medium, medium_probe: probeMed,
        large_url: large, large_probe: probeLg,
        popularity_score: ev.popularity_score ?? null,
        long_term_popularity_score: ev.long_term_popularity_score ?? null,
      });
    } catch (e) { out.push({ event_id: id, error: String((e as Error).message) }); }
  }
  return new Response(JSON.stringify({ count: out.length, results: out }, null, 2), { headers: { "content-type": "application/json" } });
});
