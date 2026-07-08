import { useState, useEffect, FormEvent, ChangeEvent } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { Timestamp } from '../lib/timestamp';
import { uploadEventImage } from '../lib/storage';
import {
  updateEvent,
  cancelEvent,
  notifyEventHolders,
  getEventForEdit,
  addTier as seamAddTier,
  updateTier as seamUpdateTier,
  deleteTier as seamDeleteTier,
} from '../lib/events';
import { useAuth } from '../context/AuthContext';
import { Event } from '../types';
import { ArrowLeft, Save, MapPin, Calendar as CalendarIcon, Music, Type, Image as ImageIcon, Palette, Globe, XCircle, ListOrdered, Tag, Plus, Upload, ShieldCheck, Loader2, AlertOctagon, Send } from 'lucide-react';
import { motion } from 'motion/react';
import { handleFirestoreError, OperationType } from '../lib/utils';
import { useToast } from '../context/ToastContext';
import { EVENT_CATEGORIES, genresFor } from '../lib/eventTaxonomy';
import { normalizeArtistLinks } from '../lib/artistLinks';
import ArtistLinksEditor from '../components/ArtistLinksEditor';
import AddonsEditor from '../components/AddonsEditor';
import VouchersEditor from '../components/VouchersEditor';
import TaxRulesEditor from '../components/TaxRulesEditor';
import {
  COMMON_TIMEZONES,
  utcToZonedWallClock,
  zonedWallClockToUtc,
  getBrowserTimezone,
  formatInTz,
} from '../lib/datetime';

/**
 * Helpers for shuttling between a Firestore Timestamp (or null) and the
 * `<input type="datetime-local">` string format. Used by the per-tier
 * sale-window inputs so the edit form shows the wall-clock time the
 * organizer originally entered, not the viewer-local interpretation.
 *
 * Returning '' on null/missing means the input renders empty rather
 * than "Invalid Date".
 */
function timestampToLocalInput(
  ts: Timestamp | null | undefined,
  tz: string | undefined,
): string {
  if (!ts || typeof ts.toDate !== 'function') return '';
  const date = ts.toDate();
  if (Number.isNaN(date.getTime())) return '';
  return utcToZonedWallClock(date, tz);
}
function localInputToTimestamp(
  wallClock: string,
  tz: string | undefined,
): Timestamp | null {
  if (!wallClock) return null;
  const utc = zonedWallClockToUtc(wallClock, tz || getBrowserTimezone());
  return utc ? Timestamp.fromDate(utc) : null;
}

// Limits matched against firestore.rules `isValidEvent`. Keep in sync.
const TITLE_MAX = 100;
const DESCRIPTION_MAX = 2000;
const LOCATION_MAX = 200;
const SUBGENRES_MAX_COUNT = 12;
const SUBGENRE_MAX_LEN = 40;
const SLUG_MAX = 80;

const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

