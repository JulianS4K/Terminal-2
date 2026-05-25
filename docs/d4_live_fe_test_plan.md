# D4 / Bridge — live FE test plan (ticket lifecycle)

**Purpose:** an executable, click-by-click test of the Bridge ticket lifecycle on the **live** site. Written because the Claude-on-the-web *sandbox* browser can't run it here (see "Environment prerequisite"); this plan is ready to run wherever the browser has network + an authenticated session.

## Why this can't run from the D4 cloud sandbox
The sandboxed Chromium (chrome-devtools MCP) is behind this environment's egress allowlist, which covers package registries + the git proxy + `localhost` only. Every app host returns **`Host not in allowlist`**:

| Host | Purpose | Sandbox result |
|---|---|---|
| `*.up.railway.app` | Bridge shell (primary) | ❌ blocked |
| `*.onrender.com` | Bridge shell (Render) | ❌ blocked |
| `hzrizjeaxlqcxfrtczpq.supabase.co` | data + auth | ❌ blocked |

D0/D1 ran their live Chrome-DevTools QA (PRs #330, #332) because **their** environments were provisioned with egress to these hosts. The server-side MCP tools reach Supabase (they run outside the sandbox); the browser does not.

### Environment prerequisite (to run this in a sandbox)
Provision the Claude-on-the-web environment with a network policy that allowlists `*.up.railway.app`, `*.onrender.com`, and `hzrizjeaxlqcxfrtczpq.supabase.co`
(https://code.claude.com/docs/en/claude-code-on-the-web). **Even then**, signed-in steps need a session — the live app uses Supabase **Google OAuth**, which a headless browser can't complete. So:
- **Public/browse steps (1, 6 view)** → runnable in an egress-enabled sandbox.
- **Signed-in / data-editing steps (organizer + wallet + scan)** → run in **your own authenticated browser via Claude for Chrome**, where the OAuth session already exists.

## Live URLs
- Bridge (Railway primary): `https://glorious-appreciation-production-a6ce.up.railway.app/bridge/`
- Bridge (Render): `https://vibepass-storefront-test.onrender.com/bridge/`
- Organizer dashboard: `…/bridge/dashboard` · Create event: `…/bridge/create-event` · Scanner: `…/bridge/checkin/:eventId`

## Test script — organizer + attendee lifecycle
Run as an **organizer** account that owns (or can create) an org. Two browser profiles (or two accounts) make the transfer step realistic: **A = organizer**, **B = attendee**.

| # | Actor | Action | Expected result |
|---|---|---|---|
| 1 | A | Sign in (Google) at `/bridge/`; open `/bridge/dashboard` | Dashboard loads; orgs listed; no console errors |
| 2 | A | Create event (`/bridge/create-event`): title, date (tomorrow), venue, 1 tier, `total_tickets` + per-account limit | Saves; redirects to dashboard; event appears as **draft** |
| 3 | A | Open the event in EditEvent → **Mark as published** | Banner flips to **published**; public `/event/:id` now loads it |
| 4 | A | On the event page, use the admin **TEST mint** (or **issue ticket to email** = B's email) | Ticket minted; counter increments; mail queued |
| 5 | A | `/my-tickets` → open the ticket → **wallet pass** | Rotating QR renders + refreshes (~30s bucket); ticket shows `active` |
| 6 | A | From the ticket, **Transfer** → enter B's email; try to scan it now | Transfer pending; ticket **locked**; door scan → "in-transfer" refusal |
| 7 | B | Open the claim link / `/claim/:id`; **Claim** | Ownership moves to B; B's `/my-tickets` shows it; A's no longer does |
| 8 | A | (organizer) `/bridge/checkin/:eventId` → scan A's **old** screenshot QR | ❌ rejected (secret rotated on claim — screenshot is dead) |
| 9 | A | Scan **B's** current wallet QR | ✅ admitted; ticket → `used`; appears in the lane's checked-in list |
| 10 | A | Scan the same ticket again | ❌ "used" (double-scan blocked) |
| 11 | A | Mint a 2nd ticket → **void/refund** it → scan it | ❌ "voided" |
| 12 | — | Marketing: accept the cookie banner; confirm org pixels load (Network: `fbevents.js`/`gtag`/TikTok) only **after** accept; socials render on `/o/:slug` | Consent gate honored; pixels fire post-consent; social links present |

### What to capture at each step
- Console: zero uncaught errors (the recently-fixed spinner + consent-link bugs are regression guards).
- Network: data calls hit `…supabase.co/rest/v1/…` with 2xx; no `Host not in allowlist`.
- The barcode payload format `T-{ticketId}:{ownerId}:{bucket}:{hmac}` and its ~30s rotation.

## Backend cross-check (already done, in this sandbox)
Every transition above is verified at the SQL/RPC layer on a branch — 41/41 scenarios + the full single-ticket lifecycle (mint→wallet→transfer→claim/rotate→scan→double-scan→void) all green. So a live failure here points at an **FE wiring/UX** issue, not backend logic.
