import { TicketIcon, Twitter, Github, Instagram, ArrowUpRight } from 'lucide-react';
import { Link } from 'react-router-dom';

export default function Footer() {
  return (
    <footer className="bg-white text-slate-900 border-t border-slate-100 pt-20 pb-10 mt-20 relative z-10">
      <div className="max-w-7xl mx-auto px-4">
        <div className="grid grid-cols-1 md:grid-cols-4 gap-10 mb-14">
          <div className="col-span-1 md:col-span-1">
            <Link to="/" className="flex items-center gap-2 mb-5 group">
              <div className="w-9 h-9 bg-slate-900 rounded-xl flex items-center justify-center">
                <TicketIcon className="text-white w-5 h-5" />
              </div>
              <span className="disp text-2xl leading-none pt-1 text-slate-900">EXOS</span>
            </Link>
            <p className="text-slate-500 text-sm font-medium leading-relaxed mb-6">
              The standard for secure digital entry. We leverage encrypted rotating tokens to eliminate ticket fraud and scalping.
            </p>
            <div className="flex gap-6">
              <Twitter className="w-5 h-5 text-slate-300 hover:text-slate-900 cursor-pointer transition-colors" />
              <Instagram className="w-5 h-5 text-slate-300 hover:text-slate-900 cursor-pointer transition-colors" />
              <Github className="w-5 h-5 text-slate-300 hover:text-slate-900 cursor-pointer transition-colors" />
            </div>
          </div>

          <div>
            <h4 className="text-[10px] font-bold text-slate-400 uppercase tracking-[0.2em] mb-4">Platform</h4>
            <ul className="space-y-3">
              <li><Link to="/" className="text-slate-500 text-sm font-medium hover:text-slate-900 transition-colors">Discover Events</Link></li>
              <li><Link to="/my-tickets" className="text-slate-500 text-sm font-medium hover:text-slate-900 transition-colors">My Tickets</Link></li>
              <li><Link to="/dashboard" className="text-slate-500 text-sm font-medium hover:text-slate-900 transition-colors">Organizer Dashboard</Link></li>
            </ul>
          </div>

          <div>
            <h4 className="text-[10px] font-bold text-slate-400 uppercase tracking-[0.2em] mb-4">Trust &amp; Safety</h4>
            <ul className="space-y-3">
              <li><a href="#" className="text-slate-500 text-sm font-medium hover:text-slate-900 transition-colors">Security</a></li>
              <li><a href="#" className="text-slate-500 text-sm font-medium hover:text-slate-900 transition-colors">Transfers</a></li>
              <li><a href="#" className="text-slate-500 text-sm font-medium hover:text-slate-900 transition-colors">Safety</a></li>
            </ul>
          </div>

          <div>
            <h4 className="text-[10px] font-bold text-slate-400 uppercase tracking-[0.2em] mb-4">Support</h4>
            <ul className="space-y-3">
              <li><a href="#" className="text-slate-500 text-sm font-medium hover:text-slate-900 transition-colors">Help Center</a></li>
              <li><a href="#" className="text-slate-500 text-sm font-medium hover:text-slate-900 transition-colors">Contact Us</a></li>
              <li><a href="#" className="text-slate-500 text-sm font-medium hover:text-slate-900 transition-colors">API Docs</a></li>
            </ul>
          </div>
        </div>

        <div className="pt-6 border-t border-slate-100 flex flex-col md:flex-row justify-between items-center gap-4">
          <p className="text-[10px] text-slate-300 font-bold uppercase tracking-widest leading-none">
            © {new Date().getFullYear()} EXOS TECHNOLOGIES • SECURE TICKETING
          </p>
          <div className="flex gap-6">
            <Link to="/privacy" className="text-[10px] text-slate-300 font-bold uppercase tracking-widest hover:text-slate-900 transition-colors">Privacy</Link>
            <Link to="/terms" className="text-[10px] text-slate-300 font-bold uppercase tracking-widest hover:text-slate-900 transition-colors">Terms</Link>
            <Link to="/status" className="text-[10px] text-slate-300 font-bold uppercase tracking-widest hover:text-slate-900 transition-colors">System Status</Link>
          </div>
        </div>
      </div>
    </footer>
  );
}
