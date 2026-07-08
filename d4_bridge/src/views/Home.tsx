import { useEffect, useMemo, useState } from 'react';
import { Event } from '../types';
import { listPublicEvents } from '../lib/events';
import { Link } from 'react-router-dom';
import { Calendar, MapPin, Search } from 'lucide-react';
import { motion } from 'motion/react';
import { formatInTz } from '../lib/datetime';
import { formatCurrency } from '../lib/utils';
import { effectiveTierPrice } from '../lib/pricing';
import { listSavedEventIds } from '../lib/saves';
import { useAuth } from '../context/AuthContext';
import SaveEventButton from '../components/SaveEventButton';

/** Lowest effective (schedule-aware) price across an event's tiers. */
function eventFromPrice(event: Event): number {
  const tiers = event.ticketTiers;
  if (tiers && tiers.length > 0) {
    return Math.min(...tiers.map((t) => effectiveTierPrice(t.price, t.priceSchedule)));
  }
  return event.price;
}

// ---------------------------------------------------------------------------
// Presentational-only helpers + demo fallback imagery (Brooklyn-punk restyle).
// The mockup's Unsplash photos stand in ONLY where a real event has no image;
// all copy/prices/dates below are bound to real event data.
// ---------------------------------------------------------------------------

const FEATURED_FALLBACK = [
  'https://images.unsplash.com/photo-1516450360452-9312f5e86fc7?q=80&w=1000',
  'https://images.unsplash.com/photo-1470229722913-7c0e2dbbafd3?q=80&w=1000',
];
const POPULAR_FALLBACK = [
  'https://images.unsplash.com/photo-1493225457124-a3eb161ffa5f?q=80&w=600',
  'https://images.unsplash.com/photo-1533174072545-7a4b6ad7a6c3?q=80&w=600',
  'https://images.unsplash.com/photo-1516450360452-9312f5e86fc7?q=80&w=600',
  'https://images.unsplash.com/photo-1459749411175-04bf5292ceea?q=80&w=600',
];
const AGENDA_FALLBACK = [
  'https://images.unsplash.com/photo-1516450360452-9312f5e86fc7?q=80&w=300',
  'https://images.unsplash.com/photo-1501386761578-eac5c94b800a?q=80&w=300',
  'https://images.unsplash.com/photo-1485872299829-c673f5194813?q=80&w=300',
  'https://images.unsplash.com/photo-1470229722913-7c0e2dbbafd3?q=80&w=300',
  'https://images.unsplash.com/photo-1574391884720-bbc3740c59d1?q=80&w=300',
  'https://images.unsplash.com/photo-1508973379184-7517410fb0bc?q=80&w=300',
  'https://images.unsplash.com/photo-1415201364774-f6f0bb35f28f?q=80&w=300',
];

const imgFor = (event: Event, pool: string[], i: number) =>
  event.image || pool[i % pool.length];

/** "8:00PM" style time in the event's timezone (Anton display slot). */
function eventTime(event: Event): string {
  if (!event.date) return 'TBA';
  return formatInTz(event.date.toDate(), event.timezone, {
    hour: 'numeric',
    minute: '2-digit',
  })
    .replace(/\s+/g, '')
    .toUpperCase();
}

/** "FRI 11 JUL" agenda / date-pill label in the event's timezone. */
function eventDayLabel(event: Event): string {
  if (!event.date) return 'DATE TBA';
  const d = event.date.toDate();
  const wd = formatInTz(d, event.timezone, { weekday: 'short' });
  const day = formatInTz(d, event.timezone, { day: 'numeric' });
  const mon = formatInTz(d, event.timezone, { month: 'short' });
  return `${wd} ${day} ${mon}`.toUpperCase();
}

/** Lowercase "fri 11 jul · 8:00pm · techno" meta line for cards. */
function eventMeta(event: Event): string {
  const parts = [eventDayLabel(event), eventTime(event)];
  if (event.category) parts.push(event.category);
  return parts.join(' · ').toLowerCase();
}

/** "$30+" / "FREE" price stamp. */
function priceStamp(event: Event): string {
  const p = eventFromPrice(event);
  if (!p || p <= 0) return 'FREE';
  return `${formatCurrency(p, event.currency)}+`;
}

