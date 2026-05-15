# D1 — Retail Site Finish Punch List

**Owner: D1 (Consumer Retail). 2026-05-13.**

This is the longer "what does it take to actually finish the retail site" list — the companion to `evo_store_next_steps.md` (which is just the 3 go-live unblocks).

Each item is tagged:
- 🟥 **BLOCKER** — site cannot be called live with this missing
- 🟧 **MVP→PROD** — site is technically live but feels like an MVP without it
- 🟨 **POLISH** — improves UX/conversion, not strictly required
- 🟦 **DEFERRED** — explicitly out of scope for v1

---

## A. Live-launch unblocks (carry from `evo_store_next_steps.md`)

| ✅ / ⬜ | Item | Tag |
|---|---|---|
| ⬜ | Deploy branch sync — repoint Render at `main` (or merge `main` → `claude/store-sql-only-demo-mode`) | 🟥 |
| ⬜ | JWT key swap — replace legacy `eyJ...` with `sb_secret_*` / `sb_publishable_*` in Render env | 🟥 |
| ⬜ | Re-verify `/api/store/events?limit=3` returns 200 in <2s | 🟥 |

Reference: `docs/evo_store_next_steps.md`.

---

## B. Real purchase path (the big gap)

Today's state, from `app.py:5720-5783`:
- `/api/store/reserve` is a **mock**. Returns `purchase_enabled: false` and `"MVP demo — no charge processed"`.
- Validates ticket-group availability against TEvo (live) or `listings_snapshots` (SQL-only mode).
- **Never** posts to TEvo `/v9/orders`. No payment processor.
- All three HTML pages show `MVP · browse only · no real purchases` badge.

To actually sell tickets:

