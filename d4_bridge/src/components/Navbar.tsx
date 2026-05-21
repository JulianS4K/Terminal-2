import { Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { Ticket, User, LogOut, PlusCircle, LayoutDashboard } from 'lucide-react';
import { motion } from 'motion/react';

export default function Navbar() {
  const { user, signIn, logout } = useAuth();

  return (
    <nav className="sticky top-0 z-50 bg-[#000000] border-b border-white/5 backdrop-blur-xl">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="flex justify-between h-24 items-center">
          <Link to="/" className="flex items-center space-x-2 group">
            <div className="w-12 h-12 bg-white flex items-center justify-center transition-all group-hover:bg-brand-primary">
              <Ticket className="text-black w-6 h-6" />
            </div>
            <span className="text-3xl font-black tracking-tighter text-white italic group-hover:text-neon transition-all">EXOS</span>
          </Link>

          <div className="flex items-center space-x-10">
            {user ? (
              <>
                <Link to="/my-tickets" className="text-[11px] font-black uppercase tracking-widest text-white/50 hover:text-white hover:italic transition-all">
                  My Tickets
                </Link>
                <Link to="/dashboard" className="text-[11px] font-black uppercase tracking-widest text-white/50 hover:text-white hover:italic transition-all flex items-center space-x-2">
                  <LayoutDashboard className="w-4 h-4 text-brand-primary" />
                  <span className="hidden sm:inline">Dashboard</span>
                </Link>
                <div className="relative group/user">
                  <button className="flex items-center space-x-3 bg-white/5 p-1 pr-6 border border-white/10 hover:border-white/20 transition-all">
                    <img src={user.photoURL || ''} alt="" className="w-10 h-10 grayscale group-hover/user:grayscale-0 transition-all border-r border-white/10" />
                    <span className="text-[10px] font-black text-white uppercase tracking-[0.2em] hidden sm:inline italic">0x{user.uid.slice(0, 4)}</span>
                  </button>
                  <div className="absolute right-0 mt-2 w-56 bg-[#111111] border border-white/10 opacity-0 invisible group-hover/user:opacity-100 group-hover/user:visible transition-all duration-300 py-2 origin-top-right shadow-2xl">
                    <div className="px-4 py-3 border-b border-white/5 mb-2">
                        <p className="text-[9px] font-black text-white/30 uppercase tracking-widest leading-none mb-1">Signed in as</p>
                        <p className="text-[11px] font-black text-white uppercase truncate italic">{user.displayName || user.email}</p>
                    </div>
                    <Link 
                      to="/profile"
                      className="w-full text-left px-4 py-4 text-[10px] font-black uppercase tracking-widest text-white/60 hover:text-white hover:bg-white/5 flex items-center space-x-3 transition-all"
                    >
                      <User className="w-4 h-4" />
                      <span>Profile & Tastes</span>
                    </Link>
                    <button 
                      onClick={logout}
                      className="w-full text-left px-4 py-4 text-[10px] font-black uppercase tracking-widest text-white/60 hover:text-brand-primary hover:bg-white/5 flex items-center space-x-3 transition-all"
                    >
                      <LogOut className="w-4 h-4" />
                      <span>Sign Out</span>
                    </button>
                  </div>
                </div>
              </>
            ) : (
              <button
                onClick={signIn}
                className="primary-button py-3 text-[10px] italic"
              >
                Sign In
              </button>
            )}
          </div>
        </div>
      </div>
    </nav>
  );
}
