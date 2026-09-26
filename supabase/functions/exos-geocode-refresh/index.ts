// exos-geocode-refresh — keeps venue coordinates inside Google's 30-day
// caching limit (EXP docs/maps.md).
//
// Called by pg_cron (x-cron-secret). Re-geocodes published events whose pin
// is 25+ days old, by Place ID where we have one (Place IDs may be stored
// indefinitely), then clears any coordinates that are still older than 30
// days. Suggested schedule: daily. Scheduling it is operator-gated.
//
// Required secrets: GOOGLE_MAPS_SERVER_KEY, CRON_SECRET, SUPABASE_URL,
// SUPABASE_SERVICE_ROLE_KEY. verify_jwt: false (the cron secret is the auth).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";
import { buildGeocodeUrl, parseGeocodeResponse, type GeocodeResult } from "../_shared/geocode.ts";

Deno.serve(async (req: Request): Promise<Response> => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;
  const key = Deno.env.get("GOOGLE_MAPS_SERVER_KEY");
  if (!key) return json({ error: "server misconfigured: GOOGLE_MAPS_SERVER_KEY unset" }, 500);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data: due, error } = await sb.rpc("exos_event_geo_due", { p_days: 25, p_limit: 50 });
  if (error) {
    console.error("exos-geocode-refresh: due query failed", error);
    return json({ error: "due query failed" }, 500);
  }

  let refreshed = 0, failed = 0;
  for (const row of (due ?? []) as { event_id: string; query: string; place_id: string | null }[]) {
    const result = await geocode(row.place_id ? { placeId: row.place_id } : { address: row.query }, key);
    const { error: upErr } = await sb.rpc("exos_upsert_event_geo", {
      p_event_id: row.event_id,
      p_query: row.query,
      p_status: result.status,
      p_place_id: result.status === "ok" ? result.placeId : null,
      p_lat: result.status === "ok" ? result.lat : null,
      p_lng: result.status === "ok" ? result.lng : null,
      p_formatted_address: result.status === "ok" ? result.formattedAddress : null,
      p_error: result.status === "error" ? result.error : null,
    });
    if (upErr || result.status !== "ok") failed++;
    else refreshed++;
  }

  const { data: expired, error: expErr } = await sb.rpc("exos_expire_event_geo");
  if (expErr) {
    console.error("exos-geocode-refresh: expiry failed", expErr);
    return json({ error: "expiry failed", refreshed, failed }, 500);
  }
  return json({ refreshed, failed, expired });
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

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
