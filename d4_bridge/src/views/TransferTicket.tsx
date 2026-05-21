import { useEffect, useState, FormEvent } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { getTicket, createTransfer } from '../lib/tickets';
import { Ticket, Event } from '../types';
import { useAuth } from '../context/AuthContext';
import { ArrowLeft, UserPlus, ShieldAlert, Send, Check, Copy } from 'lucide-react';
import { queueEmail, escapeHtml } from '../lib/mail';
import { motion } from 'motion/react';
import { useToast } from '../context/ToastContext';

export default function TransferTicket() {
  const { id } = useParams();
  const { user } = useAuth();
  const navigate = useNavigate();
  const { toast } = useToast();
  const [ticket, setTicket] = useState<Ticket | null>(null);
  const [event, setEvent] = useState<Event | null>(null);
  const [loading, setLoading] = useState(true);
  const [recipientEmail, setRecipientEmail] = useState('');
  const [sending, setSending] = useState(false);
  // After a successful transfer, switch the page into a "share link"
  // success state so the sender can copy the claim URL and pass it
  // along via SMS / iMessage / WhatsApp / wherever. The email is
  // still queued in the background — the share link is for the case
  // where the receiver hasn't seen the email yet, the email never
  // arrives, or the sender just prefers to deliver the link directly.
  const [completedTransferId, setCompletedTransferId] = useState<string | null>(null);
  const [completedReceiverEmail, setCompletedReceiverEmail] = useState<string>('');
  const [linkCopied, setLinkCopied] = useState(false);

  useEffect(() => {
    async function fetchData() {
      if (!id) return;
      try {
        const t = await getTicket(id); // joins the event in one round-trip
        if (t) {
          setTicket(t);
          setEvent(t.event ?? null);
        }
      } catch (err) {
        console.error('Failed to load ticket:', err);
      } finally {
        setLoading(false);
      }
    }
    fetchData();
  }, [id]);

  const handleTransfer = async (e: FormEvent) => {
    e.preventDefault();
    if (!ticket || !user || !recipientEmail) return;

    // Always lower-case the email when comparing or writing — Firestore
    // rules compare it byte-for-byte against the (lowercase) auth-token
    // email, so a mixed-case write would be unclaimable forever.
    const normalisedEmail = recipientEmail.trim().toLowerCase();

    setSending(true);
    if (normalisedEmail === user.email?.toLowerCase()) {
      toast({
        kind: 'warn',
        message: "You can't transfer a ticket to your own account.",
      });
      setSending(false);
      return;
    }

    try {
      // One RPC creates the pending transfer (with the denormalised event/
      // tier fields the receiver needs to render the claim screen) AND locks
      // the ticket via pending_transfer_id, atomically. The RPC refuses if
      // the ticket isn't active, already has a pending transfer, the receiver
      // is the sender, or the event is still a draft — so the previous
      // separate "lock" write (and its failure-handling) is gone.
      const transferId = await createTransfer(ticket.id, normalisedEmail);

      // Best-effort: enqueue an email to the receiver with the claim link.
      // Still routed through the Firestore Trigger Email queue (mail
      // transport is a separate migration). queueEmail never throws.
      const claimUrl = `${window.location.origin}/claim/${transferId}`;
      const safeEvent = escapeHtml(event?.title ?? 'an event');
      const safeSender = escapeHtml(user.email ?? 'A Exos user');
      void queueEmail({
        to: normalisedEmail,
        template: 'transfer-initiated',
        subject: `${safeSender} sent you a ticket to ${safeEvent}`,
        html: `
          <p>${safeSender} just transferred you a ticket to <strong>${safeEvent}</strong>.</p>
          <p>Click the link below to claim it. You'll need to sign in with this email address.</p>
          <p><a href="${claimUrl}">Claim your ticket</a></p>
          <p style="color:#666;font-size:12px;">If you weren't expecting this email, you can safely ignore it.</p>
        `,
      });

      // Switch into the share-link success state instead of bouncing
      // straight to /my-tickets. The sender can stay on the page,
      // copy the claim URL, and forward it through whatever channel
      // they want.
      setCompletedTransferId(transferId);
      setCompletedReceiverEmail(normalisedEmail);
      toast({
        kind: 'success',
        title: 'Transfer sent',
        message: `${normalisedEmail} can claim — copy the link to send via SMS or anywhere else.`,
      });
    } catch (error: any) {
      console.error('Transfer failed:', error);
      toast({ kind: 'error', message: error?.message || 'Could not send the transfer.' });
    } finally {
      setSending(false);
    }
  };

  if (loading) return <div className="max-w-7xl mx-auto p-40 text-center text-white/20 font-black uppercase tracking-widest italic animate-pulse">Loading Ticket...</div>;
  if (!ticket || ticket.ownerId !== user?.uid) return <div className="max-w-2xl mx-auto p-20 text-center font-black uppercase tracking-widest italic text-brand-accent">Access Denied</div>;

  // After a successful transfer, render the share-link success state
  // instead of the form. The sender keeps the page open, copies the
  // claim link, and pastes it into whatever messaging app they prefer.
  if (completedTransferId) {
    const claimUrl = `${window.location.origin}/claim/${completedTransferId}`;
    const handleCopy = async () => {
      try {
        await navigator.clipboard.writeText(claimUrl);
        setLinkCopied(true);
        setTimeout(() => setLinkCopied(false), 2500);
      } catch (err) {
        console.warn('Clipboard write failed:', err);
        toast({ kind: 'warn', message: 'Copy failed — long-press the link to copy manually.' });
      }
    };
    return (
      <div className="bg-[#000000] min-h-screen text-white">
        <div className="max-w-2xl mx-auto px-4 py-20">
          <div className="flex items-center justify-between mb-16">
            <div>
              <p className="text-brand-primary text-xs font-black uppercase tracking-widest italic mb-2">Transfer Sent</p>
              <h1 className="text-4xl font-black uppercase italic tracking-tighter leading-none">Share The Link</h1>
            </div>
            <div className="w-14 h-14 bg-brand-primary flex items-center justify-center">
              <Check className="text-black w-6 h-6" />
            </div>
          </div>

          <div className="bg-[#111111] border border-white/10 p-10 mb-8">
            <p className="text-[10px] font-black text-white/30 uppercase tracking-widest italic mb-2">Sent to</p>
            <p className="text-2xl font-black uppercase italic tracking-tighter mb-8 break-all">{completedReceiverEmail}</p>
            <p className="text-[10px] font-black text-white/30 uppercase tracking-widest italic mb-2">Claim link</p>
            <div className="bg-black border border-white/10 p-5 flex items-center justify-between gap-3 mb-6">
              <code className="text-[11px] font-mono text-white/70 break-all flex-1">{claimUrl}</code>
              <button
                type="button"
                onClick={handleCopy}
                className={`shrink-0 px-4 py-2 font-black uppercase tracking-tighter italic text-[10px] transition-all flex items-center gap-2 ${
                  linkCopied ? 'bg-brand-primary text-black' : 'bg-white text-black hover:bg-brand-primary'
                }`}
              >
                {linkCopied ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
                {linkCopied ? 'COPIED' : 'COPY'}
              </button>
            </div>
            <p className="text-[11px] text-white/40 italic font-medium leading-relaxed mb-2">
              We've also queued an email to {completedReceiverEmail} with this link. Send the link directly via text or any other app — the receiver signs in with the email above to claim.
            </p>
          </div>

          <div className="flex gap-4">
            <button
              type="button"
              onClick={() => navigate('/my-tickets')}
              className="flex-1 bg-white text-black py-5 font-black uppercase tracking-tighter italic text-xs hover:bg-brand-primary transition-all"
            >
              BACK TO TICKETS
            </button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="bg-[#000000] min-h-screen text-white">
      <div className="max-w-2xl mx-auto px-4 py-20">
        <div className="flex items-center justify-between mb-16">
          <div>
            <p className="text-brand-primary text-xs font-black uppercase tracking-widest italic mb-2">Transfer Ticket</p>
            <h1 className="text-4xl font-black uppercase italic tracking-tighter leading-none">Send Ticket</h1>
          </div>
          <div className="w-14 h-14 bg-white flex items-center justify-center">
            <Send className="text-black w-6 h-6" />
          </div>
        </div>

        <div className="bg-[#111111] border border-white/10 p-10 relative overflow-hidden mb-12">
          <div className="relative z-10">
            <div className="flex items-center space-x-6 mb-12">
               <div className="w-24 h-32 bg-white/5 border border-white/10 overflow-hidden shrink-0">
                  <img src={event?.image} alt="" className="w-full h-full object-cover grayscale" />
               </div>
               <div>
                  <p className="text-[10px] text-white/30 font-black uppercase tracking-tighter italic mb-1">Ticket Details</p>
                  <h2 className="text-2xl font-black text-white italic uppercase tracking-tighter mb-2">{event?.title}</h2>
                  <p className="text-[10px] font-black text-brand-primary uppercase italic tracking-tighter">Tier: {ticket.tierName || 'GENERAL'}</p>
               </div>
            </div>

            <form onSubmit={handleTransfer} className="space-y-10">
              <div className="space-y-4">
                <label className="text-[10px] font-black text-white/30 uppercase tracking-widest italic ml-1">Recipient Email</label>
                <div className="relative">
                  <UserPlus className="absolute left-6 top-1/2 -translate-y-1/2 text-brand-primary w-5 h-5" />
                  <input
                    required
                    type="email"
                    placeholder="Enter recipient email address"
                    className="w-full bg-white/5 border border-white/10 py-6 pl-16 pr-8 text-white font-black uppercase italic tracking-tighter focus:outline-none focus:border-brand-primary transition-all text-lg"
                    value={recipientEmail}
                    onChange={(e) => setRecipientEmail(e.target.value)}
                  />
                </div>
              </div>

              <div className="p-8 bg-black border border-white/5 space-y-4">
                 <div className="flex items-start">
                    <ShieldAlert className="w-6 h-6 text-brand-accent mr-4 shrink-0" />
                    <p className="text-[11px] text-white/40 font-bold leading-relaxed italic uppercase tracking-tighter">Warning: Sending this ticket will permanently remove it from your account. The recipient will receive it instantly once you authorize. This cannot be undone.</p>
                 </div>
              </div>

              <button
                type="submit"
                disabled={sending}
                className="primary-button w-full text-sm disabled:opacity-20"
              >
                {sending ? 'Sending...' : 'Send Ticket'}
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
  );
}
