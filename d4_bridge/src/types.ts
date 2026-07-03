import { Timestamp } from './lib/timestamp';

export interface UserProfile {
  uid: string;
  email: string;
  displayName: string;
  photoURL: string;
  createdAt: Timestamp;
}

// ---------------------------------------------------------------------
// Multi-tenant orgs (Bridge Phase 1).
//
// Every venue / promoter that signs up for Bridge gets an Organization.
// Events, tickets, transfers, slugs, and mail all carry an `orgId` field
// that scopes them to that org. RBAC is enforced via the
// `org_memberships/{orgId}_{uid}` collection (role per user per org).
//
// We keep events at the root collection (not nested under
// `orgs/{orgId}/events/...`) because:
//   * Cross-org browse on the public home page stays a trivial root
//     collection query — no collectionGroup index needed.
//   * Existing routes (`/event/:id`) keep working unchanged.
//   * Migration is a field-add, not a data move.
// Per-org queries still cost one indexed where() filter on `orgId`.
// ---------------------------------------------------------------------

export type OrgRole =
  // Full control. Can edit org settings, members, billing, all events.
  | 'owner'
  // Day-to-day operator. Can edit events, run check-in, view reports.
  // Cannot change org settings, billing, or member list.
  | 'manager'
  // Read-only access to financials + can issue refunds when wired up.
  // Cannot edit events or run check-in.
  | 'finance'
  // Door staff. Can read events + scan check-ins. Cannot edit anything.
  | 'scanner'
  // Can edit event content (descriptions, images, tier copy) but
  // cannot publish, refund, or check anyone in.
  | 'content';

export interface Organization {
  id: string;
  // Display name surfaced on the venue's storefront and in the dashboard.
  name: string;
  // URL-safe slug — used for branded routes like `/o/{slug}` once Sprint
  // 2 (white-label) lands. Globally unique via `slugs/{slug}` reservation.
  slug: string;
  // The bootstrap owner. The user whose `OrgRole` is `'owner'` on creation.
  // Stored here as a denormalised pointer so we can render "owned by X"
  // in admin tooling without a separate query.
  ownerUid: string;
  createdAt: Timestamp;
  updatedAt?: Timestamp;
  // Public bio + denormalized follower count (Sprint 3 — org follow graph).
  // Surfaced on OrganizerProfile; followersCount is maintained by the
  // exos_follow_org/unfollow RPCs.
  description?: string;
  followersCount?: number;
  // Phase 2 white-label. Filled in by Sprint 2.
  theme?: {
    logoUrl?: string;
    primaryColor?: string;
    accentColor?: string;
    customDomain?: string;
  };
  // Phase 2 Stripe Connect. Filled in by Sprint 3 — `connectedAccountId`
  // is a Stripe Express/Standard connected account id (acct_xxx).
  payments?: {
    connectedAccountId?: string;
    onboardingComplete?: boolean;
    chargesEnabled?: boolean;
    payoutsEnabled?: boolean;
  };
  // Phase 4 Lysted/Automatiq integration. Filled in by Sprint 4 — opaque
  // credentials that let our server push listings on the org's behalf.
  // Stored encrypted; rules block all client reads.
  distribution?: {
    lystedSellerId?: string;
    enabled?: boolean;
  };
  // Growth/marketing config (D4-OPS-14, mig 20260523200000). Public IDs/handles
  // only (no secrets). Socials render on the storefront; pixels load on public
  // pages behind the consent gate (lib/consent.ts + lib/pixels.ts).
  marketing?: {
    socials?: { instagram?: string; facebook?: string; tiktok?: string; x?: string; website?: string };
    pixels?: { meta?: string; ga4?: string; tiktok?: string };
    shareImageUrl?: string;
  };
}

export interface OrgMembership {
  // Composite id `${orgId}_${uid}` so rule checks are a single
  // `exists()` lookup with no query.
  id: string;
  orgId: string;
  uid: string;
  role: OrgRole;
  addedAt: Timestamp;
  // Uid of the actor who added this member. Useful for the eventual
  // `org_audit/{id}` log when we wire that up.
  addedBy: string;
  // Soft-disable without revoking the doc. A disabled membership is
  // ignored by the rule helper but kept for audit history.
  disabled?: boolean;
}

