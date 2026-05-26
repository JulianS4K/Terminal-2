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
      <div className="max-w-xl mx-auto p-24 text-center text-slate-300 font-bold uppercase tracking-[0.3em] animate-pulse">
        Loading your ticket...
      </div>
    );
  }

  if (!transfer || transfer.status !== 'pending') {
    return (
      <div className="max-w-xl mx-auto px-4 py-24 text-center">
        <XCircle className="w-20 h-20 text-slate-100 mx-auto mb-8" />
        <h1 className="text-3xl font-bold text-slate-900 mb-4">Transfer Expired</h1>
        <p className="text-slate-500 mb-10">
          This transfer link is no longer active or the assets have already been claimed.
        </p>
        <button
          onClick={() => navigate('/')}
          className="bg-slate-900 text-white px-10 py-4 rounded-2xl font-bold text-xs uppercase tracking-widest shadow-xl"
        >
          Back Home
        </button>
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
    <div className="max-w-2xl mx-auto px-4 py-12">
      <div className="text-center mb-12">
        <div className="inline-flex items-center justify-center w-16 h-16 bg-brand-primary rounded-[1.5rem] mb-6 shadow-xl shadow-indigo-100">
          <ShieldCheck className="text-white w-8 h-8" aria-hidden="true" />
        </div>
        <h1 className="text-4xl font-bold text-slate-900 tracking-tight mb-2">Claim Your Ticket</h1>
        <p className="text-slate-500 font-medium tracking-wide uppercase tracking-[0.2em] text-[10px]">
          Verification
        </p>
      </div>

      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        className="bg-white rounded-[2.5rem] border border-slate-100 shadow-2xl overflow-hidden mb-8"
      >
        <div className="p-10 border-b border-slate-50 relative overflow-hidden">
          <div className="absolute top-0 right-0 w-32 h-32 bg-indigo-50 rounded-full blur-3xl -mr-16 -mt-16 opacity-50"></div>
          <div className="flex items-center space-x-6 relative z-10">
            <div className="w-24 h-24 bg-slate-100 rounded-2xl overflow-hidden shrink-0 shadow-inner">
              {displayImage ? (
                <img src={displayImage} alt={displayTitle} className="w-full h-full object-cover" />
              ) : null}
            </div>
            <div className="text-left">
              <p className="text-[10px] text-slate-400 font-bold uppercase tracking-widest mb-1">
                Invitation for
              </p>
              <h2 className="text-2xl font-bold text-slate-900 tracking-tight mb-2">{displayTitle}</h2>
              <div className="flex items-center space-x-4">
                <span className="text-[10px] font-bold text-slate-400 bg-slate-50 px-3 py-1 rounded-full uppercase tracking-widest border border-slate-100">
                  {displayTier}
                </span>
                <span className="text-[10px] font-bold text-green-500 bg-green-50 px-3 py-1 rounded-full uppercase tracking-widest border border-green-100">
                  Verified
                </span>
              </div>
            </div>
          </div>
        </div>

        <div className="p-10 bg-slate-50/50">
          {!user ? (
            <div className="text-center">
              <p className="text-slate-500 font-medium mb-8">
                Identification required to claim assets.
              </p>
              <button
                onClick={() =>
                  toast({
                    kind: 'info',
                    message: 'Sign in from the navbar to claim this ticket.',
                  })
                }
                className="w-full bg-slate-900 text-white py-5 rounded-2xl font-bold uppercase tracking-widest text-xs shadow-xl shadow-slate-200"
              >
                Authorize via Identity Provider
              </button>
            </div>
          ) : isWrongUser ? (
            <div className="bg-red-50 p-8 rounded-3xl border border-red-100 text-center">
              <XCircle className="w-12 h-12 text-red-500 mx-auto mb-4" aria-hidden="true" />
              <p className="text-red-900 font-bold mb-2">Identification Conflict</p>
              <p className="text-red-700 text-sm mb-6">
                This asset is registered for <strong>{transfer.receiverEmail}</strong>, but you are
                identified as <strong>{user.email}</strong>.
              </p>
              <button
                className="text-red-900 font-bold text-xs uppercase tracking-widest hover:underline"
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
              <div className="bg-white p-8 rounded-3xl border border-slate-100 shadow-sm">
                <div className="flex items-center justify-between mb-6">
                  <div className="text-left">
                    <p className="text-[10px] text-slate-300 font-bold uppercase tracking-widest mb-1">
                      From
                    </p>
                    <p className="text-sm font-bold text-slate-600">Secure Sender</p>
                  </div>
                  <ArrowRight className="text-brand-primary w-5 h-5 mx-4" aria-hidden="true" />
                  <div className="text-right">
                    <p className="text-[10px] text-slate-300 font-bold uppercase tracking-widest mb-1">
                      Target Account
                    </p>
                    <p className="text-sm font-bold text-slate-600 truncate max-w-[140px]">
                      {user.email}
                    </p>
                  </div>
                </div>
                <div className="pt-6 border-t border-slate-50 flex items-center justify-center">
                  <CheckCircle2 className="w-4 h-4 text-green-500 mr-2" aria-hidden="true" />
                  <span className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">
                    Ready to claim
                  </span>
                </div>
              </div>

              <button
                onClick={handleClaim}
                disabled={claiming}
                className="w-full bg-slate-900 text-white py-6 rounded-2xl font-bold uppercase tracking-widest text-xs hover:bg-slate-800 transition-all shadow-2xl shadow-slate-200 active:scale-95 disabled:opacity-50"
              >
                {claiming ? 'Claiming...' : 'Claim Ticket'}
              </button>
            </div>
          )}
        </div>
      </motion.div>

      <p className="text-center text-[9px] text-slate-300 font-bold uppercase tracking-[0.4em]">
        VP SECURE EXCHANGE PROTOCOL v1.0.4
      </p>
    </div>
  );
}
