// trends-collect — Google-Trends search-interest → why_signals (the "meaning" layer).
//
// Drains trend_poll_state (rate-budgeted round-robin: active, priority DESC, oldest
// last_polled_at first), fetches each term's ~3-month interest-over-time, computes a
// MOMENTUM signal (recent avg vs prior baseline, normalized -1..1; rising searches =
// demand boost), writes why_signals (team/show → scope='performer' → flows to events
// via v_event_why_context; athlete → scope='athlete', informational + injury
// star-weighting), and stamps last_polled_at.
//
// SOURCE = SerpAPI's google_trends engine (needs SERPAPI_KEY in vault/env).
// The free Google-Trends endpoint was verified UNUSABLE from our runtime: a pg_net
// GET from the Supabase datacenter IP returns HTTP 429 (Google blocks datacenter IPs).
// So this fn is INERT until SERPAPI_KEY is set — it returns {skipped} rather than
// burning the queue on requests that can't succeed. Auth: X-Cron-Secret.
//
// A1 · pairs with migration 20260704120000_trend_poll_state.sql.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
const SERPAPI_KEY = Deno.env.get("SERPAPI_KEY") ?? "";
const UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124 Safari/537.36";

// recent (last ~7 pts) vs prior baseline → -1..1
function momentum(series: number[]): number | null {
  const v = series.filter((n) => Number.isFinite(n));
  if (v.length < 8) return null;
  const recent = v.slice(-7), prior = v.slice(0, -7);
  const avg = (a: number[]) => a.reduce((s, n) => s + n, 0) / a.length;
  const r = avg(recent), p = avg(prior);
  if (p <= 0) return r > 0 ? 1 : 0;
  return Math.max(-1, Math.min(1, (r - p) / p));
}

async function viaSerpApi(term: string): Promise<number[] | null> {
  const u = new URL("https://serpapi.com/search.json");
  u.searchParams.set("engine", "google_trends");
  u.searchParams.set("q", term);
  u.searchParams.set("data_type", "TIMESERIES");
  u.searchParams.set("date", "today 3-m");
  u.searchParams.set("geo", "US");
  u.searchParams.set("api_key", SERPAPI_KEY);
  const r = await fetch(u, { headers: { "User-Agent": UA } });
  if (!r.ok) throw new Error(`serpapi ${r.status}`);
  const j = await r.json();
  const tl = j?.interest_over_time?.timeline_data;
  if (!Array.isArray(tl)) return null;
  return tl.map((d: any) => Number(d?.values?.[0]?.extracted_value ?? d?.values?.[0]?.value ?? 0));
}

Deno.serve(async (req) => {
  if (CRON_SECRET && req.headers.get("X-Cron-Secret") !== CRON_SECRET) {
    return new Response("unauthorized", { status: 401 });
  }
  const json = (b: unknown, status = 200) =>
    new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json" } });

  if (!SERPAPI_KEY) {
    return json({ skipped: "no SERPAPI_KEY set — the free Google-Trends endpoint is datacenter-IP blocked (429). Add SERPAPI_KEY to the vault to activate." });
  }

  const batch = Math.min(Number(new URL(req.url).searchParams.get("batch") ?? "20"), 60);
  const sb = createClient(SB_URL, SB_KEY);
  const { data: targets, error } = await sb
    .from("trend_poll_state")
    .select("id, entity_type, term, tevo_performer_id")
    .eq("active", true)
    .order("priority", { ascending: false })
    .order("last_polled_at", { ascending: true, nullsFirst: true })
    .limit(batch);
  if (error) return json({ error: error.message }, 500);

  let ok = 0, fail = 0, wrote = 0;
  for (const t of targets ?? []) {
    try {
      const series = await viaSerpApi(t.term);
      const m = series ? momentum(series) : null;
      if (m !== null) {
        const scope = t.entity_type === "athlete" ? "athlete" : "performer";
        const scope_id = t.entity_type === "athlete" ? null : t.tevo_performer_id;
        await sb.from("why_signals").delete()
          .eq("signal_kind", "search_interest").eq("source", "serpapi").eq("scope_label", t.term);
        await sb.from("why_signals").insert({
          scope, scope_id, scope_label: t.term, signal_kind: "search_interest",
          signal_value: m, signal_label: `search ${m >= 0 ? "+" : ""}${(m * 100).toFixed(0)}% (${t.term})`,
          weight: 1.0, source: "serpapi", expires_at: new Date(Date.now() + 3 * 864e5).toISOString(),
        });
        wrote++; ok++;
        await sb.from("trend_poll_state").update({ last_polled_at: new Date().toISOString(), last_value: m, last_status: "ok" }).eq("id", t.id);
      } else {
        fail++;
        await sb.from("trend_poll_state").update({ last_polled_at: new Date().toISOString(), last_status: "no-series" }).eq("id", t.id);
      }
    } catch (e) {
      fail++;
      await sb.from("trend_poll_state").update({ last_polled_at: new Date().toISOString(), last_status: String(e).slice(0, 80) }).eq("id", t.id);
    }
  }
  return json({ source: "serpapi", targets: targets?.length ?? 0, ok, fail, wrote });
});
