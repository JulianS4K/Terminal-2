// OrganizerEventReport — per-event analytics page.
//
// Lives at /dashboard/event/:eventId. Renders the per-event sales
// chart (full history mode), tier-by-tier breakdown, and promoter +
// channel attribution rollups. Owner / manager / finance / admin can
// view; scanner and content roles cannot (gated client-side; rules
// already restrict event reads to org staff for drafts and to public
// for published — but the analytics data lives in tickets which is
// already organizer-or-admin-only).

import { ReactNode, useEffect, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { motion } from 'motion/react';
import { ArrowLeft, BarChart3, DollarSign, Tag, Globe, Users, Ban } from 'lucide-react';
import { getEventForEdit } from '../lib/events';
import { listEventTickets, voidTicket } from '../lib/tickets';
import { Event, Ticket } from '../types';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useToast } from '../context/ToastContext';
import SalesChart from '../components/SalesChart';
import ScanReport from '../components/ScanReport';
import WaitlistPanel from '../components/WaitlistPanel';
import AnnouncementsPanel from '../components/AnnouncementsPanel';
import TierPricingPanel from '../components/TierPricingPanel';
import ReschedulePanel from '../components/ReschedulePanel';
import { formatCurrency } from '../lib/utils';

interface TierStat {
  tierId: string;
  tierName: string;
  count: number;
  revenue: number;
}

interface PromoterStat {
  promoterId: string;
  count: number;
  revenue: number;
}

interface ChannelStat {
  channel: string;
  count: number;
  revenue: number;
}

