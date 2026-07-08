import { useEffect, useState, FormEvent } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { getTicket, createTransfer } from '../lib/tickets';
import { Ticket, Event } from '../types';
import { useAuth } from '../context/AuthContext';
import { ArrowLeft, UserPlus, ShieldAlert, Send, Check, Copy } from 'lucide-react';
import { queueEmail } from '../lib/mail';
import { publicUrl } from '../lib/utils';
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

      // Best-effort: notify the receiver. Recipient + body are server-derived
      // by the exos_queue_mail RPC (mig 20260520160000). queueEmail never throws.
      void queueEmail({ template: 'transfer-initiated', refId: transferId });

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

  if (loading) return (
    <div className="wall min-h-screen flex items-center justify-center">
      <p className="disp text-3xl tracking-tight text-white/20 animate-pulse" style={{ transform: 'skewX(-4deg)' }}>LOADING TICKET…</p>
    </div>
  );
  if (!ticket || ticket.ownerId !== user?.uid) return (
    <div className="wall min-h-screen flex items-center justify-center">
      <p className="disp text-4xl tracking-tight text-brand-accent" style={{ transform: 'skewX(-4deg)' }}>ACCESS DENIED</p>
    </div>
  );

  // After a successful transfer, render the share-link success state
  // instead of the form. The sender keeps the page open, copies the
  // claim link, and pastes it into whatever messaging app they prefer.
  if (completedTransferId) {
    const claimUrl = publicUrl(`claim/${completedTransferId}`);
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
      <div className="wall min-h-screen text-white">
        <div className="max-w-2xl mx-auto px-4 py-16 relative z-10">
          <div className="flex items-center justify-between mb-14">
            <div>
              <p className="type text-brand-primary text-[12px] uppercase tracking-widest mb-2">// transfer sent</p>
              <h1 className="disp text-5xl tracking-tight leading-none" style={{ transform: 'skewX(-4deg)' }}>SHARE THE LINK</h1>
            </div>
            <div className="w-14 h-14 bg-brand-primary flex items-center justify-center">
              <Check className="text-black w-6 h-6" />
            </div>
          </div>

          <div className="bg-[#111] border border-white/10 p-9 mb-8">
            <p className="type text-[10px] text-white/30 uppercase tracking-widest mb-2">sent to</p>
            <p className="disp text-3xl tracking-tight leading-none mb-8 break-all">{completedReceiverEmail}</p>
            <p className="type text-[10px] text-white/30 uppercase tracking-widest mb-2">claim link</p>
            <div className="bg-black border border-white/10 p-5 flex items-center justify-between gap-3 mb-6">
              <code className="type text-[11px] text-white/70 break-all flex-1">{claimUrl}</code>
              <button
                type="button"
                onClick={handleCopy}
                className={`disp shrink-0 px-4 py-2 text-sm tracking-wide transition-all flex items-center gap-2 ${
                  linkCopied ? 'bg-brand-primary text-black' : 'bg-white text-black hover:bg-brand-primary'
                }`}
              >
                {linkCopied ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
                {linkCopied ? 'COPIED' : 'COPY'}
              </button>
            </div>
            <p className="type text-[12px] text-white/45 leading-relaxed">
              We've also queued an email to {completedReceiverEmail} with this link. Send the link directly via text or any other app — the receiver signs in with the email above to claim.
            </p>
          </div>

          <button
            type="button"
            onClick={() => navigate('/my-tickets')}
            className="disp w-full bg-white text-black py-4 text-xl tracking-wide hover:bg-brand-primary transition-all"
          >
            BACK TO TICKETS
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="wall min-h-screen text-white">
      <div className="max-w-2xl mx-auto px-4 py-16 relative z-10">
        <div className="flex items-center justify-between mb-14">
          <div>
            <p className="type text-brand-primary text-[12px] uppercase tracking-widest mb-2">// transfer ticket</p>
            <h1 className="disp text-5xl tracking-tight leading-none" style={{ transform: 'skewX(-4deg)' }}>SEND TICKET</h1>
          </div>
          <div className="w-14 h-14 bg-white flex items-center justify-center">
            <Send className="text-black w-6 h-6" />
          </div>
        </div>

        <div className="group bg-[#111] border border-white/10 p-9">
          <div className="flex items-center gap-6 mb-10">
             <div className="w-24 h-32 bg-white/5 border border-white/10 overflow-hidden shrink-0">
                <img src={event?.image} alt="" className="xerox w-full h-full object-cover" />
             </div>
             <div>
                <p className="type text-[10px] text-white/30 uppercase tracking-widest mb-1">ticket details</p>
                <h2 className="disp text-3xl tracking-tight leading-none mb-2">{event?.title}</h2>
                <p className="type text-[11px] text-brand-primary uppercase tracking-widest">tier: {ticket.tierName || 'GENERAL'}</p>
             </div>
          </div>

          <form onSubmit={handleTransfer} className="space-y-8">
            <div className="space-y-3">
              <label className="type text-[10px] text-white/30 uppercase tracking-widest ml-1">recipient email</label>
              <div className="relative">
                <UserPlus className="absolute left-5 top-1/2 -translate-y-1/2 text-brand-primary w-5 h-5" />
                <input
                  required
                  type="email"
                  placeholder="enter recipient email address"
                  className="type w-full bg-white/5 border border-white/10 py-5 pl-14 pr-6 text-white placeholder-white/35 focus:outline-none focus:border-brand-primary transition-all text-base tracking-wide"
                  value={recipientEmail}
                  onChange={(e) => setRecipientEmail(e.target.value)}
                />
              </div>
            </div>

            <div className="p-6 bg-black border border-white/5 flex items-start gap-4">
               <ShieldAlert className="w-6 h-6 text-brand-accent shrink-0" />
               <p className="type text-[12px] text-white/45 leading-relaxed">Warning: Sending this ticket permanently removes it from your account. The recipient receives it instantly once you authorize. This cannot be undone.</p>
            </div>

            <button
              type="submit"
              disabled={sending}
              className="disp w-full bg-brand-primary text-black py-4 text-xl tracking-wide hover:scale-[1.01] transition-transform disabled:opacity-20"
            >
              {sending ? 'SENDING…' : 'SEND TICKET'}
            </button>
          </form>
        </div>
      </div>
    </div>
  );
}
