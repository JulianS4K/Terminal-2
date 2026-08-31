import React, { useState, useEffect, useRef } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { getEventForEdit, getPublicEvent } from '../lib/events';
import {
  getTicketForScan,
  listEventTicketsForRegistry,
  checkInTicket,
  recordScanReject,
  countEventCheckins,
  setCheckinTestWindow,
  type ScanTicket,
} from '../lib/tickets';
import { Ticket, Event } from '../types';
import { Search, CheckCircle2, XCircle, ArrowLeft, Loader2, User, Camera, ScanLine, Download, Wifi, WifiOff, RefreshCw } from 'lucide-react';
import { motion, AnimatePresence } from 'motion/react';
import { Html5Qrcode } from 'html5-qrcode';
import { useAuth } from '../context/AuthContext';
import { useToast } from '../context/ToastContext';
import { verifyAnyBarcode, extractTicketIdFromAny } from '../lib/barcode';
import { joinCheckinChannel } from '../lib/checkinChannel';
import { OfflineCheckInQueue, type PendingCheckIn } from '../lib/offlineQueue';

// Anything older than this is dropped from localStorage when the page mounts.
// Set to a generous 7 days so a multi-day festival is still cached on day 3.
const REGISTRY_TTL_MS = 7 * 24 * 60 * 60 * 1000;

interface OfflineTicketEntry {
  used: boolean;
  voided?: boolean;
  name: string;
  tier: string;
  ownerId?: string;
  barcodeSecret?: string;
  promoterId?: string;
  // Pending-transfer lock. When set, the ticket is mid-flight to a
  // receiver and the offline scan path refuses entry. Picked up on
  // each registry refresh so the lock propagates within a refresh
  // cycle even when the door staff is fully offline-cached.
  pendingTransferId?: string | null;
}

interface StoredRegistry {
  _savedAt: number;
  data: Record<string, OfflineTicketEntry>;
}

function saveRegistry(eventId: string, data: StoredRegistry['data']) {
  const payload: StoredRegistry = { _savedAt: Date.now(), data };
  localStorage.setItem(`registry_${eventId}`, JSON.stringify(payload));
}

function pruneStaleCheckInCaches() {
  const now = Date.now();
  const toDelete: string[] = [];
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (!key || !key.startsWith('registry_')) continue;
    try {
      const raw = localStorage.getItem(key);
      if (!raw) continue;
      const parsed = JSON.parse(raw);
      // Legacy entries (no _savedAt wrapper) are old-format and considered
      // stale by definition — they predate this hygiene pass.
      if (
        !parsed ||
        typeof parsed !== 'object' ||
        typeof parsed._savedAt !== 'number' ||
        now - parsed._savedAt > REGISTRY_TTL_MS
      ) {
        toDelete.push(key);
      }
    } catch {
      toDelete.push(key);
    }
  }
  // Also drop matching `pending_updates_*` for any registry we deleted —
  // pending updates without a registry have no useful UX anyway.
  for (const k of toDelete) {
    localStorage.removeItem(k);
    const eventId = k.slice('registry_'.length);
    localStorage.removeItem(`pending_updates_${eventId}`);
    localStorage.removeItem(`pending_checkins_v2_${eventId}`);
  }
}

