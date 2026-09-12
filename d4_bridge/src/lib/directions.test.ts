import { describe, it, expect } from 'vitest';
import type { Event } from '../types';
import { venueAddress, directionsUrl, detectMapsPlatform } from './directions';

const full = {
  location: 'Brooklyn Steel',
  address: { street: '319 Frost St', city: 'Brooklyn', region: 'NY', postal: '11222' },
} as unknown as Event;

describe('venueAddress', () => {
  it('puts the venue name first, then the structured parts', () => {
    expect(venueAddress(full)).toBe('Brooklyn Steel, 319 Frost St, Brooklyn, NY, 11222');
  });

  it('skips blank and missing parts without leaving stray commas', () => {
    const sparse = { location: 'The Fillmore', address: { city: '  ', region: 'CA' } } as unknown as Event;
    expect(venueAddress(sparse)).toBe('The Fillmore, CA');
  });

  it('is empty when the event has no place at all', () => {
    expect(venueAddress({} as Event)).toBe('');
  });
});

describe('directionsUrl', () => {
  it('builds a Google Maps directions link by default', () => {
    expect(directionsUrl(full)).toBe(
      'https://www.google.com/maps/dir/?api=1&destination=Brooklyn%20Steel%2C%20319%20Frost%20St%2C%20Brooklyn%2C%20NY%2C%2011222',
    );
  });

  it('builds an Apple Maps link on Apple platforms', () => {
    expect(directionsUrl(full, 'apple')).toBe(
      'https://maps.apple.com/?daddr=Brooklyn%20Steel%2C%20319%20Frost%20St%2C%20Brooklyn%2C%20NY%2C%2011222',
    );
  });

  it('returns null rather than a dead link when there is no venue', () => {
    expect(directionsUrl({} as Event)).toBeNull();
    expect(directionsUrl({ location: '   ' } as Event)).toBeNull();
  });

  it('escapes characters that would break the query', () => {
    const odd = { location: 'Bar & Grill #2' } as unknown as Event;
    expect(directionsUrl(odd)).toContain('destination=Bar%20%26%20Grill%20%232');
  });
});

describe('detectMapsPlatform', () => {
  it('reads iPhone, iPad and macOS as Apple', () => {
    expect(detectMapsPlatform('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0)')).toBe('apple');
    expect(detectMapsPlatform('Mozilla/5.0 (iPad; CPU OS 17_0)')).toBe('apple');
    expect(detectMapsPlatform('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)')).toBe('apple');
  });

  it('reads Android and Windows as other', () => {
    expect(detectMapsPlatform('Mozilla/5.0 (Linux; Android 14; Pixel 8)')).toBe('other');
    expect(detectMapsPlatform('Mozilla/5.0 (Windows NT 10.0; Win64; x64)')).toBe('other');
  });

  it('defaults to other with no user agent', () => {
    expect(detectMapsPlatform('')).toBe('other');
  });
});
