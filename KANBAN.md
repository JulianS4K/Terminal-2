# KANBAN.md — Terminal-2 shared work board

> **One source of truth for what's next, who's on it, and what just shipped.**
>
> - **code** owns: backend (Python, SQL, edge functions), audits, git push.
> - **design** owns: frontend (`static/*.html`, `design/*`), ships via code's proxy.
>
> **Update protocol**: append rows; don't edit other rows in place. Newest activity at the top of each column. Use the date format `YYYY-MM-DD HH:MM` (UTC).
>
> Status flow: `NEXT → DOING → BLOCKED (if stuck) → DONE`. When a NEXT row gets started, MOVE it (don't duplicate). When a DOING row ships, MOVE it to DONE with the commit SHA.

---

## DOING

### DOING (design) — Design handoff: 6 broker templates + 2 parallel-product designs (DONE — ready for review)

- **What**: Three deliverables in this session, all in `design/`:
  1. **`design/preliminary-event-views-2026-05-08.md`** — 6 broker-terminal view templates with ASCII wireframes:
     - T1 Event Workbench (single-event, the workhorse)
     - T2 Performer Console (sports + non-sports variants)
     - T3 Venue Pulse (mode-tabs: home-team / concert / comedy / other)
     - T4 Pricing Queue (`J/K` keyboard flow for re-pricing 47 events in a sitting)
     - T5 Metro Watchlist (competing-events demand-overlap)
     - T6 Series / Season / Tour Aggregator (MLB 5-game, NBA full season, 47-stop tour)
     - Plus: structural decisions on Julian's 5 questions, 11-row × 6-template simulation grid, metrics have/need audit, LLM analysis-layer slot reserved for Grok hookup, build sequence integrated with code's prior memos.
  2. **`design/retail-site-2026-05-08.md`** — public buying site at `/shop` + `/shop/event/{id}`:
     - Two-API architecture (`/api/retail/*` mirrors `/api/broker/*` with code-enforced wall via `retail_inventory_v` view)
     - Three surfaces: catalog, event detail + seat picker, chatbot side-panel integration
     - Telemetry-as-product: `retail_events` table feeds the chatbot training corpus
     - 8 retail-persona scenarios scored across site flows
  3. **`design/undelivered-window-2026-05-08.md`** — fulfillment ops view (internal only):
     - One normalizing view (`undelivered_orders_v`) across EVO + SG + Vivid + StubHub + retail + wholesale
     - Single dense ops board with default sort by time-to-event (red T-0/T-24h first)
     - Hold-expiry alert lane (separate from delivery queue)
     - Bulk action: "deliver all 76 for Knicks G5" — the highest-leverage feature
     - 9 fulfillment-scenario simulations
- **Plus 3 frontend skeleton files** (added on Julian's "build templates, frontend only" follow-up):
  1. **`static/_proposals/templates.html`** — broker terminal · 6 templates · hash-router (`#workbench` / `#performer` / `#venue` / `#queue` / `#metro` / `#series`). Each template fully laid out with placeholder data and `<span class="todo">` markers on every backend hook. Uses CSS variables matching `static/index.html`.
  2. **`static/_proposals/shop.html`** — retail buying site · 4 hash-routed views (`#catalog` / `#event/{id}` / `#cart` / `#account`). Light theme (deliberately opposite density of the broker terminal). Chatbot side-panel with bidirectional handoff. Strict wall: file references only `/api/retail/*`, never `/api/broker/*`.
  3. **`static/_proposals/undelivered.html`** — fulfillment ops board. Pinned hold-expiry banner, KPI strip, filter chips, dense board with time-to-event color coding, drawer for row click, bulk-deliver-for-event modal. Reads from `unified_orders` (the canonical view from mig 20260509140000 — supersedes the `undelivered_orders_v` placeholder I sketched in the original doc).
- **Plus 1 notes-for-code file**:
  - **`design/CODE_NOTES_2026-05-08.md`** — every backend hook the 3 skeletons assume, organized as: existing endpoints to wire / NEW endpoints to build / new tables/views proposed / wiring sequence / open questions. Designed so code reads top-to-bottom and knows exactly what to build without touching frontend.
- **Plus, after Julian's TEvo-templates ask + media-asset ask**:
  - **Rewrote `static/_proposals/shop.html`** to follow the canonical TEvo template set per the API-01..API-10 docs Julian uploaded:
    - 7 hash routes: `#home` · `#performer/{slug}` · `#venue/{slug}` · `#event/{id}` · `#search` · `#cart` · `#account`
    - Comprehensive search with typeahead dropdown (groups: Events / Performers / Venues per `/searches/suggestions`)
    - Performer LP — slug URL + showPerformer + listEvents(performer_id) per API-06
    - Venue LP — slug URL + showVenue + listEvents(venue_id) per API-07
    - Event LP — showEvent + listings(event_id), with seatmaps-client placeholder + static fallback (real Citizens Bank Park static map URL) per API-08
    - Cart/checkout flow — Client creation (nested company/email/address/phone per API-09) + Braintree drop-in mount (API-10)
    - Wall held: 0 broker-namespace references; only retail namespace.
  - **Added `design/MEDIA_ASSETS_2026-05-08.md`** mapping every available media asset (ESPN team logos, ESPN player headshots, TEvo static + dynamic seat maps, TEvo `meta.image`, S4K `venue_assets`) to each project surface. Catalogues 5 sources, then maps each surface in all 3 projects to its preferred resolve-order (S4K venue_assets → ESPN logo → TEvo meta.image → static map → gradient fallback). Includes channel-logo plan for the undelivered window (self-host wordmarks for EVO/SG/Vivid/SH).
- **Files touched (this session, all design-owned)**: `design/preliminary-event-views-2026-05-08.md` (now 6 templates), `design/retail-site-2026-05-08.md`, `design/undelivered-window-2026-05-08.md`, `design/CODE_NOTES_2026-05-08.md`, `design/MEDIA_ASSETS_2026-05-08.md`, `static/_proposals/templates.html`, `static/_proposals/shop.html` (rewritten to TEvo pattern), `static/_proposals/undelivered.html`.
- **NOT touched**: `app.py`, `evo_client.py`, `seatgeek_client.py`, `seatdata_client.py`, `supabase/migrations/*`, `supabase/functions/*`, `SCHEMA.md`, `AGENTS.md`, `static/index.html` (still has BLOCKED chart-range-switcher edits from earlier in this session — separate row).
- **Reads from**: `docs/terminal-redesign-2026-05-09.md`, `docs/historical-data-and-multi-view-strategy-2026-05-09.md`, `docs/broker-audit-2026-05-08.md`, `INSTRUCTIONS_FOR_CLAUDE_DESIGN.md`, `design/main.fig.md`. Skeletons reference the canonical state model in mig 20260509140000.
- **Git state at hand-off**: worktree HEAD = `3d55a38` (origin/main tip). Local main is 40 behind, but worktree itself is current.
- **Status**: 3 design docs + 3 frontend skeletons + 1 code-notes file ready for review. Skeletons are previewable by opening `static/_proposals/*.html` in a browser (no backend running needed for layout review).
- **Started**: 2026-05-08 (this session)

### DOING (code) — _none yet_
_(if I'm in the middle of something, it goes here so design knows what files I'm touching)_

### DONE (code) — Overnight: audit + XSS fix + 3-surface preview switcher

- **Audit of design's 2026-05-08 submission** committed at `docs/audit-2026-05-09.md`. Wall preserved, Python clean, backend healthy (21 crons, 0 failures last hour). 1 blocking finding: DOM-XSS in `shop.html` chatbot.
- **XSS fixed**: `sendChat()` + `openChat(prefill)` rewritten with `textContent` + `appendChild` via `_appendChatTurn()` helper. Inline deeplink onclick moved to `data-deeplink` + `addEventListener`.
- **3-surface preview launched** at `/preview/*` per Julian's overnight ask. 4 new app.py routes (landing, terminal, shop, ops). Sticky switcher header on every skeleton with active-route highlight. Landing page card grid links to GitHub specs.
- **No protected files touched** beyond app.py route additions + AGENTS LOG + KANBAN. Migrations / SCHEMA / clients untouched.
- **Pushed**: pending commit hash.

---

## NEXT

### NEXT (D0) — Consolidated frontend lane post row 157 reorg

Plan: [docs/d0_frontend_consolidation_plan.md](docs/d0_frontend_consolidation_plan.md). Self-contract: [docs/d0_operating_constraints.md](docs/d0_operating_constraints.md). Coordination: [docs/edit_coordination_protocol.md](docs/edit_coordination_protocol.md). 5 D0-tracked rows:

- **D0 → operator** — Supabase Auth Redirect URLs whitelist (2 URLs, dashboard action). Per `bot_chat` row 145. Unblocks PR #113 deployed login flow.
- **D0 → operator** — Render plan flip `vibepass-storefront-test` free → starter ($14/mo). Per D1 row 169 outstanding item 1. MCP `update_web_service` doesn't support plan changes — dashboard or Render REST API only.
- **D0** — Phase 2 design tokens: author `static/_shared/design-tokens.css`, refactor terminal CSS to reference it. Weeks 1-4.
- **D0** — `docs/d0_roadmap.md` (rolling Now/Next/Later/Backlog). First version covers D1+D2 outstanding items routed through D0.
- **D0 sign-off requirement on D1/D2 PRs PAUSED 7 days** (active 2026-05-22). Per operator directive `bot_chat` 170. Claim protocol + token discipline + CI gate still active.

### NEXT (D0 — checkpoint) — Phase 4 service-merge decision · review 2026-08-15

Recommend at decision time: collapse `vibepass-terminal-test` + `d2-orders-dashboard` into one operator-facing service; keep `vibepass-storefront-test` separate. Decision gates: ops MAU >50, deploy frequency stable. Cost-saver ~$14/mo at 3-service starter baseline.

### NEXT (P1 → A1) — Audit + sync storefront branch; gate live-TEvo flip behind your green light

**What**: Storefront branch `claude/store-sql-only-demo-mode` (HEAD `0901efd` as of 2026-05-12) is feature-complete for the MVP and ready for an audit pass. Asking A1 to review + sync to prod, after which we'd flip Render env `STOREFRONT_SQL_ONLY=false` to exercise the live-TEvo paths in production.

**What landed since the last sync** (all on P1's lane only — `app.py` web routes, `static/store/*`, `share_links`, and `evo_client.py` for one new read-method):

- `f7bf344` Lifecycle gate on event detail + share resolver — 404 ghost/cancelled events
- `24c252c` Context badges — rivalry, MLB series position, tournament parent
- `a820aac` Weather row + holiday pills (now-deprecated MLB series tab/page included in earlier commit, removed in `70b49ee`)
- `70b49ee` NYC movers strip + new event-list sort hierarchy (date asc · time asc · qty desc · listings desc · getin desc) + series tab teardown
- `25a9300` Playoff badge + parking tab + tagline/footer cleanup
- `0901efd` Live search dropdown — `/api/store/search` + `EvoClient.search_suggestions()` wrapper

**Why now**: All write surfaces still inside P1's lane (`share_links` table + `app.py` web routes + `static/store/*`). No new migrations. We've been read-only on `events / event_lifecycle / performer_metadata / venue_assets / v_rivalry_events / v_mlb_game_series / v_event_tournament_context / v_event_weather_with_fallback / v_event_calendar_context / v_event_velocity_windows / latest_event_metrics` per the lane map.

**How**:
1. A1 reviews the branch (audit-lane review checklist §9 of MIGRATION_CONVENTIONS.md). Particular attention requested on:
   - The new `_bulk_event_context` helper (`app.py`) — bulk reads against six views, all read-only. Verify no missed writes.
   - PostgREST `or_()` value sanitization in `_search_sql_only` (strips `, . ( ) "` before pattern build) — confirm the sanitizer is sufficient.
   - The 60s in-process search cache (`_search_cache`, 200-entry LRU). Single-instance Render dyno so process-local is fine; flag if you want Redis later.
   - `_search_live` falls through to `_search_sql_only` on TEvo failure — confirm that's the right fallback (vs. failing closed).
2. B1 syncs to prod once A1 is satisfied.
3. After B1 sync, P1 flips `STOREFRONT_SQL_ONLY=false` on Render and reports back observed live-mode latency + any TEvo 429s.

**Blocking question for A1**: any objection to enabling live mode against production TEvo on the Render test env? It's our seller account (X-Token in Supabase settings), but it does mean live writes to cron-cached `ticket_groups` payloads + fire-and-forget `collect-listings` calls (existing pattern, just exercised more often).

**Filed by**: P1 (storefront) · 2026-05-12

---

### NEXT (P1 → C1 / S1) — Notify: storefront ready for live-TEvo prod testing; flag if cross-lane interactions need coordination

**Routing note**: C1 is the data-side supervisor per `docs/bot-hierarchy.mermaid`; S1 owns the canonical schemas P1 reads from (`audit-datasets-schemas-auoc3` worktree). Filing to both — C1 for awareness, S1 for the actual go/no-go on view stability.

**What**: Heads-up that storefront is requesting permission from A1 to flip `STOREFRONT_SQL_ONLY=false` on the Render test env (see the row above). When that lands, P1's `/api/store/events/{id}` will call `/v9/events/:id` + `/v9/ticket_groups?owned=true` directly, and `/api/store/search` will hit `/v9/searches/suggestions`. Each detail hit also fires-and-forgets the audit-lane `collect-listings` edge function to refresh canonical SQL.

**Why flag C1/S1**: All of P1's reads bottom out in audit-lane / context-lane views — `event_xref`, `canonical_external_ids`, performer / venue / tournament context. If S1 is mid-flight on schema changes to any of those, live-mode reads from P1 would surface inconsistency to end users. Three reads I'd especially like S1 to confirm are stable:

- `v_event_tournament_context` — used for tournament-parent badges
- `event_xref` (indirectly via `v_event_tournament_context`)
- `v_rivalry_events` / `sporting_rivalries` — used for rivalry badges + the MLB series detection (`v_mlb_game_series` performer-name join)

**How**: S1 replies on this row with one of: (a) "all stable, go ahead"; (b) "wait until <date>, I'm refactoring <X>"; (c) "fine, but rename your reads from <old> to <new>". P1 will hold the live-mode flip until S1 signs off OR a week passes with no reply (whichever comes first).

**Filed by**: P1 (storefront) · 2026-05-12

---

### NEXT (code) — [SEC-MED] Cron command bodies hardcode the placeholder `CRON_SECRET`

**What**: Five `cron.job` rows currently ship the literal value `pick-any-random-string-and-save-it` in their `X-Cron-Secret` header inside the SQL command body (verified 2026-05-12 via `SELECT * FROM cron.job WHERE jobname LIKE '%collect-listings%'` etc.). Affected jobnames: `collect-listings-0-24h`, `collect-listings-1-7d`, `collect-listings-7-30d`, `collect-listings-30-60d`, `collect-listings-60d+`.

**Why it matters**: This is the same value already flagged in the SEC-CRIT row above as the in-code fallback. Rotating `CRON_SECRET` in Render / Supabase secrets won't help these specific cron jobs — the body of each `cron.schedule(...)` call has the literal baked in. When B1 rotates, the cron jobs would start failing auth unless these bodies are also rewritten. And before rotation, anyone who can `SELECT * FROM cron.job` (the `postgres` role + anyone with the right grants) reads the secret in plaintext.

**How**:
1. After CRON_SECRET rotation (the existing SEC-CRIT row), additionally:
2. `SELECT cron.unschedule('collect-listings-0-24h')` for each of the 5 jobs.
3. Reschedule with the new value: the body should reference the value via `vault.create_secret` / `get_app_secret('CRON_SECRET')` rather than a literal, so future rotations don't require re-touching `cron.job`.
4. Audit `cron.job` for any other secrets baked into command bodies (`SELECT command FROM cron.job WHERE command ILIKE '%pick-any-random%'` is the first sweep).

**Filed by**: P1 (storefront) · 2026-05-12

---

### NEXT (design) — orient and pick a starter task

**What**: Read `COWORKER_ONBOARDING.md` end-to-end, then pick a row below.
**Filed by**: code · 2026-05-09

---

## SECURITY BACKLOG (added by code · 2026-05-10 audit)

> Findings from the 2026-05-10 deep security audit (chat: "security chat"). Severity tags: **[SEC-CRIT]** = exploitable today, **[SEC-HIGH]** = exploitable under common conditions, **[SEC-MED]** = defense-in-depth gap, **[SEC-LOW]** = hardening. Each row keeps the standard NEXT format. Filed by code · 2026-05-10.
>
> **2026-05-11 first-pass — code fixes pushed by A1 for B1 review/sync.** 14 of the 16 entries now have landed in-code on PR #57. Operator steps required before B1 syncs to prod are listed at the top of the section below. The 2 remaining items (Supabase network restrictions, history rewrite of the leaked literal) are infra/git-ops actions that need a human and are tagged **[OPS-ONLY]** below.
>
> **2026-05-11 second-wave audit — new findings + fixes.** A1 ran a second pass across Python upstream clients, CI workflows, dependency pinning, app.py auth+logging, and a second-wave migration grep. **3 of 5 new findings landed in code in commit `<pending>`**; 2 are filed below for B1. Total 19 entries; 17 closed in-code, 4 are ops/human-judgment (the 2 from first pass + 2 new from second wave). Detail under "Second-wave findings (2026-05-11)" below.

### Second-wave findings (2026-05-11)

| ID | Severity | Status | One-liner |
|---|---|---|---|
| SW-1 | SEC-MED | LANDED | `seatgeek_client.py:495` was echoing user-controlled `order_id` + response body in `SeatGeekError`. Now: generic "HTTP {status}" message. |
| SW-2 | SEC-LOW | LANDED | `seatdata_client.py:215` gzip-decode error echoed the inner exception (which can carry partial bytes). Now: only the exception type name. |
| SW-3 | SEC-MED | LANDED | `requirements.txt` was fully unpinned — every redeploy could pull a different transitively-vulnerable version. Now: compatible-release ranges, dependabot-friendly. |
| SW-4 | SEC-LOW | LANDED | `AUTH_DISABLED` kill-switch was Railway-specific (`RAILWAY_ENVIRONMENT != production`). On Fly.io/Render/etc. the guard would silently re-arm. Now: checks 6 prod indicators. |
| SW-5 | SEC-MED | FILED | `require_auth` makes an outbound `GET /auth/v1/user` to Supabase on **every** authenticated request — a DoS amplifier against your Supabase auth quota. Fix below. |
| SW-6 | SEC-LOW | FILED | `seatdata_client.py:134` caches the bearer token in `self.session.headers` at init. Vault rotation doesn't propagate until the client reinits. Fix below. |
| SW-7 | OBS | NOTED | `v_dashboard_writes_24h` materialized view bypasses RLS by design (it's only count(*) aggregates over already-public catalog). Documented; no fix needed. |

### NEXT (code) — [SEC-MED · SW-5] Local JWT verification to remove the Supabase-auth DoS amplifier

**What**: `app.py:118-128` calls `requests.get(f"{SUPABASE_URL}/auth/v1/user", ...)` on every request that hits a `require_auth`-gated route. That's an outbound HTTPS round-trip to Supabase per request, which:
- Burns Supabase auth quota (free tier is 50k/month MAU; if you're sloppy in dev you can hit it fast)
- Couples API latency to Supabase availability
- Lets a flood of valid-JWT requests force a `502 auth check failed` outage by exhausting Supabase auth concurrency

The middleware-level rate limiter (`_RateLimitMiddleware`) caps per-IP bursts but doesn't help against distributed traffic.

**How**: Verify the JWT locally with `PyJWT` (the JWT secret is a server-side env var, separate from anon/service-role keys). Pattern:

```python
import jwt  # PyJWT
SUPABASE_JWT_SECRET = os.environ.get("SUPABASE_JWT_SECRET")  # from Supabase dashboard

def require_auth(authorization: str | None = Header(None)):
    if AUTH_DISABLED: return None
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    try:
        claims = jwt.decode(token, SUPABASE_JWT_SECRET, algorithms=["HS256"], audience="authenticated")
    except jwt.InvalidTokenError:
        raise HTTPException(401, "invalid session")
    email = (claims.get("email") or "").lower()
    if not email.endswith("@" + ALLOWED_EMAIL_DOMAIN.lower()):
        raise HTTPException(403, f"access restricted to @{ALLOWED_EMAIL_DOMAIN}")
    return {"email": email, "id": claims.get("sub")}
```

Add `PyJWT>=2.8,<3.0` to `requirements.txt`. Operator must set `SUPABASE_JWT_SECRET` env var (Dashboard → Settings → API → JWT Secret). Drops latency by ~50-100ms/req and removes the amplifier entirely.

**Trade-off**: locally-verified JWTs don't reflect revocation until they expire (default 1h). Acceptable for this app — the alternative is fetching once per JWT into a short-TTL cache (Redis or in-process), which adds complexity. If revocation-on-demand becomes critical (e.g., employee offboarding), layer a deny-list cache on top.

**Filed by**: A1 · 2026-05-11 second wave

---

### NEXT (code) — [SEC-LOW · SW-6] Refresh seatdata bearer per request so vault rotation propagates

**What**: `seatdata_client.py:134-138` bakes `Authorization: Bearer <api_key>` into `self.session.headers` at `__init__`. If `SEATDATA_API_KEY` is rotated via `vault.update_secret`, the running `SeatDataClient` instance never picks up the new value — it keeps signing with the old one until the process bounces.

**How**: Replace the eager header with a per-request auth callable, or simply read the key fresh into `headers` on each `request()` call. Pattern:

```python
def _request(self, method, path, **kw):
    headers = {**self._base_headers, "Authorization": f"Bearer {self._read_api_key()}"}
    return self.session.request(method, url, headers=headers, ...)

def _read_api_key(self):
    # Cached for 60s; falls back to vault on miss.
    if not self._cached or self._cached_at < time.monotonic() - 60:
        self._cached = self._fetch_from_vault()
        self._cached_at = time.monotonic()
    return self._cached
```

Same pattern applies to `seatgeek_client.py` (uses `?token=` query param, cached on init) and `evo_client.py` (signs per-request but reads `self.token` / `self._secret` at init). Lower priority on the latter two because their auth model differs.

**Filed by**: A1 · 2026-05-11 second wave

### B1 sync-to-prod checklist (apply IN THIS ORDER)

1. **Rotate `CRON_SECRET`** to a fresh random value. Set on Railway env, Supabase Edge Function secrets, AND seed into Supabase vault as `CRON_SECRET` (the new cron migration reads it from vault).
2. **Seed `EDGE_FN_ANON_JWT` in vault** with the current Supabase anon JWT value. The 3 cron migrations in `20260511000200` assert this exists.
3. **Set `CORS_ALLOWED_ORIGINS`** Railway env to your real frontend origins (comma-separated). Default permits localhost only.
4. **Set `CHAT_ALLOWED_ORIGINS`** Supabase edge fn secret for the same.
5. **Generate a fresh password for `coworker_readonly`** out-of-band before re-issuing. Migration `20260511000000` revokes LOGIN until you do this.
6. **Apply migrations in order**: `20260511000000`, `20260511000100`, `20260511000200`, `20260511000300`.
7. **Verify**: confirm cron jobs still tick (no Auth header failures); confirm `/api/store/share*` returns 401 to unauth callers; confirm edge functions return 401/500 to callers without `x-cron-secret`.

### Code changes landed by A1 (2026-05-11)

- `app.py`: import `hmac`, auth on store/share*, fail-closed `CRON_SECRET`, constant-time compare, AUTH_DISABLED non-prod guard, `CORSMiddleware` + `_SecurityHeadersMiddleware`.
- `supabase/functions/_shared/cron-auth.ts`: new shared `requireCronSecret` helper (fail-closed, constant-time).
- `supabase/functions/{collect,collect-listings,espn-collect,espn-rosters,wiki-collect,crawl-espn-team-assets,crawl-venues-and-performers,tevo-perf-find,seed-home-venues,bulk-add-watchlist,backfill-event-configurations}/index.ts`: wired to the shared helper. 6 were fail-open → fail-closed; 5 were unauth'd → now gated.
- `supabase/functions/chat/index.ts`: CORS allowlist via `CHAT_ALLOWED_ORIGINS`, rate-limit RPC errors fail-closed (was fail-open), per-min cap tightened 10 → 6.
- `supabase/migrations/20260511000000_security_coworker_readonly_nologin.sql`: ALTER ROLE … NOLOGIN.
- `supabase/migrations/20260511000100_security_search_path_definer_funcs.sql`: SET search_path on the 3 ESPN/asset DEFINER fns + a sweep over any others missing it.
- `supabase/migrations/20260511000200_security_anon_jwt_to_vault.sql`: vault-presence assertion + `_cron_invoke_edge_fn` helper + reschedule of 3 cron jobs without the literal JWT.
- `supabase/migrations/20260511000300_security_rls_internal_tables.sql`: dynamic `ENABLE RLS` on operational tables (queues, pull logs, crawl state, internal xref). Domain tables untouched.
- `static/store/store.js`: all `innerHTML` sinks with server/URL data converted to `textContent`/`createElement`; auto-mount via `body[data-page]`; URL params clamped (eventId, prices, qty).
- `static/store/{index,event,shares}.html`: CSP meta (no `'unsafe-inline'` scripts), X-Content-Type-Options, referrer policy, inline `<script>Store.mountX()` removed.
- `KANBAN.md` + `AGENTS.md`: leaked `CRON_SECRET` literal redacted.

### Still pending (after this PR)

- **[OPS-ONLY] Verify Supabase network restrictions / IP allowlist** — Supabase Dashboard → Database → Network restrictions. No code change possible.
- **[OPS-ONLY] History rewrite of the leaked literal** in git — needs `git filter-repo` + a force-push window. Decide whether private-repo posture makes it optional.
- **[SEC-MED] Add slowapi rate-limiter on `/api/store/*`** — left for the next pass; adds a Python dependency.
- **[SEC-LOW] Document `get_app_secret` whitelist + rotation runbook** — see `MIGRATION_CONVENTIONS.md` follow-up.
- **[SEC-HIGH] Full RLS coverage audit on domain tables** — internal/operational covered by `20260511000300`; events/performers/listings/etc. need explicit per-table policy decisions.

### B1-NEXT queue (filed 2026-05-15 by B1 monitoring charter)

Defense-in-depth follow-ups identified during the Phase-2 monitoring sweep. Each tagged `B1-NEXT-<N>` for tracking. Owner: B1 unless cross-lane noted.

> **🛡️ For the LIVE operating subset** (only OPEN items, severity-sorted, with closure protocol) → [`docs/b1_open_findings.md`](docs/b1_open_findings.md). Fixing bots: **delete your row from that doc in the same PR as your fix.** KANBAN here keeps the historical audit trail.

- **[B1-NEXT-1] [SEC-MED]** Add `current_user NOT IN ('service_role','postgres','supabase_admin')` body guard to `d2_cron_freshness()` ([supabase/migrations/20260513230300_d2_cron_freshness_function.sql](supabase/migrations/20260513230300_d2_cron_freshness_function.sql)). REVOKE/GRANT already done; this closes the missing third element of BOT_HIERARCHY.md §6. **Cross-lane to D2** — needs PR comment coordination per [LANE_DISCIPLINE.md §B1](LANE_DISCIPLINE.md).
- **[B1-NEXT-2] [SEC-LOW]** Drop the dead v1 overload of `match_to_aq_event_id` (the 7-arg form, superseded by 8-arg form in [supabase/migrations/20260515230000_matcher_v2_tier_1_5.sql](supabase/migrations/20260515230000_matcher_v2_tier_1_5.sql)). Cleanup, not security.
- **[B1-NEXT-3] [SEC-MED]** Edge function auth posture inventory (`docs/edge_function_auth_inventory.md`). 16 functions deployed; need per-function record of `x-cron-secret` enforcement vs. open vs. JWT-gated. Heavyweight per-function audit.
- **[B1-NEXT-4] [SEC-LOW]** Evaluate CodeQL / SAST for FastAPI + edge functions. Decide whether to add as a CI workflow.
- **[B1-NEXT-5] [SEC-MED]** Vault orphans check — `release_health_check()` row for `get_app_secret` allowlist entries not actually referenced in any prod fn / cron / edge-fn. Punch-list item from [docs/release-discipline.md](docs/release-discipline.md) §7.
- **[B1-NEXT-6] [SEC-LOW]** Egress payload review — sample anon-callable RPC responses for accidental wholesale/broker field exposure ([LANE_DISCIPLINE.md §D1](LANE_DISCIPLINE.md) wall rules). Periodically review `*_public` RPCs.
- **[B1-NEXT-7] [SEC-HIGH]** RLS gap on 3 tables — `cron_pause_state_20260514`, `sg_event_priority_state`, `sg_priority_policy` have `rowsecurity=false`, 0 policies, anon SELECT GRANT. Same pattern as Phase-1 `aq_venue_map`/`aq_performer_map` gap (fixed in PR #110). Author fix migration `<ts>_security_rls_gap_close_3_tables.sql`. Cross-lane: 1st table is C1's (cron pause snapshot), other 2 are A1's (SG pipeline).
- **[B1-NEXT-8] [SEC-MED]** §6 retrofit on `_health_check_pg_net_errors()` (A1's, added by PR #115). File PR comment to A1 per cross-lane patch protocol. Read-only diagnostic but defense-in-depth retrofit warranted.
- **[B1-NEXT-9] [SEC-MED]** §6 retrofit on `get_broker_event_page(integer, integer)` (A1's, added by PR #115). Body is already gated by `auth.jwt()->>'email'`; §6 guard is belt-and-suspenders. File PR comment to A1.
- **[B1-NEXT-10] [SEC-LOW]** Migration slot collision audit — `20260515300000` (3 files), `20260515320000` (2 files) collide. MIGRATION_CONVENTIONS.md §3 bump-by-30-or-50 rule not followed. Not security-class but flags discipline drift; recommend filenames be renamed to next free slots in a future cleanup PR.

### B1-NEXT — git + render monitoring expansion (filed 2026-05-15 by B1 charter §git+render)

Operator-extended mandate covers git settings + Render workspace. Initial sweep landed [`docs/git_repo_security_posture.md`](docs/git_repo_security_posture.md) + [`docs/render_security_posture.md`](docs/render_security_posture.md). Findings filed below.

- **[B1-NEXT-11] [SEC-HIGH]** Reassess history-rewrite priority on leaked `CRON_SECRET` in commit `5297739`. Original SECURITY BACKLOG item scoped assuming private repo; current `visibility: public` means rotated value is internet-readable. Operator decides: `git filter-repo` + force-push window, OR accept (value rotated, blast radius is whoever scraped between leak + rotation). Documented as G-1 in git posture inventory.
- **[B1-NEXT-12] [SEC-MED]** Enable `dependabot_security_updates` on the repo (currently `disabled`). After 2026-05-11 `requirements.txt` unpinning incident (SW-3 above), Dependabot is the right tool. Operator-only — Settings → Code security. Documented as G-2.
- **[B1-NEXT-13] [SEC-MED]** Enable `secret_scanning_non_provider_patterns` (currently `disabled`). Catches project-shape secrets like `CRON_SECRET`, `APPSCRIPT_INGEST_SECRET`. Operator-only. Documented as G-3.
- **[B1-NEXT-14] [SEC-MED]** Enable `secret_scanning_validity_checks` (currently `disabled`). Confirms whether leaked tokens are still active. Operator-only. Documented as G-4.
- **[B1-NEXT-15] [SEC-LOW]** Consider enabling branch-protection `enforce_admins` for `main` (currently `false`). Admin (`JulianS4K`) can bypass protections. Acceptable single-operator risk profile but documented for transparency. Operator-only. G-6.
- **[B1-NEXT-16] [SEC-LOW]** Consider enabling `required_signatures` for `main`. Currently `false`. GitHub-server-side commits (PR merges) make impersonation low-risk, but signing would harden against compromised local dev environment. G-7.
- **[B1-NEXT-17] [SEC-LOW]** Consider enabling Actions `sha_pinning_required`. Currently `false`. Workflows reference Actions by mutable tags (`@v4`, `@v7`). Tighten to immutable SHA pins for supply-chain hardening. G-8.
- **[B1-NEXT-18] [SEC-MED]** Verify Actions secrets are populated for `sync-check.yml` (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, optional `SUPABASE_PAT`). `gh api .../actions/secrets` returned empty at sweep — could be permission-filtered, could be unset. If unset, sync-check fails silently. Operator confirms next session.
- **[B1-NEXT-19] [SEC-LOW]** Render `ipAllowList: 0.0.0.0/0` on `d2-orders-dashboard` and `vibepass-terminal-test` — both supposed to be `@s4kent.com` authenticated at app layer. Optional secondary defense: tighten allowlist to known operator IPs. PR comment to D1 (Render-write authority). Documented as R-1.
- **[B1-NEXT-20] [SEC-LOW]** Render services `autoDeploy: yes` from `main` on every commit. Standard CD; consider manual approval gate for `vibepass-storefront-test` (public retail). PR comment to D1. R-2.
- **[B1-NEXT-21] [SEC-LOW]** Slack surface monitoring — operator decision on installing a Slack MCP. Currently no active Slack integration in the repo (gitleaks catches `xoxb-*`/`xoxp-*` tokens via push-protection; no Slack-posting workflows; no webhooks). Future state: with Slack MCP, B1 monitors workspace admins, 2FA enforcement, recent-message search for incident leaks. Without MCP, B1's Slack coverage is grep + gitleaks only. See `docs/b1_operating_constraints.md` "Slack posture monitoring" section.

### B1-NEXT — Librarian / archivist role (filed 2026-05-16 per operator directive)

Operator extended B1's mandate 2026-05-16: "communication channel, Librarians and archivists and maintaining bible(s) so communication between bots is seamless and up to date." Operationalized in `docs/b1_operating_constraints.md` "Librarian / archivist role" + per-session sweep steps 15-16.

- **[B1-NEXT-24] [SEC-LOW]** Periodic full-pass drift audit of `PROJECT_BIBLE.md` §3 (canonical RPC table) — verify all 32 listed RPCs exist in `pg_proc` with the signatures stated. Rotating quarterly cadence; first pass at session start. Tracked here separately from per-session sweep step 15 (which is per-session rotating spot-check).
- **[B1-NEXT-25] [SEC-LOW]** Periodic full-pass drift audit of `RESOURCES_BIBLE.md` §1 (external services) — verify Render service IDs match `mcp__render__list_services`, vault secret names match `get_app_secret` allowlist, lane ownership rows match `BOT_HIERARCHY.md`. Rotating quarterly.
- **[B1-NEXT-26] [SEC-LOW]** `bot_chat` thread-closure rate dashboard — query for `(count(resolved) + count(status-closed)) / count(total flag+question)` by lane over rolling 7d. File flag if any lane closure rate < 50%. Could be added as a row in `release_health_check()` (`coordination.thread_closure_rate_7d`).
- **[B1-NEXT-27] [SEC-LOW]** Cross-bible consistency check (PROJECT_BIBLE.md vs LANE_DISCIPLINE.md vs BOT_HIERARCHY.md). Lane ownership rows, push restrictions, write-surface declarations should align across the three. Periodic full diff.
- **[B1-NEXT-28] [SEC-LOW]** Slack channel signal-quality metric — once interactive Slack MCP loads in B1 sessions, per-channel message rate + dormancy + scheduled-task vs human post ratio. Threshold-based alerts on signal degradation.
- **[B1-NEXT-29] [SEC-MED]** §6 retrofit on `public.refresh_sg_broker_sales_event_metrics(integer)` — SECDEF, anon EXECUTE, no body guard, no shared-secret gate. Drives hourly `:17` cron populating `seatgeek_event_metrics.sold_*`. Defense-in-depth (cron callers are service_role; primary mitigation is grant model). Filed by B1 in 2026-05-16 drift sweep after testing-unified architecture landed. Cross-lane to A1 — PR comment on the originating migration.
- **[B1-NEXT-30] [SEC-MED]** §6 retrofit on `public.sg_seller_orders_queue(p_pages integer, p_statuses text)` — SECDEF, anon EXECUTE, no body guard. SG seller-side ingest queue. Defense-in-depth. Cross-lane to A1/D2 — PR comment on originating migration.
- **[B1-NEXT-31] [SEC-MED]** §6 retrofit on `public.get_broker_event_page_v2(p_event_id integer, p_chart_hours integer)` — SECDEF, anon EXECUTE, body-gated by `auth.jwt()->>'email'` (D0 Phase 2a primary RPC per PROJECT_BIBLE.md §4). §6 guard is the second belt; body is the primary mitigation. Cross-lane to A1 — PR comment on PR #150 (a1/d0-phase2a-event-page-v2).
- **[B1-NEXT-32] [SEC-CRIT] ✅ CLOSED** by A1 PR #174 (2026-05-16 21:48 UTC). `requireCronSecret(req)` added to `match-sg-performers-to-tevo` Deno.serve top. Original finding: anon JWT + caller-controlled `limit` (1-200) drove paid TEvo `/v9/performers/search` calls.
- **[B1-NEXT-33] [SEC-HIGH] ✅ CLOSED** by A1 PR #174 (2026-05-16 21:48 UTC). `requireCronSecret(req)` added to `why-noaa-weather-alerts` POST handler. Original finding: unbounded `why_signals` INSERTs via service-role.
- **[B1-NEXT-34] [SEC-MED] ✅ CLOSED** by A1 PR #174 (2026-05-16 21:48 UTC). `espn` edge function wildcard CORS replaced with explicit allow-list (terminal-test, storefront-test, d2-orders-dashboard, localhost dev) + `vary: Origin` header. Original finding: `access-control-allow-origin: *`.
- **[B1-NEXT-35] [SEC-LOW]** Create scheduled task `b1-war-games-rotation` per `docs/war_games_playbook.md`. Cadence proposal: every 4h (avoids :00 and :30 collisions; full 10-scenario rotation completes in ~40h). Posts to `#terminal-2-admin` on findings, silent on clean runs. Operator decision required (Slack MCP tool approval + cron creation). Until task is created, war-games rotation runs via per-session sweep step 19 (manual rotation).
- **[B1-NEXT-36] [SEC-MED] MERGED** Cron heartbeat detector added to `release_health_check()` via migration `20260516230000_security_release_health_cron_heartbeat.sql` ([PR #176](https://github.com/JulianS4K/Terminal-2/pull/176), merged 2026-05-16 23:25 UTC). Closes D0 audit proposal B1.2 (bot_chat 251). New helper `_health_check_cron_heartbeat()` flags any ACTIVE cron whose `last_success > 3× median inter-run interval (last 7d)`. Self-tuning — no schedule parsing required. Catches daily-cadence crons that silently fail to fire (existing `subhourly_jobs_silent_90min` row only watches sub-hourly schedules). Prod-apply gated on operator per lockdown (file in main but `apply_migration` not yet called).
- **[B1-NEXT-37] [SEC-LOW]** Backfill `cron_policy` rows for the 4 daily collect-listings windowed crons (`1-7d`, `7-30d`, `30-60d`, `60d+`). Current `cron_gate_decisions` shows decision=`fire_no_policy` because no policy row exists for them. Default-fire behavior works but defense-in-depth would add daily-max-fires + work-check-sql + interval-min limits. Cross-lane to A1 (cron_policy owner).
- **[B1-NEXT-38] [SEC-MED] ✅ CLOSED** by mig `20260517170000_sg_broker_sales_views_security_invoker.sql` (applied as version `20260517210624`). Both views now have `reloptions=["security_invoker=true"]`; `release_health_check.views.security_definer_views` row cleared. Original finding filed 2026-05-17 ~02:30 UTC via PR #188 + bot_chat 275.
- **[B1-NEXT-39] [SEC-MED]** War-games W-3 (storefront egress probe, 2026-05-17 21:50 UTC): `/api/store/search?q=yankees` exposes `we_own` (bool) + `owned_tix` (count) — semantically equivalent to forbidden `is_owned` per LANE_DISCIPLINE.md §D1 wall rules. `/api/store/events` schema includes the fields but values are null (TEvo-direct route). `/api/store/movers`, `/api/store/near` clean. May be intentional storefront-product behavior (broker storefront sells own inventory; "we have tickets!" UX badge). Filed bot_chat 308 to D0/D1 for product-intent clarification — if intentional, add carveout to LANE_DISCIPLINE.md §D1; if not, filter columns from response. Cross-lane to D0/D1.

### NEXT (code) — [SEC-CRIT] Rotate the leaked `CRON_SECRET` value, then redact from KANBAN/AGENTS

**What**: The `CRON_SECRET` value was committed in plaintext to `KANBAN.md` (lines 87, 90, 91 below this block) and discussed in `AGENTS.md`. It is in git history (commit `5297739` and prior). Anyone who clones this repo today reads the production cron secret.

**Why it matters**: With the cron secret an unauthenticated attacker can call `/api/admin/collect-orders` and similar cron-gated routes (also several edge functions that share the same secret), triggering paid TEvo / SeatGeek pulls and writes against `evo_orders` etc.

**How**:
1. Generate a new random value (32+ bytes): `python -c "import secrets; print(secrets.token_urlsafe(32))"`.
2. Set it in Railway env (`CRON_SECRET`) AND in Supabase Edge Function secrets (`supabase secrets set CRON_SECRET=...`) AND update the SQL of the relevant `cron.schedule` jobs (the body is in pg_cron — needs an update via `cron.unschedule` + reschedule).
3. Redact the value from `KANBAN.md` and `AGENTS.md` (replace with `<rotated; in vault>`).
4. Decide on history rewrite. If the repo is private to the trusted set forever, leaving history alone may be acceptable; otherwise plan a `git filter-repo` purge + force-push window.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-CRIT] Rotate `coworker_readonly` Postgres password (placeholder shipped in migration)

**What**: Migration `20260509460000_coworker_readonly_role.sql:24` creates the `coworker_readonly` role with `PASSWORD 'CHANGE_ME_BEFORE_HANDOFF'`. If the migration ran against prod and the post-handoff rotation didn't happen, that's the live password. Anyone with the public repo + a reachable Supabase Postgres host can `psql -U coworker_readonly` and read the entirety of `public.*`.

**How**:
1. Connect as superuser, run `ALTER ROLE coworker_readonly WITH PASSWORD '<new strong value>'`.
2. Re-deliver the new password to the UI coworker out-of-band.
3. Add a follow-up migration that drops the placeholder pattern: never embed credentials in DDL again. Use `vault.create_secret` or a `\set` script applied separately.
4. Verify by attempting login with `'CHANGE_ME_BEFORE_HANDOFF'` and confirming it's rejected.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-CRIT] Add auth to `/api/store/share*` endpoints (write + revoke + list are open)

**What**: In `app.py`:
- `POST /api/store/share` (line 3764) — no auth. Anyone can spam-create share links.
- `DELETE /api/store/share/{share_id}` (line 3881) — no auth. **Anyone with a share_id can revoke it**, including by enumerating from the list endpoint below.
- `GET /api/store/shares` (line 3897) — no auth. Lists every share row (event_id, filters, notes, view counts).

The handler comment at line 3774 explicitly acknowledges this is open as MVP. Risk before any sign-in flow lands: a single curl loop deletes every share link in the DB.

**How**: Wrap the three endpoints with `_=Depends(require_auth)` (mirrors the pattern at `app.py:94`). For the public read path `GET /api/store/share/{share_id}` (line 3840) — keep open since the share id is the unguessable cap (72 bits of entropy).

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-CRIT] Fix fail-open `CRON_SECRET` in app.py + 5 edge functions

**What**: Multiple components default to a weak/empty value when `CRON_SECRET` env var is unset:
- `app.py:2708` — `CRON_SECRET = os.environ.get("CRON_SECRET", "pick-any-random-string-and-save-it")`. If env unset and an attacker guesses the placeholder string, they pass auth.
- `supabase/functions/{collect,collect-listings,espn-collect,espn-rosters,wiki-collect}/index.ts` — pattern `if (expected && req.headers.get("x-cron-secret") !== expected) { reject }`. If `CRON_SECRET` env is unset, `expected` is undefined, the guard is skipped entirely → endpoint is fully open.
- `supabase/functions/crawl-espn-team-assets/index.ts:24` — hardcoded fallback string (same shape).

**How**: Replace each with fail-closed: `if (!expected) return 500; if (header !== expected) return 401`. Use a constant-time compare (Python: `hmac.compare_digest`; Deno: `crypto.subtle.timingSafeEqual`).

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-CRIT] DOM-XSS in `static/store/store.js` (multiple `innerHTML` sinks with server data)

**What**: ~20 `innerHTML` writes in `static/store/store.js` build HTML strings from server-returned and URL-derived values. Hot spots: lines 88, 90, 227, 231, 272-293, 331-343, 395, 399, 475-482, 633-634, 761, 795-807. Some use `escapeHtml()` correctly; the pattern is fragile and at least one path mixes URL params (`zones`, `section`) into the chip rendering. The retail HTML project ships these to public buyers — once a single attribute breaks the escape, it's reflected XSS.

**How**: Repeat the fix already done for `shop.html` chatbot (commit overnight): replace innerHTML with `textContent` + `appendChild`. Build chips/modals via `createElement` rather than template strings. Keep `escapeHtml()` only for genuinely opaque data, and audit each remaining call.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-HIGH] Add `SET search_path` to 3 SECURITY DEFINER functions

**What**: `supabase/migrations/20260508140000_espn_team_and_venue_assets.sql` declares `get_event_assets_public()`, `get_performer_assets_public()`, and `get_venue_assets_public()` as SECURITY DEFINER without `SET search_path`. This is the canonical Postgres privilege-escalation vector: a caller can prepend a malicious schema and intercept any unqualified function/table reference.

**How**: Add `SET search_path = public, pg_temp` to each function definition (new migration, or `ALTER FUNCTION ... SET search_path = ...`). Audit `pg_proc` for any other DEFINER functions added since: `SELECT n.nspname, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.prosecdef AND NOT 'search_path' = ANY(p.proconfig)`.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-HIGH] Audit RLS coverage on `public.*` tables (~120 tables without `ENABLE ROW LEVEL SECURITY`)

**What**: 141 `CREATE TABLE` statements across 159 migrations; only 20 have `ENABLE ROW LEVEL SECURITY`. The Supabase default GRANT model means anon role can already SELECT/INSERT/UPDATE/DELETE on any public table without RLS — the JWT for that role is published in 3 cron migrations and is also ambient on the FastAPI `/api/public/config` endpoint. Net: any reader of the repo gets anon-level direct PostgREST access to anything not RLS-gated.

**How**: 
1. Enumerate prod state — `SELECT schemaname, tablename, rowsecurity FROM pg_tables WHERE schemaname='public' AND NOT rowsecurity;`.
2. Categorize: (a) operational/internal that should never be reachable by anon → REVOKE from anon and authenticated; (b) public catalog data → ENABLE RLS + add explicit `FOR SELECT TO anon USING (true)` policy; (c) user-scoped → ENABLE RLS + per-user policy.
3. Run `mcp__supabase__get_advisors lint` for the security set; it'll flag this category.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-HIGH] Verify Supabase network restrictions (IP allowlist / Supavisor)

**What**: Repo doesn't tell us whether the Supabase Postgres host is reachable from the public internet on 5432. Combined with the (previously) leaked `coworker_readonly` placeholder password, this is the difference between "exploitable from any IP today" and "needs a foothold first".

**How**: Supabase dashboard → Project Settings → Database → "Network restrictions" / "Connection pooling" → add an allowlist for Railway egress IPs + your home IPs. Document the policy in `docs/`. If the project must remain open, mitigation moves entirely to "passwords + RLS must be hardened first".

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-HIGH] Lock down `chat` edge function (CORS `*` + LLM cost DoS)

**What**: `supabase/functions/chat/index.ts:38` returns `Access-Control-Allow-Origin: *` on a public POST that calls Anthropic via `resolveSecret(db, "anthropic_api_key", ...)`. An unauthenticated caller from any origin can drive arbitrary prompt costs against your account. The `chat_rate_limits` table exists (migration `20260507000001`) but isn't checked before the LLM call in this code path.

**How**: (a) require Bearer JWT (anon-key Supabase JWT is fine as a baseline; RLS on `chat_messages` does the actual gating); (b) call the rate-limit RPC before `llmCall`; (c) restrict `Access-Control-Allow-Origin` to the known frontend origin(s) — wildcard with credentials is invalid anyway.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-HIGH] Move the anon JWT out of cron migrations into vault

**What**: `supabase/migrations/{20260507000024,20260508016000,20260508240000}*.sql` hardcode the Supabase anon JWT in the `cron.schedule` body. This makes the JWT visible to anyone with `SELECT` on `cron.job` (e.g., `coworker_readonly` does NOT have it today, good — but any future read role might). It also locks rotation to a migration cycle.

**How**: Store the JWT in `vault.secrets` (use the existing `upsert_app_secret` whitelist, after expanding it to include `EDGE_FN_ANON_JWT`). In the cron body, read it via `(SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='EDGE_FN_ANON_JWT')`. Drop the literal from the migration files (history rewrite optional — anon JWT is semi-public per Supabase model, so this is mostly hygiene).

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-HIGH] Replace `AUTH_DISABLED` env kill-switch with a non-prod guard

**What**: `app.py:42` reads `AUTH_DISABLED` env var; `app.py:101` short-circuits `require_auth` to return None when set. A Railway misconfiguration or copy-paste from local `.env` flips the entire FastAPI surface to anonymous.

**How**: Replace the env check with `if AUTH_DISABLED and os.environ.get("RAILWAY_ENVIRONMENT") != "production":`. Better: remove the flag entirely and use a local-only `.env.local` with mock credentials.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-HIGH] Auth-gate the rest of the unauth'd edge functions

**What**: `crawl-venues-and-performers`, `tevo-perf-find`, `seed-home-venues`, `bulk-add-watchlist`, `backfill-event-configurations` have no CRON_SECRET / Bearer check. Each is reachable on its public Functions URL. They mutate state (seeding, backfills) or hit paid upstreams (TEvo).

**How**: Add the standard `x-cron-secret` check (the fail-closed version per the related row above) to each. If a function should ONLY run from an authenticated UI, switch to JWT verification via `supabase-js` createClient with the user's JWT.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-MED] Add CSP headers + CORS allowlist to FastAPI

**What**: No `CORSMiddleware` is registered in `app.py` — relying on browser SOP for cross-origin defense. None of the served HTML (`static/store/index.html`, `event.html`, `shares.html`) carries a `Content-Security-Policy` meta. Inline `<script>Store.mountCatalog()</script>` exists in `index.html:45-46`.

**How**: 
- Register `CORSMiddleware` with an explicit allowlist (Railway prod URL + localhost during dev).
- Add a small middleware that emits `Content-Security-Policy: default-src 'self'; script-src 'self'; img-src 'self' data: https:; connect-src 'self' https://*.supabase.co https://api.anthropic.com; frame-ancestors 'none'` plus `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`. Move inline scripts to external files to keep `'unsafe-inline'` out of `script-src`.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-MED] Constant-time `CRON_SECRET` comparison

