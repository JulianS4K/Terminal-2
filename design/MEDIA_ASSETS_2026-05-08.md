# Media asset inventory — what's available to each project (2026-05-08)

> **Audience**: claude design + Julian (code).
>
> **Mandate (Julian, 2026-05-08)**: assign ESPN/TEvo logos, maps, and other media to each of the 3 projects so design has a single doc listing every visual asset that's already available — no re-discovery.
>
> **Scope**: catalogs every media source (ESPN, TEvo, S4K-internal `venue_assets`, etc.), then maps each project surface to which assets it uses.

---

## 0. TL;DR

There are **5 media sources** the design system can pull from, with very different reliability and coverage:

| Source | Coverage | Hosted by | Cron / pull |
|---|---|---|---|
| **ESPN team logos** | All major US leagues (NBA/NFL/MLB/NHL/MLS/WNBA) — universally available | ESPN CDN | Auto-crawled by `crawl_espn_assets_cron` (mig 20260508240000) |
| **TEvo static seating maps** | All venues with a configuration; ~all 13K venues | TEvo S3 | Pulled per /events response (`configuration.seating_chart.medium`/`large`) |
| **TEvo dynamic seat maps** | Subset of configurations with `dynamic_map_key` | TEvo (seatmaps-client JS) | Loaded client-side at runtime |
| **TEvo performer/venue `meta.image`** | Mostly null/placeholder unless white-labeled by us | TEvo S3 | Returned in /performers/{slug} and /venues/{slug} |
| **S4K `venue_assets` table** | Manually seeded for top ~30 venues | S4K Supabase Storage | Manual seed |

The big takeaway: **ESPN logos are the most reliable visual asset** (every major-league team has one). **TEvo static maps cover almost every venue** but are flat JPGs without interactivity. **Dynamic maps** are the gold standard but require the seatmaps-client library and are conditional on a `dynamic_map_key`. **Hero images** for `meta.image` are mostly placeholder; for retail we'll lean on `venue_assets.hero_url` (when manually seeded) and design fallbacks otherwise.

---

## 1. Asset catalog — what each source provides

### 1.1 ESPN team logos

Pattern (live, scraped to S3 via cron):
```
https://a.espncdn.com/i/teamlogos/{league}/500/{abbr}.png

# examples already in static/index.html as CSS classes (.lg-*):
nba/500/ny.png       (Knicks)
nba/500/phi.png      (76ers)
nba/500/bos.png      (Celtics)
mlb/500/nyy.png      (Yankees)
mlb/500/bos.png      (Red Sox — note: name collision with NBA Celtics, scope by league)
nhl/500/bos.png      (Bruins)
nhl/500/nyr.png      (Rangers)
nfl/500/kc.png       (Chiefs)
nfl/500/lar.png      (Rams)
nfl/500/dal.png      (Cowboys)
```

**Sizes**: 500×500 PNG with transparent background. Use directly as `<img>` or as `background-image`.

**Brand colors**: each `.lg-*` class in `static/index.html` pairs the logo with the team's primary color as background — e.g. `.lg-nyk { background-color: #1d428a; }`. Useful for chip + circle treatments.

**Coverage**: `crawl_espn_assets_cron` (mig 20260508240000) pulls these for every team in the major leagues we track. Where `entity_performer_map.has_espn = true` AND the performer is mapped, a logo is available.

**Limit**: non-sports performers (concerts/comedy/theater) don't get ESPN logos. Use a placeholder for those.

### 1.2 TEvo static seating maps

Pattern (per API-08 doc):
```
https://s3.amazonaws.com/media.ticketevolution.com/configurations/static_maps/{config_id}/medium.jpg?{ts}
https://s3.amazonaws.com/media.ticketevolution.com/configurations/static_maps/{config_id}/large.jpg?{ts}

# Real example from API-08 (Citizens Bank Park / Baseball config 75):
https://s3.amazonaws.com/media.ticketevolution.com/configurations/static_maps/75/medium.jpg?1428386866

# General Admission default fallback:
https://s3.amazonaws.com/media.ticketevolution.com/configurations/default_maps/ga_500.jpg
https://s3.amazonaws.com/media.ticketevolution.com/configurations/default_maps/ga_1000.jpg
```

**Returned in**: every event's `configuration.seating_chart` object. The `medium` URL is what to use in 95% of contexts; `large` for the Event LP zoom view.

**Sizes**: JPG, ~325KB at large, ~50-100KB at medium. Static — no interactivity.

**Coverage**: every TEvo configuration has one (auto-supplied). `configuration.map_not_available` flags the rare cases where the chart isn't ready.

