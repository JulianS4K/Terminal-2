import { Link } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import { Ticket, User, LogOut, PlusCircle, LayoutDashboard, Bell } from 'lucide-react';
import { motion } from 'motion/react';
import { useT } from '../context/LanguageContext';
import LanguageSwitcher from './LanguageSwitcher';

export default function Navbar() {
  const { user, signIn, logout } = useAuth();
  const t = useT();

  return (
    <nav className="sticky top-0 z-50 bg-black/90 border-b border-white/10 backdrop-blur-xl">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="flex justify-between h-20 items-center">
          <Link to="/" className="flex items-center gap-3 group">
            <div className="w-11 h-11 bg-white flex items-center justify-center transition-colors group-hover:bg-brand-primary">
              <Ticket className="text-black w-6 h-6" />
            </div>
            <span className="disp text-4xl tracking-tight text-white leading-none pt-1 group-hover:neon transition-all" style={{ transform: 'skewX(-6deg)' }}>EXOS</span>
          </Link>

          <div className="flex items-center gap-5 sm:gap-8">
            <LanguageSwitcher />
            {user ? (
              <>
                <Link to="/my-tickets" className="type text-[12px] uppercase tracking-widest text-white/60 hover:text-brand-primary transition-colors">
                  {t('nav.myTickets')}
                </Link>
                <Link to="/dashboard" className="type text-[12px] uppercase tracking-widest text-white/60 hover:text-brand-primary transition-colors hidden sm:flex items-center gap-2">
                  <LayoutDashboard className="w-4 h-4 text-brand-primary" />
                  <span>{t('nav.dashboard')}</span>
                </Link>
                <Link
                  to="/alerts"
                  aria-label="Alerts"
                  className="text-white/60 hover:text-brand-primary transition-colors"
                >
                  <Bell className="w-5 h-5" />
                </Link>
                <div className="relative group/user">
                  <button className="flex items-center gap-3 bg-white/5 p-1 pr-5 border border-white/10 hover:border-brand-primary/60 transition-colors">
                    <img src={user.photoURL || ''} alt="" className="w-9 h-9 grayscale group-hover/user:grayscale-0 transition-all border-r border-white/10" />
                    <span className="type text-[11px] text-white uppercase tracking-widest hidden sm:inline">0x{user.uid.slice(0, 4)}</span>
                  </button>
                  <div className="absolute right-0 mt-2 w-56 bg-[#0e0e0e] border border-white/10 opacity-0 invisible group-hover/user:opacity-100 group-hover/user:visible transition-all duration-300 py-2 origin-top-right shadow-2xl">
                    <div className="px-4 py-3 border-b border-white/10 mb-2">
                        <p className="type text-[9px] text-white/30 uppercase tracking-widest leading-none mb-1">Signed in as</p>
                        <p className="disp text-lg text-white uppercase truncate tracking-wide leading-none">{user.displayName || user.email}</p>
                    </div>
                    <Link
                      to="/profile"
                      className="w-full text-left px-4 py-3.5 type text-[11px] uppercase tracking-widest text-white/60 hover:text-brand-primary hover:bg-white/5 flex items-center gap-3 transition-colors"
                    >
                      <User className="w-4 h-4" />
                      <span>{t('nav.profile')}</span>
                    </Link>
                    <button
                      onClick={logout}
                      className="w-full text-left px-4 py-3.5 type text-[11px] uppercase tracking-widest text-white/60 hover:text-brand-accent hover:bg-white/5 flex items-center gap-3 transition-colors"
                    >
                      <LogOut className="w-4 h-4" />
                      <span>{t('nav.signOut')}</span>
                    </button>
                  </div>
                </div>
              </>
            ) : (
              <button
                onClick={signIn}
                className="disp text-lg bg-brand-primary text-black px-5 py-1 hover:scale-[1.03] transition-transform tracking-wide"
              >
                {t('nav.signIn')}
              </button>
            )}
          </div>
        </div>
      </div>
    </nav>
  );
}
