# D0_BIBLE.md — Terminal build manual + D0 data reference

> **Doc version:** v1.0.0 · baseline 2026-05-28 (A1). Section-level version + bot-ref convention → [`README.md`](README.md) *Doc-writing rules*.

**Read this alongside `PROJECT_BIBLE.md` at session start.** This doc has two parts:

- **PART 1 — BUILD THE TERMINAL** (§B1–§B10): a cold-start manual. Everything a fresh engineer needs to rebuild the D0 terminal frontend from scratch — file map, fetch architecture, per-page contracts, backend surface, auth, deploy, local dev.
- **PART 2 — THE DATA LAYER** (§2–§9): what the terminal *reads*. Cross-source ID architecture, table/RPC/view inventory, freshness, ops-health surfaces, diagnostics.

D0_BIBLE owns the **cross-source ID architecture** (§3) and the **terminal build manual** (PART 1). Table/view/function *inventory* lives in `RESOURCES_BIBLE.md`; per-session rules + §3 column landmines in `PROJECT_BIBLE.md`; roster/authority in `BOT_HIERARCHY.md`.

Last updated: 2026-05-28 — PART 1 build manual added (file map, T.api fetch architecture, per-page contracts, auth, deploy chain, 6 cold-start gaps); PART 2 §4 renumbered (closed the 4f gap), §5 cross-ref fixed.

---

## 1. D0 mandate

D0 is the operator's single window into project health and trading intelligence. Two surfaces:

1. **Ops health** — visual of everything A1 monitors: cron status, 429 rates, table freshness, bot_chat feed, data source pipeline status, sync state.
2. **Trading intelligence** — event detail pages, movers index, discovery gaps, performer/venue pages with all multi-source data (EVO/SG/TD).

When D0 is "working" = the operator can open the terminal and immediately see: whether all pipelines are running, whether 429 rates are in budget, which sources are fresh vs stale, recent bot_chat activity, and navigate to any event/mover/discovery surface with live data.

**Files:** `static/terminal/*` | **Render:** `vibepass-terminal-test` (static CDN) + unified `vibepass-storefront-test` (FastAPI). See §B7.

---

# PART 1 — BUILD THE TERMINAL

> Goal of this part: a bot that has never seen the terminal can rebuild it from these sections alone. All file:line citations are against the **main checkout** `C:/VibeCode/terminal-2/`.

## B1. Build overview

The terminal is **8 vanilla-JS pages, no build step, no framework, no bundler.** Each HTML page sets `data-page` on `<body>` and loads a shared script chain that ends in one page-specific module. Two global namespaces carry everything:

- **`window.Terminal`** (built in `app.js`) — fetch wrapper + formatters. Pages alias it `const T = window.Terminal`. **There is no global `T`** — it's always `window.Terminal`.
- **`window.TerminalAuth`** (built in `auth.js`) — Supabase client + Google OAuth + session/token access.

There are **two data paths** out of the browser:

| Path | Mechanism | Used for | Auth |
|---|---|---|---|
| **Path A** | REST `T.api('/api/broker/*')` → FastAPI in `app.py` | movers, event REST fallback, performer assets, portfolio | Supabase bearer token in `Authorization` header; backend verifies against Supabase |
| **Path C** | Direct Supabase RPC `TerminalAuth.client.rpc('…')` / `.from('…')` | event page v3/v2, blind-spots, discovery gaps, performer/venue indexes, global search | Supabase session (RLS-gated); **anon/publishable key, public by design** |

*(There is no "Path B" — the A/C labels are historical. The event page uses a **Path C → Path A waterfall**: try RPC v3, fall back to RPC v2, then fall back to 5 parallel REST calls. See §B4.)*

## B2. Frontend file map (`static/terminal/`, 23 files)

**JS modules (11):**

| File | Lines | Responsibility |
|---|---|---|
| `app.js` | 145 | Core helpers: `API_BASE` resolver, `getAuthHeader`, `api()`, formatters. Exports `window.Terminal` (`app.js:140-143`). |
| `auth.js` | 145 | Supabase client + Google OAuth + `@s4kent.com` email gate. Exports `window.TerminalAuth` (`auth.js:132-143`). |
| `login.js` | 81 | Login-page state machine + post-OAuth bounce. |
| `nav.js` | 346 | Injects topbar, global search (`terminal_search` RPC `nav.js:115`), version chip, sign-out. |
| `home.js` | 413 | Landing dashboard — movers + SG blind spots. |
| `event.js` | 3489 | Event detail — charts, 7 tabs, the RPC waterfall. Heaviest module. |
| `movers.js` | 496 | Movers table (v2 index mode + legacy mode). |
| `discovery.js` | 475 | Discovery gap-alerts / blind-spots / returning-entities panels. |
| `performer.js` | 674 | Performer index + detail + ESPN + Market Carpet tab. |
| `venue.js` | 509 | Venue index + detail + Market Carpet tab. |
| `orders.js` | 50 | Doorway to the D2 orders dashboard (health ping only). |

