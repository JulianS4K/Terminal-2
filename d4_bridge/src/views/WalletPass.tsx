// WalletPass — fullscreen, lock-screen-friendly ticket pass.
//
// Lives at /wallet/pass/:ticketId. The user opens this when they get
// to the door: it auto-keeps the screen awake (Wake Lock API), hides
// the platform chrome (bare layout — see ChromeLayout in App.tsx),
// and shows a single big QR code plus the minimum information a door
// scanner / runner needs.
//
// We render this regardless of whether the holder added the ticket to
// Apple/Google Wallet — many users won't, especially on desktop. The
// native-wallet integrations are an enhancement on top of this.
//
// Status semantics — the QR is muted and the page shows a clear stamp
// when the ticket is:
//   * status === 'used'      → ENTERED (scanned in at the door)
//   * status === 'voided'    → REFUNDED (organizer revoked / refunded)
//   * pendingTransferId set  → IN TRANSFER (mid-flight to a recipient)
// The same checks happen server-side at the door scanner — this UI
// state is for the holder, not enforcement.
//
// Live updates — the ticket is re-fetched on a short poll so an
// organizer-side void / scan / transfer-claim flips this screen within
// ~15s, even while the holder is mid-stride at the door.

import { useEffect, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { QRCodeSVG } from 'qrcode.react';
import { ArrowLeft, Sun, Lock } from 'lucide-react';
import TicketPhaseCountdown, { type CountdownPhase } from '../components/TicketPhaseCountdown';
import { motion } from 'motion/react';
import { getTicket } from '../lib/tickets';
import { Event, Ticket } from '../types';
import { useAuth } from '../context/AuthContext';
import { signBarcode, signBarcodeV2, currentBucket } from '../lib/barcode';
import { issueV2 } from '../lib/barcodeFlags';
import { formatInTz, isWithinHoursBefore } from '../lib/datetime';

export default function WalletPass() {
  const { ticketId } = useParams();
  const navigate = useNavigate();
  const { user } = useAuth();
  const [ticket, setTicket] = useState<Ticket | null>(null);
  const [event, setEvent] = useState<Event | null>(null);
  const [barcode, setBarcode] = useState('');
  const [timeLeft, setTimeLeft] = useState(30);

  // Ticket + event load, polled every 15s so an organizer-side void / scan /
  // transfer-claim propagates to the screen the holder is showing the door
  // staff. Without it a refunded ticket could sit on the holder's lock screen
  // for minutes. (Replaces the Firestore onSnapshot live subscription; a
  // Supabase Realtime channel is the eventual upgrade if 15s feels laggy.)
  // getTicket joins the event, so one call covers both.
  useEffect(() => {
    if (!ticketId) return undefined;
    let cancelled = false;
    const load = async () => {
      try {
        const t = await getTicket(ticketId);
        if (cancelled) return;
        setTicket(t);
        setEvent(t?.event ?? null);
      } catch {
        /* transient read error — keep the last good render */
      }
    };
    void load();
    const poll = setInterval(load, 15000);
    return () => {
      cancelled = true;
      clearInterval(poll);
    };
  }, [ticketId]);

  // Rotating barcode refresh — same model as TicketDetail. Re-derives
  // the signed payload at every bucket boundary using the per-ticket
  // secret. Falls back to the legacy unsigned format for tickets that
  // don't carry a secret (organizer scanner tolerates them as legacy).
  // Depend on the primitive ticket fields, NOT the whole `ticket` object: the
  // 15s poll above replaces `ticket` with a fresh (equal-id) object every tick,
  // which previously re-ran this effect and reset the countdown to 30 — the
  // "switching tabs / waiting resets the timer" behavior. The QR was always
  // valid (it's derived from wall-clock), but the visible timer was misleading.
  const ticketId2 = ticket?.id;
  const barcodeSecret = ticket?.barcodeSecret;
  const uid = user?.uid;
  useEffect(() => {
    if (!ticketId2 || !uid) return undefined;
    let cancelled = false;
    let lastBucket = -1;
    const refresh = async () => {
      const bucket = currentBucket();
      lastBucket = bucket;
      if (barcodeSecret) {
        try {
          // v2 issuance (flag-gated) emits the compact binary `T2-` code; the
          // client can only sign the symmetric hmac scheme (ed25519 signing is
          // a server-side concern). Default stays on the v1 `T-` HMAC code.
          const signed = issueV2
            ? await signBarcodeV2({ ticketId: ticketId2, ownerId: uid, scheme: 'hmac', secret: barcodeSecret, bucket })
            : await signBarcode(ticketId2, uid, barcodeSecret, bucket);
          if (!cancelled) setBarcode(signed);
          return;
        } catch (err) {
          console.warn('Falling back to legacy unsigned barcode:', err);
        }
      }
      if (!cancelled) setBarcode(`T-${ticketId2}:${uid}:${bucket}`);
    };
    const tick = () => {
      if (cancelled) return;
      // Wall-clock countdown — accurate across re-renders and background-tab
      // timer throttling (a naive decrement drifts when the tab is hidden).
      const secs = 30 - (Math.floor(Date.now() / 1000) % 30);
      setTimeLeft(secs === 0 ? 30 : secs);
      // Re-sign when the 30s bucket actually rolls over.
      if (currentBucket() !== lastBucket) void refresh();
    };
    void refresh();
    const interval = setInterval(tick, 1000);
    // Re-issue immediately on return to the tab: a throttled background timer
    // can otherwise leave a stale (expired-bucket) QR on screen at the door.
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
  }, [ticketId2, barcodeSecret, uid]);

  // Best-effort screen wake lock. Keeps the screen awake while the
  // holder is showing this page at the door. Falls through silently
  // when unsupported (Safari iOS < 16.4, Firefox).
  useEffect(() => {
    let lock: { release?: () => Promise<void> } | null = null;
    void (async () => {
      try {
        // Wake Lock API isn't in the default TS lib types yet.
        const nav = navigator as unknown as {
          wakeLock?: { request: (type: string) => Promise<{ release: () => Promise<void> }> };
        };
        lock = (await nav.wakeLock?.request?.('screen')) ?? null;
      } catch {
        /* unsupported / page hidden / user-gesture missing — non-fatal */
      }
    })();
    return () => {
      try {
        void lock?.release?.();
      } catch {
        /* */
      }
    };
  }, []);

  if (!ticket) {
    return (
      <div className="wall min-h-screen flex items-center justify-center text-center">
        <p className="type text-white/50 uppercase tracking-[0.3em] text-[12px] animate-pulse">// loading pass…</p>
      </div>
    );
  }

  // Identity gate — only the owner sees the live barcode. The
  // Firestore rule already enforces this for the document read,
  // but the UI guards against rendering a stale-cached pass.
  if (!user || user.uid !== ticket.ownerId) {
    return (
      <div className="wall min-h-screen text-white flex flex-col items-center justify-center p-8 text-center">
        <p className="type text-[11px] uppercase tracking-widest text-brand-accent mb-4">
          // pass not available
        </p>
        <p className="type text-white/60 text-sm max-w-md leading-relaxed">
          You need to be signed in as the ticket holder to display this pass at the door.
        </p>
        <Link to="/my-tickets" className="disp mt-8 px-6 py-3 bg-brand-primary text-black text-lg tracking-wide hover:bg-white transition-colors">
          GO TO MY TICKETS
        </Link>
      </div>
    );
  }

  const isUsed = ticket.status === 'used';
  const isVoided = ticket.status === 'voided';
  const isInTransfer = !!(ticket as { pendingTransferId?: string | null }).pendingTransferId;
  const muted = isUsed || isVoided || isInTransfer;
  // Entry QR only renders within 24h of the event (unknown date → unlocked).
  const qrUnlocked = isWithinHoursBefore(event?.date?.toDate?.(), 24);

  // Milestone chain for the evolving pass countdown: reveal → doors → show
  // start → set times. `revealAt` mirrors the qrUnlocked 24h window. Doors +
  // show-start come from event.timing when present (fall back start → date).
  // Set times aren't in the event model yet — when a `timing.setTimes` field is
  // added, map it into `setTimePhases` and the post-reveal chain lights up with
  // zero further wiring.
  const REVEAL_HOURS_BEFORE = 24;
  const eventStart = event?.date?.toDate?.() ?? null;
  const revealAt = eventStart
    ? new Date(eventStart.getTime() - REVEAL_HOURS_BEFORE * 60 * 60 * 1000)
    : null;
  const doorsAt = event?.timing?.doorsOpen?.toDate?.() ?? null;
  const showStartAt = event?.timing?.startTime?.toDate?.() ?? eventStart;
  const setTimePhases: CountdownPhase[] = (event?.timing?.setTimes ?? [])
    .map((s, i): CountdownPhase | null => {
      const at = s.at?.toDate?.();
      return at && !Number.isNaN(at.getTime())
        ? { key: `set-${i}`, label: `${s.label} in`, at }
        : null;
    })
    .filter((p): p is CountdownPhase => p !== null);
  const postRevealPhases: CountdownPhase[] = [
    ...(doorsAt ? [{ key: 'doors', label: 'Doors open in', at: doorsAt }] : []),
    ...(showStartAt ? [{ key: 'start', label: 'Show starts in', at: showStartAt }] : []),
    ...setTimePhases,
  ];
  const stamp = isVoided
    ? {
        text: 'REFUNDED',
        sub: ticket.voidedReason || 'Refund issued by organizer',
        cls: 'bg-rose-600',
      }
    : isUsed
    ? {
        text: 'ENTERED',
        sub:
          ticket.checkInDate && event
            ? `Scanned ${formatInTz(ticket.checkInDate.toDate(), event.timezone, {
                hour: '2-digit',
                minute: '2-digit',
                month: 'short',
                day: 'numeric',
              })}`
            : 'SCANNED',
        cls: 'bg-red-600',
      }
    : isInTransfer
    ? {
        text: 'IN TRANSFER',
        sub: 'Cancel the transfer to use this ticket again',
        cls: 'bg-amber-500',
      }
    : null;

  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      className="wall grain min-h-screen text-white flex flex-col"
    >
      {/* Bare-route grain overlay. This screen renders without the shared
          ChromeLayout, so the photocopier-noise texture (defined globally in
          the mockups, not in index.css) is reproduced locally here. */}
      <style>{`.grain::before{ content:""; position:fixed; inset:0; z-index:1; pointer-events:none; opacity:.055; mix-blend-mode:overlay; background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='180' height='180'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E"); }`}</style>

      {/* Top chrome — minimal back link + tiny "max brightness"
          reminder. Deliberately no navbar — we want every pixel for
          the QR. */}
      <div className="flex items-center justify-between px-6 py-4 relative z-10">
        <button
          onClick={() => navigate(-1)}
          className="type text-[11px] uppercase tracking-widest text-white/60 hover:text-white flex items-center gap-2"
        >
          <ArrowLeft size={14} aria-hidden="true" /> back
        </button>
        <div className="type text-[10px] uppercase tracking-widest text-white/30 flex items-center gap-2">
          <Sun size={12} aria-hidden="true" /> max brightness for best scan
        </div>
      </div>

      {/* Main pass surface — centered QR with event + tier metadata. */}
      <div className="flex-1 flex flex-col items-center justify-center px-6 pb-12 relative z-10">
        <div className="bg-white text-black rounded-[2rem] p-8 shadow-2xl max-w-md w-full relative overflow-hidden">
          <div className="text-center mb-5">
            <p className="disp text-2xl tracking-tight leading-none">
              {event?.title || 'Event'}
            </p>
            {event?.date ? (
              <p className="type text-[11px] uppercase tracking-widest text-black/50 mt-1">
                {formatInTz(event.date.toDate(), event.timezone, {
                  weekday: 'short',
                  month: 'short',
                  day: 'numeric',
                  hour: 'numeric',
                  minute: '2-digit',
                })}
              </p>
            ) : null}
          </div>

          <div className="relative flex flex-col items-center">
            <div className={`p-4 bg-white border-[3px] border-black rounded-2xl ${muted ? 'opacity-20 grayscale' : ''}`}>
              {qrUnlocked ? (
                <QRCodeSVG value={barcode || ticket.id} size={260} level="H" marginSize={4} fgColor="#000000" />
              ) : (
                <div className="w-[260px] h-[260px] flex flex-col items-center justify-center text-center px-6">
                  <Lock className="w-9 h-9 text-black/30 mb-3" aria-hidden="true" />
                  <p className="type text-[11px] uppercase tracking-widest text-black/50">Entry code locked</p>
                  {revealAt ? (
                    <TicketPhaseCountdown
                      className="mt-3"
                      phases={[{ key: 'reveal', label: 'Unlocks in', at: revealAt }]}
                    />
                  ) : null}
                  <p className="type text-[11px] text-black/40 mt-3">
                    {event?.date
                      ? formatInTz(event.date.toDate(), event.timezone, {
                          month: 'short',
                          day: 'numeric',
                          hour: 'numeric',
                          minute: '2-digit',
                        })
                      : 'Date TBA'}
                  </p>
                </div>
              )}
            </div>

            {stamp ? (
              <div className="absolute inset-0 flex flex-col items-center justify-center pointer-events-none">
                <div
                  className={`${stamp.cls} text-white px-8 py-3 font-black text-2xl uppercase italic tracking-tighter -rotate-12 shadow-2xl skew-x-12`}
                >
                  {stamp.text}
                </div>
                <p className="text-black font-black text-[10px] uppercase tracking-widest mt-4 bg-white px-3 py-1 text-center max-w-[80%]">
                  {stamp.sub}
                </p>
              </div>
            ) : null}
          </div>

          {!muted && qrUnlocked && postRevealPhases.length > 0 ? (
            <div className="mt-6 flex flex-col items-center text-center">
              <TicketPhaseCountdown phases={postRevealPhases} doneLabel="Enjoy the show ✦" />
            </div>
          ) : null}

          <div className="mt-6 pt-6 border-t border-dashed border-black/20 flex justify-between items-end">
            <div className="text-left">
              <p className="type text-[9px] uppercase tracking-widest text-black/40 mb-1">holder</p>
              <p className="disp text-lg tracking-tight leading-none">
                {user.displayName || user.email || 'Guest'}
              </p>
            </div>
            <div className="text-right">
              <p className="type text-[9px] uppercase tracking-widest text-black/40 mb-1">tier</p>
              <p className="disp text-lg tracking-tight leading-none">{ticket.tierName || 'GA'}</p>
            </div>
          </div>

          {!muted && qrUnlocked ? (
            <div className="mt-6 flex flex-col items-center">
              <p className="type text-[9px] text-black/40 uppercase tracking-widest">code refreshes in</p>
              <p className="disp text-3xl text-black tracking-tight leading-none mt-1">
                00:{timeLeft.toString().padStart(2, '0')}
              </p>
              <div className="w-32 h-[3px] bg-black/10 mt-3">
                <div
                  className="h-full bg-brand-primary transition-all duration-1000"
                  style={{ width: `${(timeLeft / 30) * 100}%` }}
                />
              </div>
            </div>
          ) : null}

          <div className="mt-6 text-center">
            <p className="type text-[9px] text-black/30 break-all">{ticket.id}</p>
          </div>
        </div>
      </div>

      <div className="px-6 pb-6 text-center relative z-10">
        <p className="type text-[9px] uppercase tracking-[0.3em] text-white/20">
          Exos · Scan-Only Pass
        </p>
      </div>
    </motion.div>
  );
}
