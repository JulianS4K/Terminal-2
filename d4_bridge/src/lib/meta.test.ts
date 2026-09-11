import { describe, it, expect } from 'vitest';
import { buildEventJsonLd } from './meta';

describe('buildEventJsonLd', () => {
  it('emits geo, map link, performers, status and canonical url', () => {
    const ld = buildEventJsonLd({
      name: 'Friday Night',
      startDate: '2026-10-30T20:00:00-04:00',
      location: { name: 'Brooklyn Steel', city: 'Brooklyn', region: 'NY', country: 'US' },
      geo: { lat: 40.7128, lng: -74.006 },
      placeId: 'ChIJabc',
      performers: ['Band A', 'Band B'],
      status: 'cancelled',
      url: 'https://x/bridge/event/1',
      offers: { price: 0, currency: 'USD', availability: 'InStock', url: 'https://x/bridge/event/1', validFrom: '2026-09-01T00:00:00Z' },
    }) as any;
    expect(ld.eventStatus).toBe('https://schema.org/EventCancelled');
    expect(ld.location.geo).toEqual({ '@type': 'GeoCoordinates', latitude: 40.7128, longitude: -74.006 });
    expect(ld.location.hasMap).toContain('query_place_id=ChIJabc');
    expect(ld.location.identifier).toBe('ChIJabc');
    expect(ld.performer).toHaveLength(2);
    expect(ld.url).toBe('https://x/bridge/event/1');
    expect(ld.offers.validFrom).toBe('2026-09-01T00:00:00Z');
    expect(ld.offers.price).toBe('0.00');
  });

  it('falls back to a place-id map link without geo and to EventScheduled', () => {
    const ld = buildEventJsonLd({ name: 'x', startDate: '2026-01-01', location: { name: 'v' }, placeId: 'ChIJ1' }) as any;
    expect(ld.location.hasMap).toBe('https://www.google.com/maps/place/?q=place_id:ChIJ1');
    expect(ld.location.geo).toBeUndefined();
    expect(ld.eventStatus).toBe('https://schema.org/EventScheduled');
    expect(ld.performer).toBeUndefined();
  });
});