/**
 * Email-based invite. Owners create an invite naming the invitee's
 * email and the role they should get. Lives at `org_invites/{token}`
 * where token is a server-generated random id (not derived from the
 * email — we don't want anyone to guess the doc id from "knows the
 * email"). Invitee signs in (email-verified), visits /invite/:token,
 * and the rule allows them to:
 *   1. Read their own invite (rule gates on token + email match).
 *   2. Create a membership doc (the staff-add branch already gates on
 *      ownership; we add a "valid invite exists for this email" path).
 *   3. Mark the invite completed.
 *
 * Why not Cloud Functions for email→uid lookup: this whole flow
 * works without server-side email resolution. Firebase Auth's
 * email_verified claim on the signed-in user is the source of truth
 * for "this person controls that email."
 */
export interface OrgInvite {
  // Doc id is the token itself.
  token: string;
  orgId: string;
  // Lowercase email — invitee must sign in with this email and have
  // email_verified == true on their auth token.
  email: string;
  role: OrgRole; // Cannot be 'owner' from the client.
  createdBy: string;
  createdAt: Timestamp;
  expiresAt: Timestamp;
  status: 'pending' | 'completed' | 'cancelled' | 'expired';
  // Set when the invite is claimed; used by the OrgMembers view to
  // show "X joined as manager on Mar 15".
  claimedBy?: string;
  claimedAt?: Timestamp;
}

export interface Event {
  id: string;
  title: string;
  description: string;
  date: Timestamp;
  location: string;
  price: number;
  // The organization that owns this event. Required for all new events.
  // Optional in the type only because legacy events created before
  // Sprint 1's multi-tenant migration may not have it yet — the
  // migration script backfills every existing event with a
  // freshly-created default org keyed off `organizerId`.
  orgId?: string;
  // The user who created the event. Kept around for backwards compat
  // with the pre-orgs rule (which gated writes on `organizerId == uid`)
  // and so admin tooling can show "created by". Going forward, all
  // staff RBAC is keyed on `orgId` + `org_memberships`, not this field.
  organizerId: string;
  totalTickets: number;
  ticketsSold: number;
  image: string;
  category: string;
  // Lifecycle. Legacy events without this field are treated as
  // 'published' by the read rule and by Home for backwards compat.
  status?: 'draft' | 'published' | 'cancelled';
  // When status == 'cancelled': server timestamp of the cancel
  // action and an organizer-supplied reason (1-500 chars). Both
  // optional in the type so legacy events don't fail validation;
  // the EditEvent flow stamps both when the owner cancels.
  cancelledAt?: Timestamp;
  cancelReason?: string;
  // IANA timezone (e.g. "America/New_York"). When absent the UI falls
  // back to the viewer's local zone.
  timezone?: string;
  // ISO 4217 currency code. Defaults to 'USD' wherever this is absent.
  currency?: string;
  // Optional structured address. `location` stays as the venue display
  // name (e.g. "Brooklyn Steel"); `address` carries the lookup-friendly
  // bits for maps, calendar invites, and tax-jurisdiction logic.
  address?: {
    street?: string;
    city?: string;
    region?: string;
    country?: string;
    postal?: string;
  };
  genres?: string[];
  subgenres?: string[];
  // Performer names. Free-text, organizer-managed. Surfaced on the
  // event detail page (above genres), in transfer + reminder emails,
  // and in CSV exports. Max 10 entries × 80 chars each — enforced by
  // the firestore rule and by the Create/Edit form. Optional because
  // legacy events created before this field shipped don't have it.
  performers?: string[];
  timing?: {
    doorsOpen?: Timestamp;
    startTime: Timestamp;
    endTime?: Timestamp;
  };
  automatiqListingId?: string;
  syncStatus?: 'synced' | 'failed' | 'pending';
  // Hi.Events / Pretix inspired enhancements
  branding?: {
    primaryColor?: string;
    accentColor?: string;
    logoUrl?: string;
    bannerUrl?: string;
    customSlug?: string;
  };
  ticketTiers?: {
    id: string;
    name: string;
    price: number;
    description: string;
    capacity: number;
    // Legacy; per-tier sold counts now live in the events/{id}/tierSales
    // sub-collection. Kept here for backwards compat with old docs.
    sold: number;
    // 'paid' (default) charges via the configured payment processor.
    // 'free' bypasses payment and mints the ticket directly when wired
    // up by the payments team. 'donation' uses a buyer-chosen amount.
    ticketType?: 'paid' | 'free' | 'donation';
    // 'public' (default) shows the tier on the event page. 'hidden'
    // hides it until a promo code with this tier id in unlocksTierIds
    // is applied — used for industry comp lists, presales, etc.
    visibility?: 'public' | 'hidden';
    // Per-tier sale window. Outside this range the tier is shown but
    // the buy button is disabled with a "Sales open at..." or "Sales
    // ended" message. When null/undefined the window is open as soon
    // as the event itself is published.
    salesStart?: Timestamp | null;
    salesEnd?: Timestamp | null;
    // Scheduled (time-based) pricing. `price` above is the opening price;
    // each step says "on/after startsAt, the price becomes this". The
    // effective price is the latest already-active step (lib/pricing.ts).
    // Models early-bird → regular → last-minute. Empty/undefined = flat price.
    priceSchedule?: { startsAt: string; price: number }[];
  }[];
  // Promo code metadata. The redemption *count* lives in the
  // events/{id}/promoUses/{code} sub-collection so it can be
  // rule-enforced — see PromoUse below.
  discountCodes?: {
    code: string;
    type: 'percentage' | 'fixed';
    value: number;
    usageLimit?: number | null;
    expiresAt?: Timestamp | null;
    // Tier ids that this code makes visible. When set, applying the
    // code in EventDetails reveals otherwise-hidden tiers — used for
    // presale, industry comps, friend-of-band lists, etc.
    unlocksTierIds?: string[];
    // Note: `usedCount` historically lived on this object; it's been
    // moved to the sub-collection. We keep it as an optional field for
    // backwards-compat with any legacy events but stop relying on it.
    usedCount?: number;
  }[];
  exclusivity?: {
    primaryMarketOnly: boolean;
    startTime?: Timestamp;
    customUrlOnly: boolean;
    marketplaceBlocklist?: string[];
  };
  distributionNetworks?: string[];
  purchaseLimits?: {
    maxPerOrder?: number;
    maxPerAccount?: number;
  };
}

