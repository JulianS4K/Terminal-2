import { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { db } from '../lib/firebase';
import { doc, getDoc, collection, query, where, getDocs, limit, updateDoc, arrayUnion, arrayRemove } from 'firebase/firestore';
import { Event } from '../types';
import { useAuth } from '../context/AuthContext';
import { motion } from 'motion/react';
import { MapPin, Calendar, CheckCircle2, UserPlus } from 'lucide-react';
import { formatCurrency } from '../lib/utils';
import { formatInTz } from '../lib/datetime';

export default function OrganizerProfile() {
  const { id } = useParams();
  const { user } = useAuth();
  const [organizer, setOrganizer] = useState<{ displayName: string; photoURL?: string; description?: string } | null>(null);
  const [events, setEvents] = useState<Event[]>([]);
  const [loading, setLoading] = useState(true);
  const [isFollowing, setIsFollowing] = useState(false);
  const [followersCount, setFollowersCount] = useState(0);

  useEffect(() => {
    async function fetchOrganizerAndEvents() {
      if (!id) return;
      try {
        const orgDoc = await getDoc(doc(db, 'users', id));
        if (orgDoc.exists()) {
          const orgData = orgDoc.data();
          setOrganizer({
            displayName: orgData.displayName || 'Anonymous Organizer',
            photoURL: orgData.photoURL,
            description: orgData.description || 'Creating unforgettable experiences.'
          });
          setFollowersCount(orgData.followersCount || 0);

          if (user) {
            const userDoc = await getDoc(doc(db, 'users', user.uid));
            if (userDoc.exists() && userDoc.data().followingOrganizers?.includes(id)) {
              setIsFollowing(true);
            }
          }
        } else {
           // Fallback for organizers who haven't set up a profile properly
           setOrganizer({ displayName: 'Organizer', description: 'Experience creator.' });
        }

        const eventsQ = query(collection(db, 'events'), where('organizerId', '==', id), limit(20));
        const eventsSnap = await getDocs(eventsQ);
        const eventsData = eventsSnap.docs.map(d => ({ id: d.id, ...d.data() } as Event));
        setEvents(eventsData.sort((a,b) => (b.date?.seconds || 0) - (a.date?.seconds || 0)));
      } catch (err) {
        console.error("Error fetching organizer details", err);
      } finally {
        setLoading(false);
      }
    }
    fetchOrganizerAndEvents();
  }, [id, user]);

  const toggleFollow = async () => {
    if (!user || !id) return;
    try {
       const userRef = doc(db, 'users', user.uid);
       const orgRef = doc(db, 'users', id);
       
       if (isFollowing) {
          setIsFollowing(false);
          setFollowersCount(prev => prev - 1);
          await updateDoc(userRef, { followingOrganizers: arrayRemove(id) });
          await updateDoc(orgRef, { followersCount: Math.max(0, followersCount - 1) });
       } else {
          setIsFollowing(true);
          setFollowersCount(prev => prev + 1);
          await updateDoc(userRef, { followingOrganizers: arrayUnion(id) });
          await updateDoc(orgRef, { followersCount: followersCount + 1 });
       }
    } catch (err) {
       console.error("Failed to follow", err);
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
