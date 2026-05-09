# Interactive Venue Maps — Options for the UI

You asked for free or cheap interactive venue maps for the terminal
UI rebuild. Honest read on the landscape — what we already have,
what's available, what each tier costs, what each gives you.

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
client-side later if needed. Don't pay for interactive maps until
the UI clearly demands it.

### TEvo `fanvenues_key`

The `events` table also has `fanvenues_key` — a key into Fanvenues'
interactive seat-map system. Fanvenues is the established 3rd-party
provider TEvo integrates with. If you want true interactive,
this is the path of least resistance.

**Pricing**: Fanvenues is **commercial** ($X/month per active venue
or per-render). Not free. Reach out for a quote — historically in the
$200–$2,000/month range depending on volume. Cheap if we're already
selling tickets at those venues.

---

## Free / open-source options

### 1. Build your own from venue floorplans (DIY)

The honest truth: most "interactive venue maps" are just SVG with
clickable `<polygon>` elements. If you have the venue layout, you
can render it yourself in any framework.

**Sources for floorplans:**
- Stadium official sites usually publish PDF/PNG floorplans
- StubHub / SeatGeek public pages render maps you can inspect
- Wikipedia commons has many stadium overhead images
- Architects' renderings on Google image search

**Effort**: 4–8 hours per major venue to digitize a floorplan into
SVG with section labels. Doable for the top ~20 venues we care about
(Yankee Stadium, Madison Square Garden, Crypto.com Arena, SoFi,
Lambeau, etc.). Skip for the long tail.

**Pros**: full control, no vendor lock-in, free forever, themeable
to match your UI.

**Cons**: you're maintaining floorplan data forever. Renovations,
configuration changes (basketball vs hockey at MSG) need updates.

### 2. SVG seat-map libraries (open-source)

- **react-seat-picker** (https://github.com/eduzilla/react-seat-picker)
  — generic seat-grid library. Good for theaters, weak for stadiums.
- **seatchart.js** (https://github.com/bbc/seatchart) — by BBC, MIT
  license. Theater-shaped, doesn't handle stadium curves well.
- **Vue-Seat-Map** various libraries on GitHub.

**Pros**: free, customizable.

**Cons**: most are designed for theater/cinema layouts. Stadiums
with curved bowls are harder. Still requires you to feed in the
section/row/seat data per venue.

### 3. Static images you already have (zero work)

Just display TEvo's `seating_chart_large` URL with CSS overlays.
For terminals where the user just needs to *see* the layout (not
click sections), this is the right answer.

Cost: $0. Effort: 0. Coverage: every venue in our system.

---

## Commercial options (cheap to mid-tier)

### 4. Mapbox + custom overlays

Not built for venue maps but flexible. You can lay GeoJSON polygons
over a base "blank" map, hover them, color them by price tier, etc.

**Cost**: free up to 50k loads/month, then $5/1k.

**Effort**: substantial (build GeoJSON polygons per venue, map them
to sections). Same per-venue cost as DIY SVG, just with Mapbox's
rendering layer.

**Verdict**: only worth it if you're also showing geographic data
(like "venues near me") in the same component.

### 5. Fanvenues (the obvious answer)

Already integrated with TEvo. Many brokers use it. Pricing tiers
exist for small/mid/large operations.

**Cost**: contact-sales (typically $200–$2k/month based on volume).

**Pros**:
- Zero setup work — `fanvenues_key` from our events table just works
- Maintained by them; renovations + config changes handled
- Matches what other brokers in the industry use

**Cons**: vendor lock-in; price escalates with growth.

### 6. Vivenu / OpenSeatChart / Eventfinda

Similar tier — managed services with SDKs. Each has its own
pricing model. Worth a sales call if you outgrow Fanvenues but
want managed.

### 7. SeatGeek's open seat data

SeatGeek's public website renders interactive maps. Their CLIENT side
data is sometimes inspectable in browser DevTools — section polygons
in JSON. **Don't scrape** (ToS), but you can use their pages as a
reference for how interactive maps should *feel*.

---

## My recommendation for the UI rebuild

Three-tier approach, ship in this order:

### Tier 1 — ship now (zero cost)

Display `seating_chart_large` from TEvo as a static image. CSS zoom
on hover. Works on every event we have. Ship in the first week of UI work.

### Tier 2 — when UX demands clickability (low cost, when ready)

Build SVG overlays for the top 20 venues by event volume. List in
order:
1. Madison Square Garden
2. Yankee Stadium
3. Crypto.com Arena
4. SoFi Stadium
5. Wrigley Field
6. Lambeau Field
7. Fenway Park
8. Truist Park
9. Dodger Stadium
10. ... (rank by `events` table count per venue)

Estimate: 1 day per venue. ~4 weeks of work total. After that, the
top 20 venues are interactive; everything else falls back to Tier 1.

Use `react-svg-pan-zoom` for pan/zoom. Section data lives in our DB
(`venue_assets` already has `tevo_venue_id`; add a `sections_geojson`
column when you're ready).

### Tier 3 — when scaling demands managed (medium cost, only if we hit revenue)

Integrate Fanvenues via `fanvenues_key`. By this point you'll have
revenue to justify the spend, and you'll appreciate not maintaining
20+ SVG files yourself.

---

## What I'd actually do if I were the coworker

Skip Tier 2 entirely. Tier 1 (static images) is good enough until
you have actual user feedback saying "I want to click sections."
Most of the value of an interactive map is in **showing the layout**
— the click interaction is rarely critical for a broker workflow
where they already know which section they want.

When you DO need click interaction, jump straight to Fanvenues.
Building 20 SVGs by hand is a tarpit; the maintenance cost over a
year exceeds the Fanvenues subscription.

So: **Tier 1 → Tier 3, skip Tier 2** unless you specifically need
the brand customization that DIY SVG gives you.

---

## Data fields available in our schema

If you go with TEvo static images:

```sql
SELECT
  e.id,
  e.name,
  e.venue_name,
  e.seating_chart_medium AS map_url_800,
  e.seating_chart_large  AS map_url_1600,
  e.fanvenues_key        AS fanvenues_key  -- for Fanvenues integration
FROM events e
WHERE e.id = :event_id;
```

`get_broker_event_detail(:event_id)` already returns `map_medium_url`,
`map_large_url`, `has_seating_chart`, `fanvenues_key` — use that
helper, don't query raw events directly.

---

## Final word

The terminal you're building is a **broker tool**, not a consumer
ticket-buying surface. Brokers don't browse seat maps for fun — they
look up specific sections by name. The static image + a section
search box gets you 90% of the value with 0% of the effort.

If you push back on this read, the data point I'd want to see is
"users keep clicking on map sections expecting it to filter
listings." Until you have that signal, static is fine.
