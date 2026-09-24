// Where a sale came from: the promoter's campaign code and the ad/UTM tags
// on the link the buyer landed on. One sanitizer shared by exos-checkout
// (which stores it on the checkout session) and the EXP SPA (which reads it
// off the URL and builds share / checkout links with it), so both agree on
// what's kept. No imports, so Deno and vitest can both load it.
//
// Promoter codes are what the Promote page writes into ?promoter= (a slug);
// UTM values and Meta's fbclid / cart_origin are free text from ads, so they
// are length-capped and stripped to a safe character set before they reach
// dashboards and CSV exports.

export interface Attribution {
  promoter?: string;
  utm_source?: string;
  utm_medium?: string;
  utm_campaign?: string;
  utm_content?: string;
  fbclid?: string;
  cart_origin?: "facebook" | "instagram" | "meta_shops";
}

const PROMOTER_RE = /^[A-Za-z0-9_-]{1,64}$/;
const CART_ORIGINS = new Set(["facebook", "instagram", "meta_shops"]);
const TAG_KEYS = ["utm_source", "utm_medium", "utm_campaign", "utm_content"] as const;

export function sanitizePromoter(v: unknown): string | undefined {
  return typeof v === "string" && PROMOTER_RE.test(v) ? v : undefined;
}

// UTM-style tag: printable, no markup/quote characters, at most 100 chars.
export function sanitizeTag(v: unknown): string | undefined {
  if (typeof v !== "string") return undefined;
  const t = v.trim().replace(/[^A-Za-z0-9 _.+\-/:@]/g, "").slice(0, 100);
  return t ? t : undefined;
}

function sanitizeFbclid(v: unknown): string | undefined {
  return typeof v === "string" && /^[A-Za-z0-9_-]{1,255}$/.test(v) ? v : undefined;
}

// Build a clean Attribution from any key/value source (URLSearchParams,
// a JSON body). Unknown keys are dropped; bad values are dropped, not fixed.
export function readAttribution(get: (key: string) => unknown): Attribution {
  const out: Attribution = {};
  const promoter = sanitizePromoter(get("promoter"));
  if (promoter) out.promoter = promoter;
  for (const k of TAG_KEYS) {
    const v = sanitizeTag(get(k));
    if (v) out[k] = v;
  }
  const fbclid = sanitizeFbclid(get("fbclid"));
  if (fbclid) out.fbclid = fbclid;
  const origin = get("cart_origin");
  if (typeof origin === "string" && CART_ORIGINS.has(origin)) out.cart_origin = origin as Attribution["cart_origin"];
  return out;
}

export function isEmptyAttribution(a: Attribution): boolean {
  return Object.keys(a).length === 0;
}
