# Media-asset placement & custom-zones-default — visual test (2026-05-08)

> **Trigger**: Julian asked me to pull EVO/SeatGeek/ESPN media assets (venue maps, team logos, player headshots) into the templates and simulate placement visually. **Plus**: assume custom zones are the DEFAULT zone view for sports (not curated).
>
> **What changed in `static/_proposals/templates.html`** (4 surgical edits):
> 1. Added `.lg-{abbr}` + `.lg-lg` + `.lg-sm` CSS class system + ESPN logo URL pairs (NBA/MLB/NHL teams used in scenarios)
> 2. Added `.venue-map` + `.pl-head` CSS for static seat maps + ESPN player headshots
> 3. Added `.zone-mode-toggle` + `.cz-row` styles for the custom-zones-as-default UI
> 4. Wove logos / headshots / seat-map into T1 hero, T1 zones panel, T2 performer hero, T2 ESPN context, and T6 series timeline
>
> Verify visually by opening `static/_proposals/templates.html` in a browser and tabbing through #workbench / #performer / #series.

---

## 0. TL;DR — what's now visible where

| Surface | Asset | Element | Verdict |
|---|---|---|---|
| T1 Event Workbench hero | NYK + PHI logos (24×24) | inline beside team names | ✅ feels right |
| T1 zones panel | TEvo S3 static seat-map for MSG/Basketball config 2841 | small img above the zones list | ✅ adds spatial context without dominating |
| T1 zones panel | Custom-zones-default rows (4 example user-zones) | replaces curated zone table | ✅ matches Julian's "custom = default for sports" call |
| T2 Performer Console hero | Knicks logo (64×64 large) | inline beside team name | ✅ |
| T2 ESPN context | Brunson + Bridges + Randle ESPN headshots (28×28 circle) | inline player chips | ✅ — instantly more scannable than the prior text "Brunson Q · Bridges out" |
| T6 series timeline | NYK/PHI matchup logos per game card (18×18) + home/away label | inside each of 7 game columns | ✅ — instantly scannable home vs away pattern |
| T1 KPI grid / Splits / Order book | none added | — | ✅ — keeping these text-dense is correct |

---

## 1. Custom zones as default — design decision documented

Per Julian: **on sports, custom zones are the DEFAULT zone view.** Curated zones (the "100 End / 100 Garbage / U1 .1-9" set from venue/AQ-defined geometry) becomes a secondary toggle.

### Rationale captured from the prior simulations

- **Brokers think in their own analytical cuts**, not the venue's pre-curated geometry. "Front 10 + GA pit" and "Premium boxes" are the mental units.
- **Custom zones cross-cut sections**. A premium-boxes zone might span Club Gold + Club Platinum + Courtside; a discount tier might span U3 10+ + U4 + 400 row > 5.
- **Per-broker, not per-venue**. Different brokers slice the same venue differently.
- **Allocation View is orthogonal** — allocation tracks PHYSICAL inventory (the same 4 seats × N games); custom zones track ANALYTICAL CUTS over the price/section/row dimension.

### What the toggle looks like (top-right of the Zones panel)

```
[ My Zones ] [ Curated ] [ Sections ]
   ^active
```

Default: **My Zones**. Persists per-user via `localStorage.zone_view_v1`.

### Example custom zones rendered

The skeleton shows 4 illustrative user zones:

| Name | Predicate | Median $ | Listings | S4K% |
|---|---|---|---|---|
| Front 10 + GA pit | `section IN ('100 End','100 Corner','100 Garbage','GA') AND row ≤ 10` | $2,340 | 76 | 28% |
| Premium boxes | `section LIKE 'Club %' OR section = 'Courtside'` | $6,750 | 42 | 12% |
| Mid-tier value | `section IN ('U1 .1-9','U2 1-10','300 Center')` | $650 | 95 | 35% |
| Discount tier | `section IN ('U3 10+','U4','400') AND row > 5` | $385 | 229 | 51% |

