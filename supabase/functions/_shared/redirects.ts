// Where exos-checkout and exos-connect-onboard may send a browser back to.
// The URLs come from the client, so without a check anyone could mint a
// Stripe-hosted page that bounces the buyer to a lookalike site.
//
// Allowed: an exact origin from EXOS_REDIRECT_ORIGINS (comma-separated, e.g.
// "https://vibepass-storefront-test.onrender.com,https://exos.example"), over
// https (http only for localhost), with no embedded credentials. No imports,
// so Deno and EXP's vitest can both load it.

export function parseRedirectOrigins(raw: string | undefined | null): string[] {
  return (raw ?? "")
    .split(",")
    .map((s) => s.trim().replace(/\/+$/, ""))
    .filter((s) => s.length > 0);
}

export function isAllowedRedirect(url: unknown, allowedOrigins: string[]): boolean {
  if (typeof url !== "string" || url.length > 2048) return false;
  let u: URL;
  try { u = new URL(url); } catch { return false; }
  if (u.username || u.password) return false;
  const local = u.hostname === "localhost" || u.hostname === "127.0.0.1";
  if (u.protocol !== "https:" && !(u.protocol === "http:" && local)) return false;
  return allowedOrigins.includes(u.origin);
}
