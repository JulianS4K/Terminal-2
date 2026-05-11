// crawl-espn-team-assets edge fn v2 (adds name fallback on upsert)
//
// Captured into git 2026-05-08 by code via audit-and-commit (copilot deployed,
// no git capture until now). Drains the espn_asset_crawl_state queue: pulls
// up to N pending performers per invocation, hits ESPN's /teams/{id} endpoint
// for each, upserts logos+colors+ESPN URLs into performer_metadata and
// venue (when available) into venue_assets.
//
// AUDIT NOTE (code, 2026-05-08): no cron currently calls this fn. The queue
// progresses only via manual invocation. As of capture: 65/169 done, 104
// pending. Either copilot needs to add a cron tick driving it, or the queue
// gets drained manually periodically. Flagged as NEXT in AGENTS.md LOG.
//
// Auth model: verify_jwt=false (matches collect-listings/espn-collect pattern).
// Internal X-Cron-Secret check inside the fn — currently has the placeholder
// "pick-any-random-string-and-save-it" which means anyone with the URL can
// invoke it. Acceptable for an internal helper; tighten if it ever moves to
// a public surface.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
import { requireCronSecret } from "../_shared/cron-auth.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const SPORT_SLUG: Record<string, string> = {
  NBA:  "basketball/nba",
  WNBA: "basketball/wnba",
  MLB:  "baseball/mlb",
  NHL:  "hockey/nhl",
  NFL:  "football/nfl",
  MLS:  "soccer/usa.1",
};

interface EspnLogo { href: string; alt?: string; rel?: string[]; width?: number; height?: number; }
interface EspnImage { href: string; width?: number; height?: number; alt?: string; rel?: string[]; }
interface EspnVenue {
  id?: string; fullName?: string; capacity?: number; indoor?: boolean;
  images?: EspnImage[]; address?: { city?: string; state?: string; country?: string };
}
interface EspnTeam {
  id: string; uid?: string; slug?: string; abbreviation?: string;
  displayName?: string; shortDisplayName?: string; name?: string;
  nickname?: string; location?: string; color?: string; alternateColor?: string;
  isActive?: boolean; logos?: EspnLogo[];
  links?: { rel?: string[]; href?: string; text?: string }[];
  franchise?: { id?: string; venue?: EspnVenue };
}

function pickLogo(logos: EspnLogo[] | undefined, ...wanted: string[][]): string | null {
  if (!logos || logos.length === 0) return null;
  for (const want of wanted) {
    const hit = logos.find(l => {
      const rel = (l.rel ?? []).map(s => s.toLowerCase());
      return want.every(w => rel.includes(w));
    });
    if (hit?.href) return hit.href;
  }
  return logos[0]?.href ?? null;
}

function pickLink(links: { rel?: string[]; href?: string }[] | undefined, ...want: string[]): string | null {
  if (!links) return null;
  const wantSet = new Set(want.map(s => s.toLowerCase()));
  const hit = links.find(l => (l.rel ?? []).some(r => wantSet.has(r.toLowerCase())));
  return hit?.href ?? null;
}

function pickVenueImage(images: EspnImage[] | undefined): string | null {
  if (!images || images.length === 0) return null;
  const sorted = [...images].sort((a, b) => (b.width ?? 0) - (a.width ?? 0));
  return sorted[0]?.href ?? null;
}

function pickVenueMap(images: EspnImage[] | undefined): string | null {
  if (!images || images.length === 0) return null;
  const map = images.find(i => (i.rel ?? []).map(s => s.toLowerCase()).some(r => /map|schematic|seating/.test(r)));
  if (map?.href) return map.href;
  if (images.length >= 2) {
    const sorted = [...images].sort((a, b) => (b.width ?? 0) - (a.width ?? 0));
    return sorted[1]?.href ?? null;
  }
  return null;
}

async function fetchEspnTeam(sportSlug: string, espnTeamId: string): Promise<EspnTeam | null> {
  const url = `https://site.api.espn.com/apis/site/v2/sports/${sportSlug}/teams/${espnTeamId}`;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const r = await fetch(url, { headers: { "User-Agent": "S4K-Terminal/1.0 (asset crawler)" } });
      if (r.ok) { const j = await r.json(); return j?.team ?? null; }
      if (r.status === 429 || r.status >= 500) { await new Promise(res => setTimeout(res, 400 * (attempt + 1))); continue; }
      return null;
    } catch { await new Promise(res => setTimeout(res, 400 * (attempt + 1))); }
  }
  return null;
}