export default function EditEvent() {
  const { eventId } = useParams();
  const { user, isAdmin } = useAuth();
  const navigate = useNavigate();
  const { toast } = useToast();
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [uploadingImage, setUploadingImage] = useState(false);
  const [eventData, setEventData] = useState<Partial<Event>>({});
  // Snapshot of the original tier ids so we can compute additions/removals
  // and write the matching tierSales sub-collection updates atomically.
  const [originalTierIds, setOriginalTierIds] = useState<string[]>([]);
  // Track the slug that was on disk when we loaded so we can free it (and
  // reserve the new one) atomically if the organizer renames.
  const [originalSlug, setOriginalSlug] = useState<string>('');
  // Pre-edit snapshot of fields ticket holders care about. Diffed
  // against post-save state to queue 'event-updated' emails listing
  // only the fields that changed. Re-snapshotted on success so the
  // next save's diff is against the just-committed state.
  const [originalNotifiable, setOriginalNotifiable] = useState<{
    title?: string;
    location?: string;
    dateMs?: number;
    doorsMs?: number;
    startMs?: number;
    endMs?: number;
    status?: string;
  }>({});
  // Live subscription to per-tier sold/capacity counters so we can refuse
  // edits that would orphan paid tickets (remove a sold-from tier, drop
  // capacity below sold count, drop totalTickets below ticketsSold).
  const [tierSalesState, setTierSalesState] = useState<
    Record<string, { sold: number; capacity: number }>
  >({});
  // Snapshot of tier metadata at load time so we can name a tier in the
  // error message even after the user has removed it from local state.
  const [originalTiers, setOriginalTiers] = useState<
    { id: string; name: string }[]
  >([]);
  // Snapshot of discount codes at load time so we can compute additions /
  // removals / changes for the promoUses sub-collection in handleSubmit.
  const [originalCodes, setOriginalCodes] = useState<
    NonNullable<Event['discountCodes']>
  >([]);
  // Live promoUses sub-collection. Used to refuse identity-changing edits
  // on codes that already have redemptions.
  // Cancellation flow state. Owner-initiated, narrow case (the rest
  // of the platform is all-sales-final). Refund issuance for direct-
  // channel tickets is wired to Stripe in a future sprint; for now
  // the cancellation marks the event + emails ticket holders.
  const [cancelling, setCancelling] = useState(false);
  const [showCancelModal, setShowCancelModal] = useState(false);
  const [cancelReason, setCancelReason] = useState('');
  const [notifying, setNotifying] = useState(false);
  const [promoUsesState, setPromoUsesState] = useState<
    Record<string, { usedCount: number; usageLimit: number | null; expiresAt: Timestamp | null }>
  >({});

  useEffect(() => {
    async function fetchEvent() {
      if (!eventId) return;
      // RLS gates getEventForEdit to org staff, so a returned event means the
      // viewer is authorized to edit (replaces the old organizerId/admin check).
      const data = await getEventForEdit(eventId);
      if (!data) {
        navigate('/dashboard');
        return;
      }
      setEventData(data);
      setOriginalTierIds((data.ticketTiers || []).map((t) => t.id));
      setOriginalTiers((data.ticketTiers || []).map((t) => ({ id: t.id, name: t.name })));
      setOriginalCodes(data.discountCodes || []);
      setOriginalSlug((data.branding?.customSlug || '').trim());
      setOriginalNotifiable({
        title: data.title,
        location: data.location,
        dateMs: data.date?.toMillis?.(),
        doorsMs: data.timing?.doorsOpen?.toMillis?.(),
        startMs: data.timing?.startTime?.toMillis?.(),
        endMs: data.timing?.endTime?.toMillis?.(),
        status: data.status,
      });
      setLoading(false);
    }
    fetchEvent();
  }, [eventId, navigate]);

  // Per-tier sold/capacity from the loaded event tiers (real-time counters
  // return in phase-2 with the exos_tickets fulfillment path).
  useEffect(() => {
    const next: Record<string, { sold: number; capacity: number }> = {};
    (eventData.ticketTiers || []).forEach((t) => {
      next[t.id] = { sold: t.sold ?? 0, capacity: t.capacity ?? 0 };
    });
    setTierSalesState(next);
  }, [eventData]);

  // (promoUses subscription removed — no redemptions in phase-1; discount-code
  // usage tracking returns with checkout in phase-2. promoUsesState stays {}.)

  // Categories + genre chips share a single source of truth — see lib/eventTaxonomy.ts.
  const categories = EVENT_CATEGORIES;

  const handleGenreToggle = (genre: string) => {
    const current = eventData.genres || [];
    if (current.includes(genre)) {
      setEventData({ ...eventData, genres: current.filter(g => g !== genre) });
    } else {
      setEventData({ ...eventData, genres: [...current, genre] });
    }
  };

  /**
   * Mirror of the server-side validation in firestore.rules. Surfaces
   * specific errors instead of a generic permission-denied at submit time.
   */
  const validate = (): string | null => {
    const t = (eventData.title || '').trim();
    if (!t) return 'Please enter an event title.';
    if (t.length > TITLE_MAX) return `Title must be ${TITLE_MAX} characters or fewer.`;

    if ((eventData.description || '').length > DESCRIPTION_MAX) {
      return `Description must be ${DESCRIPTION_MAX} characters or fewer.`;
    }
    if ((eventData.location || '').length > LOCATION_MAX) {
      return `Location must be ${LOCATION_MAX} characters or fewer.`;
    }
    if ((eventData.subgenres || []).length > SUBGENRES_MAX_COUNT) {
      return `Please choose at most ${SUBGENRES_MAX_COUNT} subgenres.`;
    }
    if ((eventData.performers || []).length > 10) {
      return 'Please list at most 10 performers.';
    }
    if ((eventData.performers || []).some((p) => p.length > 80)) {
      return 'Each performer name must be 80 characters or fewer.';
    }
    if ((eventData.subgenres || []).some((s) => s.length > SUBGENRE_MAX_LEN)) {
      return `Each subgenre must be ${SUBGENRE_MAX_LEN} characters or fewer.`;
    }

    const price = Number(eventData.price);
    if (!Number.isFinite(price) || price < 0) {
      return 'Please enter a valid admission price.';
    }
    const total = Number(eventData.totalTickets);
    if (!Number.isInteger(total) || total < 1) {
      return 'Total tickets must be 1 or more.';
    }

    // The event update rule requires `ticketsSold <= totalTickets`. If the
    // organizer tries to lower totalTickets below what's already sold, we
    // catch it here with a helpful message.
    const sold = Number(eventData.ticketsSold || 0);
    if (Number.isInteger(sold) && sold > total) {
      return `${sold} tickets are already sold — total cannot drop below that.`;
    }

    const tiers = eventData.ticketTiers || [];
    if (tiers.length === 0) return 'Keep at least one tier defined.';
    let capacitySum = 0;
    for (const tier of tiers) {
      if (!tier.name?.trim()) return 'Every tier needs a name.';
      const tp = Number(tier.price);
      const tc = Number(tier.capacity);
      if (!Number.isFinite(tp) || tp < 0) {
        return `Tier "${tier.name}" has an invalid price.`;
      }
      if (!Number.isInteger(tc) || tc < 1) {
        return `Tier "${tier.name}" has an invalid capacity.`;
      }

      // Refuse a capacity drop that would make the new cap smaller than
      // the number of tickets already sold from that tier. The Firestore
      // rule on tierSales/{tierId} also enforces this, but surfacing it
      // here means the organizer gets a real explanation instead of
      // permission-denied.
      const liveSold = tierSalesState[tier.id]?.sold ?? 0;
      if (liveSold > tc) {
        return `Can't reduce "${tier.name}" capacity to ${tc} — ${liveSold} ticket(s) already sold.`;
      }

      capacitySum += tc;
    }
    if (capacitySum > total) {
      return `Tier capacities sum to ${capacitySum}, but the event total is ${total}.`;
    }

    // Tier removals: refuse any tier whose live sold count is non-zero.
    // Without this check, deleting a tier silently orphans the tickets
    // minted from it (their tierName resolves to nothing), and the
    // tierSales counter is dropped — aggregate analytics drift forever.
    const currentTierIds = tiers.map((t) => t.id);
    for (const original of originalTiers) {
      if (currentTierIds.includes(original.id)) continue;
      const sold = tierSalesState[original.id]?.sold ?? 0;
      if (sold > 0) {
        return `Can't remove "${original.name}" — ${sold} ticket(s) have already been sold from this tier. Cancel the event or refund those buyers first.`;
      }
    }

    if ((eventData.branding?.customSlug || '').length > SLUG_MAX) {
      return `Custom URL must be ${SLUG_MAX} characters or fewer.`;
    }

    // ---- Promo code validation ----------------------------------------
    // Mirrors CreateEvent.validate() so an organizer doesn't have to learn
    // two different sets of rules for the same data.
    type CodeEntryV = NonNullable<Event['discountCodes']>[number];
    const codes: CodeEntryV[] = eventData.discountCodes || [];
    const seen = new Set<string>();
    const originalByCode = new Map<string, CodeEntryV>(
      originalCodes.map((c) => [c.code, c] as const),
    );
    for (const c of codes) {
      const codeStr = (c.code || '').trim().toUpperCase();
      if (!codeStr) return 'Every promo code needs a value (e.g. EARLY30).';
      if (!/^[A-Z0-9_-]+$/.test(codeStr)) {
        return `Promo code "${codeStr}" can only contain A-Z, 0-9, underscore and hyphen.`;
      }
      if (seen.has(codeStr)) {
        return `Promo code "${codeStr}" is repeated. Use distinct codes.`;
      }
      seen.add(codeStr);
      const v = Number(c.value);
      if (!Number.isFinite(v) || v < 0) {
        return `Promo code "${codeStr}" needs a non-negative discount value.`;
      }
      if (c.type === 'percentage' && v > 100) {
        return `Promo code "${codeStr}" can't be more than 100%.`;
      }
      if (c.usageLimit != null) {
        const lim = Number(c.usageLimit);
        if (!Number.isInteger(lim) || lim < 1) {
          return `Promo code "${codeStr}" usage limit must be a positive integer.`;
        }
      }
      if (c.expiresAt) {
        const ms = (c.expiresAt as Timestamp).toMillis?.() ?? NaN;
        if (Number.isFinite(ms) && ms < Date.now()) {
          // We accept expiry in the past at the metadata level — it just
          // means the code is dead — but warn the organizer in case it
          // was unintentional.
          return `Promo code "${codeStr}" expires in the past. Pick a future date or remove it.`;
        }
      }

      // Bait-and-switch guard: if this code already has redemptions, the
      // organizer can adjust limits/expiry but can NOT change the code's
      // identity (the literal code, type, or value). Otherwise existing
      // buyers' receipts would diverge from current pricing.
      const used = promoUsesState[codeStr]?.usedCount ?? 0;
      const orig = originalByCode.get(codeStr);
      if (used > 0 && orig) {
        if (orig.type !== c.type || Number(orig.value) !== Number(c.value)) {
          return `Promo code "${codeStr}" already has ${used} redemption(s). You can adjust its usage limit or expiry, but not its discount type or value.`;
        }
        // Also lock unlocksTierIds — changing which tiers a redeemed
        // code unlocks would retroactively expose tier access (or
        // revoke it) for buyers who already used the code without
        // their knowledge. They got the tier; they keep the tier.
        const origUnlocks = (orig.unlocksTierIds || []).slice().sort();
        const curUnlocks = (c.unlocksTierIds || []).slice().sort();
        const sameLength = origUnlocks.length === curUnlocks.length;
        const sameOrder = sameLength &&
          origUnlocks.every((id, i) => id === curUnlocks[i]);
        if (!sameOrder) {
          return `Promo code "${codeStr}" already has ${used} redemption(s). You can't change which tiers it unlocks after redemptions have happened.`;
        }
      }
    }
    // Removed codes that already have redemptions: refuse, otherwise we'd
    // delete the promoUses counter and lose the audit trail.
    const codesByCode = new Map<string, CodeEntryV>(
      codes.map((c) => [c.code, c] as const),
    );
    for (const orig of originalCodes) {
      if (codesByCode.has(orig.code)) continue;
      const used = promoUsesState[orig.code]?.usedCount ?? 0;
      if (used > 0) {
        return `Can't remove "${orig.code}" — ${used} buyer(s) have already redeemed it.`;
      }
    }

    return null;
  };

  /**
   * Cancel the event. Marks status=cancelled, stamps cancelledAt and
   * cancelReason, and queues a notification email to every ticket
   * holder. Per the platform's all-sales-final policy, refunds only
   * happen on cancellation — and only for tickets where
   * channelSource is 'vibepass' (direct sales). Secondary-channel
   * tickets (Lysted / StubHub / Vivid / etc) get an email pointing
   * the buyer back to the channel they bought from, since refund
   * processing on those marketplaces is the channel's operations.
   *
   * Stripe refund issuance for direct tickets is wired in a future
   * sprint. For now this function records the intent (status flip +
   * email blast) and the actual money-movement step is documented
   * as deferred. The buyer's experience is correct from email +
   * banner perspective; the refund itself is still a manual op
   * until Stripe Connect lands.
   */
  const handleCancelEvent = async () => {
    if (!eventId || !eventData) return;
    if (cancelling) return;
    if (cancelReason.trim().length < 3) {
      toast({ kind: 'error', message: 'Provide a cancellation reason (min 3 chars).' });
      return;
    }
    if (cancelReason.length > 500) {
      toast({ kind: 'error', message: 'Reason too long (max 500 chars).' });
      return;
    }
    setCancelling(true);
    try {
      await cancelEvent(eventId, cancelReason.trim());
      // cancelEvent queues an 'event-cancelled' email to every holder
      // (exos_notify_event_holders, server-derived recipients).
      toast({
        kind: 'success',
        title: 'Event cancelled',
        message: 'Sales stopped and ticket holders have been emailed.',
      });
      setShowCancelModal(false);
      navigate('/dashboard');
    } catch (err) {
      toast({ kind: 'error', message: err instanceof Error ? err.message : 'Cancel failed' });
    } finally {
      setCancelling(false);
    }
  };

  /**
   * Email every current (non-voided) ticket holder that this event's details
   * changed (exos_notify_event_holders, 'event-updated' template — recipients
   * server-derived). Explicit action so a typo-fix save doesn't blast holders.
   */
  const handleNotifyUpdate = async () => {
    if (!eventId || notifying) return;
    setNotifying(true);
    try {
      const n = await notifyEventHolders(eventId, 'event-updated');
      if (n === null) {
        toast({ kind: 'error', message: 'Could not queue update emails — try again.' });
      } else if (n === 0) {
        toast({ kind: 'info', message: 'No ticket holders to notify yet.' });
      } else {
        toast({
          kind: 'success',
          title: 'Attendees notified',
          message: `Queued an update email to ${n} ticket holder${n === 1 ? '' : 's'}.`,
        });
      }
    } finally {
      setNotifying(false);
    }
  };

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (!eventId) return;
    if (uploadingImage) {
      toast({ kind: 'warn', message: 'Wait for the image upload to finish.' });
      return;
    }

    const err = validate();
    if (err) {
      toast({ kind: 'error', title: 'Check your details', message: err });
      return;
    }

    setSaving(true);
    try {
      const currentTierIds = (eventData.ticketTiers || []).map((t) => t.id);
      const added = currentTierIds.filter((id) => !originalTierIds.includes(id));
      const removed = originalTierIds.filter((id) => !currentTierIds.includes(id));

      const ed = eventData as Event;
      const tz = ed.timezone || getBrowserTimezone();
      const tsToIso = (ts: any): string | null =>
        ts && typeof ts.toDate === 'function' ? ts.toDate().toISOString() : null;
      const startTs = ed.timing?.startTime ?? ed.date;

      // 1. Update the event fields via the seam.
      await updateEvent(eventId, {
        name: ed.title,
        description: ed.description,
        status: ed.status,
        slug: (ed.branding?.customSlug || '').trim() || null,
        startsAt: tsToIso(startTs),
        doorsAt: tsToIso(ed.timing?.doorsOpen),
        endsAt: tsToIso(ed.timing?.endTime),
        timezone: tz,
        currency: (ed.currency || 'USD').toUpperCase(),
        venueName: ed.location,
        venueLocation: ed.location,
        venueAddress: ed.address as any,
        primaryPerformerName: ed.performers?.[0],
        performerNames: ed.performers,
        // Always send the array (never undefined) so clearing every link
        // persists as `[]` — updateEvent skips undefined fields, which would
        // otherwise leave stale links in place on removal.
        artistLinks: normalizeArtistLinks(ed.artistLinks || []) ?? [],
        category: ed.category,
        genres: ed.genres,
        subgenres: ed.subgenres,
        imageUrl: ed.image,
        totalTickets: ed.totalTickets,
        branding: ed.branding as any,
        exclusivity: ed.exclusivity as any,
        purchaseLimits: ed.purchaseLimits as any,
        distributionNetworks: ed.distributionNetworks,
      });

      // 2. Tier diff: update existing, add new, delete removed. (Seam tier CRUD
      //    is aliased to avoid the local addTier/removeTier form helpers.)
      for (const tier of ed.ticketTiers || []) {
        const tt = tier as any;
        const tin = {
          name: tier.name,
          description: tier.description,
          price: tier.price,
          capacity: tier.capacity,
          ticketType: tt.ticketType,
          visibility: tt.visibility,
          salesStart: tsToIso(tt.salesStart),
          salesEnd: tsToIso(tt.salesEnd),
        };
        if (added.includes(tier.id)) {
          await seamAddTier(eventId, tin);
        } else {
          await seamUpdateTier(tier.id, tin);
        }
      }
      for (const removedId of removed) {
        await seamDeleteTier(removedId);
      }

      // Discount-code editing + ticket-holder change-notification emails land
      // in phase-2 (codes are checkout-gated; notifications read the tickets
      // table). Slug uniqueness is enforced by updateEvent + the UNIQUE index.
      setOriginalSlug((ed.branding?.customSlug || '').trim());
      setOriginalCodes(ed.discountCodes || []);
      setOriginalTiers((ed.ticketTiers || []).map((t) => ({ id: t.id, name: t.name })));
      setOriginalTierIds((ed.ticketTiers || []).map((t) => t.id));
      toast({ kind: 'success', message: 'Changes saved.' });
      navigate('/dashboard');
    } catch (error) {
      handleFirestoreError(error, OperationType.WRITE, 'events', toast);
    } finally {
      setSaving(false);
    }
  };

  const addTier = () => {
    const tiers = [...(eventData.ticketTiers || [])];
    tiers.push({
      id: crypto.randomUUID(),
      name: '',
      price: 0,
      capacity: 0,
      sold: 0,
      description: '',
    });
    setEventData({ ...eventData, ticketTiers: tiers });
  };

  const removeTier = (id: string) => {
    setEventData({
      ...eventData,
      ticketTiers: (eventData.ticketTiers || []).filter((t) => t.id !== id),
    });
  };

  const updateTier = (id: string, field: string, value: any) => {
    const tiers = (eventData.ticketTiers || []).map((t) => {
      if (t.id === id) {
        return { ...t, [field]: field === 'price' || field === 'capacity' ? parseFloat(value) : value };
      }
      return t;
    });
    setEventData({ ...eventData, ticketTiers: tiers });
  };

  const handleImageUpload = async (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file || !user) return;
    if (!file.type.startsWith('image/')) {
      toast({ kind: 'error', message: 'Please choose an image file.' });
      e.target.value = '';
      return;
    }
    if (file.size > MAX_IMAGE_BYTES) {
      toast({
        kind: 'error',
        title: 'Image too large',
        message: `Please choose an image under ${Math.round(MAX_IMAGE_BYTES / 1024 / 1024)} MB.`,
      });
      e.target.value = '';
      return;
    }

    setUploadingImage(true);
    try {
      const { url } = await uploadEventImage(user.uid, file);
      setEventData({ ...eventData, image: url });
      toast({ kind: 'success', message: 'Image uploaded.' });
    } catch (err) {
      console.error('Image upload failed', err);
      toast({ kind: 'error', message: 'Could not upload the image.' });
      e.target.value = '';
    } finally {
      setUploadingImage(false);
    }
  };

  if (loading) return <div className="max-w-4xl mx-auto p-20 text-center type text-white/40 uppercase tracking-[0.3em]">Opening production manifest...</div>;

  return (
    <div className="max-w-4xl mx-auto px-4 py-12 text-left">
      <button onClick={() => navigate('/dashboard')} className="type flex items-center text-white/40 hover:text-brand-primary mb-10 transition-colors uppercase tracking-widest text-[10px]">
        <ArrowLeft className="w-4 h-4 mr-2" />
        Back to control center
      </button>

      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 mb-10">
        <div>
          <p className="type text-[10px] text-white/40 uppercase tracking-widest mb-2">Edit Event</p>
          <span className="inline-flex items-baseline gap-3 flex-wrap">
            <h1 className="disp text-4xl md:text-5xl uppercase tracking-wide text-white">Re-engineer Production</h1>
            <span className="marker text-brand-secondary text-lg -rotate-3 leading-none whitespace-nowrap">editing live ✦</span>
          </span>
          <p className="type text-white/50 uppercase tracking-widest text-xs mt-2">Update event logistics and branding logic.</p>
        </div>
        <div className="w-12 h-12 bg-brand-primary flex items-center justify-center">
           <Save className="text-black w-5 h-5" />
        </div>
      </div>

      {/* Admin override banner: if the current user isn't the event's
          organizer but is editing it via the admin role, make that loud
          so they don't accidentally make changes thinking it's their own
          event. The banner uses an indigo tone distinct from the
          draft/published lifecycle colours below. */}
      {isAdmin && eventData.organizerId && eventData.organizerId !== user?.uid && (
        <div className="flex items-center justify-between p-4 border border-indigo-500/40 bg-indigo-500/10 text-indigo-300 mb-4">
          <p className="text-[10px] font-black uppercase tracking-widest">
            Editing as ADMIN — owned by {eventData.organizerId}
          </p>
          <p className="text-[10px] font-medium uppercase tracking-widest opacity-70">
            Changes save under your admin role.
          </p>
        </div>
      )}

      {/* Lifecycle banner — quick visibility into draft vs published state. */}
      {(() => {
        const status = (eventData.status as Event['status']) ?? 'published';
        const tone =
          status === 'draft'
            ? 'bg-amber-500/10 border-amber-500/30 text-amber-300'
            : status === 'cancelled'
              ? 'bg-red-500/10 border-red-500/30 text-red-300'
              : 'bg-emerald-500/10 border-emerald-500/30 text-emerald-300';
        const label =
          status === 'draft'
            ? 'DRAFT — only visible to you until you publish.'
            : status === 'cancelled'
              ? 'CANCELLED'
              : 'PUBLISHED — listed publicly.';
        const next = status === 'published' ? 'draft' : 'published';
        return (
          <div
            className={`flex items-center justify-between p-4 border mb-8 ${tone}`}
          >
            <p className="text-[10px] font-black uppercase tracking-widest">{label}</p>
            <button
              type="button"
              onClick={() =>
                setEventData({ ...eventData, status: next as Event['status'] })
              }
              className="text-[10px] font-black uppercase tracking-widest underline-offset-2 hover:underline"
            >
              {status === 'published' ? 'Move to draft' : 'Mark as published'}
            </button>
          </div>
        );
      })()}

      <form onSubmit={handleSubmit} className="space-y-12">
        {/* Core Identity */}
        <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-8">
           <div className="flex items-center space-x-3 mb-2">
              <Type className="text-brand-primary w-5 h-5" />
              <h2 className="disp text-lg uppercase tracking-wide text-white leading-none">Core Identity</h2>
           </div>
           
           <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
              <div className="space-y-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Event Title</label>
                <input 
                  required
                  className="w-full bg-black border border-white/20 py-4 px-6 font-bold text-white focus:outline-none focus:border-brand-primary transition-colors"
                  value={eventData.title}
                  onChange={(e) => setEventData({ ...eventData, title: e.target.value })}
                />
              </div>
              <div className="space-y-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Category</label>
                <select 
                  className="w-full bg-black border border-white/20 py-4 px-6 font-bold text-white focus:outline-none focus:border-brand-primary transition-colors appearance-none"
                  value={eventData.category}
                  onChange={(e) => setEventData({ ...eventData, category: e.target.value })}
                >
                  {categories.map(c => <option key={c} value={c}>{c}</option>)}
                </select>
              </div>
           </div>

           <div className="grid grid-cols-1 md:grid-cols-2 gap-8 mt-8">
              <div className="space-y-4 col-span-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Genres for {eventData.category}</label>
                <div className="flex flex-wrap gap-2">
                  {genresFor(eventData.category || 'Music').map(genre => (
                    <button
                      key={genre}
                      type="button"
                      onClick={() => handleGenreToggle(genre)}
                      className={`px-4 py-2 rounded-xl text-[10px] font-black uppercase tracking-widest transition-all border ${
                        (eventData.genres || []).includes(genre)
                          ? 'bg-brand-primary text-black border-black'
                          : 'bg-white/5 text-white/40 border-white/10 hover:border-white/30'
                      }`}
                    >
                      {genre}
                    </button>
                  ))}
                </div>
              </div>

              <div className="space-y-2 col-span-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Custom Subgenres</label>
                <input
                  type="text"
                  placeholder="e.g. Ambient, Techno, Deep House (Comma separated)"
                  className="w-full bg-black border border-white/20 py-4 px-6 text-white font-bold focus:outline-none focus:border-brand-primary transition-colors"
                  value={(eventData.subgenres || []).join(', ')}
                  onChange={(e) => {
                    const val = e.target.value.split(',').map(s => s.trim()).filter(Boolean);
                    setEventData({ ...eventData, subgenres: val });
                  }}
                />
              </div>

              {/* Performers — comma-separated free-text. Surfaced
                  on the public event page above genres, in transfer
                  + reminder emails. Max 10 entries × 80 chars each;
                  validated client-side and by the firestore rule's
                  list-size cap on isValidEvent. */}
              <div className="space-y-2 col-span-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Performers</label>
                <input
                  type="text"
                  placeholder="e.g. Skrillex, Boys Noize, Boombox Cartel (max 10, comma-separated)"
                  className="w-full bg-black border border-white/20 py-4 px-6 text-white font-bold focus:outline-none focus:border-brand-primary transition-colors"
                  value={(eventData.performers || []).join(', ')}
                  onChange={(e) => {
                    const val = e.target.value
                      .split(',')
                      .map((s) => s.trim().slice(0, 80))
                      .filter(Boolean)
                      .slice(0, 10);
                    setEventData({ ...eventData, performers: val });
                  }}
                />
                <p className="type text-[9px] text-white/30 uppercase tracking-widest leading-relaxed ml-1">
                  Order matters — first name is treated as the headliner in emails and the event page.
                </p>
              </div>

              {/* Artist links — optional Spotify / Apple Music / Bandsintown /
                  social destinations per performer, rendered next to each
                  artist on the public event page. */}
              <div className="space-y-2 col-span-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Artist links (optional)</label>
                <ArtistLinksEditor
                  performers={eventData.performers || []}
                  value={eventData.artistLinks || []}
                  onChange={(artistLinks) => setEventData({ ...eventData, artistLinks })}
                />
              </div>
           </div>

           <div className="space-y-2">
              <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Narrative Description</label>
              <textarea 
                rows={4}
                className="w-full bg-black border border-white/20 py-4 px-6 font-medium text-white focus:outline-none focus:border-brand-primary transition-colors"
                value={eventData.description}
                onChange={(e) => setEventData({ ...eventData, description: e.target.value })}
              />
           </div>
        </section>

        {/* Seating and Logistics Section */}
        <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-8">
           <div className="flex items-center space-x-3 mb-2">
              <MapPin className="text-brand-primary w-5 h-5" />
              <h2 className="disp text-lg uppercase tracking-wide text-white leading-none">Logistics & Seating Manifest</h2>
           </div>

           {/* Timing controls — Date / Doors / Show Start / Show End.
               Matches CreateEvent's set so an organizer who needs to
               correct a date typo or push back doors after a soundcheck
               delay doesn't have to delete + recreate the event.
               showPicker on click forces the native calendar+time popover
               (some browsers only pop it from the icon edge, which our
               overlay icon hides). All four inputs are interpreted in
               eventData.timezone — changing the zone here doesn't
               re-interpret the times entered above; it changes how
               they're displayed downstream. Show Start mirrors
               event.date for backwards-compat with renders that still
               read the top-level field. */}
           <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
              <div className="space-y-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Event Date</label>
                <div className="relative">
                  <CalendarIcon className="absolute left-6 top-1/2 -translate-y-1/2 text-white/30 w-4 h-4 pointer-events-none" aria-hidden="true" />
                  <input
                    type="datetime-local"
                    className="w-full bg-black border border-white/20 py-4 pl-14 pr-6 text-white font-bold focus:outline-none focus:border-brand-primary transition-colors cursor-pointer"
                    value={timestampToLocalInput(eventData.date as Timestamp | undefined, eventData.timezone)}
                    onClick={(e) => {
                      const el = e.currentTarget as HTMLInputElement;
                      if (typeof el.showPicker === 'function') {
                        try { el.showPicker(); } catch { /* user-gesture errors are non-fatal */ }
                      }
                    }}
                    onChange={(e) => {
                      const ts = localInputToTimestamp(e.target.value, eventData.timezone);
                      if (ts) setEventData({ ...eventData, date: ts });
                    }}
                  />
                </div>
              </div>
              <div className="space-y-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Doors Open</label>
                <div className="relative">
                  <CalendarIcon className="absolute left-6 top-1/2 -translate-y-1/2 text-white/30 w-4 h-4 pointer-events-none" aria-hidden="true" />
                  <input
                    type="datetime-local"
                    className="w-full bg-black border border-white/20 py-4 pl-14 pr-6 text-white font-bold focus:outline-none focus:border-brand-primary transition-colors cursor-pointer"
                    value={timestampToLocalInput(eventData.timing?.doorsOpen, eventData.timezone)}
                    onClick={(e) => {
                      const el = e.currentTarget as HTMLInputElement;
                      if (typeof el.showPicker === 'function') {
                        try { el.showPicker(); } catch { /* */ }
                      }
                    }}
                    onChange={(e) => {
                      const ts = localInputToTimestamp(e.target.value, eventData.timezone);
                      setEventData({
                        ...eventData,
                        timing: {
                          ...(eventData.timing || { startTime: eventData.date as Timestamp }),
                          doorsOpen: ts ?? undefined,
                        },
                      });
                    }}
                  />
                </div>
              </div>
              <div className="space-y-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Show Start</label>
                <div className="relative">
                  <CalendarIcon className="absolute left-6 top-1/2 -translate-y-1/2 text-white/30 w-4 h-4 pointer-events-none" aria-hidden="true" />
                  <input
                    type="datetime-local"
                    className="w-full bg-black border border-white/20 py-4 pl-14 pr-6 text-white font-bold focus:outline-none focus:border-brand-primary transition-colors cursor-pointer"
                    value={timestampToLocalInput(eventData.timing?.startTime, eventData.timezone)}
                    onClick={(e) => {
                      const el = e.currentTarget as HTMLInputElement;
                      if (typeof el.showPicker === 'function') {
                        try { el.showPicker(); } catch { /* */ }
                      }
                    }}
                    onChange={(e) => {
                      const ts = localInputToTimestamp(e.target.value, eventData.timezone);
                      setEventData({
                        ...eventData,
                        date: ts ?? eventData.date,
                        timing: {
                          ...(eventData.timing || {}),
                          startTime: (ts ?? eventData.timing?.startTime) as Timestamp,
                        },
                      });
                    }}
                  />
                </div>
              </div>
              <div className="space-y-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Show End</label>
                <div className="relative">
                  <CalendarIcon className="absolute left-6 top-1/2 -translate-y-1/2 text-white/30 w-4 h-4 pointer-events-none" aria-hidden="true" />
                  <input
                    type="datetime-local"
                    className="w-full bg-black border border-white/20 py-4 pl-14 pr-6 text-white font-bold focus:outline-none focus:border-brand-primary transition-colors cursor-pointer"
                    value={timestampToLocalInput(eventData.timing?.endTime, eventData.timezone)}
                    onClick={(e) => {
                      const el = e.currentTarget as HTMLInputElement;
                      if (typeof el.showPicker === 'function') {
                        try { el.showPicker(); } catch { /* */ }
                      }
                    }}
                    onChange={(e) => {
                      const ts = localInputToTimestamp(e.target.value, eventData.timezone);
                      setEventData({
                        ...eventData,
                        timing: {
                          ...(eventData.timing || { startTime: eventData.date as Timestamp }),
                          endTime: ts ?? undefined,
                        },
                      });
                    }}
                  />
                </div>
              </div>
           </div>

           <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
              <div className="space-y-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Venue Destination</label>
                <input
                  className="w-full bg-black border border-white/20 py-4 px-6 font-bold text-white focus:outline-none focus:border-brand-primary transition-colors"
                  value={eventData.location || ''}
                  onChange={(e) => setEventData({ ...eventData, location: e.target.value })}
                />
                <details className="mt-2" open={!!eventData.address}>
                  <summary className="type text-[9px] text-white/40 uppercase tracking-widest cursor-pointer hover:text-white">
                    Address details
                  </summary>
                  <div className="grid grid-cols-1 md:grid-cols-6 gap-3 mt-3">
                    {(['street', 'city', 'region', 'postal', 'country'] as const).map((key) => (
                      <input
                        key={key}
                        type="text"
                        placeholder={key.charAt(0).toUpperCase() + key.slice(1)}
                        aria-label={key}
                        maxLength={key === 'postal' ? 20 : key === 'street' || key === 'country' ? 120 : 80}
                        className={`bg-black border border-white/20 py-3 px-4 text-white text-sm font-medium focus:outline-none focus:border-brand-primary ${
                          key === 'street' || key === 'country' ? 'md:col-span-6' :
                          key === 'city' ? 'md:col-span-3' :
                          key === 'region' ? 'md:col-span-2' : 'md:col-span-1'
                        }`}
                        value={(eventData.address as any)?.[key] || ''}
                        onChange={(e) =>
                          setEventData({
                            ...eventData,
                            address: {
                              ...(eventData.address || {}),
                              [key]: e.target.value,
                            } as Event['address'],
                          })
                        }
                      />
                    ))}
                  </div>
                </details>
              </div>
              <div className="space-y-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Total Venue Capacity</label>
                <input
                  type="number"
                  className="w-full bg-black border border-white/20 py-4 px-6 font-bold text-white focus:outline-none focus:border-brand-primary transition-colors"
                  value={eventData.totalTickets}
                  onChange={(e) => setEventData({ ...eventData, totalTickets: parseInt(e.target.value) })}
                />
              </div>

              {/* Per-event currency picker. Mirrors CreateEvent —
                  ISO 4217 three-letter codes, defaults to USD when
                  absent. The Stripe session reads this via the
                  request body; see server.ts. */}
              <div className="space-y-2">
                <label htmlFor="edit-event-currency" className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Currency</label>
                <select
                  id="edit-event-currency"
                  className="w-full bg-black border border-white/20 py-4 px-6 font-bold text-white focus:outline-none focus:border-brand-primary transition-colors appearance-none"
                  value={eventData.currency || 'USD'}
                  onChange={(e) => setEventData({ ...eventData, currency: e.target.value })}
                >
                  {(['USD', 'EUR', 'GBP', 'CAD', 'AUD', 'JPY', 'MXN', 'BRL'] as const).map((c) => (
                    <option key={c} value={c}>{c}</option>
                  ))}
                  {!['USD', 'EUR', 'GBP', 'CAD', 'AUD', 'JPY', 'MXN', 'BRL'].includes(
                    (eventData.currency || 'USD').toUpperCase(),
                  ) && (
                    <option value={(eventData.currency || 'USD').toUpperCase()}>
                      {(eventData.currency || 'USD').toUpperCase()}
                    </option>
                  )}
                </select>
              </div>

              {/* Per-event timezone picker. Required for the
                  buyer-side time renders to be honest across regions. */}
              <div className="space-y-2">
                <label htmlFor="edit-event-timezone" className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Timezone</label>
                <select
                  id="edit-event-timezone"
                  className="w-full bg-black border border-white/20 py-4 px-6 font-bold text-white focus:outline-none focus:border-brand-primary transition-colors appearance-none"
                  value={eventData.timezone || getBrowserTimezone()}
                  onChange={(e) => setEventData({ ...eventData, timezone: e.target.value })}
                >
                  {COMMON_TIMEZONES.some((t) => t.value === (eventData.timezone || getBrowserTimezone())) ? null : (
                    <option value={eventData.timezone}>{eventData.timezone}</option>
                  )}
                  {COMMON_TIMEZONES.map((tz) => (
                    <option key={tz.value} value={tz.value}>{tz.label}</option>
                  ))}
                </select>
              </div>
           </div>

           <div className="space-y-2">
              <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Seating Structure</label>
              <textarea 
                placeholder="Section A: Row 1-10 (VIP), Section B: Row 1-20 (GA)..."
                className="w-full bg-black border border-white/20 py-4 px-6 font-medium text-white focus:outline-none focus:border-brand-primary transition-colors"
                value={eventData.seatingManifest || ''}
                onChange={(e) => setEventData({ ...eventData, seatingManifest: e.target.value })}
              />
           </div>
        </section>

        {/* Purchase Controls Section */}
        <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-8">
           <div className="flex items-center space-x-3 mb-2">
              <ShieldCheck className="text-brand-primary w-5 h-5" />
              <h2 className="disp text-lg uppercase tracking-wide text-white leading-none">Purchase Controls</h2>
           </div>

           <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
              <div className="space-y-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Max per transaction</label>
                <input 
                  type="number"
                  className="w-full bg-black border border-white/20 py-4 px-6 font-bold text-white focus:outline-none focus:border-brand-primary transition-colors"
                  value={eventData.purchaseLimits?.maxPerOrder || 8}
                  onChange={(e) => setEventData({ 
                    ...eventData, 
                    purchaseLimits: { ...(eventData.purchaseLimits || { maxPerOrder: 8, maxPerAccount: 8 }), maxPerOrder: parseInt(e.target.value) } 
                  })}
                />
              </div>
              <div className="space-y-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Max per user account</label>
                <input 
                  type="number"
                  className="w-full bg-black border border-white/20 py-4 px-6 font-bold text-white focus:outline-none focus:border-brand-primary transition-colors"
                  value={eventData.purchaseLimits?.maxPerAccount || 8}
                  onChange={(e) => setEventData({ 
                    ...eventData, 
                    purchaseLimits: { ...(eventData.purchaseLimits || { maxPerOrder: 8, maxPerAccount: 8 }), maxPerAccount: parseInt(e.target.value) } 
                  })}
                />
              </div>
           </div>
        </section>

        {/* Inventory Tiers Section */}
        <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-8">
           <div className="flex items-center justify-between mb-2">
              <div className="flex items-center space-x-3">
                 <ListOrdered className="text-brand-primary w-5 h-5" />
                 <h2 className="disp text-lg uppercase tracking-wide text-white leading-none">Inventory Configuration</h2>
              </div>
              <button 
                type="button" 
                onClick={addTier}
                className="flex items-center space-x-2 text-[10px] font-bold text-brand-primary uppercase tracking-widest hover:opacity-80 transition-opacity"
              >
                <Plus className="w-3.5 h-3.5" />
                <span>Add Tier</span>
              </button>
           </div>
           
           <div className="space-y-6">
              {(eventData.ticketTiers || []).map((tier, index) => (
                <div key={tier.id} className="p-8 bg-black/40 border border-white/10 relative group/tier">
                   <button 
                     type="button"
                     onClick={() => removeTier(tier.id)}
                     className="absolute top-6 right-6 text-white/30 hover:text-brand-accent transition-colors"
                   >
                     <XCircle className="w-5 h-5" />
                   </button>
                   
                   <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
                      <div className="space-y-2 col-span-2">
                         <label className="type text-[9px] text-white/40 uppercase tracking-widest ml-1">Tier Designation (e.g. Platinum, VIP, Parking)</label>
                         <input 
                           required 
                           type="text"
                           placeholder="Enter tier name..."
                           className="w-full bg-black border border-white/20 py-4 px-6 text-white font-bold focus:outline-none focus:border-brand-primary transition-colors"
                           value={tier.name}
                           onChange={(e) => updateTier(tier.id, 'name', e.target.value)}
                         />
                      </div>
                      <div className="space-y-2">
                         <label className="type text-[9px] text-white/40 uppercase tracking-widest ml-1">Price (USD)</label>
                         <input 
                           required 
                           type="number"
                           min="0"
                           step="0.01"
                           className="w-full bg-black border border-white/20 py-4 px-6 text-white font-bold focus:outline-none focus:border-brand-primary transition-colors"
                           value={tier.price}
                           onChange={(e) => updateTier(tier.id, 'price', e.target.value)}
                         />
                      </div>
                      <div className="space-y-2">
                         <label className="type text-[9px] text-white/40 uppercase tracking-widest ml-1">Inventory Allocation</label>
                         <input 
                           required 
                           type="number"
                           min="1"
                           className="w-full bg-black border border-white/20 py-4 px-6 text-white font-bold focus:outline-none focus:border-brand-primary transition-colors"
                           value={tier.capacity}
                           onChange={(e) => updateTier(tier.id, 'capacity', e.target.value)}
                         />
                      </div>
                      <div className="space-y-2 col-span-2">
                         <label className="type text-[9px] text-white/40 uppercase tracking-widest ml-1">Tier Benefits & Access Rights</label>
                         <textarea
                           required
                           placeholder="Describe the exclusivity of this tier..."
                           className="w-full bg-black border border-white/20 py-4 px-6 text-white font-medium focus:outline-none focus:border-brand-primary transition-colors"
                           value={tier.description}
                           onChange={(e) => updateTier(tier.id, 'description', e.target.value)}
                         />
                      </div>

                      {/* Advanced controls — same shape as CreateEvent.
                          Times round-trip through Firestore Timestamps;
                          inputs use the wall-clock representation in
                          the event's timezone so renaming the timezone
                          doesn't silently shift sale windows. */}
                      <details className="col-span-2 mt-2" open={
                        !!(tier as any).salesStart || !!(tier as any).salesEnd ||
                        ((tier as any).visibility && (tier as any).visibility !== 'public') ||
                        ((tier as any).ticketType && (tier as any).ticketType !== 'paid')
                      }>
                        <summary className="type text-[9px] text-white/40 uppercase tracking-widest cursor-pointer hover:text-white">
                          Advanced (sale window, visibility, type)
                        </summary>
                        <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4 pt-4 border-t border-white/10">
                          <div className="space-y-2">
                            <label className="type text-[9px] text-white/40 uppercase tracking-widest ml-1">Type</label>
                            <select
                              className="w-full bg-black border border-white/20 py-3 px-5 text-white font-bold focus:outline-none focus:border-brand-primary transition-colors"
                              value={(tier as any).ticketType ?? 'paid'}
                              onChange={(e) => updateTier(tier.id, 'ticketType', e.target.value)}
                            >
                              <option value="paid">Paid</option>
                              <option value="free">Free</option>
                              <option value="donation">Donation</option>
                            </select>
                          </div>
                          <div className="space-y-2">
                            <label className="type text-[9px] text-white/40 uppercase tracking-widest ml-1">Visibility</label>
                            <select
                              className="w-full bg-black border border-white/20 py-3 px-5 text-white font-bold focus:outline-none focus:border-brand-primary transition-colors"
                              value={(tier as any).visibility ?? 'public'}
                              onChange={(e) => updateTier(tier.id, 'visibility', e.target.value)}
                            >
                              <option value="public">Public</option>
                              <option value="hidden">Hidden — unlock by code</option>
                            </select>
                          </div>
                          <div className="space-y-2">
                            <label className="type text-[9px] text-white/40 uppercase tracking-widest ml-1">Sales Open</label>
                            <input
                              type="datetime-local"
                              className="w-full bg-black border border-white/20 py-3 px-5 text-white font-bold focus:outline-none focus:border-brand-primary transition-colors cursor-pointer"
                              value={timestampToLocalInput((tier as any).salesStart, eventData.timezone)}
                              onClick={(e) => {
                                const el = e.currentTarget as HTMLInputElement;
                                if (typeof el.showPicker === 'function') {
                                  try { el.showPicker(); } catch { /* */ }
                                }
                              }}
                              onChange={(e) =>
                                updateTier(
                                  tier.id,
                                  'salesStart',
                                  localInputToTimestamp(e.target.value, eventData.timezone),
                                )
                              }
                            />
                          </div>
                          <div className="space-y-2">
                            <label className="type text-[9px] text-white/40 uppercase tracking-widest ml-1">Sales Close</label>
                            <input
                              type="datetime-local"
                              className="w-full bg-black border border-white/20 py-3 px-5 text-white font-bold focus:outline-none focus:border-brand-primary transition-colors cursor-pointer"
                              value={timestampToLocalInput((tier as any).salesEnd, eventData.timezone)}
                              onClick={(e) => {
                                const el = e.currentTarget as HTMLInputElement;
                                if (typeof el.showPicker === 'function') {
                                  try { el.showPicker(); } catch { /* */ }
                                }
                              }}
                              onChange={(e) =>
                                updateTier(
                                  tier.id,
                                  'salesEnd',
                                  localInputToTimestamp(e.target.value, eventData.timezone),
                                )
                              }
                            />
                          </div>
                          <p className="md:col-span-2 type text-[9px] text-white/30 uppercase tracking-widest leading-relaxed">
                            Times above are interpreted in the event's
                            timezone ({eventData.timezone || '(viewer-local)'}).
                          </p>
                        </div>
                      </details>
                   </div>
                </div>
              ))}
              {(eventData.ticketTiers || []).length === 0 && (
                <div className="text-center py-10 border border-dashed border-white/10">
                   <p className="type text-white/40 text-xs uppercase tracking-widest">No custom tiers defined. Primary price will be used.</p>
                </div>
              )}
           </div>
        </section>

        {/* Add-ons & Merch — self-contained CRUD (not part of the form submit). */}
        {eventId && <AddonsEditor eventId={eventId} />}

        {/* Vouchers — self-contained CRUD (not part of the form submit). */}
        {eventId && <VouchersEditor eventId={eventId} />}

        {/* Tax / VAT rules — self-contained CRUD (not part of the form submit). */}
        {eventId && <TaxRulesEditor eventId={eventId} />}

        {/* Commercial Logic Section */}
        <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-10">
           <div className="flex items-center space-x-3 mb-2">
              <Globe className="text-brand-primary w-5 h-5" />
              <h2 className="disp text-lg uppercase tracking-wide text-white leading-none">Commercial Exclusivity</h2>
           </div>

           <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div className="flex items-center justify-between p-6 bg-black/40 border border-white/10 hover:border-brand-primary/40 transition-all">
                 <div>
                    <p className="type text-[10px] text-white uppercase tracking-widest mb-1">Primary Market Only</p>
                    <p className="type text-[9px] text-white/40">Bypass all secondary distribution networks</p>
                 </div>
                 <input 
                    type="checkbox" 
                    className="w-5 h-5 accent-[#00FF00]"
                    checked={eventData.exclusivity?.primaryMarketOnly || false}
                    onChange={(e) => setEventData({ 
                      ...eventData, 
                      exclusivity: { ...(eventData.exclusivity || { primaryMarketOnly: false, customUrlOnly: false }), primaryMarketOnly: e.target.checked } 
                    })}
                 />
              </div>
              <div className="flex items-center justify-between p-6 bg-black/40 border border-white/10 hover:border-brand-primary/40 transition-all">
                 <div>
                    <p className="type text-[10px] text-white uppercase tracking-widest mb-1">Custom URL Exclusivity</p>
                    <p className="type text-[9px] text-white/40">Restricts visibility to private direct links</p>
                 </div>
                 <input 
                    type="checkbox" 
                    className="w-5 h-5 accent-[#00FF00]"
                    checked={eventData.exclusivity?.customUrlOnly || false}
                    onChange={(e) => setEventData({ 
                      ...eventData, 
                      exclusivity: { ...(eventData.exclusivity || { primaryMarketOnly: false, customUrlOnly: false }), customUrlOnly: e.target.checked } 
                    })}
                 />
              </div>
           </div>

           <div>
              <div className="flex items-center justify-between mb-4">
                 <h3 className="type text-[10px] text-white/40 uppercase tracking-widest">Active Discount Tokens</h3>
                 <button
                   type="button"
                   onClick={() => {
                     const codes = [...(eventData.discountCodes || [])];
                     // Pre-seed with empty fields so the organizer has to
                     // type a real code; saves an extra clear step.
                     codes.push({
                       code: '',
                       type: 'percentage',
                       value: 10,
                       usageLimit: null,
                       expiresAt: null,
                     });
                     setEventData({ ...eventData, discountCodes: codes });
                   }}
                   className="text-[10px] font-bold text-brand-primary uppercase tracking-widest"
                 >
                   Deploy Token
                 </button>
              </div>
              <div className="space-y-4">
                 {(eventData.discountCodes || []).map((dc, idx) => {
                   const codeStr = (dc.code || '').toUpperCase();
                   const usage = promoUsesState[codeStr];
                   const used = usage?.usedCount ?? 0;
                   // Lock identity-changing fields for codes that have
                   // already been redeemed — validate() will reject them
                   // anyway, but disabling at the UI level makes it
                   // obvious why.
                   const identityLocked = used > 0;
                   // The expiresAt input is `<input type="date">`, which
                   // wants yyyy-MM-dd. Convert from Timestamp-or-string.
                   const expIso = (() => {
                     if (!dc.expiresAt) return '';
                     const ts = dc.expiresAt as Timestamp | { toDate?: () => Date };
                     try {
                       const d = (ts as Timestamp).toDate
                         ? (ts as Timestamp).toDate()
                         : new Date(String(ts));
                       if (Number.isNaN(d.getTime())) return '';
                       return d.toISOString().slice(0, 10);
                     } catch {
                       return '';
                     }
                   })();
                   return (
                    <div key={idx} className="flex flex-wrap items-center gap-3 bg-black/40 p-4 border border-white/10">
                       <input
                          aria-label={`Discount code ${idx + 1}`}
                          maxLength={32}
                          disabled={identityLocked}
                          className="flex-grow min-w-[120px] bg-black border border-white/20 px-4 py-3 text-xs font-bold uppercase tracking-widest text-white disabled:opacity-60 disabled:cursor-not-allowed font-mono"
                          value={dc.code}
                          onChange={(e) => {
                             const codes = [...(eventData.discountCodes || [])];
                             codes[idx] = {
                               ...codes[idx],
                               code: e.target.value
                                 .toUpperCase()
                                 .replace(/[^A-Z0-9_-]/g, ''),
                             };
                             setEventData({ ...eventData, discountCodes: codes });
                          }}
                       />
                       <select
                          aria-label={`Discount type for code ${codeStr || idx + 1}`}
                          disabled={identityLocked}
                          className="bg-black border border-white/20 px-4 py-3 text-xs font-bold text-white/60 disabled:opacity-60 disabled:cursor-not-allowed"
                          value={dc.type}
                          onChange={(e) => {
                             const codes = [...(eventData.discountCodes || [])];
                             codes[idx] = { ...codes[idx], type: e.target.value as 'percentage' | 'fixed' };
                             setEventData({ ...eventData, discountCodes: codes });
                          }}
                       >
                          <option value="percentage">% Off</option>
                          <option value="fixed">$ Off</option>
                       </select>
                       <input
                          aria-label={`Discount value for code ${codeStr || idx + 1}`}
                          type="number"
                          min={0}
                          max={dc.type === 'percentage' ? 100 : undefined}
                          step="0.01"
                          disabled={identityLocked}
                          className="w-20 bg-black border border-white/20 px-4 py-3 text-xs font-bold text-white disabled:opacity-60 disabled:cursor-not-allowed"
                          value={dc.value}
                          onChange={(e) => {
                             const codes = [...(eventData.discountCodes || [])];
                             codes[idx] = { ...codes[idx], value: parseFloat(e.target.value) };
                             setEventData({ ...eventData, discountCodes: codes });
                          }}
                       />
                       <input
                          aria-label={`Usage limit for code ${codeStr || idx + 1}`}
                          type="number"
                          min={1}
                          placeholder="∞"
                          className="w-24 bg-black border border-white/20 px-4 py-3 text-xs font-bold text-white"
                          value={dc.usageLimit ?? ''}
                          onChange={(e) => {
                             const codes = [...(eventData.discountCodes || [])];
                             const v = parseInt(e.target.value, 10);
                             codes[idx] = {
                               ...codes[idx],
                               usageLimit: Number.isInteger(v) && v > 0 ? v : null,
                             };
                             setEventData({ ...eventData, discountCodes: codes });
                          }}
                       />
                       <input
                          aria-label={`Expiry date for code ${codeStr || idx + 1}`}
                          type="date"
                          className="w-36 bg-black border border-white/20 px-3 py-3 text-xs font-bold text-white"
                          value={expIso}
                          onChange={(e) => {
                             const codes = [...(eventData.discountCodes || [])];
                             const ms = e.target.value
                               ? new Date(e.target.value).getTime()
                               : NaN;
                             codes[idx] = {
                               ...codes[idx],
                               expiresAt: Number.isFinite(ms)
                                 ? Timestamp.fromDate(new Date(ms))
                                 : null,
                             };
                             setEventData({ ...eventData, discountCodes: codes });
                          }}
                       />
                       {used > 0 && (
                         <span
                           title="This code has redemptions. Identity fields are locked."
                           className="text-[9px] font-black text-emerald-400 bg-emerald-500/10 border border-emerald-500/30 px-2 py-1 rounded-full"
                         >
                           {used} USED
                         </span>
                       )}
                       <button
                         type="button"
                         aria-label={`Remove code ${codeStr || idx + 1}`}
                         disabled={identityLocked}
                         onClick={() => {
                            const codes = (eventData.discountCodes || []).filter((_, i) => i !== idx);
                            setEventData({ ...eventData, discountCodes: codes });
                         }}
                         className="p-2 text-white/30 hover:text-brand-accent transition-colors disabled:opacity-30 disabled:cursor-not-allowed"
                       >
                          <XCircle className="w-5 h-5" />
                       </button>

                      {/* Hidden-tier unlocks. Only renders when at least
                          one hidden tier exists on the event. Locking
                          mirrors the validate() guard: the multi-select
                          is read-only once a code has redemptions. */}
                      {(eventData.ticketTiers || []).some(
                        (t) => (t as any).visibility === 'hidden',
                      ) && (
                        <div className="basis-full mt-2 pt-3 border-t border-white/10">
                          <p className="type text-[9px] text-white/40 uppercase tracking-widest mb-2">
                            Unlocks hidden tiers
                          </p>
                          <div className="flex flex-wrap gap-2">
                            {(eventData.ticketTiers || [])
                              .filter((t) => (t as any).visibility === 'hidden')
                              .map((t) => {
                                const checked = (dc.unlocksTierIds || []).includes(t.id);
                                return (
                                  <label
                                    key={t.id}
                                    className={`flex items-center gap-2 px-3 py-1 rounded-full border text-[10px] font-bold uppercase tracking-widest ${
                                      identityLocked
                                        ? 'opacity-60 cursor-not-allowed'
                                        : 'cursor-pointer'
                                    } ${
                                      checked
                                        ? 'bg-brand-primary text-black border-brand-primary'
                                        : 'bg-black text-white/60 border-white/20 hover:border-white/40'
                                    }`}
                                  >
                                    <input
                                      type="checkbox"
                                      className="sr-only"
                                      checked={checked}
                                      disabled={identityLocked}
                                      onChange={() => {
                                        const codes = [...(eventData.discountCodes || [])];
                                        const cur = codes[idx].unlocksTierIds || [];
                                        codes[idx] = {
                                          ...codes[idx],
                                          unlocksTierIds: cur.includes(t.id)
                                            ? cur.filter((id) => id !== t.id)
                                            : [...cur, t.id],
                                        };
                                        setEventData({ ...eventData, discountCodes: codes });
                                      }}
                                    />
                                    {t.name || '(unnamed tier)'}
                                  </label>
                                );
                              })}
                          </div>
                        </div>
                      )}
                    </div>
                   );
                 })}
              </div>
           </div>
        </section>

        {/* Distribution Hub Section (Already present but refined) */}
        <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-8">
           <div className="flex items-center space-x-3 mb-2">
              <Palette className="text-brand-primary w-5 h-5" />
              <h2 className="disp text-lg uppercase tracking-wide text-white leading-none">Branding Engine</h2>
           </div>

           <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
              <div className="space-y-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Primary Signature (HEX)</label>
                <div className="flex space-x-4">
                  <input 
                    className="flex-grow bg-black border border-white/20 py-4 px-6 font-mono text-white focus:outline-none focus:border-brand-primary transition-colors"
                    value={eventData.branding?.primaryColor || ''}
                    onChange={(e) => setEventData({ 
                      ...eventData, 
                      branding: { ...(eventData.branding || {}), primaryColor: e.target.value } 
                    })}
                  />
                  <div className="w-14 h-14 border border-white/10" style={{ backgroundColor: eventData.branding?.primaryColor }}></div>
                </div>
              </div>
              <div className="space-y-2">
                <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Accent Signature (HEX)</label>
                <div className="flex space-x-4">
                  <input
                    className="flex-grow bg-black border border-white/20 py-4 px-6 font-mono text-white focus:outline-none focus:border-brand-primary transition-colors"
                    value={eventData.branding?.accentColor || ''}
                    onChange={(e) => setEventData({
                      ...eventData,
                      branding: { ...(eventData.branding || {}), accentColor: e.target.value }
                    })}
                  />
                  <div className="w-14 h-14 border border-white/10" style={{ backgroundColor: eventData.branding?.accentColor }}></div>
                </div>
              </div>

              {/*
                Vanity URL slug. Edit-time normalization mirrors what
                CreateEvent does so the value the user sees in the input
                is exactly what gets reserved at slugs/{slug}. Without
                that mirror, the slug-rename batch in handleSubmit was
                effectively dead code (no UI could change the value)
                AND would have produced confusing errors if the rule
                rejected an unnormalized slug.
              */}
              <div className="md:col-span-2 space-y-2">
                <label htmlFor="edit-event-slug" className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">
                  Custom Vanity Slug
                </label>
                <div className="relative">
                  <span className="absolute left-6 top-1/2 -translate-y-1/2 text-white/40 text-xs font-bold font-mono">
                    vibepass.io/e/
                  </span>
                  <input
                    id="edit-event-slug"
                    type="text"
                    maxLength={SLUG_MAX}
                    placeholder="summer-horizon-2026"
                    className="w-full bg-black border border-white/20 py-4 pl-32 pr-6 text-white font-bold focus:outline-none focus:border-brand-primary"
                    value={eventData.branding?.customSlug || ''}
                    onChange={(e) =>
                      setEventData({
                        ...eventData,
                        branding: {
                          ...(eventData.branding || {}),
                          customSlug: e.target.value
                            .toLowerCase()
                            .replace(/[^a-z0-9-]/g, '-')
                            .replace(/-+/g, '-')
                            .slice(0, SLUG_MAX),
                        },
                      })
                    }
                  />
                </div>
                <p className="type text-[9px] text-white/30 uppercase tracking-widest leading-relaxed">
                  Lowercase letters, digits, and hyphens. Renaming frees the
                  old slug atomically — clashes abort the save.
                </p>
              </div>
           </div>

            <div className="md:col-span-2 space-y-2">
              <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1">Event Artwork</label>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div className="relative border border-dashed border-white/20 p-8 flex flex-col items-center justify-center bg-black/40 hover:bg-black/60 transition-all cursor-pointer group">
                  <input
                    type="file"
                    accept="image/*"
                    className="absolute inset-0 opacity-0 cursor-pointer"
                    onChange={handleImageUpload}
                  />
                  <Upload className="w-8 h-8 text-white/40 mb-2 group-hover:text-brand-primary" />
                  <p className="type text-[10px] text-white/40 uppercase tracking-widest text-center">Change Artwork</p>
                </div>
                {eventData.image ? (
                  <div className="w-full h-32 overflow-hidden border border-white/10">
                    <img src={eventData.image} alt="Preview" className="w-full h-full object-cover" />
                  </div>
                ) : (
                  <div className="w-full h-32 bg-black/40 border border-white/10 flex items-center justify-center type text-[10px] text-white/30 uppercase tracking-widest">
                    No Art Detected
                  </div>
                )}
              </div>
           </div>
        </section>

        {/* Distribution Networks */}
        <section className="bg-[#111] border border-white/10 p-6 md:p-8 space-y-8">
           <div className="flex items-center space-x-3 mb-2">
              <Globe className="text-brand-primary w-5 h-5" />
              <h2 className="disp text-lg uppercase tracking-wide text-white leading-none">Distribution Hub Integration</h2>
           </div>

           <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
              {[
                { id: 'stubhub', name: 'StubHub' },
                { id: 'seatgeek', name: 'SeatGeek' },
                { id: 'ticketmaster', name: 'Ticketmaster' },
                { id: 'axs', name: 'AXS' },
                { id: 'vivid', name: 'Vivid Seats' },
                { id: 'gametime', name: 'Gametime' },
                { id: 'viagogo', name: 'Viagogo' },
                { id: 'tickpick', name: 'TickPick' },
                { id: 'gotickets', name: 'GoTickets' }
              ].map(network => (
                <label key={network.id} className="flex items-center space-x-3 p-4 bg-black/40 cursor-pointer hover:bg-black/60 transition-colors border border-white/10 has-[:checked]:border-brand-primary has-[:checked]:bg-brand-primary/10">
                   <input
                     type="checkbox"
                     className="w-4 h-4 accent-brand-primary"
                     defaultChecked={true}
                   />
                   <span className="type text-[10px] uppercase tracking-widest text-white/60">{network.name}</span>
                </label>
              ))}
           </div>
        </section>

        <button
          type="submit"
          disabled={saving}
          className="w-full bg-brand-primary text-black py-6 font-black uppercase italic tracking-tighter text-xs hover:bg-brand-primary/90 transition-all active:scale-[0.98] disabled:opacity-50"
        >
          {saving ? 'Synchronizing Manifest...' : 'Commit Changes to Ledger'}
        </button>

        {/*
          Notify attendees of an update. Published-only; explicit (not
          auto-fired on save) so a minor edit doesn't email every holder.
        */}
        {eventData.status === 'published' && (
          <section className="mt-8 bg-[#111] p-8 border border-white/10">
            <div className="flex items-start gap-3 mb-4">
              <Send className="text-white/50 w-5 h-5 flex-shrink-0 mt-1" />
              <div>
                <h3 className="text-sm font-black uppercase tracking-tighter italic text-white mb-1">
                  Notify attendees
                </h3>
                <p className="type text-xs text-white/50 max-w-prose">
                  Email every current ticket holder that this event's details
                  changed. Save your edits first, then send. Recipients are
                  derived server-side — no list to manage.
                </p>
              </div>
            </div>
            <button
              type="button"
              onClick={handleNotifyUpdate}
              disabled={notifying}
              className="px-6 py-3 bg-brand-primary hover:bg-brand-primary/90 disabled:opacity-50 text-black font-black uppercase tracking-tighter italic text-xs transition-all"
            >
              {notifying ? 'Sending…' : 'Email ticket holders about an update'}
            </button>
          </section>
        )}

        {/*
          Danger zone — cancellation. Only surfaced for published
          events that haven't already been cancelled. Hidden in draft
          state because cancelling a draft is just deleting it.
        */}
        {eventData.status === 'published' && (
          <section className="mt-8 bg-[#111] p-8 border border-brand-accent/40">
            <div className="flex items-start gap-3 mb-4">
              <AlertOctagon className="text-brand-accent w-5 h-5 flex-shrink-0 mt-1" />
              <div>
                <h3 className="text-sm font-black uppercase tracking-tighter italic text-brand-accent mb-1">
                  Cancel Event
                </h3>
                <p className="type text-xs text-white/50 max-w-prose">
                  Marks the event as cancelled, notifies every ticket holder by
                  email, and stops further sales. Direct-channel buyers will be
                  refunded automatically; secondary-channel buyers (StubHub, Vivid,
                  etc.) are pointed back to that channel for refund processing.
                </p>
              </div>
            </div>
            <button
              type="button"
              onClick={() => setShowCancelModal(true)}
              className="px-6 py-3 bg-brand-accent/10 hover:bg-brand-accent/20 text-brand-accent font-black uppercase tracking-tighter italic text-xs transition-all"
            >
              Cancel this event
            </button>
          </section>
        )}
      </form>

      {/* Cancellation confirmation modal. */}
      {showCancelModal && (
        <div
          className="fixed inset-0 z-50 bg-black/70 flex items-center justify-center p-4"
          onClick={() => !cancelling && setShowCancelModal(false)}
        >
          <div
            className="w-full max-w-md bg-[#111] border border-white/10 p-6"
            onClick={(e) => e.stopPropagation()}
          >
            <h2 className="text-xl font-black uppercase italic tracking-tighter text-white mb-2">
              Cancel event?
            </h2>
            <p className="text-sm text-white/50 mb-4">
              All ticket holders will be notified. This can't be undone — once
              cancelled, the event stays cancelled.
            </p>
            <label htmlFor="cancel-reason" className="block type text-[10px] text-white/40 uppercase tracking-widest mb-2">
              Reason (shown to buyers in their email)
            </label>
            <textarea
              id="cancel-reason"
              value={cancelReason}
              onChange={(e) => setCancelReason(e.target.value)}
              rows={3}
              maxLength={500}
              placeholder="Venue closure, artist illness, etc."
              className="w-full bg-black border border-white/20 px-3 py-2 text-sm text-white focus:outline-none focus:border-brand-primary"
            />
            <div className="flex gap-2 mt-4 justify-end">
              <button
                type="button"
                onClick={() => setShowCancelModal(false)}
                disabled={cancelling}
                className="px-4 py-2 bg-white/10 hover:bg-white/20 text-white font-black uppercase tracking-tighter italic text-xs transition-all"
              >
                Keep event
              </button>
              <button
                type="button"
                onClick={handleCancelEvent}
                disabled={cancelling || cancelReason.trim().length < 3}
                className="px-4 py-2 bg-brand-accent hover:bg-brand-accent/90 text-black font-black uppercase tracking-tighter italic text-xs transition-all disabled:opacity-50"
              >
                {cancelling ? 'Cancelling…' : 'Cancel event'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}