export default function OrganizerCheckIn() {
  const { eventId } = useParams();
  const navigate = useNavigate();
  const { user } = useAuth();
  const { toast } = useToast();
  const [event, setEvent] = useState<Event | null>(null);
  const [searchId, setSearchId] = useState('');
  const [status, setStatus] = useState<'idle' | 'searching' | 'success' | 'not-found' | 'already-used' | 'invalid-barcode'>('idle');
  // Reason text shown in the 'invalid-barcode' state — populated by the
  // HMAC verifier so the operator knows whether the issue was a stale
  // barcode (screenshot from earlier) or a forged one.
  const [invalidReason, setInvalidReason] = useState<string>('');
  // Set when a check-in is refused because doors aren't open yet — surfaces an
  // owner/manager "enable test scanning" control (RPC is server-gated).
  const [doorsBlocked, setDoorsBlocked] = useState(false);
  const [enablingTest, setEnablingTest] = useState(false);
  const [foundTicket, setFoundTicket] = useState<Ticket | null>(null);
  const [buyerName, setBuyerName] = useState<string>('');
  const [scanning, setScanning] = useState(false);
  const [isOffline, setIsOffline] = useState(!navigator.onLine);
  const [offlineRegistry, setOfflineRegistry] = useState<Record<string, OfflineTicketEntry>>({});
  const [downloading, setDownloading] = useState(false);
  const [syncing, setSyncing] = useState(false);
  // Durable, crash-safe offline check-in queue (lib/offlineQueue.ts). Each item
  // carries a stable idempotency key so a reconnect replay after a crash is a
  // server-side no-op (mig 20260713120000) rather than a second audit row.
  // `pending` mirrors the queue for rendering; `queueRef` is the source of truth.
  const [pending, setPending] = useState<PendingCheckIn[]>([]);
  const queueRef = useRef<OfflineCheckInQueue | null>(null);
  const [recentScans, setRecentScans] = useState<{ id: string, name: string, time: Date, status: string }[]>([]);
  // "Inside venue" = tickets actually scanned in (exos_event_checkins count),
  // NOT tickets sold. Seeded on mount; refreshed by the realtime channel below
  // as scans land (this lane + others).
  const [insideVenue, setInsideVenue] = useState(0);
  const scannerRef = useRef<Html5Qrcode | null>(null);
  // Holds the setTimeout ID for the deferred camera start so stopScanner()
  // can cancel a pending start that hasn't fired yet. Without this, if
  // stopScanner is called within the 50ms window, scannerRef.current is still
  // null (timeout hasn't run) so stopScanner is a no-op, then the timeout
  // fires and starts the camera with no owner to shut it down.
  const startScannerTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wasOfflineRef = useRef(isOffline);

  useEffect(() => {
    async function fetchEvent() {
      if (!eventId) return;
      try {
        // Staff RLS on exos_events lets door staff read the event (any status).
        const ev = await getEventForEdit(eventId);
        if (ev) setEvent(ev);
      } catch (err) {
        console.error('Failed to load event for check-in:', err);
      }
    }
    fetchEvent();

    const handleSyncStatus = () => setIsOffline(!navigator.onLine);
    window.addEventListener('online', handleSyncStatus);
    window.addEventListener('offline', handleSyncStatus);

    // Sweep stale offline-check-in caches from previous events.
    //
    // We tag each registry payload with `_savedAt` and prune anything older
    // than 7 days on mount. Without this, every event the organizer checks
    // attendees in for accumulates ~one entry per attendee in localStorage
    // forever and eventually trips the ~5MB browser quota.
    pruneStaleCheckInCaches();

    // Load registry and pending updates for THIS event, if cached.
    if (eventId) {
      const saved = localStorage.getItem(`registry_${eventId}`);
      if (saved) {
        try {
          const parsed = JSON.parse(saved);
          // Older payloads were stored as plain Record<id, entry>; newer ones
          // wrap the data in `{ _savedAt, data }`. Handle both shapes.
          if (parsed && typeof parsed === 'object' && parsed.data) {
            setOfflineRegistry(parsed.data);
          } else {
            setOfflineRegistry(parsed);
          }
        } catch {
          // Corrupt cache — drop it.
          localStorage.removeItem(`registry_${eventId}`);
        }
      }
      const queue = new OfflineCheckInQueue(localStorage, eventId);
      queueRef.current = queue;
      // One-time migration: fold any legacy `pending_updates_<id>` array (bare
      // ids, no idempotency key) into the new queue, then drop the old key so a
      // partially-upgraded device doesn't replay from two stores.
      const legacy = localStorage.getItem(`pending_updates_${eventId}`);
      if (legacy) {
        try {
          const ids: unknown = JSON.parse(legacy);
          if (Array.isArray(ids)) {
            for (const id of ids) {
              if (typeof id === 'string') queue.enqueue({ ticketId: id, source: 'manual', verification: 'manual' });
            }
          }
        } catch {
          /* corrupt legacy value — dropped below */
        }
        localStorage.removeItem(`pending_updates_${eventId}`);
      }
      setPending(queue.list());
    }

    return () => {
      window.removeEventListener('online', handleSyncStatus);
      window.removeEventListener('offline', handleSyncStatus);
      void stopScanner();
    };
  }, [eventId]);

  useEffect(() => {
    if (!isOffline && pending.length > 0) {
      syncPendingUpdates();
    }
  }, [isOffline, pending.length]);

  const syncPendingUpdates = async () => {
    const queue = queueRef.current;
    if (!queue || queue.size() === 0 || syncing) return;
    setSyncing(true);
    try {
      // queue.flush retries each item independently (one failure never aborts
      // the rest) and drops committed OR already-'used' items while keeping ones
      // that only threw (network/auth) for next time — same drop semantics as
      // the old loop. The crash-safety upgrade: each replay carries the item's
      // stable idempotency key, so a check-in the server already committed
      // (crash between commit and dequeue) returns the stored result and writes
      // NO second exos_event_checkins row.
      //
      // Replays go through as a manual override (source/verification 'manual',
      // no barcode payload): by reconnect time the 30s barcode bucket is stale
      // and would be rejected — the admission decision was already made offline,
      // so this records it rather than re-verifying. Mirrors the prior behavior.
      await queue.flush((item) =>
        checkInTicket(item.ticketId, 'manual', 'manual', undefined, eventId, item.idempotencyKey),
      );
    } finally {
      setPending(queue.list());
      setSyncing(false);
    }
  };

  // Queue an offline-admitted check-in for durable, crash-safe replay. Dedupes
  // by ticket id (a double-scan at the door can't enqueue twice) and mints a
  // stable idempotency key. Records the original source/verification for the
  // audit even though the replay itself goes through as a manual override.
  const enqueueOffline = (
    docId: string,
    barcodePayload: string,
    offlineTicket: OfflineTicketEntry,
  ) => {
    const queue = queueRef.current;
    if (!queue) return;
    queue.enqueue({
      ticketId: docId,
      source: scanning ? 'camera' : 'manual',
      verification: offlineTicket.barcodeSecret ? 'verified' : 'manual',
      barcodePayload,
    });
    setPending(queue.list());
  };

  // Tear down the live camera scanner safely. stop() rejects if the camera
  // isn't actively running, so guard on state and swallow that case.
  const stopScanner = async () => {
    // Cancel any pending deferred start so the camera doesn't open after we
    // shut down (the 50ms timeout may not have fired yet when stopScanner is
    // called, e.g. on unmount or stop-button tap).
    if (startScannerTimeoutRef.current !== null) {
      clearTimeout(startScannerTimeoutRef.current);
      startScannerTimeoutRef.current = null;
    }
    const s = scannerRef.current;
    scannerRef.current = null;
    if (!s) return;
    try {
      if (s.isScanning) await s.stop();
    } catch {
      /* not scanning / already stopped */
    }
    try {
      s.clear();
    } catch {
      /* element already torn down */
    }
  };

  const startScanner = () => {
    setScanning(true);
    setStatus('idle');

    // Defer one tick so the #reader container is in the DOM, then open the
    // back camera DIRECTLY (facingMode: environment). The previous
    // Html5QrcodeScanner widget required a second "Request Camera / Start"
    // tap that often never activated the camera on phones, and its fixed
    // 250px qrbox threw on narrow viewports (video < box) — both fixed here.
    startScannerTimeoutRef.current = setTimeout(async () => {
      startScannerTimeoutRef.current = null;
      try {
        const html5Qr = new Html5Qrcode('reader');
        scannerRef.current = html5Qr;
        await html5Qr.start(
          { facingMode: 'environment' },
          {
            fps: 10,
            // Responsive box: 70% of the smaller video dimension, so it
            // never exceeds the camera frame on small phones.
            qrbox: (vw: number, vh: number) => {
              const m = Math.floor(Math.min(vw, vh) * 0.7);
              return { width: m, height: m };
            },
          },
          (decodedText: string) => {
            setSearchId(decodedText);
            handleCheckIn(undefined, decodedText);
            void stopScanner();
            setScanning(false);
          },
          () => {
            /* per-frame decode miss — ignore */
          },
        );
      } catch (err) {
        console.error('Camera start failed:', err);
        toast({
          kind: 'error',
          message:
            'Could not open the camera. Allow camera access for this site in your browser settings, or type the ticket ID below to check in.',
        });
        scannerRef.current = null;
        setScanning(false);
      }
    }, 50);
  };

  /**
   * Build a CSV from the in-memory offline registry and trigger a browser
   * download. We deliberately don't refetch from Firestore — the registry
   * already represents what the organizer cares about (ticket id, attendee
   * name, tier, used/unused). For a richer export with email/checkInDate
   * the organizer can extend this.
   */
  const exportAttendeesCsv = async () => {
    let entries = Object.entries(offlineRegistry);
    // Auto-sync if the operator hits Export before they've ever
    // downloaded the registry. Skip if we're offline (downloadRegistry
    // would just fail) — in that case the toast tells them what to do.
    if (entries.length === 0) {
      if (isOffline) {
        toast({
          kind: 'info',
          message: 'No registry data — connect to the network and sync first.',
        });
        return;
      }
      toast({ kind: 'info', message: 'Syncing attendees first…' });
      await downloadRegistry();
      // Re-read state after the sync. We can't rely on closure-captured
      // offlineRegistry — pull from localStorage which the sync just
      // wrote, then fall through to the CSV build.
      try {
        const raw = localStorage.getItem(`registry_${eventId}`);
        if (raw) {
          const parsed = JSON.parse(raw);
          const data = (parsed && parsed.data) || parsed;
          entries = Object.entries(data);
        }
      } catch {
        /* ignore — we'll just fall through to "no entries" */
      }
      if (entries.length === 0) {
        toast({ kind: 'warn', message: 'No attendees to export yet.' });
        return;
      }
    }
    const escape = (v: unknown) => {
      const s = String(v ?? '');
      // Wrap in quotes and escape any internal quotes/commas/newlines.
      if (/[",\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
      return s;
    };
    const header = ['ticket_id', 'attendee', 'tier', 'status', 'promoter'];
    const rows = entries.map(([id, raw]) => {
      // `Object.entries` widens our typed Record values to `unknown`; cast
      // back to the row shape we put in.
      const e = raw as OfflineTicketEntry;
      return [id, e.name, e.tier, e.voided ? 'voided' : e.used ? 'used' : 'active', e.promoterId || ''];
    });
    const csv = [header, ...rows]
      .map((row) => row.map(escape).join(','))
      .join('\r\n');

    const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `attendees-${eventId || 'event'}-${new Date()
      .toISOString()
      .slice(0, 10)}.csv`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    // Free the blob URL after the download tick.
    setTimeout(() => URL.revokeObjectURL(url), 0);

    toast({ kind: 'success', message: `Exported ${rows.length} attendee(s).` });
  };

  const downloadRegistry = async (opts: { silent?: boolean } = {}) => {
    if (!eventId || !user) return;
    const silent = opts.silent === true;
    if (!silent) setDownloading(true);
    try {
      // listEventTicketsForRegistry resolves owner display names + carries the
      // per-ticket barcode_secret (staff RLS) so the offline HMAC check works.
      const entries = await listEventTicketsForRegistry(eventId);
      const registry: Record<string, OfflineTicketEntry> = {};
      for (const e of entries) {
        registry[e.id] = {
          used: e.status === 'used',
          voided: e.status === 'voided',
          name: e.name,
          tier: e.tier,
          ownerId: e.ownerId,
          barcodeSecret: e.barcodeSecret,
          promoterId: e.promoterId,
          pendingTransferId: e.pendingTransferId,
        };
      }

      setOfflineRegistry(registry);
      saveRegistry(eventId, registry);
      if (!silent) {
        toast({
          kind: 'success',
          message: `Synced ${entries.length} ticket(s) for offline check-in.`,
        });
      }
    } catch (err) {
      console.error(err);
      if (!silent) toast({ kind: 'error', message: 'Failed to sync offline registry.' });
    } finally {
      if (!silent) setDownloading(false);
    }
  };

  // Shared-lock (D4-OPS-10): subscribe to other lanes' check-ins for this event
  // and mark those tickets used locally, so a near-simultaneous scan here is
  // refused. Authoritative + RLS-gated (org staff only) via postgres_changes.
  useEffect(() => {
    if (!eventId) return undefined;
    const ch = joinCheckinChannel(eventId, (ticketId) => {
      setOfflineRegistry((prev) => {
        const entry = prev[ticketId];
        if (!entry || entry.used) return prev; // unknown ticket or already used
        const next = { ...prev, [ticketId]: { ...entry, used: true } };
        saveRegistry(eventId, next);
        return next;
      });
      // A check-in landed (this lane or another) — bump the live count by one
      // rather than re-running a count(*) per scan. A count(*) per realtime tick
      // per lane doesn't scale at a busy multi-lane gate; postgres_changes emits
      // exactly one event per check-in row (incl. our own), so +1 is accurate.
      // Reconciled against the authoritative head-count on reconnect below.
      setInsideVenue((n) => n + 1);
    });
    return () => ch.leave();
  }, [eventId]);

  // Seed "inside venue" on mount (the realtime channel keeps it live after).
  useEffect(() => {
    if (!eventId) return undefined;
    let cancelled = false;
    countEventCheckins(eventId)
      .then((n) => { if (!cancelled) setInsideVenue(n); })
      .catch(() => {/* non-fatal */});
    return () => { cancelled = true; };
  }, [eventId]);

  // On reconnect, re-pull the registry: Realtime doesn't replay check-ins other
  // lanes made while we were offline, so catch up silently once links return.
  useEffect(() => {
    if (wasOfflineRef.current && !isOffline) {
      void downloadRegistry({ silent: true });
      // Realtime doesn't replay check-ins that landed while we were
      // disconnected, so reconcile the live count against the authoritative
      // head-count once (the only count(*) on this path — not per scan).
      if (eventId) countEventCheckins(eventId).then(setInsideVenue).catch(() => {});
    }
    wasOfflineRef.current = isOffline;
  }, [isOffline]);

  // Write an audit entry every time we refuse a scan. Organizers
  // see these on the event report — useful for door-staff debugging
  // ("which ticket id keeps getting rejected?") AND for spotting
  // patterns of abuse (broker buying tickets to event_A and
  // attempting to walk into event_B in a refund-then-resell loop).
  // Best-effort: a write failure here logs but doesn't change UI.
  const writeScanReject = async (
    reason:
      | 'wrong-event'
      | 'voided'
      | 'used'
      | 'in-transfer'
      | 'invalid-barcode'
      | 'not-found'
      | 'expired-code',
    source: 'camera' | 'manual',
    ctx: {
      ticketIdAttempted?: string | null;
      wrongEventId?: string;
      wrongEventTitle?: string;
      reasonDetail?: string;
    } = {},
  ) => {
    if (!eventId || !user) return;
    try {
      await recordScanReject({
        eventId,
        orgId: event?.orgId || '',
        reason,
        source,
        ticketIdAttempted: ctx.ticketIdAttempted ?? null,
        wrongEventId: ctx.wrongEventId ?? null,
        wrongEventTitle: ctx.wrongEventTitle ?? null,
        reasonDetail: ctx.reasonDetail ?? null,
      });
    } catch (err) {
      console.warn('scanReject audit write failed (non-fatal):', err);
    }
  };

  const handleCheckIn = async (e?: React.FormEvent, manualValue?: string) => {
    if (e) e.preventDefault();
    const probeValue = manualValue || searchId;
    if (!probeValue || !eventId) return;

    setStatus('searching');
    setFoundTicket(null);
    setInvalidReason('');
    setDoorsBlocked(false);

    // Extract the ticket doc id from the QR payload regardless of format
    // (legacy 3-segment, signed 4-segment, or bare id). HMAC verification
    // happens later, after we've read the ticket doc and have its secret.
    const docId = extractTicketIdFromAny(probeValue) || probeValue;

    // Sanity-check the id length before a lookup so a manual-entry typo can't
    // burn a staff-RLS read on junk. Ticket ids are UUIDs — anything over 128
    // chars can't be a real ticket id.
    if (!docId || docId.length > 128) {
      setStatus('not-found');
      return;
    }

    // Try offline registry first if offline or if we have it
    if (offlineRegistry[docId]) {
      const offlineTicket = offlineRegistry[docId];

      // Detect manual entry. If door staff TYPED a bare doc id (no
      // 'T-' prefix, no ':' separator, and not via the camera), we skip
      // the HMAC verifier — there's no signature to check, and the docId
      // hitting the offline registry is itself the verification (the
      // registry was downloaded under organizer-only rule gating). A
      // CAMERA scan is never treated as bare manual entry: a scanned bare
      // UUID is a forgery downgrade and must fail the signature check.
      const isBareManualEntry =
        !scanning &&
        typeof probeValue === 'string' &&
        !probeValue.startsWith('T-') &&
        !probeValue.includes(':');

      // HMAC verification offline. The registry stores barcodeSecret
      // alongside the ticket metadata at sync time, so we can run the
      // full signature check without a network round-trip.
      //
      // Edge case: a transfer that completes after this registry was
      // synced rotates the per-ticket secret server-side. The new
      // owner's barcode will fail HMAC verification against our cached
      // secret; we surface a clear "code rejected, please re-sync"
      // error to the operator instead of silently admitting a screenshot.
      if (offlineTicket.barcodeSecret && !isBareManualEntry) {
        // verifyAnyBarcode handles both v1 (`T-`) and v2 (`T2-`) codes; the
        // per-ticket secret covers the v1 + v2-hmac schemes offline.
        const verify = await verifyAnyBarcode(probeValue, { secret: offlineTicket.barcodeSecret });
        if (!verify.ok) {
          setStatus('invalid-barcode');
          const reasonText: Record<string, string> = {
            'malformed': 'Could not read this code.',
            'bad-bucket': 'Code is malformed.',
            'bucket-expired':
              'This code expired. Ask the attendee to refresh their ticket.',
            'signature-mismatch':
              "Signature didn't match this ticket. The ticket may have been transferred since the offline registry was synced — re-sync to refresh.",
            'legacy-no-secret':
              'This is an old-format ticket. Ask the attendee to open the app and refresh their ticket, then rescan.',
          };
          setInvalidReason(reasonText[verify.reason || ''] || 'Code rejected.');
          setRecentScans((prev) =>
            [
              { id: docId.slice(0, 8), name: offlineTicket.name, time: new Date(), status: 'DENIED' },
              ...prev,
            ].slice(0, 5),
          );
          const auditReason: 'expired-code' | 'invalid-barcode' =
            verify.reason === 'bucket-expired' ? 'expired-code' : 'invalid-barcode';
          void writeScanReject(auditReason, scanning ? 'camera' : 'manual', {
            ticketIdAttempted: docId,
            reasonDetail: verify.reason || undefined,
          });
          return;
        }
      }
      // Legacy v1 cache (no barcodeSecret) — fall through with a
      // console note. The operator should re-sync the registry.

      if (offlineTicket.pendingTransferId) {
        // Same lock as the online path — offline registry refresh
        // (the auto-pull) propagates the flag, so within one refresh
        // cycle staff sees the lock too.
        setStatus('invalid-barcode');
        setInvalidReason(
          'This ticket is mid-transfer. Ask the holder to either cancel the transfer or have the recipient claim it before scanning.',
        );
        setBuyerName(offlineTicket.name);
        setRecentScans((prev) =>
          [
            { id: docId.slice(0, 8), name: offlineTicket.name, time: new Date(), status: 'DENIED' },
            ...prev,
          ].slice(0, 5),
        );
        void writeScanReject('in-transfer', scanning ? 'camera' : 'manual', {
          ticketIdAttempted: docId,
        });
        return;
      }

      if (offlineTicket.voided) {
        // Voided == refunded. Stays unscannable forever. Door staff
        // should direct the holder to event support.
        setStatus('invalid-barcode');
        setInvalidReason(
          'This ticket was refunded. The holder should not be admitted with this ticket. Direct them to event support if there is a dispute.',
        );
        setBuyerName(offlineTicket.name);
        setRecentScans((prev) =>
          [
            { id: docId.slice(0, 8), name: offlineTicket.name, time: new Date(), status: 'DENIED' },
            ...prev,
          ].slice(0, 5),
        );
        void writeScanReject('voided', scanning ? 'camera' : 'manual', {
          ticketIdAttempted: docId,
        });
        return;
      }

      if (offlineTicket.used) {
        setStatus('already-used');
        setBuyerName(offlineTicket.name);
        setRecentScans(prev => [{ id: docId.slice(0, 8), name: offlineTicket.name, time: new Date(), status: 'DENIED' }, ...prev].slice(0, 5));
        void writeScanReject('used', scanning ? 'camera' : 'manual', {
          ticketIdAttempted: docId,
        });
        return;
      }
      
      // If we are online, flip the ticket server-side now; on failure
      // (network) admit based on the offline registry and queue a replay.
      // Fully offline → always queue.
      if (!isOffline) {
        try {
          const result = await checkInTicket(
            docId,
            scanning ? 'camera' : 'manual',
            offlineTicket.barcodeSecret ? 'verified' : 'manual',
            probeValue,
            eventId,
          );
          // Honor a server-side rejection (barcode secret rotated via a transfer,
          // or doors not open yet) — do NOT admit locally.
          if (!result.ok && (result.reason === 'barcode-rejected' || result.reason === 'barcode-expired' || result.reason === 'doors-not-open')) {
            setStatus('invalid-barcode');
            setInvalidReason(
              result.reason === 'barcode-expired'
                ? 'This code expired. Ask the attendee to refresh their ticket and rescan.'
                : result.reason === 'doors-not-open'
                ? 'Doors are not open yet for this event. Check-in opens at the event’s doors time.'
                : "Signature didn't match this ticket (server check) — it may have been transferred since the offline registry was synced. Re-sync and retry.",
            );
            if (result.reason === 'doors-not-open') setDoorsBlocked(true);
            setBuyerName(offlineTicket.name);
            setRecentScans((prev) =>
              [{ id: docId.slice(0, 8), name: offlineTicket.name, time: new Date(), status: 'DENIED' }, ...prev].slice(0, 5),
            );
            void writeScanReject(
              result.reason === 'barcode-expired' ? 'expired-code' : 'invalid-barcode',
              scanning ? 'camera' : 'manual',
              { ticketIdAttempted: docId, reasonDetail: result.reason },
            );
            return;
          }
        } catch (err) {
          console.error('Server check-in failed; admitting on offline registry and queuing replay.', err);
          enqueueOffline(docId, probeValue, offlineTicket);
        }
      } else {
        enqueueOffline(docId, probeValue, offlineTicket);
      }

      // Mark locally as used
      const updated = { ...offlineRegistry, [docId]: { ...offlineTicket, used: true } };
      setOfflineRegistry(updated);
      if (eventId) saveRegistry(eventId, updated);

      setBuyerName(offlineTicket.name);
      setFoundTicket({ id: docId, tierName: offlineTicket.tier } as any);
      setStatus('success');
      setRecentScans(prev => [{ id: docId.slice(0, 8), name: offlineTicket.name, time: new Date(), status: 'SUCCESS' }, ...prev].slice(0, 5));
      setSearchId('');
      return;
    }

    // Not in the offline registry and we're offline: supabase-js has no offline
    // write queue (unlike the old Firestore SDK), so we can neither verify the
    // ticket nor durably record the reject until the link returns. Surface
    // "not found"; a re-scan once back online audits properly.
    if (isOffline) {
      setStatus('not-found');
      return;
    }

    try {
      // Staff-gated read (exos_tickets RLS). Returns null when the ticket
      // doesn't exist OR the caller isn't staff of its org — both map to
      // "not a valid ticket for this door", which also subsumes the old
      // organizer-mismatch branch (RLS won't return a foreign-org ticket).
      const scanTicket = await getTicketForScan(docId);
      const sourceTag: 'camera' | 'manual' = scanning ? 'camera' : 'manual';

      if (!scanTicket) {
        setStatus('not-found');
        void writeScanReject('not-found', sourceTag, { ticketIdAttempted: docId });
        return;
      }

      // Wrong-event detection — the ticket exists but belongs to another
      // event. Best-effort fetch of that event's (public) title so door
      // staff can route the holder; failures fall through to generic copy.
      if (scanTicket.eventId !== eventId) {
        let otherTitle: string | undefined;
        try {
          const otherEvent = await getPublicEvent(scanTicket.eventId);
          otherTitle = otherEvent?.title;
        } catch {
          /* draft / private event — generic copy */
        }
        setStatus('invalid-barcode');
        setInvalidReason(
          otherTitle
            ? `Wrong event — this ticket is for "${otherTitle}". Direct the holder to that event's door.`
            : 'Wrong event — this ticket belongs to a different event. Direct the holder to the correct door.',
        );
        setRecentScans((prev) =>
          [
            { id: docId.slice(0, 8), name: '—', time: new Date(), status: 'DENIED' },
            ...prev,
          ].slice(0, 5),
        );
        void writeScanReject('wrong-event', sourceTag, {
          ticketIdAttempted: docId,
          wrongEventId: scanTicket.eventId,
          wrongEventTitle: otherTitle,
        });
        return;
      }

      // Bare TYPED id entry has no signature to verify — the staff RLS read
      // is itself the gate, so we skip HMAC and process it as 'manual'. A
      // camera scan (scanning) is never bare-manual: a scanned bare UUID is a
      // forgery downgrade and must go through (and fail) the signature check.
      const isBareManualEntry =
        !scanning &&
        typeof probeValue === 'string' &&
        !probeValue.startsWith('T-') &&
        !probeValue.includes(':');
      if (isBareManualEntry) {
        await processTicket(scanTicket, 'manual');
        return;
      }

      // HMAC verification path for actual barcode payloads. Legacy 3-segment
      // shapes are REJECTED (verifyBarcode returns ok:false for them) — an
      // unsigned code is forgeable from a screenshot.
      const verify = await verifyAnyBarcode(probeValue, { secret: scanTicket.barcodeSecret || '' });
      if (!verify.ok) {
        setStatus('invalid-barcode');
        const reasonText: Record<string, string> = {
          'malformed': 'Could not read this code.',
          'bad-bucket': 'Code is malformed.',
          'bucket-expired':
            'This code expired. Ask the attendee to refresh their ticket and try again.',
          'signature-mismatch':
            "Signature doesn't match this ticket. Possible screenshot or tampered code.",
          'legacy-no-secret':
            'This is an old-format ticket. Ask the attendee to open the app and refresh their ticket, then rescan.',
        };
        setInvalidReason(reasonText[verify.reason || ''] || 'Code rejected.');
        setFoundTicket(scanTicket);
        setRecentScans((prev) =>
          [
            { id: docId.slice(0, 8), name: '—', time: new Date(), status: 'DENIED' },
            ...prev,
          ].slice(0, 5),
        );
        const auditReason: 'expired-code' | 'invalid-barcode' =
          verify.reason === 'bucket-expired' ? 'expired-code' : 'invalid-barcode';
        void writeScanReject(auditReason, sourceTag, {
          ticketIdAttempted: docId,
          reasonDetail: verify.reason || undefined,
        });
        return;
      }

      await processTicket(scanTicket, 'verified', probeValue);
    } catch (error) {
      console.error(error);
      setStatus('not-found');
    }
  };

  const processTicket = async (
    scanTicket: ScanTicket,
    verification: 'verified' | 'legacy' | 'manual',
    barcodePayload?: string,
  ) => {
    const name = scanTicket.ownerName || 'Anonymous attendee';
    setBuyerName(name);
    setFoundTicket(scanTicket);

    const src: 'camera' | 'manual' = scanning ? 'camera' : 'manual';
    const pushScan = (status: 'SUCCESS' | 'DENIED') =>
      setRecentScans((prev) =>
        [{ id: scanTicket.id.slice(0, 6), name, time: new Date(), status }, ...prev].slice(0, 5),
      );

    // The RPC does the atomic status flip (only if still 'active' — the
    // double-scan guard) AND writes the append-only check-in audit row. For a
    // signed payload it also RE-VERIFIES the HMAC server-side (D4-OPS-6), so a
    // forged/replayed code is rejected even if the client check was bypassed.
    const result = await checkInTicket(scanTicket.id, src, verification, barcodePayload, eventId);

    if (result.ok) {
      setStatus('success');
      pushScan('SUCCESS');
      setSearchId('');
      return;
    }

    // Server-side barcode rejection (forged / stale / wrong-owner code).
    if (result.reason === 'barcode-rejected' || result.reason === 'barcode-expired') {
      setStatus('invalid-barcode');
      setInvalidReason(
        result.reason === 'barcode-expired'
          ? 'This code expired. Ask the attendee to refresh their ticket and rescan.'
          : "Signature didn't match this ticket (server check). Possible screenshot or tampered code.",
      );
      pushScan('DENIED');
      void writeScanReject(
        result.reason === 'barcode-expired' ? 'expired-code' : 'invalid-barcode',
        src,
        { ticketIdAttempted: scanTicket.id, reasonDetail: result.reason },
      );
      return;
    }

    if (result.reason === 'doors-not-open') {
      setStatus('invalid-barcode');
      setInvalidReason(
        'Doors are not open yet for this event. Check-in opens at the event’s doors time.',
      );
      setDoorsBlocked(true);
      pushScan('DENIED');
      return;
    }

    if (result.reason === 'in-transfer') {
      setStatus('invalid-barcode');
      setInvalidReason(
        'This ticket is mid-transfer. Ask the holder to either cancel the transfer or have the recipient claim it before scanning.',
      );
      pushScan('DENIED');
      void writeScanReject('in-transfer', src, { ticketIdAttempted: scanTicket.id });
      return;
    }
    if (result.reason === 'voided') {
      setStatus('invalid-barcode');
      setInvalidReason(
        'This ticket was refunded. The holder should not be admitted with this ticket. Direct them to event support if there is a dispute.',
      );
      pushScan('DENIED');
      void writeScanReject('voided', src, { ticketIdAttempted: scanTicket.id });
      return;
    }
    if (result.reason === 'used') {
      setStatus('already-used');
      pushScan('DENIED');
      void writeScanReject('used', src, { ticketIdAttempted: scanTicket.id });
      return;
    }

    // not-found or any unexpected reason.
    setStatus('not-found');
    void writeScanReject('not-found', src, { ticketIdAttempted: scanTicket.id });
  };

  // Owner/manager: open a bounded test-scanning window so the doors gate is
  // lifted for early scanner testing. Auto-expires (no left-on-forever). The RPC
  // rejects non-owner/manager callers, so it's safe to offer here.
  const enableTestWindow = async () => {
    if (!eventId) return;
    setEnablingTest(true);
    try {
      await setCheckinTestWindow(eventId, 3);
      setDoorsBlocked(false);
      setStatus('idle');
      setInvalidReason('');
      toast({ kind: 'success', message: 'Test scanning enabled for 3 hours. Remember it lifts the doors gate.' });
    } catch (err) {
      console.error('enable test window failed', err);
      toast({ kind: 'error', message: 'Could not enable test scanning — owner/manager only.' });
    } finally {
      setEnablingTest(false);
    }
  };

  if (!event) return null;

  const rejectCount = recentScans.filter((s) => s.status !== 'SUCCESS').length;

  return (
    <div className="max-w-7xl mx-auto px-4 py-10">
      <style>{`
        @keyframes checkinScanline { 0% { top: 8%; } 100% { top: 92%; } }
        .checkin-scanline { animation: checkinScanline 2s ease-in-out infinite alternate; }
      `}</style>

      <button onClick={() => navigate('/dashboard')} className="flex items-center gap-2 text-slate-500 hover:text-slate-900 text-[10px] font-black uppercase tracking-widest mb-6 transition-colors">
        <ArrowLeft className="w-3.5 h-3.5" />
        Back to dashboard
      </button>

      <div className="flex flex-col md:flex-row md:items-end justify-between gap-4 mb-8">
        <div>
          <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Door Check-In</p>
          <span className="inline-flex items-baseline gap-3 flex-wrap">
            <h1 className="text-3xl md:text-4xl font-bold tracking-tight text-slate-900">{event.title}</h1>
            <span className="marker text-brand-secondary text-lg rotate-[-3deg] leading-none whitespace-nowrap">at the door ✦</span>
          </span>
        </div>
        <div className="flex flex-wrap items-center gap-2">
           <div className={`flex items-center space-x-2 px-3 py-2 rounded text-[10px] font-black uppercase tracking-widest ${isOffline ? 'bg-red-50 text-red-500 border border-red-200' : 'bg-emerald-50 text-emerald-500 border border-emerald-200'}`}>
              {isOffline ? <WifiOff className="w-3 h-3" /> : <Wifi className="w-3 h-3" />}
              <span>{isOffline ? 'Offline' : 'Online'}</span>
           </div>
           <button
             onClick={() => downloadRegistry()}
             disabled={downloading}
             className="flex items-center space-x-2 px-3 py-2 bg-slate-900 text-white rounded text-[10px] font-black uppercase tracking-widest hover:bg-slate-800 transition-all disabled:opacity-50"
           >
              <Download className={`w-3 h-3 ${downloading ? 'animate-bounce' : ''}`} aria-hidden="true" />
              <span>{downloading ? 'Syncing...' : 'Sync'}</span>
           </button>
           <button
             type="button"
             onClick={exportAttendeesCsv}
             aria-label="Export attendees as CSV"
             className="flex items-center space-x-2 px-3 py-2 bg-white text-slate-900 border border-slate-200 rounded text-[10px] font-black uppercase tracking-widest hover:bg-slate-50 transition-all shadow-sm"
           >
              <Download className="w-3 h-3" aria-hidden="true" />
              <span>Export CSV</span>
           </button>
        </div>
      </div>

      {pending.length > 0 && (
         <div className="mb-6 flex flex-wrap items-center gap-3 bg-amber-50 border border-amber-200 rounded-lg px-4 py-2.5">
           <div className="text-[11px] font-bold text-amber-700 uppercase tracking-widest">
             {pending.length} unsynced validations
           </div>
           {!isOffline && (
             <button
               onClick={syncPendingUpdates}
               disabled={syncing}
               className="flex items-center text-[10px] font-black text-slate-700 bg-white border border-slate-200 hover:bg-slate-50 px-3 py-1.5 rounded transition-all uppercase tracking-widest disabled:opacity-50"
             >
               <RefreshCw className={`w-3 h-3 mr-2 ${syncing ? 'animate-spin' : ''}`} />
               Force Sync
             </button>
           )}
         </div>
      )}

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* SCANNER STAGE */}
        <div className="lg:col-span-2 space-y-6">
      <div className="bg-white p-6 md:p-8 rounded-2xl border border-slate-200 shadow-sm overflow-hidden">
        {scanning ? (
           <div className="relative mb-2">
              <div className="relative rounded-2xl overflow-hidden bg-black border border-slate-800">
                <div id="reader" className="w-full overflow-hidden"></div>
                {/* punk reticle + scanline overlay */}
                <div className="pointer-events-none absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 w-56 h-56 max-w-[70%] max-h-[70%]">
                  <div className="absolute -top-1 -left-1 w-10 h-10 border-t-4 border-l-4 border-brand-primary"></div>
                  <div className="absolute -top-1 -right-1 w-10 h-10 border-t-4 border-r-4 border-brand-primary"></div>
                  <div className="absolute -bottom-1 -left-1 w-10 h-10 border-b-4 border-l-4 border-brand-primary"></div>
                  <div className="absolute -bottom-1 -right-1 w-10 h-10 border-b-4 border-r-4 border-brand-primary"></div>
                  <div className="checkin-scanline absolute left-2 right-2 h-0.5 bg-brand-primary shadow-[0_0_12px_#00FF00]"></div>
                </div>
                <div className="pointer-events-none absolute top-4 left-4 flex items-center gap-2 text-[10px] font-black uppercase tracking-widest text-white/80">
                  <span className="w-2 h-2 bg-brand-primary rounded-full animate-ping"></span> Scanning…
                </div>
                <div className="pointer-events-none absolute bottom-4 left-0 right-0 text-center type text-[11px] uppercase tracking-widest text-white/40">point camera at the rotating QR pass</div>
              </div>
              <button
                onClick={() => {
                  void stopScanner();
                  setScanning(false);
                }}
                aria-label="Stop the QR code scanner"
                className="mt-4 w-full py-4 text-[10px] font-bold uppercase tracking-widest text-slate-400 hover:text-slate-900 transition-colors"
              >
                Abort Scanning
              </button>
           </div>
        ) : (
          <div className="flex flex-col space-y-4 mb-2">
             <button
               onClick={startScanner}
               className="w-full bg-slate-900 hover:bg-black text-white rounded-2xl py-8 flex flex-col items-center justify-center transition-all border border-slate-800"
             >
                <ScanLine className="w-8 h-8 mb-2 text-brand-primary" />
                <span className="disp text-2xl tracking-wide">OPEN CAMERA SCANNER</span>
             </button>

             <div className="relative">
                <div className="absolute inset-0 flex items-center"><div className="w-full border-t border-slate-100"></div></div>
                <div className="relative flex justify-center text-[9px] uppercase font-bold tracking-widest text-slate-300"><span className="bg-white px-4">Manual Entry — no camera?</span></div>
             </div>

             <form onSubmit={(e) => handleCheckIn(e)} className="relative">
                <input
                  type="text"
                  placeholder="Enter pass ID or last 6 digits…"
                  className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-5 pl-14 pr-24 text-slate-900 font-mono focus:outline-none focus:border-tm-blue transition-all"
                  value={searchId}
                  onChange={(e) => setSearchId(e.target.value)}
                />
                <Search className="absolute left-6 top-1/2 -translate-y-1/2 text-slate-400 w-5 h-5" />
                <button
                  type="submit"
                  className="absolute right-4 top-1/2 -translate-y-1/2 bg-slate-900 text-white px-4 py-2 rounded-xl text-[10px] font-bold uppercase tracking-widest hover:bg-slate-800 transition-colors"
                >
                  Check
                </button>
             </form>
          </div>
        )}

        <AnimatePresence mode="wait">
          {status === 'searching' && (
            <motion.div 
              key="searching"
              initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}
              className="flex flex-col items-center justify-center py-10"
            >
              <Loader2 className="w-12 h-12 text-brand-primary animate-spin mb-4" />
              <p className="text-slate-400 font-bold uppercase tracking-widest text-xs">Verifying Ticket...</p>
            </motion.div>
          )}

          {status === 'success' && foundTicket && (
            <motion.div 
              key="success"
              initial={{ scale: 0.9, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}
              className="bg-green-50/50 p-8 rounded-[2.5rem] border border-green-100 flex flex-col items-center text-center"
            >
              <div className="w-20 h-20 bg-green-500 rounded-full flex items-center justify-center text-white mb-6 shadow-lg shadow-green-200">
                 <CheckCircle2 className="w-10 h-10" />
              </div>
              <h2 className="text-2xl font-bold text-green-900 mb-1 leading-none uppercase tracking-tight">Entry Allowed</h2>
              <p className="text-green-600 font-bold uppercase tracking-widest text-[10px] mb-6">Identity Verified</p>
              
              <div className="w-full space-y-4">
                 <div className="flex items-center justify-between p-4 bg-white rounded-2xl border border-green-50">
                    <div className="flex items-center space-x-3 text-left">
                       <User className="text-green-500 w-5 h-5" />
                       <div>
                          <p className="text-[10px] text-slate-400 font-bold uppercase tracking-widest leading-none mb-1">Attendee</p>
                          <p className="font-bold text-slate-900">{buyerName}</p>
                       </div>
                    </div>
                 </div>
                 <div className="p-4 bg-white rounded-2xl border border-green-50 text-left">
                    <p className="text-[10px] text-slate-400 font-bold uppercase tracking-widest leading-none mb-1">Ticket Type</p>
                    <p className="font-bold text-slate-900">{foundTicket.tierName || 'Standard Admission'}</p>
                 </div>
              </div>
            </motion.div>
          )}

          {status === 'already-used' && foundTicket && (
            <motion.div 
              key="already-used"
              initial={{ scale: 0.9, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}
              className="bg-orange-50/50 p-8 rounded-[2.5rem] border border-orange-100 flex flex-col items-center text-center"
            >
              <div className="w-20 h-20 bg-orange-500 rounded-full flex items-center justify-center text-white mb-6 shadow-lg shadow-orange-200">
                 <XCircle className="w-10 h-10" />
              </div>
              <h2 className="text-2xl font-bold text-orange-900 mb-1 leading-none uppercase tracking-tight">Already Used</h2>
              <p className="text-orange-600 font-bold uppercase tracking-widest text-[10px] mb-6">Ticket already checked in</p>
              
              <p className="text-slate-500 text-sm font-medium mb-4">Checked in at: <br/><strong>{foundTicket.checkInDate ? foundTicket.checkInDate.toDate().toLocaleString() : 'Recent timestamp'}</strong></p>
              
              <div className="w-full p-4 bg-white rounded-2xl border border-orange-100 text-left">
                 <p className="text-[10px] text-slate-400 font-bold uppercase tracking-widest leading-none mb-1">Attendee Name</p>
                 <p className="font-bold text-slate-900">{buyerName}</p>
              </div>
            </motion.div>
          )}

          {status === 'not-found' && (
            <motion.div
              key="not-found"
              initial={{ scale: 0.9, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}
              className="bg-red-50/50 p-8 rounded-[2.5rem] border border-red-100 flex flex-col items-center text-center relative"
            >
              <div className="w-20 h-20 bg-red-500 rounded-full flex items-center justify-center text-white mb-6 shadow-lg shadow-red-200">
                 <XCircle className="w-10 h-10" aria-hidden="true" />
              </div>
              <h2 className="text-2xl font-bold text-red-900 mb-1 leading-none uppercase tracking-tight">Invalid Ticket</h2>
              <p className="text-red-600 font-bold uppercase tracking-widest text-[10px] mb-6">Ticket not found or invalid for this event</p>

              {/*
                NOTE: A "Force Admit Pass" button used to live here. It pushed
                whatever value the operator had typed into the search box into
                pendingUpdates and then later flushed it to Firestore as
                status:'used'. With the rules tightened, that update would be
                rejected for any ticket the organizer doesn't own — but the
                button itself was a footgun for laundering tickets and a great
                way for an operator to invalidate the wrong ID by accident.
                The right answer is a verified rescan, not a manual override.
              */}
            </motion.div>
          )}

          {status === 'invalid-barcode' && (
            <motion.div
              key="invalid-barcode"
              initial={{ scale: 0.9, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}
              className="bg-amber-50/50 p-8 rounded-[2.5rem] border border-amber-200 flex flex-col items-center text-center"
            >
              <div className="w-20 h-20 bg-amber-500 rounded-full flex items-center justify-center text-white mb-6 shadow-lg shadow-amber-200">
                 <XCircle className="w-10 h-10" aria-hidden="true" />
              </div>
              <h2 className="text-2xl font-bold text-amber-900 mb-1 leading-none uppercase tracking-tight">Code Rejected</h2>
              <p className="text-amber-700 font-bold uppercase tracking-widest text-[10px] mb-4">
                {invalidReason || 'Signature did not match — possible screenshot or stale code.'}
              </p>
              {doorsBlocked ? (
                <button
                  type="button"
                  onClick={enableTestWindow}
                  disabled={enablingTest}
                  className="mt-2 px-4 py-2 bg-amber-600 hover:bg-amber-700 text-white rounded-xl text-[10px] font-black uppercase tracking-widest transition-colors disabled:opacity-50"
                >
                  {enablingTest ? 'Enabling…' : 'Enable test scanning (3h)'}
                </button>
              ) : (
                <p className="text-amber-600 text-[11px] font-medium mb-2">
                  Ask the attendee to open their ticket and rescan the live QR.
                </p>
              )}
            </motion.div>
          )}
        </AnimatePresence>
      </div>
        </div>

        {/* SIDEBAR: stats + scan log */}
        <div className="space-y-6">
          <div className="grid grid-cols-3 gap-3">
            <div className="bg-white rounded-xl border border-slate-200 shadow-sm p-4 text-center">
              <p className="disp text-3xl tracking-tight text-green-600" style={{ transform: 'skewX(-3deg)' }}>{insideVenue}</p>
              <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest mt-1">In</p>
            </div>
            <div className="bg-white rounded-xl border border-slate-200 shadow-sm p-4 text-center">
              <p className="disp text-3xl tracking-tight text-slate-900" style={{ transform: 'skewX(-3deg)' }}>{event.totalTickets}</p>
              <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest mt-1">Sold</p>
            </div>
            <div className="bg-white rounded-xl border border-slate-200 shadow-sm p-4 text-center">
              <p className="disp text-3xl tracking-tight text-rose-500" style={{ transform: 'skewX(-3deg)' }}>{rejectCount}</p>
              <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest mt-1">Rejects</p>
            </div>
          </div>

          <div className="bg-white rounded-2xl border border-slate-200 shadow-sm overflow-hidden">
            <div className="px-5 py-4 border-b border-slate-100 flex items-center justify-between">
              <h2 className="text-sm font-black text-slate-900 uppercase tracking-widest">Scan log</h2>
              <span className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">live</span>
            </div>
            {recentScans.length === 0 ? (
              <p className="px-5 py-6 text-xs text-slate-400 font-bold uppercase tracking-widest">No scans yet.</p>
            ) : (
              <ul className="divide-y divide-slate-50 max-h-[420px] overflow-y-auto">
                {recentScans.map((scan, idx) => {
                  const ok = scan.status === 'SUCCESS';
                  return (
                    <li key={idx} className="flex items-center gap-3 px-5 py-3">
                      <span className={`w-7 h-7 rounded-full flex items-center justify-center shrink-0 ${ok ? 'bg-green-50 text-green-600' : 'bg-rose-50 text-rose-500'}`}>
                        {ok ? <CheckCircle2 className="w-4 h-4" /> : <XCircle className="w-4 h-4" />}
                      </span>
                      <div className="min-w-0 flex-1">
                        <p className="text-sm font-bold text-slate-800 truncate">{ok ? scan.name : 'Rejected'}</p>
                        <p className="text-[11px] text-slate-400 truncate uppercase tracking-tighter">{scan.id}</p>
                      </div>
                      <span className="text-[10px] font-mono text-slate-300 shrink-0">{scan.time.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
