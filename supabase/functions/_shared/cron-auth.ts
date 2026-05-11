// Shared cron-secret auth for Supabase edge functions.
//
// Hardened 2026-05-11 (security chat). Use this everywhere instead of the
// old `if (expected && header !== expected)` pattern, which fails open when
// CRON_SECRET env is unset.
//
// Usage:
//   import { requireCronSecret } from "../_shared/cron-auth.ts";
//   Deno.serve(async (req) => {
//     const authErr = requireCronSecret(req);
//     if (authErr) return authErr;
//     // ... rest of handler
//   });

export function requireCronSecret(req: Request): Response | null {
  const expected = Deno.env.get("CRON_SECRET");
  if (!expected) {
    return new Response(
      "server misconfigured: CRON_SECRET unset",
      { status: 500 },
    );
  }
  const provided = req.headers.get("x-cron-secret") ?? "";
  if (!constantTimeEqual(provided, expected)) {
    return new Response("unauthorized", { status: 401 });
  }
  return null;
}

function constantTimeEqual(a: string, b: string): boolean {
  // Length mismatch leaks 1 bit (provided length != expected length), which
  // is acceptable for a fixed-length shared secret. The byte-by-byte loop
  // is constant-time across the longest-of-two so per-character timing
  // cannot reveal where the mismatch is.
  let mismatch = a.length ^ b.length;
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) {
    mismatch |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }
  return mismatch === 0;
}
