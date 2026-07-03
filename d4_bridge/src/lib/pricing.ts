// Scheduled tier pricing (seller-side dynamic pricing, v1 — time-based).
//
// A tier's `price` is the opening/default price. `priceSchedule` is an ordered
// list of {startsAt, price} steps — "on/after this time, the price becomes this".
// The EFFECTIVE price right now is the price of the latest step whose startsAt is
// in the past, or the base price if none apply. Computed at read time (no cron),
// so the storefront shows the live price and an "increases on <date>" nudge.
//
// This models early-bird → regular → last-minute and steady price ramps. It is
// our OWN primary-market inventory — unrelated to the RULE-2 upstream reprice
// lockdown (see mig 20260703122000).

export interface PriceStep {
  /** ISO timestamp — the step takes effect on/after this moment. */
  startsAt: string;
  /** The price from this step onward (until a later step supersedes it). */
  price: number;
}

/** Keep only well-formed steps, normalized + sorted ascending by time. */
export function normalizeSchedule(schedule: unknown): PriceStep[] {
  if (!Array.isArray(schedule)) return [];
  return schedule
    .filter(
      (s): s is PriceStep =>
        !!s &&
        typeof (s as any).price === 'number' &&
        (s as any).price >= 0 &&
        typeof (s as any).startsAt === 'string' &&
        !Number.isNaN(Date.parse((s as any).startsAt)),
    )
    .map((s) => ({ startsAt: new Date(s.startsAt).toISOString(), price: s.price }))
    .sort((a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt));
}

/**
 * The tier's price at `now` — base price overridden by the latest already-active
 * schedule step. Falls back to the base price when the schedule is empty/invalid
 * or entirely in the future.
 */
export function effectiveTierPrice(
  basePrice: number,
  schedule?: unknown,
  now: Date = new Date(),
): number {
  const steps = normalizeSchedule(schedule);
  let price = basePrice;
  const t = now.getTime();
  for (const s of steps) {
    if (Date.parse(s.startsAt) <= t) price = s.price;
    else break;
  }
  return price;
}

/**
 * The next scheduled step in the future (for "price changes to $X on <date>"),
 * or null when nothing upcoming. The caller compares its price to the current
 * effective price to decide whether it's a rise or a drop.
 */
export function nextPriceStep(schedule?: unknown, now: Date = new Date()): PriceStep | null {
  const steps = normalizeSchedule(schedule);
  const t = now.getTime();
  for (const s of steps) {
    if (Date.parse(s.startsAt) > t) return s;
  }
  return null;
}
