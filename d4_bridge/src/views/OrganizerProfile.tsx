import { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { Event, Organization } from '../types';
import { getPublicOrg, followOrg, unfollowOrg, isFollowingOrg } from '../lib/orgs';
import SocialLinks from '../components/SocialLinks';
import { listPublicEventsForOrg } from '../lib/events';
import { useAuth } from '../context/AuthContext';
import { motion } from 'motion/react';
import { MapPin, Calendar, CheckCircle2, UserPlus } from 'lucide-react';
import { formatCurrency } from '../lib/utils';
import { formatInTz } from '../lib/datetime';

export default function OrganizerProfile() {
  const { id } = useParams();
  const { user } = useAuth();
  type Socials = NonNullable<Organization['marketing']>['socials'];
  const [organizer, setOrganizer] = useState<{ displayName: string; photoURL?: string; description?: string; socials?: Socials } | null>(null);
  const [events, setEvents] = useState<Event[]>([]);
  const [loading, setLoading] = useState(true);
  const [isFollowing, setIsFollowing] = useState(false);
  const [followersCount, setFollowersCount] = useState(0);

  useEffect(() => {
    let cancelled = false;
    async function fetchOrganizerAndEvents() {
      if (!id) return;
      try {
        // `id` is an ORG id (org-centric model — events belong to orgs).
        // Profile + follower count come from the public org projection; events
        // from the published-events seam (already ordered soonest-first).
        const [org, evs] = await Promise.all([
          getPublicOrg(id),
          listPublicEventsForOrg(id),
        ]);
        if (cancelled) return;
        if (org) {
          setOrganizer({
            displayName: org.name || 'Organizer',
            photoURL: org.theme?.logoUrl,
            description: org.description || 'Creating unforgettable experiences.',
            socials: org.marketing?.socials,
          });
          setFollowersCount(org.followersCount ?? 0);
        } else {
          setOrganizer({ displayName: 'Organizer', description: 'Experience creator.' });
        }
        setEvents(evs);

        if (user) {
          const following = await isFollowingOrg(id).catch(() => false);
          if (!cancelled) setIsFollowing(following);
        }
      } catch (err) {
        console.error('Error fetching organizer details', err);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    fetchOrganizerAndEvents();
    return () => {
      cancelled = true;
    };
  }, [id, user]);

  const toggleFollow = async () => {
    if (!user || !id) return;
    const next = !isFollowing;
    // Optimistic flip; the RPC maintains followers_count atomically server-side
    // (idempotent — a double follow/unfollow never mis-counts).
    setIsFollowing(next);
    setFollowersCount((prev) => Math.max(0, prev + (next ? 1 : -1)));
    try {
      if (next) await followOrg(id);
      else await unfollowOrg(id);
    } catch (err) {
      console.error('Failed to toggle follow', err);
      // Revert on failure.
      setIsFollowing(!next);
      setFollowersCount((prev) => Math.max(0, prev + (next ? -1 : 1)));
    }
  };

  if (loading) return <div className="min-h-screen wall flex items-center justify-center type uppercase text-white/50 tracking-widest text-xs animate-pulse">Loading Profile...</div>;

  return (
    <div className="wall grain min-h-screen text-white pb-20">
       <style>{`
         .grain::before {
           content: ""; position: fixed; inset: 0; z-index: 1; pointer-events: none;
           opacity: .055; mix-blend-mode: overlay;
           background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='180' height='180'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
         }
       `}</style>
       {/* Banner */}
       <div className="h-64 bg-[#111] relative overflow-hidden flex items-end border-b border-white/10">
          {organizer?.photoURL && (
            <div className="absolute inset-0 opacity-30">
              <img src={organizer.photoURL} alt="" className="xerox w-full h-full object-cover" />
            </div>
          )}
          <div className="absolute inset-0 bg-gradient-to-t from-black to-transparent z-10"></div>
          <div className="max-w-7xl mx-auto px-4 w-full relative z-20 pb-8 flex flex-col md:flex-row md:items-end justify-between gap-6">
             <div className="flex items-end space-x-6">
               <div className="w-32 h-32 bg-brand-primary flex items-center justify-center disp text-6xl text-black border-4 border-black uppercase">
                 {organizer?.displayName?.charAt(0) || 'O'}
               </div>
               <div className="mb-2">
                 <h1 className="disp text-5xl tracking-tight leading-none uppercase" style={{ transform: 'skewX(-4deg)' }}>{organizer?.displayName}</h1>
                 <p className="type text-brand-primary text-[11px] uppercase tracking-widest mt-2">{followersCount} Followers</p>
               </div>
             </div>
             <div>
                {user && user.uid !== id && (
                  <button
                     onClick={toggleFollow}
                     className={`disp mb-2 px-8 py-2.5 text-lg tracking-wide transition-colors ${isFollowing ? 'bg-white/10 text-white border border-white/20 hover:bg-white/20' : 'bg-brand-primary text-black hover:bg-white'}`}
                  >
                     {isFollowing ? 'FOLLOWING' : 'FOLLOW'}
                  </button>
                )}
             </div>
          </div>
       </div>

       <div className="max-w-7xl mx-auto px-4 mt-12 grid grid-cols-1 md:grid-cols-4 gap-12 relative z-10">

          {/* About */}
          <div className="md:col-span-1 space-y-8">
             <div>
                <h3 className="type text-[10px] uppercase tracking-widest text-white/40 mb-2">about organizer</h3>
                <p className="type text-[13px] text-white/60 leading-relaxed">{organizer?.description}</p>
                <SocialLinks socials={organizer?.socials} className="flex items-center gap-4 mt-4" />
             </div>
             <div className="w-full h-px bg-white/10"></div>
             <div>
                <h3 className="type text-[10px] uppercase tracking-widest text-white/40 mb-2">notifications</h3>
                <p className="type text-[11px] text-white/40 leading-relaxed">Follow to get alerts when this organizer announces events in your region.</p>
             </div>
          </div>

          {/* Events */}
          <div className="md:col-span-3">
             <div className="flex items-center justify-between mb-8 border-b border-white/10 pb-4">
                <h2 className="disp text-3xl tracking-tight uppercase" style={{ transform: 'skewX(-4deg)' }}>UPCOMING EXPERIENCES</h2>
             </div>

             {events.length === 0 ? (
                <div className="py-20 text-center border border-white/5 border-dashed">
                    <p className="type text-white/30 text-sm uppercase tracking-tighter">No upcoming events.</p>
                </div>
             ) : (
                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                   {events.map(event => (
                       <Link key={event.id} to={`/event/${event.id}`} className="bg-[#111] border border-white/10 overflow-hidden group hover:border-brand-primary/60 transition-colors">
                           <div className="aspect-video relative overflow-hidden">
                              <img src={event.image || 'https://images.unsplash.com/photo-1492684223066-81342ee5ff30'} alt={event.title} className="xerox w-full h-full object-cover transition-all duration-700" />
                              <div className="absolute inset-0 bg-gradient-to-t from-black to-transparent opacity-80"></div>
                              <div className="absolute bottom-4 left-4 right-4">
                                 <h3 className="disp text-2xl text-white uppercase tracking-tight leading-none mb-1">{event.title}</h3>
                                 <p className="type text-[9px] text-brand-primary uppercase tracking-widest">{event.category || 'EVENT'}</p>
                              </div>
                           </div>
                           <div className="p-5">
                              <div className="flex items-center text-white/50 text-[10px] uppercase tracking-widest type mb-1 gap-2">
                                <Calendar className="w-3 h-3 text-brand-primary" />
                                <span>{event.date ? formatInTz((event.date as any).toDate(), event.timezone, { dateStyle: 'medium' }) : 'Date TBD'}</span>
                              </div>
                              <div className="flex items-center text-white/50 text-[10px] uppercase tracking-widest type pb-4 mb-4 border-b border-white/5 gap-2 truncate">
                                <MapPin className="w-3 h-3 text-brand-primary shrink-0" />
                                <span className="line-clamp-1">{event.location}</span>
                              </div>
                              <div className="flex justify-between items-center">
                                 <span className="stamp neon text-base">
                                    {event.ticketTiers?.length ? formatCurrency(Math.min(...event.ticketTiers.map(t => t.price))) : formatCurrency(event.price)}+
                                 </span>
                                 <span className="type text-[9px] text-white/40 uppercase tracking-widest group-hover:text-brand-primary transition-colors">view details →</span>
                              </div>
                           </div>
                       </Link>
                   ))}
                </div>
             )}
          </div>
       </div>
    </div>
  );
}