export interface Ticket {
  id: string;
  eventId: string;
  // Denormalised org pointer — copied from the parent event at mint time
  // so check-in tooling and the eventual cross-org buyer dashboard can
  // filter by org without a join. Optional because pre-Sprint-1 tickets
  // don't have it; the migration script backfills.
  orgId?: string;
  buyerId: string;
  ownerId: string;
  // Same backwards-compat reasoning as Event.organizerId — RBAC moves
  // to org_memberships in Sprint 1 but the field is preserved on
  // existing tickets.
  organizerId: string;
  // 'active'      — sellable + scannable
  // 'transferred' — legacy status (set by old code; kept for backward
  //                 compat). New code uses pendingTransferId for
  //                 in-flight transfers.
  // 'used'        — checked in at the door (sticky).
  // 'voided'      — refunded / revoked by organizer or admin. Sticky
  //                 like 'used'. In Exos terms voided == refunded:
  //                 the void is the mechanism, the refund is the
  //                 financial action that follows. Scanner refuses
  //                 entry; wallet QR mutes; TicketDetail shows
  //                 "REFUNDED".
  status: 'active' | 'transferred' | 'used' | 'voided';
  // Audit context for voids/refunds — populated when an organizer
  // flips status:'active' -> status:'voided'. Optional because legacy
  // tickets predate the field.
  voidedAt?: Timestamp;
  voidedBy?: string;
  voidedReason?: string;
  purchaseDate: Timestamp;
  barcodeValue: string;
  barcodeSecret?: string;
  tierId?: string;
  tierName?: string;
  orderId?: string;
  pricePaid?: number;
  stripeSessionId?: string;
  // Set by ClaimTicket so the rules can verify the linkage to the
  // completed transfer doc.
  transferId?: string;
  // Pending-transfer lock. Set by TransferTicket immediately after
  // creating a `transfers/{id}` doc with status:'pending'. Cleared
  // (set to null) on claim (ClaimTicket) or cancel (MyTickets cancel
  // button). Every consumer — wallet UI, door-scan flow, offline
  // registry — treats a non-null value as "ticket is in transit,
  // refuse to act". Without this lock, the original holder could
  // walk in with the QR while the receiver hasn't claimed yet.
  pendingTransferId?: string | null;
  // Buyer's email at fulfillment time, lowercased. Denormalized
  // because the canonical source (auth token email) isn't readable
  // from another user's context — without this, the organizer's
  // cancellation flow can't email ticket holders. Set by MyTickets
  // fulfillment for direct sales; populated by the Lysted webhook
  // for secondary-channel sales when the channel passes it through
  // (some channels pass hashed identifiers only — those tickets
  // simply don't get emailed and rely on the channel's own buyer
  // notifications).
  buyerEmail?: string;
  // Optional promoter / affiliate id. Set when the buyer arrived via
  // ?promoter=<id> on the event page; threaded through Stripe metadata
  // and stamped onto the ticket at fulfillment time so the organizer
  // can attribute sales back to the promoter.
  promoterId?: string;
  // Where the sale originated. 'vibepass' = direct via storefront /
  // embed widget; the Lysted-distributed channels (Sprint 4) write
  // their own value here (e.g., 'stubhub', 'vivid', 'seatgeek').
  // Drives cancellation refund routing: only 'vibepass' tickets get
  // a Stripe refund through us; secondary-channel cancellations send
  // the buyer back to the channel they bought from. Optional in the
  // type because legacy tickets predate the field; treat undefined
  // as 'vibepass' (direct) for backwards compat.
  channelSource?: 'vibepass' | 'stubhub' | 'vivid' | 'seatgeek' | 'axs' | 'gametime' | 'tickpick' | 'gotickets' | 'ticketnetwork' | 'ticketevolution' | 'ticketmaster';
  lastReissueDate?: Timestamp;
  checkInDate?: Timestamp;
}

