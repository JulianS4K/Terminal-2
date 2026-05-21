// Single source of truth for event categories and their associated genre
// chips. CreateEvent and EditEvent used to maintain duplicate copies of
// these arrays inline; if you wanted to add a category you had to update
// two files and pray you didn't typo. Now there's one list.

export const EVENT_CATEGORIES = [
  'Music',
  'Nightlife',
  'Sports',
  'Tech',
  'Arts',
  'Food',
] as const;

export type EventCategory = (typeof EVENT_CATEGORIES)[number];

export const CATEGORY_GENRES: Record<EventCategory, string[]> = {
  Music: [
    'Electronic',
    'Hip Hop',
    'Rock',
    'Pop',
    'Jazz',
    'Classical',
    'R&B',
    'Country',
    'Latin',
    'Metal',
  ],
  Nightlife: [
    'Club',
    'Bar',
    'Lounge',
    'Festival',
    'Underground',
    'House Party',
  ],
  Sports: [
    'Basketball',
    'Soccer',
    'Football',
    'Tennis',
    'Baseball',
    'Combat Sports',
    'Esports',
  ],
  Tech: ['Conference', 'Workshop', 'Meetup', 'Hackathon', 'AI', 'Web3'],
  Arts: [
    'Gallery',
    'Theatre',
    'Dance',
    'Performance Art',
    'Photography',
    'Fashion',
  ],
  Food: ['Festival', 'Pop-up', 'Tasting', 'Workshop', 'Dining Experience'],
};

/** Helper to enumerate genres for a (possibly user-typed) category. */
export function genresFor(category: string): string[] {
  return (CATEGORY_GENRES as Record<string, string[]>)[category] || [];
}

// Coarse map: Exos category → TEvo `public.events.event_type` bucket, so an
// Exos primary event is consistent with the D0 catalog taxonomy. Only the
// categories with an unambiguous TEvo coarse bucket (game / concert / show)
// are mapped; Nightlife / Tech / Food stay undefined → event_type NULL, which
// matches the plurality of real TEvo rows (~60% are NULL). The fine-grained
// TEvo subtypes (rock-pop, broadway-*, ncaa, …) are reached via the matched
// canonical row through bridge_event_xref, not set from here.
export const CATEGORY_EVENT_TYPE: Partial<Record<EventCategory, string>> = {
  Sports: 'game',
  Music: 'concert',
  Arts: 'show',
};

/** Map a (possibly user-typed) category to the coarse TEvo event_type, or
 *  undefined when there's no clean bucket (caller should leave it NULL). */
export function eventTypeForCategory(category: string): string | undefined {
  return (CATEGORY_EVENT_TYPE as Record<string, string | undefined>)[category];
}
