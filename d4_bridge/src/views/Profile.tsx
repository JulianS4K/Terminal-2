import { useAuth } from '../context/AuthContext';
import { Settings } from 'lucide-react';
import { Link } from 'react-router-dom';

export default function Profile() {
  const { user } = useAuth();

  if (!user) {
    return (
      <div className="max-w-7xl mx-auto p-20 text-center font-bold text-white/40 type uppercase tracking-widest text-xs">
        Please sign in to view your profile.
      </div>
    );
  }

  const initial = (user.displayName?.charAt(0) || user.email?.charAt(0) || '?').toUpperCase();
  const displayName = (user.displayName || user.email?.split('@')[0] || 'Pass Holder');

  return (
    <div className="wall d4-grain min-h-screen text-white pb-20">
      {/* Bespoke film-grain overlay (from the Profile mockup; not in index.css). */}
      <style>{`
        .d4-grain::before {
          content: "";
          position: fixed;
          inset: 0;
          z-index: 1;
          pointer-events: none;
          opacity: .055;
          mix-blend-mode: overlay;
          background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='180' height='180'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
        }
      `}</style>

      <div className="max-w-4xl mx-auto px-4 py-12 relative z-10">

        {/* Header */}
        <div className="flex items-center gap-6 mb-12">
          <div className="w-24 h-24 bg-brand-primary flex items-center justify-center disp text-5xl text-black">
            {initial}
          </div>
          <div>
            <h1 className="disp text-4xl md:text-5xl tracking-tight leading-none uppercase" style={{ transform: 'skewX(-4deg)' }}>
              {displayName}
            </h1>
            <p className="type text-white/40 text-[10px] uppercase tracking-widest mt-2">pass holder // general access</p>
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-8">

          {/* Main Content */}
          <div className="md:col-span-2 space-y-8">

            {/* Following (Friends removed per Kanban) */}
            <div className="bg-[#111] border border-white/10 p-8">
              <h2 className="disp text-2xl md:text-3xl tracking-tight mb-6 uppercase" style={{ transform: 'skewX(-4deg)' }}>
                Following Organizers
              </h2>
              <div className="text-center py-14 border border-white/5 border-dashed">
                <p className="type text-white/30 mb-4 text-[13px] uppercase tracking-widest">your following list is empty</p>
                <Link
                  to="/"
                  className="disp inline-block px-6 py-2 bg-white text-black text-lg tracking-wide hover:bg-brand-primary transition-colors uppercase"
                >
                  Find Events
                </Link>
              </div>
            </div>

          </div>

          {/* Sidebar */}
          <div className="space-y-4">
            <Link to="/my-tickets" className="block w-full p-6 bg-brand-primary text-black hover:bg-white transition-colors group">
              <h3 className="disp text-2xl tracking-tight uppercase">My Vault</h3>
              <p className="type text-[10px] uppercase tracking-widest opacity-70 group-hover:opacity-100 transition-all">access your passes</p>
            </Link>

            <div className="bg-[#111] border border-white/10 p-6">
              <div className="flex items-center gap-2 mb-4 text-white/40">
                <Settings className="w-4 h-4" />
                <span className="type text-[10px] uppercase tracking-widest">settings</span>
              </div>
              <ul className="space-y-3">
                <li><button className="type text-[12px] uppercase tracking-widest text-white hover:text-brand-primary transition-colors">edit profile</button></li>
                <li><button className="type text-[12px] uppercase tracking-widest text-white hover:text-brand-primary transition-colors">payment methods</button></li>
                <li><button className="type text-[12px] uppercase tracking-widest text-white hover:text-brand-primary transition-colors">privacy</button></li>
              </ul>
            </div>
          </div>

        </div>

      </div>
    </div>
  );
}
