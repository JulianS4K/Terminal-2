import { useEffect, useState } from 'react';
import { useLocation, useNavigate, Link } from 'react-router-dom';
import { Ticket, Event, Transfer } from '../types';
import { useAuth } from '../context/AuthContext';
import {
  listMyTickets,
  listInboundTransfers,
  listOutboundTransfers,
  cancelTransfer,
} from '../lib/tickets';
import { Ticket as TicketIcon, Calendar, ArrowRight, UserPlus, Mail } from 'lucide-react';
import { format } from 'date-fns';
import { formatInTz } from '../lib/datetime';
import { motion } from 'motion/react';
import { useToast } from '../context/ToastContext';

export default function MyTickets() {
  const { user } = useAuth();
  const location = useLocation();
  const navigate = useNavigate();
  const { toast } = useToast();
  const [tickets, setTickets] = useState<(Ticket & { event?: Event })[]>([]);
  const [groupedTickets, setGroupedTickets] = useState<{ [eventId: string]: (Ticket & { event?: Event })[] }>({});
  const [showReceipts, setShowReceipts] = useState<string | null>(null); // eventId
  const [pendingTransfers, setPendingTransfers] = useState<Transfer[]>([]);
  const [outboundTransfers, setOutboundTransfers] = useState<Transfer[]>([]);
  const [loading, setLoading] = useState(true);

  const handleCancelTransfer = async (transferId: string) => {
    // Confirmation lives outside the loading state so a user that backs out
    // doesn't see a brief loading flash.
    if (!window.confirm('Cancel this transfer? You will keep the ticket.')) return;
    try {
      // The RPC flips the transfer to 'cancelled' AND clears the ticket's
      // pendingTransferId lock atomically (server-side), so the wallet UI
      // and door-scan flow start honoring the ticket again immediately.
      await cancelTransfer(transferId);
      setOutboundTransfers((prev) => prev.filter((t) => t.id !== transferId));
      toast({ kind: 'success', message: 'Transfer cancelled.' });
    } catch (err) {
      console.error('Cancel transfer failed:', err);
      toast({ kind: 'error', message: 'Could not cancel the transfer.' });
    }
  };

  useEffect(() => {
    const params = new URLSearchParams(location.search);
    const sessionId = params.get('session_id');
    if (sessionId && user) {
      // Real Stripe fulfillment (server-side mint via webhook into
      // exos_tickets) is phase-2. Checkout is gated in EventDetails, so no
      // live Stripe session reaches this redirect yet — but if one ever does
      // (stale link, manual nav) we surface a clear message and strip the
      // param rather than silently doing nothing.
      toast({
        kind: 'info',
        message: 'Ticket purchase fulfillment is being wired up (phase-2).',
      });
      navigate('/my-tickets', { replace: true });
    }
  }, [location, user, navigate, toast]);

  useEffect(() => {
    if (!user) return undefined;
    let cancelled = false;

    const load = async () => {
      try {
        // Tickets (with event joined) + both pending-transfer directions.
        // The transfer rows carry denormalised event title/image, so no
        // ticket/event dereference is needed (the old Firestore N+1 is gone).
        const [ticketsWithEvents, inbound, outbound] = await Promise.all([
          listMyTickets(),
          listInboundTransfers(),
          listOutboundTransfers(),
        ]);
        if (cancelled) return;

        setTickets(ticketsWithEvents);

        const grouped = ticketsWithEvents.reduce((acc, t) => {
          if (!acc[t.eventId]) acc[t.eventId] = [];
          acc[t.eventId].push(t);
          return acc;
        }, {} as { [eventId: string]: (Ticket & { event?: Event })[] });

        // Sort each event's tickets so the scannable ones surface first.
        // Order: active+unlocked → in-transfer → used → voided, so the
        // cluster's "main" ticket (eventTickets[0]) is always usable at the
        // door even in a 4-pack with one claimed/used ticket mixed in.
        const sortRank = (t: Ticket & { event?: Event }) => {
          if (t.status === 'voided') return 3;
          if (t.status === 'used') return 2;
          if (t.pendingTransferId) return 1;
          return 0;
        };
        Object.values(grouped).forEach((arr) => arr.sort((a, b) => sortRank(a) - sortRank(b)));
        setGroupedTickets(grouped);

        setPendingTransfers(inbound);
        setOutboundTransfers(outbound);
      } catch (err) {
        if (!cancelled) {
          console.error('Failed to load tickets:', err);
          toast({ kind: 'error', message: 'Could not load your tickets.' });
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    };

    void load();
    return () => {
      cancelled = true;
    };
  }, [user, toast]);

  if (!user) return <div className="max-w-7xl mx-auto p-20 text-center font-bold text-slate-300 uppercase tracking-widest text-xs">Please sign in to access your secure vault.</div>;
  if (loading) return <div className="max-w-7xl mx-auto p-24 text-center text-slate-300 font-bold uppercase tracking-[0.3em] animate-pulse">Syncing Tickets...</div>;

  return (
    <div className="bg-[#000000] min-h-screen text-white">
      <div className="max-w-7xl mx-auto px-4 py-12">
        <div className="flex flex-col md:flex-row justify-between items-start md:items-end mb-16 gap-8">
          <div>
            <p className="text-brand-primary text-xs font-black uppercase tracking-widest italic mb-2">My Tickets</p>
            <h1 className="text-6xl font-black uppercase italic tracking-tighter leading-none">My Tickets</h1>
          </div>
          <div className="flex bg-white/5 p-1 border border-white/10 italic">
             <button className="px-8 py-3 text-[10px] font-black uppercase tracking-tighter bg-brand-primary text-black">ACTIVE</button>
             <button className="px-8 py-3 text-[10px] font-black uppercase tracking-tighter text-white/40 hover:text-white">ARCHIVE</button>
          </div>
        </div>

        {/* Transfer Notifications */}
        {(pendingTransfers.length > 0 || outboundTransfers.length > 0) && (
          <div className="mb-20 space-y-12">
            {pendingTransfers.length > 0 && (
              <div>
                <h2 className="text-xs font-black text-brand-primary uppercase tracking-tighter italic mb-8 flex items-center">
                  <div className="w-2 h-2 bg-brand-primary rounded-full mr-3 animate-ping"></div>
                  Incoming Tickets ({pendingTransfers.length})
                </h2>
                <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8">
                  {pendingTransfers.map((trans) => (
                    <div key={trans.id} className="bg-brand-primary p-8 border-4 border-brand-primary relative overflow-hidden group">
                       <div className="relative z-10">
                          <div className="flex items-center space-x-6 mb-8">
                             <div className="w-14 h-14 bg-black flex items-center justify-center">
                                <Mail className="text-brand-primary w-6 h-6" />
                             </div>
                             <div>
                                <p className="text-[10px] font-black text-black uppercase tracking-tighter italic leading-none mb-1">Reference ID: {trans.id.slice(0,6)}</p>
                                <h3 className="text-2xl font-black text-black uppercase italic tracking-tighter truncate max-w-[180px]">{trans.eventTitle}</h3>
                             </div>
                          </div>
                          <Link 
                            to={`/claim/${trans.id}`}
                            className="w-full bg-black text-white py-4 font-black uppercase tracking-tighter italic text-xs flex items-center justify-center space-x-2 hover:bg-white hover:text-black transition-all"
                          >
                            <span>Claim Ticket</span>
                          </Link>
                       </div>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {outboundTransfers.length > 0 && (
              <div>
                <h2 className="text-xs font-black text-white/30 uppercase tracking-tighter italic mb-8 flex items-center">
                  <div className="w-2 h-2 bg-white/20 rounded-full mr-3 animate-pulse"></div>
                  Pending Outbound Transfers ({outboundTransfers.length})
                </h2>
                <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8">
                  {outboundTransfers.map((trans) => (
                    <div key={trans.id} className="bg-[#111111] border border-white/10 p-8 relative overflow-hidden group">
                       <div className="relative z-10">
                          <div className="flex items-center space-x-6 mb-8">
                             <div className="w-14 h-14 bg-white/5 border border-white/10 flex items-center justify-center grayscale group-hover:grayscale-0 transition-all">
                                <Mail className="text-white/20 w-6 h-6 group-hover:text-brand-primary" />
                             </div>
                             <div>
                                <p className="text-[10px] font-black text-white/30 uppercase tracking-tighter italic leading-none mb-1">Transfer ID: {trans.id.slice(0,6)}</p>
                                <h3 className="text-2xl font-black text-white uppercase italic tracking-tighter truncate max-w-[180px]">{trans.eventTitle}</h3>
                                <p className="text-[9px] font-black text-brand-primary uppercase italic tracking-widest mt-1">To: {trans.receiverEmail.split('@')[0]}...</p>
                             </div>
                          </div>
                          <button
                            onClick={() => handleCancelTransfer(trans.id)}
                            className="w-full bg-white/5 border border-white/10 text-white/50 py-4 font-black uppercase tracking-tighter italic text-xs flex items-center justify-center space-x-2 hover:bg-white hover:text-black transition-all"
                          >
                            <span>Cancel Transfer</span>
                          </button>
                       </div>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        )}

        {tickets.length === 0 ? (
          <div className="text-center py-40 border border-dashed border-white/20">
            <TicketIcon className="w-24 h-24 text-white/5 mx-auto mb-10" />
            <p className="text-white/30 mb-12 font-black uppercase tracking-widest italic text-sm">You have no tickets yet.</p>
            <Link to="/" className="primary-button inline-flex items-center">
              Find Events
            </Link>
          </div>
        ) : (
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-px bg-white/10 border border-white/10">
            {Object.entries(groupedTickets).map(([eventId, tickets]) => {
              const eventTickets = tickets as (Ticket & { event?: Event })[];
              const mainTicket = eventTickets[0];
              const event = mainTicket.event;
              return (
                <motion.div
                  key={eventId}
                  className="bg-[#111111] group relative"
                >
                  <Link to={`/ticket/${mainTicket.id}`} className="block h-64 relative overflow-hidden">
                    <img 
                      src={event?.image || 'https://images.unsplash.com/photo-1492684223066-81342ee5ff30?q=80&w=600'} 
                      alt=""
                      className="w-full h-full object-cover grayscale group-hover:grayscale-0 transition-all duration-700"
                    />
                    <div className="absolute inset-0 bg-gradient-to-t from-[#111111] via-transparent to-transparent"></div>
                    <div className="absolute top-6 right-6 flex space-x-2">
                      <span className="bg-brand-primary text-black text-[10px] font-black px-3 py-1 uppercase tracking-tighter italic">
                        {eventTickets.length} {eventTickets.length === 1 ? 'PASS' : 'PASSES'}
                      </span>
                    </div>
                    <div className="absolute bottom-6 left-8 right-8">
                      <h3 className="text-white font-black text-3xl uppercase italic tracking-tighter leading-none group-hover:text-brand-primary transition-colors">{event?.title}</h3>
                    </div>
                  </Link>
                  
                  <div className="p-8">
                    <div className="flex justify-between items-end mb-10">
                      <div>
                        <p className="text-[10px] text-white/30 font-black uppercase tracking-tighter italic mb-1">Date</p>
                        <p className="text-sm font-black text-white italic uppercase tracking-tighter">{event?.date ? formatInTz(event.date.toDate(), event.timezone, { month: 'short', day: 'numeric', year: 'numeric' }) : 'N/A'}</p>
                      </div>
                      <div className="text-right">
                        <p className="text-[10px] text-white/30 font-black uppercase tracking-tighter italic mb-1">Pass Count</p>
                        <p className="text-sm font-black text-brand-primary italic uppercase tracking-tighter">{eventTickets.length} ACTIVE</p>
                      </div>
                    </div>

                    <div className="flex gap-4">
                      <Link 
                        to={`/ticket/${mainTicket.id}`}
                        className="flex-1 flex items-center justify-center bg-white text-black p-4 font-black uppercase tracking-tighter italic text-xs hover:bg-brand-primary transition-all"
                      >
                        <span>OPEN PASSES</span>
                      </Link>
                      <button 
                        onClick={() => setShowReceipts(eventId)}
                        className="flex-1 flex items-center justify-center border border-white/20 text-white/60 p-4 font-black uppercase tracking-tighter italic text-xs hover:border-white hover:text-white transition-all"
                      >
                        <span>RECEIPTS</span>
                      </button>
                    </div>
                  </div>

                  <div className="px-8 pb-8 flex items-center justify-between text-[9px] font-black text-white/10 uppercase italic tracking-widest">
                    <span>Cluster ID: {eventId.slice(0, 12)}</span>
                    <div className="flex space-x-1">
                      {[1,2,3,4,5].map(i => <div key={i} className="w-1 h-1 bg-white/5 rounded-full"></div>)}
                    </div>
                  </div>
                </motion.div>
              );
            })}
          </div>
        )}
      </div>

      {/* Receipts Modal */}
      {showReceipts && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
           <div className="absolute inset-0 bg-black/90" onClick={() => setShowReceipts(null)}></div>
           <div className="relative bg-[#111111] border border-white/10 w-full max-w-2xl max-h-[80vh] overflow-y-auto">
              <div className="p-8 border-b border-white/5 flex justify-between items-center bg-black">
                 <h2 className="text-xl font-black uppercase italic tracking-tighter">Purchase History</h2>
                 <button onClick={() => setShowReceipts(null)} className="text-white/40 hover:text-white font-black text-xs uppercase italic tracking-tighter">CLOSE [X]</button>
              </div>
              <div className="p-8 space-y-6">
                 {(() => {
                   const eventTickets = groupedTickets[showReceipts];
                   const receiptsMap = new Map<string, { tickets: typeof eventTickets, firstTicket: typeof eventTickets[0] }>();
                   eventTickets.forEach(t => {
                     const key = t.orderId || t.id;
                     if (!receiptsMap.has(key)) {
                        receiptsMap.set(key, { tickets: [], firstTicket: t });
                     }
                     receiptsMap.get(key)!.tickets.push(t);
                   });
                   return Array.from(receiptsMap.values()).map(({ tickets, firstTicket }) => (
                    <div key={firstTicket.id} className="bg-white/5 p-6 border border-white/10 flex flex-col md:flex-row justify-between items-start md:items-center gap-6 group hover:border-brand-primary transition-all">
                       <div>
                          <p className="text-[10px] text-brand-primary font-black uppercase tracking-tighter italic mb-1">Receipt ID: {firstTicket.orderId?.slice(0, 8) || 'LEGACY_SYNC'}</p>
                          <h4 className="text-lg font-black uppercase italic tracking-tighter text-white">
                             {firstTicket.tierName || 'GENERAL'} <span className="text-white/40 text-sm ml-2">× {tickets.length}</span>
                          </h4>
                          <p className="text-[10px] text-white/40 font-bold uppercase tracking-widest mt-1">{firstTicket.purchaseDate ? format(firstTicket.purchaseDate.toDate(), 'PPP p') : 'N/A'}</p>
                       </div>
                       <div className="flex items-center space-x-4 w-full md:w-auto">
                          <Link 
                            to={`/ticket/${firstTicket.id}`}
                            className="flex-1 md:flex-none px-6 py-3 bg-white text-black text-[10px] font-black uppercase italic tracking-tighter hover:bg-brand-primary transition-all text-center"
                          >
                            OPEN PASSES
                          </Link>
                       </div>
                    </div>
                   ));
                 })()}
              </div>
           </div>
        </div>
      )}
   </div>
  );
}
