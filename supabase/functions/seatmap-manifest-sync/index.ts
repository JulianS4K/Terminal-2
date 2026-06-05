// seatmap-manifest-sync — fetch TEvo seat-map manifests (public CDN) and cache the
// section-key lists in public.seatmap_manifest. Runs on Supabase egress (which CAN
// reach maps.ticketevolution.com, unlike the agent/SQL sandbox), driven by the
// `seatmap-manifest-sync` cron. Bounded per run; idempotent (upsert). See
// migration 20260603160000.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const MAPS = "https://maps.ticketevolution.com";

// Cron-secret gate — inlined (self-contained for per-function deploy) but identical
// in behaviour to ../_shared/cron-auth.ts: fail-closed if CRON_SECRET unset, then a
// constant-time compare of the x-cron-secret header.
function requireCronSecret(req: Request): Response | null {
  const expected = Deno.env.get("CRON_SECRET");
  if (!expected) return new Response("server misconfigured: CRON_SECRET unset", { status: 500 });
  const provided = req.headers.get("x-cron-secret") ?? "";
  let mismatch = provided.length ^ expected.length;
  const n = Math.max(provided.length, expected.length);
  for (let i = 0; i < n; i++) mismatch |= (provided.charCodeAt(i) || 0) ^ (expected.charCodeAt(i) || 0);
  return mismatch === 0 ? null : new Response("unauthorized", { status: 401 });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const t0 = Date.now();
  const WALL_BUDGET_MS = 50_000;
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const body = await req.json().catch(() => ({}));
  const limit = Math.min(Number(body?.limit ?? 60), 200);

  const { data: targets, error: tErr } = await db.rpc("seatmap_manifest_targets", { p_limit: limit });
  if (tErr) return new Response(JSON.stringify({ error: tErr.message }), { status: 500 });

  let processed = 0, synced = 0, withMap = 0, errors = 0;
  const errs: unknown[] = [];

  for (const t of targets ?? []) {
    if (Date.now() - t0 > WALL_BUDGET_MS) break;
    processed++;
    const row: Record<string, unknown> = {
      venue_id: t.venue_id, configuration_id: t.configuration_id,
      has_map: false, http_status: null, section_count: 0, section_keys: [],
      fetched_at: new Date().toISOString(),
    };
    try {
      const r = await fetch(`${MAPS}/${t.venue_id}/${t.configuration_id}/manifest.json`, {
        signal: AbortSignal.timeout(8000),
      });
      row.http_status = r.status;
      if (r.ok) {
        const m = await r.json().catch(() => ({}));
        const keys = Object.keys((m && m.sections) || {});
        row.has_map = keys.length > 0;
        row.section_count = keys.length;
        row.section_keys = keys;
        if (row.has_map) withMap++;
      }
    } catch (e) {
      errors++; errs.push({ v: t.venue_id, c: t.configuration_id, e: String((e as Error).message) });
    }
    const { error: upErr } = await db.from("seatmap_manifest")
      .upsert(row, { onConflict: "venue_id,configuration_id" });
    if (upErr) { errors++; errs.push({ v: t.venue_id, c: t.configuration_id, e: upErr.message }); }
    else synced++;
  }

  return new Response(JSON.stringify({
    ok: true, processed, synced, withMap, errors,
    remaining: (targets?.length ?? 0) - processed,
    ms: Date.now() - t0, sample_errors: errs.slice(0, 5),
  }), { headers: { "Content-Type": "application/json" } });
});
