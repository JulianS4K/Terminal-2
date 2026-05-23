// exos-distribute — push Exos primary inventory to distribution channels
// (Automatiq/Lysted -> EVO/SeatGeek/StubHub) (D4 "Toast for tickets" SCAFFOLD).
//
// Why this is the "it's both" path: D1's storefront reads TEvo/EVO "owned"
// inventory, and Automatiq distributes INTO EVO — so listing an org's primary
// inventory via Automatiq surfaces it in the D1 storefront AND the wider
// secondary ecosystem from one push. bridge_event_xref.tevo_event_id links the
// resulting EVO listing back to the Exos primary for buy-routing + dedupe.
//
// Auth: cron-secret gated (Hard Rule #7 — burns a paid upstream API + mutates).
//
// ⚠ GATED: the actual Automatiq/Lysted listing call is a forbidden upstream
// WRITE without explicit operator authorization (Hard Rule #2) + provider creds.
// This fn is INERT until AUTOMATIQ_API_KEY is set; the listing call is a clearly
// marked TODO. Until then it no-ops with a misconfigured response — same posture
// as the Stripe + mail-drainer scaffolds.
//
// Required secrets (operator, when activated): CRON_SECRET, SUPABASE_URL,
// SUPABASE_SERVICE_ROLE_KEY, AUTOMATIQ_API_KEY. Per-org distribution creds
// (e.g. lystedSellerId) live in exos_org_secrets.distribution.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";

interface DistRow {
  id: string;
  event_id: string;
  org_id: string;
  channel: string;
  requested_qty: number | null;
  unit_price: number | null;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const automatiqKey = Deno.env.get("AUTOMATIQ_API_KEY");
  if (!automatiqKey) {
    // Inert until the operator activates distribution (creds + Hard Rule #2 sign-off).
    return json({ error: "distribution disabled: AUTOMATIQ_API_KEY unset (gated)" }, 500);
  }

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: pending, error } = await sb
    .from("exos_distribution_listings")
    .select("id, event_id, org_id, channel, requested_qty, unit_price")
    .eq("status", "pending")
    .limit(25);
  if (error) {
    console.error("exos-distribute: read pending failed", error);
    return json({ error: "read failed", detail: error.message }, 500);
  }

  const rows = (pending ?? []) as DistRow[];
  let listed = 0;
  let failed = 0;

  for (const row of rows) {
    await sb.from("exos_distribution_listings")
      .update({ status: "listing", last_synced_at: new Date().toISOString() })
      .eq("id", row.id);
    try {
      // TODO(operator/A1): call Automatiq/Lysted to create the listing for this
      // event on `row.channel`, using AUTOMATIQ_API_KEY + the org's
      // exos_org_secrets.distribution creds. On success capture the external
      // listing id; for EVO, also record the resulting tevo_event_id into
      // bridge_event_xref so D1 routes the buy back to the Exos primary.
      throw new Error("automatiq integration not wired (scaffold)");
      // const ext = await automatiqCreateListing(...);
      // await sb.from("exos_distribution_listings").update({ status:"listed",
      //   external_listing_id: ext.id, last_synced_at: new Date().toISOString(),
      //   error: null }).eq("id", row.id);
      // listed++;
    } catch (e) {
      await sb.from("exos_distribution_listings")
        .update({ status: "failed", error: String(e).slice(0, 500), last_synced_at: new Date().toISOString() })
        .eq("id", row.id);
      failed++;
    }
  }

  return json({ pending: rows.length, listed, failed, note: "scaffold — listing call not wired" });
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