**What**: `app.py:2713` and the edge functions use `==` / `!==` on the cron secret. Practical timing-attack exploitability is low over public networks but is a free hardening.

**How**: `hmac.compare_digest(x_cron_secret, CRON_SECRET)` in Python; `crypto.subtle.timingSafeEqual` (after wrapping both in `TextEncoder` byte arrays of equal length) in Deno.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-MED] Add rate limiting on FastAPI public routes (store/* + login)

**What**: No app-level rate limit on `/api/store/*`, `/api/public/config`, or the auth-burning `/api/config` (which validates the Supabase JWT every request via an outbound `requests.get` — itself a DoS amplifier against Supabase auth).

**How**: Add `slowapi` (FastAPI-native) keyed by IP, default `60/minute` for `/api/store/*`, lower for the share-create + revoke routes.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-MED] Bound numeric URL/query params in store.js

**What**: `static/store/store.js` lines 145, 173-175 coerce `eventId`, prices, qty via `Number()` with no upper/lower bound. Edge cases (`Infinity`, very-large ints) propagate to API calls and DOM text.

**How**: Clamp to sane bounds (`eventId 1..1e9`, `min_price/max_price 0..1e6`, `min_qty 1..50`). Reject non-finite values with a user-facing error.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-LOW] Add SRI + clickjacking hardening on retail HTML

**What**: `static/store/{index,event,shares}.html` reference `/static/store/style.css` without `integrity`. Pages have no `X-Frame-Options` / `frame-ancestors` (covered if the CSP entry above lands).

**How**: Generate SHA-384 hashes for `style.css` + `store.js` and add `integrity="sha384-..." crossorigin="anonymous"`. The CSP `frame-ancestors 'none'` covers iframe embedding.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — [SEC-LOW] Document the `get_app_secret` whitelist + rotation runbook

**What**: `get_app_secret`/`upsert_app_secret` are correctly whitelisted (good), but the whitelist is implicit in the function body and grows every time a new upstream lands. There's no place to look up "which secrets exist, who can read them, last rotated when".

**How**: Add a `vault.secret_metadata` view (name, last_rotated_at, owner) and a section in `MIGRATION_CONVENTIONS.md` that requires every new vault secret to add itself to the whitelist + this metadata table in the same migration.

**Filed by**: code · 2026-05-10

---

### NEXT (code) — Set Railway CRON_SECRET to unblock EVO orders — VALUE REDACTED 2026-05-11

**Status**: superseded by the [SEC-CRIT] rotation row at the top of SECURITY BACKLOG. The original literal value was redacted from this row on 2026-05-11 (security chat) — see git log for the audit trail. Do NOT re-introduce the literal into source. Recipient: get the rotated value out-of-band from Julian.

**How** (operational, no secret in source):
- Railway dashboard → terminal-2-production service → Variables → add/update `CRON_SECRET=<rotated value, out-of-band>`
- OR `railway variables set CRON_SECRET=<rotated value, out-of-band>` if using the CLI
- After setting, redeploy is automatic; next cron tick (≤ 10 min) starts ingesting

**Verify**: `SELECT COUNT(*) FROM evo_orders` 30 min after redeploy — should be > 0.

**Why this is on the board**: design surfaced it during the 2026-05-08 Supabase data-reality pass. It's been the persistent action item from `docs/audit-2026-05-09.md` §5 item 1. Several design surfaces (Undelivered Window, Event Workbench order book strip, Pricing Queue) need EVO orders to feel populated.

**Filed by**: design · 2026-05-08

---

### NEXT (code) — Backfill SG event xref to TEvo

**What**: SeatGeek has 186 distinct SG events with orders in our DB but only 0-1 are TEvo-xref'd today. SG also has 25 distinct SG events with seller listings, only 1 xref'd. Most existing SG data is invisible at the event level.

**How**: name+venue+date matching from `seatgeek_orders` + `seatgeek_seller_listings` against `events`. Likely 80%+ matchable via fuzzy name + exact venue + date-equals.

**Companion task — same pattern for SeatData** (`seatdata_event_xref` is also 1 event today; SD has 254 sales for that event but more SD pulls are coming).

**Why**: unlocks `unified_orders_by_event` for the entire SG-covered book. Currently every event-level order panel shows zero SG orders even when they exist.

**Filed by**: design · 2026-05-08 (per data-reality-2026-05-08.md)

---

### NEXT (design) — Order status uses unified vocabulary now

**What**: New `unified_orders` + `unified_orders_by_event` views (mig 20260509140000) collapse EVO + SG seller-direct + SeatData into a single rowset with 6 canonical states (`pending` / `accepted` / `substitution` / `rejected` / `cancelled` / `fulfilled`). Two flags carry alongside: `is_terminal` (state won't change), `is_sale_succeeded` (only `fulfilled`).

UI surfaces that should use this:
1. **Event hero "order book strip"** — render counts in canonical buckets (pending / accepted / fulfilled / rejected+cancelled / substitution) regardless of which source they came from. Add a small badge per source within each bucket if the user wants to drill in.
2. **Movers panel** — the "Read" classifier should consider `unified_orders_by_event.fulfilled` count vs `in_flight` count. Strong fulfilled momentum + low in-flight = supply about to dry up.
3. **Sale pipeline page** (Page 6 in the redesign memo) — shows 5 canonical buckets with rows from all 3 sources blended into each.

**Why**: Brokers don't think in "EVO completed vs SG fulfilled vs SG delivered". They think "did the sale go through". The canonical states model that.

**Backend ready**: yes. `SELECT * FROM unified_orders_by_event WHERE tevo_event_id = X;` returns per-source per-canonical-state counts + gross.

**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Companion strategy at docs/historical-data-and-multi-view-strategy-2026-05-09.md

**What**: Second strategy memo extending the redesign. Covers:
- 4 historical-data layers (event / performer / venue / matchup), each answering different broker questions
- Buyer sentiment composite (formula + 5 visual options) — backed by new `event_sentiment` table
- Similar-event matching — new `find_similar_events(event_id, n)` SQL function returns ranked comparables
- Micro→macro view spectrum (10 zoom levels)
- Web vs PWA differences (same data, different consumption pattern)
- Schema additions made live: `matchup_xref` (445 matchups seeded), `event_sentiment`, `performer_baselines` (72), `venue_baselines` (67)

**Why**: Mandate was "tell me ideal views and how to incorporate ALL the data". This is the answer for historical depth + sentiment + similar-event intelligence + the phone form factor.

**Verified live**:
- Sentiment composite separates bullish (Knicks G5 +54, Pistons-Cavs G3 +100) from bearish (Wolves-Spurs G5 -34)
- Similar-events for Knicks G5 returns G7/G2/G1 (perfect 2.0 score), G6/G4/G3 (1.6), Finals games (1.0)
- Matchup table groups 13 Yankees-Orioles, 13 Yankees-Blue Jays, 11 Red Sox-Yankees, 7 Knicks-76ers

**Read both memos as a pair**:
1. `docs/terminal-redesign-2026-05-09.md` — what 7 pages to build
2. `docs/historical-data-and-multi-view-strategy-2026-05-09.md` — how to incorporate historical/sentiment/similar/PWA

**Filed by**: code · 2026-05-09

---

### NEXT (design) — TERMINAL REBUILD per docs/terminal-redesign-2026-05-09.md

**What**: User mandate — **rebuild `static/index.html` from scratch** based on what the data actually supports. The full design memo is at `docs/terminal-redesign-2026-05-09.md` and includes:
- 7 page templates (Home / Event detail / Performer / Movers / Cross-source explorer / Order book / Settings)
- 9 findings from data simulations on actual prod data
- Build sequence (Event detail first, then Home, then Movers, etc.)
- Visual conventions, deletion list, open questions

**Why**: Prior `static/index.html` accumulated 3,000+ lines over many iterations. The data shape is now clearer (sports-first, owned_premium_pct should be top-line KPI, mover classification is missing). Cleaner to start fresh than refactor.

**Headliner finding**: `owned_premium_pct` (S4K asks vs competitor asks for the same event) varies from −32% to +255% across our book. It's the single most actionable broker metric and isn't surfaced anywhere right now. Make it the biggest number on the event page.

**Top of the build queue**: Page 2 (Event detail) — that's where 80% of broker time goes. Ship that first with the new owned-premium KPI; the rest follows.

**Backend coverage** (what's already there to support this):
- 822 active sports events with rich tracking (avg 48 snapshots, 7 days price history)
- Cross-source entity maps for clean translation (`entity_event_map`, `entity_performer_map`, `entity_venue_map`)
- All metrics tables populated (TEvo `event_metrics`, `seatgeek_event_metrics`, `seatdata_event_stats`)
- Order books from both TEvo and SG seller-direct
- Lifecycle classifier filters ghost events automatically

**Files**: `static/index.html` (rebuild), referencing endpoints in `app.py`. New endpoints to add are listed in §4 of the redesign memo (5 new routes).

**Filed by**: code · 2026-05-09

---

### NEXT (design) — Cross-source data coverage badge on event hero

**What**: New view `cross_source_event_audit` returns one row per TEvo event with: ESPN id, SeatData event_id + sales_count, SG event_id + listings count + active tickets, EVO orders, lifecycle status. Render this as a 4-light coverage badge on the event hero ("TEvo · ESPN · SeatData · SG"), each light lit per source linked. Plus a popover showing actual counts.

Plus three new chart series powered by `seatgeek_event_metrics`:
- `SG_Cost_Median` (line, $-axis) — our wholesale cost percentile
- `SG_Active_Tickets` (bar, count axis) — our active SG inventory
- `SG_Sold_Quantity` (bar, count axis) — sold SG history

**Why**: At a glance brokers see "we have 3-source coverage on this event" vs "TEvo only — no comp data". Drives decisions about which events deserve deeper attention.
**Backend ready**: yes — view + metrics table both populated by master cascade every 2 min.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — SeatGeek Seller Direct: S4K inventory + sales overlay

**What**: SG Seller Direct integration is live (commit *pending*). Cron `seatgeek-seller-collect-10min` (jobid 41) pulls 1000 listings + paginated orders every 10 min from `sellerdirect-api.seatgeek.com`. Every row carries inline event metadata, so `seatgeek_event_xref` auto-fills via fuzzy match.

UI surfaces to add:
1. **"S4K on SG" panel on event hero**. `GET /api/seatgeek/event/{tevo_id}/seller-listings` returns our active SG listings for the event with summary (count, tickets, median cost). Show as a small dense panel: "S4K SG: 12 listings · 47 tix · median cost $89".
2. **Realized SG sales chart series**. `GET /api/seatgeek/event/{tevo_id}/seller-orders` returns persisted orders with state breakdown. Add a new chart series `SG_Orders_Confirmed` (bar, hourly) — direct visibility into our SG sales velocity, parallel to TEvo's evo_orders.
3. **Cross-source sale comparison**. Combine: TEvo evo_orders (our TEvo sales), SG seller_orders (our SG sales), SeatData sales (whole-market sold comps), TEvo evo asks (current asks), SG seller_listings asks. That's 5 series for a single event — dense but each has a distinct color/dash convention.
4. **Auto-link status badge**. `GET /api/seatgeek/seller-status` reports auto-link rate. Surface on a settings page: "SG events seen: N, auto-linked to TEvo: M". When auto-linked stalls or fails, badge goes amber.

**Why**: This is the deepest data we have. SG Seller Direct gives us OUR actual transactions on SG, not market-wide aggregates. Combined with TEvo /v9/orders we now have the full S4K sales pipeline on both marketplaces.
**Backend ready**: yes — cron firing every 10 min, 200 listings + 400 orders already persisted from initial test pulls.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — SeatGeek BROKER DATA: marketplace listings + sold-comp overlay

**What**: SG integration is now the **broker** data API (not public). Three high-value UI surfaces:
1. **SG marketplace overlay** on the chart workbench. `GET /api/seatgeek/event/{id}/listings?latest_only=true` returns ALL secondary listings on the SG marketplace (when v2 was used). Plot as a scatter overlay alongside TEvo asks — gives brokers cross-marketplace visibility (TEvo asks vs SG marketplace asks).
2. **SG sold-comp panel** on the event hero. `GET /api/seatgeek/event/{id}/sales` returns transacted broadcast (wholesale) prices. Pair with SeatData's retail-side sold prices — together that's the full "what's actually clearing" view.
3. **Match button + manual link**. Broker API has no search endpoint. Show a "Link to SeatGeek" button when `seatgeek_event_xref` is empty; opens a small input that POSTs `/api/seatgeek/event/{tevo_id}/link?sg_event_id=N`. The user pastes the SG event_id from their SG broker portal (or any SG URL) once per event.
4. **"We are the marketplace" indicator**. `seatgeek_listings_snapshots.is_broker_owned=true` flags listings posted by THIS account. Surface as a badge: "S4K is N of M listings on SeatGeek".

**Why**: SeatGeek + TEvo + SeatData together give us 3-source coverage. SG is the only source that exposes BOTH our listings AND competitor listings on the same marketplace. The `sglid` (SeatGeek Listing ID) gives us cross-source listing linkage if we ever want to compare the SAME listing across exchanges.
**Backend ready**: yes — `POST /api/seatgeek/event/{tevo_id}/link?sg_event_id=N` then `POST /sync-listings` (with `?v2=true` for full marketplace) and `POST /sync-sales`.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — EVO orders: hero strip + chart series + e-ticket alerts

**What**: TEvo `/v9/orders` is now ingested every 10 min into `evo_orders` + `evo_order_items`. Three UI pieces unlock high-impact broker workflows:

1. **Order-book strip on event hero** — compact 5-segment bar showing pending / accepted / rejected / completed / pending_substitution counts pulled from `GET /api/broker/event/{id}/orders`. Click → side panel with the raw rows.
2. **Chart series `EVO_Orders_Completed`** — bar chart on `yC` axis, hourly buckets. The purest signal of demand for our specific inventory.
3. **E-ticket fulfillment alerts** — top-of-dashboard red banner if any item has `eticket_available=true AND eticket_downloaded_at IS NULL` for an event within 48h. The whole dashboard should pulse red until it's cleared.
4. **Hold-expiry alerts** — yellow badge on event tiles where `hold_expires_at < NOW() + 1h`.

**Why**: We've been flying blind on our own order book. Brokers waste time reconciling between the TEvo dashboard and our terminal; this brings the order state inline with the pricing data they're already looking at. The e-ticket alerts in particular catch deliverability misses BEFORE the buyer complains.

**Backend ready**: yes — cron jobid 40 firing every 10 min as of `<sha pending>`. `GET /api/broker/event/{id}/orders` returns `{ items, orders, summary: { total_items, by_state, tickets_sold, gross_sold, last_update_at } }`.
**Reference**: `docs/data-sources-terminal-uses.md` §5 has all 7 UI ideas worked out.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Render SeatData sales overlay on the chart workbench

**What**: SeatData integration is live (commit *pending*). For any TEvo event linked to SeatData, `/api/seatdata/event/{tevo_event_id}/sales` returns up to 5000 historical sale rows: `{sale_timestamp, quantity, price, zone, section, row}` plus an aggregated `summary: {avg, median, min, max, tickets_total, zones, first_sale, last_sale}`.

UI surfaces:
1. **Chart workbench** — add a new togglable series category "SeatData_Sales" (paint as scatter dots, not line). Each dot is a transacted sale; size = quantity, color = zone. Hover tooltip shows `$price · qty · section · row`. Y-axis = `y$` (same as TEvo prices).
2. **Event hero** — small badge "SeatData: 254 sales · median $668 · last sold 14m ago" pulled from the summary. Click opens a side panel with the sale list.
3. **Sync button** — manual "Refresh sales" button on the event page that POSTs `/api/seatdata/event/{id}/sync-sales` (charges 1 pull). Disable with tooltip if `/api/seatdata/budget` says budget is exhausted.
4. **Splash for unlinked events** — when `/api/seatdata/event/{id}` returns `linked:false`, show a "Match this event to SeatData" button that POSTs `/auto-search`.

**Why**: TEvo gives us asks; SeatData gives us actual transactions. Brokers price against transacted comps, not asks. This is the most actionable signal we've added since the chart workbench itself.
**Backend ready**: yes — Knicks G5 (TEvo 3345925) is pre-populated with 254 rows for visual testing.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Render event lifecycle status badge

**What**: Backend now classifies every event as `active | ghost_eliminated | completed | postponed | cancelled` via the new `lifecycle` block in `/api/broker/event/{id}/overview` and `lifecycle` field on each event in `/api/portfolio`. UI surfaces that need treatment:
1. **Event hero** (top of event detail page): show a colored badge if `lifecycle.status !== 'active'`. Suggested colors: `ghost_eliminated` = dim red, `completed` = neutral gray, `postponed` = amber, `cancelled` = solid red. Include `lifecycle.reasons[0]` as a small subline.
2. **Watchlist row + Movers list**: small dot or strikethrough on rows where the event is non-active. Tooltip shows the reason.
3. **Portfolio header**: when `inactive_excluded_count > 0`, show "N ghost events hidden" with a "Show all" link that re-fetches with `?include_inactive=true`.

**Why**: 18% of future events in our system are ghosts (eliminated playoff brackets). Without this badge a broker can scan the watchlist and waste time triaging events that won't happen. Knowing at-a-glance which events are actually playable is critical.
**Backend ready**: yes — the lifecycle data is live as of `<sha pending>`. Just consume it.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Splits inventory panel needs a glance-readable design

**What**: The chart already exposes `splits_min_q`, `splits_pct_pairs`, `splits_pct_singles`, `splits_with_singles..4plus`. The event page has a Splits Inventory panel but it's currently a bare table. Redesign to make "what splits are out there RIGHT NOW" answerable in <2 seconds.

**Why**: Splits are the difference between "this listing is buyable" and "this is a 6-pack only stadium tier" — brokers need to triage at a glance.
**Files**: `static/index.html` (search for "Splits Inventory")
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Event hero needs a "TIL EVENT" countdown

**What**: Top of event page shows home/away logos, venue, date. Add a prominent days-hours-minutes countdown to game time, color-shifted as it gets close (>14d gray, 7d-14d soft, 1d-7d accent, <24h hot). Updates live in-page.

**Why**: Time-to-event drives the entire collect-listings cron tier (20m / 1h / 4h / 12h / daily) — brokers think in event-proximity, the UI should too.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (design) — Watchlist 3-tab needs a sort persistence story

**What**: Watchlist tabs (mine / movers / gametime) lose sort state on tab switch. Persist `sortBy` + `sortDir` per tab in localStorage with versioned key.

**Why**: Brokers customize sort by tab (mine = my-positions-by-cost-basis; movers = absolute change; gametime = chronological). Forcing them to re-pick on every tab is annoying.
**Files**: `static/index.html`
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Update get_performers_by_league RPC to filter ghost events

**What**: `/api/broker/performers/by-league/{league}` now accepts `?include_inactive=` but the underlying SQL RPC (`get_performers_by_league`, mig 20260508050000) aggregates over ALL events including ghost playoff brackets. Rewrite the RPC to JOIN against `event_lifecycle` and exclude `is_active=false` rows when the new `p_include_inactive` arg is false.

**Why**: A team like Boston Celtics gets aggregate `home_events=8` from all the speculative Round 2/3/Finals home games even though they're eliminated. Should be `home_events=2` (the actual played games). Currently the API response includes `_inactive_filter_applied: false` so the frontend can flag the discrepancy.

**Files**: `supabase/migrations/<new>.sql` + matching update in `app.py` to pass through `p_include_inactive`.
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Investigate listings_snapshots index for zone backfill timeout

**What**: `backfill_stale_zone_metrics` has been timing out at 120s pre-cascade. Check whether `(event_id, captured_at, is_ancillary)` index exists. Add if missing. Re-run a 50-batch test to confirm we can fold zone backfill back into the master cascade.

**Why**: Currently zones runs on a separate slower cron (jobid 39, batch=5) which is below historic throughput. An index could let us collapse it back into the 2-min cascade.
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Replace league→slug CASE with a lookup table

**What**: `auto_link_event_xref` currently has a hardcoded CASE mapping NBA→`basketball/nba`, NFL→`football/nfl`, etc. Create a `league_slug` table; reference it from the function.

**Why**: SeatGeek migration will need multi-source slug mapping. Hardcoded CASE blocks that.
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Fix `is_baseline` detection in espn-collect

**What**: NBA/NFL/MLS/WNBA/WC always return `is_baseline=true` from `espn-collect.roster`. Only MLB+NHL detect changes correctly. Means injury-change overlays only render markers for 2 of 7 leagues.

**Why**: User reported NBA injuries didn't show as overlays. Root cause is upstream content_hash logic skipping the change-detection branch for those 5 leagues.
**Files**: `supabase/functions/espn-collect/index.ts`
**Filed by**: code · 2026-05-09 (carried over from prior session)

---

### NEXT (code) — Extend `espn-collect.gameday` scope to MLS/NHL/NFL/WNBA/WC

**What**: Currently only iterates NBA + MLB events. Means MLS/NHL/NFL/WNBA/WC have full performer-level coverage but ZERO event-level snapshots/xref. ~80% of the cross-league data gap.
**Files**: `supabase/functions/espn-collect/index.ts`
**Filed by**: code · 2026-05-09

---

### NEXT (code) — Capture 6 MCP-applied migrations into prod migration ledger

**What**: 6 migrations (20260508220000 through 20260509040000) have been applied via Supabase MCP `execute_sql` and captured as files in `supabase/migrations/`, but the prod migration ledger doesn't list them. Run `supabase db push` (or equivalent) to reconcile.

**Why**: Drift detection (sync-check.sh) flags this on every run.
**Filed by**: code · 2026-05-09

---

## BLOCKED

### BLOCKED (design) — Polish the chart range switcher

- **What**: Removed `color` from the `.rng` transition (was the source of the activate flash); added `[` / `]` keyboard stepping (one-shot global listener that respects input focus and clamps at the ends); added a Chart.js crosshair plugin + switched the tooltip to `mode:'index'` so all visible series values render at the snapped x; added a relative-time `title` callback ("3h ago", "yesterday 4 PM", "Apr 24") replacing the long ISO.
- **Files touched (already on disk, not yet reviewed/committed)**: `static/index.html`
  - CSS: ~lines 88-101 (`.rng` transition + new `:focus-visible` outline)
  - JS keyboard wiring: ~lines 1726-1755 (`_wireRangeKeyboard` + call from `_wireRangeButtons`)
  - JS chart helpers: ~lines 1830-1888 (`_formatRelativeTime`, `_evtChartCrosshair` plugin)
  - JS tooltip config: ~lines 2065-2080 (`mode:'index'` + `title` callback)
  - JS chart constructor: ~lines 2147-2151 (register `_evtChartCrosshair` locally, not globally)
- **Blocker**: paused by Julian — hold review/commit until he gives the go-ahead. File edits remain in the worktree; nothing has been pushed.
- **Started**: 2026-05-09 02:15 UTC
- **Flagged by**: design · 2026-05-09

---

## DONE (last 10)

### DONE — `<sha pending>` · feat: cross-source order status mapping (unified vocabulary)
- Mig 20260509140000 adds order_status_xref (13 mappings, 6 canonical states), canonical_order_status() RPC, unified_orders view (254 SD fulfilled + 200 SG accepted + 200 SG fulfilled live), unified_orders_by_event rollup, order_status_coverage diagnostic. Caught and fixed seatgeek_sales_snapshots vs seatdata_sales_snapshots typo during build. SCHEMA v19. Future sources (TickPick, Vivid Seats) just add xref rows + UNION branch.
- by: code · landed: 2026-05-09 04:30 UTC

### DONE — `005e3c0` · feat: matchup index + buyer sentiment + baselines + similar-events finder
- See AGENTS LOG for details.
- by: code · landed: 2026-05-09 04:00 UTC

### DONE — `<sha pending>` · feat: cross-source entity maps (universal id translator)
- 3 views (entity_event_map / entity_performer_map / entity_venue_map) translate any source's id to all others, TEvo as hub. 6 translation functions (forward + inverse, both directions). taxonomy_xref table seeded with 12 league/type mappings (NBA, MLB, etc.). cross_source_coverage diagnostic view. Live coverage: 269/1233 events on ESPN, 37 multi-source performers, 21 SG-linked venues. All round-trips verified. Mig 20260509120000. SCHEMA v17.
- by: code · landed: 2026-05-09 03:30 UTC

### DONE — `e7e680f` · feat: SG metrics + xref + cascade + RULE 2 read-only
- Mig 20260509110000. New tables: seatgeek_performer_xref (102 auto-linked from listings/orders), seatgeek_venue_xref (21), seatgeek_event_metrics (28 cols parallel to event_metrics + seatdata_event_stats). New views: seatgeek_categorized_listings, cross_source_event_audit. Smart matcher fix prevents ghost-event mismatches (Lynx→Timberwolves bug fixed). master_cascade_2min extended with SG xref + metrics stages (1.7s total runtime). RULE 2 read-only enforcement at code level (HTTP method allowlist in evo/seatdata/seatgeek clients). Cross-source audit shows Knicks G5 with TEvo+ESPN+SeatData coverage (3 sources, 254 sales). SCHEMA v16.
- by: code · landed: 2026-05-09 03:15 UTC

### DONE — `c3762f5` · feat(seatgeek): seller-direct ingest with auto-xref via inline event metadata
- Added 2nd SG broker host (`sellerdirect-api.seatgeek.com`). Probe revealed /listings (157,846 active S4K), /orders?status= (496K fulfilled lifetime), /order single. Migration 20260509100000 adds seatgeek_seller_listings + seatgeek_orders + order_tickets + pull_log + sg_attempt_event_xref RPC + seatgeek_orders_by_event view. Each row carries inline event metadata → fuzzy match to TEvo on (date, venue) auto-fills xref. Live test: page-1 listings = 200 rows, 25 distinct SG events, 2 auto-linked to TEvo. Cron seatgeek-seller-collect-10min (jobid 41) every 10 min, pulls 5×200 listings + 4 status filters of orders. Page=N is deprecated; client uses page_cursor pagination. SCHEMA v15.
- by: code · landed: 2026-05-09 03:00 UTC

### DONE — `089c9a8` · refactor(seatgeek): scrap public-API, rebuild for BROKER DATA API
- v13 used wrong host (api.seatgeek.com/2 with ?client_id=). Token is actually for brokerdata.seatgeek.com with ?token=. Mig 20260509090000 drops 5 unused tables, rebuilds around event_xref/listings_snapshots/sales_snapshots/pull_log + event_latest view. Client + 6 routes rewritten for /listings, /v2/listings, /sales (purchases scope unavailable). Live diag: 400 "No event found" on bogus event_id (auth pass), 401 on /purchases (covered by TEvo /v9/orders). SCHEMA v14.
- by: code · landed: 2026-05-09 05:00 UTC

### DONE — `4c9641f` · feat(seatgeek): integration scaffolded — section_info + recommendations + xref
- 3rd data source. Metadata + discovery only (no pricing). Mig 20260509080000 adds `seatgeek_event/venue/performer_xref`, `seatgeek_taxonomies`, `seatgeek_event_sections`, `seatgeek_recommendations`, `seatgeek_pull_log`, `upsert_app_secret(name, value)` RPC. New `seatgeek_client.py` covers all 9 SG endpoints. 6 new `/api/seatgeek/*` routes. Awaiting SEATGEEK_API_TOKEN push to Vault before live test. SCHEMA bumped to v13.
- by: code · landed: 2026-05-09 04:30 UTC

### DONE — `914d846` · feat: vault for keys + SeatData↔TEvo mapping + EVO orders 10-min cron
- (a) Supabase Vault stores `SEATDATA_API_KEY`; `get_app_secret(name)` RPC reads it. seatdata_client uses vault by default. (b) New cross-source xref tables (venue/performer/zone/section) + `normalize_sd_listing()` function + `sd_sales_normalized` view fixing the SeatData quantity-null caveat. (c) TEvo `/v9/orders` ingested every 10 min: `evo_orders`, `evo_order_items`, `evo_orders_by_event` view; cron jobid 40. New routes: `POST /api/admin/collect-orders`, `GET /api/broker/event/{id}/orders`. EvoClient gained `list_orders`/`iter_orders`/`get_order`. (d) Bucket 18 added to taxonomy. Comprehensive memo at `docs/data-sources-terminal-uses.md`. Mig `20260509070000`. SCHEMA v12.
- by: code · landed: 2026-05-09 04:00 UTC

### DONE — `0582fac` · feat(seatdata): integration live + Knicks G5 sales pulled (254 rows)
- New second-source pricing API alongside TEvo. Hard-capped to BASIC plan budget (100/day, 2000/month) at the DB level. New `seatdata_client.py` + 7 `/api/seatdata/*` routes. Live-tested on TEvo 3345925: matched to sd_event_id=1247184, pulled 254 historical sales (median $668, avg $773, range $378-$3,756). Mig `20260509060000`. SCHEMA v11. **User action required**: set `SEATDATA_API_KEY` env var on Railway.
- by: code · landed: 2026-05-09 03:00 UTC

### DONE — `dc4c41d` · feat(events): lifecycle classifier sorts ghost playoff games out of live surfaces
- New SQL fn `derive_event_lifecycle(event_id)` + view `event_lifecycle`. Status enum `active | ghost_eliminated | completed | postponed | cancelled`. Strongest signal: TEvo `last_seen` staleness (live=avg 1.0h, ghost=avg 133h, zero overlap). Wired into `/api/broker/event/{id}/overview` (lifecycle block), `/api/broker/movers` (`?include_inactive` defaults false), `/api/portfolio` (per-event lifecycle + `inactive_excluded_count`). Distribution: 1045 active / 95 completed / 89 ghost / 2 postponed / 1 cancelled. Mig `20260509050000`. SCHEMA bumped to v10.
- by: code · landed: 2026-05-09 02:30 UTC

### DONE — `<sha pending>` · feat(cron): cascading 2-min freshness model
- 6 individual freshness crons collapsed into `master-cascade-2min` (jobid 38). ESPN injury/trade cadence 10m → 2m. Worst-case event coverage staleness 50m → 2m. Verified runtime ~150-200ms per tick. Side-fixed `auto_link_event_xref` NOT NULL bug. SCHEMA bumped to v8.
- by: code · landed: 2026-05-09 00:55 UTC

### DONE — `<sha pending>` · fix(chart): pin x-axis to range_meta + Robinhood-style transitions
- Backend now returns `range_meta: {hours, since, until}`. Frontend pins Chart.js x-axis explicitly to that window so 30d view doesn't collapse to 24h when newer series have sparse history. Auto-picks time unit (hour/day) by range. Smooth fade between ranges. Active range button uses `.rng.active` class.
- by: code · landed: pending push (this commit)

### DONE — `999ad3f` · feat(cron): cascading freshness migration committed
- See above for details.
- by: code · landed: 2026-05-09 00:55 UTC

### DONE — `27e20bd` · feat(chart): new default series + bar chart type for quantity
- by: code · landed: 2026-05-08 ~23:30 UTC

### DONE — `c58d6a4` · feat(schema): SCHEMA.md v6 + RULE 1 + midnight sweep cron
- by: code · landed: 2026-05-08

### DONE — `c8af9b8` · fix(chart): range buttons toggle active state via CSS class
- by: code · landed: 2026-05-08

---

## Reference — column conventions

- **NEXT** rows include: What, Why, Files (if known), Filed-by + date.
- **DOING** rows include: What, Files touched (with line range estimate), Status, Started timestamp.
- **DONE** rows include: commit SHA, subject line, by-whom, landed timestamp.
- **BLOCKED** rows: copy of the original DOING content + a `**Blocker**:` line + by-whom-flagged.

If a row sits in DOING for >2 days untouched, code's audit pass surfaces it as a stuck-work flag.