export default function Home() {
  const { user } = useAuth();
  const [events, setEvents] = useState<Event[]>([]);
  const [loading, setLoading] = useState(true);
  const [searchTerm, setSearchTerm] = useState('');
  const [selectedDay, setSelectedDay] = useState<string | null>(null);
  const [savedIds, setSavedIds] = useState<Set<string>>(new Set());

  // Local-day key ("y-m-d") used to match an event's date against a selected
  // date pill. Local (not UTC) so "tonight" means the viewer's tonight.
  const dayKey = (dt: Date) => `${dt.getFullYear()}-${dt.getMonth()}-${dt.getDate()}`;

  // Client-side fuzzy filter — hits the in-memory event set so it
  // stays sub-millisecond even with a few hundred events. We filter
  // on title + location + category for a casual "where can I find
  // this thing on Saturday" experience without needing a real
  // search index. When the catalog crosses ~1000 events we'll wire
  // an Algolia-style index.
  const filteredEvents = useMemo(() => {
    const term = searchTerm.trim().toLowerCase();
    return events.filter((ev) => {
      if (term.length > 0) {
        const haystack = `${ev.title || ''} ${ev.location || ''} ${ev.category || ''}`.toLowerCase();
        if (!haystack.includes(term)) return false;
      }
      if (selectedDay) {
        if (!ev.date) return false;
        if (dayKey(ev.date.toDate()) !== selectedDay) return false;
      }
      return true;
    });
  }, [events, searchTerm, selectedDay]);

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

  // Which of these events the signed-in user has already saved — fetched once
  // so the per-card hearts render controlled (no N per-card queries).
  useEffect(() => {
    if (!user) {
      setSavedIds(new Set());
      return undefined;
    }
    let alive = true;
    listSavedEventIds().then((ids) => {
      if (alive) setSavedIds(ids);
    });
    return () => {
      alive = false;
    };
  }, [user]);

  // --- Derived, presentational-only view slices -----------------------------

  // Genre pills bound to the real category set. Clicking one drives the
  // EXISTING search filter (no new state) — "ALL" clears it.
  const categories = useMemo(() => {
    const set = new Set<string>();
    for (const ev of events) if (ev.category) set.add(ev.category);
    return ['ALL', ...Array.from(set)];
  }, [events]);

  const featured = filteredEvents.slice(0, 2);
  const popular = filteredEvents.slice(2, 6);

  // Agenda grouped by day, preserving the ascending (starts_at) order the
  // public view already returns.
  const agendaGroups = useMemo(() => {
    const groups: { label: string; items: Event[] }[] = [];
    const index = new Map<string, number>();
    for (const ev of filteredEvents) {
      const label = eventDayLabel(ev);
      let i = index.get(label);
      if (i === undefined) {
        i = groups.length;
        index.set(label, i);
        groups.push({ label, items: [] });
      }
      groups[i].items.push(ev);
    }
    return groups;
  }, [filteredEvents]);

  // Date scroller — next four days from now, each a real day filter. Clicking
  // a pill filters the page to that day; clicking the active pill clears it.
  const datePills = useMemo(() => {
    const kickers = ['tonight', 'tomorrow', 'weekend', 'sunday'];
    const now = new Date();
    return Array.from({ length: 4 }, (_, i) => {
      const d = new Date(now);
      d.setDate(now.getDate() + i);
      const wd = d.toLocaleDateString('en-US', { weekday: 'short' }).toUpperCase();
      return { kicker: kickers[i], label: `${wd} ${d.getDate()}`, key: dayKey(d) };
    });
    // dayKey is a stable pure closure; recompute only on mount.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const savedChip = (event: Event) => (
    // Save-from-discovery. Sibling of the card Link (not nested) so the heart
    // toggles without navigating; signed-out opens auth.
    <div className="absolute top-3 right-3 z-20">
      <SaveEventButton
        eventId={event.id}
        variant="chip"
        initialSaved={savedIds.has(event.id)}
        onChange={(saved) =>
          setSavedIds((prev) => {
            const next = new Set(prev);
            if (saved) next.add(event.id);
            else next.delete(event.id);
            return next;
          })
        }
      />
    </div>
  );

  return (
    <div className="wall grain min-h-screen text-white">
      {/* Local-only presentational classes lifted from the mockup's <style>.
          .grain / .tape / .under-spray aren't in index.css. */}
      <style>{`
        .grain::before{ content:""; position:fixed; inset:0; z-index:1; pointer-events:none; opacity:.055; mix-blend-mode:overlay;
          background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='180' height='180'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E"); }
        .tape{ position:absolute; width:96px; height:22px; background:rgba(0,255,0,.14); border-left:1px dashed rgba(0,255,0,.35); border-right:1px dashed rgba(0,255,0,.35); box-shadow:0 1px 3px rgba(0,0,0,.5); }
        .under-spray{ position:relative; }
        .under-spray::after{ content:""; position:absolute; left:0; right:0; bottom:-8px; height:12px; background:#00FF00; filter:blur(.5px); opacity:.95;
          -webkit-mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='300' height='12'%3E%3Cpath d='M0 7 Q40 2 80 6 T160 5 T240 7 T300 4 L300 12 L0 12Z' fill='%23000'/%3E%3C/svg%3E") no-repeat center/100% 100%;
          mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='300' height='12'%3E%3Cpath d='M0 7 Q40 2 80 6 T160 5 T240 7 T300 4 L300 12 L0 12Z' fill='%23000'/%3E%3C/svg%3E") no-repeat center/100% 100%; }
        .no-bar::-webkit-scrollbar{ display:none; } .no-bar{ -ms-overflow-style:none; scrollbar-width:none; }
      `}</style>

      {/* ============ HERO ============ */}
      <header className="relative overflow-hidden border-b border-white/10">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 pt-12 pb-14 relative z-10">
          <div className="inline-flex items-center gap-2 border border-brand-primary/60 text-white px-3 py-1.5 mb-8">
            <MapPin className="w-4 h-4 text-brand-primary" />
            <span className="disp text-lg tracking-wide leading-none pt-0.5">NEW YORK</span>
            <span className="text-[10px] text-white/50">▼</span>
          </div>

          <div className="relative max-w-4xl mb-7">
            <motion.h1
              initial={{ opacity: 0, x: -20 }}
              animate={{ opacity: 1, x: 0 }}
              className="leading-[0.82]"
            >
              <span className="disp block text-6xl md:text-8xl tracking-tight text-white" style={{ transform: 'skewX(-5deg)' }}>
                WHAT ARE YOU
              </span>
              <span className="disp inline-block text-6xl md:text-9xl tracking-tight neon under-spray mt-2" style={{ transform: 'skewX(-5deg)' }}>
                DOING TONIGHT?
              </span>
            </motion.h1>
            <span className="marker absolute right-0 top-2 md:top-6 text-brand-secondary text-2xl md:text-3xl rotate-[7deg] hidden sm:block">
              real tickets only →
            </span>
          </div>

          <p className="type text-white/60 text-base md:text-lg max-w-xl mb-9 leading-relaxed">
            Every show, every basement, every after-hours in the city. No scalpers, no bots —
            guaranteed authentic entry, every time.
          </p>

          <div className="relative max-w-2xl mb-8">
            <Search className="absolute left-5 top-1/2 -translate-y-1/2 text-white/70 w-5 h-5 pointer-events-none" />
            <input
              type="search"
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              aria-label="Search events"
              placeholder="search bands, venues, nights..."
              className="type w-full bg-[#111] border border-white/20 py-5 pl-14 pr-6 text-white placeholder-white/35 focus:outline-none focus:border-brand-primary transition-all text-base tracking-wide"
            />
          </div>

          {/* date scroller — real day filter */}
          <div className="flex gap-2 overflow-x-auto no-bar -mx-1 px-1">
            {datePills.map((p) => {
              const active = selectedDay === p.key;
              return (
                <button
                  key={p.key}
                  onClick={() => setSelectedDay(active ? null : p.key)}
                  aria-pressed={active}
                  className={`shrink-0 px-6 py-2.5 min-w-[92px] text-center transition-colors ${
                    active
                      ? 'bg-brand-primary text-black'
                      : 'bg-white/5 border border-white/15 text-white/75 hover:border-brand-primary'
                  }`}
                >
                  <span className="type text-[10px] uppercase tracking-widest block leading-none">{p.kicker}</span>
                  <span className="disp text-2xl tracking-wide leading-none mt-1 block">{p.label}</span>
                </button>
              );
            })}
            {selectedDay && (
              <button
                onClick={() => setSelectedDay(null)}
                className="shrink-0 flex items-center gap-2 text-white/70 px-5 py-2.5 border border-white/15 hover:border-brand-primary transition-colors"
              >
                <Calendar className="w-4 h-4" />
                <span className="type text-[11px] uppercase tracking-widest">all dates</span>
              </button>
            )}
          </div>
        </div>
      </header>

      {/* ============ GENRE PILLS (sticky under the h-20 navbar) ============ */}
      {categories.length > 1 && (
        <div className="sticky top-20 z-40 bg-black/92 backdrop-blur border-b border-white/10">
          <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
            <div className="flex gap-2 overflow-x-auto no-bar py-3.5 items-center">
              {categories.map((cat) => {
                const active =
                  cat === 'ALL'
                    ? searchTerm.trim() === ''
                    : searchTerm.trim().toLowerCase() === cat.toLowerCase();
                return (
                  <button
                    key={cat}
                    onClick={() => setSearchTerm(cat === 'ALL' ? '' : cat)}
                    className={`shrink-0 disp text-lg tracking-wide px-4 py-0.5 border transition-colors ${
                      active
                        ? 'bg-white text-black border-white'
                        : 'bg-white/5 text-white/70 border-white/15 hover:border-brand-primary hover:text-brand-primary'
                    }`}
                  >
                    {cat.toUpperCase()}
                  </button>
                );
              })}
            </div>
          </div>
        </div>
      )}

      <main className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-14 relative z-10">
        {loading ? (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
            {[1, 2, 3, 4].map((i) => (
              <div key={i} className="animate-pulse bg-[#111111] h-[420px]"></div>
            ))}
          </div>
        ) : events.length === 0 ? (
          <div className="text-center py-32 border border-white/10 border-dashed">
            <p className="disp text-3xl text-white/40 mb-8 tracking-tight" style={{ transform: 'skewX(-4deg)' }}>
              NO EVENTS IN THIS AREA.
            </p>
            <Link to="/dashboard" className="disp text-lg bg-brand-primary text-black px-6 py-2 inline-block hover:scale-[1.03] transition-transform tracking-wide">
              CREATE EVENT
            </Link>
          </div>
        ) : filteredEvents.length === 0 ? (
          <div className="text-center py-32 border border-white/10 border-dashed">
            <p className="disp text-3xl text-white/40 mb-3 tracking-tight" style={{ transform: 'skewX(-4deg)' }}>
              NOTHING MATCHES "{searchTerm}".
            </p>
            <button
              onClick={() => setSearchTerm('')}
              className="type text-[12px] text-brand-primary uppercase tracking-widest underline hover:no-underline"
            >
              clear search
            </button>
          </div>
        ) : (
          <>
            {/* ============ FEATURED ============ */}
            {featured.length > 0 && (
              <section className="mb-20">
                <div className="flex items-end justify-between mb-8">
                  <h2 className="disp text-4xl md:text-5xl tracking-tight text-white" style={{ transform: 'skewX(-5deg)' }}>
                    FEATURED <span className="neon">TONIGHT</span>
                  </h2>
                  <Link to="/" className="type text-[12px] uppercase tracking-widest text-white/50 hover:text-brand-primary border-b border-white/30 pb-1">
                    see all ↗
                  </Link>
                </div>
                <div className="grid grid-cols-1 lg:grid-cols-2 gap-5">
                  {featured.map((event, i) => (
                    <motion.div
                      key={event.id}
                      className="group relative bg-[#111] border border-white/10 hover:border-brand-primary/60 transition-all overflow-hidden"
                    >
                      <div className={`tape ${i % 2 === 0 ? '-top-2 left-8 rotate-[-6deg]' : '-top-2 right-10 rotate-[5deg]'}`}></div>
                      {savedChip(event)}
                      <Link to={`/event/${event.id}`} className="block">
                        <div className="relative h-72 overflow-hidden">
                          <img
                            src={imgFor(event, FEATURED_FALLBACK, i)}
                            alt={event.title}
                            className="xerox w-full h-full object-cover transition-all duration-700"
                          />
                          <div className="absolute inset-0 bg-gradient-to-t from-[#111] via-transparent to-transparent"></div>
                          <span className="stamp text-brand-primary absolute top-4 left-4 rotate-[-6deg] bg-black/50 text-base">
                            {(event.category || 'LIVE').toUpperCase()}
                          </span>
                        </div>
                        <div className="p-6">
                          <p className="type text-[11px] uppercase tracking-widest text-brand-primary mb-1">{eventMeta(event)}</p>
                          <h3 className="disp text-4xl md:text-5xl text-white leading-[0.9] tracking-tight mb-3">{event.title}</h3>
                          <div className="flex items-center justify-between border-t border-white/10 pt-3">
                            <span className="type text-[12px] uppercase tracking-wide text-white/60 truncate pr-3">{event.location}</span>
                            <span className="stamp text-brand-primary text-xl shrink-0">{priceStamp(event)}</span>
                          </div>
                        </div>
                      </Link>
                    </motion.div>
                  ))}
                </div>
              </section>
            )}

            {/* ============ POPULAR GRID ============ */}
            {popular.length > 0 && (
              <section className="mb-20">
                <div className="flex items-end justify-between mb-8">
                  <h2 className="disp text-4xl md:text-5xl tracking-tight text-white" style={{ transform: 'skewX(-5deg)' }}>
                    POPULAR <span className="text-brand-secondary">THIS WEEK</span>
                  </h2>
                  <Link to="/" className="type text-[12px] uppercase tracking-widest text-white/50 hover:text-brand-primary border-b border-white/30 pb-1">
                    see all ↗
                  </Link>
                </div>
                <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
                  {popular.map((event, i) => (
                    <div key={event.id} className="group relative flex flex-col bg-[#111] border border-white/10 hover:border-brand-primary/60 transition-all">
                      {savedChip(event)}
                      <Link to={`/event/${event.id}`} className="flex flex-col">
                        <div className="relative aspect-[3/4] overflow-hidden">
                          <img
                            src={imgFor(event, POPULAR_FALLBACK, i)}
                            alt={event.title}
                            className="xerox w-full h-full object-cover transition-all duration-700"
                          />
                          <div className="absolute inset-0 bg-gradient-to-t from-[#111] via-transparent to-transparent"></div>
                          <span className="disp absolute top-2 left-2 bg-brand-primary text-black px-2 text-sm tracking-wide">
                            {(event.category || 'EVENT').toUpperCase()}
                          </span>
                          <div className="absolute bottom-3 left-3 right-3">
                            <p className="type text-[10px] uppercase tracking-widest text-brand-primary mb-0.5">
                              {`${eventDayLabel(event)} · ${eventTime(event)}`.toLowerCase()}
                            </p>
                            <h3 className="disp text-2xl text-white leading-[0.9] tracking-tight line-clamp-2">{event.title}</h3>
                          </div>
                        </div>
                        <div className="p-3 flex items-center justify-between">
                          <span className="type text-[11px] uppercase text-white/50 truncate pr-2">{event.location}</span>
                          <span className="stamp text-brand-primary text-base shrink-0">{priceStamp(event)}</span>
                        </div>
                      </Link>
                    </div>
                  ))}
                </div>
              </section>
            )}

            {/* ============ AGENDA ============ */}
            {agendaGroups.length > 0 && (
              <section>
                <div className="flex items-end justify-between mb-8">
                  <h2 className="disp text-4xl md:text-5xl tracking-tight text-white" style={{ transform: 'skewX(-5deg)' }}>
                    ALL <span className="neon">UPCOMING</span>
                  </h2>
                  <span className="marker text-white/35 text-lg rotate-[-3deg]">sorted by date</span>
                </div>
                {agendaGroups.map((day) => (
                  <div key={day.label} className="mb-10">
                    <div className="flex items-center gap-3 mb-4">
                      <span className="marker text-2xl text-white rotate-[-2deg]">{day.label}</span>
                      <div className="flex-1 border-t border-dashed border-white/20"></div>
                      <span className="type text-[11px] uppercase tracking-widest text-white/35">
                        {day.items.length} {day.items.length === 1 ? 'show' : 'shows'}
                      </span>
                    </div>
                    <div className="divide-y divide-white/5 border-y border-white/10">
                      {day.items.map((event, i) => (
                        <Link
                          key={event.id}
                          to={`/event/${event.id}`}
                          className="group grid grid-cols-[64px_1fr_auto] md:grid-cols-[64px_100px_1fr_auto_auto] items-center gap-3 md:gap-5 py-3.5 hover:bg-white/[0.03] px-1 transition-colors"
                        >
                          <div className="w-16 h-16 overflow-hidden hidden md:block">
                            <img
                              src={imgFor(event, AGENDA_FALLBACK, i)}
                              alt={event.title}
                              className="xerox w-full h-full object-cover transition-all duration-700"
                            />
                          </div>
                          <span className="disp text-2xl md:text-3xl text-white leading-none tracking-wide">{eventTime(event)}</span>
                          <div className="min-w-0">
                            <div className="flex items-center gap-2">
                              <h3 className="disp text-xl md:text-2xl text-white leading-none tracking-tight truncate group-hover:neon transition-all">
                                {event.title}
                              </h3>
                            </div>
                            <p className="type text-[11px] uppercase tracking-wide text-white/40 mt-1 truncate">
                              {event.location}
                              {event.category ? ` · ${event.category.toLowerCase()}` : ''}
                            </p>
                          </div>
                          <span className="stamp text-brand-primary text-base hidden md:inline">{priceStamp(event)}</span>
                          <span className="disp text-base bg-white text-black px-3 py-0.5 group-hover:bg-brand-primary transition-colors tracking-wide whitespace-nowrap">
                            TICKETS
                          </span>
                        </Link>
                      ))}
                    </div>
                  </div>
                ))}
              </section>
            )}
          </>
        )}
      </main>
    </div>
  );
}
