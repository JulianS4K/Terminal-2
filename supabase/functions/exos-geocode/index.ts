// exos-geocode — server-side Geocoding API proxy for venue maps (EXP docs/maps.md).
//
// The browser never calls googleapis.com for geocoding: it calls this
// function, which adds the server key, asks the Geocoding API, and returns
// { lat, lng, placeId }. Only organizers can trigger a lookup (each one costs
// money); buyers read stored results from exos_public_event_geo.
//
//   POST { event_id }  → org staff (owner / manager / content) geocode their
//                         event's venue; the result is stored (exos_event_geo).
//                         Skips the API call when the address hasn't changed
//                         and the stored pin is under 25 days old.
//   POST { address }   → any org staff member previews an address before
//                         saving an event. Nothing is stored.
//
// Required secrets: GOOGLE_MAPS_SERVER_KEY (restricted to the Geocoding API),
// SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY. verify_jwt: true.
// Read-only toward Google (GET); this is not a ticketing upstream.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildGeocodeUrl, parseGeocodeResponse, venueQuery, type GeocodeResult } from "../_shared/geocode.ts";

const EDIT_ROLES = ["owner", "manager", "content"];
const FRESH_MS = 25 * 24 * 3600 * 1000;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);
  const key = Deno.env.get("GOOGLE_MAPS_SERVER_KEY");
  if (!key) return json({ error: "server misconfigured: GOOGLE_MAPS_SERVER_KEY unset" }, 500);

  const sbUser = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await sbUser.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  let p: { event_id?: unknown; address?: unknown };
  try { p = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // Address preview: staff of at least one org, nothing stored.
  if (typeof p.address === "string") {
    const address = p.address.trim().slice(0, 300);
    if (!address) return json({ error: "address required" }, 400);
    const { count } = await sb.from("exos_org_memberships").select("org_id", { count: "exact", head: true })
      .eq("user_id", user.id).in("role", EDIT_ROLES);
    if (!count) return json({ error: "forbidden" }, 403);
    return reply(await geocode({ address }, key));
  }

  if (typeof p.event_id !== "string" || !/^[0-9a-f-]{36}$/i.test(p.event_id)) {
    return json({ error: "event_id or address required" }, 400);
  }
  const { data: ev } = await sb.from("exos_events")
    .select("id, org_id, venue_name, venue_location, venue_address")
    .eq("id", p.event_id).maybeSingle();
  if (!ev) return json({ error: "event not found" }, 404);
  const { data: allowed } = await sbUser.rpc("exos_has_org_role", { p_org_id: ev.org_id, p_roles: EDIT_ROLES });
  if (allowed !== true) return json({ error: "forbidden" }, 403);

  const query = venueQuery(ev.venue_name ?? ev.venue_location, ev.venue_address, ev.venue_location);
  if (!query) return json({ status: "zero_results", reason: "no mappable venue" });

  const { data: prior } = await sb.from("exos_event_geo")
    .select("query, status, place_id, lat, lng, geocoded_at").eq("event_id", ev.id).maybeSingle();
  if (prior && prior.query === query && prior.status === "ok" && prior.lat != null &&
      Date.now() - Date.parse(prior.geocoded_at) < FRESH_MS) {
    return json({ status: "ok", lat: prior.lat, lng: prior.lng, placeId: prior.place_id, cached: true });
  }

  const result = await geocode({ address: query }, key);
  const { error: upErr } = await sb.rpc("exos_upsert_event_geo", {
    p_event_id: ev.id,
    p_query: query,
    p_status: result.status,
    p_place_id: result.status === "ok" ? result.placeId : null,
    p_lat: result.status === "ok" ? result.lat : null,
    p_lng: result.status === "ok" ? result.lng : null,
    p_formatted_address: result.status === "ok" ? result.formattedAddress : null,
    p_error: result.status === "error" ? result.error : null,
  });
  if (upErr) {
    console.error("exos-geocode: store failed", upErr);
    return json({ error: "could not store result" }, 500);
  }
  return reply(result);
});

async function geocode(q: { address: string } | { placeId: string }, key: string): Promise<GeocodeResult> {
  try {
    const res = await fetch(buildGeocodeUrl(q, key), { signal: AbortSignal.timeout(8000) });
    if (!res.ok) return { status: "error", error: `HTTP ${res.status}` };
    return parseGeocodeResponse(await res.json());
  } catch (e) {
    return { status: "error", error: e instanceof Error ? e.message.slice(0, 200) : "request failed" };
  }
}

function reply(r: GeocodeResult): Response {
  if (r.status === "ok") return json({ status: "ok", lat: r.lat, lng: r.lng, placeId: r.placeId, formattedAddress: r.formattedAddress });
  if (r.status === "zero_results") return json({ status: "zero_results" });
  console.error("exos-geocode: lookup failed", r.error);
  return json({ status: "error", error: "lookup failed" }, 502);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
