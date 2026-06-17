# D4 / Exos — Parity Build Backlog

> **Created:** 2026-06-17 · derived from the Exos-vs-pretix-vs-Hi.Events feature audit.
> **Purpose:** one card = one buildable unit. Pull from the top of **Backlog**, build it,
> move it to **Done**. Ordered by impact ÷ effort for our indie-cap + secondary-market
> positioning.
>
> **Relationship to `d4_bridge/KANBAN.md`:** that board is the legacy (Firestore-era)
> roadmap and its "To Do" section is stale — several items there (outbound webhooks, tax
> rules, REST API, invoicing) shipped LIVE on Supabase in the 2026-06-16 migrations. This
> board supersedes it for parity work. Don't rebuild anything in **Already shipped** below.
>
> Status legend: ✅ live · 🟡 scaffolded/partial · ❌ absent · 🔒 blocked on external creds/auth.

---

## Backlog (ordered — build top to bottom)

### 1. Custom checkout questions / attendee forms  ❌  *(gap vs BOTH pretix + Hi.Events)*
- **Why:** the single feature we lose to *both* competitors. Organizers can't collect
  attendee name/email/dietary/t-shirt/waiver/etc. at checkout. Table-stakes for
  conferences and most paid events.
- **Build:** `exos_questions` (per-event or per-tier, types: text/select/checkbox/number/
  date, required flag, sort_order) + `exos_order_answers` (per ticket/order). RLS: org
  staff manage; buyer reads own answers. Render in checkout form; surface in attendee
  export + `exos-api` attendee endpoint.
- **Effort:** M · **Blocker:** none (pure additive schema + FE).
- **Done when:** organizer defines questions on an event, buyer answers at checkout,
  answers appear in attendee list + CSV/XLSX export + API.

