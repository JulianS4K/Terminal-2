// Probe TEvo to discover the NFL category_id by searching for known NFL teams.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const HOST = "api.ticketevolution.com";
async function hmac(secret: string, msg: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(msg));
  let bin = "";
  for (const b of new Uint8Array(sig)) bin += String.fromCharCode(b);
  return btoa(bin);
}
function qs(p: Record<string, any>): string {
  const pairs: [string, string][] = [];
  for (const [k, v] of Object.entries(p)) {
    if (v === null || v === undefined || v === "") continue;
    pairs.push([k, typeof v === "boolean" ? (v ? "true" : "false") : String(v)]);
  }
  pairs.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
}
async function tevoGet(token: string, secret: string, path: string, params: any) {
  const q = qs(params);
  const sig = await hmac(secret, `GET ${HOST}${path}?${q}`);
  const r = await fetch(`https://${HOST}${path}?${q}`, { headers: { "X-Token": token, "X-Signature": sig, "Accept": "application/vnd.ticketevolution.api+json; version=9" } });
  return { status: r.status, body: await r.text() };
}
Deno.serve(async () => {
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: creds } = await db.from("settings").select("key,value").in("key", ["tevo_token", "tevo_secret"]);
  const m: any = {}; for (const r of creds ?? []) m[r.key] = r.value;
  const out: any = {};
  // Probe: search for Dallas Cowboys, look at the category
  const r1 = await tevoGet(m.tevo_token, m.tevo_secret, "/v9/performers", { q: "Dallas Cowboys" });
  let p1: any = {}; try { p1 = JSON.parse(r1.body); } catch (_) {}
  const cowboys = (p1.performers ?? [])[0] ?? null;
  out.cowboys = cowboys ? { id: cowboys.id, name: cowboys.name, category: cowboys.category } : null;

  // Probe: try category /v9/categories
  const r2 = await tevoGet(m.tevo_token, m.tevo_secret, "/v9/categories", { name: "NFL" });
  out.categories_search_nfl_status = r2.status;
  out.categories_search_nfl_body = r2.body.slice(0, 800);

  // Probe: search performers with name=NFL
  const r3 = await tevoGet(m.tevo_token, m.tevo_secret, "/v9/performers", { q: "NFL" });
  let p3: any = {}; try { p3 = JSON.parse(r3.body); } catch (_) {}
  out.nfl_performers = (p3.performers ?? []).slice(0, 5).map((p: any) => ({ id: p.id, name: p.name, category: p.category }));

  return new Response(JSON.stringify(out, null, 2), { status: 200, headers: { "content-type": "application/json" } });
});