export default function OrganizerEventReport() {
  const { eventId } = useParams<{ eventId: string }>();
  const navigate = useNavigate();
  const { user, isAdmin } = useAuth();
  const { activeRole } = useOrganization();
  const { toast } = useToast();

  const [event, setEvent] = useState<Event | null>(null);
  const [tickets, setTickets] = useState<Ticket[]>([]);
  const [loading, setLoading] = useState(true);
  const [voidingId, setVoidingId] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      if (!eventId) return;
      setLoading(true);
      try {
        const [ev, ts] = await Promise.all([
          getEventForEdit(eventId),   // staff RLS on exos_events
          listEventTickets(eventId),  // staff RLS on exos_tickets
        ]);
        if (cancelled) return;
        if (ev) setEvent(ev);
        setTickets(ts);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, [eventId]);

  if (!user) {
    return (
      <div className="max-w-3xl mx-auto p-12 text-center text-slate-500">
        Sign in to view event analytics.
      </div>
    );
  }
  // Gate: only owner / manager / finance (or admin) see financials. NOTE:
  // canEditEvents() returns true for the 'content' role too, which wrongly
  // exposed the report to content staff — gate explicitly on the finance-capable
  // roles. (Column-scoping buyer_email/price_paid out of scanner/content at the
  // RLS layer is a tracked follow-up on the barcode-secret least-privilege
  // pattern from mig 20260702123000.) Falls back to legacy organizerId.
  const allowedByRole =
    isAdmin || activeRole === 'owner' || activeRole === 'manager' || activeRole === 'finance';
  const allowedByLegacy = event?.organizerId === user.uid;
  if (event && !allowedByRole && !allowedByLegacy) {
    return (
      <div className="max-w-3xl mx-auto p-12 text-center text-slate-500">
        You don't have access to this event's analytics.
      </div>
    );
  }
  if (loading || !event) {
    return (
      <div className="max-w-7xl mx-auto p-24 text-center text-slate-300 font-bold uppercase tracking-[0.3em] animate-pulse">
        Loading…
      </div>
    );
  }

  // Refund + void a single ticket. In Exos a voided ticket IS a
  // refunded ticket — this is the per-ticket refund control (the
  // event-level cancellation flow already exists for whole-event
  // refunds). Optimistic local update so the UI reflects the change
  // without re-fetching.
  //
  // Note: this flow does NOT issue a Stripe refund. The actual money
  // movement is a separate step the organizer arranges via their
  // Stripe dashboard. The void is sticky regardless: the ticket is
  // unscannable even if the refund hasn't cleared yet, which is the
  // important property for the door.
  const handleVoidTicket = async (ticket: Ticket) => {
    if (!user || !ticket || ticket.status !== 'active') return;
    const reason = window.prompt(
      `Refund / void ticket ${ticket.id.slice(0, 8)}? Provide a short reason (audit log).`,
      '',
    );
    if (reason === null) return;
    if (reason.length > 500) {
      toast({ kind: 'error', message: 'Reason too long (max 500 chars).' });
      return;
    }
    setVoidingId(ticket.id);
    try {
      // SECDEF RPC: gates on org-staff (owner/manager/finance) or admin,
      // refuses non-active tickets, and stamps voided_at/by/reason server-side.
      await voidTicket(ticket.id, reason.trim() || undefined);
      setTickets((prev) =>
        prev.map((t) => (t.id === ticket.id ? { ...t, status: 'voided' as const } : t)),
      );
      toast({
        kind: 'success',
        message:
          'Ticket voided. Issue the buyer a refund through your Stripe dashboard — the ticket is already unscannable.',
      });
    } catch (err) {
      console.error('Void failed:', err);
      toast({ kind: 'error', message: 'Could not void this ticket. Retry?' });
    } finally {
      setVoidingId(null);
    }
  };

  // Compute aggregates from the loaded ticket set. Voided tickets are
  // excluded from sold/revenue counts but kept in the attendees list
  // (greyed out) so the organizer can audit the void rationale.
  const activeTickets = tickets.filter(
    (t) => t.status !== 'cancelled' && t.status !== 'voided',
  );
  const totalSold = activeTickets.length;
  const totalRevenue = activeTickets.reduce((sum, t) => sum + (t.pricePaid || 0), 0);

  const tierMap = new Map<string, TierStat>();
  for (const t of activeTickets) {
    const tid = t.tierId || 'unknown';
    const existing = tierMap.get(tid) || {
      tierId: tid,
      tierName: t.tierName || 'Unknown',
      count: 0,
      revenue: 0,
    };
    existing.count += 1;
    existing.revenue += t.pricePaid || 0;
    tierMap.set(tid, existing);
  }
  const tierStats = Array.from(tierMap.values()).sort((a, b) => b.count - a.count);

  const promoterMap = new Map<string, PromoterStat>();
  for (const t of activeTickets) {
    if (!t.promoterId) continue;
    const existing = promoterMap.get(t.promoterId) || {
      promoterId: t.promoterId,
      count: 0,
      revenue: 0,
    };
    existing.count += 1;
    existing.revenue += t.pricePaid || 0;
    promoterMap.set(t.promoterId, existing);
  }
  const promoterStats = Array.from(promoterMap.values()).sort((a, b) => b.count - a.count);

  const channelMap = new Map<string, ChannelStat>();
  for (const t of activeTickets) {
    const ch = t.channelSource || 'vibepass';
    const existing = channelMap.get(ch) || { channel: ch, count: 0, revenue: 0 };
    existing.count += 1;
    existing.revenue += t.pricePaid || 0;
    channelMap.set(ch, existing);
  }
  const channelStats = Array.from(channelMap.values()).sort((a, b) => b.count - a.count);

  const checkedIn = activeTickets.filter((t) => t.status === 'used').length;
  const currency = event.currency || 'USD';

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="bg-[#f2f4f7] min-h-screen"
    >
      <div className="max-w-7xl mx-auto px-4 py-12">
        <button
          onClick={() => navigate('/dashboard')}
          className="flex items-center gap-2 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6 transition-all"
        >
          <ArrowLeft size={14} /> Back to dashboard
        </button>

        <div className="mb-10">
          <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">
            Event Report
          </p>
          <h1 className="text-3xl md:text-4xl font-bold tracking-tight text-slate-900">
            {event.title}
          </h1>
        </div>

        <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
          <Stat label="Tickets Sold" value={String(totalSold)} icon={<Users size={16} />} />
          <Stat
            label="Revenue"
            value={formatCurrency(totalRevenue, currency)}
            icon={<DollarSign size={16} />}
          />
          <Stat
            label="Checked In"
            value={`${checkedIn} / ${totalSold}`}
            icon={<BarChart3 size={16} />}
          />
          <Stat
            label="Capacity"
            value={`${event.totalTickets || 0}`}
            icon={<Tag size={16} />}
          />
        </div>

        {/* Sales over time — full history. Pre-event activity. */}
        <div className="mb-8">
          <SalesChart organizerId={null} eventId={eventId!} fullHistory={true} />
        </div>

        {/* Door-scan report — live during event day. Reads the
            exos_event_checkins audit log on a short poll so an organizer
            watching during the show sees scans roll in as staff check
            attendees in. Pairs with the sales chart above (pre-event)
            for the full event lifecycle. */}
        <div className="mb-8">
          <h2 className="text-sm font-bold text-slate-700 mb-3 mt-2">Door scans</h2>
          <ScanReport eventId={eventId!} totalSold={totalSold} />
        </div>

        {/* Reschedule — postpone/move the event + notify holders (owner/manager). */}
        <ReschedulePanel
          event={event}
          canManage={isAdmin || activeRole === 'owner' || activeRole === 'manager' || allowedByLegacy}
        />

        {/* Scheduled pricing — time-based price steps per tier (owner/manager). */}
        <TierPricingPanel
          event={event}
          canManage={isAdmin || activeRole === 'owner' || activeRole === 'manager' || allowedByLegacy}
        />

        {/* Waitlist — demand captured after sell-out; release spots to notify. */}
        <WaitlistPanel eventId={eventId!} />

        {/* Attendee updates — broadcast a message to ticket holders (email +
            in-app). Composer is owner/manager-only; the RPC re-checks server-side.
            Finance-capable viewers below (scanner/content can't reach this page)
            still see the sent history read-only. */}
        <AnnouncementsPanel
          eventId={eventId!}
          canSend={isAdmin || activeRole === 'owner' || activeRole === 'manager' || allowedByLegacy}
        />

        {/* Tier breakdown. */}
        <Section title="By Tier" empty="No tier breakdown yet — first sale populates this." rows={tierStats.length}>
          <Table
            cols={['Tier', 'Sold', 'Revenue']}
            rows={tierStats.map((t) => [t.tierName, String(t.count), formatCurrency(t.revenue, currency)])}
          />
        </Section>

        {/* Promoter / affiliate. */}
        <Section
          title="By Promoter"
          empty="No promoter-attributed sales yet. Buyers who arrive via ?promoter=X are counted here."
          rows={promoterStats.length}
        >
          <Table
            cols={['Promoter', 'Sold', 'Revenue']}
            rows={promoterStats.map((p) => [p.promoterId, String(p.count), formatCurrency(p.revenue, currency)])}
          />
        </Section>

        {/* Channel attribution — direct vs Lysted secondary channels. */}
        <Section
          title="By Channel"
          empty="All sales are direct so far."
          rows={channelStats.length}
        >
          <Table
            icon={<Globe size={14} />}
            cols={['Channel', 'Sold', 'Revenue']}
            rows={channelStats.map((c) => [c.channel, String(c.count), formatCurrency(c.revenue, currency)])}
          />
        </Section>

        {/* Attendees + per-ticket refund/void controls. Lists every
            ticket including voided ones (greyed out, with reason).
            For events at 250-1k tickets this list is fine; for larger
            shows we'd add pagination + search. */}
        <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
          <h3 className="text-sm font-bold text-slate-700 mb-1">Attendees</h3>
          <p className="text-xs text-slate-400 mb-4">
            "Refund / void" makes the ticket unscannable and shows "REFUNDED" on the buyer's wallet.
            Issue the actual refund through your Stripe dashboard separately.
          </p>
          {tickets.length === 0 ? (
            <p className="text-xs text-slate-400">No tickets sold yet.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
                    <th className="py-2 font-black">Ticket</th>
                    <th className="py-2 font-black">Tier</th>
                    <th className="py-2 font-black">Status</th>
                    <th className="py-2 font-black text-right">Action</th>
                  </tr>
                </thead>
                <tbody>
                  {tickets.map((t) => {
                    const isVoided = t.status === 'voided';
                    const isUsed = t.status === 'used';
                    const statusBadge = isVoided
                      ? { text: 'refunded', cls: 'bg-rose-50 text-rose-600 border-rose-200' }
                      : isUsed
                      ? { text: 'used', cls: 'bg-slate-100 text-slate-500 border-slate-200' }
                      : { text: 'active', cls: 'bg-emerald-50 text-emerald-700 border-emerald-200' };
                    return (
                      <tr
                        key={t.id}
                        className={`border-b border-slate-50 last:border-b-0 ${isVoided ? 'opacity-40' : ''}`}
                      >
                        <td className="py-2 text-slate-700 font-mono text-xs">{t.id.slice(0, 12)}…</td>
                        <td className="py-2 text-slate-700">{t.tierName || 'Standard'}</td>
                        <td className="py-2">
                          <span className={`inline-block px-2 py-0.5 text-[10px] font-bold uppercase tracking-widest border rounded-full ${statusBadge.cls}`}>
                            {statusBadge.text}
                          </span>
                          {isVoided && t.voidedReason ? (
                            <span className="block text-[10px] text-slate-400 italic mt-1">
                              {t.voidedReason}
                            </span>
                          ) : null}
                        </td>
                        <td className="py-2 text-right">
                          {t.status === 'active' ? (
                            <button
                              onClick={() => handleVoidTicket(t)}
                              disabled={voidingId === t.id}
                              className="inline-flex items-center gap-1 px-2 py-1 bg-rose-50 hover:bg-rose-100 text-rose-600 rounded text-[10px] font-bold uppercase tracking-widest border border-rose-200 disabled:opacity-40 transition-colors"
                            >
                              <Ban size={12} aria-hidden="true" />
                              {voidingId === t.id ? 'Voiding…' : 'Refund / Void'}
                            </button>
                          ) : (
                            <span className="text-[10px] text-slate-300 font-bold uppercase tracking-widest">—</span>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>
    </motion.div>
  );
}

function Stat({ label, value, icon }: { label: string; value: string; icon: ReactNode }) {
  return (
    <div className="bg-white p-5 rounded border border-slate-200 shadow-sm">
      <div className="flex justify-between items-start mb-3">
        <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest leading-none">{label}</p>
        <span className="text-slate-400">{icon}</span>
      </div>
      <p className="text-2xl font-bold text-slate-900 tracking-tight">{value}</p>
    </div>
  );
}

function Section({
  title,
  empty,
  rows,
  children,
}: {
  title: string;
  empty: string;
  rows: number;
  children: ReactNode;
}) {
  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <h3 className="text-sm font-bold text-slate-700 mb-3">{title}</h3>
      {rows === 0 ? (
        <p className="text-xs text-slate-400">{empty}</p>
      ) : (
        children
      )}
    </div>
  );
}

function Table({ cols, rows, icon }: { cols: string[]; rows: string[][]; icon?: ReactNode }) {
  return (
    <table className="w-full text-sm">
      <thead>
        <tr className="text-left text-[10px] font-black text-slate-400 uppercase tracking-widest border-b border-slate-100">
          {cols.map((c) => (
            <th key={c} className="py-2 font-black">{c}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {rows.map((row, i) => (
          <tr key={i} className="border-b border-slate-50 last:border-b-0">
            {row.map((cell, j) => (
              <td key={j} className="py-2 text-slate-700">
                {j === 0 && icon ? <span className="inline-flex items-center gap-2">{icon}{cell}</span> : cell}
              </td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  );
}