| ⬜ | Item | Tag | Notes |
|---|---|---|---|
| ⬜ | Decide payment processor (Stripe? Adyen? Square?) | 🟥 | Stripe is path-of-least-resistance — best Flask SDK, lowest friction for first launch |
| ⬜ | Wire `/api/store/reserve` to actually call TEvo `/v9/orders` POST | 🟥 | Already have `evo_client.py` — just need a `create_order()` method that maps reservation → TEvo order body |
| ⬜ | Stripe checkout session creation endpoint (`/api/store/checkout`) | 🟥 | Server-side intent creation; client redirects to Stripe-hosted page |
| ⬜ | Stripe webhook handler for `payment_intent.succeeded` → finalize TEvo order | 🟥 | Idempotent (same `payment_intent.id` won't double-order). Store the cross-ref. |
| ⬜ | Refund / cancellation handling | 🟥 | `payment_intent.refunded` → call TEvo cancel; reverse our DB |
| ⬜ | Fraud / 3DS handling | 🟧 | Stripe does most of this; just need to handle `requires_action` |
| ⬜ | Remove "MVP · browse only · no real purchases" badges on all 3 HTML pages once #1-#5 land | 🟥 | `static/store/index.html:15`, `event.html:15`, `shares.html:15` |
| ⬜ | Order confirmation page (`/store/order/{id}`) | 🟥 | Shows what was bought, when tickets will arrive, contact for support |
| ⬜ | Order email (transactional) | 🟥 | Resend / Postmark / SES — receipt + delivery instructions |

---

## C. Accounts & auth

Operator said "no Google Auth needed for v1 live launch" — storefront is read-only. But to support logged-in features (order history, saved searches, alerts), this is needed:

| ⬜ | Item | Tag |
|---|---|---|
| ⬜ | Wire Google OAuth (Supabase Auth provider — easier than rolling Flask-side) | 🟧 |
| ⬜ | Add `/auth/google/callback` route | 🟧 |
| ⬜ | Session-cookie issuance + verification middleware | 🟧 |
| ⬜ | `/api/store/me/orders` — list logged-in user's orders | 🟧 |
| ⬜ | `/api/store/me/watchlist` — saved searches / events | 🟦 |
| ⬜ | Optional checkout-as-guest (no account required) | 🟧 | Important for conversion — don't force signup before purchase |
| ⬜ | Remove `ALLOWED_EMAIL_DOMAIN` gate (or document it) | 🟨 | Currently set but unused since Google Auth never plugged in |

---

## D. Trust + legal (required for any commerce site)

| ⬜ | Item | Tag | Notes |
|---|---|---|---|
| ⬜ | Privacy policy page (`/privacy`) | 🟥 | Required by GDPR/CCPA for collecting any email/PII. Free generators exist (Termly, iubenda). Link from footer. |
| ⬜ | Terms of service page (`/terms`) | 🟥 | Required before processing payments. Ticket-specific clauses: refund policy, event cancellation, transfer rules. |
| ⬜ | Contact / support page (`/support`) | 🟥 | Email or contact form. Stripe will ask for this URL during account verification. |
| ⬜ | About page (`/about`) | 🟧 | Stripe also wants this. Brief company description, location. |
| ⬜ | Cookie consent banner | 🟧 | Only required if we add analytics/tracking. With zero 3rd-party scripts today, technically optional. |
| ⬜ | Footer links to all of the above | 🟥 | Currently `static/store/index.html:61-63` is just "VibePass · MVP preview" — needs ©, legal links |
| ⬜ | Update "MVP preview" footer text | 🟥 | Replace with real copyright + tagline |

---

## E. Observability & operations

| ⬜ | Item | Tag | Notes |
|---|---|---|---|
| ⬜ | Sentry (or equivalent) for server-side errors | 🟧 | `app.py` currently catches `RuntimeError` from TEvo but no remote reporting |
| ⬜ | Sentry browser SDK in `static/store/store.js` | 🟧 | 1862 lines unminified — bugs will happen |
| ⬜ | Uptime monitor on `/healthz` | 🟧 | UptimeRobot free tier, or BetterUptime |
| ⬜ | Synthetic test: every 5 min hit `/api/store/events?limit=3` and `/api/store/events/{known_id}` | 🟧 | Catches the same class of bug that LEM view caused |
| ⬜ | Analytics (PostHog / Plausible / Fathom) | 🟧 | Conversion funnel: search → event detail → reserve → purchase. Plausible is GDPR-friendly. |
| ⬜ | Render dashboard saved view: 4xx + 5xx response rate over 24h | 🟨 | Quick eyeball check |
| ⬜ | TEvo API call quota dashboard | 🟧 | Currently no tracking — if TEvo rate-limits us, storefront breaks silently |
| ⬜ | Status page (`/status` or status.vibepass.com) | 🟨 | Cheap signal during incidents |

---

## F. SEO + sharing

The whole site has zero social-share metadata:

| ⬜ | Item | Tag | Notes |
|---|---|---|---|
| ⬜ | OG (`og:title`, `og:image`, `og:description`, `og:url`) on `index.html` | 🟧 | Default to brand image + tagline |
| ⬜ | OG on `event.html` — populate per-event from `<title>` | 🟥 | Critical: share links posted in iMessage / Slack / WhatsApp render as a bare URL today |
| ⬜ | Twitter card meta | 🟨 | Subset of OG; one extra tag |
| ⬜ | `robots.txt` | 🟧 | Allow indexing of `/store/` and event pages; disallow `/api/` and `/store/shares` |
| ⬜ | `sitemap.xml` | 🟧 | Generated from `/api/store/events`. Submit to Google Search Console. |
| ⬜ | Per-event canonical URL | 🟧 | `<link rel="canonical">` on `event.html` to prevent dupes from filter params |
| ⬜ | Favicon | 🟥 | None exists — most browsers show a generic globe. `static/favicon.ico` + `<link rel="icon">` |
| ⬜ | Apple touch icon | 🟨 | `apple-touch-icon.png` for iOS home-screen |
| ⬜ | Page title pattern | 🟧 | Today: `VibePass — tickets`. Better: `{Event Name} tickets · {Venue} · {Date} · VibePass` for SEO |

---

## G. Performance & reliability

| ⬜ | Item | Tag | Notes |
|---|---|---|---|
| ⬜ | Minify `store.js` (1862 lines unminified ships as-is to clients) | 🟧 | Add a build step or use Render's static asset pipeline. ~50-60% size cut typical. |
| ⬜ | Cache-Control headers on static assets | 🟧 | `style.css` and `store.js` should be `max-age=31536000, immutable` with content-hashed filenames. (Interim: `?v=<sha>` query-string cache-bust shipped in PR-fixing-the-2-phase-loader-2026-05-15 — see `app.py:_read_storefront_html`.) |
| ⬜ | TEvo API response cache (Redis or in-process) for catalog queries | 🟧 | `/api/store/events` doesn't need fresh-every-request data; 60s cache acceptable |
| ⬜ | gzip / brotli compression | 🟨 | Render does this automatically — verify it's on |
| ⬜ | CDN for static assets | 🟨 | Render auto-edges everything; only matters if traffic grows |
| ⬜ | Mobile/responsive QA — test on iPhone SE, iPhone 14 Pro, mid-range Android | 🟧 | `style.css` has some `@media` queries — needs a pass |
| ⬜ | **`/api/store/home` filter variants — closes the last TEvo dependency** | 🟧 | Today the filtered home view (`?performer_id=...` or `?venue_id=...`) falls back to `/api/store/events` (TEvo-direct, ~1.5s, returns `from_price=null` cards). Extending `/api/store/home` to accept `performer_id` + `venue_id` filters lets us serve **every** storefront view from SQL in ~50ms with prices populated. Same join shape as the no-filter case + a final `IN (...)` on `events.primary_performer_id` or `events.venue_id`. Per A1 bot_chat 2026-05-15 feedback after Fix A landed: "closes the last TEvo dependency on the storefront." |

---

## H. Frontend polish

| ⬜ | Item | Tag | Notes |
|---|---|---|---|
| ⬜ | Brand logo (replace text-only `VibePass` brand in topbar) | 🟧 | SVG, ideally with dark + light variant |
| ⬜ | Loading states — "Loading available events…" is a string; consider skeleton cards | 🟨 | `index.html:53` |
| ⬜ | Empty-state copy when search returns 0 results | 🟨 | `index.html:55-57` exists but generic |
| ⬜ | Error-state when TEvo is down — graceful "Try again in a moment" | 🟧 | Today users probably see a JS console error |
| ⬜ | Seat map / venue diagram (if data available from TEvo) | 🟨 | `/api/store/events/{id}/zones` exists; surface in `event.html` |
| ⬜ | Price chart on event detail (sparkline of recent price moves) | 🟦 | Cool for power users but adds load time |
| ⬜ | Filter UI polish — section, row, quantity sliders | 🟨 | `event.html:96-97` has bare inputs |
| ⬜ | Share-link UX — "copy" feedback, expiry preview | 🟧 | `static/store/test/event.html` has a copy-pasteable pattern; promote to main |
| ⬜ | A11y audit — keyboard nav, screen-reader labels, contrast ratios | 🟧 | Some `aria-*` present but no audit done |

---

## I. PWA / mobile (deferred — flag for later)

| ⬜ | Item | Tag |
|---|---|---|
| ⬜ | `manifest.json` for "Add to Home Screen" | 🟦 |
| ⬜ | Service worker for offline event-detail caching | 🟦 |
| ⬜ | Push notifications for price drops on watched events | 🟦 |
| ⬜ | Native app shell (React Native? Capacitor wrapper of the web app?) | 🟦 |

---

## J. Out-of-scope for v1 (explicit deferrals)

The following are **deliberately not on the punch list**:

- Order management UI for sellers (we're not a marketplace v1, we're a single-seller storefront)
- Reviews / ratings system
- Multi-language / i18n
- Multi-currency
- Email marketing flow (re-engagement, abandoned-cart)
- Loyalty program
- Referral program
- Native iOS/Android apps (web-only for v1)

---

## K. Suggested execution order

Working backwards from "first real customer can buy a ticket":

1. **Sprint 1 (live-launch unblocks)** — Section A. 1-3 hrs total. Already documented in `evo_store_next_steps.md`.
2. **Sprint 2 (real purchase path)** — Section B. ~1-2 weeks. Biggest single chunk. Block on payment-processor decision.
3. **Sprint 3 (trust + legal + observability)** — Sections D + E. ~3-5 days. Necessary to plug into Stripe (they verify) and to actually catch errors in prod.
4. **Sprint 4 (SEO + sharing)** — Section F. ~2 days. Big conversion lever once we have actual share traffic.
5. **Sprint 5 (polish + performance)** — Sections G + H. Ongoing.
6. **Sprint 6+ (PWA, accounts, loyalty)** — Sections C, I, J. After v1 launches.

Don't optimize Section G (perf) before Section B (purchases) — there are zero customers to make faster yet.

---

## L. What A1 owns vs what D1 owns

This punch list is D1's lane, but several items need cross-lane support:

| Item | D1 | A1 | B1 | C1 |
|---|---|---|---|---|
| TEvo `create_order()` in `evo_client.py` | implement + use | review | sec review (PII / token leaks) | — |
| Stripe webhook handler — DB schema for orders + payments | implement | apply migration | — | review (canonical sales table) |
| Privacy / terms / about pages | author + ship | review | review (PII handling claims) | — |
| Sentry / analytics integration | implement | env var setup | review CSP impact | — |
| OG tags + sitemap | implement | — | — | — |
| Render env updates (Stripe keys, Sentry DSN) | implement (D1 owns Render) | — | — | — |

When in doubt, post a `question` in `bot_chat`. A1 will adjudicate scope/lane.

---

## M. Tracking

Open a tracking issue or use the existing KANBAN.md sections:
- Sprint 1 → existing `evo_store_next_steps.md`, will close out when live
- Sprints 2-5 → recommend a new section in `KANBAN.md` titled `RETAIL FINISH PUNCH LIST` with the 🟥/🟧 items pulled forward

Post `change_log` events to `bot_chat` as items close. Link this doc.

Owner: D1. A1 reviews on PR. C1 backs D1 for canonical-data questions (e.g. orders schema).
