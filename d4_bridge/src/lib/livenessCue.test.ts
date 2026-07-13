import { describe, it, expect } from 'vitest';
import { livenessCue } from './livenessCue';

describe('livenessCue', () => {
  it('is deterministic for the same seed', () => {
    const a = livenessCue('T2-hABCDEF');
    const b = livenessCue('T2-hABCDEF');
    expect(a).toEqual(b);
  });

  it('changes as the barcode rotates (different seeds usually differ)', () => {
    const seeds = Array.from({ length: 20 }, (_, i) => `T2-h-bucket-${i}`);
    const labels = new Set(seeds.map((s) => livenessCue(s).label));
    // Not a guarantee of uniqueness, but 20 seeds should yield several distinct
    // cues — a frozen (screenshot) cue would collapse to one.
    expect(labels.size).toBeGreaterThan(3);
  });

  it('produces a valid palette color + single digit', () => {
    const c = livenessCue('anything');
    expect(c.hex).toMatch(/^#[0-9A-F]{6}$/i);
    expect(c.digit).toBeGreaterThanOrEqual(0);
    expect(c.digit).toBeLessThanOrEqual(9);
    expect(c.label).toBe(`${c.name} ${c.digit}`);
  });

  it('handles empty/missing seed without throwing', () => {
    expect(() => livenessCue('')).not.toThrow();
    expect(() => livenessCue(null)).not.toThrow();
    expect(() => livenessCue(undefined)).not.toThrow();
  });
});
