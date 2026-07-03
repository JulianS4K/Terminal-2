// Supabase Edge Function: broadway-cast-collect
//
// Daily cast-source WATCH for the Broadway cast-run overlay (D3).
//
// For every broadway_show_ref with a cast_wiki_title, fetch the article's cast
// section from Wikipedia (GET-only — RULE 2), hash it, and compare to the last
// seen hash. On a change, log candidate cast rows + raise a bot_chat flag so a
// curator can confirm and update broadway_cast_run by hand. This function NEVER
// writes broadway_cast_run — the curated table is authoritative; candidates are
// advisory only. Change detection is the product; auto-authoring is not.
//
// Wikipedia is the one automation-friendly cast source (open API, rate-limit-
// free at this scale, proven by wiki-collect). IBDB/Playbill/BroadwayWorld 403
// datacenter fetchers and stay in the human-curated path.
//
// Invoked once/day by the broadway_cast_collect_daily pg_cron job.
// POST { slug?: string }  — optional single-show run for testing.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";

const WIKI_API = "https://en.wikipedia.org/w/api.php";
const USER_AGENT = "Terminal-2/1.0 (s4kentertainment.com; julian@s4kent.com)";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Fetch raw wikitext for an article (GET only).
async function fetchWikitext(title: string): Promise<{ status: number; text: string | null }> {
  const url = `${WIKI_API}?action=parse&page=${encodeURIComponent(title)}&prop=wikitext&format=json&formatversion=2&redirects=1`;
  const r = await fetch(url, { headers: { "User-Agent": USER_AGENT, Accept: "application/json" } });
  if (!r.ok) return { status: r.status, text: null };
  const j = await r.json();
  return { status: 200, text: j?.parse?.wikitext ?? null };
}

// Slice out the cast/replacement section(s) — the part that changes when a lead
// turns over. Falls back to the whole article if no cast heading is found, so
// change detection still works.
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
// Pulls "Name … Month DD, YYYY" style rows out of the cast section. Deliberately
// conservative: better to surface nothing than to fabricate a run.
function parseCandidates(section: string): Array<{ performer: string; dates: string }> {
  const out: Array<{ performer: string; dates: string }> = [];
  const dateRe = /((?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},?\s+\d{4})/g;
  const nameRe = /\[\[([^\]|]+?)(?:\|[^\]]+)?\]\]/; // first wikilinked name on a line
  for (const raw of section.split("\n")) {
    const dates = raw.match(dateRe);
    if (!dates || dates.length === 0) continue;
    const nm = raw.match(nameRe);
    if (!nm) continue;
    const performer = nm[1].trim();
    // skip obvious non-person links (dates, roles, theatres)
    if (/theatre|theater|musical|broadway|\d{4}/i.test(performer)) continue;
    out.push({ performer, dates: dates.join(" – ") });
    if (out.length >= 12) break;
  }
  return out;
}

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  let body: any = {}; try { body = await req.json(); } catch (_) { /* no body */ }
  const slugFilter = body?.slug as string | undefined;

  let q = db.from("broadway_show_ref")
    .select("show_slug, title, cast_wiki_title, cast_last_section_hash")
    .not("cast_wiki_title", "is", null);
  if (slugFilter) q = q.eq("show_slug", slugFilter);
  const { data: shows, error: selErr } = await q;
  if (selErr) return new Response(JSON.stringify({ error: selErr.message }), { status: 500 });

  const stats = { polled: 0, changed: 0, flags: 0, errors: 0, not_found: 0, log: [] as string[] };

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
      } else if (status === 404 || !res.text) {
        stats.not_found++;
        err = `no wikitext (status ${status}) for "${s.cast_wiki_title}"`;
      }
    } catch (e) {
      stats.errors++; err = (e as Error).message;
      stats.log.push(`${s.show_slug}: ${err}`);
    }

    // First observation (no prior hash) is not a "change" — just a baseline.
    const isBaseline = !s.cast_last_section_hash && !!hash;

    // Log the poll.
    await db.from("broadway_cast_pull_log").insert({
      show_slug: s.show_slug, source: "Wikipedia", wiki_title: s.cast_wiki_title,
      http_status: status, section_hash: hash || null, section_changed: changed,
      candidates, flag_raised: changed, error_message: err,
    });

    // Stamp freshness + latest hash (only advance the hash when we got one).
    const upd: Record<string, unknown> = { cast_last_polled_at: new Date().toISOString() };
    if (hash) upd.cast_last_section_hash = hash;
    await db.from("broadway_show_ref").update(upd).eq("show_slug", s.show_slug);

    // On a real change, flag a curator (event_type 'flag' does NOT auto-resolve).
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
    if (isBaseline) stats.log.push(`${s.show_slug}: baseline hash recorded`);

    await sleep(120); // be polite to Wikipedia
  }

  return new Response(JSON.stringify(stats), { headers: { "Content-Type": "application/json" } });
});
