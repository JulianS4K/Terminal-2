// Supabase Edge Function: broadway-cast-collect
//
// Cast-source automation for the Broadway cast-run overlay (D3). Two modes:
//
//   mode "poll"     (daily)  — for every broadway_show_ref with a cast_wiki_title,
//                              fetch the article's cast section, hash it, and on a
//                              change log candidates + raise a bot_chat flag for a
//                              curator. NEVER writes broadway_cast_run (curated table
//                              is authoritative; candidates are advisory only).
//   mode "discover" (weekly) — for shows with NO cast_wiki_title yet, search Wikipedia
//                              for the article and auto-set a high-confidence match so
//                              the daily poll starts watching it; low-confidence hits
//                              are logged as suggestions for a curator instead.
//
// Wikipedia is the one automation-friendly cast source (open API, rate-limit-free at
// this scale, proven by wiki-collect). IBDB/Playbill/BroadwayWorld 403 datacenter
// fetchers and stay in the human-curated path. GET-only — RULE 2.
//
// POST { mode?: "poll" | "discover", slug?: string }  (default "poll")

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";

const WIKI_API = "https://en.wikipedia.org/w/api.php";
const USER_AGENT = "Terminal-2/1.0 (s4kentertainment.com; julian@s4kent.com)";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function fetchWikitext(title: string): Promise<{ status: number; text: string | null }> {
  const url = `${WIKI_API}?action=parse&page=${encodeURIComponent(title)}&prop=wikitext&format=json&formatversion=2&redirects=1`;
  const r = await fetch(url, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" } });
  if (!r.ok) return { status: r.status, text: null };
  const j = await r.json();
  return { status: 200, text: j?.parse?.wikitext ?? null };
}

async function wikiSearch(query: string): Promise<Array<{ title: string }>> {
  const url = `${WIKI_API}?action=query&list=search&srsearch=${encodeURIComponent(query)}&srlimit=3&srnamespace=0&format=json&formatversion=2`;
  const r = await fetch(url, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" } });
  if (!r.ok) return [];
  const j = await r.json();
  return (j?.query?.search ?? []).map((s: any) => ({ title: s.title as string }));
}

// Slice out the cast/replacement section(s) — the part that changes when a lead
// turns over. Falls back to the whole article if no cast heading is found.
function extractCastSection(wikitext: string): string {
  const lines = wikitext.split("\n");
  const out: string[] = [];
  let capturing = false;
  const castHeading = /^==+\s*(cast|casts|replacement|principal cast|casting)\b/i;
  const anyHeading = /^==+[^=]/;
  for (const line of lines) {
    if (castHeading.test(line)) { capturing = true; out.push(line); continue; }
    if (capturing && anyHeading.test(line) && !castHeading.test(line)) { capturing = false; }
    if (capturing) out.push(line);
  }
  return (out.length ? out.join("\n") : wikitext).trim();
}

// Best-effort candidate extraction — advisory only, for a human to confirm.
function parseCandidates(section: string): Array<{ performer: string; dates: string }> {
  const out: Array<{ performer: string; dates: string }> = [];
  const dateRe = /((?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?\s+\d{4})/g;
  const nameRe = /\[\[([^\]|]+?)(?:\|[^\]]+)?\]\]/;
  for (const raw of section.split("\n")) {
    const dates = raw.match(dateRe);
    if (!dates || dates.length === 0) continue;
    const nm = raw.match(nameRe);
    if (!nm) continue;
    const performer = nm[1].trim();
    if (/theatre|theater|musical|broadway|\d{4}/i.test(performer)) continue;
    out.push({ performer, dates: dates.join(" – ") });
    if (out.length >= 12) break;
  }
  return out;
}

// Normalize a title for match confidence: drop parenthticals, punctuation, and
// filler words so "Hamilton" ~ "Hamilton (musical)" and "SIX: The Musical" ~ "Six (musical)".
function normTitle(s: string): string {
  return s.toLowerCase()
    .replace(/\(.*?\)/g, " ")
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\b(the|a|an|musical|play|broadway)\b/g, " ")
    .replace(/\s+/g, " ").trim();
}

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ---- mode: poll (daily) ----------------------------------------------------
async function runPoll(db: any, slugFilter?: string) {
  let q = db.from("broadway_show_ref")
    .select("show_slug, title, cast_wiki_title, cast_last_section_hash")
    .not("cast_wiki_title", "is", null);
  if (slugFilter) q = q.eq("show_slug", slugFilter);
  const { data: shows, error } = await q;
  if (error) throw new Error(error.message);

  const stats = { mode: "poll", polled: 0, changed: 0, flags: 0, errors: 0, not_found: 0, log: [] as string[] };
  for (const s of (shows ?? []) as any[]) {
    stats.polled++;
    let status = 0, section = "", hash = "", changed = false, err: string | null = null;
    let candidates: Array<{ performer: string; dates: string }> = [];
    try {
      const res = await fetchWikitext(s.cast_wiki_title);
      status = res.status;
      if (status === 200 && res.text) {
        section = extractCastSection(res.text);
        hash = await sha256Hex(section);
        candidates = parseCandidates(section);
        changed = !!s.cast_last_section_hash && s.cast_last_section_hash !== hash;
      } else { stats.not_found++; err = `no wikitext (status ${status}) for "${s.cast_wiki_title}"`; }
    } catch (e) { stats.errors++; err = (e as Error).message; stats.log.push(`${s.show_slug}: ${err}`); }

    await db.from("broadway_cast_pull_log").insert({
      show_slug: s.show_slug, source: "Wikipedia", wiki_title: s.cast_wiki_title,
      http_status: status, section_hash: hash || null, section_changed: changed,
      candidates, flag_raised: changed, error_message: err,
    });

    const upd: Record<string, unknown> = { cast_last_polled_at: new Date().toISOString() };
    if (hash) upd.cast_last_section_hash = hash;
    await db.from("broadway_show_ref").update(upd).eq("show_slug", s.show_slug);

    if (changed) {
      stats.changed++;
      try {
        await db.rpc("bot_chat_log", {
          p_level: "info", p_lane: "d3", p_event_type: "flag",
          p_message: `Cast section changed on Wikipedia for "${s.title}" (${s.cast_wiki_title}). Review broadway_cast_run for a new/updated lead.`,
          p_meta: { show_slug: s.show_slug, candidates },
        });
        stats.flags++;
      } catch (e) { stats.log.push(`bot_chat_log ${s.show_slug}: ${(e as Error).message}`); }
    }
    await sleep(120);
  }
  return stats;
}

