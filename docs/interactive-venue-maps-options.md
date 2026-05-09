# Interactive Venue Maps — Options for the UI (revised 2026-05-09)

> **Update 2026-05-09**: Fanvenues was acquired by StubHub. We don't
> use SG/StubHub-affiliated tools as primary infrastructure — too much
> conflict-of-interest risk for a broker terminal. **Recommendation
> is now: stick with TEvo's seat-chart URLs for v1, build DIY SVG
> overlays only for the top venues if/when click-interaction is the
> bottleneck.**

You asked for free or cheap interactive venue maps for the terminal
UI rebuild. Honest read on the landscape — what we already have,
what's available, what each tier costs.

---

## What we already have (free, in our data today)

### TEvo `seating_chart_medium` / `seating_chart_large` URLs

Every event row in `events` table has these two columns:
- `seating_chart_medium` — typically 800×600px PNG/JPG
- `seating_chart_large` — 1600×1200px or larger

These are **static images**, not interactive. But they're free, they
already populate, they show real seat layouts, and they're rendered
by TEvo itself which means they match how brokers see them.

**Verdict for v1**: ship the static image. Add hover/zoom on
client-side later if needed.

How to query:

```sql
SELECT seating_chart_medium, seating_chart_large
FROM events WHERE id = :event_id;
-- Or via the helper:
SELECT * FROM get_broker_event_detail(:event_id);
-- Returns map_medium_url, map_large_url, has_seating_chart.
```

### TEvo `fanvenues_key` (deprecated for new work)

The `events` table has a `fanvenues_key` column populated for many
events — it's TEvo's identifier into Fanvenues' interactive
seat-map system. **Don't build new dependencies on this**: Fanvenues
was acquired by StubHub. If you ever DO want interactive maps, the
StubHub conflict alone disqualifies it. The column stays in the
schema for backward compat.

---

## Free / open-source paths

### Build your own SVG from venue floorplans (DIY)

The honest truth: most "interactive venue maps" are just SVG with
clickable `<polygon>` elements. If you have the venue layout, you
can render it yourself in any framework.

**Sources for floorplans:**
- Stadium official sites usually publish PDF/PNG floorplans
- TEvo's `seating_chart_large` PNG is itself a usable reference
- Wikipedia commons has many stadium overhead images
- Architects' renderings on Google image search

**Effort**: 4–8 hours per major venue to digitize a floorplan into
SVG with section labels. Doable for the top ~20 venues we care about
(Yankee Stadium, MSG, Crypto.com Arena, SoFi, Lambeau, etc.). Skip
for the long tail — fall back to TEvo's static image.

**Pros**: full control, no vendor lock-in, free forever, themeable
to match the terminal UI.

**Cons**: maintaining floorplan data forever — renovations,
configuration changes (basketball vs hockey at MSG) need updates.

### SVG seat-map libraries

- **react-seat-picker** — generic seat-grid library. Good for
  theaters, weak for stadiums.
- **seatchart.js** (BBC, MIT license) — theater-shaped, doesn't
  handle stadium curves well.
- **Vue-Seat-Map** various libraries on GitHub.

**Pros**: free, customizable.
**Cons**: most are designed for theater/cinema layouts. Stadiums
with curved bowls are harder. Still requires you to feed in the
section/row/seat data per venue.

---

## Commercial options (excluding the SG/StubHub family)

### Mapbox + custom overlays

Not built for venue maps but flexible. You can lay GeoJSON polygons
over a base "blank" map, hover them, color them by price tier, etc.

- **Cost**: free up to 50k loads/month, then $5/1k.
- **Effort**: substantial — build GeoJSON polygons per venue, map
  them to sections.
- **Verdict**: only worth it if you're also showing geographic data
  ("venues near me") in the same component.

### Vivenu / OpenSeatChart / Eventfinda

Managed seat-map services with SDKs. Each has its own pricing.
Worth a sales call if you outgrow DIY but want managed.

---

## My recommendation for the UI rebuild

Two-tier approach:

### Tier 1 — ship now (zero cost)

Display `seating_chart_large` from TEvo as a static image. CSS zoom
on hover. Works on every event we have. Ship in the first week of
UI work.

### Tier 2 — when click-interaction is the actual bottleneck

Build SVG overlays for the top ~20 venues by event volume. Estimate
1 day per venue. After that, the top 20 are interactive; everything
else falls back to Tier 1.

Use `react-svg-pan-zoom` for pan/zoom. Section data lives in our DB
(`venue_assets` already has `tevo_venue_id`; add a `sections_geojson`
column when you're ready).

---

## What I'd actually do if I were the coworker

Skip Tier 2 entirely until users tell you they want it. Tier 1
(static images) is good enough until the terminal hits real
production usage and someone says "I want to click sections."

Most of the value of a venue map in a broker workflow is **seeing
the layout** — the click interaction is rarely critical for users
who already know the section they want.

If/when click is needed: DIY SVG for top venues, static fallback
for the rest. **Do not chase Fanvenues** — the StubHub conflict
makes it unsuitable infrastructure for our broker tooling.

---

## Data fields available in our schema

```sql
SELECT
  e.id,
  e.name,
  e.venue_name,
  e.seating_chart_medium AS map_url_800,
  e.seating_chart_large  AS map_url_1600,
  e.fanvenues_key        -- DEPRECATED for new work; StubHub acquired Fanvenues
FROM events e
WHERE e.id = :event_id;
```

Use the helper instead: `get_broker_event_detail(:event_id)` returns
`map_medium_url`, `map_large_url`, `has_seating_chart`,
`fanvenues_key` in one row.
