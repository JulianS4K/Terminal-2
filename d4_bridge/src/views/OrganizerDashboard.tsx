import { useEffect, useMemo, useState } from 'react';
import { Event } from '../types';
import { listOrgEvents } from '../lib/events';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { Link } from 'react-router-dom';
import { Plus, Settings, Users, BarChart3, ChevronRight, Music, MapPin, Calendar, CheckCircle2, Download, Megaphone, Search, Sparkles } from 'lucide-react';
import { motion } from 'motion/react';
import { formatCurrency } from '../lib/utils';
import { formatInTz } from '../lib/datetime';
import { downloadIcsFile } from '../lib/calendarUtils';
import SalesChart from '../components/SalesChart';

type StatusFilter = 'all' | 'draft' | 'published' | 'cancelled';

export default function OrganizerDashboard() {
  const { user, isAdmin } = useAuth();
  const { orgs } = useOrganization();
  const [events, setEvents] = useState<Event[]>([]);
  const [loading, setLoading] = useState(true);
  // Search + filter state. Both apply client-side over the loaded
  // event set since we already cap at 200 and an organizer with
  // 200+ events still benefits from a sub-100ms filter loop. When
  // we cross 1000 events per organizer we'll move this server-side.
  const [searchTerm, setSearchTerm] = useState('');
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('all');
  // Onboarding nudge: surfaces when user is signed in but has no
  // orgs yet AND hasn't dismissed the prompt. Reads the same
  // localStorage key the onboarding flow writes on completion.
  const [onboardingDismissed, setOnboardingDismissed] = useState(() => {
    try {
      return localStorage.getItem('vibepass:onboarded') === '1';
    } catch {
      return false;
    }
  });

  useEffect(() => {
    async function fetchEvents() {
      if (!user) return;
      setLoading(true);
      try {
        // Org-based model: list events across the orgs the user belongs to.
        // (Admin "all events on the platform" view is deferred to phase-2 — it
        //  needs an admin RLS bypass; see migration 20260520120000 audit finding.)
        const lists = await Promise.all(orgs.map((e) => listOrgEvents(e.org.id)));
        const seen = new Set<string>();
        const deduped = lists.flat().filter((ev) => {
          if (seen.has(ev.id)) return false;
          seen.add(ev.id);
          return true;
        });
        setEvents(deduped);
      } catch (err) {
        console.error('Failed to load events', err);
        setEvents([]);
      } finally {
        setLoading(false);
      }
    }
    fetchEvents();
  }, [user, orgs]);

  const totalEarnings = events.reduce((acc, event) => acc + (event.price * event.ticketsSold), 0);
  const totalTicketsSold = events.reduce((acc, event) => acc + event.ticketsSold, 0);

  // Apply search + status filter. Memoized so the rendered list
  // only recomputes when the inputs change.
  const filteredEvents = useMemo(() => {
    const term = searchTerm.trim().toLowerCase();
    return events.filter((ev) => {
      if (statusFilter !== 'all') {
        const status = ev.status ?? 'published'; // legacy events default to published
        if (status !== statusFilter) return false;
      }
      if (term.length === 0) return true;
      const haystack = `${ev.title || ''} ${ev.location || ''} ${ev.category || ''}`.toLowerCase();
      return haystack.includes(term);
    });
  }, [events, searchTerm, statusFilter]);

  // Onboarding nudge condition: signed in, no orgs, not dismissed.
  // Admins skip — they're not running events themselves.
  const showOnboardingNudge =
    user && !isAdmin && orgs.length === 0 && !onboardingDismissed;

  if (!user) return <div className="max-w-7xl mx-auto p-20 text-center text-gray-500">Sign in to manage your events.</div>;

  return (
    <div className="bg-[#f2f4f7] min-h-screen">
      <div className="max-w-7xl mx-auto px-4 py-12 text-left">
        {isAdmin && (
          <div className="flex items-center justify-between p-4 rounded-xl border border-indigo-300 bg-indigo-50 text-indigo-800 mb-6">
            <p className="text-[10px] font-black uppercase tracking-widest">
              Admin — showing your orgs' events. Platform-wide admin view pending phase-2.
            </p>
            <p className="text-[10px] font-medium uppercase tracking-widest opacity-70">
              {events.length} loaded
            </p>
          </div>
        )}
        <div className="flex flex-col md:flex-row justify-between items-start md:items-center mb-10 gap-6">
          <div>
            <h1 className="text-3xl font-bold tracking-tight mb-1 text-slate-900">
              {isAdmin ? 'All Events (admin)' : 'My Events'}
            </h1>
            <p className="text-slate-500 text-sm">
              {isAdmin
                ? 'Every event on the platform. You can edit any of them in support mode.'
                : 'Manage and track your events and ticket sales.'}
            </p>
          </div>
          <div className="flex space-x-3">
            {orgs.length > 0 && (
              <Link
                to={orgs.length === 1 ? `/orgs/${orgs[0].org.id}/promote` : '/orgs'}
                className="bg-white text-slate-900 border border-slate-200 px-6 py-3 rounded flex items-center space-x-2 font-bold hover:bg-slate-50 shadow-sm transition-all text-sm"
              >
                <Megaphone className="w-4 h-4" />
                <span>Promote</span>
              </Link>
            )}
            <Link
              to="/create-event"
              className="bg-[#026cdf] text-white px-6 py-3 rounded flex items-center space-x-2 font-bold hover:bg-[#015bbd] shadow-sm transition-all text-sm"
            >
              <Plus className="w-4 h-4" />
              <span>Create Event</span>
            </Link>
          </div>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-8">
          {[
            { label: 'TOTAL EARNINGS', value: formatCurrency(totalEarnings), icon: BarChart3, color: 'text-slate-900' },
            { label: 'TICKETS SOLD', value: totalTicketsSold, icon: Users, color: 'text-slate-900' },
            { label: 'ACTIVE EVENTS', value: events.length, icon: Music, color: 'text-slate-900' },
            // Removed RELIABILITY SCORE — it was a hardcoded 98/100 from
            // the original AI Studio scaffold, not connected to any real
            // metric. Misleading on a live dashboard. When we have a real
            // reliability number (e.g., check-in success rate vs. total
            // tickets sold) we can wire one in.
          ].map((stat, idx) => (
            <motion.div 
              initial={{ opacity: 0, y: 5 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ delay: idx * 0.05 }}
              key={idx} 
              className="bg-white p-6 rounded border border-slate-200 shadow-sm"
            >
              <div className="flex justify-between items-start mb-4">
                <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest leading-none">{stat.label}</p>
                <stat.icon className={`w-4 h-4 text-slate-400`} />
              </div>
              <p className={`text-2xl font-bold ${stat.color} tracking-tight`}>{stat.value}</p>
            </motion.div>
          ))}
        </div>

        {/*
          Sales chart — last 30 days. Admins pass null to see platform-wide
          counts; organizers pass their uid so the query filters to their
          tickets only. The chart degrades gracefully when no tickets
          have been sold yet (empty state) or when the composite index
          isn't deployed (error fallback message).
        */}
        <div className="mb-8">
          <SalesChart organizerId={isAdmin ? null : user.uid} />
        </div>

        {showOnboardingNudge && (
          <div className="mb-6 bg-gradient-to-r from-indigo-50 to-purple-50 border border-indigo-200 rounded-2xl p-5 flex items-center justify-between gap-4">
            <div className="flex items-start gap-3">
              <Sparkles className="text-indigo-600 w-5 h-5 flex-shrink-0 mt-0.5" />
              <div>
                <p className="text-sm font-bold text-indigo-900 mb-1">Finish setup</p>
                <p className="text-xs text-indigo-700">
                  Create your first organization to enable white-label storefront, distribution, and team access.
                </p>
              </div>
            </div>
            <div className="flex gap-2 flex-shrink-0">
              <Link
                to="/onboarding"
                className="px-4 py-2 bg-indigo-600 hover:bg-indigo-700 text-white font-bold uppercase tracking-tighter italic text-[10px] transition-all"
              >
                Continue
              </Link>
              <button
                onClick={() => {
                  setOnboardingDismissed(true);
                  try { localStorage.setItem('vibepass:onboarded', '1'); } catch { /* ignore */ }
                }}
                className="px-4 py-2 bg-transparent text-indigo-600 hover:bg-indigo-100 font-bold uppercase tracking-tighter italic text-[10px] transition-all"
              >
                Dismiss
              </button>
            </div>
          </div>
        )}

        {events.length > 0 && (
          <div className="mb-6 flex flex-col md:flex-row gap-3">
            <div className="relative flex-1">
              <Search className="absolute left-4 top-1/2 -translate-y-1/2 text-slate-400 w-4 h-4" />
              <input
                type="search"
                value={searchTerm}
                onChange={(e) => setSearchTerm(e.target.value)}
                placeholder="Search by title, location, or category…"
                aria-label="Search events"
                className="w-full bg-white border border-slate-200 pl-12 pr-4 py-3 rounded-xl text-sm font-bold text-slate-900 placeholder:text-slate-400 placeholder:font-normal focus:outline-none focus:border-brand-primary"
              />
            </div>
            <select
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value as StatusFilter)}
              aria-label="Filter by status"
              className="bg-white border border-slate-200 px-4 py-3 rounded-xl text-sm font-bold text-slate-900 focus:outline-none focus:border-brand-primary"
            >
              <option value="all">All statuses</option>
              <option value="published">Published</option>
              <option value="draft">Drafts</option>
              <option value="cancelled">Cancelled</option>
            </select>
          </div>
        )}

        <div className="bg-white rounded border border-slate-200 shadow-sm overflow-hidden mb-8">
          <div className="px-6 py-5 border-b border-slate-100 flex justify-between items-center bg-white">
            <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest">Your Events</h2>
            <div className="flex space-x-2">
               <div className="relative">
                  <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400 w-3 h-3" />
                  <input type="text" placeholder="Search events..." className="pl-8 pr-4 py-1.5 bg-slate-50 border border-slate-200 rounded text-xs focus:outline-none focus:border-[#026cdf]" />
               </div>
            </div>
          </div>

          {loading ? (
            <div className="p-20 text-center text-slate-300 font-bold uppercase tracking-widest text-xs">Loading events...</div>
          ) : events.length === 0 ? (
            <div className="p-20 text-center">
              <Music className="w-12 h-12 text-slate-100 mx-auto mb-4" />
              <p className="text-slate-400 font-bold uppercase tracking-widest text-[10px]">No events found</p>
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-left border-collapse">
                <thead>
                  <tr className="bg-slate-50 border-b border-slate-100">
                    <th className="px-6 py-4 text-[10px] font-black text-slate-400 uppercase tracking-widest">Event</th>
                    <th className="px-6 py-4 text-[10px] font-black text-slate-400 uppercase tracking-widest">Status</th>
                    <th className="px-6 py-4 text-[10px] font-black text-slate-400 uppercase tracking-widest">Ticket Sales</th>
                    <th className="px-6 py-4 text-[10px] font-black text-slate-400 uppercase tracking-widest">Total Revenue</th>
                    <th className="px-6 py-4 text-[10px] font-black text-slate-400 uppercase tracking-widest text-right">Actions</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-50">
                  {filteredEvents.length === 0 && events.length > 0 && (
                    <tr>
                      <td colSpan={5} className="px-6 py-12 text-center text-sm text-slate-400">
                        No events match your search or filter.
                      </td>
                    </tr>
                  )}
                  {filteredEvents.map((event) => (
                    <tr key={event.id} className="hover:bg-slate-50/50 transition-colors">
                      <td className="px-6 py-4">
                        <div className="flex items-center space-x-4">
                          <div className="w-10 h-12 bg-slate-100 rounded overflow-hidden shrink-0">
                            <img src={event.image || ''} alt="" className="w-full h-full object-cover" />
                          </div>
                          <div>
                            <p className="font-bold text-slate-900 text-sm mb-0.5">{event.title}</p>
                            <p className="text-[10px] text-slate-400 uppercase tracking-widest">{formatInTz(event.date.toDate(), event.timezone, { month: 'short', day: 'numeric', year: 'numeric' })} • {event.location}</p>
                          </div>
                        </div>
                      </td>
                      <td className="px-6 py-4">
                        <span className="px-2 py-1 bg-green-50 text-green-600 rounded text-[10px] font-bold uppercase tracking-widest border border-green-100">Active</span>
                      </td>
                      <td className="px-6 py-4">
                        <div className="w-full max-w-[100px] bg-slate-100 h-1 rounded-full overflow-hidden">
                           <div className="bg-[#026cdf] h-full" style={{ width: `${Math.min(100, (event.ticketsSold / 100) * 100)}%` }}></div>
                        </div>
                        <p className="text-[10px] font-bold text-slate-400 mt-1 uppercase tracking-widest">{event.ticketsSold} SOLD</p>
                      </td>
                      <td className="px-6 py-4">
                        <p className="font-bold text-slate-900 text-sm">{formatCurrency(event.ticketsSold * event.price)}</p>
                      </td>
                      <td className="px-6 py-4 text-right">
                        <div className="flex items-center justify-end space-x-2">
                           <Link to={`/dashboard/event/${event.id}/promote`} aria-label="Promote event" className="p-2 text-slate-400 hover:text-[#026cdf] transition-colors"><Megaphone className="w-4 h-4" /></Link>
                           <Link to={`/dashboard/event/${event.id}`} aria-label="Sales report" className="p-2 text-slate-400 hover:text-[#026cdf] transition-colors"><BarChart3 className="w-4 h-4" /></Link>
                           <Link to={`/edit-event/${event.id}`} aria-label="Edit event" className="p-2 text-slate-400 hover:text-[#026cdf] transition-colors"><Settings className="w-4 h-4" /></Link>
                           <Link to={`/create-event?clone=${event.id}`} aria-label="Duplicate event as a new draft" className="p-2 text-slate-400 hover:text-[#026cdf] transition-colors text-[10px] font-black uppercase tracking-widest">CLONE</Link>
                           <Link to={`/checkin/${event.id}`} aria-label="Open check-in view" className="p-2 text-slate-400 hover:text-green-600 transition-colors"><CheckCircle2 className="w-4 h-4" /></Link>
                           <Link to={`/event/${event.id}`} aria-label="View public event page" className="p-2 text-slate-400 hover:text-[#026cdf] transition-colors"><ChevronRight className="w-4 h-4" /></Link>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>

        <div className="mb-12">
            <div className="bg-white p-8 rounded border border-slate-200 shadow-sm relative w-full">
                <div className="flex items-center space-x-2 mb-6">
                    <BarChart3 className="w-4 h-4 text-[#026cdf]" />
                    <h3 className="text-[11px] font-black text-slate-900 uppercase tracking-[0.2em]">Sales Activity</h3>
                </div>
                <div className="h-48 flex items-end justify-between space-x-2">
                    {[40, 70, 45, 90, 65, 85, 30, 60, 75, 50, 80, 95].map((h, i) => (
                        <div key={i} className="flex-grow bg-slate-100 hover:bg-[#026cdf] transition-all rounded-t-sm" style={{ height: `${h}%` }}></div>
                    ))}
                </div>
                <div className="flex justify-between mt-4 text-[9px] font-bold text-slate-400 uppercase tracking-widest">
                    <span>MAY</span>
                    <span>JUN</span>
                    <span>JUL</span>
                    <span>AUG</span>
                    <span>SEP</span>
                    <span>OCT</span>
                </div>
            </div>
        </div>
      </div>
    </div>
  );
}
