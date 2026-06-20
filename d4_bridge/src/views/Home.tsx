import { useEffect, useMemo, useState } from 'react';
import { Event } from '../types';
import { listPublicEvents } from '../lib/events';
import { Link } from 'react-router-dom';
import { Calendar, MapPin, Search } from 'lucide-react';
import { motion } from 'motion/react';
import { formatInTz } from '../lib/datetime';
import { formatCurrency } from '../lib/utils';

// Coarse date buckets for the discovery filter. Mirrors the "what can I do
// this weekend" mental model a retail buyer brings — not a full date picker.
type DateBucket = 'all' | 'today' | 'weekend' | 'month';

const DATE_BUCKETS: { key: DateBucket; label: string }[] = [
  { key: 'all', label: 'Any Date' },
  { key: 'today', label: 'Today' },
  { key: 'weekend', label: 'This Weekend' },
  { key: 'month', label: 'This Month' },
];

// Returns true when `d` falls inside the requested bucket. "Weekend" is the
// upcoming Sat+Sun (or the current one if it's already the weekend); "month"
// is the remainder of the current calendar month. All comparisons are in the
// viewer's local time — good enough for a coarse browse filter.
function inDateBucket(d: Date, bucket: DateBucket): boolean {
  if (bucket === 'all') return true;
  const now = new Date();

  if (bucket === 'today') {
    return (
      d.getFullYear() === now.getFullYear() &&
      d.getMonth() === now.getMonth() &&
      d.getDate() === now.getDate()
    );
  }

  if (bucket === 'weekend') {
    // Day of week: 0 Sun … 6 Sat. Find the coming Saturday (or today if
    // it's already Sat/Sun), then the window is that Sat 00:00 → Mon 00:00.
    const day = now.getDay();
    const daysUntilSat = day === 0 ? 6 : 6 - day; // Sun → next Sat is 6 away
    const satStart = new Date(now);
    satStart.setHours(0, 0, 0, 0);
    // If today is already the weekend (Sat=6 or Sun=0), anchor on it.
    if (day === 0) satStart.setDate(now.getDate() - 1); // back to Saturday
    else satStart.setDate(now.getDate() + daysUntilSat);
    const monStart = new Date(satStart);
    monStart.setDate(satStart.getDate() + 2);
    return d >= satStart && d < monStart;
  }

  // 'month' — from now until the end of the current calendar month.
  const monthEnd = new Date(now.getFullYear(), now.getMonth() + 1, 1);
  return d >= now && d < monthEnd;
}

