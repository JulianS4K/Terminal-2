# D0 terminal — build manual (on-demand reference)

> **Not a session-start bible** (moved out of the canonical set 2026-06-19; the own-bible model was retired — bots don't pre-know their lane). Read this **only when building/modifying the D0 terminal frontend**. The cross-source ID architecture that used to live here (PART 2 §3) is now canonical in **`PROJECT_BIBLE §5`**; table/view/cron inventory in **`RESOURCES_BIBLE`**; rules + column landmines in `PROJECT_BIBLE §3`.

Cold-start manual to rebuild the D0 terminal frontend from scratch — file map, fetch architecture, per-page contracts, backend surface, auth, deploy, charting, seat map.

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
| **Path A** | REST `T.api('/api/broker/*')` → FastAPI in `routers/broker.py` | movers, event REST fallback, performer assets, portfolio | Supabase bearer token in `Authorization` header; backend verifies against Supabase |
| **Path C** | Direct Supabase RPC `TerminalAuth.client.rpc('…')` / `.from('…')` | event page v3/v2, blind-spots, discovery gaps, performer/venue indexes, global search | Supabase session (RLS-gated); **anon/publishable key, public by design** |

*(There is no "Path B" — the A/C labels are historical. The event page uses a **Path C → Path A waterfall**: try RPC v3, fall back to RPC v2, then fall back to 5 parallel REST calls. See §B4.)*

## B2. Frontend file map (`static/terminal/`, 25 files)

**JS modules (11):**

| File | Lines | Responsibility |
|---|---|---|
| `app.js` | 145 | Core helpers: `API_BASE` resolver, `getAuthHeader`, `api()`, formatters. Exports `window.Terminal` (`app.js:140-143`). |
| `auth.js` | 145 | Supabase client + Google OAuth + `@s4kent.com` email gate. Exports `window.TerminalAuth` (`auth.js:132-143`). |
| `login.js` | 81 | Login-page state machine + post-OAuth bounce. |
| `nav.js` | 346 | Injects topbar, global search (`terminal_search` RPC `nav.js:115`), version chip, sign-out. |
| `home.js` | 413 | Landing dashboard — movers + SG blind spots. |
| `event.js` | 4246 | Event detail — charts, tabs incl. **Seat Map (§B11)**, the RPC waterfall. Heaviest module. |
| `movers.js` | 496 | Movers table (v2 index mode + legacy mode). |
| `discovery.js` | 475 | Discovery gap-alerts / blind-spots / returning-entities panels. |
| `performer.js` | 674 | Performer index + detail + ESPN + Market Carpet tab. |
| `venue.js` | 509 | Venue index + detail + Market Carpet tab. |
| `orders.js` | 50 | Doorway to the D2 orders dashboard (health ping only). |

**HTML pages (9):** `index.html` (home), `event.html`, `movers.html`, `discovery.html`, `performer.html`, `venue.html`, `subs.html`, `orders.html`, `login.html`.
Each sets `data-page` on `<body>` and loads the chain **`lib/supabase.js → auth.js → app.js → nav.js → <page>.js`**, with two exceptions:
- `login.html` loads only `lib/supabase.js → auth.js → login.js` (no app.js/nav.js — you're not authed yet).
- `event.html` additionally loads `lib/uplot.iife.min.js` + `lib/uplot.min.css` (charts) and `lib/tevomaps.bundle.js` (Seat Map, §B11).

**lib/ (4) + 1 notice:** `lib/supabase.js` (197 KB minified UMD supabase-js bundle, no source map), `lib/uplot.iife.min.js` (charting), `lib/uplot.min.css`, `lib/tevomaps.bundle.js` (617 KB vendored `@ticketevolution/seatmaps-client@5.0.0` UMD bundle, global `Tevomaps`, React bundled in — see §B11 + `lib/tevomaps.bundle.NOTICE.md` for provenance/license).

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
| **Home** (`index.html` / `home.js`) | A + C | `T.api('/api/broker/movers?window_hours=…')` (`home.js:31`); rpc `get_blind_spots_sg_selling({p_min_score:2})` (`home.js:122`); rpc `get_sg_market_chart(offset,limit)` — the home DISCOVERY panel "TOP 50 — MARKET SELLING, WE'RE NOT IN": top US events we hold no position in, ranked all-platform (blended SG+SeatData volume + median-of-medians across platforms + market breadth) with primary (AXS/TM) face-value availability (redesigned in place, mig 20260709190000) | `event_movers_index`, SG blind-spot views, `sg_market_chart` |
| **Event** (`event.html` / `event.js`) | **C→C→A waterfall** | see waterfall below (`event.js:211-267`) | `get_broker_event_page_v2/v3`, `event_metrics`, listings, SG, TD, ESPN, weather |
| **Movers** (`movers.html` / `movers.js`) | A + C | v2 `T.api('/api/broker/movers?window_days=&source=&category=')` (`movers.js:131`); legacy `?window_hours=` (`movers.js:242`); rpc `get_blind_spots_sg_selling` (`movers.js:299`) | `event_movers_index(_history)`, `discovery_gap_alerts` |
| **Discovery** (`discovery.html` / `discovery.js`) | C | `from('discovery_gap_alerts').select().is('resolved_at',null)` (`discovery.js:73-79`); rpc `get_blind_spots_tevo_selling` (`:260`), `get_returning_entities` (`:374`); enrich via `sg_events_canonical` + `events` | `discovery_gap_alerts`, `sg_events_canonical`, `events` |
| **Performer** (`performer.html` / `performer.js`) | A + C | index rpc `get_broker_performer_index` (`:48`); detail `T.api('/api/broker/performer/{id}/assets')` + `T.api('/api/portfolio?performer_id={id}')` (`:111-112`); ESPN rpc `get_broker_performer_page({p_performer_id})` (`:355`); Market Carpet reads `event_listing_snapshot_daily`/`event_movers_index`/`discovery_gap_alerts` (`:491-508`) | `performer_metadata`, `entity_performer_map`, `espn_*`, portfolio |
| **Venue** (`venue.html` / `venue.js`) | C | index rpc `get_broker_venue_index` (`:45`); detail rpc `get_broker_venue_page({p_venue_id})` — one round-trip for 4 tabs (`:108`); Market Carpet same 3 tables (`:332-349`) | `venue_assets`, `entity_venue_map` |
| **Subs** (`subs.html` / `subs.js`) | A + C | `T.api('/api/broker/event/{id}/substitutions?section=&row=&quantity=&revenue=&source=&fee_pct=')` (`subs.js`); event-name typeahead rpc `terminal_search` | `listings_snapshots`, `seatgeek_seller_listings`, `section_metrics` (logic in `core/substitutions.py`) |
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

## B5. Backend surface (`server.py` + `routers/`)

The backend is `server.py` (a ~1,800-line FastAPI **shell**) + `routers/*` (the route
modules, `include_router`'d back after the BR-CODE-1 decomposition; `app.py` was
renamed `server.py` on 2026-06-26 and its route handlers lifted into `routers/`).
Route handlers live in `routers/`, not the shell. The relevant pieces for the terminal:

- **Mount strategy** (in `server.py`; order matters — static mount must be last):
  - each route group `include_router`'d (via the `build_*_router(...)` factories)
  - `app.include_router(d2_router)` in try/except (optional D2 dashboard)
  - `app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")`
- **`/api/broker/*` routes** live in `routers/broker.py` (`build_broker_router`):
  - `/api/broker/movers` (analytics helper `_compute_movers` in `core/movers.py`)
  - `/api/broker/event/{id}/overview`, `/chart-data`, `/zones`, `/orders`, `/cadences`
  - `/api/broker/performer/{id}/assets`
- **`/api/axs/*` routes** — `/api/axs/event/{id}` (latest snapshot state), `/sections` (per-section availability+pricing), `/listings` (**EVO-standard consecutive-seat blocks** from `v_axs_listings`: section/row/quantity/retail_price/type/format/splits/wheelchair + AXS-only `seat_numbers`), `/series` (price+listing time series for charts). Keyed by `tevo_event_id`; read-only from `axs_*_snapshots`. FE: **AXS Box Office** tab renders the by-section rollup **+** the grouped listings table, plus a sky-blue AXS line (legend toggle) on the median-price and listing-count charts. **Cross-source reuse:** an AXS event, once AQ-mapped to `tevo_event_id`, is a canonical TEvo event already collected by the existing TEvo+SG+TD-markets pollers — so all-marketplace data is automatic (no AXS-specific poller), surfaced via the existing cross-source panel / `get_event_all_source_listing_metrics`. Empty-state until snapshots ingest.
- **CORS** (`server.py`): `_CORS_ORIGINS` from env `CORS_ALLOWED_ORIGINS`; **default is localhost-only** (`http://localhost:3000,http://localhost:5173,http://127.0.0.1:3000`). Wildcards and non-concrete URLs are rejected at boot. `allow_credentials=True`; methods `GET/POST/DELETE/OPTIONS`; headers `Authorization/Content-Type/X-Cron-Secret`. **⚠ The CDN origin is not in the default — see §B10 gap #1.**
- **Security headers** (`_SecurityHeadersMiddleware`, `server.py`): CSP `connect-src 'self' https://*.supabase.co`.
- **Token verification** (`core/auth.py` `require_auth`): backend POSTs the incoming bearer to `{SUPABASE_URL}/auth/v1/user` with the anon apikey to validate the session server-side.

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
| `vibepass-storefront-test` | `render.yaml` | `web` (python) | build = `pip install -r requirements.txt`; start = `uvicorn server:app --host 0.0.0.0 --port $PORT` (`render.yaml`); `healthCheckPath: /healthz`; plan `starter`, region `oregon` | FastAPI. Hosts D0 terminal + D1 storefront + D2 dashboard via `include_router` (testing-unified). Env: `PYTHON_VERSION=3.12.7`, `STOREFRONT_SQL_ONLY=true`, `STOREFRONT_AS_LANDING=true`, `ALLOWED_EMAIL_DOMAIN=s4kent.com`; secrets `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY`, `CRON_SECRET` (all `sync:false`). |

**Static-vs-API:** the static service just publishes `static/`. The API service runs `server.py`, which *also* mounts `/static` (so the terminal is reachable same-origin on the API host too — that's the dev/test convenience). In production the CDN serves the frontend and calls the API host cross-origin (hence the CORS requirement, §B10 gap #1).

## B8. Local dev

- **Run it**: `uvicorn server:app --host 0.0.0.0 --port 8000` — the same command Render uses. **There is no `if __name__ == "__main__"` / `uvicorn.run()` block in `server.py`** (verified absent), so `python server.py` does nothing — you must launch via uvicorn.
- **Required env vars** (`core/config.py`): `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY`. The backend builds its Supabase client with the service-role key (`server.py` via `core/db.make_supabase_client`).
- **Optional**: `AUTH_DISABLED=true` to bypass JWT verification in dev (`core/auth.py`; ignored in prod); `CORS_ALLOWED_ORIGINS` (defaults to localhost — fine for same-origin dev).
- **Static**: FastAPI mounts `/static` from `STATIC_DIR` (`server.py`); the terminal is served same-origin, so `API_BASE` resolves to `''` on localhost (`app.js:32`) and no CORS config is needed locally.

## B9. Charting (uPlot)

Loaded **only on `event.html`** (`event.html:11` css, `:381` js). One composite `#composite-chart` section with two stacked uPlot panes — **price** (`#chartHostPrice`, medians on a $-axis) + **inventory** (`#chartHostInv`, qty lines + SG sale bars) — sharing one range selector (6h/24h/3d/7d/30d/90d/1y/ALL) + per-source pill toggles. Built in `event.js`: `renderChartPrice`, `renderChartInventory`, Y-range guard `robustYRange`, `clipRangeForHours` (fit-to-history x-axis).

**Retention-aware hybrid backbone (rebuilt 2026-06-03).** Each median/count line is **two data layers spliced into one continuous series** via `mergeDurable(fine, daily)`:
- **fine** (recent, high-res) — `event_metrics_series` for TEvo (from `get_broker_event_page_v3/v2`, loaded at `V3_LOAD_HOURS=720`≈30d) + SG firehose series from `get_event_chart_extended`. Capped by the source's sweep window (firehoses 30d, `event_metrics` 120d — see RESOURCES_BIBLE retention ladder).
- **daily** (long-horizon, durable) — `event_listing_snapshot_daily` (**indefinite** retention, 3 slots/day; EVO+SG+TD medians/getins/counts). Fetched in `loadTdFreshness` (limit 1200 ≈ 2yr), exposed via `durMed()`/`durCnt()`.
- `mergeDurable` keeps every fine point and prepends only daily points **older than** the earliest fine point → one line whose depth = max(both layers), so SG no longer dead-ends at 30d while TEvo runs to 120d. The `#chartLayerHint` pill flips to "○ daily history" when the window > 30d. **Caveat:** the durable table only started **2026-05-27**, so long-range depth is shallow today and deepens as it fills; EVO daily coverage ~97%, SG ~6% (sparse but honest — `spanGaps` handles it). TD lines (SH/GT/VD) are the daily series natively.

## B10. Cold-start gaps (resolved here so you aren't blocked)

1. **CORS allowlist omits the CDN origin.** Default `CORS_ALLOWED_ORIGINS` is localhost-only (`server.py`); `https://vibepass-terminal-test.onrender.com` is **not** included. Because the CDN serves the frontend cross-origin to the API service (`app.js:36-37`), every `/api/broker/*` call from the deployed CDN fails CORS until an operator sets `CORS_ALLOWED_ORIGINS` on `vibepass-storefront-test` to include the CDN https origin. This is a runtime-config dependency invisible from source. **Action when wiring prod:** set that env var.
2. **No app entrypoint in `server.py`.** No `__main__`/`uvicorn.run`; run via `uvicorn server:app …` (§B8).
3. **`render-d0-terminal.yaml` is not the live config** (header annotated "not yet active", `:83-87`). Treat the Render dashboard as source of truth for the static service's headers/rewrites.
4. **`lib/supabase.js` is a 197 KB minified UMD bundle, no source map, no in-tree version string.** To reproduce auth behavior (implicit flow, `detectSessionInUrl`) a rebuild must independently pin the supabase-js version.
5. **`tickpick_orders` / `vivid_orders` are unreachable from the frontend by design** — service_role-only, read through a SECDEF RPC (`event.js:2607`), never a direct table read. Know the RPC name to surface TP/Vivid sales.
6. **No TODO/FIXME/HACK markers exist in the frontend JS** — it's clean; the gaps above came from cross-file/runtime analysis, not in-code breadcrumbs.

---

## B11. Seat Map — multi-source Tevomaps overlay
`event.html` Seat Map tab: TEvo interactive seatmap, sections colored by a selected source's listing floor (PRs #406-410).
- **Library:** `lib/tevomaps.bundle.js` = vendored UMD `@ticketevolution/seatmaps-client@5.0.0` (global `window.Tevomaps`, React bundled → no build step). License/sha → `lib/tevomaps.bundle.NOTICE.md` (UNLICENSED; TEvo broker relationship). Update: re-`npm pack`, copy `dist/bundle.js`, refresh sha.
- **Inputs (Path-C, no backend):** `venueId`←`events.venue_id`, `configurationId`←`events.configuration_id`; per-source `ticketGroups` by tevo event_id via `get_event_evo_listings_full` / `get_event_sg_listings_full` / `get_event_td_listings(tevo_event_id,platform,hours)`.
- **CSP:** library fetches `maps.ticketevolution.com/{venueId}/{configurationId}/{map.svg,manifest.json}` from the browser → `event.html` `<meta>` CSP `connect-src` must include that host (#406). Not reachable from CI/agent/SQL (egress allowlist) — only a real browser renders it.
- **Section-name gotcha (`PROJECT_BIBLE §3`):** manifest keys = full names (`Lower Level Corner 104`); sources store only the tail token (`104`); map matches `tevo_section_name` exactly (lowercased). `loadSeatmap` reduces both to a tail (digits + short suffix), remaps token→full name. Tail collision (`2`→`Floor 2` & `Event Level Suites 2`) prefers `Floor N`; others grey.
- **Selector:** renders once (TEvo default); re-colors one source at a time via `api.updateTicketGroups()`. Sources: TEvo/SG/StubHub/GameTime/VividSeats/TickPick. **TP is ZONE-MAPPED** (whole bands `100s`/`Lower`/`Suites` → `_seatmapZoneKeys` expands to the section set; `_seatmapIsZoneSource`; excluded from auto-pick — over-counts). **TM excluded** (primary box-office). `Floor N`↔`VIP N` → `_smPick` T4b prefers unique Floor key. Coverage MSG/Knicks: GT ~100%, VD ~99%, SH ~96%, SG ~87%; residue is zone-level (no section #). Unmapped sections → `unmapped` pill + amber tint (`_seatmapRowMapped`) + per-source count footer.
- **Availability:** ~100% upcoming events have `venue_id`+`configuration_id`; only ~79 configs / 72 venues have `v_broker_configurations.fanvenues_key` (in-DB "map exists" proxy; ~1,483 events). True CDN coverage ≥79, browser-probe-confirmable only (KANBAN follow-up).

---
