// SG SellerDirect webhook receiver.
//
// Spec: https://developer.seatgeek.com/sellerdirect/api/webhook-notifications
// (operator pasted full spec into the WS2 plan 2026-05-16).
//
// Flow:
//   1. Method check — only POST accepted.
//   2. Bearer auth — Authorization header compared (constant-time) against
//      vault secret SG_SELLER_WEBHOOK_SECRET set in env at deploy.
//   3. Parse + schema_version gate — currently only v1.
//   4. Idempotency — INSERT notification_id into
//      sg_seller_webhook_notifications_seen ON CONFLICT DO NOTHING. If the
//      row already existed, the request is a SG retry; return 200 silently.
//   5. Dispatch — by metadata.notification_type, call the matching RPC.
//   6. Always return 200 quickly (≤10s timeout per SG spec). Long writes
//      run async; failures are logged but don't fail the webhook (SG's
//      circuit breaker pauses webhooks when we 5xx).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireBearer } from "../_shared/bearer-auth.ts";

interface WebhookEnvelope {
  metadata: {
    notification_type: string;
    seller_id?: number;
    notification_id: string;
    notification_generated_at?: string;
    schema_version: number;
  };
  // SG sends `data` as an array for batched notifications. order.fulfillment.error
  // is the one outlier — spec shows it as a single object; we accept both.
  data: unknown;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  // 1. Auth
  const authErr = requireBearer(req, "SG_SELLER_WEBHOOK_SECRET");
  if (authErr) return authErr;

  // 2. Parse + envelope validation
  let body: WebhookEnvelope;
  try {
    body = await req.json();
  } catch (_) {
    return new Response("invalid JSON", { status: 400 });
  }
  const metadata = body?.metadata;
  if (!metadata?.notification_id || !metadata?.notification_type) {
    return new Response("missing required metadata fields", { status: 400 });
  }
  if (metadata.schema_version !== 1) {
    return new Response(
      `unsupported schema_version: ${metadata.schema_version}`,
      { status: 400 },
    );
  }

  // 3. Idempotency log — record this notification_id before dispatch.
  //    SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY are injected by the platform.
  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const payloadCount = Array.isArray(body.data) ? body.data.length : 1;
  const seenInsert = await sb
    .from("sg_seller_webhook_notifications_seen")
    .insert({
      notification_id: metadata.notification_id,
      notification_type: metadata.notification_type,
      seller_id: metadata.seller_id ?? null,
      payload_count: payloadCount,
      schema_version: metadata.schema_version,
      payload_summary: summarizePayload(metadata.notification_type, body.data),
    })
    .select("notification_id");

  if (seenInsert.error) {
    // Postgres 23505 = unique_violation → SG retry, return 200 silently.
    if (seenInsert.error.code === "23505") {
      return jsonResponse({ deduped: true, notification_id: metadata.notification_id });
    }
    // Other DB errors are unexpected — log + 500 so SG's circuit breaker
    // surfaces the issue rather than us silently dropping notifications.
    console.error(
      `sg-seller-webhook: failed to record notification ${metadata.notification_id}`,
      seenInsert.error,
    );
    return new Response("internal error recording notification", { status: 500 });
  }

  // 4. Dispatch async — respond 200 immediately per SG recommendation.
  //    On Deno Deploy, the response is sent when we return; pending
  //    promises continue running. We swallow dispatch errors so the
  //    webhook always 200s once we've recorded the notification.
  //    (If SG sees 5xx repeatedly its circuit breaker pauses deliveries —
  //    we'd rather retain the audit row + retry-via-replay than lose
  //    visibility into what was sent.)
  dispatch(sb, metadata, body.data).catch((e) => {
    console.error(
      `sg-seller-webhook: async dispatch failed for ${metadata.notification_id} (${metadata.notification_type}): ${e}`,
    );
  });

  return jsonResponse({ received: true, notification_id: metadata.notification_id });
});

// Map notification_type → ingest RPC. Each RPC takes (p_events, p_seller_id,
// p_notification_id?) and returns (inserted, updated, skipped). order.created
// is special: it UPSERTs into seatgeek_orders and does NOT take notification_id
// (idempotency comes from sg_order_id, not notification_id).
async function dispatch(
  sb: ReturnType<typeof createClient>,
  metadata: WebhookEnvelope["metadata"],
  data: unknown,
): Promise<void> {
  const type = metadata.notification_type;
  const sellerId = metadata.seller_id ?? null;
  const notifId = metadata.notification_id;

  switch (type) {
    case "ping":
      // Audit row already recorded; no further action.
      return;

    case "order.created": {
      const events = Array.isArray(data) ? data : [data];
      const { error } = await sb.rpc("sg_seller_orders_ingest_from_webhook", {
        p_orders: events,
        p_seller_id: sellerId,
      });
      if (error) throw error;
      return;
    }

    case "order.retransfer":
      await callIngest(sb, "sg_seller_order_retransfers_ingest", data, sellerId, notifId);
      return;

    case "order.fulfillment.error":
      // SG sends a single object for this type (per spec); the RPC handles
      // both shapes defensively.
      await callIngest(sb, "sg_seller_order_fulfillment_errors_ingest", data, sellerId, notifId);
      return;

    case "listing.event.inactive":
      await callIngest(sb, "sg_seller_listing_inactive_events_ingest", data, sellerId, notifId);
      return;

    case "listing.visibility":
      await callIngest(sb, "sg_seller_listing_visibility_ingest", data, sellerId, notifId);
      return;

    case "listing.normalization.status":
      await callIngest(sb, "sg_seller_listing_normalization_ingest", data, sellerId, notifId);
      return;

    case "listing.normalization.status.changed":
      await callIngest(sb, "sg_seller_listing_normalization_changes_ingest", data, sellerId, notifId);
      return;

    default:
      console.warn(`sg-seller-webhook: unknown notification_type ${type} (id=${notifId})`);
      return;
  }
}

async function callIngest(
  sb: ReturnType<typeof createClient>,
  rpcName: string,
  data: unknown,
  sellerId: number | null,
  notificationId: string,
): Promise<void> {
  const events = Array.isArray(data) ? data : [data];
  const { error } = await sb.rpc(rpcName, {
    p_events: events,
    p_seller_id: sellerId,
    p_notification_id: notificationId,
  });
  if (error) throw error;
}

// Tiny audit summary stored on the notifications_seen row — keeps the table
// scannable for "what was in this batch" without re-pulling SG.
function summarizePayload(notificationType: string, data: unknown): Record<string, unknown> {
  const items = Array.isArray(data) ? data : [data];
  const summary: Record<string, unknown> = { count: items.length };
  if (notificationType === "order.created" && items.length > 0) {
    const first = items[0] as Record<string, unknown>;
    summary.first_order_id = first?.id ?? null;
    summary.first_status = first?.status ?? null;
  }
  return summary;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