export default function Home() {
  const [events, setEvents] = useState<Event[]>([]);
  const [loading, setLoading] = useState(true);
  const [searchTerm, setSearchTerm] = useState('');
  const [activeCategory, setActiveCategory] = useState<string>('all');
  const [activeDate, setActiveDate] = useState<DateBucket>('all');

  // Categories present in the loaded catalog, in first-seen order. We derive
  // these from real data rather than the canonical taxonomy so we never show
  // a pill that filters to zero events.
  const categories = useMemo(() => {
    const seen = new Set<string>();
    const out: string[] = [];
    for (const ev of events) {
      const c = (ev.category || '').trim();
      if (c && !seen.has(c)) {
        seen.add(c);
        out.push(c);
      }
    }
    return out;
  }, [events]);

  // Client-side fuzzy filter — hits the in-memory event set so it
  // stays sub-millisecond even with a few hundred events. We filter
  // on title + location + category + genres, plus the category and date
  // facets. When the catalog crosses ~1000 events we'll wire an
  // Algolia-style index and push facets server-side.
  const filteredEvents = useMemo(() => {
    const term = searchTerm.trim().toLowerCase();
    return events.filter((ev) => {
      if (activeCategory !== 'all') {
        if ((ev.category || '').trim().toLowerCase() !== activeCategory.toLowerCase()) {
          return false;
        }
      }
      if (activeDate !== 'all') {
        const d = ev.date?.toDate?.();
        if (!d || !inDateBucket(d, activeDate)) return false;
      }
      if (term.length > 0) {
        const haystack = `${ev.title || ''} ${ev.location || ''} ${ev.category || ''} ${(ev.genres || []).join(' ')}`.toLowerCase();
        if (!haystack.includes(term)) return false;
      }
      return true;
    });
  }, [events, searchTerm, activeCategory, activeDate]);

  const filtersActive =
    searchTerm.trim().length > 0 || activeCategory !== 'all' || activeDate !== 'all';

  function clearFilters() {
    setSearchTerm('');
    setActiveCategory('all');
    setActiveDate('all');
  }

  useEffect(() => {
    async function fetchEvents() {
      try {
        // Reads exos_public_events (published-only, column-narrowed view).
        // NOTE: customUrlOnly (private/presale) events aren't excluded yet —
        // `exclusivity` isn't exposed on the public view. Pending follow-up
        // before storefront launch (add a customUrlOnly filter to the view).
        // Fetch a wider page now that browse filters run client-side, so the
        // category/date facets have enough to work with.
        const list = await listPublicEvents(48);
        setEvents(list);
      } catch (err) {
        console.error('Failed to load events', err);
      } finally {
        setLoading(false);
      }
    }
    fetchEvents();
  }, []);

  const pillBase =
    'px-4 py-2 text-[10px] font-black uppercase tracking-tighter border transition-all whitespace-nowrap';
  const pillOn = 'bg-brand-primary text-black border-brand-primary';
  const pillOff = 'bg-[#111111] text-white/60 border-white/10 hover:text-white hover:border-white/30';

  return (
    <div className="bg-[#000000] min-h-screen">
      <div className="max-w-7xl mx-auto px-4 py-8">
        {/* Hero Section */}
        <section className="mb-12 pt-10 pb-12 border-b border-white/10">
          <div className="max-w-4xl">
            <motion.h1
              initial={{ opacity: 0, x: -20 }}
              animate={{ opacity: 1, x: 0 }}
              className="text-6xl md:text-8xl font-black mb-8 tracking-tighter uppercase italic leading-[0.85]"
            >
              Access all<br />areas.
            </motion.h1>
            <p className="text-brand-primary text-xl font-black uppercase tracking-tighter mb-12 max-w-xl">
              Your pass to the world's best events. Guaranteed authentic entry, every time.
            </p>
            <div className="relative max-w-lg">
              <Search className="absolute left-6 top-1/2 -translate-y-1/2 text-white w-5 h-5 pointer-events-none" />
              <input
                type="search"
                value={searchTerm}
                onChange={(e) => setSearchTerm(e.target.value)}
                aria-label="Search events"
                placeholder="Search events..."
                className="w-full bg-[#111111] border border-white/20 rounded-none py-6 pl-16 pr-8 text-white placeholder-white/30 focus:outline-none focus:border-brand-primary transition-all font-black uppercase tracking-tighter text-lg"
              />
            </div>
          </div>
        </section>

        {/* Discovery filters — category + date facets over the loaded catalog */}
        <section className="mb-10 space-y-4">
          <div className="flex flex-wrap gap-2" role="group" aria-label="Filter by category">
            <button
              type="button"
              onClick={() => setActiveCategory('all')}
              aria-pressed={activeCategory === 'all'}
              className={`${pillBase} ${activeCategory === 'all' ? pillOn : pillOff}`}
            >
              All Events
            </button>
            {categories.map((c) => (
              <button
                key={c}
                type="button"
                onClick={() => setActiveCategory(c)}
                aria-pressed={activeCategory.toLowerCase() === c.toLowerCase()}
                className={`${pillBase} ${activeCategory.toLowerCase() === c.toLowerCase() ? pillOn : pillOff}`}
              >
                {c}
              </button>
            ))}
          </div>
          <div className="flex flex-wrap gap-2" role="group" aria-label="Filter by date">
            {DATE_BUCKETS.map((b) => (
              <button
                key={b.key}
                type="button"
                onClick={() => setActiveDate(b.key)}
                aria-pressed={activeDate === b.key}
                className={`${pillBase} ${activeDate === b.key ? pillOn : pillOff}`}
              >
                {b.label}
              </button>
            ))}
          </div>
        </section>

        {/* Featured Events */}
        <section className="mb-20">
          <div className="flex justify-between items-end mb-12">
            <div>
              <h2 className="text-4xl font-black tracking-tighter uppercase italic">
                {filtersActive ? 'Results' : 'Trending Experiences'}
              </h2>
              <div className="h-1 w-20 bg-brand-primary mt-2"></div>
              {!loading && (
                <p className="text-white/30 text-[10px] font-black uppercase tracking-tighter mt-3">
                  {filteredEvents.length} {filteredEvents.length === 1 ? 'Event' : 'Events'}
                </p>
              )}
            </div>
            {filtersActive ? (
              <button
                type="button"
                onClick={clearFilters}
                className="text-white font-black text-xs tracking-tighter uppercase border-b-2 border-white hover:text-brand-primary hover:border-brand-primary transition-all pb-1"
              >
                Clear Filters
              </button>
            ) : (
              <span className="text-white/30 font-black text-xs tracking-tighter uppercase border-b-2 border-white/10 pb-1">
                View All
              </span>
            )}
          </div>

          {loading ? (
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
              {[1, 2, 3, 4].map(i => (
                <div key={i} className="animate-pulse bg-[#111111] h-[500px]"></div>
              ))}
            </div>
          ) : events.length === 0 ? (
            <div className="text-center py-32 border border-white/5 border-dashed">
              <p className="text-white/30 mb-8 text-xl font-black uppercase italic tracking-tighter">No events found in this area.</p>
              <Link to="/dashboard" className="primary-button">
                Create Event
              </Link>
            </div>
          ) : filteredEvents.length === 0 ? (
            <div className="text-center py-32 border border-white/5 border-dashed">
              <p className="text-white/30 mb-2 text-xl font-black uppercase italic tracking-tighter">
                {searchTerm.trim().length > 0
                  ? `Nothing matches "${searchTerm}".`
                  : 'Nothing matches these filters.'}
              </p>
              <button
                onClick={clearFilters}
                className="text-brand-primary text-xs font-black uppercase tracking-widest underline hover:no-underline"
              >
                Clear filters
              </button>
            </div>
          ) : (
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
              {filteredEvents.map((event) => (
                <motion.div
                  key={event.id}
                  className="primary-card flex flex-col h-[520px] group relative overflow-hidden"
                >
                  <Link to={`/event/${event.id}`} className="flex-shrink-0 relative overflow-hidden">
                    <div className="aspect-[3/4] relative">
                      <img
                        src={event.image || 'https://images.unsplash.com/photo-1492684223066-81342ee5ff30?q=80&w=600'}
                        alt={event.title}
                        className="w-full h-full object-cover grayscale group-hover:grayscale-0 transition-all duration-700 scale-105 group-hover:scale-100"
                      />
                      <div className="absolute inset-0 bg-gradient-to-t from-black via-transparent to-transparent opacity-60"></div>
                      <div className="absolute bottom-6 left-6 right-6">
                        <div className="flex gap-2 mb-2 flex-wrap">
                          <div className="bg-brand-primary text-black px-2 py-0.5 inline-block text-[10px] font-black uppercase tracking-tighter">
                            {event.category || 'EVENT'}
                          </div>
                          {event.genres?.slice(0, 2).map(genre => (
                            <div key={genre} className="bg-white/10 backdrop-blur-md text-white/50 px-2 py-0.5 inline-block text-[10px] font-black uppercase tracking-tighter border border-white/5">
                              {genre}
                            </div>
                          ))}
                        </div>
                        <h3 className="font-black text-3xl text-white uppercase italic tracking-tighter leading-none">{event.title}</h3>
                      </div>
                    </div>
                  </Link>
                  <div className="p-6 flex flex-col flex-grow bg-[#111111]">
                    <div className="space-y-1 mb-auto">
                      <div className="flex items-center text-white/50 text-[10px] font-black uppercase tracking-tighter italic">
                        <Calendar className="w-3 h-3 mr-2 text-brand-primary" />
                        <span>
                          {event.date
                            ? formatInTz(event.date.toDate(), event.timezone, {
                                dateStyle: 'medium',
                              })
                            : 'Date pending'}
                        </span>
                      </div>
                      <div className="flex items-center text-white/50 text-[10px] font-black uppercase tracking-tighter italic">
                        <MapPin className="w-3 h-3 mr-2 text-brand-primary" />
                        <span className="line-clamp-1">{event.location}</span>
                      </div>
                    </div>
                    <div className="mt-8 flex items-center justify-between border-t border-white/5 pt-6">
                      <div>
                        {event.ticketTiers && event.ticketTiers.length > 0 ? (
                          <div className="flex flex-col">
                            <span className="text-[10px] font-black text-white/30 uppercase tracking-tighter leading-none mb-1">Price</span>
                            <span className="font-black text-2xl text-brand-primary tracking-tighter">
                              {formatCurrency(Math.min(...event.ticketTiers.map(t => t.price)))}
                            </span>
                          </div>
                        ) : (
                          <span className="font-black text-2xl text-brand-primary tracking-tighter">{formatCurrency(event.price)}</span>
                        )}
                      </div>
                      <Link
                        to={`/event/${event.id}`}
                        className="bg-white text-black text-[10px] font-black uppercase tracking-tighter px-6 py-3 hover:bg-brand-primary transition-colors"
                      >
                        Buy Tickets
                      </Link>
                    </div>
                  </div>
                </motion.div>
              ))}
            </div>
          )}
        </section>


      </div>
    </div>
  );
}