**Use case**: fallback when seatmaps-client isn't loaded; design-time mockup; print-friendly version.

### 1.3 TEvo dynamic seat maps (seatmaps-client)

Library: TEvo's `seatmaps-client` JavaScript library (CDN-hosted, see TEvo docs for current URL).

Keyed by: `configuration.dynamic_map_key` (e.g. `"6635"` for AT&T Park / Baseball; `"6615"` for Citizens Bank Park / Baseball).

**Capabilities**:
- Interactive section highlight on hover
- Click section to filter listings
- Zoom + pan
- Sync with our listings table (selected section → filter)

**Coverage**: subset of configurations have `dynamic_map_key` populated. When null, fall back to static map.

**Implementation**: load the library on the Event LP, pass `dynamic_map_key`, listen for section-selected event, then re-fetch listings with `?section=` filter.

Per API-08 doc: *"If you wish to display our interactive seating charts you can use our seatmaps-client to display the chart as well as allow selection of sections on the map."*

### 1.4 TEvo performer / venue `meta.image`

Returned by `/performers/{slug}` and `/venues/{slug}`:
```json
"meta": {
  "image": "/images/original/missing.png"
}
```

**Reality check**: `meta.image` is mostly the placeholder `/images/original/missing.png` for unmapped entities. White-label TEvo clients customize these per-entity, but for the long tail it's empty.

**Implication for design**: don't depend on `meta.image` for hero art. Treat it as opportunistic — use S4K's own `venue_assets` for top venues, and design pleasant fallbacks (gradients, generic icons) for everything else.

### 1.5 S4K `venue_assets` table