/**
 * Check-in list — a named subset of an event's tiers that a group of
 * door staff can scan against. Lives at
 * events/{eventId}/checkInLists/{listId}.
 *
 * Mirrors hi.events' check-in lists model: one event can have many
 * lists ("Main Door", "VIP Entry", "Press"), each scoped to a set of
 * tier ids. Eventually `staffUids` will gate which uids are allowed
 * to use a list — for now lists are organizer/admin-managed only.
 */
export interface CheckInList {
  id: string;
  name: string;
  allowedTierIds: string[];
  staffUids?: string[];
  createdAt?: Timestamp;
  updatedAt?: Timestamp;
}

/**
 * Per-promo-code redemption counter. Lives at
 * events/{eventId}/promoUses/{codeUpper}. Buyers increment `usedCount`
 * via Firestore rule; organizers manage `usageLimit`/`expiresAt`.
 */
export interface PromoUse {
  usedCount: number;
  usageLimit?: number | null;
  expiresAt?: Timestamp | null;
  lastUsed?: Timestamp;
  lastUpdated?: Timestamp;
}

export interface Transfer {
  id: string;
  ticketId: string;
  senderId: string;
  receiverEmail: string;
  status: 'pending' | 'completed' | 'cancelled';
  createdAt: Timestamp;
  updatedAt?: Timestamp;
  // Denormalised event/tier metadata — written when the transfer is created
  // so the receiver can render the claim UI without reading the ticket
  // (which Firestore rules forbid them from doing).
  eventId?: string;
  eventTitle?: string;
  eventImage?: string;
  tierName?: string;
  organizerId?: string;
  // Denormalised org pointer mirroring Ticket.orgId — lets organizer
  // tooling filter "transfers in flight for our org" without a join
  // through tickets. Backfilled by the Sprint 1 migration.
  orgId?: string;
  // Denormalised sender email so the receiver can send a "claimed"
  // notification back without reading the sender's user doc.
  senderEmail?: string;
}
