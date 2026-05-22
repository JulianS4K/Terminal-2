import { useState, useEffect, useRef, FormEvent, ChangeEvent } from 'react';
import { createEvent, getEventForEdit } from '../lib/events';
import { uploadEventImage, deleteStorageObject } from '../lib/storage';
import { useAuth } from '../context/AuthContext';
import { useOrganization } from '../context/OrganizationContext';
import { useNavigate, Link, useSearchParams } from 'react-router-dom';
import { ArrowLeft, Image as ImageIcon, Calendar as CalendarIcon, MapPin, Tag, DollarSign, ListOrdered, Upload, Globe, ShieldCheck, Loader2, Plus, X } from 'lucide-react';
import { handleFirestoreError, OperationType } from '../lib/utils';
import { useToast } from '../context/ToastContext';
import {
  COMMON_TIMEZONES,
  getBrowserTimezone,
  zonedWallClockToUtc,
} from '../lib/datetime';
import { EVENT_CATEGORIES, genresFor } from '../lib/eventTaxonomy';

// Image is now uploaded to Firebase Storage and only the download URL ends
// up in the Firestore event doc. We still cap at 5 MB on the client to give
// users a fast-failure experience — the Storage rules enforce the same cap.
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

// Limits matched against Firestore rule constraints. Keep in sync with
// `isValidEvent` in firestore.rules so the UI fails fast instead of getting
// a generic permission-denied at submit.
const TITLE_MAX = 100;
const DESCRIPTION_MAX = 2000;
const SUBGENRES_MAX_COUNT = 12;
const PERFORMERS_MAX_COUNT = 10;
const PERFORMER_MAX_LEN = 80;
const SUBGENRE_MAX_LEN = 40;
const SLUG_MAX = 80;
const LOCATION_MAX = 200;

// Optional Automatiq integration. The endpoint is not implemented yet, so we
// gate the call behind an env flag — otherwise every event creation 404s and
// writes a misleading `syncStatus: 'failed'` to the doc.
const AUTOMATIQ_ENABLED =
  (import.meta as any).env?.VITE_AUTOMATIQ_ENABLED === 'true';

interface PromoCodeDraft {
  id: string;
  code: string;
  type: 'percentage' | 'fixed';
  value: string;
  usageLimit: string;
  // Optional ISO date (yyyy-MM-dd) — empty means no expiry. Stored as a
  // Firestore Timestamp on submit when present.
  expiresAt: string;
  // Tier ids that this code makes visible. Used for hidden / pre-sale
  // tiers — applying the code in EventDetails reveals those rows.
  unlocksTierIds: string[];
  usedCount: number;
}

// ISO 4217 currency codes the UI exposes. Stripe processing for
// non-USD currencies is wired up by the payments team — this just
// stores the picker value alongside the event so prices render in
// the right symbol everywhere.
const SUPPORTED_CURRENCIES: { code: string; label: string }[] = [
  { code: 'USD', label: 'USD — US Dollar' },
  { code: 'EUR', label: 'EUR — Euro' },
  { code: 'GBP', label: 'GBP — British Pound' },
  { code: 'CAD', label: 'CAD — Canadian Dollar' },
  { code: 'AUD', label: 'AUD — Australian Dollar' },
  { code: 'JPY', label: 'JPY — Japanese Yen' },
  { code: 'MXN', label: 'MXN — Mexican Peso' },
  { code: 'BRL', label: 'BRL — Brazilian Real' },
];

