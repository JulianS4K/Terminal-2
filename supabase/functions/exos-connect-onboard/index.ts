// exos-connect-onboard — create/refresh an org's Stripe Connect account +
// onboarding link (D4-OPS-7 SCAFFOLD). Org OWNER only.
//
// Returns a Stripe hosted onboarding URL. On return, Stripe fires
// account.updated -> stripe-webhook -> exos_record_org_stripe(), which flips
// chargesEnabled/payoutsEnabled once onboarding completes.
//
// Required secrets: STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_ANON_KEY,
// SUPABASE_SERVICE_ROLE_KEY.
//
// TODO(operator): Connect account type ('standard' here) + country/capabilities.

import Stripe from "https://esm.sh/stripe@16?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);

  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
  if (!stripeKey) return json({ error: "server misconfigured: STRIPE_SECRET_KEY unset" }, 500);

  const authHeader = req.headers.get("Authorization") ?? "";
  const sbUser = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user } } = await sbUser.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  let p: { org_id?: string; return_url?: string; refresh_url?: string };
  try { p = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }
  const { org_id, return_url, refresh_url } = p;
  if (!org_id || !return_url || !refresh_url) {
    return json({ error: "missing org_id / return_url / refresh_url" }, 400);
  }

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // Owner-only.
  const { data: mem } = await sb.from("exos_org_memberships")
    .select("role, disabled").eq("org_id", org_id).eq("user_id", user.id).maybeSingle();
  if (!mem || mem.disabled || mem.role !== "owner") return json({ error: "forbidden: org owner only" }, 403);

  const stripe = new Stripe(stripeKey, { httpClient: Stripe.createFetchHttpClient(), apiVersion: "2024-06-20" });

  // Reuse an existing connected account if present.
  const { data: secrets } = await sb.from("exos_org_secrets").select("payments").eq("org_id", org_id).maybeSingle();
  let acctId = (secrets?.payments as { connectedAccountId?: string } | null)?.connectedAccountId;

  try {
    if (!acctId) {
      const acct = await stripe.accounts.create({ type: "standard", metadata: { exos_org_id: org_id } });
      acctId = acct.id;
      await sb.rpc("exos_record_org_stripe", {
        p_org_id: org_id, p_account_id: acctId,
        p_charges_enabled: false, p_payouts_enabled: false,
      });
    }
    const link = await stripe.accountLinks.create({
      account: acctId,
      refresh_url,
      return_url,
      type: "account_onboarding",
    });
    return json({ url: link.url, account_id: acctId });
  } catch (e) {
    console.error("exos-connect-onboard: stripe error", e);
    return json({ error: "could not start onboarding" }, 502);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
