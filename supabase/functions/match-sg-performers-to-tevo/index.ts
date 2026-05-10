// match-sg-performers-to-tevo
//
// Reads from v_sg_unmatched_candidate_performers (Phase 8 view), runs each
// candidate name through Tevo /v9/performers/search, picks the best hit, and
// calls record_sg_performer_match() to persist the link. The Phase 4 trigger
// pipeline cascades the row into performer_external_ids and
// canonical_external_ids automatically.
//
// Match acceptance rules:
//   confidence 1.00 — exact lower(name) equality
//   confidence 0.90 — slugified equality (strip punctuation/whitespace)
//   confidence 0.75 — top hit's name token-set ⊇ candidate token-set (e.g.
//                     "Boston Bruins" -> "Boston Bruins (Preseason)")
//   anything below — recorded with confidence as-is and meta.review='manual'
//                    so it surfaces for review without blocking ingestion.
//
// GET /functions/v1/match-sg-performers-to-tevo?limit=80&dry_run=false
//   -> { ok, processed, accepted, skipped, by_confidence, samples }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const HOST = "api.ticketevolution.com";
const BASE = `https://${HOST}`;

async function hmac(secret: string, msg: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(msg));
  let bin = ""; for (const b of new Uint8Array(sig)) bin += String.fromCharCode(b);
  return btoa(bin);
}

function qs(p: Record<string, unknown>): string {
  const pairs: [string, string][] = [];
  for (const [k, v] of Object.entries(p)) {
    if (v === null || v === undefined || v === "") continue;
    pairs.push([k, typeof v === "boolean" ? (v ? "true" : "false") : String(v)]);
  }
  pairs.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
}

async function tevoSearch(token: string, secret: string, q: string, categoryId?: string) {
  const params: Record<string, unknown> = { q, per_page: 10, page: 1 };
  if (categoryId) params.category_id = categoryId;
  const path = "/v9/performers/search";
  const queryStr = qs(params);
  const sig = await hmac(secret, `GET ${HOST}${path}?${queryStr}`);
  const r = await fetch(`${BASE}${path}?${queryStr}`, {
    headers: {
      "X-Token": token,
      "X-Signature": sig,
      "Accept": "application/vnd.ticketevolution.api+json; version=9",
    },
  });
  if (r.status !== 200) {
    return { ok: false, status: r.status, body: (await r.text()).slice(0, 300) };
  }
  return { ok: true, body: await r.json() };
}

const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
const tokenSet = (s: string) =>
  new Set(s.toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length > 1));
const supersetOf = (big: Set<string>, small: Set<string>) => {
  for (const t of small) if (!big.has(t)) return false;
  return true;
};

// SG category → TEvo top-level category_id (helps disambiguation).
// Ids per Tevo catalog: sports=1, concerts=54, theater=68 (approximate).
function categoryFor(sgCategory: string | null): string | undefined {
  if (!sgCategory) return undefined;
  if (["mlb", "nhl", "nba", "mls", "wnba", "ncaa_football", "ncaa_basketball",
       "nfl", "nascar", "nfl_preseason"].includes(sgCategory)) return "1";
  if (["concert"].includes(sgCategory)) return "54";
  if (["comedy", "theater"].includes(sgCategory)) return "68";
  return undefined;
}

interface Candidate {
  performer_name: string;
  event_count: number;
  categories: (string | null)[];
}

interface Hit {
  id: number;
  name: string;
  popularity_score?: number;
  category?: { id: number; name: string; slug: string } | null;
  venue?: { id: number; name: string } | null;
}

function pickBest(candidate: string, hits: Hit[]): {
  hit: Hit | null;
  confidence: number;
  method: string;
} {
  if (!hits || hits.length === 0) return { hit: null, confidence: 0, method: "no_hits" };
  const candSlug = slug(candidate);
  const candTokens = tokenSet(candidate);

  // exact (case-insensitive) name match
  const exact = hits.find((h) => h.name.toLowerCase() === candidate.toLowerCase());
  if (exact) return { hit: exact, confidence: 1.00, method: "exact_lc" };

  // slug equality
  const slugMatch = hits.find((h) => slug(h.name) === candSlug);
  if (slugMatch) return { hit: slugMatch, confidence: 0.90, method: "slug_eq" };

  // token-set superset (TEvo result name contains all of our candidate tokens)
  const tokenSuper = hits.find((h) => supersetOf(tokenSet(h.name), candTokens));
  if (tokenSuper) return { hit: tokenSuper, confidence: 0.75, method: "token_superset" };

  // fall-through: top by popularity_score, but mark for review
  const sorted = [...hits].sort(
    (a, b) => (b.popularity_score ?? 0) - (a.popularity_score ?? 0),
  );
  return { hit: sorted[0], confidence: 0.4, method: "popularity_top" };
}

