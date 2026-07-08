import { useEffect, useState, useRef } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { getTicket, listMyTicketsForEvent } from '../lib/tickets';
import { Ticket, Event } from '../types';
import { useAuth } from '../context/AuthContext';
import { QRCodeSVG } from 'qrcode.react';
import { publicUrl } from '../lib/utils';
import { ArrowLeft, Share2, ShieldCheck, RefreshCw, Ticket as TicketIcon, Calendar, Download, PlusCircle, Instagram, Send, ChevronLeft, ChevronRight, Smartphone, Lock } from 'lucide-react';
import { formatInTz, isWithinHoursBefore } from '../lib/datetime';
import { signBarcode, currentBucket } from '../lib/barcode';
import { motion, AnimatePresence } from 'motion/react';
import AddToCalendar from '../components/AddToCalendar';
import { shareEventToStory } from '../lib/poster';
import { useToast } from '../context/ToastContext';
import ShareModal from '../components/ShareModal';
import OrganizerUpdates from '../components/OrganizerUpdates';
import RescheduleNotice from '../components/RescheduleNotice';

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

  if (loading) return (
    <div className="wall min-h-screen flex items-center justify-center p-20 text-center">
      <p className="type text-white/50 uppercase tracking-[0.3em] text-[12px] animate-pulse">// loading ticket...</p>
    </div>
  );
  if (!tickets.length || !event) {
    return (
      <div className="wall min-h-screen flex items-center justify-center p-20 text-center">
        <p className="type text-brand-accent uppercase tracking-widest text-[12px]">// access denied: no tickets found</p>
      </div>
    );
  }

  const currentTicket = tickets[currentIndex];
  // Gate the scannable entry QR to within 24h of the event — before that the
  // code is useless at the door and showing it early only invites screenshots.
  const qrUnlocked = isWithinHoursBefore(event.date?.toDate?.(), 24);
  const handleInstagramStory = async () => {
    await shareEventToStory(
      { title: event.title, url: publicUrl(`event/${event.id}`), imageUrl: event.image },
      toast,
    );
  };

  const handleSMSShare = () => {
    const text = `I just secured tickets for ${event.title}! Join me: ${publicUrl(`event/${event.id}`)}`;
    window.location.href = `sms:?&body=${encodeURIComponent(text)}`;
  };

  return (
    <div className="wall min-h-screen text-white">
      <div className="max-w-2xl mx-auto px-4 py-12 relative z-10">
        <button onClick={() => navigate('/my-tickets')} className="type inline-flex items-center gap-2 text-white/50 hover:text-white mb-12 transition-colors text-[12px] uppercase tracking-widest">
          <ArrowLeft className="w-4 h-4 text-brand-primary" />
          back to tickets
        </button>

        <div className="relative">
          <AnimatePresence mode="wait">
            <motion.div
              key={currentTicket.id}
              initial={{ opacity: 0, x: 20 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0, x: -20 }}
              className="bg-[#111] border border-white/10 shadow-2xl relative overflow-hidden"
            >
              {/* Top Branding Section */}
              <div className="p-9 pb-20 bg-brand-primary text-black relative">
                 <div className="flex justify-between items-start mb-10">
                    <div>
                      <p className="disp text-lg tracking-wide leading-none">PASS {currentIndex + 1} OF {tickets.length}</p>
                      <p className="type text-[10px] uppercase tracking-[0.2em] mt-1 opacity-60">{currentTicket.tierName}</p>
                    </div>
                    <span className="w-2 h-2 bg-black rounded-full animate-pulse"></span>
                 </div>
                 <h1 className="disp text-5xl md:text-6xl leading-[0.85] tracking-tight mb-3">{event.title}</h1>
                 <p className="type text-[11px] uppercase tracking-widest text-black/60">{event.category} // {event.location}</p>
              </div>

              <div className="-mt-12 px-8 md:px-10 relative z-20">
                 <div className="bg-white p-8 md:p-10 flex flex-col items-center justify-center group mb-8 relative">
                    <div className={`relative p-5 bg-white border-[3px] border-black transition-transform duration-500 flex flex-col items-center w-full max-w-[300px] ${currentTicket.status === 'used' || currentTicket.status === 'voided' || (currentTicket as any).pendingTransferId ? 'opacity-20 grayscale' : 'group-hover:scale-[1.02]'}`}>
                      {qrUnlocked ? (
                        <QRCodeSVG value={barcode} size={220} level="H" includeMargin={false} fgColor="#000000" />
                      ) : (
                        <div className="w-[220px] h-[220px] flex flex-col items-center justify-center text-center px-4 bg-slate-50 border border-dashed border-black/20">
                          <Lock className="w-8 h-8 text-black/30 mb-3" aria-hidden="true" />
                          <p className="type text-[10px] uppercase tracking-widest text-black/50">Entry code locked</p>
                          <p className="type text-[10px] text-black/40 mt-1">
                            Unlocks 24h before{event.date ? ` · ${formatInTz(event.date.toDate(), event.timezone, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })}` : ' the event'}
                          </p>
                        </div>
                      )}
                      <div className="mt-5 w-full text-center border-t-[3px] border-dashed border-black/20 pt-5 space-y-3">
                        <div>
                          <p className="type text-[9px] uppercase tracking-widest text-black/40">event</p>
                          <p className="disp text-lg text-black tracking-tight leading-none mt-0.5">{event.title}</p>
                        </div>
                        <div className="flex justify-between items-end text-left pt-1">
                           <div>
                             <p className="type text-[9px] uppercase tracking-widest text-black/40">pass holder</p>
                             <p className="disp text-base text-black tracking-tight leading-none mt-0.5 overflow-hidden text-ellipsis whitespace-nowrap max-w-[120px]">{user.displayName || user.email || 'Guest'}</p>
                           </div>
                           <div className="text-right">
                             <p className="type text-[9px] uppercase tracking-widest text-black/40">pass id</p>
                             <p className="type text-[11px] text-black leading-none mt-0.5">{currentTicket.id}</p>
                           </div>
                        </div>
                      </div>
                      <div className="absolute -top-3 -right-3 w-9 h-9 bg-brand-primary border-4 border-white flex items-center justify-center">
                         <span className="w-2.5 h-2.5 bg-black rounded-full animate-ping"></span>
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
                       <div className="mt-7 flex flex-col items-center">
                          <p className="type text-[10px] text-black/40 uppercase tracking-widest">code expires in</p>
                          <p className="disp text-4xl text-black tracking-tight leading-none mt-1">00:{timeLeft.toString().padStart(2, '0')}</p>
                          <div className="w-40 h-[3px] bg-black/10 mt-3">
                             <div className="h-full bg-brand-primary transition-all duration-1000" style={{ width: `${(timeLeft / 30) * 100}%` }}></div>
                          </div>
                       </div>
                    )}
                 </div>

                 {tickets.length > 1 && (
                   <div className="flex justify-between items-center my-8 pb-8 border-b border-white/5">
                      <button
                        onClick={prevTicket}
                        disabled={currentIndex === 0}
                        aria-label="Previous ticket"
                        className="type flex items-center gap-2 text-white/40 hover:text-white disabled:opacity-0 transition-all text-[10px] uppercase tracking-widest"
                      >
                         <ChevronLeft className="w-4 h-4" aria-hidden="true" />
                         <span>prev</span>
                      </button>
                      <div className="flex gap-1.5">
                        {tickets.map((_, i) => (
                           <span key={i} className={`h-1.5 transition-all ${i === currentIndex ? 'bg-brand-primary w-4' : 'bg-white/15 w-1.5'}`}></span>
                        ))}
                      </div>
                      <button
                        onClick={nextTicket}
                        disabled={currentIndex === tickets.length - 1}
                        aria-label="Next ticket"
                        className="type flex items-center gap-2 text-white/40 hover:text-white disabled:opacity-0 transition-all text-[10px] uppercase tracking-widest"
                      >
                         <span>next</span>
                         <ChevronRight className="w-4 h-4" aria-hidden="true" />
                      </button>
                   </div>
                 )}

                 <div className="grid grid-cols-2 gap-px bg-white/5 border border-white/5 mb-10">
                    <div className="p-6 bg-black">
                       <p className="type text-white/30 uppercase tracking-widest text-[9px] mb-1">level</p>
                       <p className="disp neon text-2xl tracking-wide">{currentTicket.tierName || 'GENERAL'}</p>
                    </div>
                    <div className="p-6 bg-black text-right">
                       <p className="type text-white/30 uppercase tracking-widest text-[9px] mb-1">entry_hash</p>
                       <p className="disp text-white text-2xl tracking-wide">SEC_A{currentIndex + 1}</p>
                    </div>
                 </div>

                 <div className="space-y-3 mb-10">
                    <div className="grid grid-cols-2 gap-3">
                       <button onClick={handleSMSShare} className="type flex items-center justify-center gap-2 bg-white/5 border border-white/10 text-white/60 py-3.5 text-[11px] uppercase tracking-widest hover:bg-white hover:text-black transition-colors">
                          <Send className="w-3.5 h-3.5 text-brand-primary" />
                          sms_forward
                       </button>
                       <button onClick={handleInstagramStory} className="type flex items-center justify-center gap-2 bg-white/5 border border-white/10 text-white/60 py-3.5 text-[11px] uppercase tracking-widest hover:bg-white hover:text-black transition-colors">
                          <Instagram className="w-3.5 h-3.5 text-brand-primary" />
                          story_prep
                       </button>
                    </div>
                    <div className="flex gap-4">
                       <AddToCalendar event={event} variant="button" className="flex-1" />
                    </div>
                    {/* OPEN PASS — fullscreen browser pass with rotating
                        QR + screen wake-lock. Use case: holder hands their
                        phone to the door staff at max brightness. Status
                        overlays (REDEEMED, REFUNDED, IN TRANSFER) refresh on
                        a short poll, so a void issued by the organizer
                        mid-walk-up flips the screen within ~15s. Native
                        Apple/Google Wallet integrations are scaffolded in
                        Commit 14 but not enabled yet. */}
                    <Link
                      to={`/wallet/pass/${currentTicket.id}`}
                      className="type flex items-center justify-center gap-3 bg-white/5 border border-white/10 text-white/60 py-4 text-[11px] uppercase tracking-widest hover:border-white hover:text-white transition-colors"
                    >
                      <Smartphone className="w-4 h-4 text-brand-primary" aria-hidden="true" />
                      open pass (fullscreen)
                    </Link>
                    <div className="grid grid-cols-2 gap-3">
                      <button
                        onClick={() => setShowShare(true)}
                        className="type flex items-center justify-center gap-2 bg-white/5 border border-white/10 text-white/60 py-4 text-[11px] uppercase tracking-widest hover:border-white hover:text-white transition-colors"
                      >
                        <Share2 className="w-4 h-4 text-brand-primary" />
                        share
                      </button>
                      {currentTicket.status === 'active' && !(currentTicket as any).pendingTransferId ? (
                        <Link
                          to={`/transfer/${currentTicket.id}`}
                          className="type flex items-center justify-center gap-2 bg-white/5 border border-white/10 text-white/60 py-4 text-[11px] uppercase tracking-widest hover:border-white hover:text-white transition-colors"
                        >
                          <Send className="w-4 h-4 text-brand-primary" />
                          transfer
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
                          className="type flex items-center justify-center gap-2 bg-white/[0.02] border border-white/5 text-white/20 py-4 text-[11px] uppercase tracking-widest cursor-not-allowed"
                        >
                          <Send className="w-4 h-4 text-white/20" />
                          transfer
                        </button>
                      )}
                    </div>
                 </div>
              </div>

              <div className="p-7 bg-black border-t border-white/5 flex items-center justify-between type text-[10px] uppercase tracking-widest text-white/25">
                 <div className="flex items-center gap-3">
                    <div className="w-6 h-6 bg-brand-primary flex items-center justify-center">
                       <TicketIcon className="text-black w-3.5 h-3.5" />
                    </div>
                    digital ticket
                 </div>
                 <span>id: {currentTicket.id.slice(0, 16)}</span>
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

        <div className="mt-10 bg-brand-accent/5 border border-brand-accent/25 p-7 flex items-start gap-5">
           <ShieldCheck className="w-8 h-8 text-brand-accent shrink-0" />
           <div>
              <p className="disp text-brand-accent text-lg tracking-wide mb-1">SECURITY PROTECTION</p>
              <p className="type text-white/45 text-[12px] leading-relaxed">This code automatically updates every 30 seconds to prevent unauthorized use. Present this live ticket at the entrance instead of a screenshot.</p>
           </div>
        </div>

        {/* Reschedule notice — shown when the organizer has moved the event. */}
        <RescheduleNotice eventId={event.id} timezone={event.timezone} />

        {/* Organizer updates — the in-app counterpart to announcement emails.
            Renders nothing until the organizer has broadcast at least one. */}
        <OrganizerUpdates eventId={event.id} />
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