export default function CreateEvent() {
  const { user } = useAuth();
  // Bridge multi-tenant: every new event must belong to the active org.
  // Falls back to legacy uid-only path if the user has no orgs yet so
  // existing flows keep working pre-migration.
  const { activeOrg, orgs, loading: orgLoading } = useOrganization();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const cloneFromId = searchParams.get('clone');
  const { toast } = useToast();
  const [loading, setLoading] = useState(false);
  const [hydratingClone, setHydratingClone] = useState<boolean>(!!cloneFromId);
  const [uploadingImage, setUploadingImage] = useState(false);
  // Track every Storage path the user has uploaded during this session.
  // We use this to clean up orphans on cancel-with-discard and to delete
  // the previous file when the user uploads a replacement — without it,
  // every abandoned draft permanently consumes Storage quota.
  const uploadedImagePathRef = useRef<string | null>(null);
  const [formData, setFormData] = useState({
    title: '',
    description: '',
    date: '',
    location: '',
    price: '',
    totalTickets: '',
    image: '',
    category: 'Music',
    timezone: getBrowserTimezone(),
    currency: 'USD',
    address: {
      street: '',
      city: '',
      region: '',
      country: '',
      postal: '',
    },
    genres: [] as string[],
    subgenres: [] as string[],
    performers: [] as string[],
    timing: {
      doorsOpen: '',
      startTime: '',
      endTime: ''
    },
    branding: {
      primaryColor: '#0f172a',
      accentColor: '#6366f1',
      customSlug: ''
    },
    exclusivity: {
      primaryMarketOnly: false,
      customUrlOnly: false
    },
    purchaseLimits: {
      maxPerOrder: '8',
      maxPerAccount: '8'
    },
    distributionNetworks: ['stubhub', 'seatgeek', 'ticketmaster', 'axs', 'vivid', 'gametime', 'viagogo', 'tickpick', 'gotickets', 'ticketevolution']
  });
  const [promoCodes, setPromoCodes] = useState<PromoCodeDraft[]>([]);

  // Tier draft shape carries the new fields as plain strings so empty
  // datetime/number inputs don't render "undefined" or "0" in the form.
  type TierDraft = {
    id: string;
    name: string;
    price: string;
    description: string;
    capacity: string;
    sold: number;
    ticketType: 'paid' | 'free' | 'donation';
    visibility: 'public' | 'hidden';
    salesStart: string; // datetime-local string, empty = no window
    salesEnd: string;
  };
  const makeBlankTier = (preset?: Partial<TierDraft>): TierDraft => ({
    id: crypto.randomUUID(),
    name: '',
    price: '',
    description: '',
    capacity: '',
    sold: 0,
    ticketType: 'paid',
    visibility: 'public',
    salesStart: '',
    salesEnd: '',
    ...(preset || {}),
  });
  const [ticketTiers, setTicketTiers] = useState<TierDraft[]>([
    makeBlankTier({
      name: 'General Admission',
      description: 'Standard entry to the event.',
    }),
  ]);

  // ---- Draft autosave --------------------------------------------------
  // Long-form data lives a long time in users' fingers and not at all in
  // a refreshed tab. We mirror everything to localStorage on change and
  // restore on mount so an accidental nav-away doesn't cost an organizer
  // their work. We keep this scoped per-user so two accounts on the same
  // browser don't trip over each other.
  const draftKey = `vibepass:draft-event:${user?.uid ?? 'anon'}`;
  // Block the autosave write until we've decided whether to restore — we
  // don't want the empty initial state to immediately overwrite a saved
  // draft on mount.
  const [autosaveReady, setAutosaveReady] = useState(false);
  const restoredRef = useRef(false);

  // Restore-or-discard prompt on first paint.
  useEffect(() => {
    if (restoredRef.current) return;
    restoredRef.current = true;
    try {
      const raw = localStorage.getItem(draftKey);
      if (!raw) {
        setAutosaveReady(true);
        return;
      }
      const saved = JSON.parse(raw);
      // Be lenient about shape — old drafts pre-rename shouldn't crash
      // the page; if they don't have what we expect, drop them silently.
      if (
        saved &&
        typeof saved === 'object' &&
        saved.formData &&
        Array.isArray(saved.ticketTiers)
      ) {
        if (window.confirm('You have an unsaved event draft. Restore it?')) {
          setFormData((prev) => ({ ...prev, ...saved.formData }));
          setTicketTiers(saved.ticketTiers);
          if (Array.isArray(saved.promoCodes)) setPromoCodes(saved.promoCodes);
        } else {
          localStorage.removeItem(draftKey);
        }
      } else {
        localStorage.removeItem(draftKey);
      }
    } catch (err) {
      console.warn('Could not restore draft', err);
      try {
        localStorage.removeItem(draftKey);
      } catch {
        /* ignore */
      }
    } finally {
      setAutosaveReady(true);
    }
    // We intentionally only run this once per uid — autosave write happens
    // in a separate effect below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user?.uid]);

  // Debounced write. We don't store image data — the URL is fine but if
  // the user uploaded a new file before publishing, we don't want to
  // re-upload from a stale draft on restore (the URL itself is short).
  // ---- Event clone hydration -----------------------------------------
  // /create-event?clone=<eventId> pre-fills the form from an existing
  // event. We deliberately:
  //   * Never carry forward the slug, ticketsSold, status, sub-collection
  //     state, or any audit-log refs — the clone is a brand-new draft.
  //   * Generate fresh tier ids and promo code ids so the new event's
  //     tierSales / promoUses sub-collections start clean.
  //   * Pull the source event publicly (events are readable by anyone
  //     for published / cancelled events) — admins can clone drafts they
  //     have access to via the same rule.
  useEffect(() => {
    if (!cloneFromId || restoredRef.current) return;
    let cancelled = false;
    (async () => {
      try {
        const ev = await getEventForEdit(cloneFromId);
        if (cancelled || !ev) {
          setHydratingClone(false);
          return;
        }
        const src = ev as unknown as Record<string, any>;
        setFormData((prev) => ({
          ...prev,
          title: (src.title || '') + ' (Copy)',
          description: src.description || '',
          location: src.location || '',
          category: src.category || prev.category,
          timezone: src.timezone || prev.timezone,
          currency: src.currency || prev.currency,
          address: {
            street: src.address?.street || '',
            city: src.address?.city || '',
            region: src.address?.region || '',
            country: src.address?.country || '',
            postal: src.address?.postal || '',
          },
          genres: Array.isArray(src.genres) ? src.genres : [],
          subgenres: Array.isArray(src.subgenres) ? src.subgenres : [],
          performers: Array.isArray(src.performers) ? src.performers : [],
          totalTickets: String(src.totalTickets ?? ''),
          price: String(src.price ?? ''),
          image: src.image || '',
          // Slug intentionally cleared — uniqueness rule would reject a
          // duplicate, and the user almost certainly wants a different one.
          branding: {
            primaryColor: src.branding?.primaryColor || prev.branding.primaryColor,
            accentColor: src.branding?.accentColor || prev.branding.accentColor,
            customSlug: '',
          },
          purchaseLimits: {
            maxPerOrder: String(src.purchaseLimits?.maxPerOrder ?? '8'),
            maxPerAccount: String(src.purchaseLimits?.maxPerAccount ?? '8'),
          },
          // Don't copy timing — the new event is for a future date.
          timing: { doorsOpen: '', startTime: '', endTime: '' },
          date: '',
        }));
        if (Array.isArray(src.ticketTiers)) {
          setTicketTiers(
            src.ticketTiers.map((t: any) =>
              makeBlankTier({
                name: t.name || '',
                description: t.description || '',
                price: String(t.price ?? ''),
                capacity: String(t.capacity ?? ''),
                ticketType: t.ticketType ?? 'paid',
                visibility: t.visibility ?? 'public',
              }),
            ),
          );
        }
        if (Array.isArray(src.discountCodes)) {
          setPromoCodes(
            src.discountCodes.map((d: any) => ({
              id: crypto.randomUUID(),
              code: d.code || '',
              type: d.type || 'percentage',
              value: String(d.value ?? ''),
              usageLimit: d.usageLimit != null ? String(d.usageLimit) : '',
              expiresAt: '',
              unlocksTierIds: Array.isArray(d.unlocksTierIds) ? d.unlocksTierIds : [],
              usedCount: 0,
            })),
          );
        }
      } catch (err) {
        console.warn('Could not hydrate clone source:', err);
      } finally {
        if (!cancelled) setHydratingClone(false);
      }
    })();
    return () => {
      cancelled = true;
    };
    // We deliberately run this only when cloneFromId is first read; the
    // restored-from-localStorage flow takes precedence if there's a draft.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cloneFromId]);

  useEffect(() => {
    if (!autosaveReady) return;
    const t = setTimeout(() => {
      try {
        localStorage.setItem(
          draftKey,
          JSON.stringify({
            formData,
            ticketTiers,
            promoCodes,
            savedAt: Date.now(),
          }),
        );
      } catch (err) {
        // Most likely cause: storage quota exceeded (very large image
        // data URLs no longer apply, but other apps can crowd us out).
        console.warn('Autosave failed', err);
      }
    }, 600);
    return () => clearTimeout(t);
  }, [autosaveReady, draftKey, formData, ticketTiers, promoCodes]);

  const clearDraft = () => {
    try {
      localStorage.removeItem(draftKey);
    } catch {
      /* ignore */
    }
  };

  const addTier = () => {
    setTicketTiers([...ticketTiers, makeBlankTier()]);
  };

  const removeTier = (id: string) => {
    if (ticketTiers.length > 1) {
      setTicketTiers(ticketTiers.filter(t => t.id !== id));
    }
  };

  // `value` is typed loosely because tier fields are a mix of string,
  // number-as-string, and union-typed enums (ticketType / visibility).
  // TypeScript can't narrow that statically through a string field name,
  // so we accept `unknown` and trust the caller — there are only four
  // call sites and they all pass valid shapes.
  const updateTier = (id: string, field: string, value: unknown) => {
    setTicketTiers(
      ticketTiers.map((t) => (t.id === id ? ({ ...t, [field]: value } as typeof t) : t)),
    );
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

    // Upload to Supabase Storage (exos-media bucket). RLS gates writes to
    // event-images/{auth.uid}/* so users can't overwrite each other's files.
    // Only the public URL ends up on the event row — the row stays small and
    // listing queries don't drag image bytes.
    setUploadingImage(true);
    try {
      const { path, url } = await uploadEventImage(user.uid, file);

      // If a previous upload from this session is now orphaned by this
      // replacement, delete it so abandoned drafts don't accumulate
      // Storage objects. Best-effort — deleteStorageObject never throws.
      const previous = uploadedImagePathRef.current;
      if (previous && previous !== path) {
        await deleteStorageObject(previous);
      }
      uploadedImagePathRef.current = path;

      setFormData((prev) => ({ ...prev, image: url }));
      toast({ kind: 'success', message: 'Image uploaded.' });
    } catch (err) {
      console.error('Image upload failed', err);
      toast({
        kind: 'error',
        title: 'Upload failed',
        message: 'Could not upload the image. Please try again.',
      });
      e.target.value = '';
    } finally {
      setUploadingImage(false);
    }
  };

  /**
   * Delete the in-progress Storage upload, if any. Called from the
   * cancel-with-discard path so an abandoned draft doesn't leave an
   * orphaned file behind.
   *
   * Not called on successful save — at that point the file is part of
   * the published event and we explicitly want to keep it.
   */
  const cleanupOrphanedImage = async () => {
    const path = uploadedImagePathRef.current;
    if (!path) return;
    // Best-effort — deleteStorageObject swallows errors (already-deleted /
    // offline are both non-fatal for orphan cleanup).
    await deleteStorageObject(path);
    uploadedImagePathRef.current = null;
  };

  // Categories + genre chips come from the taxonomy module so adding a
  // category in the future is a one-file change.
  const categories = EVENT_CATEGORIES;

  // ---- Promo code editor helpers ---------------------------------------
  // We keep the UI fields as strings (so empty inputs don't show "0") and
  // coerce on submit, mirroring the tier editor below.
  const addPromoCode = () => {
    setPromoCodes((prev) => [
      ...prev,
      {
        id: crypto.randomUUID(),
        code: '',
        type: 'percentage',
        value: '',
        usageLimit: '',
        expiresAt: '',
        unlocksTierIds: [],
        usedCount: 0,
      },
    ]);
  };
  const removePromoCode = (id: string) => {
    setPromoCodes((prev) => prev.filter((p) => p.id !== id));
  };
  const updatePromoCode = (
    id: string,
    field: keyof PromoCodeDraft,
    value: string,
  ) => {
    setPromoCodes((prev) =>
      prev.map((p) =>
        p.id === id
          ? {
              ...p,
              [field]:
                field === 'code'
                  ? value.toUpperCase().replace(/[^A-Z0-9_-]/g, '').slice(0, 32)
                  : value,
            }
          : p,
      ),
    );
  };

  // Flip a tier id in/out of a code's unlocksTierIds. Kept separate from
  // updatePromoCode because the value type is array-shaped, not string.
  const togglePromoUnlock = (codeId: string, tierId: string) => {
    setPromoCodes((prev) =>
      prev.map((p) => {
        if (p.id !== codeId) return p;
        const has = p.unlocksTierIds.includes(tierId);
        return {
          ...p,
          unlocksTierIds: has
            ? p.unlocksTierIds.filter((t) => t !== tierId)
            : [...p.unlocksTierIds, tierId],
        };
      }),
    );
  };

  const handleGenreToggle = (genre: string) => {
    const current = formData.genres;
    if (current.includes(genre)) {
      setFormData({ ...formData, genres: current.filter(g => g !== genre) });
    } else {
      setFormData({ ...formData, genres: [...current, genre] });
    }
  };

  /**
   * Run all client-side validation that mirrors firestore.rules constraints.
   * Returns null on success, or a user-facing error message on failure.
   *
   * The server still enforces these via rules, but a permission-denied is a
   * lousy way to tell a user "your title is too long" — much better to fail
   * fast in the UI with a real explanation.
   */
  const validate = (): string | null => {
    const t = formData.title.trim();
    if (!t) return 'Please enter an event title.';
    if (t.length > TITLE_MAX) return `Title must be ${TITLE_MAX} characters or fewer.`;

    if (formData.description.length > DESCRIPTION_MAX) {
      return `Description must be ${DESCRIPTION_MAX} characters or fewer.`;
    }

    if (formData.location.length > LOCATION_MAX) {
      return `Location must be ${LOCATION_MAX} characters or fewer.`;
    }

    if (formData.subgenres.length > SUBGENRES_MAX_COUNT) {
      return `Please choose at most ${SUBGENRES_MAX_COUNT} subgenres.`;
    }
    if (formData.performers.length > PERFORMERS_MAX_COUNT) {
      return `Please list at most ${PERFORMERS_MAX_COUNT} performers.`;
    }
    if (formData.performers.some((p) => p.length > PERFORMER_MAX_LEN)) {
      return `Each performer name must be ${PERFORMER_MAX_LEN} characters or fewer.`;
    }
    if (formData.subgenres.some((s) => s.length > SUBGENRE_MAX_LEN)) {
      return `Each subgenre must be ${SUBGENRE_MAX_LEN} characters or fewer.`;
    }

    if (formData.branding.customSlug.length > SLUG_MAX) {
      return `Custom URL must be ${SLUG_MAX} characters or fewer.`;
    }

    const price = parseFloat(formData.price);
    if (!Number.isFinite(price) || price < 0) {
      return 'Please enter a valid admission price (0 or more).';
    }

    const total = parseInt(formData.totalTickets, 10);
    if (!Number.isInteger(total) || total < 1) {
      return 'Please enter a valid total ticket count (1 or more).';
    }

    // Timing: parse all three potential dates and verify ordering.
    const startTimeStr = formData.timing.startTime || formData.date;
    if (!startTimeStr) return 'Please set the show start time.';
    const startMs = new Date(startTimeStr).getTime();
    if (!Number.isFinite(startMs)) return 'Show start time is invalid.';
    if (startMs < Date.now()) return 'Show start time must be in the future.';

    if (formData.timing.doorsOpen) {
      const doorsMs = new Date(formData.timing.doorsOpen).getTime();
      if (!Number.isFinite(doorsMs)) return 'Doors-open time is invalid.';
      if (doorsMs > startMs) return 'Doors must open before the show starts.';
    }
    if (formData.timing.endTime) {
      const endMs = new Date(formData.timing.endTime).getTime();
      if (!Number.isFinite(endMs)) return 'Show end time is invalid.';
      if (endMs <= startMs) return 'Show end must be after the show start.';
    }

    // Tier validations.
    if (ticketTiers.length === 0) return 'Please define at least one tier.';
    let capacitySum = 0;
    for (const t of ticketTiers) {
      if (!t.name.trim()) return 'Every tier needs a name.';
      const tp = parseFloat(t.price as string);
      const tc = parseInt(t.capacity as string, 10);
      if (!Number.isFinite(tp) || tp < 0) {
        return `Tier "${t.name}" has an invalid price.`;
      }
      if (!Number.isInteger(tc) || tc < 1) {
        return `Tier "${t.name}" has an invalid capacity.`;
      }
      // Ticket-type / price interaction.
      if (t.ticketType === 'free' && tp !== 0) {
        return `Tier "${t.name}" is marked Free — set price to 0.`;
      }
      if (t.ticketType === 'paid' && tp === 0) {
        return `Tier "${t.name}" has price 0 — switch its type to Free or set a price.`;
      }
      // Sale window: end must be after start.
      if (t.salesStart && t.salesEnd) {
        const ws = new Date(t.salesStart).getTime();
        const we = new Date(t.salesEnd).getTime();
        if (Number.isFinite(ws) && Number.isFinite(we) && we <= ws) {
          return `Tier "${t.name}": sales end must be after sales start.`;
        }
      }
      // Sale window must end before show end (if both set).
      if (t.salesEnd && formData.timing.endTime) {
        const we = new Date(t.salesEnd).getTime();
        const showEnd = new Date(formData.timing.endTime).getTime();
        if (Number.isFinite(we) && Number.isFinite(showEnd) && we > showEnd) {
          return `Tier "${t.name}": sales end is after the event ends.`;
        }
      }
      capacitySum += tc;
    }
    if (capacitySum > total) {
      return `Tier capacities sum to ${capacitySum}, but the event total is ${total}. Reduce tier capacities or raise the total.`;
    }

    // Currency: ISO 4217 three-letter code.
    if (!/^[A-Z]{3}$/.test(formData.currency)) {
      return 'Currency must be a 3-letter ISO code (e.g. USD, EUR).';
    }

    // Promo codes — keep the per-row validation tight so we don't write
    // junk that will silently fail at redemption time.
    const seenCodes = new Set<string>();
    for (const p of promoCodes) {
      const code = p.code.trim().toUpperCase();
      if (!code) return 'Every promo code needs a value (e.g. EARLY30).';
      if (!/^[A-Z0-9_-]+$/.test(code)) {
        return `Promo code "${code}" can only contain A-Z, 0-9, underscore and hyphen.`;
      }
      if (seenCodes.has(code)) {
        return `Promo code "${code}" is repeated. Use distinct codes.`;
      }
      seenCodes.add(code);
      const v = parseFloat(p.value);
      if (!Number.isFinite(v) || v < 0) {
        return `Promo code "${code}" needs a non-negative discount value.`;
      }
      if (p.type === 'percentage' && v > 100) {
        return `Promo code "${code}" can't be more than 100%.`;
      }
      if (p.usageLimit) {
        const lim = parseInt(p.usageLimit, 10);
        if (!Number.isInteger(lim) || lim < 1) {
          return `Promo code "${code}" usage limit must be a positive integer.`;
        }
      }
      if (p.expiresAt) {
        const expMs = new Date(p.expiresAt).getTime();
        if (!Number.isFinite(expMs)) {
          return `Promo code "${code}" has an invalid expiry date.`;
        }
        if (expMs < Date.now()) {
          return `Promo code "${code}" expires in the past.`;
        }
      }
    }

    return null;
  };

  const handleSubmit = async (e: FormEvent, publish: boolean) => {
    e.preventDefault();
    if (!user) return;
    if (uploadingImage) {
      toast({ kind: 'warn', message: 'Wait for the image upload to finish.' });
      return;
    }

    const err = validate();
    if (err) {
      toast({ kind: 'error', title: 'Check your details', message: err });
      return;
    }

    setLoading(true);
    try {
      // Convert wall-clock inputs (datetime-local) into UTC Timestamps,
      // interpreting each one in the event's timezone — that way
      // "8pm in NY" stays "8pm in NY" for every viewer regardless of
      // their browser's local zone.
      const tz = formData.timezone;
      // zonedWallClockToUtc returns null only when the input doesn't
      // match yyyy-MM-ddTHH:mm — datetime-local always emits that shape
      // and validate() above already rejected empty timing, so the null
      // branches below are unreachable in practice. We bail out hard
      // anyway: the previous fallback (`?? new Date(input)`) silently
      // produced browser-local-interpreted UTC which would corrupt the
      // event's stored time if anything ever changed upstream.
      const startUtc = zonedWallClockToUtc(
        formData.timing.startTime || formData.date,
        tz,
      );
      if (!startUtc) {
        toast({
          kind: 'error',
          title: 'Invalid start time',
          message: 'Could not parse the show start time. Please re-enter it.',
        });
        return;
      }
      const doorsUtc = formData.timing.doorsOpen
        ? zonedWallClockToUtc(formData.timing.doorsOpen, tz)
        : null;
      if (formData.timing.doorsOpen && !doorsUtc) {
        toast({
          kind: 'error',
          title: 'Invalid doors-open time',
          message: 'Could not parse the doors-open time. Please re-enter it.',
        });
        return;
      }
      const endUtc = formData.timing.endTime
        ? zonedWallClockToUtc(formData.timing.endTime, tz)
        : null;
      if (formData.timing.endTime && !endUtc) {
        toast({
          kind: 'error',
          title: 'Invalid end time',
          message: 'Could not parse the show end time. Please re-enter it.',
        });
        return;
      }

      const totalTickets = parseInt(formData.totalTickets, 10);
      // TierInput[] for the events seam (ISO strings; DB generates tier ids).
      const tiers = ticketTiers.map((t) => {
        const salesStartUtc = t.salesStart ? zonedWallClockToUtc(t.salesStart, tz) : null;
        const salesEndUtc = t.salesEnd ? zonedWallClockToUtc(t.salesEnd, tz) : null;
        return {
          name: t.name.trim(),
          description: t.description?.trim() || '',
          price: parseFloat(t.price as string),
          capacity: parseInt(t.capacity as string, 10),
          ticketType: t.ticketType,
          visibility: t.visibility,
          salesStart: salesStartUtc ? salesStartUtc.toISOString() : null,
          salesEnd: salesEndUtc ? salesEndUtc.toISOString() : null,
        };
      });

      const slug = formData.branding.customSlug.trim();

      // Events belong to an org (exos_events.org_id is NOT NULL). Require an
      // active org — the dashboard nudges org creation when the user has none.
      if (!activeOrg) {
        toast({
          kind: 'error',
          title: 'No organization',
          message: 'Create an organization first — events belong to an org.',
        });
        return;
      }

      const addr = Object.values(formData.address).some((v) => String(v || '').trim())
        ? {
            street: formData.address.street.trim(),
            city: formData.address.city.trim(),
            region: formData.address.region.trim(),
            country: formData.address.country.trim(),
            postal: formData.address.postal.trim(),
          }
        : undefined;

      try {
        await createEvent({
          orgId: activeOrg.id,
          name: formData.title.trim(),
          description: formData.description.trim(),
          status: publish ? 'published' : 'draft',
          slug: slug || null,
          startsAt: startUtc.toISOString(),
          doorsAt: doorsUtc ? doorsUtc.toISOString() : null,
          endsAt: endUtc ? endUtc.toISOString() : null,
          timezone: tz,
          currency: formData.currency.toUpperCase(),
          venueName: formData.location.trim(),
          venueLocation: formData.location.trim(),
          venueAddress: addr,
          primaryPerformerName: formData.performers[0],
          performerNames: formData.performers.length > 0 ? formData.performers : undefined,
          category: formData.category,
          genres: formData.genres,
          subgenres: formData.subgenres,
          imageUrl: formData.image,
          totalTickets,
          branding: {
            primaryColor: formData.branding.primaryColor,
            accentColor: formData.branding.accentColor,
            customSlug: slug,
          },
          exclusivity: {
            primaryMarketOnly: formData.exclusivity.primaryMarketOnly,
            customUrlOnly: formData.exclusivity.customUrlOnly,
          },
          purchaseLimits: {
            maxPerOrder: parseInt(formData.purchaseLimits.maxPerOrder, 10) || 8,
            maxPerAccount: parseInt(formData.purchaseLimits.maxPerAccount, 10) || 8,
          },
          distributionNetworks: formData.distributionNetworks,
          tiers,
          discountCodes: promoCodes
            .filter((p) => p.code.trim())
            .map((p) => {
              const usage = parseInt(p.usageLimit, 10);
              const expMs = p.expiresAt ? new Date(p.expiresAt).getTime() : NaN;
              return {
                code: p.code.trim().toUpperCase(),
                type: p.type,
                value: parseFloat(p.value),
                usageLimit: Number.isInteger(usage) && usage > 0 ? usage : null,
                expiresAt: Number.isFinite(expMs) ? new Date(expMs).toISOString() : null,
              };
            }),
        });
      } catch (commitErr) {
        // exos_events.slug is UNIQUE — a collision surfaces as a unique violation.
        if (slug && /duplicate|unique|exists/i.test(String(commitErr))) {
          toast({
            kind: 'error',
            title: 'Slug already taken',
            message: `"${slug}" is already in use. Pick a different vanity URL.`,
          });
          return;
        }
        throw commitErr;
      }

      // Automatiq distribution sync is later-phase (env-gated + needs the
      // distribution rails). The old Firestore-based sync write is removed; it
      // returns with the Automatiq integration.

      // Successful save (publish or draft). Drop the localStorage draft so
      // the next visit to /create-event starts clean. The Storage upload
      // (if any) is now part of the saved event — clear the orphan ref
      // so a subsequent cancel doesn't try to delete a live file.
      clearDraft();
      uploadedImagePathRef.current = null;
      toast({
        kind: 'success',
        message: publish ? 'Event published.' : 'Draft saved.',
      });
      navigate('/dashboard');
    } catch (error) {
      handleFirestoreError(error, OperationType.WRITE, 'events', toast);
    } finally {
      setLoading(false);
    }
  };

  // Email-verify gate: the Firestore rule requires `isVerified()` (the auth
  // token's `email_verified` claim) on event creation. Without this guard,
  // an unverified user fills out the entire form before getting a generic
  // permission-denied at submit time.
  if (!user) {
    return (
      <div className="max-w-xl mx-auto px-4 py-24 text-center">
        <h1 className="text-3xl font-bold text-slate-900 mb-4">Sign in to create an event</h1>
        <p className="text-slate-500 mb-10">Use the navbar to sign in, then come back here.</p>
        <Link to="/" className="bg-slate-900 text-white px-10 py-4 rounded-2xl font-bold text-xs uppercase tracking-widest shadow-xl">Back home</Link>
      </div>
    );
  }
  if (!user.emailVerified) {
    return (
      <div className="max-w-xl mx-auto px-4 py-24 text-center">
        <h1 className="text-3xl font-bold text-slate-900 mb-4">Verify your email first</h1>
        <p className="text-slate-500 mb-10">
          We sent a verification link to <strong>{user.email}</strong>. Click it,
          then refresh this page to start creating events.
        </p>
        <button
          onClick={() => window.location.reload()}
          className="bg-slate-900 text-white px-10 py-4 rounded-2xl font-bold text-xs uppercase tracking-widest shadow-xl"
        >
          I&apos;ve verified — reload
        </button>
      </div>
    );
  }

  return (
    <div className="max-w-3xl mx-auto px-4 py-12">
      <div className="flex items-center justify-between mb-12">
        <div>
          <h1 className="text-3xl font-bold tracking-tight text-slate-900 mb-2">Configure Experience</h1>
          <p className="text-slate-500 font-medium text-sm tracking-wide">Enter the technical specs for your event listing.</p>
        </div>
        <div className="w-12 h-12 bg-slate-900 rounded-2xl flex items-center justify-center text-white font-bold">1</div>
      </div>

      {/*
        Active-org banner. We surface the active org so multi-org users
        know which one this event is being filed under, and we offer a
        path to create one if they have none yet. We don't HARD-block
        creating an event without an org because legacy single-tenant
        flows keep working under the rule's backwards-compat path —
        but we make it obvious that org-less events won't show on a
        white-label storefront once Sprint 2 lands.
      */}
      {!orgLoading && (
        <div className="mb-8">
          {activeOrg ? (
            <div className="bg-brand-primary/10 border border-brand-primary/30 px-4 py-3 text-xs font-bold uppercase tracking-widest text-brand-primary flex items-center justify-between gap-3">
              <span>Filing under: {activeOrg.name}</span>
              <Link to="/orgs" className="underline hover:no-underline">Switch</Link>
            </div>
          ) : orgs.length === 0 ? (
            <div className="bg-yellow-500/10 border border-yellow-500/30 px-4 py-3 text-xs font-bold uppercase tracking-widest text-yellow-600">
              No organization yet —{' '}
              <Link to="/orgs/new" className="underline hover:no-underline">create one</Link>{' '}
              to enable white-label and distribution. Or proceed without one (legacy path).
            </div>
          ) : (
            <div className="bg-yellow-500/10 border border-yellow-500/30 px-4 py-3 text-xs font-bold uppercase tracking-widest text-yellow-600">
              No active org —{' '}
              <Link to="/orgs" className="underline hover:no-underline">pick one</Link>{' '}
              before publishing.
            </div>
          )}
        </div>
      )}

      <form onSubmit={(e) => handleSubmit(e, true)} className="space-y-10 group">
        <div className="bg-white p-10 rounded-[2.5rem] border border-slate-100 shadow-sm space-y-8">
          <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
            <div className="md:col-span-2 space-y-2">
              <label htmlFor="event-title" className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Event Descriptor</label>
              <div className="relative">
                <Tag className="absolute left-6 top-1/2 -translate-y-1/2 text-slate-400 w-4 h-4" aria-hidden="true" />
                <input
                  id="event-title"
                  required
                  type="text"
                  maxLength={TITLE_MAX}
                  placeholder="e.g. Midnight Horizon Festival"
                  className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 pl-14 pr-6 text-slate-900 font-bold focus:outline-none focus:border-brand-primary focus:bg-white transition-all shadow-inner"
                  value={formData.title}
                  onChange={(e) => setFormData({ ...formData, title: e.target.value })}
                />
              </div>
            </div>

            <div className="space-y-2">
              <label htmlFor="event-category" className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Category</label>
              <select
                id="event-category"
                className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 px-6 text-slate-900 font-bold focus:outline-none focus:border-brand-primary focus:bg-white transition-all appearance-none"
                value={formData.category}
                onChange={(e) => setFormData({ ...formData, category: e.target.value })}
              >
                {categories.map(c => <option key={c} value={c}>{c}</option>)}
              </select>
            </div>

            <div className="space-y-4 md:col-span-2">
              <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Genres for {formData.category}</label>
              <div className="flex flex-wrap gap-2">
                {genresFor(formData.category).map(genre => (
                  <button
                    key={genre}
                    type="button"
                    onClick={() => handleGenreToggle(genre)}
                    className={`px-4 py-2 rounded-xl text-[10px] font-black uppercase tracking-widest transition-all border ${
                      formData.genres.includes(genre)
                        ? 'bg-brand-primary text-black border-black'
                        : 'bg-slate-50 text-slate-400 border-transparent hover:border-slate-200'
                    }`}
                  >
                    {genre}
                  </button>
                ))}
              </div>
            </div>

            <div className="md:col-span-2 space-y-2">
              <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Custom Subgenres</label>
              <input
                type="text"
                placeholder={`e.g. Ambient, Techno, Deep House (max ${SUBGENRES_MAX_COUNT}, comma-separated)`}
                className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 px-6 text-slate-900 font-bold focus:outline-none focus:border-brand-primary focus:bg-white transition-all shadow-inner"
                value={formData.subgenres.join(', ')}
                onChange={(e) => {
                  const val = Array.from(
                    new Set(
                      e.target.value
                        .split(',')
                        .map((s) => s.trim().slice(0, SUBGENRE_MAX_LEN))
                        .filter(Boolean),
                    ),
                  ).slice(0, SUBGENRES_MAX_COUNT);
                  setFormData({ ...formData, subgenres: val });
                }}
              />
            </div>

            {/* Performers — comma-separated free-text. Surfaced on
                the event page above genres, in transfer + reminder
                emails, and CSV exports. Max 10 entries × 80 chars
                each. We don't dedupe by case — "Headliner" vs
                "headliner" stays distinct so an organizer can list
                the same artist twice for a back-to-back set if they
                want. */}
            <div className="md:col-span-2 space-y-2">
              <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Performers</label>
              <input
                type="text"
                placeholder={`e.g. Skrillex, Boys Noize, Boombox Cartel (max ${PERFORMERS_MAX_COUNT}, comma-separated)`}
                className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 px-6 text-slate-900 font-bold focus:outline-none focus:border-brand-primary focus:bg-white transition-all shadow-inner"
                value={formData.performers.join(', ')}
                onChange={(e) => {
                  const val = e.target.value
                    .split(',')
                    .map((s) => s.trim().slice(0, PERFORMER_MAX_LEN))
                    .filter(Boolean)
                    .slice(0, PERFORMERS_MAX_COUNT);
                  setFormData({ ...formData, performers: val });
                }}
              />
              <p className="text-[9px] text-slate-300 font-bold uppercase tracking-widest leading-relaxed">
                Order matters — first name is treated as the headliner in emails and the event page.
              </p>
            </div>

            <div className="space-y-2">
              <label htmlFor="event-price" className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Admission Price (USD)</label>
              <div className="relative">
                <DollarSign className="absolute left-6 top-1/2 -translate-y-1/2 text-slate-400 w-4 h-4" aria-hidden="true" />
                <input
                  id="event-price"
                  required
                  type="number"
                  min="0"
                  step="0.01"
                  className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 pl-14 pr-6 text-slate-900 font-bold focus:outline-none focus:border-brand-primary focus:bg-white transition-all shadow-inner"
                  value={formData.price}
                  onChange={(e) => setFormData({ ...formData, price: e.target.value })}
                />
              </div>
            </div>

            <div className="space-y-2">
              <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Doors Open</label>
              <div className="relative">
                <CalendarIcon
                  className="absolute left-6 top-1/2 -translate-y-1/2 text-slate-400 w-4 h-4 pointer-events-none"
                  aria-hidden="true"
                />
                <input
                  type="datetime-local"
                  className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 pl-14 pr-6 text-slate-900 font-bold focus:outline-none focus:border-brand-primary focus:bg-white transition-all shadow-inner cursor-pointer"
                  value={formData.timing.doorsOpen}
                  onClick={(e) => {
                    // showPicker() opens the native calendar+time
                    // popover. Without this, clicking the input on
                    // some browsers focuses for typing only — the
                    // picker is reachable only via the small icon at
                    // the right edge, which our overlay icon hides.
                    const el = e.currentTarget as HTMLInputElement;
                    if (typeof el.showPicker === 'function') {
                      try { el.showPicker(); } catch { /* user-gesture errors are non-fatal */ }
                    }
                  }}
                  onChange={(e) => setFormData({ ...formData, timing: { ...formData.timing, doorsOpen: e.target.value } })}
                />
              </div>
            </div>

            <div className="space-y-2">
              <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Show Start</label>
              <div className="relative">
                <CalendarIcon
                  className="absolute left-6 top-1/2 -translate-y-1/2 text-slate-400 w-4 h-4 pointer-events-none"
                  aria-hidden="true"
                />
                <input
                  required
                  type="datetime-local"
                  className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 pl-14 pr-6 text-slate-900 font-bold focus:outline-none focus:border-brand-primary focus:bg-white transition-all shadow-inner cursor-pointer"
                  value={formData.timing.startTime || formData.date}
                  onClick={(e) => {
                    const el = e.currentTarget as HTMLInputElement;
                    if (typeof el.showPicker === 'function') {
                      try { el.showPicker(); } catch { /* */ }
                    }
                  }}
                  onChange={(e) => setFormData({ ...formData, date: e.target.value, timing: { ...formData.timing, startTime: e.target.value } })}
                />
              </div>
            </div>

            <div className="space-y-2">
              <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Show End</label>
              <div className="relative">
                <CalendarIcon
                  className="absolute left-6 top-1/2 -translate-y-1/2 text-slate-400 w-4 h-4 pointer-events-none"
                  aria-hidden="true"
                />
                <input
                  type="datetime-local"
                  className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 pl-14 pr-6 text-slate-900 font-bold focus:outline-none focus:border-brand-primary focus:bg-white transition-all shadow-inner cursor-pointer"
                  value={formData.timing.endTime}
                  onClick={(e) => {
                    const el = e.currentTarget as HTMLInputElement;
                    if (typeof el.showPicker === 'function') {
                      try { el.showPicker(); } catch { /* */ }
                    }
                  }}
                  onChange={(e) => setFormData({ ...formData, timing: { ...formData.timing, endTime: e.target.value } })}
                />
              </div>
            </div>

            <div className="md:col-span-2 space-y-2">
              <label htmlFor="event-timezone" className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Event Timezone</label>
              <p className="text-[9px] text-slate-300 font-medium uppercase tracking-widest leading-relaxed">
                All event times above are interpreted in this zone, no matter where the viewer is.
              </p>
              <select
                id="event-timezone"
                className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 px-6 text-slate-900 font-bold focus:outline-none focus:border-brand-primary focus:bg-white transition-all appearance-none"
                value={formData.timezone}
                onChange={(e) => setFormData({ ...formData, timezone: e.target.value })}
              >
                {COMMON_TIMEZONES.some((t) => t.value === formData.timezone) ? null : (
                  <option value={formData.timezone}>{formData.timezone}</option>
                )}
                {COMMON_TIMEZONES.map((tz) => (
                  <option key={tz.value} value={tz.value}>
                    {tz.label}
                  </option>
                ))}
              </select>
            </div>

            <div className="space-y-2">
              <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Inventory Depth</label>
              <div className="relative">
                <ListOrdered className="absolute left-6 top-1/2 -translate-y-1/2 text-slate-400 w-4 h-4" />
                <input
                  required
                  type="number"
                  min="1"
                  className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 pl-14 pr-6 text-slate-900 font-bold focus:outline-none focus:border-brand-primary focus:bg-white transition-all shadow-inner"
                  value={formData.totalTickets}
                  onChange={(e) => setFormData({ ...formData, totalTickets: e.target.value })}
                />
              </div>
            </div>

            <div className="md:col-span-2 space-y-2">
              <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Venue</label>
              <div className="relative">
                <MapPin className="absolute left-6 top-1/2 -translate-y-1/2 text-slate-400 w-4 h-4" aria-hidden="true" />
                <input
                  required
                  type="text"
                  maxLength={LOCATION_MAX}
                  placeholder="e.g. Brooklyn Steel"
                  className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 pl-14 pr-6 text-slate-900 font-bold focus:outline-none focus:border-brand-primary focus:bg-white transition-all shadow-inner"
                  value={formData.location}
                  onChange={(e) => setFormData({ ...formData, location: e.target.value })}
                />
              </div>
              {/* Optional structured address. Persists to event.address
                  when any field has content; otherwise the form skips
                  writing the object so legacy events stay clean.
                  Used for calendar invites, map embeds, and tax
                  jurisdictions when the payments team wires those up. */}
              <details className="mt-3">
                <summary className="text-[9px] font-bold text-slate-400 uppercase tracking-widest cursor-pointer hover:text-slate-700">
                  Add address details (optional — for maps & receipts)
                </summary>
                <div className="grid grid-cols-1 md:grid-cols-6 gap-3 mt-3">
                  <input
                    type="text"
                    placeholder="Street"
                    aria-label="Street"
                    maxLength={120}
                    className="md:col-span-6 bg-white border border-slate-200 rounded-xl py-3 px-4 text-slate-900 text-sm font-medium focus:outline-none focus:border-brand-primary"
                    value={formData.address.street}
                    onChange={(e) => setFormData({ ...formData, address: { ...formData.address, street: e.target.value } })}
                  />
                  <input
                    type="text"
                    placeholder="City"
                    aria-label="City"
                    maxLength={80}
                    className="md:col-span-3 bg-white border border-slate-200 rounded-xl py-3 px-4 text-slate-900 text-sm font-medium focus:outline-none focus:border-brand-primary"
                    value={formData.address.city}
                    onChange={(e) => setFormData({ ...formData, address: { ...formData.address, city: e.target.value } })}
                  />
                  <input
                    type="text"
                    placeholder="State / Region"
                    aria-label="State or region"
                    maxLength={80}
                    className="md:col-span-2 bg-white border border-slate-200 rounded-xl py-3 px-4 text-slate-900 text-sm font-medium focus:outline-none focus:border-brand-primary"
                    value={formData.address.region}
                    onChange={(e) => setFormData({ ...formData, address: { ...formData.address, region: e.target.value } })}
                  />
                  <input
                    type="text"
                    placeholder="Postal"
                    aria-label="Postal code"
                    maxLength={20}
                    className="md:col-span-1 bg-white border border-slate-200 rounded-xl py-3 px-4 text-slate-900 text-sm font-medium focus:outline-none focus:border-brand-primary"
                    value={formData.address.postal}
                    onChange={(e) => setFormData({ ...formData, address: { ...formData.address, postal: e.target.value } })}
                  />
                  <input
                    type="text"
                    placeholder="Country"
                    aria-label="Country"
                    maxLength={80}
                    className="md:col-span-6 bg-white border border-slate-200 rounded-xl py-3 px-4 text-slate-900 text-sm font-medium focus:outline-none focus:border-brand-primary"
                    value={formData.address.country}
                    onChange={(e) => setFormData({ ...formData, address: { ...formData.address, country: e.target.value } })}
                  />
                </div>
              </details>
            </div>

            <div className="md:col-span-2 space-y-2">
              <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Event Artwork</label>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div className="relative border-2 border-dashed border-slate-200 rounded-2xl p-8 flex flex-col items-center justify-center bg-slate-50 hover:bg-slate-100 transition-all cursor-pointer group">
                  <input
                    type="file"
                    accept="image/*"
                    aria-label="Upload event artwork"
                    disabled={uploadingImage}
                    className="absolute inset-0 opacity-0 cursor-pointer disabled:cursor-wait"
                    onChange={handleImageUpload}
                  />
                  {uploadingImage ? (
                    <Loader2 className="w-8 h-8 text-brand-primary mb-2 animate-spin" aria-hidden="true" />
                  ) : (
                    <Upload className="w-8 h-8 text-slate-400 mb-2 group-hover:text-brand-primary" aria-hidden="true" />
                  )}
                  <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">
                    {uploadingImage ? 'Uploading…' : 'Upload Custom Art'}
                  </p>
                </div>
                {formData.image ? (
                  <div className="w-full h-32 rounded-2xl overflow-hidden border border-slate-200">
                    <img src={formData.image} alt="Event artwork preview" className="w-full h-full object-cover" />
                  </div>
                ) : (
                  <div className="w-full h-32 rounded-2xl bg-white border border-slate-100 flex items-center justify-center text-[10px] font-bold text-slate-300 uppercase tracking-widest">
                    Artwork Preview
                  </div>
                )}
              </div>
              {/*
                The "Or provide image URL" alternative input that used to
                live here is gone. With Storage uploads as the canonical
                path, accepting an arbitrary string in the same `image`
                field opened two foot-guns: (1) any non-validated URL got
                set as the event banner, including non-http(s) schemes,
                and (2) typing a URL after uploading a file silently
                stomped the uploaded URL with no UI feedback.
              */}
            </div>

            <div className="md:col-span-2 space-y-2">
              <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Core Narrative</label>
              <textarea
                required
                rows={5}
                maxLength={DESCRIPTION_MAX}
                placeholder="Describe the experience atmosphere..."
                className="w-full bg-slate-50 border-2 border-transparent rounded-3xl py-4 px-6 text-slate-900 font-medium focus:outline-none focus:border-brand-primary focus:bg-white transition-all resize-none shadow-inner"
                value={formData.description}
                onChange={(e) => setFormData({ ...formData, description: e.target.value })}
              />
              <p className="text-[9px] text-slate-300 font-bold uppercase tracking-widest ml-1">
                {formData.description.length} / {DESCRIPTION_MAX}
              </p>
            </div>
          </div>
        </div>

        {/* Ticket Tiers Section */}
        <div className="bg-white p-10 rounded-[2.5rem] border border-slate-100 shadow-sm space-y-8">
           <div className="flex items-center justify-between mb-2">
              <h3 className="text-sm font-bold text-slate-900 uppercase tracking-[0.2em]">Inventory Tiers</h3>
              <button 
                type="button" 
                onClick={addTier}
                className="text-[10px] font-bold text-brand-primary uppercase tracking-widest hover:opacity-80 transition-opacity"
              >
                + Add Tier
              </button>
           </div>
           
           <div className="space-y-6">
              {ticketTiers.map((tier, index) => (
                <div key={tier.id} className="p-6 bg-slate-50 rounded-3xl border border-slate-100 relative group/tier">
                   {ticketTiers.length > 1 && (
                     <button 
                       type="button"
                       onClick={() => removeTier(tier.id)}
                       className="absolute top-4 right-4 text-slate-300 hover:text-red-500 transition-colors"
                     >
                       <Tag className="w-4 h-4 rotate-45" />
                     </button>
                   )}
                   <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                      <div className="space-y-2 col-span-2">
                         <label className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">Tier Designation</label>
                         <input 
                           required 
                           type="text"
                           placeholder="e.g. VIP Backstage"
                           className="w-full bg-white border-2 border-transparent rounded-xl py-3 px-5 text-slate-900 font-bold focus:outline-none focus:border-brand-primary transition-all"
                           value={tier.name}
                           onChange={(e) => updateTier(tier.id, 'name', e.target.value)}
                         />
                      </div>
                      <div className="space-y-2">
                         <label className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">Price (USD)</label>
                         <input 
                           required 
                           type="number"
                           min="0"
                           step="0.01"
                           className="w-full bg-white border-2 border-transparent rounded-xl py-3 px-5 text-slate-900 font-bold focus:outline-none focus:border-brand-primary transition-all"
                           value={tier.price}
                           onChange={(e) => updateTier(tier.id, 'price', e.target.value)}
                         />
                      </div>
                      <div className="space-y-2">
                         <label className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">Quantity Available</label>
                         <input 
                           required 
                           type="number"
                           min="1"
                           className="w-full bg-white border-2 border-transparent rounded-xl py-3 px-5 text-slate-900 font-bold focus:outline-none focus:border-brand-primary transition-all"
                           value={tier.capacity}
                           onChange={(e) => updateTier(tier.id, 'capacity', e.target.value)}
                         />
                      </div>
                      <div className="space-y-2 col-span-2">
                         <label className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">Tier Benefits</label>
                         <input
                           required
                           type="text"
                           placeholder="What is included?"
                           className="w-full bg-white border-2 border-transparent rounded-xl py-3 px-5 text-slate-900 font-medium focus:outline-none focus:border-brand-primary transition-all"
                           value={tier.description}
                           onChange={(e) => updateTier(tier.id, 'description', e.target.value)}
                         />
                      </div>

                      {/* Advanced controls — drives sale-window
                          enforcement at the rule layer (tierSales doc),
                          hidden-tier visibility (only revealed when an
                          unlocking promo code is applied), and the
                          paid/free/donation type the payments team will
                          branch on. Defaults are public + paid + no
                          window, so a tier the organizer never opens
                          this section for behaves like before. */}
                      <details className="col-span-2 mt-2">
                        <summary className="text-[9px] font-bold text-slate-400 uppercase tracking-widest cursor-pointer hover:text-slate-700">
                          Advanced (sale window, visibility, type)
                        </summary>
                        <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4 pt-4 border-t border-slate-100">
                          <div className="space-y-2">
                            <label className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">Type</label>
                            <select
                              className="w-full bg-white border-2 border-transparent rounded-xl py-3 px-5 text-slate-900 font-bold focus:outline-none focus:border-brand-primary transition-all"
                              value={tier.ticketType}
                              onChange={(e) => updateTier(tier.id, 'ticketType', e.target.value)}
                            >
                              <option value="paid">Paid</option>
                              <option value="free">Free</option>
                              <option value="donation">Donation</option>
                            </select>
                          </div>
                          <div className="space-y-2">
                            <label className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">Visibility</label>
                            <select
                              className="w-full bg-white border-2 border-transparent rounded-xl py-3 px-5 text-slate-900 font-bold focus:outline-none focus:border-brand-primary transition-all"
                              value={tier.visibility}
                              onChange={(e) => updateTier(tier.id, 'visibility', e.target.value)}
                            >
                              <option value="public">Public</option>
                              <option value="hidden">Hidden — unlock by code</option>
                            </select>
                          </div>
                          <div className="space-y-2">
                            <label className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">Sales Open</label>
                            <input
                              type="datetime-local"
                              className="w-full bg-white border-2 border-transparent rounded-xl py-3 px-5 text-slate-900 font-bold focus:outline-none focus:border-brand-primary transition-all"
                              value={tier.salesStart}
                              onChange={(e) => updateTier(tier.id, 'salesStart', e.target.value)}
                            />
                          </div>
                          <div className="space-y-2">
                            <label className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">Sales Close</label>
                            <input
                              type="datetime-local"
                              className="w-full bg-white border-2 border-transparent rounded-xl py-3 px-5 text-slate-900 font-bold focus:outline-none focus:border-brand-primary transition-all"
                              value={tier.salesEnd}
                              onChange={(e) => updateTier(tier.id, 'salesEnd', e.target.value)}
                            />
                          </div>
                          <p className="md:col-span-2 text-[9px] text-slate-300 font-medium uppercase tracking-widest leading-relaxed">
                            Times above are interpreted in the event's
                            timezone ({formData.timezone}). Leaving a
                            field blank means no constraint on that side.
                          </p>
                        </div>
                      </details>
                   </div>
                </div>
              ))}
           </div>
        </div>

        {/* Promo Codes Section */}
        <div className="bg-white p-10 rounded-[2.5rem] border border-slate-100 shadow-sm space-y-8">
          <div className="flex items-center justify-between">
            <div>
              <h3 className="text-sm font-bold text-slate-900 uppercase tracking-[0.2em]">Promo Codes</h3>
              <p className="text-[9px] text-slate-300 font-medium uppercase tracking-widest mt-1">
                Optional. Buyers redeem at checkout.
              </p>
            </div>
            <button
              type="button"
              onClick={addPromoCode}
              className="text-[10px] font-bold text-brand-primary uppercase tracking-widest hover:opacity-80 transition-opacity flex items-center gap-2"
            >
              <Plus className="w-3 h-3" aria-hidden="true" /> Add Code
            </button>
          </div>

          {promoCodes.length === 0 ? (
            <p className="text-[10px] text-slate-300 font-medium uppercase tracking-widest">
              No promo codes defined.
            </p>
          ) : (
            <div className="space-y-4">
              {promoCodes.map((p) => (
                <div
                  key={p.id}
                  className="p-6 bg-slate-50 rounded-3xl border border-slate-100 grid grid-cols-1 md:grid-cols-12 gap-4 items-end"
                >
                  <div className="md:col-span-3 space-y-2">
                    <label className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">Code</label>
                    <input
                      required
                      type="text"
                      placeholder="EARLY30"
                      maxLength={32}
                      className="w-full bg-white border-2 border-transparent rounded-xl py-3 px-5 text-slate-900 font-bold uppercase focus:outline-none focus:border-brand-primary transition-all font-mono"
                      value={p.code}
                      onChange={(e) => updatePromoCode(p.id, 'code', e.target.value)}
                    />
                  </div>
                  <div className="md:col-span-3 space-y-2">
                    <label className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">Type</label>
                    <select
                      className="w-full bg-white border-2 border-transparent rounded-xl py-3 px-5 text-slate-900 font-bold focus:outline-none focus:border-brand-primary transition-all appearance-none"
                      value={p.type}
                      onChange={(e) => updatePromoCode(p.id, 'type', e.target.value)}
                    >
                      <option value="percentage">Percentage</option>
                      <option value="fixed">Fixed amount</option>
                    </select>
                  </div>
                  <div className="md:col-span-2 space-y-2">
                    <label className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">
                      Value {p.type === 'percentage' ? '(%)' : '($)'}
                    </label>
                    <input
                      required
                      type="number"
                      min="0"
                      step="0.01"
                      max={p.type === 'percentage' ? 100 : undefined}
                      className="w-full bg-white border-2 border-transparent rounded-xl py-3 px-5 text-slate-900 font-bold focus:outline-none focus:border-brand-primary transition-all"
                      value={p.value}
                      onChange={(e) => updatePromoCode(p.id, 'value', e.target.value)}
                    />
                  </div>
                  <div className="md:col-span-2 space-y-2">
                    <label className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">
                      Usage Limit
                    </label>
                    <input
                      type="number"
                      min="1"
                      placeholder="Unlimited"
                      className="w-full bg-white border-2 border-transparent rounded-xl py-3 px-5 text-slate-900 font-bold focus:outline-none focus:border-brand-primary transition-all"
                      value={p.usageLimit}
                      onChange={(e) => updatePromoCode(p.id, 'usageLimit', e.target.value)}
                    />
                  </div>
                  <div className="md:col-span-1 space-y-2">
                    <label className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">
                      Expires
                    </label>
                    <input
                      type="date"
                      className="w-full bg-white border-2 border-transparent rounded-xl py-3 px-3 text-slate-900 font-bold focus:outline-none focus:border-brand-primary transition-all text-xs"
                      value={p.expiresAt}
                      onChange={(e) => updatePromoCode(p.id, 'expiresAt', e.target.value)}
                    />
                  </div>
                  <div className="md:col-span-1 flex justify-end">
                    <button
                      type="button"
                      aria-label={`Remove promo code ${p.code || '(empty)'}`}
                      onClick={() => removePromoCode(p.id)}
                      className="text-slate-300 hover:text-red-500 transition-colors p-2"
                    >
                      <X className="w-4 h-4" aria-hidden="true" />
                    </button>
                  </div>

                  {/* Hidden-tier unlocks. Only renders when the
                      organizer has at least one hidden tier — otherwise
                      the section is silent (no clutter for the common
                      case). Each checkbox is a tier the code reveals
                      when applied at checkout. */}
                  {ticketTiers.some((t) => t.visibility === 'hidden') && (
                    <div className="md:col-span-12 mt-2 pt-3 border-t border-slate-100">
                      <p className="text-[9px] font-bold text-slate-400 uppercase tracking-widest mb-2">
                        Unlocks hidden tiers
                      </p>
                      <div className="flex flex-wrap gap-2">
                        {ticketTiers
                          .filter((t) => t.visibility === 'hidden')
                          .map((t) => {
                            const checked = p.unlocksTierIds.includes(t.id);
                            return (
                              <label
                                key={t.id}
                                className={`flex items-center gap-2 px-3 py-1 rounded-full border cursor-pointer text-[10px] font-bold uppercase tracking-widest ${
                                  checked
                                    ? 'bg-slate-900 text-white border-slate-900'
                                    : 'bg-white text-slate-600 border-slate-200 hover:border-slate-400'
                                }`}
                              >
                                <input
                                  type="checkbox"
                                  className="sr-only"
                                  checked={checked}
                                  onChange={() => togglePromoUnlock(p.id, t.id)}
                                />
                                {t.name || `(unnamed tier)`}
                              </label>
                            );
                          })}
                      </div>
                    </div>
                  )}
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Branding Section */}
        <div className="bg-white p-10 rounded-[2.5rem] border border-slate-100 shadow-sm space-y-8">
           <h3 className="text-sm font-bold text-slate-900 uppercase tracking-[0.2em] mb-2">Platform Customization</h3>
           <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
              <div className="space-y-2">
                 <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Primary Color</label>
                 <div className="flex items-center space-x-3">
                    <input 
                      type="color"
                      className="w-12 h-12 rounded-xl cursor-pointer border-none p-0 bg-transparent"
                      value={formData.branding.primaryColor}
                      onChange={(e) => setFormData({ ...formData, branding: { ...formData.branding, primaryColor: e.target.value } })}
                    />
                    <input 
                      type="text"
                      className="flex-grow bg-slate-50 border-2 border-transparent rounded-xl py-3 px-4 text-slate-900 font-mono text-xs focus:outline-none focus:border-brand-primary"
                      value={formData.branding.primaryColor}
                      onChange={(e) => setFormData({ ...formData, branding: { ...formData.branding, primaryColor: e.target.value } })}
                    />
                 </div>
              </div>
              <div className="space-y-2">
                 <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Accent Color</label>
                 <div className="flex items-center space-x-3">
                    <input 
                      type="color"
                      className="w-12 h-12 rounded-xl cursor-pointer border-none p-0 bg-transparent"
                      value={formData.branding.accentColor}
                      onChange={(e) => setFormData({ ...formData, branding: { ...formData.branding, accentColor: e.target.value } })}
                    />
                    <input 
                      type="text"
                      className="flex-grow bg-slate-50 border-2 border-transparent rounded-xl py-3 px-4 text-slate-900 font-mono text-xs focus:outline-none focus:border-brand-primary"
                      value={formData.branding.accentColor}
                      onChange={(e) => setFormData({ ...formData, branding: { ...formData.branding, accentColor: e.target.value } })}
                    />
                 </div>
              </div>
              <div className="md:col-span-2 space-y-2">
                 <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Custom Vanit Slug</label>
                 <div className="relative">
                    <span className="absolute left-6 top-1/2 -translate-y-1/2 text-slate-400 text-xs font-bold font-mono">vibepass.io/e/</span>
                    <input
                      type="text"
                      maxLength={SLUG_MAX}
                      placeholder="summer-horizon-2026"
                      className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 pl-32 pr-6 text-slate-900 font-bold focus:outline-none focus:border-brand-primary"
                      value={formData.branding.customSlug}
                      onChange={(e) =>
                        setFormData({
                          ...formData,
                          branding: {
                            ...formData.branding,
                            // Strip anything that's not a slug-safe character.
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
              </div>
           </div>
        </div>

        <div className="bg-white p-10 rounded-[2.5rem] border border-slate-100 shadow-sm space-y-8">
           <div className="flex items-center space-x-3 mb-2">
              <Globe className="text-brand-primary w-5 h-5" />
              <h3 className="text-sm font-bold text-slate-900 uppercase tracking-[0.2em]">Exclusivity Logic</h3>
           </div>
           
           <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div className="flex items-center justify-between p-6 bg-slate-50 rounded-2xl border border-transparent hover:border-indigo-100 transition-all">
                 <div>
                    <p className="text-[10px] font-bold text-slate-900 uppercase tracking-widest mb-1">Primary Market Only</p>
                    <p className="text-[9px] text-slate-400 font-medium">Bypass distribution networks</p>
                 </div>
                 <input 
                    type="checkbox" 
                    className="w-5 h-5 accent-indigo-500"
                    checked={formData.exclusivity.primaryMarketOnly}
                    onChange={(e) => setFormData({ 
                      ...formData, 
                      exclusivity: { ...formData.exclusivity, primaryMarketOnly: e.target.checked } 
                    })}
                 />
              </div>
              <div className="flex items-center justify-between p-6 bg-slate-50 rounded-2xl border border-transparent hover:border-indigo-100 transition-all">
                 <div>
                    <p className="text-[10px] font-bold text-slate-900 uppercase tracking-widest mb-1">Custom URL Only</p>
                    <p className="text-[9px] text-slate-400 font-medium">Private listing logic</p>
                 </div>
                 <input 
                    type="checkbox" 
                    className="w-5 h-5 accent-indigo-500"
                    checked={formData.exclusivity.customUrlOnly}
                    onChange={(e) => setFormData({ 
                      ...formData, 
                      exclusivity: { ...formData.exclusivity, customUrlOnly: e.target.checked } 
                    })}
                 />
              </div>
           </div>
        </div>

        {/* Distribution Networks */}
        <div className="bg-white p-10 rounded-[2.5rem] border border-slate-100 shadow-sm space-y-8">
           <div className="flex items-center space-x-3 mb-2">
              <ShieldCheck className="text-brand-primary w-5 h-5" />
              <h3 className="text-sm font-bold text-slate-900 uppercase tracking-[0.2em]">Purchase Controls</h3>
           </div>
           
           <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
              <div className="space-y-2">
                <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Max per transaction</label>
                <input 
                  type="number"
                  min="1"
                  className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 px-6 text-slate-900 font-bold focus:outline-none focus:border-brand-primary focus:bg-white transition-all shadow-inner"
                  value={formData.purchaseLimits.maxPerOrder}
                  onChange={(e) => setFormData({ ...formData, purchaseLimits: { ...formData.purchaseLimits, maxPerOrder: e.target.value } })}
                />
              </div>
              <div className="space-y-2">
                <label className="text-[10px] font-bold text-slate-400 uppercase tracking-widest ml-1">Max per user account</label>
                <input 
                  type="number"
                  min="1"
                  className="w-full bg-slate-50 border-2 border-transparent rounded-2xl py-4 px-6 text-slate-900 font-bold focus:outline-none focus:border-brand-primary focus:bg-white transition-all shadow-inner"
                  value={formData.purchaseLimits.maxPerAccount}
                  onChange={(e) => setFormData({ ...formData, purchaseLimits: { ...formData.purchaseLimits, maxPerAccount: e.target.value } })}
                />
              </div>
           </div>
        </div>

        {/* Distribution Networks */}
        <div className="bg-white p-10 rounded-[2.5rem] border border-slate-100 shadow-sm space-y-8">
           <div className="flex items-center space-x-3 mb-2">
              <Tag className="text-brand-primary w-5 h-5" />
              <h3 className="text-sm font-bold text-slate-900 uppercase tracking-[0.2em]">Distribution Hub</h3>
           </div>
           
           <p className="text-[10px] text-slate-400 font-bold uppercase tracking-widest leading-relaxed">Select global markets for synchronized inventory listing.</p>
           
           <div className="grid grid-cols-2 md:grid-cols-3 gap-4">
              {[
                { id: 'stubhub', name: 'StubHub' },
                { id: 'seatgeek', name: 'SeatGeek' },
                { id: 'ticketmaster', name: 'Ticketmaster' },
                { id: 'axs', name: 'AXS' },
                { id: 'vivid', name: 'Vivid Seats' },
                { id: 'gametime', name: 'Gametime' },
                { id: 'viagogo', name: 'Viagogo' },
                { id: 'ticketevolution', name: 'Ticket Evolution' },
                { id: 'tickpick', name: 'TickPick' },
                { id: 'gotickets', name: 'GoTickets' }
              ].map(network => (
                <label key={network.id} className="flex items-center space-x-3 p-4 bg-slate-50 rounded-2xl cursor-pointer hover:bg-slate-100 transition-colors border border-transparent has-[:checked]:border-brand-primary has-[:checked]:bg-indigo-50/30">
                   <input
                     type="checkbox"
                     className="w-4 h-4 accent-brand-primary"
                     // Bound to formData.distributionNetworks so the user's
                     // choice is actually persisted. Previously this was a
                     // defaultChecked={true} cosmetic that no code read.
                     checked={formData.distributionNetworks.includes(network.id)}
                     onChange={(e) => {
                       const current = formData.distributionNetworks;
                       const next = e.target.checked
                         ? Array.from(new Set([...current, network.id]))
                         : current.filter((n) => n !== network.id);
                       setFormData({ ...formData, distributionNetworks: next });
                     }}
                   />
                   <span className="text-[10px] font-bold uppercase tracking-widest text-slate-600">{network.name}</span>
                </label>
              ))}
           </div>
        </div>

        <div className="flex gap-4">
          <button
            type="button"
            onClick={async () => {
              const hasInput =
                formData.title.trim() ||
                formData.description.trim() ||
                formData.image ||
                ticketTiers.some((t) => t.price || t.capacity || t.description);
              if (
                hasInput &&
                !window.confirm(
                  'Discard this event? Your unsaved changes will be lost.\n\nTip: a draft is saved automatically — you can also click "Save Draft" to keep your work and finish later.',
                )
              ) {
                return;
              }
              // Best-effort orphan cleanup: if the user uploaded an
              // image during this session and is now discarding the
              // form, delete the Storage object so it doesn't sit
              // forever consuming quota.
              await cleanupOrphanedImage();
              clearDraft();
              navigate('/dashboard');
            }}
            className="flex-1 bg-white border-2 border-slate-100 text-slate-400 py-5 rounded-2xl font-bold uppercase tracking-widest text-xs hover:border-slate-200 transition-all font-mono"
          >
            Cancel Session
          </button>
          <button
            type="button"
            disabled={loading || uploadingImage}
            onClick={(e) => handleSubmit(e as unknown as FormEvent, false)}
            className="flex-1 bg-white border-2 border-slate-200 text-slate-700 py-5 rounded-2xl font-bold uppercase tracking-widest text-xs hover:border-slate-400 transition-all disabled:opacity-50"
          >
            {loading ? 'Saving…' : 'Save Draft'}
          </button>
          <button
            type="submit"
            disabled={loading || uploadingImage}
            className="flex-[2] bg-slate-900 text-white py-5 rounded-2xl font-bold uppercase tracking-widest text-xs hover:bg-slate-800 transition-all shadow-2xl shadow-slate-200 disabled:opacity-50"
          >
            {loading
              ? 'Publishing…'
              : uploadingImage
                ? 'Waiting for image upload…'
                : 'Publish Event'}
          </button>
        </div>
      </form>
    </div>
  );
}