Deno.serve(async (req) => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const tevoToken   = Deno.env.get("TEVO_TOKEN")  ?? Deno.env.get("TEVO_API_TOKEN")  ?? "";
  const tevoSecret  = Deno.env.get("TEVO_SECRET") ?? Deno.env.get("TEVO_API_SECRET") ?? "";
  if (!tevoToken || !tevoSecret) {
    return new Response(JSON.stringify({ ok: false, error: "missing TEvo creds" }),
      { status: 500, headers: { "content-type": "application/json" } });
  }

  const url = new URL(req.url);
  const limit       = Math.max(1, Math.min(200, Number(url.searchParams.get("limit") ?? "80")));
  const dryRun      = url.searchParams.get("dry_run") === "true";
  const minConf     = Number(url.searchParams.get("min_confidence") ?? "0.75");

  const sb = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: candidates, error: candErr } = await sb
    .from("v_sg_unmatched_candidate_performers")
    .select("performer_name, event_count, categories")
    .order("event_count", { ascending: false })
    .limit(limit);
  if (candErr) {
    return new Response(JSON.stringify({ ok: false, error: candErr.message }), { status: 500 });
  }

  const samples: Array<Record<string, unknown>> = [];
  const byConf: Record<string, number> = {};
  let accepted = 0, skipped = 0, errored = 0;

  for (const c of (candidates ?? []) as Candidate[]) {
    // pick first non-null category for the search scope
    const sgCat = (c.categories ?? []).find((x) => x) ?? null;
    const catId = categoryFor(sgCat);

    const r = await tevoSearch(tevoToken, tevoSecret, c.performer_name, catId);
    if (!r.ok) {
      errored++;
      samples.push({ name: c.performer_name, error: r.status, body: r.body });
      continue;
    }
    const hits = ((r.body as { performers?: Hit[] }).performers ?? []) as Hit[];
    const best = pickBest(c.performer_name, hits);

    if (!best.hit || best.confidence < minConf) {
      skipped++;
      samples.push({
        name: c.performer_name, event_count: c.event_count,
        sg_category: sgCat, decision: "skipped", reason: best.method,
        confidence: best.confidence, top_hit: best.hit ? { id: best.hit.id, name: best.hit.name } : null,
      });
      continue;
    }

    byConf[best.method] = (byConf[best.method] ?? 0) + 1;

    if (!dryRun) {
      const { error: rpcErr } = await sb.rpc("record_sg_performer_match", {
        p_sg_name:       c.performer_name,
        p_tevo_perf_id:  best.hit.id,
        p_confidence:    best.confidence,
        p_match_method:  `tevo_search:${best.method}`,
        p_meta: {
          tevo_name: best.hit.name,
          tevo_category: best.hit.category?.slug,
          popularity: best.hit.popularity_score,
          sg_event_count: c.event_count,
          sg_categories: c.categories,
        },
      });
      if (rpcErr) { errored++; samples.push({ name: c.performer_name, rpc_error: rpcErr.message }); continue; }
    }
    accepted++;
    if (samples.length < 10) {
      samples.push({
        name: c.performer_name, event_count: c.event_count,
        decision: "accepted", method: best.method,
        confidence: best.confidence,
        tevo: { id: best.hit.id, name: best.hit.name },
      });
    }
  }

  return new Response(JSON.stringify({
    ok: true,
    dry_run: dryRun,
    processed: candidates?.length ?? 0,
    accepted, skipped, errored,
    by_method: byConf,
    samples,
  }, null, 2), { headers: { "content-type": "application/json" } });
});
