// Notifications — the /alerts feed. Punk "// what you missed" design from the
// Exos set. Backed by real transfer signals via lib/notifications.ts (no faked
// items); event-side alerts (reminders/drops/price steps) will merge in as
// those get a backend. Read-state is client-only for now (mark-all-read).

import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Ticket, ArrowLeftRight, Bell, Zap, DollarSign, ChevronRight } from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import {
  listNotifications,
  listReadNotificationIds,
  markNotificationsRead,
  NotificationItem,
  NotificationIcon,
} from '../lib/notifications';
import { applyMeta } from '../lib/meta';

const ICONS: Record<NotificationIcon, typeof Ticket> = {
  transfer: ArrowLeftRight,
  ticket: Ticket,
  reminder: Bell,
  drop: Zap,
  price: DollarSign,
};

const TABS: [string, string][] = [
  ['all', 'All'],
  ['tickets', 'Tickets'],
  ['events', 'Events'],
];

function relTime(ms: number): string {
  if (!ms) return '';
  const s = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (s < 60) return 'now';
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h`;
  const d = Math.floor(h / 24);
  return `${d}d`;
}

export default function Notifications() {
  const { user, signIn } = useAuth();
  const [items, setItems] = useState<NotificationItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [tab, setTab] = useState('all');
  // Client-only read state (no server read-state yet): ids the user has cleared.
  const [readIds, setReadIds] = useState<Set<string>>(new Set());

  useEffect(() => {
    applyMeta({ title: 'Alerts', description: 'What you missed on Exos.' });
  }, []);

  useEffect(() => {
    let cancelled = false;
    if (!user) {
      setLoading(false);
      return undefined;
    }
    setLoading(true);
    // Load the feed and the server-side read-state in parallel. The read-state
    // is best-effort (empty Set until mig 20260709120000 is applied) and is
    // unioned with any read ids the user cleared locally this session.
    Promise.all([listNotifications(), listReadNotificationIds()])
      .then(([list, serverRead]) => {
        if (cancelled) return;
        setItems(list);
        setReadIds((prev) => new Set([...prev, ...serverRead]));
      })
      .catch((err) => console.error('Failed to load notifications', err))
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [user]);

  const isUnread = (n: NotificationItem) => n.unread && !readIds.has(n.id);

  const visible = useMemo(
    () => items.filter((n) => tab === 'all' || n.category === tab),
    [items, tab],
  );

  const markAll = () => {
    const ids = items.map((n) => n.id);
    setReadIds(new Set(ids));
    markNotificationsRead(ids);
  };

  if (!user) {
    return (
      <div className="wall min-h-[80vh] flex flex-col items-center justify-center text-center px-6">
        <h1 className="disp text-4xl md:text-5xl tracking-tight mb-4" style={{ transform: 'skewX(-4deg)' }}>
          SIGN IN FOR <span className="neon">ALERTS</span>
        </h1>
        <p className="type text-white/55 mb-8 max-w-sm">
          Your transfers, drops, and reminders live here once you're on the list.
        </p>
        <button
          onClick={signIn}
          className="disp bg-brand-primary text-black px-7 py-3 text-lg tracking-wide hover:scale-[1.02] transition-transform"
        >
          SIGN IN
        </button>
      </div>
    );
  }

  return (
    <div className="wall min-h-screen">
      <div className="max-w-2xl mx-auto px-4 py-10">
        <div className="flex items-end justify-between mb-8">
          <div>
            <p className="type text-brand-primary text-xs tracking-[0.3em] uppercase mb-2">// what you missed</p>
            <h1 className="disp text-5xl md:text-6xl leading-none" style={{ transform: 'skewX(-4deg)' }}>
              ALERTS
            </h1>
          </div>
          {items.some(isUnread) && (
            <button
              onClick={markAll}
              className="type text-[11px] uppercase tracking-widest text-white/40 hover:text-brand-primary"
            >
              Mark all read
            </button>
          )}
        </div>

        {/* Tabs */}
        <div className="flex gap-2 mb-6">
          {TABS.map(([k, label]) => {
            const on = k === tab;
            const unread = items.filter((n) => isUnread(n) && (k === 'all' || n.category === k)).length;
            return (
              <button
                key={k}
                onClick={() => setTab(k)}
                className={`type text-[11px] uppercase tracking-widest px-3.5 py-2 border transition-colors ${
                  on ? 'border-brand-primary text-brand-primary' : 'border-white/12 text-white/40 hover:text-white'
                }`}
              >
                {label}
                {unread > 0 && <span className="text-brand-secondary"> {unread}</span>}
              </button>
            );
          })}
        </div>

        {/* Feed */}
        {loading ? (
          <div className="text-center text-white/40 py-20 type uppercase tracking-[0.3em] animate-pulse">
            Loading…
          </div>
        ) : visible.length === 0 ? (
          <div className="border border-white/10 bg-[#0d0d0d] p-12 text-center">
            <p className="disp text-2xl tracking-tight mb-2">ALL CLEAR</p>
            <p className="type text-white/45 text-sm">
              {tab === 'events'
                ? 'No event alerts yet — follow organizers to hear about drops.'
                : "You're all caught up. Nothing new here."}
            </p>
          </div>
        ) : (
          <div className="space-y-2">
            {visible.map((n) => {
              const Icon = ICONS[n.icon];
              const unread = isUnread(n);
              return (
                <Link
                  key={n.id}
                  to={n.to}
                  onClick={() => {
                    setReadIds((prev) => new Set(prev).add(n.id));
                    markNotificationsRead([n.id]);
                  }}
                  className={`flex gap-4 p-4 border transition-colors group ${
                    unread ? 'border-white/15 bg-[#0d0d0d]' : 'border-white/5 bg-transparent'
                  } hover:border-white/30`}
                >
                  {unread ? (
                    <span className="w-1.5 h-1.5 rounded-full bg-brand-primary mt-2.5 shrink-0" />
                  ) : (
                    <span className="w-1.5 shrink-0" />
                  )}
                  <div
                    className="w-10 h-10 flex items-center justify-center shrink-0"
                    style={{ background: `${n.tone}1a`, border: `1px solid ${n.tone}40` }}
                  >
                    <Icon className="w-5 h-5" style={{ color: n.tone }} />
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-baseline gap-2">
                      <p className={`font-bold text-[15px] ${unread ? 'text-white' : 'text-white/70'}`}>
                        {n.title}
                      </p>
                      <span className="type text-[10px] text-white/30 ml-auto shrink-0">{relTime(n.ts)}</span>
                    </div>
                    <p className="text-white/50 text-sm mt-0.5">{n.body}</p>
                  </div>
                  <ChevronRight className="w-4 h-4 text-white/20 self-center group-hover:text-brand-primary shrink-0" />
                </Link>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}
