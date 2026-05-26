import { useEffect, useState, useRef } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { getTicket, listMyTicketsForEvent } from '../lib/tickets';
import { Ticket, Event } from '../types';
import { useAuth } from '../context/AuthContext';
import { QRCodeSVG } from 'qrcode.react';
import { publicUrl } from '../lib/utils';
import { ArrowLeft, Share2, ShieldCheck, RefreshCw, Ticket as TicketIcon, Calendar, Download, PlusCircle, Instagram, Send, ChevronLeft, ChevronRight, Smartphone } from 'lucide-react';
import { formatInTz } from '../lib/datetime';
import { signBarcode, currentBucket } from '../lib/barcode';
import { motion, AnimatePresence } from 'motion/react';
import { downloadIcsFile } from '../lib/calendarUtils';
import { useToast } from '../context/ToastContext';
import ShareModal from '../components/ShareModal';

export default function TicketDetail() {
  const { id } = useParams();
  const { user } = useAuth();
  const navigate = useNavigate();
  const { toast } = useToast();
  const [tickets, setTickets] = useState<Ticket[]>([]);
  const [currentIndex, setCurrentIndex] = useState(0);
  const [event, setEvent] = useState<Event | null>(null);
  const [loading, setLoading] = useState(true);
  const [barcode, setBarcode] = useState('');
  const [timeLeft, setTimeLeft] = useState(30);
  const [showShare, setShowShare] = useState(false);

  useEffect(() => {
    async function fetchData() {
      if (!id || !user) return;
      try {
        const ticketData = await getTicket(id);
        if (ticketData) {
          // getTicket joins the event in one round-trip.
          if (ticketData.event) setEvent(ticketData.event);

          // All tickets for this event owned by the user (the carousel).
          const allTickets = await listMyTicketsForEvent(ticketData.eventId);

          // Sort so scannable tickets (active + unlocked) come first.
          // A buyer with a 4-pack that includes one in-transfer or one
          // already-redeemed shouldn't see the locked one as the first
          // pass on the screen — they'll panic. Order: active+unlocked
          // → in-transfer → used → voided.
          const sortRank = (t: Ticket) => {
            if (t.status === 'voided') return 3;
            if (t.status === 'used') return 2;
            if ((t as any).pendingTransferId) return 1;
            return 0;
          };
          const sorted = [...allTickets].sort((a, b) => sortRank(a) - sortRank(b));
          setTickets(sorted);

          // Default the carousel to the URL-matched ticket if it's
          // scannable; otherwise jump to the first scannable ticket
          // in the sorted list. Falls through to index 0 (the URL
          // ticket itself) if literally no ticket is scannable —
          // better than landing on a random one.
          const urlIdx = sorted.findIndex(t => t.id === id);
          const urlTicket = urlIdx !== -1 ? sorted[urlIdx] : null;
          const isScannable = (t: Ticket) =>
            t.status === 'active' && !(t as any).pendingTransferId;
          if (urlTicket && isScannable(urlTicket)) {
            setCurrentIndex(urlIdx);
          } else {
            const firstScannable = sorted.findIndex(isScannable);
            setCurrentIndex(
              firstScannable !== -1
                ? firstScannable
                : (urlIdx !== -1 ? urlIdx : 0),
            );
          }
        }
      } catch (err) {
        console.error(err);
      } finally {
        setLoading(false);
      }
    }
    fetchData();
  }, [id, user]);

  // Depend on the current ticket's PRIMITIVE fields, not the whole array, so a
  // refetch that replaces `tickets` with equal-id objects doesn't re-run this
  // and reset the countdown. The QR is always valid (derived from wall-clock),
  // but the visible timer was misleadingly resetting.
  const td_id = tickets[currentIndex]?.id;
  const td_secret = tickets[currentIndex]?.barcodeSecret;
  const td_uid = user?.uid;
  useEffect(() => {
    if (!td_id || !td_uid) return undefined;
    let cancelled = false;
    let lastBucket = -1;

    // Sign the barcode for the current 30-second bucket. The HMAC binds
    // ticketId + ownerId + bucket against the per-ticket secret (lib/barcode.ts).
    // Legacy tickets without a secret fall back to the unsigned 3-segment shape.
    const refresh = async () => {
      const bucket = currentBucket();
      lastBucket = bucket;
      if (td_secret) {
        try {
          const signed = await signBarcode(td_id, td_uid, td_secret, bucket);
          if (!cancelled) setBarcode(signed);
          return;
        } catch (err) {
          console.warn('Falling back to legacy unsigned barcode:', err);
        }
      }
      if (!cancelled) setBarcode(`T-${td_id}:${td_uid}:${bucket}`);
    };

    const tick = () => {
      if (cancelled) return;
      // Wall-clock countdown — accurate across re-renders + background-tab
      // timer throttling (a naive decrement drifts when the tab is hidden).
      const secs = 30 - (Math.floor(Date.now() / 1000) % 30);
      setTimeLeft(secs === 0 ? 30 : secs);
      if (currentBucket() !== lastBucket) void refresh();
    };

    void refresh();
    const interval = setInterval(tick, 1000);
    // Re-issue immediately on tab-return so a throttled background timer never
    // leaves a stale (expired-bucket) QR on screen at the door.
    const onVisible = () => {
      if (document.visibilityState === 'visible') {
        void refresh();
        tick();
      }
    };
    document.addEventListener('visibilitychange', onVisible);

    return () => {
      cancelled = true;
      clearInterval(interval);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [td_id, td_secret, td_uid]);

  const nextTicket = () => {
    if (currentIndex < tickets.length - 1) {
      setCurrentIndex(prev => prev + 1);
    }
  };

  const prevTicket = () => {
    if (currentIndex > 0) {
      setCurrentIndex(prev => prev - 1);
    }
  };

  if (loading) return <div className="max-w-2xl mx-auto p-20 text-center text-gray-500">Loading ticket...</div>;
  if (!tickets.length || !event) {
    return <div className="max-w-2xl mx-auto p-20 text-center text-red-500">Access Denied: No tickets found.</div>;
  }

  const currentTicket = tickets[currentIndex];
  const handleInstagramStory = async () => {
    try {
      await navigator.clipboard.writeText(publicUrl(`event/${event.id}`));
      toast({ kind: 'success', message: 'Event link copied — paste it into your Story.' });
    } catch (err) {
      console.error('Story share failed:', err);
      toast({ kind: 'error', message: 'Could not copy link.' });
    }
  };

  const handleSMSShare = () => {
    const text = `I just secured tickets for ${event.title}! Join me: ${publicUrl(`event/${event.id}`)}`;
    window.location.href = `sms:?&body=${encodeURIComponent(text)}`;
  };

  return (
    <div className="bg-[#000000] min-h-screen text-white">
      <div className="max-w-2xl mx-auto px-4 py-12">
        <button onClick={() => navigate('/my-tickets')} className="flex items-center text-white/50 hover:text-white mb-16 transition-colors font-black uppercase tracking-tighter italic text-xs">
          <ArrowLeft className="w-4 h-4 mr-2 text-brand-primary" />
          Back to Tickets
        </button>

        <div className="relative">
          <AnimatePresence mode="wait">
            <motion.div
              key={currentTicket.id}
              initial={{ opacity: 0, x: 20 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0, x: -20 }}
              className="bg-[#111111] border border-white/10 shadow-2xl relative overflow-hidden"
            >
              {/* Top Branding Section */}
              <div className="p-10 pb-20 bg-brand-primary text-black">
                 <div className="flex justify-between items-start mb-12">
                    <div className="flex flex-col">
                      <p className="text-[10px] font-black uppercase tracking-tighter italic leading-none">PASS {currentIndex + 1} OF {tickets.length}</p>
                      <p className="text-[9px] font-bold uppercase tracking-[0.2em] mt-1 opacity-50">{currentTicket.tierName}</p>
                    </div>
                    <div className="w-1.5 h-1.5 bg-black rounded-full animate-pulse"></div>
                 </div>
                 <h1 className="text-5xl font-black uppercase italic tracking-tighter leading-none mb-4">{event.title}</h1>
                 <p className="text-black/60 font-black uppercase tracking-widest text-[10px] italic">{event.category} // {event.location}</p>
              </div>

              <div className="-mt-12 px-10 relative z-20">
                 <div className="bg-white p-10 shadow-2xl flex flex-col items-center justify-center group mb-12 relative">
                    <div className={`relative p-6 bg-white border-2 border-black transition-transform duration-500 flex flex-col items-center ${currentTicket.status === 'used' || currentTicket.status === 'voided' || (currentTicket as any).pendingTransferId ? 'opacity-20 grayscale' : 'group-hover:scale-[1.02]'}`}>
                      <QRCodeSVG value={barcode} size={220} level="H" includeMargin={false} fgColor="#000000" />
                      <div className="mt-6 w-full text-center border-t-2 border-dashed border-black/20 pt-6 space-y-2">
                        <div>
                          <p className="text-[9px] font-black uppercase tracking-widest text-black/40">Event</p>
                          <p className="text-sm font-black uppercase tracking-tighter leading-tight">{event.title}</p>
                        </div>
                        <div className="flex justify-between items-end text-left pt-2">
                           <div>
                             <p className="text-[9px] font-black uppercase tracking-widest text-black/40">Pass Holder</p>
                             <p className="text-xs font-black uppercase tracking-tighter leading-tight overflow-hidden text-ellipsis whitespace-nowrap max-w-[120px]">{user.displayName || user.email || 'Guest'}</p>
                           </div>
                           <div className="text-right">
                             <p className="text-[9px] font-black uppercase tracking-widest text-black/40">Pass ID</p>
                             <p className="text-xs font-black uppercase tracking-tighter leading-tight font-mono">{currentTicket.id}</p>
                           </div>
                        </div>
                      </div>
                      <div className="absolute -top-3 -right-3 w-10 h-10 bg-brand-primary flex items-center justify-center border-4 border-white">
                         <div className="w-2.5 h-2.5 bg-black rounded-full animate-ping"></div>
                      </div>
                    </div>

                    {currentTicket.status === 'used' ? (
                       <div className="absolute inset-0 flex flex-col items-center justify-center z-30">
                          <div className="bg-red-600 text-white px-8 py-3 font-black text-2xl uppercase italic tracking-tighter -rotate-12 shadow-2xl skew-x-12">
                             ENTERED
                          </div>
                          <p className="text-black font-black text-[10px] uppercase tracking-widest mt-4 bg-white px-3 py-1">
                             {currentTicket.checkInDate ? `Scanned ${formatInTz(currentTicket.checkInDate.toDate(), event.timezone, { hour: '2-digit', minute: '2-digit', month: 'short', day: 'numeric' })}` : 'SCANNED'}
                          </p>
                       </div>
                    ) : currentTicket.status === 'voided' ? (
                       // Refunded (voided) state. Holder sees a clear
                       // REFUNDED stamp + the audit reason if one was
                       // recorded. Money movement happens via Stripe
                       // dashboard — we just kill scannability here.
                       <div className="absolute inset-0 flex flex-col items-center justify-center z-30">
                          <div className="bg-rose-600 text-white px-8 py-3 font-black text-2xl uppercase italic tracking-tighter -rotate-12 shadow-2xl skew-x-12">
                             REFUNDED
                          </div>
                          <p className="text-black font-black text-[10px] uppercase tracking-widest mt-4 bg-white px-3 py-1 text-center max-w-[80%]">
                             {currentTicket.voidedReason || 'Refund issued by organizer'}
                          </p>
                       </div>
                    ) : (currentTicket as any).pendingTransferId ? (
                       // Pending-transfer lock. The QR is muted via the
                       // wrapper opacity above. To get the QR back,
                       // either cancel the transfer from My Tickets or
                       // wait for the receiver to claim — at which
                       // point the original wallet entry disappears
                       // from the holder's list (it's no longer their
                       // ownerId).
                       <div className="absolute inset-0 flex flex-col items-center justify-center z-30">
                          <div className="bg-amber-500 text-white px-8 py-3 font-black text-xl uppercase italic tracking-tighter -rotate-6 shadow-2xl skew-x-12">
                             IN TRANSFER
                          </div>
                          <p className="text-black font-black text-[10px] uppercase tracking-widest mt-4 bg-white px-3 py-1 text-center">
                             Cancel the transfer to use this ticket again
                          </p>
                       </div>
                    ) : (
                       <div className="mt-8 flex flex-col items-center space-y-2">
                          <p className="text-[10px] text-black/30 font-black uppercase tracking-tighter italic">Code Expires In</p>
                          <p className="text-3xl font-black text-black italic tracking-tighter leading-none">00:{timeLeft.toString().padStart(2, '0')}</p>
                          <div className="w-40 h-[2px] bg-black/5 mt-4 flex">
                             <div className="h-full bg-brand-primary transition-all duration-1000" style={{ width: `${(timeLeft / 30) * 100}%` }}></div>
                          </div>
                       </div>
                    )}
                 </div>

                 {tickets.length > 1 && (
                   <div className="flex justify-between items-center mb-10 pb-10 border-b border-white/5">
                      <button
                        onClick={prevTicket}
                        disabled={currentIndex === 0}
                        aria-label="Previous ticket"
                        className="flex items-center space-x-2 text-white/40 hover:text-white disabled:opacity-0 transition-all font-black text-[10px] uppercase tracking-widest"
                      >
                         <ChevronLeft className="w-4 h-4" aria-hidden="true" />
                         <span>PREV</span>
                      </button>
                      <div className="flex space-x-1.5">
                        {tickets.map((_, i) => (
                           <div key={i} className={`w-1.5 h-1.5 rounded-full transition-all ${i === currentIndex ? 'bg-brand-primary w-4' : 'bg-white/10'}`}></div>
                        ))}
                      </div>
                      <button
                        onClick={nextTicket}
                        disabled={currentIndex === tickets.length - 1}
                        aria-label="Next ticket"
                        className="flex items-center space-x-2 text-white/40 hover:text-white disabled:opacity-0 transition-all font-black text-[10px] uppercase tracking-widest"
                      >
                         <span>NEXT</span>
                         <ChevronRight className="w-4 h-4" aria-hidden="true" />
                      </button>
                   </div>
                 )}

                 <div className="grid grid-cols-2 gap-px bg-white/5 border border-white/5 mb-12">
                    <div className="p-8 bg-black">
                       <p className="text-white/30 font-black uppercase tracking-tighter italic text-[9px] mb-2 leading-none">LEVEL</p>
                       <p className="text-brand-primary font-black text-xl italic uppercase tracking-tighter">{currentTicket.tierName || 'GENERAL'}</p>
                    </div>
                    <div className="p-8 bg-black text-right">
                       <p className="text-white/30 font-black uppercase tracking-tighter italic text-[9px] mb-2 leading-none">ENTRY_HASH</p>
                       <p className="text-white font-black text-xl italic uppercase tracking-tighter">SEC_A{currentIndex + 1}</p>
                    </div>
                 </div>

                 <div className="space-y-4 mb-12">
                    <div className="flex gap-4">
                       <button onClick={handleSMSShare} className="flex-1 bg-white/5 border border-white/10 text-white/50 py-4 font-black uppercase tracking-tighter italic text-xs hover:bg-white hover:text-black transition-all flex items-center justify-center space-x-2">
                          <Send className="w-3.5 h-3.5 text-brand-primary" />
                          <span>SMS_FORWARD</span>
                       </button>
                       <button onClick={handleInstagramStory} className="flex-1 bg-white/5 border border-white/10 text-white/50 py-4 font-black uppercase tracking-tighter italic text-xs hover:bg-white hover:text-black transition-all flex items-center justify-center space-x-2">
                          <Instagram className="w-3.5 h-3.5 text-brand-primary" />
                          <span>STORY_PREP</span>
                       </button>
                    </div>
                    <div className="flex gap-4">
                       <button
                         onClick={() => downloadIcsFile(event)}
                         className="flex-1 bg-white text-black py-4 font-black uppercase tracking-tighter italic text-xs hover:bg-brand-primary transition-all"
                       >
                          CALENDAR
                       </button>
                    </div>
                    {/* OPEN PASS — fullscreen browser pass with rotating
                        QR + screen wake-lock. Use case: holder hands their
                        phone to the door staff at max brightness. Status
                        overlays (REDEEMED, REFUNDED, IN TRANSFER) refresh on
                        a short poll, so a void issued by the organizer
                        mid-walk-up flips the screen within ~15s. Native
                        Apple/Google Wallet integrations are scaffolded in
                        Commit 14 but not enabled yet. */}
                    <div className="grid grid-cols-1 gap-3 mb-3">
                      <Link
                        to={`/wallet/pass/${currentTicket.id}`}
                        className="bg-white/5 border border-white/10 text-white/60 py-4 font-black uppercase tracking-tighter italic text-xs flex items-center justify-center space-x-3 hover:border-white hover:text-white transition-all"
                      >
                        <Smartphone className="w-4 h-4 text-brand-primary" aria-hidden="true" />
                        <span>OPEN PASS (FULLSCREEN)</span>
                      </Link>
                    </div>
                    <div className="grid grid-cols-2 gap-3">
                      <button
                        onClick={() => setShowShare(true)}
                        className="bg-white/5 border border-white/10 text-white/50 py-5 font-black uppercase tracking-tighter italic text-xs flex items-center justify-center space-x-3 hover:border-white hover:text-white transition-all"
                      >
                        <Share2 className="w-4 h-4 text-brand-primary" />
                        <span>SHARE</span>
                      </button>
                      {currentTicket.status === 'active' && !(currentTicket as any).pendingTransferId ? (
                        <Link
                          to={`/transfer/${currentTicket.id}`}
                          className="bg-white/5 border border-white/10 text-white/50 py-5 font-black uppercase tracking-tighter italic text-xs flex items-center justify-center space-x-3 hover:border-white hover:text-white transition-all"
                        >
                          <Send className="w-4 h-4 text-brand-primary" />
                          <span>TRANSFER</span>
                        </Link>
                      ) : (
                        // Only an unused, unlocked ticket can be transferred —
                        // a scanned-in (used), refunded (voided), or already-
                        // pending ticket shows TRANSFER disabled with the reason.
                        // The server enforces the same (exos_create_transfer
                        // requires status='active'); this is the UX mirror.
                        <button
                          type="button"
                          disabled
                          aria-disabled="true"
                          title={
                            currentTicket.status === 'used'
                              ? "Already scanned in — used tickets can't be transferred"
                              : currentTicket.status === 'voided'
                              ? "Refunded tickets can't be transferred"
                              : 'A transfer is already pending for this ticket'
                          }
                          className="bg-white/[0.02] border border-white/5 text-white/20 py-5 font-black uppercase tracking-tighter italic text-xs flex items-center justify-center space-x-3 cursor-not-allowed"
                        >
                          <Send className="w-4 h-4 text-white/20" />
                          <span>TRANSFER</span>
                        </button>
                      )}
                    </div>
                 </div>
              </div>

              <div className="p-8 bg-black border-t border-white/5 flex items-center justify-between text-[10px] font-black uppercase italic tracking-widest text-white/20">
                 <div className="flex items-center space-x-3">
                    <div className="w-6 h-6 bg-brand-primary flex items-center justify-center">
                       <TicketIcon className="text-black w-3.5 h-3.5" />
                    </div>
                    <span>Digital Ticket</span>
                 </div>
                 <span>ID: {currentTicket.id.slice(0, 16)}</span>
              </div>
            </motion.div>
          </AnimatePresence>

          {/* Visual Cues for Sliding */}
          {tickets.length > 1 && (
            <div className="absolute -inset-x-6 top-1/2 -translate-y-1/2 flex justify-between pointer-events-none">
                <div className="w-12 h-12 bg-white/5 rounded-full border border-white/10 blur-sm"></div>
                <div className="w-12 h-12 bg-white/5 rounded-full border border-white/10 blur-sm"></div>
            </div>
          )}
        </div>

        <div className="mt-12 bg-brand-accent/5 border border-brand-accent/20 p-8 flex items-start space-x-6">
           <ShieldCheck className="w-8 h-8 text-brand-accent shrink-0" />
           <div>
              <p className="text-brand-accent font-black text-xs uppercase tracking-tighter italic mb-2">Security Protection</p>
              <p className="text-white/40 text-[11px] leading-relaxed italic font-medium uppercase tracking-tighter">This code automatically updates every 30 seconds to prevent unauthorized use. Please present this live ticket at the entrance instead of a screenshot.</p>
           </div>
        </div>
      </div>

      {/*
        Buyer-side share modal: "I'm going to {event}!" framed share.
        Links to the public event page (not the ticket page — those
        are private). Open Graph tags from EventDetails handle the
        rich preview when posted.
      */}
      {event && (
        <ShareModal
          open={showShare}
          onClose={() => setShowShare(false)}
          title={event.title}
          url={publicUrl(`event/${event.id}`)}
          text={`I'm going to ${event.title}!`}
        />
      )}
    </div>
  );
}
