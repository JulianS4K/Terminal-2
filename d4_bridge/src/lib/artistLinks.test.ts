import { describe, it, expect } from 'vitest';
import {
  artistLinkHref,
  normalizeArtistLinks,
  linksForArtist,
  hasAnyLink,
} from './artistLinks';

describe('artistLinkHref', () => {
  it('expands bare handles per platform', () => {
    expect(artistLinkHref('instagram', '@boysnoize')).toBe('https://instagram.com/boysnoize');
    expect(artistLinkHref('x', 'boysnoize')).toBe('https://x.com/boysnoize');
    expect(artistLinkHref('tiktok', 'foo')).toBe('https://tiktok.com/@foo');
    expect(artistLinkHref('youtube', 'foo')).toBe('https://youtube.com/@foo');
    expect(artistLinkHref('website', 'example.com')).toBe('https://example.com');
  });

  it('passes full URLs through untouched', () => {
    expect(artistLinkHref('x', 'https://x.com/foo')).toBe('https://x.com/foo');
    expect(artistLinkHref('spotify', 'http://open.spotify.com/artist/1')).toBe('http://open.spotify.com/artist/1');
  });

  it('falls back to platform search for handle-less platforms', () => {
    expect(artistLinkHref('spotify', 'Skrillex')).toBe('https://open.spotify.com/search/Skrillex');
    expect(artistLinkHref('bandsintown', 'Boys Noize')).toBe('https://www.bandsintown.com/?query=Boys%20Noize');
    expect(artistLinkHref('appleMusic', 'Skrillex')).toBe('https://music.apple.com/us/search?term=Skrillex');
  });

  it('returns empty string for empty input', () => {
    expect(artistLinkHref('tiktok', '   ')).toBe('');
  });
});

describe('normalizeArtistLinks', () => {
  it('trims values, drops rows with no name or no links, omits when nothing survives', () => {
    expect(
      normalizeArtistLinks([
        { name: '  Skrillex  ', spotify: ' https://x ' },
        { name: 'Nobody' },
        { name: '', instagram: 'x' },
      ]),
    ).toEqual([{ name: 'Skrillex', spotify: 'https://x' }]);
    expect(normalizeArtistLinks([{ name: 'A' }])).toBeUndefined();
  });
});

describe('linksForArtist', () => {
  const links = [{ name: 'Boys Noize', instagram: 'boysnoize' }];
  it('matches case- and trim-insensitively', () => {
    expect(linksForArtist('  boys NOIZE ', links)?.instagram).toBe('boysnoize');
  });
  it('returns undefined on no match or empty list', () => {
    expect(linksForArtist('Missing', links)).toBeUndefined();
    expect(linksForArtist('Boys Noize', undefined)).toBeUndefined();
  });
});

describe('hasAnyLink', () => {
  it('is false with only a name, true with any link', () => {
    expect(hasAnyLink({ name: 'x' })).toBe(false);
    expect(hasAnyLink({ name: 'x', youtube: 'y' })).toBe(true);
  });
});
