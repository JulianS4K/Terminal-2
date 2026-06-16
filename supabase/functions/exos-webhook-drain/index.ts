// exos-webhook-drain — deliver queued Exos webhooks (Hi.Events parity).
//
// Cron-invoked (requireCronSecret). Claims due rows from exos_webhook_deliveries
// and POSTs each to its webhook URL, signed with the per-hook secret:
//   X-Exos-Signature: sha256=<hex HMAC-SHA256(secret, rawBody)>
// Receivers verify the signature to trust the payload. Failures retry with
// exponential backoff; after MAX_ATTEMPTS the row is marked 'dead'.
//
// SSRF guard: https-only, and we resolve the host's A records and refuse any
// that land in a private / loopback / link-local / metadata range — so an org
// can't point a webhook at internal infrastructure.
//
// Required secrets: CRON_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";

const MAX_ATTEMPTS = 8;
const BATCH = 50;
const TIMEOUT_MS = 8000;

Deno.serve(async (req: Request): Promise<Response> => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data: due, error } = await sb
    .from("exos_webhook_deliveries")
    .select("id, webhook_id, event_type, payload, attempts, exos_webhooks!inner(url, secret, enabled)")
    .eq("status", "pending")
    .lte("next_attempt_at", new Date().toISOString())
    .order("next_attempt_at", { ascending: true })
    .limit(BATCH);
  if (error) {
    console.error("exos-webhook-drain: query failed", error);
    return json({ error: "query failed" }, 500);
  }

  let delivered = 0, failed = 0, dead = 0, skipped = 0;

  for (const row of due ?? []) {
    const hook = (row as unknown as { exos_webhooks: { url: string; secret: string; enabled: boolean } }).exos_webhooks;
    // Disabled mid-flight → drop quietly.
    if (!hook?.enabled) {
      await sb.from("exos_webhook_deliveries").update({ status: "dead", last_error: "webhook disabled" }).eq("id", row.id);
      skipped++;
      continue;
    }

    const ssrf = await urlIsBlocked(hook.url);
    if (ssrf) {
      await sb.from("exos_webhook_deliveries")
        .update({ status: "dead", last_error: `blocked url: ${ssrf}` }).eq("id", row.id);
      dead++;
      continue;
    }

    const body = JSON.stringify(row.payload);
    const sig = await hmacHex(hook.secret, body);
    let ok = false, code: number | null = null, errText: string | null = null;
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
    try {
      const res = await fetch(hook.url, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "user-agent": "Exos-Webhooks/1.0",
          "x-exos-event": String(row.event_type),
          "x-exos-delivery": String(row.id),
          "x-exos-timestamp": new Date().toISOString(),
          "x-exos-signature": `sha256=${sig}`,
        },
        body,
        signal: ctrl.signal,
        redirect: "manual", // a 3xx to an internal host would defeat the SSRF check
      });
      code = res.status;
      ok = res.status >= 200 && res.status < 300;
      if (!ok) errText = `http ${res.status}`;
    } catch (e) {
      errText = e instanceof Error ? e.message : "fetch failed";
    } finally {
      clearTimeout(timer);
    }

    const attempts = (row.attempts ?? 0) + 1;
    if (ok) {
      await sb.from("exos_webhook_deliveries").update({
        status: "delivered", attempts, last_status_code: code,
        last_error: null, delivered_at: new Date().toISOString(),
      }).eq("id", row.id);
      delivered++;
    } else if (attempts >= MAX_ATTEMPTS) {
      await sb.from("exos_webhook_deliveries").update({
        status: "dead", attempts, last_status_code: code, last_error: errText,
      }).eq("id", row.id);
      dead++;
    } else {
      // Exponential backoff: ~2^attempts minutes, capped at 6h.
      const backoffMs = Math.min(2 ** attempts * 60_000, 6 * 3600_000);
      await sb.from("exos_webhook_deliveries").update({
        status: "pending", attempts, last_status_code: code, last_error: errText,
        next_attempt_at: new Date(Date.now() + backoffMs).toISOString(),
      }).eq("id", row.id);
      failed++;
    }
  }

  return json({ processed: (due ?? []).length, delivered, failed, dead, skipped });
});

// Resolve the host and block private / loopback / link-local / metadata targets.
// Returns a reason string if blocked, else null.
//
// Residual risk (B1, flagged in mig 20260616200000): this resolves DNS, then
// fetch() resolves again — a DNS-rebinding host could flip to an internal IP
// between the two lookups. Fully closing it needs IP-pinned connect (impractical
// with Deno fetch + TLS SNI). Mitigating factors: webhook URLs are set only by
// authenticated org owner/manager (not anonymous attackers), redirects are
// disabled (manual), and literal private IPs + localhost/.local/.internal are
// blocked outright. Treat as a known low residual pending an allowlist/pinning pass.
async function urlIsBlocked(rawUrl: string): Promise<string | null> {
  let u: URL;
  try { u = new URL(rawUrl); } catch { return "invalid url"; }
  if (u.protocol !== "https:") return "non-https";
  const host = u.hostname;
  if (host === "localhost" || host.endsWith(".local") || host.endsWith(".internal")) return "internal host";

  // If the host is a literal IP, check it directly; else resolve A records.
  const literals = /^[0-9.]+$/.test(host) || host.includes(":") ? [host] : await resolveA(host);
  if (literals.length === 0) return "dns resolution failed";
  for (const ip of literals) {
    if (isPrivateIp(ip)) return `private ip ${ip}`;
  }
  return null;
}

async function resolveA(host: string): Promise<string[]> {
  try {
    return await Deno.resolveDns(host, "A");
  } catch {
    return [];
  }
}

function isPrivateIp(ip: string): boolean {
  // IPv6 loopback / unique-local / link-local.
  if (ip.includes(":")) {
    const l = ip.toLowerCase();
    return l === "::1" || l.startsWith("fc") || l.startsWith("fd") || l.startsWith("fe80") || l === "::";
  }
  const p = ip.split(".").map(Number);
  if (p.length !== 4 || p.some((n) => Number.isNaN(n) || n < 0 || n > 255)) return true; // malformed → block
  const [a, b] = p;
  return (
    a === 10 ||                              // 10/8
    a === 127 ||                             // loopback
    a === 0 ||                               // 0.0.0.0/8
    (a === 172 && b >= 16 && b <= 31) ||     // 172.16/12
    (a === 192 && b === 168) ||              // 192.168/16
    (a === 169 && b === 254) ||              // link-local + 169.254.169.254 metadata
    (a === 100 && b >= 64 && b <= 127)       // 100.64/10 CGNAT
  );
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
