import { useEffect, useMemo, useState } from 'react';
import { Event } from '../types';
import { listPublicEvents } from '../lib/events';
import { Link } from 'react-router-dom';
import { Calendar, MapPin, Search } from 'lucide-react';
import { motion } from 'motion/react';
import { formatInTz } from '../lib/datetime';
import { formatCurrency } from '../lib/utils';

export default function Home() {
  const [events, setEvents] = useState<Event[]>([]);
  const [loading, setLoading] = useState(true);
  const [searchTerm, setSearchTerm] = useState('');

  // Client-side fuzzy filter — hits the in-memory event set so it
  // stays sub-millisecond even with a few hundred events. We filter
  // on title + location + category for a casual "where can I find
  // this thing on Saturday" experience without needing a real
  // search index. When the catalog crosses ~1000 events we'll wire
  // an Algolia-style index.
  const filteredEvents = useMemo(() => {
    const term = searchTerm.trim().toLowerCase();
    if (term.length === 0) return events;
    return events.filter((ev) => {
      const haystack = `${ev.title || ''} ${ev.location || ''} ${ev.category || ''}`.toLowerCase();
      return haystack.includes(term);
    });
  }, [events, searchTerm]);

  useEffect(() => {
    async function fetchEvents() {
      try {
        // Reads exos_public_events (published-only, column-narrowed view).
        // NOTE: customUrlOnly (private/presale) events aren't excluded yet —
        // `exclusivity` isn't exposed on the public view. Pending follow-up
        // before storefront launch (add a customUrlOnly filter to the view).
        const list = await listPublicEvents(20);
        setEvents(list);
      } catch (err) {
        console.error('Failed to load events', err);
      } finally {
        setLoading(false);
      }
    }
    fetchEvents();
  }, []);

  return (
    <div className="bg-[#000000] min-h-screen">
      <div className="max-w-7xl mx-auto px-4 py-8">
        {/* Hero Section */}
        <section className="mb-20 pt-10 pb-20 border-b border-white/10">
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

        {/* Featured Events */}
        <section className="mb-20">
          <div className="flex justify-between items-end mb-12">
            <div>
              <h2 className="text-4xl font-black tracking-tighter uppercase italic">Trending Experiences</h2>
              <div className="h-1 w-20 bg-brand-primary mt-2"></div>
            </div>
            <Link to="/" className="text-white font-black text-xs tracking-tighter uppercase border-b-2 border-white hover:text-brand-primary hover:border-brand-primary transition-all pb-1">View All</Link>
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
                Nothing matches "{searchTerm}".
              </p>
              <button
                onClick={() => setSearchTerm('')}
                className="text-brand-primary text-xs font-black uppercase tracking-widest underline hover:no-underline"
              >
                Clear search
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
