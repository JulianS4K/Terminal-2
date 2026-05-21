import { useAuth } from '../context/AuthContext';
import { Settings } from 'lucide-react';
import { Link } from 'react-router-dom';

export default function Profile() {
  const { user } = useAuth();

  if (!user) {
    return (
      <div className="max-w-7xl mx-auto p-20 text-center font-bold text-slate-300 uppercase tracking-widest text-xs">
        Please sign in to view your profile.
      </div>
    );
  }

  return (
    <div className="bg-[#000000] min-h-screen text-white pb-20">
      <div className="max-w-4xl mx-auto px-4 py-12">
        
        {/* Header */}
        <div className="flex items-center space-x-6 mb-12">
          <div className="w-24 h-24 bg-brand-primary flex items-center justify-center text-4xl font-black text-black uppercase italic">
            {user.displayName?.charAt(0) || user.email?.charAt(0) || '?'}
          </div>
          <div>
            <h1 className="text-4xl font-black tracking-tighter uppercase italic">{user.displayName || user.email?.split('@')[0]}</h1>
            <p className="text-white/40 text-[10px] uppercase font-black tracking-widest mt-1">Pass Holder // General Access</p>
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
          
          {/* Main Content */}
          <div className="md:col-span-2 space-y-8">
            
            {/* Following (Friends removed per Kanban) */}
            <div className="bg-[#111111] border border-white/10 p-8">
               <h2 className="text-2xl font-black tracking-tighter uppercase italic mb-6">Following Organizers</h2>
               
               <div className="text-center py-12 border border-white/5 border-dashed">
                 <p className="text-white/30 mb-4 text-sm font-black uppercase italic tracking-tighter">Your following list is empty.</p>
                 <Link to="/" className="inline-block px-6 py-2 bg-white text-black text-[10px] uppercase font-black tracking-widest hover:bg-brand-primary transition-all">
                   Find Events
                 </Link>
               </div>
            </div>

          </div>

          {/* Sidebar */}
          <div className="space-y-4">
             <Link to="/my-tickets" className="block w-full p-6 bg-brand-primary text-black hover:bg-white transition-all group">
               <h3 className="font-black text-xl uppercase italic tracking-tighter">My Vault</h3>
               <p className="text-[10px] font-bold uppercase tracking-widest opacity-60 group-hover:opacity-100 transition-all">Access your passes</p>
             </Link>
             
             <div className="bg-[#111111] border border-white/10 p-6">
                <div className="flex items-center space-x-2 mb-4 text-white/40">
                  <Settings className="w-4 h-4" />
                  <span className="text-[10px] uppercase font-black tracking-widest">Settings</span>
                </div>
                <ul className="space-y-3">
                  <li><button className="text-xs font-bold uppercase tracking-widest text-white hover:text-brand-primary transition-all">Edit Profile</button></li>
                  <li><button className="text-xs font-bold uppercase tracking-widest text-white hover:text-brand-primary transition-all">Payment Methods</button></li>
                  <li><button className="text-xs font-bold uppercase tracking-widest text-white hover:text-brand-primary transition-all">Privacy</button></li>
                </ul>
             </div>
          </div>

        </div>

      </div>
    </div>
  );
}
