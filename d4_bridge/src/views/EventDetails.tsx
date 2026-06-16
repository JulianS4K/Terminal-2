import { useEffect, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { Event, Organization } from '../types';
import { getPublicEvent, getEventForEdit } from '../lib/events';
import { mintTickets, claimFreeTickets } from '../lib/tickets';
import { startCheckout } from '../lib/checkout';
import SocialLinks from '../components/SocialLinks';
import { shareEventToStory } from '../lib/poster';
import { useAuth } from '../context/AuthContext';
import { Calendar, MapPin, Ticket, ShieldCheck, Share2, ArrowLeft, CheckCircle2, Copy, Send, Instagram, Minus, Plus, Tag } from 'lucide-react';
import { formatCurrency, generateBarcodeContent, handleFirestoreError, OperationType, publicUrl } from '../lib/utils';
import { getStripe } from '../lib/stripe';
import { formatInTz } from '../lib/datetime';
import { motion } from 'motion/react';
import { useToast } from '../context/ToastContext';
import { applyMeta } from '../lib/meta';
import { getPublicOrg } from '../lib/orgs';
import { initOrgPixels, trackPixelEvent } from '../lib/pixels';
import ShareModal from '../components/ShareModal';
import EventCountdown from '../components/EventCountdown';
import WaitlistCTA from '../components/WaitlistCTA';
import AddonSelector, { type AddonSelection } from '../components/AddonSelector';
import { claimFreeAddons } from '../lib/addons';
import { useT } from '../context/LanguageContext';

export default function EventDetails() {
  const { id } = useParams();
  const t = useT();
  const { user, isAdmin, signIn } = useAuth();
  const navigate = useNavigate();
  const { toast } = useToast();
  const [event, setEvent] = useState<Event | null>(null);
  const [org, setOrg] = useState<Organization | null>(null);
  const [loading, setLoading] = useState(true);
  const [purchasing, setPurchasing] = useState(false);
  const [selectedTierId, setSelectedTierId] = useState<string | null>(null);
  const [discountCode, setDiscountCode] = useState('');
  const [appliedDiscount, setAppliedDiscount] = useState<{ type: 'percentage' | 'fixed', value: number } | null>(null);
  // The literal code that's currently applied — needed so we can pass it
  // through to the Stripe metadata and the post-purchase usage increment.
  const [appliedDiscountCode, setAppliedDiscountCode] = useState<string | null>(null);
  const [quantity, setQuantity] = useState(1);
  const [addonSel, setAddonSel] = useState<AddonSelection>({ items: [], totalCents: 0 });
  const [userTicketCount, setUserTicketCount] = useState(0);
  // Per-tier sold/capacity, sourced from the events/{id}/tierSales sub-
  // collection. Buyers can no longer mutate the embedded ticketTiers array
  // (the rule lockdown that closed the price-rewrite vulnerability) so the
  // embedded `sold` is no longer authoritative — these counts are.
  const [showShare, setShowShare] = useState(false);

  // Per-account ticket count gates max-per-account at checkout. Lands in
  // phase-2 with the exos_tickets table; stays 0 until then.
  useEffect(() => {
    setUserTicketCount(0);
  }, [user, id]);

  useEffect(() => {
    async function fetchEvent() {
      if (!id) { setLoading(false); return; }
      // Published events via the public view; fall back to the staff read so an
      // organizer can preview their own draft (RLS gates that to org staff).
      let data = await getPublicEvent(id);
      if (!data && user) data = await getEventForEdit(id);
      if (data) {
        setEvent(data);
        if (data.ticketTiers && data.ticketTiers.length > 0) {
          setSelectedTierId(data.ticketTiers[0].id);
        }
        // SEO: per-event meta tags (Open Graph, Twitter Card,
        // Schema.org Event). Crawlers that execute JS pick this up;
        // social-card previewers fall back to the index.html defaults.
        try {
          const startIso = data.date?.toDate ? data.date.toDate().toISOString() : undefined;
          const endIso = data.timing?.endTime?.toDate?.()?.toISOString();
          const remaining = Math.max(0, (data.totalTickets || 0) - (data.ticketsSold || 0));
          applyMeta({
            title: data.title,
            description: (data.description || '').slice(0, 200),
            imageUrl: data.image || undefined,
            canonicalUrl: publicUrl(`event/${data.id}`),
            event: startIso
              ? {
                  name: data.title,
                  startDate: startIso,
                  endDate: endIso,
                  location: {
                    name: data.location,
                    streetAddress: data.address?.street,
                    city: data.address?.city,
                    region: data.address?.region,
                    country: data.address?.country,
                    postal: data.address?.postal,
                  },
                  image: data.image,
                  description: (data.description || '').slice(0, 200),
                  offers: {
                    price: data.price,
                    currency: data.currency || 'USD',
                    availability: remaining > 0 ? 'InStock' : 'SoldOut',
                    url: publicUrl(`event/${data.id}`),
                  },
                }
              : undefined,
          });
        } catch (err) {
          // Meta-tag failures are non-fatal — they don't block render.
          console.warn('Meta apply failed:', err);
        }
        // Marketing: load the hosting org's pixels (consent-gated) and fire a
        // ViewContent for this event. The public event row carries only
        // orgId, so fetch the public org for its marketing config.
        if (data.orgId) {
          getPublicOrg(data.orgId)
            .then((o) => {
              setOrg(o ?? null);
              initOrgPixels(o?.marketing?.pixels);
              trackPixelEvent('ViewContent', { content_name: data.title, content_ids: [data.id] });
            })
            .catch(() => {/* non-fatal */});
        }
      }
      setLoading(false);
    }
    // A thrown fetch (network/Supabase error) must still clear the spinner so
    // the "Event not found" state renders instead of an infinite loader.
    fetchEvent().catch((err) => {
      console.warn('Event load failed:', err);
      setLoading(false);
    });
  }, [id, user]);

  // (Live per-tier sold/capacity subscription removed — phase-1 reads
  // sold/capacity off the mapped tiers; real-time counters return in phase-2
  // with the exos_tickets fulfillment path.)

  const applyDiscount = async () => {
    if (!event || !discountCode) return;
    const upper = discountCode.trim().toUpperCase();
    const codeObj = event.discountCodes?.find((c) => c.code === upper);
    if (!codeObj) {
      toast({ kind: 'error', message: 'Invalid discount code.' });
      setAppliedDiscount(null);
      setAppliedDiscountCode(null);
      return;
    }

    // Usage-limit / expiry enforcement lands in phase-2 (a validate-code RPC):
    // discount codes are org-secret, so buyer-side validation can't read the
    // counter directly. Phase-1 applies the code locally — checkout is gated.
    setAppliedDiscount({ type: codeObj.type, value: codeObj.value });
    setAppliedDiscountCode(upper);
    toast({
      kind: 'success',
      title: 'Discount applied',
      message: `${codeObj.value}${codeObj.type === 'percentage' ? '%' : '$'} off your purchase.`,
    });
  };

  // Tiers visible to the current viewer. A tier is visible if it's
  // public OR if the currently-applied promo code unlocks it (the code
  // carries an `unlocksTierIds` array). This is the buyer-side mirror
  // of the per-tier visibility model on the event doc — without it,
  // setting a tier to 'hidden' would have no effect because all tiers
  // would still be in the rendered list.
  const visibleTiers = (event?.ticketTiers || []).filter((t) => {
    const visibility = (t as { visibility?: string }).visibility ?? 'public';
    if (visibility === 'public') return true;
    if (!appliedDiscountCode) return false;
    const code = event?.discountCodes?.find((c) => c.code === appliedDiscountCode);
    return code?.unlocksTierIds?.includes(t.id) === true;
  });

  const selectedTier = visibleTiers.find((t) => t.id === selectedTierId);

  /** Returns null if the tier is currently on sale, otherwise an
   *  explanation string ("Sales open at..." / "Sales ended"). */
  const tierWindowStatus = (
    tier: NonNullable<typeof event>['ticketTiers'] extends (infer T)[] ? T : never,
  ): string | null => {
    const t = tier as {
      salesStart?: { toMillis: () => number } | null;
      salesEnd?: { toMillis: () => number } | null;
    };
    const now = Date.now();
    if (t.salesStart && t.salesStart.toMillis() > now) {
      return `Sales open at ${formatInTz(new Date(t.salesStart.toMillis()), event?.timezone, { dateStyle: 'medium', timeStyle: 'short' })}.`;
    }
    if (t.salesEnd && t.salesEnd.toMillis() < now) {
      return 'Sales for this tier have ended.';
    }
    return null;
  };
  
  const calculateFinalPrice = () => {
    if (!event) return 0;
    let basePrice = selectedTier ? selectedTier.price : event.price;
    
    if (appliedDiscount) {
      if (appliedDiscount.type === 'percentage') {
        basePrice = basePrice * (1 - appliedDiscount.value / 100);
      } else {
        basePrice = Math.max(0, basePrice - appliedDiscount.value);
      }
    }
    return basePrice;
  };

  const priceToDisplay = calculateFinalPrice();

  const maxPerOrder = event?.purchaseLimits?.maxPerOrder || 8;
  const maxPerAccount = event?.purchaseLimits?.maxPerAccount || 8;
  // Paid checkout is gated on the Stripe publishable key — the backend
  // (exos-checkout + exos_fulfill_checkout) is built but stays dormant until
  // payments are switched on. No key → paid tiers show "Coming soon".
  const stripeEnabled = !!(import.meta as { env?: { VITE_STRIPE_PUBLISHABLE_KEY?: string } }).env?.VITE_STRIPE_PUBLISHABLE_KEY;

  const handlePurchase = async () => {
    if (!user) {
      toast({ kind: 'info', message: 'Sign in to grab your ticket.' });
      await signIn();
      return;
    }
    if (!event) return;
    const tier = event.ticketTiers?.find((t) => t.id === selectedTierId) || event.ticketTiers?.[0];
    if (!tier?.id) {
      toast({ kind: 'error', message: 'No ticket tier available for this event yet.' });
      return;
    }
    const unitPrice = tier.price ?? event.price ?? 0;
    // Grand total = tickets + selected add-ons. A free tier with PAID add-ons
    // still routes through checkout; only a $0 grand total takes the free path.
    const grandTotalCents = Math.round(unitPrice * quantity * 100) + addonSel.totalCents;

    if (grandTotalCents > 0) {
      if (!stripeEnabled) {
        toast({ kind: 'info', title: t('event.comingSoonTitle'), message: t('event.comingSoon') });
        return;
      }
      setPurchasing(true);
      try {
        const url = await startCheckout({
          eventId: event.id,
          tierId: tier.id,
          quantity,
          successUrl: publicUrl('my-tickets?checkout=success'),
          cancelUrl: publicUrl(`event/${event.id}`),
          addons: addonSel.items,
        });
        window.location.href = url; // leave the SPA for Stripe-hosted checkout
      } catch (err: any) {
        console.error('Checkout failed:', err);
        toast({ kind: 'error', message: err?.message || 'Could not start checkout.' });
        setPurchasing(false);
      }
      return;
    }

    // Free claim — mint to the buyer, capturing campaign attribution off the URL
    // (?promoter / ?utm_source) so it lands in the event's Sales report.
    setPurchasing(true);
    try {
      const params = new URLSearchParams(window.location.search);
      // Shared idempotency/order ref so any free $0 extras attach to this claim.
      const orderRef = crypto.randomUUID();
      const ids = await claimFreeTickets({
        eventId: event.id,
        tierId: tier.id,
        quantity,
        promoterId: params.get('promoter'),
        channel: params.get('utm_source'),
        // Idempotency key for this claim attempt — a network retry returns the
        // same tickets instead of minting twice (button is disabled meanwhile).
        orderRef,
      });
      // Attach any free extras (best-effort — a swag hiccup shouldn't fail the
      // ticket claim the buyer already completed).
      if (addonSel.items.length > 0) {
        try {
          await claimFreeAddons(event.id, orderRef, addonSel.items);
        } catch (addErr) {
          console.error('claimFreeAddons failed:', addErr);
        }
      }
      trackPixelEvent('Purchase', {
        content_name: event.title,
        content_ids: [event.id],
        value: 0,
        currency: event.currency || 'USD',
        num_items: ids.length,
      });
      toast({ kind: 'success', title: "You're in!", message: `${ids.length} ticket(s) reserved — find them in My Tickets.` });
      navigate('/my-tickets');
    } catch (err: any) {
      console.error('Free claim failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not reserve tickets. Please try again.' });
    } finally {
      setPurchasing(false);
    }
  };

  const handleShare = async () => {
    const shareData = {
      title: event?.title,
      text: `Join me at ${event?.title}!`,
      url: window.location.href,
    };

    try {
      if (navigator.share) {
        await navigator.share(shareData);
      } else {
        await navigator.clipboard.writeText(window.location.href);
        toast({ kind: 'success', message: 'Link copied to clipboard.' });
      }
    } catch (err) {
      console.error('Error sharing:', err);
    }
  };

  /**
   * TEST-MODE BYPASS — admin only.
   *
   * Mints a ticket directly without going through Stripe checkout.
   * Used for end-to-end validation of the QR / check-in flow without
   * needing a real payment processor wired up. The ticket is written
   * with a `bypass_test_<random>` stripeSessionId so admin tooling can
   * later filter and purge test tickets.
   *
   * Mirrors the writes that MyTickets fulfillment does on real
   * Stripe-success (ticket doc + tierSales increment + event
   * ticketsSold increment), so the resulting ticket behaves
   * identically to a real one — same rotating HMAC barcode, same
   * check-in flow, same audit-log path.
   *
   * The "TEST" label on the button is intentionally loud so this
   * never gets confused with a real purchase. We also gate visibility
   * on `isAdmin` so regular users don't see it.
   */
  const handleTestBuy = async () => {
    if (!user || !event) return;
    if (!isAdmin) {
      toast({ kind: 'error', message: 'Test mint is admin-only.' });
      return;
    }
    // Comp / test-mint via the SECDEF exos_mint_tickets RPC (org-staff or
    // admin). Mints real exos_tickets rows — same rotating-barcode + check-in
    // path as a paid ticket — so the end-to-end flow (wallet → door scan →
    // transfer) is exercisable without Stripe checkout (which stays phase-2).
    setPurchasing(true);
    try {
      const tier = event.ticketTiers?.find((t) => t.id === selectedTierId) || event.ticketTiers?.[0];
      const ids = await mintTickets({
        eventId: event.id,
        tierId: tier?.id ?? null,
        quantity,
        orderRef: `comp_${crypto.randomUUID()}`,
        pricePaid: 0,
      });
      toast({ kind: 'success', message: `Minted ${ids.length} test ticket(s).` });
      navigate('/my-tickets');
    } catch (err: any) {
      console.error('Test mint failed:', err);
      toast({ kind: 'error', message: err?.message || 'Test mint failed.' });
    } finally {
      setPurchasing(false);
    }
  };

  const handleInstagramStory = async () => {
    if (!event) return;
    // Share the event POSTER image to the OS share sheet (→ Instagram Story),
    // with the URL copied for the link sticker. Shared impl in lib/poster.ts.
    await shareEventToStory(
      { title: event.title, url: publicUrl(`event/${event.id}`), imageUrl: event.image },
      toast,
    );
  };

  const handleSMSShare = () => {
    const text = `Join me at ${event?.title}! Access intel here: ${window.location.href}`;
    window.location.href = `sms:?&body=${encodeURIComponent(text)}`;
  };

  if (loading) return <div className="max-w-7xl mx-auto p-24 text-center text-slate-300 font-bold uppercase tracking-[0.3em] animate-pulse">Loading Experience Details...</div>;
  if (!event) return <div className="max-w-7xl mx-auto p-20 text-center font-bold text-slate-300 uppercase tracking-widest text-xs">Event not found.</div>;

  // Helper: live sold/capacity for a given tier from the sub-collection,
  // falling back to the embedded values if the sub-collection hasn't loaded
  // yet (first paint) or the tier predates the sub-collection migration.
  const liveTier = (tierId: string, fallbackCap?: number) => {
    const t = event?.ticketTiers?.find((x) => x.id === tierId);
    return {
      sold: t?.sold ?? 0,
      capacity: t?.capacity ?? fallbackCap ?? 0,
    };
  };

  // Lifecycle gate. Drafts are only renderable to the organizer; if a
  // non-organizer somehow lands here (e.g. they bookmarked a draft URL,
  // or the rule loosens later), show a friendly "not available" instead
  // of half-rendering the page. Cancelled events stay viewable so old
  // ticket-holders can find context.
  const eventStatus = event.status ?? 'published';
  const isOrganizer = !!user && user.uid === event.organizerId;
  // Draft visibility is enforced server-side: getPublicEvent returns
  // published-only and getEventForEdit is RLS-gated to org staff, so a draft in
  // state means the viewer is authorized — no extra client gate needed.

  const soldOut = selectedTier
    ? (() => {
        const t = liveTier(selectedTier.id, selectedTier.capacity);
        return t.sold >= t.capacity;
      })()
    : event.ticketsSold >= event.totalTickets;

  const primaryStyle = event.branding?.primaryColor ? { backgroundColor: event.branding.primaryColor } : {};
  const accentStyle = event.branding?.accentColor ? { color: event.branding.accentColor } : {};
  const accentBgStyle = event.branding?.accentColor ? { backgroundColor: event.branding.accentColor } : {};
  const accentBorderStyle = event.branding?.accentColor ? { borderColor: event.branding.accentColor } : {};

  return (
    <div className="bg-[#000000] min-h-screen text-white">
      <div className="max-w-7xl mx-auto px-4 py-8">
        <button onClick={() => navigate(-1)} className="flex items-center text-white/50 hover:text-white mb-12 transition-colors font-black uppercase tracking-tighter italic text-xs">
          <ArrowLeft className="w-4 h-4 mr-2 text-brand-primary" />
          Back to Events
        </button>

        {eventStatus === 'cancelled' && (
          <div className="mb-8 p-5 rounded-2xl border border-red-400/40 bg-red-500/10">
            <p className="text-xs font-black uppercase tracking-widest text-red-300 mb-2">
              This event has been cancelled
            </p>
            {event.cancelReason && (
              <p className="text-sm text-red-100/80 mb-2">
                <span className="font-black uppercase tracking-widest text-red-300/60 text-[10px]">Reason: </span>
                {event.cancelReason}
              </p>
            )}
            <p className="text-xs text-red-100/60">
              If you bought directly through this site, your refund will be issued
              automatically within 5 business days. If you bought via a partner site
              (StubHub, Vivid Seats, etc.) please contact that channel for refund
              processing.
            </p>
          </div>
        )}

        {eventStatus === 'draft' && isOrganizer && (
          <div className="mb-8 p-4 rounded-2xl border border-amber-300/30 bg-amber-300/10 flex items-center justify-between">
            <p className="text-[10px] font-black uppercase tracking-widest text-amber-200">
              DRAFT — only you can see this. Publish from the Edit screen to list it.
            </p>
            <Link
              to={`/edit-event/${event.id}`}
              className="text-[10px] font-black uppercase tracking-widest text-amber-200 hover:text-white"
            >
              Edit →
            </Link>
          </div>
        )}
        {eventStatus === 'cancelled' && (
          <div className="mb-8 p-4 rounded-2xl border border-red-300/40 bg-red-300/10">
            <p className="text-[10px] font-black uppercase tracking-widest text-red-200">
              CANCELLED — sales are closed.
            </p>
          </div>
        )}

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-16">
          {/* Left Column: Image and Description */}
          <div className="lg:col-span-2">
            <div className="aspect-video relative mb-12 border border-white/10 group overflow-hidden">
              <img 
                src={event.image || 'https://images.unsplash.com/photo-1492684223066-81342ee5ff30?q=80&w=1200'} 
                alt={event.title}
                className="w-full h-full object-cover grayscale group-hover:grayscale-0 transition-all duration-700"
              />
              <div className="absolute inset-0 bg-gradient-to-t from-black via-transparent to-transparent opacity-80"></div>
              <div className="absolute bottom-8 left-8 right-8">
                <span className="bg-brand-primary text-black px-3 py-1 text-[10px] font-black uppercase tracking-tighter italic mb-4 inline-block">
                  {event.category}
                </span>
                <h1 className="text-5xl md:text-7xl font-black uppercase italic tracking-tighter leading-none">{event.title}</h1>
              </div>
            </div>
            
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-px bg-white/10 border border-white/10 mb-16">
              <div className="flex items-center p-8 bg-[#111111]">
                <div className="w-12 h-12 bg-white/5 flex items-center justify-center mr-6">
                   <Calendar className="text-brand-primary w-6 h-6" />
                </div>
                <div>
                   <p className="text-[10px] text-white/30 font-black uppercase tracking-tighter mb-1">Date & Time</p>
                   <p className="font-black text-xl uppercase tracking-tighter italic">{formatInTz(event.date.toDate(), event.timezone, { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })}</p>
                   {event.date && eventStatus !== 'cancelled' && (
                     <p className="text-[10px] text-brand-primary font-black uppercase tracking-widest mt-1">
                       <EventCountdown
                         startsAt={event.date.toDate()}
                         doorsOpen={
                           event.timing?.doorsOpen
                             ? typeof event.timing.doorsOpen === 'string'
                               ? new Date(event.timing.doorsOpen)
                               : (event.timing.doorsOpen as any).toDate?.() ?? null
                             : null
                         }
                       />
                     </p>
                   )}
                   {event.timing && (
                     <div className="flex gap-3 mt-1 text-[10px] text-white/40 font-black uppercase tracking-widest italic">
                        {event.timing.doorsOpen && (
                          <span>
                            DOORS {formatInTz(
                              typeof event.timing.doorsOpen === 'string'
                                ? new Date(event.timing.doorsOpen)
                                : (event.timing.doorsOpen as any).toDate(),
                              event.timezone,
                              { hour: 'numeric', minute: '2-digit' },
                            )}
                          </span>
                        )}
                        {event.timing.startTime && (
                          <span className="text-brand-primary">
                            START {formatInTz(
                              typeof event.timing.startTime === 'string'
                                ? new Date(event.timing.startTime)
                                : (event.timing.startTime as any).toDate(),
                              event.timezone,
                              { hour: 'numeric', minute: '2-digit' },
                            )}
                          </span>
                        )}
                        {event.timezone && (
                          <span className="text-white/30">// {event.timezone}</span>
                        )}
                     </div>
                   )}
                </div>
              </div>
              <div className="flex items-center p-8 bg-[#111111]">
                <div className="w-12 h-12 bg-white/5 flex items-center justify-center mr-6">
                   <MapPin className="text-brand-primary w-6 h-6" />
                </div>
                <div>
                   <p className="text-[10px] text-white/30 font-black uppercase tracking-tighter mb-1">Location</p>
                   <p className="font-black text-xl uppercase tracking-tighter italic">{event.location}</p>
                </div>
              </div>
              {/* Performers block — only renders when the organizer
                  has set at least one. First name is treated as the
                  headliner (slightly larger). The block sits above
                  genres because at a music event, performer names
                  are usually what the buyer cares about most. */}
              {event.performers && event.performers.length > 0 ? (
                <div className="p-8 bg-[#111111] sm:col-span-2">
                  <p className="text-[10px] text-white/30 font-black uppercase tracking-tighter mb-3">Performers</p>
                  <div className="flex flex-wrap items-baseline gap-x-4 gap-y-2">
                    <p className="font-black text-3xl uppercase tracking-tighter italic text-white">
                      {event.performers[0]}
                    </p>
                    {event.performers.slice(1).map((name) => (
                      <p
                        key={name}
                        className="font-black text-lg uppercase tracking-tighter italic text-white/60"
                      >
                        {name}
                      </p>
                    ))}
                  </div>
                </div>
              ) : null}
              <div className="flex items-center p-8 bg-[#111111] sm:col-span-2">
                <div className="w-12 h-12 bg-white/5 flex items-center justify-center mr-6">
                   <Tag className="text-brand-primary w-6 h-6" />
                </div>
                <div>
                   <p className="text-[10px] text-white/30 font-black uppercase tracking-tighter mb-1">Genres</p>
                   <p className="font-black text-xl uppercase tracking-tighter italic">
                      {event.genres?.join(', ') || event.category}
                      {event.subgenres && event.subgenres.length > 0 && <span className="text-white/40 ml-2">({event.subgenres.join(', ')})</span>}
                   </p>
                </div>
              </div>
            </div>

            <div className="mb-16">
              <h2 className="text-2xl font-black uppercase italic tracking-tighter mb-8 border-l-4 border-brand-primary pl-4">ABOUT THE EVENT</h2>
              <p className="text-white/60 text-xl leading-relaxed italic font-medium whitespace-pre-wrap">{event.description}</p>
            </div>
            
            <div className="mb-16 bg-[#111111] border border-white/10 p-8 flex items-center justify-between group">
               <div className="flex items-center space-x-6">
                  <div className="w-16 h-16 bg-brand-primary flex items-center justify-center text-2xl font-black text-black italic">
                    {(org?.name || 'O').charAt(0).toUpperCase()}
                  </div>
                  <div>
                    <p className="text-[10px] text-white/40 font-black uppercase tracking-widest mb-1">Presented By</p>
                    <h3 className="text-2xl font-black italic uppercase tracking-tighter">{org?.name || 'Event Organizer'}</h3>
                    {org?.marketing?.socials && Object.values(org.marketing.socials).some(Boolean) ? (
                      <SocialLinks socials={org.marketing.socials} className="flex items-center gap-3 mt-2" />
                    ) : null}
                  </div>
               </div>
               <Link to={`/organizer/${event.orgId ?? ''}`} className="px-6 py-3 bg-white/5 border border-white/10 text-xs font-black uppercase tracking-widest group-hover:bg-brand-primary group-hover:text-black transition-all">
                  View Profile
               </Link>
            </div>
          </div>

          {/* Right Column: Checkout Card */}
          <div className="lg:col-span-1">
            <div className="sticky top-28 bg-[#111111] border border-white/10 shadow-2xl overflow-hidden">
              <div className="p-8">
                <div className="mb-8">
                    <p className="text-[10px] text-white/30 font-black uppercase tracking-tighter mb-2">Price</p>
                    <p className="text-6xl font-black text-brand-primary tracking-tighter italic">{formatCurrency(priceToDisplay * quantity, event.currency)}</p>
                </div>

                <div className="mb-10">
                   <p className="text-[10px] text-white/30 font-black uppercase tracking-tighter mb-4">Quantity</p>
                   <div className="flex items-center space-x-6 bg-black p-4 border border-white/5">
                      <button 
                        onClick={() => setQuantity(Math.max(1, quantity - 1))}
                        className="w-10 h-10 bg-white/5 flex items-center justify-center hover:bg-white/10 transition-colors"
                      >
                        <Minus className="w-4 h-4 text-white" />
                      </button>
                      <span className="text-2xl font-black italic">{quantity}</span>
                      <button 
                        onClick={() => setQuantity(Math.min(maxPerOrder, quantity + 1))}
                        className="w-10 h-10 bg-white/5 flex items-center justify-center hover:bg-white/10 transition-colors"
                      >
                        <Plus className="w-4 h-4 text-white" />
                      </button>
                   </div>
                   <p className="text-[8px] text-white/20 font-black uppercase tracking-widest mt-2 italic">Max per order: {maxPerOrder} | Total Limit: {maxPerAccount}</p>
                </div>

                {/* Tier Selection */}
                {event.ticketTiers && event.ticketTiers.length > 0 && (
                  <div className="mb-10 space-y-2">
                     <p className="text-[10px] text-white/30 font-black uppercase tracking-tighter mb-4">Select Ticket Type</p>
                     {visibleTiers.map((tier) => (
                       <button
                         key={tier.id}
                         onClick={() => setSelectedTierId(tier.id)}
                         className={`w-full p-6 text-left border-2 transition-all relative overflow-hidden flex flex-col items-start ${
                           selectedTierId === tier.id 
                             ? 'border-brand-primary bg-brand-primary/5' 
                             : 'border-white/10 hover:border-white/30 hover:bg-white/5'
                         }`}
                       >
                         {selectedTierId === tier.id && (
                            <div className="absolute top-0 right-0 w-8 h-8 bg-brand-primary flex items-center justify-center">
                               <CheckCircle2 className="w-4 h-4 text-black" />
                            </div>
                         )}
                         
                         <div className="flex justify-between items-center w-full mb-1">
                            <p className="font-black text-white text-lg uppercase tracking-tighter italic">{tier.name}</p>
                            <p className="font-black text-brand-primary text-lg tracking-tighter italic">{formatCurrency(tier.price, event.currency)}</p>
                         </div>
                         
                         <p className="text-[10px] text-white/50 font-medium mb-4 uppercase tracking-tighter">{tier.description}</p>
                         
                         {(() => {
                           const live = liveTier(tier.id, tier.capacity);
                           const remaining = Math.max(0, live.capacity - live.sold);
                           return (
                             <div className="flex items-center space-x-2">
                               <div className={`w-1.5 h-1.5 ${remaining < 10 ? 'bg-brand-accent' : 'bg-brand-primary'}`}></div>
                               <span className="text-[9px] font-black text-white/30 uppercase tracking-widest leading-none">
                                 {remaining} SLOTS REMAINING
                               </span>
                             </div>
                           );
                         })()}
                       </button>
                     ))}
                  </div>
                )}

                <div className="space-y-6 mb-10">
                  <div className="bg-black p-4 border border-white/5">
                     <p className="text-[10px] text-white/30 font-black uppercase tracking-tighter mb-2">DISCOUNT_CODE</p>
                     <div className="flex gap-2">
                        <input 
                          className="flex-grow bg-white/5 border border-white/10 px-4 py-3 text-xs font-black uppercase tracking-tighter text-white focus:outline-none focus:border-brand-primary"
                          placeholder="ENTER_TOKEN"
                          value={discountCode}
                          onChange={(e) => setDiscountCode(e.target.value)}
                        />
                        <button 
                          onClick={applyDiscount}
                          className="px-6 py-3 bg-white text-black text-[10px] font-black uppercase tracking-tighter hover:bg-brand-primary transition-all shrink-0"
                        >
                          APPLY
                        </button>
                     </div>
                  </div>

                  <div className="divide-y divide-white/5 border-t border-white/5">
                    <div className="flex justify-between text-[10px] py-4 font-black uppercase tracking-tighter">
                      <span className="text-white/30">Status</span>
                      <span className={soldOut ? 'text-brand-accent' : 'text-brand-primary'}>
                        {soldOut ? t('event.soldOut') : t('event.available')}
                      </span>
                    </div>
                    <div className="flex justify-between text-[10px] py-4 font-black uppercase tracking-tighter">
                      <span className="text-white/30">Tickets Available</span>
                      <span className="text-white">
                        {selectedTier
                          ? (() => {
                              const t = liveTier(selectedTier.id, selectedTier.capacity);
                              return `${Math.max(0, t.capacity - t.sold)}`;
                            })()
                          : `${event.totalTickets - event.ticketsSold}`}
                      </span>
                    </div>
                  </div>
                </div>

                {!soldOut && (
                  <AddonSelector
                    eventId={event.id}
                    currency={event.currency || 'USD'}
                    onChange={setAddonSel}
                  />
                )}

                <button
                  disabled={soldOut || purchasing}
                  onClick={handlePurchase}
                  className="primary-button w-full flex items-center justify-center space-x-4 disabled:bg-white/10 disabled:text-white/20"
                >
                  {purchasing ? (
                    <span className="animate-pulse uppercase tracking-tighter italic text-xs font-black">{t('event.processing')}</span>
                  ) : (
                    <>
                      <Ticket className="w-5 h-5" />
                      <span className="uppercase tracking-tighter italic text-sm font-black">{soldOut ? t('event.soldOut') : t('event.buy')}</span>
                    </>
                  )}
                </button>

                {soldOut && (
                  <div className="mt-3">
                    <WaitlistCTA
                      eventId={event.id}
                      tierId={selectedTierId}
                      defaultEmail={user?.email ?? null}
                      defaultName={user?.displayName ?? null}
                      accentStyle={accentBgStyle}
                    />
                  </div>
                )}

                {/*
                  TEST-MODE bypass — admin-only. Skips Stripe and mints
                  a ticket directly so we can validate QR + check-in
                  end-to-end without payments wired. Visible label is
                  intentionally loud so this never gets confused with a
                  real purchase. Remove once Stripe Connect is live and
                  buyers pay through the regular flow.
                */}
                {isAdmin && !soldOut && (
                  <button
                    type="button"
                    disabled={purchasing}
                    onClick={handleTestBuy}
                    className="mt-3 w-full bg-amber-500/10 border-2 border-amber-500/40 hover:bg-amber-500/20 text-amber-200 py-3 font-black uppercase italic tracking-tighter text-xs transition-all disabled:opacity-50"
                  >
                    🧪 Test Mint (admin · bypasses Stripe)
                  </button>
                )}

                <div className="mt-8 flex flex-col space-y-4 text-[9px] font-black uppercase tracking-[0.2em] text-white/30">
                  <div className="flex items-center">
                    <ShieldCheck className="w-4 h-4 mr-3 text-brand-primary" />
                    SECURE DIGITAL ENTRY
                  </div>
                  <button onClick={() => setShowShare(true)} className="flex items-center hover:text-brand-primary transition-colors text-left">
                    <Share2 className="w-4 h-4 mr-3 text-brand-primary" />
                    Share Link
                  </button>
                  <button onClick={handleSMSShare} className="flex items-center hover:text-brand-primary transition-colors text-left">
                    <Send className="w-4 h-4 mr-3 text-brand-primary" />
                    Send via SMS
                  </button>
                  <button onClick={handleInstagramStory} className="flex items-center hover:text-brand-primary transition-colors text-left">
                    <Instagram className="w-4 h-4 mr-3 text-brand-primary" />
                    Share to Instagram
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      {/*
        Unified share modal — single entry point for the "Share Link"
        button on the event card. Falls back to platform pickers when
        navigator.share isn't available. Promoter attribution is
        threaded through if the URL we're on already has ?promoter=X
        — that's how a buyer who arrived via a promoter link can pass
        the same attribution forward when they share.
      */}
      {event && (
        <ShareModal
          open={showShare}
          onClose={() => setShowShare(false)}
          title={event.title}
          url={window.location.href.split('?')[0]}
          promoterId={new URLSearchParams(window.location.search).get('promoter') ?? undefined}
        />
      )}
    </div>
  );
}
