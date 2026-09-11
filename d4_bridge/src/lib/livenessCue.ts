// Exos (Bridge / D4) — rotating "liveness cue" for the entry pass.
//
// A secondary, human-glanceable anti-screenshot signal that complements the
// rotating barcode: a colored chip + short code derived deterministically from
// the CURRENT signed barcode, so it changes every 30s in lockstep with the code.
// A screenshot freezes it; a live pass keeps cycling. Door staff (and the
// holder) can see at a glance that the pass is live, without decoding anything.
//
// Pure + deterministic (same barcode → same cue), so it's unit-testable and the
// same input always renders identically. Colors are all dark enough to carry
// white text.

export interface LivenessCue {
  name: string;
  hex: string;
  digit: number;
  /** e.g. "TEAL 7" */
  label: string;
}

const PALETTE: ReadonlyArray<{ name: string; hex: string }> = [
  { name: 'TEAL', hex: '#0D9488' },
  { name: 'INDIGO', hex: '#4F46E5' },
  { name: 'ROSE', hex: '#E11D48' },
  { name: 'AMBER', hex: '#B45309' },
  { name: 'VIOLET', hex: '#7C3AED' },
  { name: 'EMERALD', hex: '#059669' },
  { name: 'SKY', hex: '#0284C7' },
  { name: 'CRIMSON', hex: '#BE123C' },
];

/** FNV-1a 32-bit hash — cheap, stable, good enough spread for a UI cue. */
function fnv1a(s: string): number {
  let h = 2166136261 >>> 0;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}

/**
 * Derive the liveness cue for a given seed (pass the current barcode string).
 * Empty/missing seed falls back to a stable default so nothing throws.
 */
export function livenessCue(seed: string | null | undefined): LivenessCue {
  const h = fnv1a(seed || '');
  const c = PALETTE[h % PALETTE.length];
  const digit = Math.floor(h / PALETTE.length) % 10;
  return { name: c.name, hex: c.hex, digit, label: `${c.name} ${digit}` };
}
