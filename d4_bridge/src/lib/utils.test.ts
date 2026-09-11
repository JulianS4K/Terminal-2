import { describe, it, expect } from 'vitest';
import { formatCurrency, publicUrl } from './utils';

describe('formatCurrency', () => {
  it('formats known currencies with the en-US symbol', () => {
    expect(formatCurrency(25, 'USD')).toBe('$25.00');
    expect(formatCurrency(0, 'usd')).toBe('$0.00');
    expect(formatCurrency(1234.5, 'EUR')).toBe('€1,234.50');
    expect(formatCurrency(10)).toBe('$10.00');
  });

  it('falls back to a plain suffix on an unknown code instead of throwing', () => {
    expect(formatCurrency(12.345, 'NOPE')).toBe('12.35 NOPE');
  });
});

describe('publicUrl', () => {
  it('normalizes the leading slash and never produces a double slash', () => {
    const a = publicUrl('event/123');
    const b = publicUrl('/event/123');
    expect(a).toBe(b);
    expect(a.endsWith('/event/123')).toBe(true);
    expect(a).not.toMatch(/(^|[^:])\/\//);
  });
});
