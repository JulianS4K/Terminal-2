// Server-side scheduled tier price, used by exos-checkout to charge what the
// storefront shows. Mirrors EXP src/lib/pricing.ts effectiveTierPrice exactly;
// EXP's src/lib/pricingParity.test.ts compares the two. No imports, so both
// Deno and vitest can load it.
//
// Base price, overridden by the latest schedule step whose startsAt has passed
// (inclusive); malformed steps are ignored.
export function effectiveTierPrice(basePrice: number, schedule: unknown, now: Date = new Date()): number {
  if (!Array.isArray(schedule)) return basePrice;
  const steps = (schedule as Array<{ price?: unknown; startsAt?: unknown } | null>)
    .filter((st): st is { price: number; startsAt: string } =>
      !!st && typeof st.price === "number" && st.price >= 0 &&
      typeof st.startsAt === "string" && !Number.isNaN(Date.parse(st.startsAt)))
    .map((st) => ({ at: Date.parse(st.startsAt), price: st.price }))
    .sort((a, b) => a.at - b.at);
  let price = basePrice;
  for (const st of steps) {
    if (st.at <= now.getTime()) price = st.price;
    else break;
  }
  return price;
}
