// Shared Bearer-token auth for inbound webhooks (sibling to cron-auth.ts).
//
// SG SellerDirect sends `Authorization: Bearer <token>` per the spec
// (see supabase/functions/sg-seller-webhook/index.ts for the full link).
// This module pulls the expected token from env (set per-function), does
// a constant-time compare, and returns either a Response (to be returned
// directly to the caller) or null on success.
//
// Usage:
//   import { requireBearer } from "../_shared/bearer-auth.ts";
//   Deno.serve(async (req) => {
//     const authErr = requireBearer(req, "SG_SELLER_WEBHOOK_SECRET");
//     if (authErr) return authErr;
//     // ... handler
//   });

export function requireBearer(req: Request, envVarName: string): Response | null {
  const expected = Deno.env.get(envVarName);
  if (!expected) {
    return new Response(
      `server misconfigured: ${envVarName} unset`,
      { status: 500 },
    );
  }
  const header = req.headers.get("Authorization") ?? "";
  // Expected shape: "Bearer <token>". Reject malformed headers early.
  if (!header.startsWith("Bearer ")) {
    return new Response("unauthorized", { status: 401 });
  }
  const provided = header.slice("Bearer ".length);
  if (!constantTimeEqual(provided, expected)) {
    return new Response("unauthorized", { status: 401 });
  }
  return null;
}

function constantTimeEqual(a: string, b: string): boolean {
  // Mirror of cron-auth.ts. Length mismatch leaks 1 bit; the byte-by-byte
  // loop is constant-time across the longest-of-two so per-character
  // timing cannot reveal where the mismatch is.
  let mismatch = a.length ^ b.length;
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) {
    mismatch |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }
  return mismatch === 0;
}
