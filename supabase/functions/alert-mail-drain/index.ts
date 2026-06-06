// alert-mail-drain — outbound mail drainer for the D0 terminal's alert emails.
//
// A sibling of exos-mail-drain: SAME Resend backend + claim/mark/drain pattern,
// but reads the terminal's OWN public.alert_mail queue (mig 20260604125000) so
// alerts stay separate from D4/Exos transactional mail (Exos is a separate
// project). Cron-driven; enqueued by alert_dispatch_* (mig 20260604130000).
//
// Auth: cron-secret gated (Hard Rule #7 — burns a paid email API + mutates
// data, so platform verify_jwt alone is NOT sufficient).
//
// Concurrency: alert_mail_claim_batch() does FOR UPDATE SKIP LOCKED + flips
// pending→sending, so overlapping invocations grab disjoint rows. Outcome via
// alert_mail_mark() (sent / failed-at-cap / pending-retry).
//
// Required edge-function secrets (operator-set at deploy; NOT in repo):
//   CRON_SECRET                 — shared cron secret (repo-wide)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY  — injected by the platform
//   RESEND_API_KEY              — email provider key (same Resend account is fine)
//   ALERT_MAIL_FROM             — verified sender, e.g. "S4K Terminal <alerts@yourdomain>"
//
// Cron (operator / A1 — cron.* is operator-gated):
//   select cron.schedule('alert-mail-drain-2min', '*/2 * * * *', $cron$
//     do $b$ begin
//       if not public.cron_should_fire('alert-mail-drain-2min') then return; end if;
//       perform public._cron_invoke_edge_fn(
//         'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/alert-mail-drain',
//         '{}'::jsonb);
//     end $b$; $cron$);

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { requireCronSecret } from "../_shared/cron-auth.ts";

const RESEND_ENDPOINT = "https://api.resend.com/emails";

interface MailRow {
  id: string;
  to_email: string;
  subject: string;
  html: string;
  attempts: number;
}

Deno.serve(async (req: Request): Promise<Response> => {
  const authErr = requireCronSecret(req);
  if (authErr) return authErr;

  const resendKey = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("ALERT_MAIL_FROM");
  if (!resendKey || !from) {
    return json({ error: "server misconfigured: RESEND_API_KEY / ALERT_MAIL_FROM unset" }, 500);
  }

  let limit = 20;
  let maxAttempts = 5;
  try {
    const b = await req.json();
    if (Number.isInteger(b?.limit)) limit = Math.min(Math.max(b.limit, 1), 100);
    if (Number.isInteger(b?.max_attempts)) maxAttempts = Math.min(Math.max(b.max_attempts, 1), 10);
  } catch (_) {
    /* no/!json body — use defaults */
  }

  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: batch, error: claimErr } = await sb.rpc("alert_mail_claim_batch", {
    p_limit: limit,
    p_max_attempts: maxAttempts,
  });
  if (claimErr) {
    console.error("alert-mail-drain: claim failed", claimErr);
    return json({ error: "claim failed", detail: claimErr.message }, 500);
  }

  const rows = (batch ?? []) as MailRow[];
  let sent = 0;
  let failed = 0;

  for (const row of rows) {
    try {
      const res = await fetch(RESEND_ENDPOINT, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${resendKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          from,
          to: [row.to_email],
          subject: row.subject,
          html: row.html,
        }),
      });
      if (res.ok) {
        await sb.rpc("alert_mail_mark", { p_id: row.id, p_ok: true });
        sent++;
      } else {
        const text = await res.text().catch(() => "");
        await sb.rpc("alert_mail_mark", {
          p_id: row.id,
          p_ok: false,
          p_error: `resend ${res.status}: ${text.slice(0, 500)}`,
          p_max_attempts: maxAttempts,
        });
        failed++;
      }
    } catch (e) {
      await sb.rpc("alert_mail_mark", {
        p_id: row.id,
        p_ok: false,
        p_error: `send threw: ${String(e).slice(0, 500)}`,
        p_max_attempts: maxAttempts,
      });
      failed++;
    }
  }

  return json({ claimed: rows.length, sent, failed });
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