Each row hovers with cursor pointer; click → drilldown to the listings inventory grid filtered to that cut. Right-aligned `@` action toggles "watch" (saves the cut to user's pinned list). New zone via the `+ New custom zone` row at the bottom (opens predicate editor in a side drawer — out of scope for this skeleton).

### Where the curated geometry still shows up

Click the `[ Curated ]` toggle → switches the rows to the venue's named-zone geometry: `100 Corner / 100 End / 100 Garbage / 300 Center / U1 .1-9 / U1 10+ / U2 1-10 / U2 11-25 / U3 .1-9 / U3 10+ / U4 / 400 / Risers 6-8 / Risers 9+`. This is what the AQ pricer rules attach to — when you're in pricer-config mode, you switch here.

`[ Sections ]` toggle → drops to raw section level (every section_id), no zone aggregation. Used rarely for fresh-listings investigation.

### Schema implication

`user_custom_zones` table — proposed in `simulations-edge-and-ui-2026-05-08.md` §9. Columns:
```
user_custom_zones (
  id, user_id, name, predicate_jsonb, display_order,
  is_team_shared boolean, created_at, last_used_at
)
```

Predicate is a small JSON DSL: `{"section_in": [...], "row_op": "≤", "row_value": 10}` etc. Server evaluates against `listings_snapshots` filtered by event_id.

---

## 2. Asset-by-asset placement decisions

### 2.1 Team logos in T1 hero

**Placement**: inline within the H3 title. `<span class="lg lg-nyk"></span>Knicks vs <span class="lg lg-phi"></span>76ers`.

**Size**: 24×24px with team-color background fill behind the logo (the existing `.lg-{abbr}` CSS pattern already provides `background-color: #1d428a` for NYK + the ESPN PNG for the team). Vertical-align tuned to match the H3 text baseline.

**Why this size**: 24×24 is large enough to recognize the team at a glance, small enough not to dominate the hero text. Bigger (32+) would steal attention from the OWNED PREMIUM tile which is the biggest visual on the page (intentionally).

**Alternative tested mentally**: 32px logos on team-color squares — too prominent, competes with the −26% premium tile. Rejected.

### 2.2 Big team logo in T2 Performer Console hero

**Placement**: 64×64 inline beside "New York Knicks · NBA · home: MSG".

**Why bigger**: T2's hero IS the performer. The logo deserves prominence. 64px reads as "this page is about THIS team" instantly.

**`.lg-lg` modifier** added to the CSS — same color/image, just sized up.

### 2.3 ESPN player headshots in T2 ESPN context

**Placement**: 3 player chips with 28×28 circular headshots + name + status badge + injury detail.

**Layout**: `display:flex; gap:18px; flex-wrap:wrap;`. Each chip = headshot + name + Q/OUT/A badge + 1-line detail.

**Why circular**: matches sports-broadcast convention. Keeps the player as the visual unit.

**Why the chip layout vs a table**: tables are good for dense numerics; injury context is biographical. The chip flow visually says "these are the 3 people whose status drives demand right now" — eye reads them as humans, not data rows.

**Real ESPN URLs used**:
- Brunson: `https://a.espncdn.com/i/headshots/nba/players/full/3934672.png`
- Bridges: `https://a.espncdn.com/i/headshots/nba/players/full/3982181.png`
- Randle: `https://a.espncdn.com/i/headshots/nba/players/full/3064440.png`
- Embiid (in CSS as ready-to-use): `https://a.espncdn.com/i/headshots/nba/players/full/3059318.png`

**Data caveat from data-reality doc**: ESPN player coverage is NBA + MLB + MLS only today (NFL/NHL/WNBA = 0). For non-covered leagues, the chip block degrades to text-only "Player A · Q | Player B · Out".

### 2.4 TEvo static seat map in T1 Zones panel

**Placement**: small image (max-height 220px, aspect 1.4:1) ABOVE the zones list inside the Zones panel.

**Why above the list, not full width**: the zones table is the actionable element; the map is supporting context. Map at top of panel = "here's the spatial layout" → table below = "here's the metrics". Reading flow stays vertical.

**Real URL used**: `https://s3.amazonaws.com/media.ticketevolution.com/configurations/static_maps/2841/medium.jpg?1428386866` (MSG / Basketball config 2841).

**Label overlay**: "MSG · Basketball config · TEvo static" in bottom-left corner so the user knows the source. Bottom-left bias chosen because zone-table headings are top-aligned (no collision).

**Alternative tested mentally**: full-width map (the size of the chart band). Rejected — too much real estate for static context. Future enhancement: clicking the map zooms into a side drawer with the LARGE map (`large.jpg`) and section-click-to-filter wired via TEvo's seatmaps-client when available.

**Opacity 0.85** — slight desaturation so the map sits behind the zone table without competing for attention.

### 2.5 Team logos per game card in T6 Series timeline

**Placement**: inside each of the 7 series-col cards. Pattern: small home-team logo + "v" + small away-team logo + "MSG · home" / "Phil · away" label.

**Size**: 18×18 (`.lg-sm`). Smaller than T1 hero because there are 7 of these cards on screen — visual density requires smaller logos.

**Why home-team-first ordering**: the host is structurally important. NYK at MSG → NYK appears first; PHI at Phil → PHI appears first. Reading the row, the eye picks up the home/away rotation pattern instantly (NYK-PHI / NYK-PHI / PHI-NYK / PHI-NYK / NYK-PHI / PHI-NYK / NYK-PHI = the 2-2-1-1-1 NBA series format).

**Why explicit "home" / "away" label**: redundant with the venue label but reduces cognitive load. The pricer doesn't have to remember "MSG = NYK home"; it's stated.

### 2.6 What I deliberately did NOT add

- **No KPI grid icons** — text-numeric is the right rendering. Adding mini-icons next to "retail / get-in / qty" would look like marketing, not analytical software.
- **No Splits panel imagery** — splits are intrinsically numeric (pairs %, singles %, min split). Bars or gauges might come later but icons would mislead.
- **No Order book channel icons** — the canonical state model is the substance. Channel-icon chips would suggest visual differentiation matters at this surface — it doesn't (per `unified_orders` design).
- **No background images on T1 hero** — bowl-photo backgrounds (Eventbrite-style) cheapen the day-trader feel. Keeping the dark surface clean.
- **No animated logo states** — even when a player goes from Q → OUT, the headshot doesn't pulse. Status badge changes color is enough; logo motion would be distracting.

---

## 3. Visual hierarchy verdict

After layering the assets, the T1 Event Workbench reads top-to-bottom as:

1. **Event identity** — logos + matchup + venue + countdown (top hero) — instant recognition
2. **Owned premium KPI** — biggest number on page (intentional)
3. **Competing-metro strip + sentiment ribbon + AI placeholder** — context band
4. **Chart band** — primary analytical surface
5. **KPI grid + Zones (with seat map + custom zones default) + Splits/ESPN** — decision-support row
6. **Comparable matchups** — historical context
7. **Order book** — current state of our pipeline

Logos appear at #1 and inside #6 — bookending the page at human scale. Player headshots and seat maps live deeper in the page where the broker's attention is investigative. **No image element competes with the biggest number on the page** (the −26% owned premium).

---

## 4. Performance notes

- **All ESPN logo / headshot URLs are remote** to `a.espncdn.com`. In production, pre-warm with `<link rel="preconnect">` to that domain.
- **TEvo S3 seat maps** — same; `<link rel="preconnect">` to `s3.amazonaws.com` recommended.
- **Lazy load**: anything below the fold (T2/T6/T5 etc.) when user is on T1 — uses CSS background-image which doesn't load until the element is rendered. The hash-router already handles this since hidden templates have `display:none`.
- **CSS background-image vs `<img>`**: chose `background-image` for logos and seat map. Reason: lets us show team-color fallback behind the logo (covers the case when the ESPN PNG fails to load — the team color fills the box gracefully). With `<img>` + `alt`, broken-image icons would appear.

---

## 5. Code-side follow-ups surfaced

| # | Item | Why |
|---|---|---|
| 1 | `user_custom_zones` table | Per §1 — backs the custom-zones-default UI |
| 2 | Predicate evaluator | Server-side function that takes a custom-zone predicate + event_id + returns matching listings; aggregate rolls up median / count / S4K% |
| 3 | `team_color` lookup or column | The `.lg-{abbr}` CSS hardcodes team colors today (Knicks blue, 76ers blue, etc.) — consider moving to a `team_metadata.primary_color` field for new teams |
| 4 | ESPN headshot URL — handle missing player IDs | When `espn_athletes.headshot_url` is null, fall back to initials chip (e.g. "JB" on team-color background) |
| 5 | TEvo `configuration.seating_chart.medium` URL pull | The skeleton hardcodes config 2841; production should pull from `/api/broker/event/{id}/overview` → `configuration.seating_chart.medium` |
| 6 | `dynamic_map_key` enable | When `configuration.dynamic_map_key` is non-null, swap the static `<div>` for the TEvo seatmaps-client iframe + section-click filter wiring |

---

## 6. Status

Filed by: design · 2026-05-08
4 surgical edits to `static/_proposals/templates.html` — verifiable by opening in a browser.
1 placement-rationale doc (this).
Custom-zones-default for sports validated as the right primary view; curated stays one toggle away.
No code changes outside the skeleton. No backend writes. Ready for design review.