Internal table (from `docs/terminal-data-inventory.md` and code's redesign memo):

```
venue_assets:
  venue_id (PK, FK to events.venue_id)
  hero_url        — landscape photo of the venue exterior or a marquee event
  map_url         — static seat map (sometimes higher-quality than TEvo's)
  image_url       — square logo / iconic shot
  capacity        — total seats
  has_map         — boolean
```

**Coverage**: manually seeded for top ~30 venues. The seed list is up to ops; for the long tail this table is empty.

**Use**: prefer over TEvo's `meta.image` and over the static map when available, for the retail shop's hero strip.

---

## 2. Project-by-project asset assignment

### 2.1 Broker terminal — `static/index.html` + `static/_proposals/templates.html`

| Surface | Asset | Source | Notes |
|---|---|---|---|
| **T1 hero (event title row)** | Team logos for both performers (sports) | ESPN — `lg-{abbr}` class pattern from index.html | Skeleton currently shows `◤NYK◢ vs ◢PHI◣` — replace with two `<img>` tags or two CSS-painted divs using the existing class system. |
| **T1 zone breakdown** | Static seating map (small) for zone visualization context | TEvo `configuration.seating_chart.medium` | Optional — could show the static map next to the zone table for a "where in the venue" context. |
| **T1 chart + KPIs** | None — pure data | — | |
| **T1 competing-metro strip** | Tiny event-icon per row | ESPN team logo for sports; gradient placeholder for non-sports | Keep at 16-20px size. |
| **T2 Performer Console hero** | Big team logo + team color treatment | ESPN logo + `.lg-{abbr}` color pair | T2 wireframe currently shows `◤NYK◢` text — paint a 64×64 logo on the team-color background. |
| **T2 ESPN context block** | Player headshots (injuries/Q listings) | ESPN player headshots: `https://a.espncdn.com/i/headshots/nba/players/full/{espn_player_id}.png` | Available when `espn_injuries.athlete_id` is populated. Use 32×32 circle. |
| **T2 history strip (last 5 comparables)** | Team logos for opponent | ESPN | Same pattern as T1 hero. |
| **T2 non-sports variant (tour mode)** | Tour map (geo) | NEW — design from scratch using D3 + a US/EU outline SVG | No existing TEvo asset for tour maps. |
| **T3 Venue Pulse hero** | Venue photo (wide) | S4K `venue_assets.hero_url` when seeded; otherwise generic gradient | The static seating map is NOT a hero — it's data. |
| **T3 section premium curve** | Static seating map alongside the bars (optional) | TEvo `configuration.seating_chart.medium` | Helps user mentally tie sections to physical location. |
| **T4 Pricing Queue card** | Team logos (sports) per event | ESPN | Small, in the event title bar. |
| **T5 Metro Watchlist rows** | Tiny event-icon per row | ESPN team logos OR generic event icon | Keep at 16-20px. |
| **T6 Series timeline columns** | Team-color stripe at top of each game card | `.lg-{abbr}` background-color | Creates visual continuity across the 7 games of a series. |
| **Sentiment ribbon** | None — data only | — | |

**Brand**: keep S4K orange `--accent: #f58426` as the only brand color. The `brand-dot` (8×8 colored square) is the only S4K mark in the broker terminal — by design (Robinhood/Bloomberg restraint).

### 2.2 Retail shop — `static/_proposals/shop.html`

| Surface | Asset | Source | Notes |
|---|---|---|---|
| **Home — Tonight Near You cards** | Hero image per event | S4K `venue_assets.hero_url` (preferred) → fallback to TEvo `static_maps/{config_id}/medium.jpg` cropped → fallback to gradient | Most important visual on the site. Without good hero images the home page feels empty. |
| **Home — chips + categories** | Optional small icons (basketball, theater mask, mic, etc.) | Use lucide-react / heroicons inline SVG | Not a CDN dependency — inline SVG for speed. |
| **Search typeahead — events** | Tiny team logo (sports) | ESPN | 16×16 inline next to event name; absent for non-sports rows. |
| **Search typeahead — performers** | Square performer image | TEvo `meta.image` if not missing.png; else ESPN logo (sports); else gradient | 24×24 circle. |
| **Search typeahead — venues** | Square venue image | S4K `venue_assets.image_url`; else gradient | 24×24 rounded square. |
| **Performer LP hero** | Big performer image + team-color band | ESPN logo + `.lg-{abbr}` color (sports); `meta.image` (non-sports if exists); gradient otherwise | 120×120 logo on tinted background. |
| **Venue LP hero** | Wide venue photo | S4K `venue_assets.hero_url` (must seed for top venues); fallback to a static map fragment | 120×120 in the lp-hero block; consider widening to a full-bleed banner for the venue page. |
| **Event LP — interactive seat map** | TEvo dynamic seat map | TEvo seatmaps-client + `configuration.dynamic_map_key` | Primary interactive surface on the Event LP. The skeleton already reserves the `.seat-chart` div for it. |
| **Event LP — fallback static map** | TEvo static seating map | `configuration.seating_chart.medium` or `large` | Used when `dynamic_map_key` is null OR while the dynamic library is loading. The skeleton sets it as a `background-image` on `.seat-chart .static-map` (currently using a real Citizens Bank Park URL as placeholder). |
| **Event LP — performer chips** | Small team logos | ESPN | "Phillies vs Diamondbacks" with 16×16 logos next to each name. |
| **Cart/checkout** | None | — | Trust-signal copy, not images. |
| **Brand mark (nav)** | S4K orange dot + "VibePass" wordmark | CSS-only | The retail brand is `VibePass` — same orange but a friendlier wordmark vs the broker terminal's `S4K Terminal`. |

**Important**: retail surfaces should NEVER show internal data. That means: no `office.name` (broker name), no `wholesale_price`, no `entity_*_map` provenance lights. The wall is enforced at the data layer (`retail_inventory_v` view) but design should also avoid surfacing those fields visually.

### 2.3 Undelivered window — `static/_proposals/undelivered.html`

| Surface | Asset | Source | Notes |
|---|---|---|---|
| **Top KPI strip** | Channel-logo wordmarks for the by-channel breakdown | Self-host wordmarks for EVO, SeatGeek, Vivid, StubHub | Currently text-only ("EVO", "SG", "Vivid", "SH"). Better: 12-14px wordmark SVGs. Self-host since linking to vendor logos directly is brittle. |
| **Hold-expiry lane rows** | Channel chip per row (text) | Self-host wordmarks (same as above) | Keep at chip size — the countdown is the primary visual. |
| **Main board — Event column** | Tiny team logo (sports) when applicable | ESPN | Helps ops scan a 1000-row board faster than reading text-only event names. |
| **Main board — Channel column** | Small channel chip | Self-host wordmarks | Replace text "EVO"/"SG"/"Vivid"/"SH" with 14px logos for faster recognition at scale. |
| **Drawer (row detail)** | Listing thumbnail (the static seat map for the event's config) | TEvo `configuration.seating_chart.medium` | Helps ops visualize which section the order is for. |
| **Bulk action confirmation modal** | None | — | Text-only is fine. |
| **Brand** | S4K orange dot + "Undelivered" title | CSS-only | Same brand mark as broker terminal (they share auth). |

**No retail-style hero imagery here** — this is an internal ops view. Density wins over visual richness.

---

## 3. Recommended hierarchy for image sourcing

For any retail or terminal surface that needs an image, follow this resolve order:

1. **S4K `venue_assets.hero_url` / `image_url`** when available (highest quality, manually curated).
2. **ESPN logo** when the entity is a major-league sports performer/team (`entity_performer_map.has_espn = true`).
3. **TEvo `meta.image`** if NOT the placeholder `/images/original/missing.png`.
4. **TEvo `configuration.seating_chart.medium`** for venue-context contexts (cropped or used as backdrop).
5. **Generic gradient + initials chip** as the universal fallback.

The retail shop especially needs steps 4-5 because the long tail of events doesn't have curated hero imagery.

---

## 4. Channel logos for the Undelivered Window

The UDW renders 4-6 channels (EVO, SeatGeek, Vivid, StubHub, retail, wholesale). Channel wordmarks should be self-hosted in `static/_assets/channels/`:

| Channel | Suggested asset | Notes |
|---|---|---|
| EVO (TicketEvolution) | `tevo-wordmark.svg` (14×60px) | Self-host — TEvo brand guidelines vary; we own the integration. |
| SeatGeek | `seatgeek-wordmark.svg` | Public brand mark. |
| Vivid Seats | `vividseats-wordmark.svg` | Public brand mark. |
| StubHub | `stubhub-wordmark.svg` | Public brand mark. |
| Retail (VibePass internal) | own logo — same as `/shop` brand | Reuse VibePass orange dot. |
| Wholesale | text-only "WS" chip | No external brand involved. |

Recommend code/design pair to gather these wordmarks (each vendor has a Brand assets / Press kit page) and commit them to `static/_assets/channels/`. Keep file sizes <2KB each.

---

## 5. Seatmaps-client library — integration plan (Event LP)

For the Event LP (Template 1 in broker, retail shop's Event LP):

1. Load the library:
   ```html
   <script src="https://cdn.jsdelivr.net/npm/seatmaps-client/dist/index.umd.min.js"></script>
   ```
   (Confirm exact URL from TEvo's seatmaps-client repo.)

2. After `/events/{id}` returns, read `configuration.dynamic_map_key`. If non-null:
   ```js
   const sm = new SeatmapsClient(document.getElementById('seat-chart'), {
     mapId: configuration.dynamic_map_key,
     onSelectSection: (section) => filterListingsBySection(section),
   });
   ```

3. If `dynamic_map_key` is null OR the library fails to load, fall back to setting `background-image` on `.seat-chart .static-map` from `configuration.seating_chart.medium`.

The shop skeleton's `.seat-chart` div is already structured for this — just needs the library wired in.

---

## 6. Open questions for code

1. **`venue_assets` seeding owner**. Who maintains the manual seed list of top-30 venues' hero images? Suggest: ops uploads via Supabase Storage + we add a simple admin form on the broker terminal.
2. **ESPN headshot coverage**. Confirm: does `crawl_espn_assets_cron` also pull player headshots, or only team logos? If team-only, file a NEXT (code) row to extend it.
3. **Channel logo licensing**. Self-hosting external brand marks is generally permitted under fair-use brand assets pages, but confirm with legal before launching the retail shop.
4. **Tour map data source**. For non-sports T6 tour mode, no existing asset. Suggest: derive a per-tour map from `events.venue.address.lat/lng` joined to the tour's stops — render as an inline SVG D3 plot rather than depending on an external map provider.
5. **Performer image fallback**. What's the design pattern when `meta.image` is missing AND the performer isn't a sports team? Suggest: a colored circle with the performer's initials (e.g. "MS" for Madonna, "TS" for Taylor Swift) on a brand-color gradient.

---

## 7. References

- ESPN team logo CDN: `https://a.espncdn.com/i/teamlogos/{league}/500/{abbr}.png`
- ESPN player headshot CDN: `https://a.espncdn.com/i/headshots/{league}/players/full/{espn_player_id}.png`
- TEvo static seating maps: `https://s3.amazonaws.com/media.ticketevolution.com/configurations/static_maps/{config_id}/{medium|large}.jpg`
- TEvo sandbox default GA map: `https://s3.amazonaws.com/media.sandbox.ticketevolution.com/configurations/default_maps/ga_{500|1000}.jpg`
- TEvo seatmaps-client: see TEvo developer docs (referenced in API-08)
- Live in-codebase: `static/index.html` lines 109-142 — every `.lg-*` CSS class is an existing logo + team-color pair, ready to reuse.
- S4K table: `venue_assets` (see SCHEMA.md tables section + `crawl_espn_assets_cron` mig 20260508240000)
- Companion: `design/CODE_NOTES_2026-05-08.md` — backend hooks per project

---

## 8. Status

Filed by: design · 2026-05-08
No code changes. No backend writes. Ready for design + code to align on `venue_assets` seeding before the retail shop ships.