Deno.serve(async (req: Request) => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const startedAt = Date.now();
  const WALL_MS = 50_000;
  const PACING_MS = 250;

  let limit = 30;
  try { const body = await req.json(); if (typeof body?.limit === "number") limit = Math.max(1, Math.min(100, body.limit)); } catch {}

  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: pending, error: pickErr } = await sb
    .from("espn_asset_crawl_state")
    .select("performer_id, espn_team_id, espn_league, retries")
    .eq("status", "pending").lt("retries", 3)
    .order("retries", { ascending: true }).limit(limit);

  if (pickErr) return new Response(JSON.stringify({ error: pickErr.message }), { status: 500, headers: { "Content-Type": "application/json" } });
  if (!pending || pending.length === 0) return new Response(JSON.stringify({ done: true, fetched: 0 }), { headers: { "Content-Type": "application/json" } });

  const stats = { fetched: 0, ok: 0, error: 0, venue_writes: 0, team_writes: 0 };

  for (const row of pending) {
    if (Date.now() - startedAt > WALL_MS) break;

    const sportSlug = SPORT_SLUG[row.espn_league];
    if (!sportSlug) {
      await sb.from("espn_asset_crawl_state").update({ status: "error", last_error: `unsupported league: ${row.espn_league}`, retries: row.retries + 1 }).eq("performer_id", row.performer_id);
      stats.error++; continue;
    }

    const team = await fetchEspnTeam(sportSlug, row.espn_team_id);
    stats.fetched++;
    await new Promise(res => setTimeout(res, PACING_MS));

    if (!team) {
      await sb.from("espn_asset_crawl_state").update({ status: "error", last_error: "team fetch failed", retries: row.retries + 1 }).eq("performer_id", row.performer_id);
      stats.error++; continue;
    }

    const { data: pei } = await sb.from("performer_external_ids").select("external_name").eq("performer_id", row.performer_id).eq("source", "espn").maybeSingle();
    const fallbackName = pei?.external_name ?? team.displayName ?? team.name ?? null;

    const teamAssets = {
      name: fallbackName,
      espn_team_id: team.id ?? row.espn_team_id,
      espn_league: row.espn_league,
      color_primary: team.color ?? null,
      color_alternate: team.alternateColor ?? null,
      logo_default_url:    pickLogo(team.logos, ["full","default"], ["full"]),
      logo_dark_url:       pickLogo(team.logos, ["full","dark"]),
      logo_scoreboard_url: pickLogo(team.logos, ["full","scoreboard"]),
      logo_4k_primary_url: pickLogo(team.logos, ["full","primary_logo_on_white_color"], ["full","primary_logo_on_primary_color"], ["full","primary_logo_on_black_color"]),
      logo_secondary_url:  pickLogo(team.logos, ["full","secondary_logo_on_white_color"], ["full","secondary_logo_on_primary_color"]),
      espn_team_url:     pickLink(team.links, "clubhouse", "team"),
      espn_roster_url:   pickLink(team.links, "roster"),
      espn_schedule_url: pickLink(team.links, "schedule"),
      espn_raw: team,
      espn_fetched_at: new Date().toISOString(),
    };

    const { error: pmErr } = await sb.from("performer_metadata").upsert({ performer_id: row.performer_id, ...teamAssets }, { onConflict: "performer_id" });
    if (pmErr) {
      await sb.from("espn_asset_crawl_state").update({ status: "error", last_error: `performer_metadata upsert: ${pmErr.message}`, retries: row.retries + 1 }).eq("performer_id", row.performer_id);
      stats.error++; continue;
    }
    stats.team_writes++;

    const { data: phv } = await sb.from("performer_home_venues").select("venue_id, venue_name").eq("performer_id", row.performer_id).limit(1).maybeSingle();
    const venue = team.franchise?.venue;
    if (phv?.venue_id && venue) {
      const venuePatch = {
        tevo_venue_id: phv.venue_id, venue_name: phv.venue_name ?? null,
        espn_venue_id: venue.id ?? null, espn_venue_name: venue.fullName ?? null,
        hero_image_url: pickVenueImage(venue.images), map_image_url: pickVenueMap(venue.images),
        capacity: venue.capacity ?? null,
        city: venue.address?.city ?? null, state: venue.address?.state ?? null,
        country: venue.address?.country ?? null, is_indoor: venue.indoor ?? null,
        espn_raw: venue, source: "espn", fetched_at: new Date().toISOString(),
      };
      const { error: vaErr } = await sb.from("venue_assets").upsert(venuePatch, { onConflict: "tevo_venue_id" });
      if (!vaErr) stats.venue_writes++;
    }

    await sb.from("espn_asset_crawl_state").update({ status: "ok", last_error: null, last_fetched_at: new Date().toISOString() }).eq("performer_id", row.performer_id);
    stats.ok++;
  }

  const { count: pendingRemaining } = await sb.from("espn_asset_crawl_state").select("performer_id", { count: "exact", head: true }).eq("status", "pending");

  return new Response(JSON.stringify({ ok: true, elapsed_ms: Date.now() - startedAt, ...stats, pending_remaining: pendingRemaining ?? null }), { headers: { "Content-Type": "application/json" } });
});