### 2. Light up payments + transactional email  🟡🔒  *(claimed-parity, not live)*
- **Why:** the entire commerce loop is scaffolded but inert. No real revenue or comms
  until creds land. Highest impact, lowest *code* effort (it's mostly config).
- **Build:** set `STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET` + Connect account decision
  (Standard/Express, destination/direct, fee %); set `RESEND_API_KEY` / `EXOS_MAIL_FROM`;
  schedule the `exos-mail-drain` (2-min) cron. Then end-to-end test: checkout → fulfill →
  invoice → ticket-issued mail.
- **Effort:** S (code) / operator-gated (creds) · **Blocker:** 🔒 operator sets Stripe +
  Resend secrets; A1 schedules cron.
- **Done when:** a sandbox purchase mints a ticket via webhook + sends the confirmation mail.

### 3. Sub-events / event series / recurring  ❌  *(gap vs pretix)*
- **Why:** biggest addressable-market unlock that does NOT need a seat-map engine. No model
  today for a tour, a season, or a daily/weekly recurring show — each is a separate event.
- **Build:** `exos_event_series` parent + `series_id` FK on `exos_events`; optionally
  per-occurrence capacity overrides. Calendar/list FE for a series; series-level branding
  inherited by children. Decide: shared inventory vs per-occurrence.
- **Effort:** M–L · **Blocker:** design decision on shared-vs-per-occurrence inventory.
- **Done when:** an organizer creates a series, adds N dated occurrences, and a buyer picks
  an occurrence from a series page.

### 4. Reserved seating / seating plans  ❌  *(gap vs pretix; Hi.Events also lacks it)*
- **Why:** highest ceiling, highest effort. The one feature that moves Exos from "GA
  ticketing" into pretix's full venue territory (theaters, arenas, assigned seats).
- **Build:** `exos_seating_plans` (zones/sections/rows/seats JSON) + `exos_seats` (status:
  free/held/sold, tier link) + per-tier seat assignment. Organizer seat-map editor +
  buyer-facing seat picker. Atomic hold-on-select + release-on-timeout in checkout.
- **Effort:** L (multi-week) · **Blocker:** none, but large; sequence after 1–3.
- **Done when:** organizer draws a plan, buyer picks a specific seat, seat locks during
  checkout and mints to that seat.

### 5. Product variations  ❌  *(gap vs pretix)*
- **Why:** add-ons/tiers are flat. No size/color matrix (a "T-shirt" add-on can't have
  S/M/L/XL with independent stock).
- **Build:** `exos_addon_variations` (variation axis + per-variation capacity/sold/price
  delta) hung off `exos_event_addons` (and optionally tiers). Variation picker in checkout.
- **Effort:** M · **Blocker:** none.
- **Done when:** an add-on exposes selectable variations each with their own stock.

### 6. Refund flow to live  🟡  *(gap vs both — scaffolded only)*
- **Why:** `exos_refund_checkout` exists but isn't wired to Stripe. Full/partial refunds are
  table-stakes; both competitors ship them.
- **Build:** wire `exos_refund_checkout` → Stripe refund API (full + partial), flip
  `exos_invoices` to credit-note status, void/return inventory, queue refund mail.
- **Effort:** M · **Blocker:** depends on #2 (Stripe live).
- **Done when:** organizer issues a partial refund; money returns, invoice updates, inventory
  re-opens.

### 7. Gift cards  ❌  *(gap vs pretix)*
- **Why:** redeemable cross-event balance; a retention/gifting primitive pretix has.
- **Build:** `exos_gift_cards` (code, balance_cents, org scope) + redemption as a checkout
  payment source (partial pay + remainder via Stripe). Atomic balance decrement.
- **Effort:** M · **Blocker:** depends on #2 for mixed-tender checkout.
- **Done when:** a gift card partially pays for an order and its balance decrements.

### 8. Memberships / season tickets  ❌  *(gap vs pretix)*
- **Why:** recurring entitlement model (member price, season pass that admits to all
  occurrences in a series). Pairs naturally with #3.
- **Build:** `exos_memberships` (holder, type, validity window) + entitlement check in
  checkout/mint (member-only tiers, season-pass admits to series occurrences).
- **Effort:** L · **Blocker:** best after #3 (series).
- **Done when:** a season-pass holder is admitted to every occurrence in a series.

### 9. Multi-provider payments  🟡  *(gap vs pretix)*
- **Why:** Stripe-only today. B2B/conference invoicing needs bank-transfer; some markets
  need SEPA/PayPal.
- **Build:** payment-provider abstraction over the checkout edge fn; first add an
  offline/bank-transfer path (org marks paid) + a true free path independent of a Stripe
  session id. Layer PayPal/SEPA later.
- **Effort:** M · **Blocker:** depends on #2.
- **Done when:** an organizer accepts a bank-transfer order that mints on manual mark-paid.

### 10. Bulk messaging segmented by ticket type  🟡  *(gap vs Hi.Events)*
- **Why:** we can `announce-to-followers`, but can't "email all VIP buyers." Hi.Events does
  segmented blasts.
- **Build:** message composer that targets buyers by tier/add-on/check-in status; reuse the
  `exos_mail` queue + a new `event-message` template with server-derived recipient list.
- **Effort:** S–M · **Blocker:** depends on #2 (email live).
- **Done when:** organizer sends a message to exactly the holders of one tier.

### 11. Customizable PDF ticket design  🟡  *(gap vs Hi.Events)*
- **Why:** we mint a rotating QR + client-side invoice PDF, but no designable branded PDF
  ticket. Hi.Events has customizable PDF ticket templates.
- **Build:** per-org PDF ticket template (logo, colors, fields, terms) rendered server- or
  client-side with the rotating-QR caveat (QR stays app-rendered; PDF carries a static
  fallback or claim link).
- **Effort:** M · **Blocker:** none.
- **Done when:** an org sets a branded PDF template and buyers download a styled ticket PDF.

### 12. Product categories  ❌  *(gap vs Hi.Events)*
- **Why:** add-ons are a flat list. Categories group merch/upgrades/extras in the storefront.
- **Build:** `exos_addon_categories` (name, sort_order) + `category_id` on
  `exos_event_addons`; grouped rendering in checkout.
- **Effort:** S · **Blocker:** none.
- **Done when:** add-ons render grouped under organizer-defined categories.

### 13. Drag-and-drop event page builder  🟡  *(gap vs Hi.Events)*
- **Why:** we use fixed templates + branding; Hi.Events has a block/page builder for richer
  event pages.
- **Build:** block-based page model (`exos_event_pages` w/ ordered content blocks: text/
  image/video/FAQ/map) + a builder UI + public renderer.
- **Effort:** L · **Blocker:** none; lower priority than commerce features.
- **Done when:** organizer composes a custom event page from blocks and it renders publicly.

### 14. Badge printing  ❌  *(gap vs pretix)*
- **Why:** conference badge layouts (name/company/QR) for on-site printing. Niche but
  expected for the conference segment.
- **Build:** badge template per event (fields from checkout answers — depends on #1) +
  print/PDF export for a check-in list.
- **Effort:** M · **Blocker:** depends on #1 (questions provide badge fields).
- **Done when:** organizer prints badges for an attendee list with custom fields + QR.

### 15. Multi-language UI (translations)  🟡  *(gap vs both)*
- **Why:** i18n framework is stubbed; strings hardcoded English. Spanish is the largest
  non-English US event language.
- **Build:** extract user-facing strings to keys (`react-i18next` or similar), ship `es-US`
  first, translate email templates too.
- **Effort:** M (mechanical) · **Blocker:** none.
- **Done when:** the storefront + emails render fully in Spanish via a locale switch.

### 16. Plugin / extensibility system  ❌  *(gap vs pretix)*
- **Why:** zero extensibility; new payment method/integration/workflow needs a fork.
  Pretix's moat is its plugin marketplace. Long-term, not urgent.
- **Build:** minimal plugin contract — manifest + entry module registering a handful of
  hooks (event-cancel, custom payment method, custom email template, webhook transform).
  Start with ~5 hooks.
- **Effort:** L (multi-week) · **Blocker:** none; deliberately last — stabilize core first.
- **Done when:** a sample plugin registers a hook without forking the app.

---

## Blocked — external authorization (not buildable until unblocked)

### Secondary-market distribution push  🟡🔒  *(unique to Exos — neither competitor has it)*
- Schema (`exos_distribution_listings`) + `exos-distribute` edge fn are scaffolded but
  **inert**. Pushes inventory OUT to SeatGeek/TEvo/StubHub/Vivid/TickPick.
- **Blocked on:** Hard Rule #2 (upstream-write lockdown) — needs explicit operator
  authorization per platform + B1/D2 sign-off + a documented listing-write carve-out +
  `AUTOMATIQ_API_KEY`. **Do not build the write path without that authorization.**

---

## Already shipped — audit reconciliation (do NOT rebuild; verify only)

These appeared as "gaps" in a naive feature-list compare but the audit confirmed they're
already LIVE in the schema/migrations. Spot-check, don't rebuild:

- ✅ **Vouchers** (access tokens, bypass-capacity, price-override, email-reserved) — `exos_vouchers`.
- ✅ **Waitlist + auto-assign** — `exos_waitlist` (exceeds Hi.Events, which lacks it).
- ✅ **Tax rules** (inclusive/exclusive) — `exos_tax_rules`.
- ✅ **Invoicing** (sequential per-org) — `exos_invoices` / `exos_invoice_counters`.
- ✅ **Add-ons / merch** — `exos_event_addons` / `exos_order_addons`.
- ✅ **REST API + outbound webhooks** (HMAC, SSRF guard, retry/backoff) — `exos_api_keys`,
  `exos_webhooks`, `exos_webhook_deliveries`.
- ✅ **Discount codes** (% / fixed) — `exos_discount_codes` (note: consumption enforcement is
  dormant — small follow-up if needed).
- ✅ **Promoter / affiliate tracking** — `?promoter=<id>` stamped on tickets, rolled up in
  reports (audit flagged it ❌ from schema names; it's implemented at the FE/attribution
  layer — **verify** rather than rebuild).
- ✅ **SEO** — meta tags + sitemap + Schema.org Event JSON-LD already shipped.
- ✅ **CSV export** (XLSX is a trivial half-day add if wanted).

---

## Ahead of both competitors (defend, don't rebuild)

- ✅ **P2P ticket transfers** with barcode reissue (anti-resale-fraud) — neither ships this.
- ✅ **Rotating HMAC-SHA256 barcodes** (60s buckets) — both use static QR.
- ✅ **Org follow graph + announce-to-followers** — a social/marketing layer neither has.
- ✅ **Defense-in-depth RLS** (REVOKE-all + re-grant + policies + SECDEF RPCs).
