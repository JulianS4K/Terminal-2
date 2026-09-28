// TEvo Catalog Notifications (webhooks) receiver.
//
// Spec: TEvo Integrations "Catalog Notifications (Webhooks)" (Confluence,
// updated 2026-01-30; operator pasted it 2026-09-28). TEvo POSTs
// application/x-www-form-urlencoded with:
//   recipient, event_type, body (entity JSON),
//   + event_id | performer_id | venue_id (per entity kind).
// event_type ∈ {event,performer,venue}_{created,updated,deleted}. The URL is
// SHARED with TEvo Order Notifications, so we triage on event_type and log
// anything else (order_*, unknown) rather than dropping it. TEvo expects no
// response body.
//
// This is INBOUND only — it never calls TEvo (RULE 2). Registering the URL is
// a TEvo-support ticket the operator files, not an API call.
//
// Flow:
//   1. Method check — POST only.
//   2. Auth, both required:
//      a. `?token=` in the URL we register with TEvo, constant-time compared
//         against env TEVO_WEBHOOK_SECRET (TEvo sends no signature or bearer,
//         so the secret has to ride in the URL).
//      b. Source IP in TEvo's published allowlist (18.235.211.7,
//         35.170.152.168 — sandbox and prod). Override with env
//         TEVO_WEBHOOK_ALLOWED_IPS (comma-separated; "*" disables the check,
//         e.g. for a curl smoke test). Forwarding headers can be forged, so
//         the token is the real gate; the IP check is defence in depth and
//         accepts a match in any forwarding header to avoid rejecting real
//         TEvo traffic behind an extra proxy hop.
//   3. Parse the form; classify event_type → entity_kind + entity_id.
//   4. INSERT into tevo_webhook_notifications; a unique violation on
//      body_sha256 is a retry → 200 without a second row.
//   5. 200. DB failures return 500 so they show up rather than vanish.
//
// Deploy with --no-verify-jwt: TEvo sends no Supabase JWT.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const DEFAULT_ALLOWED_IPS = ["18.235.211.7", "35.170.152.168"];

const ENTITY_ID_FIELD: Record<string, string> = {
  event: "event_id",
  performer: "performer_id",
  venue: "venue_id",
};

// Fields stored in dedicated columns; everything else goes to extra_fields.
const KNOWN_FIELDS = new Set(["recipient", "event_type", "body", "event_id", "performer_id", "venue_id"]);

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  // 2a. URL token
  const expected = Deno.env.get("TEVO_WEBHOOK_SECRET");
  if (!expected) {
    return new Response("server misconfigured: TEVO_WEBHOOK_SECRET unset", { status: 500 });
  }
  const provided = new URL(req.url).searchParams.get("token") ?? "";
  if (!constantTimeEqual(provided, expected)) {
    return new Response("unauthorized", { status: 401 });
  }

  // 2b. Source IP allowlist
  const candidates = candidateIps(req);
  if (!ipAllowed(candidates)) {
    console.warn(`tevo-catalog-webhook: rejected source ip(s) ${candidates.join(",") || "<none>"}`);
    return new Response("forbidden", { status: 403 });
  }

  // 3. Parse
  const raw = await req.text();
  const form = new URLSearchParams(raw);
  const eventType = (form.get("event_type") ?? "").trim();
  if (!eventType) {
    return new Response("missing event_type", { status: 400 });
  }
  const kind = entityKind(eventType);
  const entityId = kind in ENTITY_ID_FIELD
    ? parseId(form.get(ENTITY_ID_FIELD[kind]))
    : null;

  const bodyStr = form.get("body");
  let body: unknown = null;
  let bodyRaw: string | null = null;
  if (bodyStr != null) {
    try {
      body = JSON.parse(bodyStr);
    } catch (_) {
      bodyRaw = bodyStr;
    }
  }

  const extra: Record<string, string> = {};
  for (const [k, v] of form.entries()) {
    if (!KNOWN_FIELDS.has(k)) extra[k] = v;
  }

  // 4. Record
  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { error } = await sb.from("tevo_webhook_notifications").insert({
    body_sha256: await sha256Hex(raw),
    event_type: eventType,
    entity_kind: kind,
    // Fall back to body.id when the top-level id field is missing.
    entity_id: entityId ?? (kind in ENTITY_ID_FIELD ? parseId((body as { id?: unknown } | null)?.id) : null),
    recipient: form.get("recipient"),
    body,
    body_raw: bodyRaw,
    extra_fields: extra,
    source_ip: candidates[0] ?? null,
  });

  if (error) {
    if (error.code === "23505") {
      return jsonResponse({ received: true, deduped: true });
    }
    console.error(`tevo-catalog-webhook: insert failed for ${eventType}`, error);
    return new Response("internal error recording notification", { status: 500 });
  }

  return jsonResponse({ received: true });
});

function entityKind(eventType: string): "event" | "performer" | "venue" | "order" | "other" {
  const m = /^(event|performer|venue)_(created|updated|deleted)$/.exec(eventType);
  if (m) return m[1] as "event" | "performer" | "venue";
  if (eventType.startsWith("order")) return "order";
  return "other";
}

function parseId(v: unknown): number | null {
  if (v == null) return null;
  const s = String(v).trim();
  return /^\d+$/.test(s) ? Number(s) : null;
}

function candidateIps(req: Request): string[] {
  const out: string[] = [];
  for (const h of ["x-real-ip", "cf-connecting-ip", "x-forwarded-for"]) {
    for (const part of (req.headers.get(h) ?? "").split(",")) {
      const ip = part.trim();
      if (ip && !out.includes(ip)) out.push(ip);
    }
  }
  return out;
}

function ipAllowed(candidates: string[]): boolean {
  const override = Deno.env.get("TEVO_WEBHOOK_ALLOWED_IPS");
  const allowed = override
    ? override.split(",").map((s) => s.trim()).filter(Boolean)
    : DEFAULT_ALLOWED_IPS;
  if (allowed.includes("*")) return true;
  return candidates.some((ip) => allowed.includes(ip));
}

async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function constantTimeEqual(a: string, b: string): boolean {
  // Mirror of _shared/bearer-auth.ts.
  let mismatch = a.length ^ b.length;
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) {
    mismatch |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }
  return mismatch === 0;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
