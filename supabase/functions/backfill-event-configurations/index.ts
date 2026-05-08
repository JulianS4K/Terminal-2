// v2: slower pacing (250ms), explicit retry on 429/5xx, processes one event at
// a time and stops gracefully after 50s wall-clock so we don't lose progress to
// the 60s edge-fn timeout.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const HOST = "api.ticketevolution.com"; const BASE = `https://${HOST}`;
async function hmac(secret: string, msg: string): Promise<string> {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const s = await crypto.subtle.sign("HMAC", k, enc.encode(msg));
  let bin = ""; for (const b of new Uint8Array(s)) bin += String.fromCharCode(b); return btoa(bin);
}
async function tevoEvent(token: string, secret: string, id: number, attempt = 0): Promise<any> {
  const path = `/v9/events/${id}`; const sig = await hmac(secret, `GET ${HOST}${path}?`);
  const r = await fetch(`${BASE}${path}?`, { headers: { "X-Token": token, "X-Signature": sig, "Accept": "application/vnd.ticketevolution.api+json; version=9" } });
  if ((r.status === 429 || r.status >= 500) && attempt < 2) {
    await new Promise((res) => setTimeout(res, 1000 * (attempt + 1)));
    return tevoEvent(token, secret, id, attempt + 1);
  }
  if (!r.ok) throw new Error(`${r.status} on ${path}`);
  return r.json();
}
Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  const t0 = Date.now();
  const WALL_BUDGET_MS = 50_000;
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: settings } = await db.from("settings").select("key,value").in("key", ["tevo_token","tevo_secret"]);
  const m: Record<string,string> = {}; for (const r of settings ?? []) m[r.key] = r.value;
  if (!m.tevo_token || !m.tevo_secret) return new Response(JSON.stringify({error:"no creds"}), { status: 500 });
  const body = await req.json().catch(() => ({}));
  let ids: number[] = body?.event_ids ?? [];
  const limit = Math.min(body?.limit ?? 100, 500);
  if (body?.all_chat_tracked) {
    const { data } = await db.from("events")
      .select("id")
      .or("configuration_id.is.null,seating_chart_medium.is.null")
      .gte("occurs_at_local", new Date().toISOString().slice(0,10))
      .order("occurs_at_local", { ascending: true })
      .limit(limit);
    ids = (data ?? []).map((r: any) => Number(r.id));
  }
  let updated = 0; let withMap = 0; let errors = 0; let skipped = 0;
  const errs: any[] = [];
  for (const id of ids) {
    if (Date.now() - t0 > WALL_BUDGET_MS) { skipped = ids.length - (updated + errors); break; }
    try {
      const ev = await tevoEvent(m.tevo_token, m.tevo_secret, id);
      const cfg = ev.configuration ?? {};
      const sc = cfg.seating_chart ?? {};
      const med = typeof sc.medium === "string" ? sc.medium : null;
      const lg = typeof sc.large === "string" ? sc.large : null;
      const hasMap = !!(med && med !== "null" && med.startsWith("http"));
      if (hasMap) withMap++;
      const patch: any = {
        configuration_id: cfg.id ?? null,
        configuration_name: cfg.name ?? null,
        seating_chart_medium: med,
        seating_chart_large: lg,
        fanvenues_key: cfg.fanvenues_key && String(cfg.fanvenues_key).trim() ? String(cfg.fanvenues_key) : null,
        popularity_score: typeof ev.popularity_score === "number" ? ev.popularity_score : null,
        long_term_popularity_score: typeof ev.long_term_popularity_score === "number" ? ev.long_term_popularity_score : null,
      };
      const { error: upErr } = await db.from("events").update(patch).eq("id", id);
      if (upErr) { errors++; errs.push({ id, error: upErr.message }); continue; }
      updated++;
    } catch (e) { errors++; errs.push({ id, error: String((e as Error).message) }); }
    await new Promise((r) => setTimeout(r, 250));
  }
  return new Response(JSON.stringify({ requested: ids.length, updated, with_map: withMap, errors, skipped, error_sample: errs.slice(0, 5), elapsed_ms: Date.now() - t0 }, null, 2), { headers: { "content-type": "application/json" } });
});
