import { useEffect, useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { getTransfer, claimTransfer } from '../lib/tickets';
import { getPublicEvent } from '../lib/events';
import { useAuth } from '../context/AuthContext';
import { Event, Transfer } from '../types';
import { ShieldCheck, ArrowRight, XCircle, CheckCircle2 } from 'lucide-react';
import { queueEmail, queueTicketIssued } from '../lib/mail';
import { motion } from 'motion/react';
import { useToast } from '../context/ToastContext';

// NOTE on the data flow.
//
// The receiver of a transfer cannot read the ticket doc — Firestore rules
// only grant ticket reads to the current owner / buyer / organizer, and
// the receiver is none of those until *after* a successful claim. The
// transfer doc is the only source of truth they can read pre-claim.
//
// To make the claim screen render anything useful, TransferTicket
// denormalises the event title / image / tier name onto the transfer doc
// at create time. We then fetch the (publicly readable) event doc here
// purely to enrich the display when available; if it fails for any
// reason we fall back to the denormalised values.
//
// The claim itself doesn't need a ticket fetch either: we already have
// `transfer.ticketId` and the rules verify the caller's email against the
// transfer doc's receiverEmail.

export default function ClaimTicket() {
  const { transferId } = useParams();
  const { user, logout, openAuthModal } = useAuth();
  const navigate = useNavigate();
  const { toast } = useToast();
  const [transfer, setTransfer] = useState<Transfer | null>(null);
  const [event, setEvent] = useState<Event | null>(null);
  const [loading, setLoading] = useState(true);
  const [claiming, setClaiming] = useState(false);

  useEffect(() => {
    async function fetchData() {
      if (!transferId) return;
      try {
        const transData = await getTransfer(transferId);
        if (!transData) {
          setLoading(false);
          return;
        }
        setTransfer(transData);

        // Best-effort enrichment from the public event row. Transfers refuse
        // draft events, so the event is published and publicly readable; the
        // transfer also carries denormalised title/image as a fallback.
        if (transData.eventId) {
          try {
            const ev = await getPublicEvent(transData.eventId);
            if (ev) setEvent(ev);
          } catch (eventErr) {
            console.warn('Could not enrich claim screen with event:', eventErr);
          }
        }
      } catch (error) {
        console.error('Failed to load transfer:', error);
        toast({ kind: 'error', message: 'Could not load this transfer.' });
      } finally {
        setLoading(false);
      }
    }
    fetchData();
  }, [transferId, toast]);

  const handleClaim = async () => {
    if (!user || !transfer) return;

    if (user.email?.toLowerCase() !== transfer.receiverEmail.toLowerCase()) {
      toast({
        kind: 'error',
        title: 'Wrong account',
        message: 'This transfer was sent to a different email address.',
      });
      return;
    }

    setClaiming(true);
    try {
      // One RPC does the whole claim atomically: flips the transfer to
      // 'completed', reassigns ownership to the caller, ROTATES the per-ticket
      // barcode secret (so the sender's old screenshot is dead), echoes the
      // transferId, and clears the pending-transfer lock. It re-verifies the
      // caller's confirmed email matches the transfer and refuses if the
      // ticket was used/voided in the meantime.
      const claimedTicketId = await claimTransfer(transfer.id);

      // Notify the sender that their transfer was claimed. Recipient + body
      // are server-derived by the exos_queue_mail RPC (mig 20260520160000).
      void queueEmail({ template: 'transfer-claimed', refId: transfer.id });
      // Confirm to the new owner that the ticket is now in their wallet
      // (server-derived recipient; mig 20260523210000).
      void queueTicketIssued(claimedTicketId);

      toast({ kind: 'success', message: 'Ticket claimed.' });
      navigate('/my-tickets');
    } catch (error: any) {
      console.error('Claim failed:', error);
      toast({ kind: 'error', message: error?.message || 'Could not claim the ticket.' });
    } finally {
      setClaiming(false);
    }
  };

  if (loading) {
    return (
      <div className="wall min-h-screen flex items-center justify-center">
        <p className="disp text-3xl tracking-tight text-white/20 animate-pulse" style={{ transform: 'skewX(-4deg)' }}>LOADING YOUR TICKET…</p>
      </div>
    );
  }

  if (!transfer || transfer.status !== 'pending') {
    return (
      <div className="wall min-h-screen">
        <div className="max-w-xl mx-auto px-4 py-24 text-center">
          <XCircle className="w-20 h-20 text-white/20 mx-auto mb-8" />
          <h1 className="disp text-5xl tracking-tight leading-none mb-4" style={{ transform: 'skewX(-4deg)' }}>TRANSFER EXPIRED</h1>
          <p className="type text-white/40 text-sm mb-10">
            This transfer link is no longer active or the assets have already been claimed.
          </p>
          <button
            onClick={() => navigate('/')}
            className="disp bg-brand-primary text-black px-10 py-3 text-lg tracking-wide hover:scale-[1.01] transition-transform"
          >
            BACK HOME
          </button>
        </div>
      </div>
    );
  }

  // Display fields — prefer the (live) event doc, fall back to the
  // denormalised values on the transfer doc so the screen still renders
  // even when the event read failed or the doc is missing fields.
  const displayTitle = event?.title || transfer.eventTitle || 'Event';
  const displayImage = event?.image || transfer.eventImage || '';
  const displayTier = transfer.tierName || 'General Entry';

  const isWrongUser =
    user && user.email?.toLowerCase() !== transfer.receiverEmail.toLowerCase();

  return (
    <div className="wall min-h-screen">
      <div className="max-w-2xl mx-auto px-4 py-16 relative z-10">
        <div className="text-center mb-12">
          <div className="inline-flex items-center justify-center w-16 h-16 bg-brand-primary mb-6">
            <ShieldCheck className="text-black w-8 h-8" aria-hidden="true" />
          </div>
          <h1 className="disp text-5xl tracking-tight leading-none mb-2" style={{ transform: 'skewX(-4deg)' }}>CLAIM YOUR TICKET</h1>
          <p className="type text-[11px] text-white/40 uppercase tracking-[0.25em]">
            secure exchange · verification
          </p>
        </div>

        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          className="bg-[#111] border border-white/10 overflow-hidden mb-8"
        >
          <div className="group p-8 border-b border-white/5 flex items-center gap-6">
            <div className="w-24 h-24 bg-white/5 overflow-hidden shrink-0">
              {displayImage ? (
                <img src={displayImage} alt={displayTitle} className="xerox w-full h-full object-cover" />
              ) : null}
            </div>
            <div>
              <p className="type text-[10px] text-white/30 uppercase tracking-widest mb-1">
                invitation for
              </p>
              <h2 className="disp text-3xl tracking-tight leading-none mb-3">{displayTitle}</h2>
              <div className="flex items-center gap-3">
                <span className="type text-[9px] text-white/60 bg-white/5 border border-white/10 px-3 py-1 uppercase tracking-widest">
                  {displayTier}
                </span>
                <span className="type text-[9px] text-brand-primary bg-brand-primary/10 border border-brand-primary/30 px-3 py-1 uppercase tracking-widest">
                  verified
                </span>
              </div>
            </div>
          </div>

          <div className="p-8 bg-black/40">
            {!user ? (
              <div className="text-center">
                <p className="type text-white/50 text-sm mb-8">
                  Identification required to claim assets.
                </p>
                <button
                  onClick={() =>
                    toast({
                      kind: 'info',
                      message: 'Sign in from the navbar to claim this ticket.',
                    })
                  }
                  className="disp w-full bg-white text-black py-4 text-lg tracking-wide hover:bg-brand-primary transition-all"
                >
                  AUTHORIZE VIA IDENTITY PROVIDER
                </button>
              </div>
            ) : isWrongUser ? (
              <div className="bg-brand-accent/10 p-8 border border-brand-accent/30 text-center">
                <XCircle className="w-12 h-12 text-brand-accent mx-auto mb-4" aria-hidden="true" />
                <p className="disp text-xl tracking-tight text-white mb-2">IDENTIFICATION CONFLICT</p>
                <p className="type text-white/60 text-sm mb-6">
                  This asset is registered for <strong className="text-white">{transfer.receiverEmail}</strong>, but you are
                  identified as <strong className="text-white">{user.email}</strong>.
                </p>
                <button
                  className="type text-brand-accent text-xs uppercase tracking-widest hover:underline"
                  onClick={async () => {
                    await logout();
                    openAuthModal();
                  }}
                >
                  Switch Profile
                </button>
              </div>
            ) : (
              <div className="space-y-8">
                <div className="bg-white/5 border border-white/10 p-7">
                  <div className="flex items-center justify-between mb-6">
                    <div className="text-left">
                      <p className="type text-[9px] text-white/30 uppercase tracking-widest mb-1">
                        from
                      </p>
                      <p className="disp text-lg tracking-tight">SECURE SENDER</p>
                    </div>
                    <ArrowRight className="text-brand-primary w-6 h-6 mx-4 shrink-0" aria-hidden="true" />
                    <div className="text-right min-w-0">
                      <p className="type text-[9px] text-white/30 uppercase tracking-widest mb-1">
                        target account
                      </p>
                      <p className="disp text-lg tracking-tight truncate">
                        {user.email}
                      </p>
                    </div>
                  </div>
                  <div className="pt-5 border-t border-white/5 flex items-center justify-center gap-2">
                    <CheckCircle2 className="w-4 h-4 text-brand-primary" aria-hidden="true" />
                    <span className="type text-[10px] text-white/40 uppercase tracking-widest">
                      ready to claim
                    </span>
                  </div>
                </div>

                <button
                  onClick={handleClaim}
                  disabled={claiming}
                  className="disp w-full bg-brand-primary text-black py-4 text-xl tracking-wide hover:scale-[1.01] transition-transform disabled:opacity-50"
                >
                  {claiming ? 'CLAIMING…' : 'CLAIM TICKET'}
                </button>
              </div>
            )}
          </div>
        </motion.div>

        <p className="text-center type text-[9px] text-white/25 uppercase tracking-[0.35em]">
          exos secure exchange protocol v1.0.4
        </p>
      </div>
    </div>
  );
}
