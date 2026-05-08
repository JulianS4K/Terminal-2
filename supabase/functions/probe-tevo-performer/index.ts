// Probe TEvo /v9/performers/{id} for non-sports performers to discover what
// metadata exists beyond name (genre, category chain, popularity, etc).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const HOST = "api.ticketevolution.com"; const BASE = `https://${HOST}`;
async function hmac(secret: string, msg: string): Promise<string> {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const s = await crypto.subtle.sign("HMAC", k, enc.encode(msg));
  let bin = ""; for (const b of new Uint8Array(s)) bin += String.fromCharCode(b); return btoa(bin);
}
async function tevoGet(token: string, secret: string, path: string) {
  const sig = await hmac(secret, `GET ${HOST}${path}?`);
  const r = await fetch(`${BASE}${path}?`, { headers: { "X-Token": token, "X-Signature": sig, "Accept": "application/vnd.ticketevolution.api+json; version=9" } });
  if (!r.ok) throw new Error(`${r.status} on ${path}`);
  return r.json();
}
Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: settings } = await db.from("settings").select("key,value").in("key", ["tevo_token","tevo_secret"]);
  const m: Record<string,string> = {}; for (const r of settings ?? []) m[r.key] = r.value;
  if (!m.tevo_token || !m.tevo_secret) return new Response(JSON.stringify({error:"no creds"}), { status: 500 });
  const body = await req.json();
  const ids: number[] = body?.performer_ids ?? [];
  const out: any[] = [];
  for (const id of ids) {
    try {
      const p = await tevoGet(m.tevo_token, m.tevo_secret, `/v9/performers/${id}`);
      out.push({ id, raw: p });
    } catch (e) { out.push({ id, error: String((e as Error).message) }); }
    await new Promise(r => setTimeout(r, 200));
  }
  return new Response(JSON.stringify({ count: out.length, results: out }, null, 2), { headers: { "content-type": "application/json" } });
});
