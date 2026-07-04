# Kanban Board / Product Roadmap

Current baseline: `af37caf` + tsconfig fix + 4 rebuild commits
(mail templateName rename, voided ticket status, pending-transfer
lock, ScanReport field rename).

## In Progress (rebuild queue, ~10 commits remaining)

- **Commit 5** — Scanner event-scoping reinforcement: clearer
  "Wrong event — this ticket is for [other title]" error copy +
  `events/{eventId}/scanRejects/{id}` audit collection so
  organizers can see attempted misdirected scans.
- **Commit 6** — Performer names. `event.performers?: string[]`
  field (max 10 × 80 chars), chip input on Create + Edit, render
  on EventDetails, threaded into email templates.
- **Commit 7** — EditEvent timing controls (Date / Doors /
  Show Start / Show End inputs in EditEvent's Logistics section,
  mirroring CreateEvent's `showPicker()` pattern).
- **Commit 8** — Event change notifications. EditEvent diffs
  date/doors/start/end/venue/title against pre-edit snapshot;
  queues `event-updated` email per active ticket holder
  summarizing only changed fields. (Price changes deliberately
  skipped until refund flow is wired.)
- **Commit 9** — Wallet pass route. `/wallet/pass/:ticketId`
  fullscreen browser-only pass with rotating QR + screen wake-lock
  + status overlays. Bare layout (no chrome).
- **Commit 10** — Manual "Send reminder now" button on both
  OrganizerEventReport and OrganizerCheckIn. Queues
  `event-reminder` email per active ticket holder. 6-hour cooldown
  via `events/{eventId}.lastReminderSentAt`.
- **Commit 11** — Scanner offline improvements: 5-min registry
  auto-refresh while online, attest-and-admit escape hatch,
  audit-backfill writes `events/{id}/checkIns` on sync with
  `offlineScannedAt`.
- **Commit 12** — Cap hardening, client-side only. EventDetails
  recount before checkout + MyTickets clamp at fulfillment.
  Server-side firebase-admin check deferred until Stripe Connect.
- **Commit 13** — Concentration flags. Owner-only
  `users/{uid}/concentrationFlags/{eventId}` collection +
  ClaimTicket post-claim count + write when over cap. Broker
  detection signal for when we scale.
- **Commit 14** — Apple/Google Wallet endpoint scaffolds. Server
  endpoints with idToken verify + ownership check, returning 503
  with setup hints until env vars set. APPLE + GOOGLE buttons on
  TicketDetail.

## Competitor gap backlog (TM · AXS · SeatGeek · OpenDate — 2026-07-03)

Feature-parity gaps from a scan of Ticketmaster, AXS, SeatGeek, and
OpenDate against what Bridge ships today, ranked by impact for our
indie-primary + secondary-market positioning. `[ ]` = not started,
`[~]` = partial/scaffolded, `[x]` = shipped.

### Seller side (organizer)
- `[x]` **Scheduled / dynamic tier pricing** (early-bird → regular →
  last-minute time steps). *(TM, SeatGeek.)* Shipped v1: `price_schedule`
  on tiers (mig `20260703122000`), read-time effective price
  (`lib/pricing.ts`), `TierPricingPanel` editor on the event report,
  live price + "price rises on…" nudge on EventDetails. **Follow-up:**
  sold-%-based steps; server-side charge enforcement lands with
  exos-checkout (must recompute effective price server-side).
- `[ ]` **Reserved seating maps** — visual section/row/seat chart
  builder + per-seat pricing + buyer seat picker + ADA/accessible
  seats. *(TM, AXS, SeatGeek — table stakes.)* We only have a free-text
  `seatingManifest`. Largest single build; unblocks ADA + per-seat price.
- `[ ]` **Marketing automation + CRM** — segmented email/SMS/push
  campaigns to followers / past attendees / waitlist, **abandoned-cart
  recovery**, audience segments. *(OpenDate's moat; TM, SeatGeek.)*
  Reuses `exos_mail` + `exos_org_follows` + ticket history. Highest
  revenue leverage after resale.
- `[ ]` **Timed-entry / time-slot / recurring events** — capacity per
  slot; daily/recurring admissions. *(Most modern platforms.)* We're
  single-date only.
- `[ ]` **Season packages / memberships / multi-event bundles.** *(TM,
  AXS, SeatGeek.)* Single-event only today.
- `[ ]` **Box office / POS** — in-person sale, card reader, cash,
  physical ticket stock printing. *(OpenDate, AXS venues.)* Online-only.
- `[ ]` **Booking + artist settlement** — holds/offers calendar, deal
  terms, payout/settlement accounting. *(OpenDate signature.)*
- `[ ]` **Auto pre-event reminders** (T-1d / T-1h). Manual announcement
  shipped; needs a scheduled send (cron/drainer) to auto-fire.
- `[ ]` **Group sales / comp allocations** workflow. *(TM, AXS.)*
- `[ ]` **RFID / hardware access control + entry zones.** *(Enterprise
  venues.)* We have phone-camera scan only.

### Buyer side (fan)
- `[ ]` **Fan-to-fan resale / face-value exchange** — priced resale,
  barcode void+reissue to buyer, payout routing, price caps. *(TM Face
  Value Exchange, AXS Official Resale, SeatGeek marketplace.)* **#1
  strategic gap** — it *is* our secondary-market thesis, and the
  reissue-on-transfer + `channelSource` + Automatiq schema are already
  here. We only do free transfers today. **Recommended next build.**
- `[ ]` **Ticket insurance / refund protection.** *(TM, AXS, SeatGeek
  via XCover / Cover Genius.)* Add-on revenue; mostly a partner wire-up.
- `[ ]` **Installment / BNPL payment plans** (Affirm / Klarna /
  Afterpay). *(SeatGeek.)* Conversion on higher-priced tiers.
- `[ ]` **Smart queue / virtual waiting room + Verified Fan** (fair
  high-demand onsales). *(TM, AXS.)* Our waitlist is post-sellout only.
- `[ ]` **Deal Score / price transparency + personalized discovery.**
  *(SeatGeek.)* Basic discovery only today.
- `[ ]` **Event-day experience hub** (directions, food-to-seat, merch,
  rideshare, in-app upgrades — SeatGeek **Rally**). We stop at ticket +
  add-ons.
- `[~]` **Native Apple / Google Wallet passes.** *(TM, AXS, SeatGeek.)*
  Browser-only `WalletPass` today; native `.pkpass` / Google Wallet
  scaffolds still on the rebuild queue.
- `[ ]` **Self-service upgrades + gift cards / gifting.** *(TM,
  SeatGeek.)* Upgrades depend on the seat-map work.

## To Do (post-rebuild — borrowed from hi.events + pretix research)

The most public open-source alternatives are hi.events (Laravel +
React, ~2 years old, AGPL-3.0) and pretix (Django, ~10 years old,
mature plugin marketplace). Both are battle-tested in different
markets — hi.events on Eventbrite-replacement, pretix on
conferences. Items below are picked from feature comparison;
they're things they have that we don't, ranked by impact for our
indie-cap + secondary-market positioning.

### Stripe webhook fulfillment (server-side)

- Today: ticket-mint runs client-side in `MyTickets.tsx` after the
  Stripe redirect. Fragile — a buyer who closes the tab before
  fulfillment runs gets a paid receipt with no ticket.
- Need: Cloud Function on `checkout.session.completed` webhook
  that mints the ticket server-side, idempotent on `session.id`.
  Removes the entire client-side mint path.
- Blocker: Cloud Functions surface not yet built. Lands with the
  Stripe Connect work for Sprint 3.

### Tax + fee config (per-event, organizer-managed)

- Today: tickets carry `pricePaid` only. No way for organizer to
  add a $2 facility fee or 8.875% NYC sales tax separately.
- Need: `event.fees?: { name, type:'percent'|'fixed', value,
  taxable:bool }[]`. Stripe session emits a separate line item per
  fee. CSV export breaks them out.
- Blocker: requires Stripe line-item refactor. Wait for Stripe
  Connect.

### Plugin loader

- Today: zero. Adding a new payment method, integration, or
  custom workflow requires forking.
- Need: minimal plugin contract — `manifest.json` + entry-point
  module that registers handlers (event-cancel hook, custom
  payment method, custom email template). Pretix has a 10-year-
  old marketplace; we can start with 5 hooks and grow.
- Effort: large. Multi-week build. Long-term moat once it exists.

### Reserved seating maps

- Today: free-form `seatingManifest` text field.
- Need: structured zone/section/row data + visual seat-map editor
  for the organizer + per-tier seat assignment + buyer-facing seat
  picker. Pretix has this; hi.events doesn't.
- Already tagged: in-progress on the existing kanban under "Fully
  dynamic GA Seating & customized manifesting".

### Multi-language (English + Spanish)

- Today: every UI string is hardcoded English.
- Need: i18n framework (lightweight: `react-i18next` or
  similar — NOT one of the heavy SaaS solutions). Extract every
  user-facing string in views/ + components/ to translation keys.
  Ship es-US locale first (largest non-English language in US
  events).
- Scope: every view + email template. ~1-2 days of mechanical
  extraction + translation review. Spanish-only for v1; other
  languages added per-translator capacity.

### REST API for event creation + webhook delivery

- Today: events are created via Firestore SDK from the SPA. A
  partner who wants to sync events from their own CRM has no
  HTTP endpoint to call.
- Need: `POST /api/events` + `PATCH /api/events/:id` + signed
  outbound webhooks (mentioned earlier as Kanban #127).
- Pretix exposes their entire feature set via REST. We don't need
  100% parity — start with event create/update/cancel + ticket
  list + transfer create.

### XLSX export

- Today: CSV export only.
- Need: same data, XLSX format. Trivial — `xlsx` npm package, one
  new download button. Useful for organizers who pivot in Excel.
- Effort: half a day.

### More payment methods

- Today: Stripe Checkout only.
- Need: at minimum, support for bank transfer (for B2B/conference
  invoicing) + a free-ticket path that doesn't require a Stripe
  session id (currently the rule requires it).
- Pretix has a dozen payment methods via plugins. Once the plugin
  loader exists, this becomes someone-else's-problem.

## To Do (existing kanban, deferred)

- **Auto-firing pre-event reminder emails** — Cloud Function cron
  for T-1 day and T-1 hour reminders. Manual button (Commit 10)
  ships the template; cron fires it automatically. Blocker: Cloud
  Functions surface.
- **Outbound webhook system** — per-org webhook config + signed
  HTTP delivery worker. Foundational for CRM/automation.
- **MailChimp / Salesforce / Zapier** — connectors that subscribe
  to outbound webhooks. Blocked on the webhook system.
- **Native CMS plugins** — WordPress / Wix / Squarespace embedding
  the existing `/embed/event/:id` route + checkout.
- **Google Maps + Google Places** — env-gated by
  `VITE_GOOGLE_MAPS_API_KEY`. Lazy script loader + Places
  Autocomplete on Create/Edit address fields + iframe-embed map
  on EventDetails.
- **Music identity OAuth** — Spotify / Apple Music / YouTube
  Music / Last.FM / Bandsintown to build a Music DNA profile per
  buyer.
- **Algorithmic discovery (Suggested for You)** — recommendation
  engine seeded by Music DNA + browsing/purchase history. Blocked
  on the music identity work.
- **Friends & social graph** — find friends, sync contacts, see
  what events friends are attending, form groups.
- **Advanced social marketing hub** — auto-publish to
  Instagram / Facebook, track ad ROI, generate AI copy.
- **Automatiq / Secondary Market Sync** — bi-directional API sync
  to forward inventory to StubHub / SeatGeek / Ticketmaster /
  Vivid + resend failed transfers. The `channelSource` field
  exists on tickets in our schema; this work makes it real.
- **Organizer profiles + follower system** — buyer-facing org
  pages with a follow button, notifications when followed orgs
  publish new events.

## Done

- **Prod apply — the five D4 migrations are LIVE + verified (2026-07-04).**
  `20260703120000`–`20260703124000` (saves · announcements · tier price
  schedule · announcement retract · reschedule) applied to prod
  (`hzrizjeaxlqcxfrtczpq`). Verified against actual schema objects, not
  the ledger — prod stamps migrations by MCP `apply_migration` timestamp,
  so repo filename version-keys never match; confirmed via `to_regclass`
  / `pg_policy` / column + grant introspection that every table, column,
  RPC, RLS policy, view option (`security_invoker`), and mail-allowlist
  value is present and matches. Security advisor clean for these surfaces
  (only the by-design "authenticated can execute SECDEF" WARN on the two
  RPCs — gate is inside the function body). Code merged to `main` via
  PR #777 (squash `85da7b7`).
  - `[ ]` **Follow-up (D4 · ops):** confirm the `exos_mail` drainer is
    configured + running (`RESEND_API_KEY` + `EXOS_MAIL_FROM`) — the
    schema is verified but email *delivery* for announcements + reschedule
    notices rides that drainer. In-app notices, saved events, and pricing
    display don't depend on it and are fully functional.
- **Reschedule events (seller → buyer).** First-class postpone/move
  action, distinct from a silent EditEvent field change: updates the
  event timing, logs old→new (`exos_event_reschedules`, staff + holder
  RLS), and emails every non-voided holder the new date (server-rendered
  in the event tz; new `event-rescheduled` mail template). Via the
  `exos_reschedule_event()` SECDEF RPC (owner/manager; mig
  `20260703124000`). `ReschedulePanel` on OrganizerEventReport
  (tz-aware inputs + history); `RescheduleNotice` on TicketDetail shows
  holders "was X → now Y". Tickets stay valid.
- **Scheduled / dynamic tier pricing (seller).** `price_schedule` jsonb
  on `exos_ticket_tiers` (mig `20260703122000`) — ordered
  `{startsAt, price}` time steps; effective price computed at read time
  (`lib/pricing.ts`), exposed through the security-invoker
  `exos_public_tiers` view (+ anon column grant). `TierPricingPanel`
  editor on OrganizerEventReport (owner/manager); EventDetails shows the
  live effective price + a "price rises to $X on <date>" urgency nudge.
  Own primary inventory — not a RULE-2 upstream reprice. Flesh-out:
  editor is event-timezone-aware (zonedWallClockToUtc); storefront
  strikes the opening price when a step marks it down; Home cards show
  the effective "from" price. **Follow-up:** sold-%-based steps +
  server-side charge enforcement (with exos-checkout).
- **Buyer saved events (wishlist).** `exos_event_saves` table (private
  per-user, RLS `user_id = auth.uid()`, no counter → plain RLS-gated
  writes). Heart toggle on EventDetails + Home discovery cards
  (`SaveEventButton`), a "Saved Events" section in My Tickets that
  un-hearts in place. Migration `20260703120000` (D4 authors; A1 applies).
- **Organizer → attendee announcements (two-sided).** Owner/manager
  broadcast a free-text update to non-voided ticket holders; buyers get
  it as an email (via the existing `exos_mail` queue, new
  `event-announcement` template) AND an in-app thread on their ticket
  ("Updates from the organizer"). Persisted in `exos_event_announcements`
  (staff + holder RLS read), sent via `exos_send_event_announcement()`
  SECDEF RPC (recipients server-derived, body tag-escaped — no open
  relay). Composer on OrganizerEventReport (`AnnouncementsPanel`);
  read-only thread on TicketDetail (`OrganizerUpdates`). Migration
  `20260703121000`. Flesh-out: owner/manager can **retract** an
  announcement (staff DELETE RLS, mig `20260703123000`) — pulls it from
  holders' in-app threads (sent emails aren't recalled).
- Live deployment to Firebase Hosting at
  `gen-lang-client-0961373515.web.app`.
- Tsconfig truncation fix (commit 6532147).
- Mail wire field rename `template → templateName` (Commit 1) —
  fixes Trigger Email extension misinterpreting our string field
  as template-mode rendering.
- Voided/refunded ticket status (Commit 2) — sticky transition,
  audit fields, scanner reject in online + offline paths,
  REFUNDED stamp on TicketDetail, Refund/Void button on
  OrganizerEventReport's Attendees list.
- Pending-transfer lock (Commit 3) — `pendingTransferId` field
  prevents sender double-spend during in-flight transfers, also
  closes the two-tabs race for concurrent transfers.
- ScanReport field rename (Commit 4) — onSnapshot now reads
  `organizerId`/`source`/`scannedAt` instead of stale
  `scanner`/`station`/`at` field names. Fixes silent "unknown"
  display for every scan.
- Stress simulation suite (`stress-sim.ts` + `scripts/stress-test.cjs`).
- Multi-tenant orgs (Phase 1) with RBAC roles
  (owner/manager/finance/scanner/content) + composite-id
  membership lookups.
- White-label theming per org (Phase 2).
- Embed widget (`/embed/event/:id`, chromeless iframe-friendly).
- Organizer onboarding flow.
- Email-based member invites with token-doc claim flow.
- Refund flow (organizer-initiated event-level cancellation +
  buyer notification).
- Real-time sales chart on organizer dashboard.
- SEO meta tags + sitemap + robots.txt + per-event Schema.org
  Event JSON-LD.
- Per-event analytics page with sales chart, tier breakdown,
  promoter and channel attribution.
- Promo codes with expiry + sub-collection counter +
  rule-enforced monotonic increment.
- Promoter / affiliate tracking (`?promoter=<id>` URL → stamped
  on ticket → rolled up in event report).
- Slug-based vanity URLs (`/e/:slug` resolver).
- Hardened Firestore security rules: organizer/admin gates,
  isEventStaff helper, append-only checkIns audit log,
  per-tier sold counters in `events/{id}/tierSales`,
  promoUses sub-collection counter.
- HMAC-signed rotating barcodes (Web Crypto API, 30-second
  buckets, per-ticket secret rotated on transfer claim).
- Offline organizer check-in with localStorage registry +
  pending-updates queue + camera scanner with flashlight.
- Per-event currency picker, structured address inputs,
  per-tier sale windows + visibility + ticketType.
- Production-hardened Express server: rate limiter, security
  headers, structured access log, /healthz, graceful shutdown.
- Code-split routes + chunked vendor bundles (firebase, stripe,
  motion, qr-code).
- ErrorBoundary at app root + Toast system replacing alert().
- Three-platform competitive simulation (Exos vs DICE.fm
  vs Eventbrite end-to-end roleplay).
- 250-cap event-day end-to-end stress simulation + Automatiq
  10-channel oversell race simulation (all invariants held).
- Social sharing (SMS, Instagram Story file share via
  `navigator.share` native sheet on mobile).
- Date/time picker UX fix on CreateEvent (showPicker on click).
- Repository hygiene — `.gitignore` patterns for service-account
  JSONs, README docs for HTTPS barcode requirement and admin
  grant flow, buyer-profile private-only policy.
