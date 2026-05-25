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

  if (loading) return <div className="min-h-screen bg-[#000000] flex items-center justify-center font-black uppercase text-white/50 tracking-widest text-xs animate-pulse">Loading Profile...</div>;

  return (
    <div className="bg-[#000000] min-h-screen text-white pb-20">
       {/* Banner */}
       <div className="h-64 bg-[#111111] relative overflow-hidden flex items-end">
          <div className="absolute inset-0 bg-gradient-to-t from-black to-transparent z-10"></div>
          <div className="max-w-7xl mx-auto px-4 w-full relative z-20 pb-8 flex flex-col md:flex-row md:items-end justify-between gap-6">
             <div className="flex items-end space-x-6">
               <div className="w-32 h-32 bg-brand-primary flex items-center justify-center text-6xl font-black text-black shadow-2xl border-4 border-black uppercase italic">
                 {organizer?.displayName?.charAt(0) || 'O'}
               </div>
               <div className="mb-2">
                 <h1 className="text-5xl font-black tracking-tighter uppercase italic">{organizer?.displayName}</h1>
                 <p className="text-brand-primary text-xs uppercase font-black tracking-widest mt-2">{followersCount} Followers</p>
               </div>
             </div>
             <div>
                {user && user.uid !== id && (
                  <button 
                     onClick={toggleFollow}
                     className={`mb-2 px-8 py-3 text-xs font-black uppercase tracking-widest transition-all ${isFollowing ? 'bg-white/10 text-white border border-white/20 hover:bg-white/20' : 'bg-brand-primary text-black hover:bg-white'}`}
                  >
                     {isFollowing ? 'Following' : 'Follow'}
                  </button>
                )}
             </div>
          </div>
       </div>

       <div className="max-w-7xl mx-auto px-4 mt-12 grid grid-cols-1 md:grid-cols-4 gap-12">
          
          {/* About */}
          <div className="md:col-span-1 space-y-8">
             <div>
                <h3 className="text-[10px] font-black uppercase tracking-widest text-white/40 mb-2">About Organizer</h3>
                <p className="text-sm font-medium italic text-slate-300">{organizer?.description}</p>
                <SocialLinks socials={organizer?.socials} className="flex items-center gap-4 mt-4" />
             </div>
             <div className="w-full h-px bg-white/10"></div>
             <div>
                <h3 className="text-[10px] font-black uppercase tracking-widest text-white/40 mb-2">Notifications</h3>
                <p className="text-[10px] font-black italic uppercase text-slate-500">Follow to get alerts when this organizer announces events in your region.</p>
             </div>
          </div>

          {/* Events */}
          <div className="md:col-span-3">
             <div className="flex items-center justify-between mb-8 border-b border-white/10 pb-4">
                <h2 className="text-2xl font-black tracking-tighter uppercase italic">Upcoming Experiences</h2>
             </div>
             
             {events.length === 0 ? (
                <div className="py-20 text-center border border-white/5 border-dashed">
                    <p className="text-white/30 text-sm font-black uppercase italic tracking-tighter">No upcoming events.</p>
                </div>
             ) : (
                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                   {events.map(event => (
                       <Link key={event.id} to={`/event/${event.id}`} className="bg-[#111111] border border-white/5 overflow-hidden group hover:border-brand-primary transition-colors">
                           <div className="aspect-video relative overflow-hidden">
                              <img src={event.image || 'https://images.unsplash.com/photo-1492684223066-81342ee5ff30'} alt={event.title} className="w-full h-full object-cover grayscale group-hover:grayscale-0 transition-all duration-700" />
                              <div className="absolute inset-0 bg-gradient-to-t from-black to-transparent opacity-80"></div>
                              <div className="absolute bottom-4 left-4 right-4">
                                 <h3 className="font-black text-2xl text-white uppercase italic tracking-tighter leading-none mb-1">{event.title}</h3>
                                 <p className="text-[9px] text-brand-primary font-black uppercase tracking-widest">{event.category || 'EVENT'}</p>
                              </div>
                           </div>
                           <div className="p-6">
                              <div className="flex items-center text-white/50 text-[10px] font-black uppercase tracking-tighter italic mb-2">
                                <Calendar className="w-3 h-3 mr-2 text-brand-primary" />
                                <span>{event.date ? formatInTz((event.date as any).toDate(), event.timezone, { dateStyle: 'medium' }) : 'Date TBD'}</span>
                              </div>
                              <div className="flex items-center text-white/50 text-[10px] font-black uppercase tracking-tighter italic pb-4 mb-4 border-b border-white/5">
                                <MapPin className="w-3 h-3 mr-2 text-brand-primary" />
                                <span className="line-clamp-1">{event.location}</span>
                              </div>
                              <div className="flex justify-between items-center">
                                 <span className="font-black text-xl text-white tracking-tighter">
                                    {event.ticketTiers?.length ? formatCurrency(Math.min(...event.ticketTiers.map(t => t.price))) : formatCurrency(event.price)}
                                 </span>
                                 <span className="text-[9px] font-black text-white/40 uppercase tracking-widest group-hover:text-brand-primary transition-colors">View Details</span>
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