// ---- mode: discover (weekly) -----------------------------------------------
// Fill in cast_wiki_title for shows that have none, by searching Wikipedia and
// auto-setting only high-confidence matches. Low-confidence hits are logged as
// suggestions (source 'title-sweep') for a curator — never silently set.
async function runDiscover(db: any) {
  const { data: shows, error } = await db.from("broadway_show_ref")
    .select("show_slug, title, city")
    .is("cast_wiki_title", null);
  if (error) throw new Error(error.message);

  const stats = { mode: "discover", scanned: 0, resolved: 0, suggested: 0, none: 0, errors: 0, log: [] as string[] };
  for (const s of (shows ?? []) as any[]) {
    stats.scanned++;
    try {
      const hits = await wikiSearch(`${s.title} Broadway`);
      if (hits.length === 0) { stats.none++; }
      const want = normTitle(s.title);
      const match = hits.find((h) => {
        const got = normTitle(h.title);
        return want.length > 2 && (got === want || got.includes(want) || want.includes(got));
      });
      if (match) {
        await db.from("broadway_show_ref").update({
          cast_wiki_title: match.title,
          cast_source_name: "Wikipedia (auto)",
          cast_source_url: "https://en.wikipedia.org/wiki/" + match.title.replace(/ /g, "_"),
        }).eq("show_slug", s.show_slug);
        await db.from("broadway_cast_pull_log").insert({
          show_slug: s.show_slug, source: "title-sweep", wiki_title: match.title,
          http_status: 200, section_changed: false, flag_raised: false,
          candidates: hits, error_message: null,
        });
        stats.resolved++;
      } else if (hits.length > 0) {
        // ambiguous — log a suggestion for a human, don't set.
        await db.from("broadway_cast_pull_log").insert({
          show_slug: s.show_slug, source: "title-sweep", wiki_title: null,
          http_status: 200, section_changed: false, flag_raised: true,
          candidates: hits, error_message: "no high-confidence title match — needs curator",
        });
        stats.suggested++;
      }
    } catch (e) { stats.errors++; stats.log.push(`${s.show_slug}: ${(e as Error).message}`); }
    await sleep(150);
  }
  return stats;
}

Deno.serve(async (req) => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  let body: any = {}; try { body = await req.json(); } catch (_) { /* no body */ }
  const mode = (body?.mode as string) ?? "poll";
  try {
    const stats = mode === "discover" ? await runDiscover(db) : await runPoll(db, body?.slug);
    return new Response(JSON.stringify(stats), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: (e as Error).message, mode }), { status: 500 });
  }
});