**HTML pages (8):** `index.html` (home), `event.html`, `movers.html`, `discovery.html`, `performer.html`, `venue.html`, `orders.html`, `login.html`.
Each sets `data-page` on `<body>` and loads the chain **`lib/supabase.js → auth.js → app.js → nav.js → <page>.js`**, with two exceptions:
- `login.html` loads only `lib/supabase.js → auth.js → login.js` (no app.js/nav.js — you're not authed yet).
- `event.html` additionally loads `lib/uplot.iife.min.js` (`event.html:381`) + `lib/uplot.min.css` (`event.html:11`).

**lib/ (3):** `lib/supabase.js` (197 KB minified UMD supabase-js bundle, no source map), `lib/uplot.iife.min.js` (charting), `lib/uplot.min.css`.

**css (1):** `style.css` — shared styling for every page.

## B3. Data-fetch architecture

### `window.Terminal.api(path)` — the Path-A wrapper (`app.js:63-87`)

```
T.api(path)  →  fetch(API_BASE + path, { headers: {Accept, Authorization}, credentials, mode })
```

- **`API_BASE` resolution** (IIFE `app.js:27-42`), in priority order:
  1. `localStorage.terminalApiBase` override, if set (`app.js:28-29`)
  2. host is `localhost` / `127.0.0.1` / empty → `''` (same-origin) (`app.js:32`)
  3. hostname contains `terminal-test` → `https://vibepass-storefront-test.onrender.com` (`app.js:36-37`) — **this is the cross-origin case: the static CDN calls the FastAPI service**
  4. any other host → `''` (same-origin) (`app.js:41`)
- **Bearer injection** (`getAuthHeader`, `app.js:50-61`): primary `window.TerminalAuth.getAccessToken()` → `Authorization: Bearer <tok>`; fallback `localStorage.terminalToken`.
- **`credentials`/`mode`**: `omit`/`cors` when cross-origin, else `same-origin`/`same-origin` (`app.js:67-68`).
- **Error handling**: 401/403 throw bespoke "session expired" messages (`app.js:70-75`); other non-OK strips HTML tags from the body and clips to 80 chars (`app.js:76-84`); success returns `res.json()` (`app.js:86`).
- **All `window.Terminal` exports** (`app.js:140-143`): `setStatus, getAuthHeader, api, getEventId, fmtDate, fmtNum, fmtPct, daysUntil, latestNonNull`.

### Path C — direct Supabase RPC (`TerminalAuth.client`)

Pages call `TerminalAuth.client.rpc('fn_name', {args})` or `.from('table').select(…)` directly against Supabase. These are **RLS-gated** — the publishable key only sees what row-level security allows. Used where a SECDEF RPC already returns the exact payload (event page, indexes, blind-spots, discovery, search).

## B4. Per-page contracts

| Page (HTML / JS) | Path | Endpoints / RPCs | Backing tables/views |
|---|---|---|---|
| **Home** (`index.html` / `home.js`) | A + C | `T.api('/api/broker/movers?window_hours=…')` (`home.js:31`); rpc `get_blind_spots_sg_selling({p_min_score:2})` (`home.js:122`) | `event_movers_index`, SG blind-spot views |
| **Event** (`event.html` / `event.js`) | **C→C→A waterfall** | see waterfall below (`event.js:211-267`) | `get_broker_event_page_v2/v3`, `event_metrics`, listings, SG, TD, ESPN, weather |
| **Movers** (`movers.html` / `movers.js`) | A + C | v2 `T.api('/api/broker/movers?window_days=&source=&category=')` (`movers.js:131`); legacy `?window_hours=` (`movers.js:242`); rpc `get_blind_spots_sg_selling` (`movers.js:299`) | `event_movers_index(_history)`, `discovery_gap_alerts` |
| **Discovery** (`discovery.html` / `discovery.js`) | C | `from('discovery_gap_alerts').select().is('resolved_at',null)` (`discovery.js:73-79`); rpc `get_blind_spots_tevo_selling` (`:260`), `get_returning_entities` (`:374`); enrich via `sg_events_canonical` + `events` | `discovery_gap_alerts`, `sg_events_canonical`, `events` |
| **Performer** (`performer.html` / `performer.js`) | A + C | index rpc `get_broker_performer_index` (`:48`); detail `T.api('/api/broker/performer/{id}/assets')` + `T.api('/api/portfolio?performer_id={id}')` (`:111-112`); ESPN rpc `get_broker_performer_page({p_performer_id})` (`:355`); Market Carpet reads `event_listing_snapshot_daily`/`event_movers_index`/`discovery_gap_alerts` (`:491-508`) | `performer_metadata`, `entity_performer_map`, `espn_*`, portfolio |
| **Venue** (`venue.html` / `venue.js`) | C | index rpc `get_broker_venue_index` (`:45`); detail rpc `get_broker_venue_page({p_venue_id})` — one round-trip for 4 tabs (`:108`); Market Carpet same 3 tables (`:332-349`) | `venue_assets`, `entity_venue_map` |
| **Orders** (`orders.html` / `orders.js`) | — | health ping to `https://d2-orders-dashboard.onrender.com/healthz` (`orders.js:9,25`); **no broker API** | (D2 dashboard, separate service) |
| **Login** (`login.html` / `login.js`) | C (auth) | Supabase Google OAuth via `TerminalAuth.signInWithGoogle`; no broker API | Supabase auth |
| **(global)** `nav.js` | C | rpc `terminal_search({p_q, p_limit:6})` (`nav.js:115`) | `terminal_search` |

**Event page waterfall** (`fetchPayload(eventId)`, `event.js:211-267`):
1. **Path C v3** — `rpc('get_broker_event_page_v3', {p_event_id, p_chart_hours: V3_LOAD_HOURS})` where `V3_LOAD_HOURS = 720` (`event.js:17,220`).
2. On `isMissing` (PG `42883` / "does not exist") or `isTimeout` (`57014` / statement timeout) → **Path C v2** `rpc('get_broker_event_page_v2', …)` (`event.js:237`).
3. One more v2 retry on cold-cache timeout (`event.js:246-247`).
4. **Path A fallback** — 5 parallel `T.api()` calls (`event.js:259-265`): `/api/broker/event/{id}/overview`, `/chart-data?hours=720`, `/zones`, `/orders`, `/cadences`, reshaped by `legacyToV2Shape`.

Plus 6 parallel enrichment loaders in `init()` (`event.js:78-86`): `loadCrossSourceMetrics`, `loadWeatherLocalized`, `loadSgZonesSplits`, `loadTdSplits`, `loadCrossPlatformSales`, `loadChartExtended`.

**Discovery gap-type values** (`discovery.js:8-9`, priority map `:140-144`):
`value_gap_large` · `fill_rate_spike` · `sg_no_evo` · `td_sh_no_evo` · `td_gt_no_evo` · `td_vd_no_evo` · `td_gt_premium` · `td_vd_premium` · `td_sh_no_gt` · `evo_no_sg`

## B5. Backend surface (`app.py`)

`app.py` is a ~7900-line FastAPI monolith. The relevant pieces for the terminal:

- **Mount strategy** (order matters — static mount must be last):
  - prefix-less `include_router(...)` documented at `app.py:7879`
  - `app.include_router(d2_router)` in try/except (optional D2 dashboard) at `app.py:7886`
  - `app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")` at `app.py:7940`
- **`/api/broker/*` routes** are plain `@app.get` decorators directly in `app.py` (not a sub-router):
  - `/api/broker/movers` (`app.py:3517`; handler `broker_movers` `:3518`; v2 helper `_broker_movers_v2` `:3486`)
  - `/api/broker/event/{id}/overview` (`:2200`), `/chart-data` (`:3033`), `/zones` (`:2411`), `/orders` (`:4139`), `/cadences` (`:3737`)
  - `/api/broker/performer/{id}/assets` (`:1126`)
- **CORS** (`app.py:450-477`): `_CORS_ORIGINS` from env `CORS_ALLOWED_ORIGINS`; **default is localhost-only** (`http://localhost:3000,http://localhost:5173,http://127.0.0.1:3000`, `app.py:452`). Wildcards and non-concrete URLs are rejected at boot (`:459-470`). `allow_credentials=True`; methods `GET/POST/DELETE/OPTIONS`; headers `Authorization/Content-Type/X-Cron-Secret` (`:474-476`). **⚠ The CDN origin is not in the default — see §B10 gap #1.**
- **Security headers** (`_SecurityHeadersMiddleware`, `app.py:480`): CSP `connect-src 'self' https://*.supabase.co`.
- **Token verification** (`app.py:425-426`): backend POSTs the incoming bearer to `{SUPABASE_URL}/auth/v1/user` with the anon apikey to validate the session server-side.

## B6. Auth flow

- **Client config** (`auth.js:18-20`): `SUPABASE_URL = https://hzrizjeaxlqcxfrtczpq.supabase.co`; `SUPABASE_KEY = sb_publishable_…` (publishable/anon — explicitly commented "Public anon key — safe to embed", `auth.js:13`); `ALLOWED_EMAIL_DOMAIN = s4kent.com`.
- **`service_role` is NOT present anywhere in `static/terminal/`** (verified). The only `service_role` string in the tree is an explanatory comment in `event.js:2607`. **Never embed the service_role key client-side.**
- **createClient** (`auth.js:27-34`): `{ auth: { persistSession:true, autoRefreshToken:true, detectSessionInUrl:true, flowType:'implicit' } }`.
- **Sign-in**: Google OAuth — `signInWithOAuth({ provider:'google', redirectTo: <login.html?return=…> })` (`auth.js:94-109`).
- **Gate** (`requireAuth`, `auth.js:75-92`): localhost bypasses; no session → redirect to `loginUrl()`; session whose email domain ≠ `s4kent.com` → `signOut()` + bounce.
- **Session storage**: Supabase default (localStorage) via `persistSession:true`; the access token is surfaced through `TerminalAuth.getAccessToken()` and injected as the Path-A bearer (§B3).
- **`window.TerminalAuth` exports** (`auth.js:132-143`): `client, requireAuth, signInWithGoogle, signOut, getAccessToken, getSession, getEmail, isAllowedEmail, onReady, ready`.
- **Why the publishable key is safe**: it can only do what RLS permits. Path-C RPCs are SECDEF and gated; the storefront/terminal split keeps wholesale fields behind broker-only RPCs. The real secret (`SUPABASE_SERVICE_ROLE_KEY`) lives only in the backend env (§B7).

## B7. Deploy chain (Render)

Two services, both deploy from `branch: main`:

| Service | IaC | Type | Build / Start | Role |
|---|---|---|---|---|
| `vibepass-terminal-test` | `render-d0-terminal.yaml` | `static` | build = `echo` (no build step); `publishPath: static` (widened from `static/terminal`, PR #181); rewrites e.g. `/` → `/home/index.html` | Static CDN host. Serving cross-origin is what triggers `API_BASE` Topology-3 in `app.js:36`. **⚠ The yaml header says it is "not yet the active Render config" — the Render dashboard is source of truth for this service's headers/rewrites (§B10 gap #3).** |
| `vibepass-storefront-test` | `render.yaml` | `web` (python) | build = `pip install -r requirements.txt`; start = `uvicorn app:app --host 0.0.0.0 --port $PORT` (`render.yaml:39`); `healthCheckPath: /healthz`; plan `starter`, region `oregon` | FastAPI. Hosts D0 terminal + D1 storefront + D2 dashboard via `include_router` (testing-unified). Env: `PYTHON_VERSION=3.12.7`, `STOREFRONT_SQL_ONLY=true`, `STOREFRONT_AS_LANDING=true`, `ALLOWED_EMAIL_DOMAIN=s4kent.com`; secrets `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY`, `CRON_SECRET` (all `sync:false`). |

**Static-vs-API:** the static service just publishes `static/`. The API service runs `app.py`, which *also* mounts `/static` (so the terminal is reachable same-origin on the API host too — that's the dev/test convenience). In production the CDN serves the frontend and calls the API host cross-origin (hence the CORS requirement, §B10 gap #1).

## B8. Local dev

- **Run it**: `uvicorn app:app --host 0.0.0.0 --port 8000` — the same command Render uses. **There is no `if __name__ == "__main__"` / `uvicorn.run()` block in `app.py`** (verified absent), so `python app.py` does nothing — you must launch via uvicorn.
- **Required env vars** (`app.py:213-215`): `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY`. The backend builds its Supabase client with the service-role key (`app.py:310`).
- **Optional**: `AUTH_DISABLED=true` to bypass JWT verification in dev (`app.py:224`; ignored in prod `:240`); `CORS_ALLOWED_ORIGINS` (defaults to localhost — fine for same-origin dev).
- **Static**: FastAPI mounts `/static` from `STATIC_DIR` (`app.py:7940`); the terminal is served same-origin, so `API_BASE` resolves to `''` on localhost (`app.js:32`) and no CORS config is needed locally.

## B9. Charting (uPlot)

Loaded **only on `event.html`** (`event.html:11` css, `:381` js). Two independent uPlot instances render into `#chart-price` and `#chart-inventory` (`event.html:143-183`), each with 6h/24h/3d/7d/30d/ALL range selects. Built in `event.js`: `renderChartPrice` (`:630`), `renderChartInventory` (`:734`), Y-range guard `robustYRange` (`:711`), bar-path drawing (`:764`). Series originate from the `get_broker_event_page_v3/v2` payload's chart block (Path-A equivalent: `…/chart-data?hours=720`), mapped through `adaptChart` over `event_metrics_series` columns (`event.js:294`).

## B10. Cold-start gaps (resolved here so you aren't blocked)

1. **CORS allowlist omits the CDN origin.** Default `CORS_ALLOWED_ORIGINS` is localhost-only (`app.py:452`); `https://vibepass-terminal-test.onrender.com` is **not** included. Because the CDN serves the frontend cross-origin to the API service (`app.js:36-37`), every `/api/broker/*` call from the deployed CDN fails CORS until an operator sets `CORS_ALLOWED_ORIGINS` on `vibepass-storefront-test` to include the CDN https origin. This is a runtime-config dependency invisible from source. **Action when wiring prod:** set that env var.
2. **No app entrypoint in `app.py`.** No `__main__`/`uvicorn.run`; run via `uvicorn app:app …` (§B8).
3. **`render-d0-terminal.yaml` is not the live config** (header annotated "not yet active", `:83-87`). Treat the Render dashboard as source of truth for the static service's headers/rewrites.
4. **`lib/supabase.js` is a 197 KB minified UMD bundle, no source map, no in-tree version string.** To reproduce auth behavior (implicit flow, `detectSessionInUrl`) a rebuild must independently pin the supabase-js version.
5. **`tickpick_orders` / `vivid_orders` are unreachable from the frontend by design** — service_role-only, read through a SECDEF RPC (`event.js:2607`), never a direct table read. Know the RPC name to surface TP/Vivid sales.
6. **No TODO/FIXME/HACK markers exist in the frontend JS** — it's clean; the gaps above came from cross-file/runtime analysis, not in-code breadcrumbs.

---

# PART 2 — THE DATA LAYER

> What the terminal reads. The terminal itself is read-only against the DB (D0 never writes tables); these are the surfaces it queries.

## 2. "Check before investigating" checklist

Run these checks before spending tokens on exploratory queries. Prevents re-discovery of known architecture.

1. **Column names** → `PROJECT_BIBLE.md §3` landmines table (20+ entries). Check before any new query.
2. **Table exists?** → `SELECT relname FROM pg_class JOIN pg_namespace n ON n.oid=relnamespace WHERE nspname='public' AND relkind IN ('r','v','m') AND relname ILIKE '%keyword%'`
3. **Cross-source join?** → Source IDs are source-internal. Use `aq_event_map` as the hub. See §3 below.
4. **RPC exists?** → `RESOURCES_BIBLE.md` function inventory + `PROJECT_BIBLE.md §4` SECDEF quick-list. Never re-implement `bot_chat_log`, `cross_source_venue_resolve`, `sg_attempt_event_xref_v3`, `refresh_td_event_links`, etc.
5. **Already in a view?** → Check `RESOURCES_BIBLE.md` for `v_canonical_*`, `v_event_*`, `v_sg_*`, `v_bot_chat_*` views before writing raw SQL.
6. **Migration already shipped?** → `MIGRATION_CONVENTIONS.md` landmark-migration log. Don't re-implement work already in prod.
7. **Open drift item?** → `KANBAN.md`. If you're debugging something that looks like a known gap, check there first.

---

## 3. Cross-source ID architecture (DO NOT re-discover this)

### 3a. ID namespaces

Each source has its own independent numeric ID space. A `tevo_event_id = 3001234` means NOTHING to SeatGeek or TicketsData. Never join raw IDs across sources.

| Source | ID column | Format | Internal to |
|---|---|---|---|
| TEvo | `tevo_event_id` / `event_id` | bigint 3.0M–3.4M | TEvo only |
| SeatGeek | `sg_event_id` | bigint 17M+ | SG only |
| TicketsData (GT/VD/SH/TM) | `event_id` in `ticketsdata_event_xref` | bigint 4.5M–160M | Each platform |
| ESPN | `espn_event_id` | text | ESPN only |
| Vivid / TickPick | `vivid_event_id` / `tickpick_*` | bigint | Each platform |

**The `aq_short_event_id` landmine — same column name, two totally different systems:**

| Table | Format | System | Join target |
|---|---|---|---|
| `ticketsdata_event_xref.aq_short_event_id` | 7-char alphanumeric e.g. `K9KX32Z` | TD's cross-platform AQ | `aq_event_map.aq_short_event_id` (100% join rate) |
| `listings_snapshots.aq_short_event_id` | `SYS-{hex}` format | TEvo's internal AQ | 0% populated in practice — query by `event_id` |

**Never join these two `aq_short_event_id` columns to each other. Zero matches guaranteed.**

### 3b. `aq_event_map` — the canonical cross-source hub

`aq_event_map` is the single table that knows all platform IDs for a given event. Always go through here.

```
ticketsdata_event_xref.aq_short_event_id (K9KX32Z)
         │
         ▼  JOIN aq_event_map ON aq_short_event_id
aq_event_map (7,271 rows as of 2026-05-28)
   ├── tevo_event_id        bigint  — 2,590 populated (35.6%)
   ├── sg_event_id          bigint  — 4,434 populated (61.0%)
   ├── sh_event_id          bigint  — StubHub
   ├── vivid_event_id       bigint  — Vivid
   ├── tm_event_id          bigint  — Ticketmaster
   ├── event_name           text    — universal text name
   ├── venue_name           text    — universal text venue name
   ├── event_date           timestamp — event datetime (no timezone)
   ├── city, state          text    — location
   ├── performer            text    — primary performer/team
   ├── category             text    — sport/genre
   ├── venue_short_id       text    — AQ venue ID → aq_venue_map (tevo_venue_id, sg_venue_id)
   ├── performer_short_id   text    — AQ performer ID → aq_performer_map (tevo_performer_id)
   └── aq_source            text    — 'aq_curated' | 'system_seed'
```

### 3c. TD → TEvo resolution chain

Run in this order. Stop when tevo_event_id is found.

```
Step 1: aq_event_map.tevo_event_id              → 417/575 TD events resolved (72.5%)
Step 2: aq_event_map.sg_event_id
           → sg_events_canonical.tevo_event_id  → same 417 today; handles bridge race conditions
Step 3: sg_to_tevo_search_bridge cron runs      → fills aq_event_map.tevo_event_id over days
Step 4: refresh_td_event_links() @ 06:05 UTC    → picks up Steps 1-3 nightly
Step 5: TEXT: performer + date match            → sg_events_canonical where performer name
           matches and same calendar date       → unique because touring artists don't
                                                  double-book same day (user confirmed)
```

**Expected NULL tevo_event_id (correct, don't try to fix):**
- `venue_name ILIKE '%parking%'` → TEvo doesn't track parking lots (25 events, correct NULL)
- Event name contains "CANCELLED" → skip
- International events (Estadio Azteca, Mexico City venues etc.) → TEvo doesn't track

**`ticketsdata_event_xref.tevo_match_method` values:**
`aq_event_map` | `sg_canonical_direct` | `text_performer_date` | `pending_bridge` | `null_parking`

### 3d. Other cross-source bridges

| Bridge | Tables | How filled |
|---|---|---|
| TEvo ↔ SG | `sg_events_canonical.tevo_event_id` | `sg_to_tevo_search_bridge_30min` cron (API call to TEvo `/v9/events`) |
| TEvo ↔ ESPN | `event_xref.espn_event_id` | `match_events_to_espn_10min` cron |
| TEvo ↔ TD | `ticketsdata_event_xref.tevo_event_id` (mig 380000) | `refresh_td_event_links()` daily |
| Venue text → tevo_venue_id | `cross_source_venue_map` | `cross_source_venue_resolve(name, city, state)` fn |

### 3e. aq_venue_map and aq_performer_map

```
aq_venue_map (columns: venue_short_id, venue_name, city, state, tevo_venue_id, sg_venue_id, ...)
aq_performer_map (columns: performer_short_id, performer_name, tevo_performer_id, aliases[])
```

Join via `aq_event_map.venue_short_id = aq_venue_map.venue_short_id` to get `tevo_venue_id`.
Note: `aq_venue_map.sg_venue_id` is sparsely populated — only 2/40 unmatched non-parking events had it.

### 3f. Performer cross-source mapping chain (DO NOT re-discover this)

**Canonical ID: `tevo_performer_id` (bigint) — all performer roads lead here.**

```
tevo_performer_id
  │
  ├─ entity_performer_map      — tevo_performer_id PK, espn_team_id, espn_league,
  │                               home_venue_ids[] (tevo_venue_id[]), genre, what_event_type,
  │                               sd_performer_id, sg_performer_name (denorm shortcut)
  │
  ├─ performer_metadata        — performer_id (=tevo_performer_id), name, slug, espn_team_id,
  │                               espn_league, color_primary, color_alternate,
  │                               logo_default_url, logo_dark_url, logo_light_url,
  │                               logo_scoreboard_url
  │
  ├─ performer_external_ids    — performer_id (=tevo_performer_id), source TEXT,
  │                               external_id TEXT, external_name TEXT, league TEXT
  │                               (normalized multi-source ID store — 1 row per source)
  │
  ├─ seatgeek_performer_xref   — tevo_performer_id → sg_performer_name,
  │                               match_method, match_confidence
  │
  ├─ seatdata_performer_xref   — tevo_performer_id → sd_std_event_id, sd_performer_name
  │
  ├─ aq_performer_map          — performer_short_id → tevo_performer_id, performer_name, aliases[]
  │   Join via: aq_event_map.performer_short_id = aq_performer_map.performer_short_id
  │
  ├─ td_gt_performers          — ⚠ NO tevo_performer_id. Only: performer_url, performer_slug,
  │   (TD only)                   team_name, active. Link via event chain:
  │                               ticketsdata_event_xref → aq_event_map → tevo_event_id
  │                               → entity_performer_map / performer_home_venues
  │
  └─ ESPN bridge
      performer_espn_team_xref  — tevo_performer_id → espn_team_id, espn_league, match_method
      performer_metadata.espn_team_id (same bridge, denormalized on performer record)
      espn_athletes             — espn_athlete_id, full_name, display_name, jersey, position,
                                   espn_team_id, espn_league, status, headshot_url
      espn_teams_canonical      — espn_team_id, espn_league, display_name, abbreviation
      espn_athlete_team_history — espn_athlete_id → espn_team_id, espn_league,
                                   start_date, end_date, transaction_type
```

**Quick lookup path:**
- TEvo performer → ESPN team: `performer_metadata.espn_team_id` (fastest, denormalized)
- TEvo performer → SG name: `entity_performer_map.sg_performer_name`
- TD performer → TEvo: go through event (`ticketsdata_event_xref.tevo_event_id → entity_performer_map`)
- ESPN athlete: `espn_athletes` JOIN `espn_teams_canonical` ON `espn_team_id + espn_league`

⚠ **Always scope ESPN queries by `espn_league`** — same numeric `espn_team_id` appears in multiple leagues.

### 3g. Venue cross-source mapping chain (DO NOT re-discover this)

**Canonical ID: `tevo_venue_id` (bigint) — all venue roads lead here.**

```
tevo_venue_id
  │
  ├─ venue_assets              — tevo_venue_id PK, venue_name, city, state, is_indoor,
  │                               capacity, lat, lon,
  │                               espn_venue_id TEXT, espn_venue_name TEXT,
  │                               nws_station, nws_grid_id, nws_grid_x, nws_grid_y
  │                               (This IS the ESPN venue bridge — no separate table needed)
  │
  ├─ entity_venue_map          — tevo_venue_id, tevo_venue_name, sd_venue_id,
  │                               sg_venue_name (denorm), external_ids jsonb
  │
  ├─ seatgeek_venue_xref       — tevo_venue_id → sg_venue_name, match_method, match_confidence
  │
  ├─ seatdata_venue_xref       — tevo_venue_id → sd_std_venue_id, sd_venue_name, sd_city, sd_state
  │
  ├─ aq_venue_map              — venue_short_id → tevo_venue_id, venue_name, city, state, sg_venue_id
  │   Join via: aq_event_map.venue_short_id = aq_venue_map.venue_short_id
  │   ⚠ sg_venue_id sparsely populated (~5%)
  │
  ├─ cross_source_venue_map    — canonical_name → tevo_venue_id, sg_aliases[], tickpick_aliases[],
  │                               vivid_aliases[], seatdata_aliases[]
  │   Function: cross_source_venue_resolve(name, city, state) → tevo_venue_id
  │             (3-tier: canonical → aliases → prefix-match; 43% on unknown names)
  │
  └─ performer_home_venues     — performer_id (=tevo_performer_id) → venue_id (=tevo_venue_id),
                                  venue_name, league
      entity_performer_map.home_venue_ids[] (same link, denormalized)
```

**Quick lookup path:**
- Have tevo_venue_id → `venue_assets` (complete record: ESPN, weather, geo all in one row)
- Have text name → `cross_source_venue_resolve(name, city, state)`
- Have venue_short_id (from aq_event_map) → `aq_venue_map`
- Need ESPN venue → `venue_assets.espn_venue_id` directly — no separate ESPN venue table

---

## 4. Canonical table inventory

### 4a. Cross-source registry tables

| Table | Rows | Purpose | Key columns |
|---|---|---|---|
| `aq_event_map` | 7,271 | Cross-platform event hub | aq_short_event_id, tevo_event_id, sg_event_id, event_name, event_date, performer, venue_name |
| `aq_venue_map` | ~500 | Venue cross-reference | venue_short_id, venue_name, tevo_venue_id, sg_venue_id |
| `aq_performer_map` | ~1,000 | Performer cross-reference | performer_short_id, performer_name, tevo_performer_id, aliases[] |
| `cross_source_venue_map` | 391+ | Text name → tevo_venue_id | canonical_name, tevo_venue_id, sg_aliases, tickpick_aliases, vivid_aliases |
| `sg_events_canonical` | 4,609 | SG event catalog with TEvo link | sg_event_id, tevo_event_id, sg_event_name, sg_venue_id, sg_datetime_utc, match_method, match_confidence |
| `event_xref` | ~1,085 | TEvo ↔ ESPN bridge | tevo_event_id, espn_event_id, espn_league |

### 4b. TD-specific tables

| Table | Rows | Purpose | Key columns |
|---|---|---|---|
| `ticketsdata_event_xref` | 575 | TD event catalog with cross-source links | event_id (TD-internal), aq_short_event_id, platform, active, tevo_event_id (mig 380000), sg_event_id (mig 380000), tevo_match_method |
| `ticketsdata_listings_snapshots` | 244K | TD listing firehose | aq_short_event_id, platform, price, quantity, captured_at |

**TD ↔ TEvo linkage warning (pre-mig-380000):** `ticketsdata_event_xref.event_id` is TD's platform-native ID (4.5M–160M range), NOT tevo_event_id. After mig 380000 applied, use `ticketsdata_event_xref.tevo_event_id` directly.

### 4c. TEvo tables

| Table | Rows | Purpose | Key columns |
|---|---|---|---|
| `event_metrics` | 87,785 | TEvo listing metrics (agg) | event_id (=tevo_event_id), captured_at, retail_min/median/max, tickets_count |
| `listings_snapshots` | 8M+ | TEvo listing firehose | event_id, tevo_ticket_group_id, section, row, retail_price, is_owned, brokerage_id |
| `event_listing_snapshot_daily` | 3,054 | Daily cross-source snapshot | event_id, snapshot_date, evo_*/sg_*/td_* price+count columns |
| `event_movers_index` | ~5K | Price velocity index | event_id, source, window_days, category (+ 5 computed cols) |
| `event_movers_index_history` | ~30K | Movers history | same schema |
| `discovery_gap_alerts` | — | SG coverage gaps by market | alert_type, market, event_id |

**listings_snapshots filter:** `is_owned = true AND brokerage_id = 1768` for our inventory. `aq_short_event_id` is 0% populated — use `event_id` only.

### 4d. SeatGeek tables

| Table | Rows | Purpose | Key columns |
|---|---|---|---|
| `seatgeek_event_metrics` | 46,573 | SG listing metrics | sg_event_id, captured_at, listings_all_*/listings_owned_* |
| `seatgeek_listings_snapshots` | 9.2M | SG listing firehose | sg_event_id, broadcast_price, quantity, pulled_at |
| `seatgeek_sales_snapshots` | — | SG sales firehose | sg_event_id, sg_sale_id, broadcast_price, sale_at_utc. **MANDATORY DEDUP: DISTINCT ON (sg_sale_id) ORDER BY sg_sale_id, pulled_at DESC** |
| `sg_event_priority_state` | 4,609 | Priority tier management | sg_event_id, tier (not priority_tier!), last_polled_at |

**SG column landmines:** `seatgeek_event_metrics` uses `listings_all_min/median/p90` (not `cost_*`). `sg_event_priority_state` uses `tier` (not `priority_tier`). `seatgeek_sales_snapshots` uses `sale_at_utc` (not `sold_at`), `broadcast_price` (not `price`), `pulled_at` (not `captured_at`).

### 4e. ESPN tables

| Table | Rows | Purpose | Key columns |
|---|---|---|---|
| `espn_event_snapshots` | 6,918 | Gameday event data | espn_event_id, espn_league, game_state, home_team_id, away_team_id |
| `espn_event_date_lookup` | — | Forward-look home/away/datetime | espn_event_id, espn_league, game_at_utc |
| `espn_injuries_snapshots` | — | Player injury status | espn_athlete_id, espn_league, status, description |
| `espn_athletes` | ~857 | Player roster catalog | espn_athlete_id, full_name, display_name, jersey, position, espn_team_id, espn_league, status, headshot_url |
| `espn_teams_canonical` | ~30 | Team catalog | espn_team_id, espn_league, display_name, abbreviation |
| `espn_athlete_team_history` | — | Player trade/signing history | espn_athlete_id, espn_team_id, espn_league, start_date, end_date, transaction_type |

**ESPN landmine:** Always scope by `espn_league` — `espn_team_id = "28"` maps to BOTH MLB Atlanta Braves AND an NHL team. **Every ESPN query must include `AND espn_league = 'MLB'` (or the relevant league).** (This is RULE 1 — see `RESOURCES_BIBLE.md` event taxonomy RULES.)

### 4f. Performer tables

| Table | Purpose | Key columns | Notes |
|---|---|---|---|
| `entity_performer_map` | Primary performer catalog — most denormalized | tevo_performer_id (PK), espn_team_id, espn_league, home_venue_ids[] (tevo_venue_id[]), genre, what_event_type, sd_performer_id, sg_performer_name | **Start here** for any performer lookup |
| `performer_metadata` | Branding + ESPN link | performer_id (=tevo_performer_id), name, slug, espn_team_id, espn_league, color_primary, color_alternate, logo_default_url, logo_dark_url, logo_light_url, logo_scoreboard_url | Primary tevo→ESPN bridge for team sports |
| `performer_external_ids` | Multi-source ID store (normalized) | performer_id (=tevo_performer_id), source TEXT, external_id TEXT, external_name TEXT, league TEXT | 1 row per source; query: `WHERE performer_id=$1 AND source='sg'` |
| `seatgeek_performer_xref` | TEvo ↔ SG performer bridge | tevo_performer_id, sg_performer_name, match_method, match_confidence | |
| `seatdata_performer_xref` | TEvo ↔ SeatData bridge | tevo_performer_id, sd_std_event_id, sd_performer_name | |
| `aq_performer_map` | AQ performer → TEvo link | performer_short_id (PK), performer_name, tevo_performer_id, aliases[] | Join via `aq_event_map.performer_short_id` |
| `performer_home_venues` | Performer ↔ venue link | performer_id (=tevo_performer_id), venue_id (=tevo_venue_id), venue_name, league | Teams → home stadium |
| `performer_espn_team_xref` | Explicit tevo→ESPN bridge table | tevo_performer_id, espn_team_id, espn_league, match_method | Redundant with performer_metadata.espn_team_id but more explicit |
| `td_gt_performers` | TD performers catalog | id, performer_url, performer_slug, team_name, active | ⚠ NO tevo_performer_id — link via event chain only |

**TD performer → TEvo path (no direct bridge):** look up the event's `tevo_event_id` in `ticketsdata_event_xref` (after mig 380000), then query `entity_performer_map` for that event's performers via the `tevo_event_id` context (through `aq_event_map` → `event_xref`).

### 4g. Venue tables

| Table | Purpose | Key columns | Notes |
|---|---|---|---|
| `venue_assets` | Primary venue catalog — most complete | tevo_venue_id (PK), venue_name, city, state, is_indoor, capacity, lat, lon, espn_venue_id TEXT, espn_venue_name TEXT, nws_station, nws_grid_id, nws_grid_x, nws_grid_y | **Start here.** Includes ESPN + weather in one row. |
| `entity_venue_map` | Multi-source venue IDs (denorm) | tevo_venue_id, tevo_venue_name, sd_venue_id, sg_venue_name, external_ids jsonb | Quick SG/SeatData name lookup |
| `seatgeek_venue_xref` | TEvo ↔ SG venue bridge | tevo_venue_id, sg_venue_name, match_method, match_confidence | |
| `seatdata_venue_xref` | TEvo ↔ SeatData venue bridge | tevo_venue_id, sd_std_venue_id, sd_venue_name, sd_city, sd_state | |
| `aq_venue_map` | AQ venue → TEvo/SG link | venue_short_id (PK), venue_name, city, state, tevo_venue_id, sg_venue_id | sg_venue_id ~5% populated — don't rely on it |
| `cross_source_venue_map` | Text name → tevo_venue_id with aliases | canonical_name, tevo_venue_id, sg_aliases[], tickpick_aliases[], vivid_aliases[], seatdata_aliases[] | Use function `cross_source_venue_resolve()` |

**Venue text → tevo_venue_id:**
```sql
-- Preferred: use the existing function
SELECT public.cross_source_venue_resolve('Fenway Park', 'Boston', 'MA');

-- Manual fallback if function returns NULL:
SELECT tevo_venue_id FROM cross_source_venue_map
WHERE canonical_name ILIKE '%fenway%'
   OR 'Fenway Park' = ANY(sg_aliases)
   OR 'Fenway Park' = ANY(vivid_aliases);
```

### 4h. Ops health tables

| Table/View | Purpose | Key columns |
|---|---|---|
| `cron.job` | Cron schedule registry | jobname, schedule, command, active |
| `cron.job_run_details` | Cron execution history | jobid, runid, status, start_time, end_time, return_message |
| `v_sg_broker_429_health` | SG 429 rate monitoring | hour_bucket, total_requests, failed_429, pct_429 |
| `bot_chat` | Cross-lane coordination log | id, bot_level, bot_lane, event_type, message, created_at, resolved_at |
| `v_bot_chat_unresolved` | Open bot_chat items | Excludes rows with a `status` event reply pointing at them via in_reply_to |

**Cron health query:**
```sql
SELECT jobname, status, start_time, return_message
FROM cron.job_run_details
WHERE start_time > now() - interval '24 hours'
ORDER BY start_time DESC;
```

**bot_chat write (standing permission, no operator approval needed):**
```sql
SELECT public.bot_chat_log(
  p_level := 'data-collection',  -- bot tier, NOT severity. Valid: admin|security|supervisor|primary-sales|secondary-sales|data-collection
  p_lane := 'D0',
  p_event_type := 'change_log',   -- change_log | question | flag | status (status = closes parent thread)
  p_message := 'Description of change',
  p_related_pr := NULL, p_related_mig := '20260528380000',
  p_in_reply_to := NULL, p_meta := NULL);
```

---

## 5. Key RPCs for D0

| RPC | Purpose | Typical args |
|---|---|---|
| `get_broker_event_page_v3(p_event_id, p_chart_hours)` | Full event page payload (v3 — primary; falls back to v2). See §B4 waterfall. | event_id (tevo), 720 |
| `get_broker_event_page_v2(p_event_id, p_chart_hours)` | Full event page payload — 11 keys incl. sales_tape, weather, ESPN, SG side-by-side | event_id (tevo), 720 |
| `get_event_chart_extended(p_event_id, p_chart_hours, p_espn_home_team, p_espn_away_team)` | Time-series chart data: SG listings/owned/sales + ESPN annotations | event_id, 168, null, null |
| `get_broker_performer_index()` / `get_broker_performer_page(p_performer_id)` | Performer list / detail pages | — / performer_id |
| `get_broker_venue_index()` / `get_broker_venue_page(p_venue_id)` | Venue list / detail pages | — / venue_id |
| `get_blind_spots_sg_selling(p_min_score)` / `get_blind_spots_tevo_selling(...)` | Discovery / home blind-spot panels | 2 |
| `get_returning_entities(...)` | Discovery returning-entities panel | — |
| `terminal_search(p_q, p_limit)` | Global nav search | text, 6 |
| `refresh_td_event_links()` | Sync TD→TEvo links (5-step chain) | none |
| `auto_match_sg_canonical_v3()` | Sweep unlinked SG events through TEvo matcher | none |
| `cross_source_venue_resolve(name, city, state)` | Text venue name → tevo_venue_id | 'Fenway Park', 'Boston', 'MA' |
| `bot_chat_log(...)` | Cross-lane coordination message | see §4h |
| `cron_should_fire(jobname)` | Cron gate (wrap all cron bodies with this) | 'job-name' |

---

## 6. Views worth knowing

| View | Purpose |
|---|---|
| `_v_d0_event_index` | D0 primary event index with SG + TEvo data |
| `v_canonical_event` | Canonical event with venue/performer resolved |
| `v_bot_chat_unresolved` | Open bot_chat threads (auto-excludes status-closed) |
| `v_sg_broker_429_health` | SG 429 rate by hour |
| `v_event_weather_with_fallback` | Weather with climatology fallback — use `weather_kind` not `is_climo_fallback` |
| `latest_event_metrics` | Materialized: latest event_metrics per event (~1K rows) — use instead of scanning 8M listings_snapshots for "latest per event" |

---

## 7. Data source freshness expectations

| Source | Expected freshness | Table | Alert if stale > |
|---|---|---|---|
| TEvo listings | <15 min | `event_metrics` | 30 min |
| SeatGeek listings | <15 min | `seatgeek_event_metrics` | 1 hour |
| ESPN | <15 min | `espn_event_snapshots` | 30 min |
| TicketsData | <1 hour | `ticketsdata_listings_snapshots` | 2 hours |
| Daily snapshot | daily @ 00:00 UTC | `event_listing_snapshot_daily` | 26 hours |
| Movers index | 4×/day | `event_movers_index` | 8 hours |

**SG 429 threshold:** `pct_429 > 15%` → investigate. Pre-fix (2026-05-28) was 78%. Safe burst: ≤8 concurrent requests per cron fire (mig 350000).

---

## 8. Current cron health snapshot (2026-05-28)

| Cron | Status | Issue |
|---|---|---|
| TEvo: collect-listings-* (5 crons) | ✅ | |
| TEvo: evo_discover_new_events | ❌ | bot_chat_log called with 5th arg 'D0' — needs migration fix |
| TEvo: listings_aq_backfill_overnight | ❌ | pg_cron 120s hard limit — open KANBAN item |
| SG: sg_broker_listings_queue_5min | ✅ | |
| SG: sg_broker_listings_queue_5min_peak | ✅ | Fixed mig 350000 — burst 25→8 |
| SG: sg_blindspot_poll_5min | ❌ | deadlock on sg_event_priority_state UPDATE |
| ESPN: all 8 crons | ✅ | |
| TD: td_pull_drain, td_normalize_drain | ✅ | |
| Sweep: sweep-old-listings, sweep-old-sg-listings | ✅ | Fixed mig 360000 |
| Movers: compute-event-movers | ✅ | Fixed mig 370000 |
| TD links: refresh-td-event-links | ✅ | New mig 380000 |

---

## 9. Quick diagnostic queries

```sql
-- Cron failures in last 24h
SELECT jobname, status, start_time, left(return_message, 200) AS msg
FROM cron.job_run_details
WHERE start_time > now() - interval '24h' AND status != 'succeeded'
ORDER BY start_time DESC LIMIT 20;

-- SG 429 rate (last 6h)
SELECT hour_bucket, total_requests, failed_429, round(pct_429, 1) AS pct_429
FROM v_sg_broker_429_health
ORDER BY hour_bucket DESC LIMIT 6;

-- Data freshness across all sources
SELECT 'tevo' AS src, MAX(captured_at) AS latest, COUNT(DISTINCT event_id) AS events
FROM event_metrics
UNION ALL
SELECT 'sg', MAX(captured_at), COUNT(DISTINCT sg_event_id)
FROM seatgeek_event_metrics
UNION ALL
SELECT 'td', MAX(captured_at), COUNT(DISTINCT aq_short_event_id)
FROM ticketsdata_listings_snapshots
UNION ALL
SELECT 'espn', MAX(captured_at), COUNT(DISTINCT espn_event_id)
FROM espn_event_snapshots;

-- Open bot_chat items
SELECT id, bot_lane, event_type, left(message, 100) AS msg, created_at
FROM v_bot_chat_unresolved
ORDER BY created_at DESC LIMIT 20;

-- TD → TEvo link coverage
SELECT tevo_match_method, COUNT(*) AS n, COUNT(*) FILTER (WHERE active) AS active_n
FROM ticketsdata_event_xref
GROUP BY 1 ORDER BY 2 DESC;
```
