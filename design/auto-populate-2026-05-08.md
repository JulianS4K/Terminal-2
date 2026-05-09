# Auto-populating views — scope detection design (2026-05-08)

> **Trigger**: Julian asked "how do we auto-populate some view to a performer or series or tour or whatever scenario we have."
>
> **Companion**: this doc complements `terminal-only-redesign-2026-05-08.md` (view definitions) and the simulation trio (`simulations-{non-sports,sports,edge-and-ui}-2026-05-08.md`). It answers a different question: given an event/performer/venue/tour, **how does the terminal pick which view to render?**
>
> **Premise**: the broker doesn't manually pick a template. The data picks the **most-specific applicable scope**, and the broker can drill in/out via banner hints, breadcrumbs, and tabs.

---

## 0. TL;DR

The terminal's view auto-populate is a 3-step pipeline:

1. **Click → URL** — the user's click sets a hash that encodes the entry point + an optional "context" hint.
2. **Backend `detect_view_scope(event_id, user_context)`** — server returns the recommended view + a list of secondary scopes that apply.
3. **Frontend renders the recommended view + lights up secondary-scope affordances** — banners, breadcrumb chips, sidebar drawers — that one-click drill the broker into the alternate scope without losing context.

The result: clicking "Knicks G5" opens Event Workbench by default but a banner says "🎯 part of a 7-game series · Open Series view →". Clicking "Madonna 5/13 Brooklyn" opens Event Workbench with a "🎤 stop 13 of 47 · Open Tour view →" banner.

---

## 1. Entry-point detection map

Every event in the system has up to 9 applicable scopes. Detection runs at the click time and returns **which subset applies**.

| Scope | Detected via | Recommended view | When primary |
|---|---|---|---|
| **Single event (T1)** | always — every event has this | Event Workbench | DEFAULT — when no other scope is more specific |
| **Series (T6 series mode)** | `matchup_xref` row joining this event to others contiguous + `name` parsing for "Game N" + `series_xref` (proposed) | T6 Series mode | When event is part of a 3-7 game contiguous block (NBA/NHL/MLB playoffs, MLB stand) |
| **Multi-day single event (T6 multi-day)** | `multi_day_event_link` (proposed) — F1 race weekend, tennis tournament, golf major | T6 Multi-day mode | When event is one day of a 3-7 day campaign |
| **Tour (T6 tour mode)** | `tour_metadata.tour_id` (deferred) OR parsed from `events.tour_name` | T6 Tour mode | When event is a stop in a multi-stop touring campaign |
| **Season (T6 season mode)** | `events.primary_performer_id + season_year + is_home=true` | T6 Season mode | When user clicked from a Performer page → season aggregate is implied |
| **Performer (T2)** | clicked from a performer link OR explicit `#performer/{slug}` route | T2 Performer Console | When user came FROM a performer entry point |
| **Venue (T3)** | clicked from a venue link OR explicit `#venue/{slug}` route | T3 Venue Pulse | When user came FROM a venue entry point |
| **Metro (T5)** | clicked from a metro overview OR same-day same-metro context | T5 Metro Watchlist | When user came FROM a metro / "tonight in NYC" view |
| **Mega-event (T1 mega-mode)** | `major_event_calendar` row matching event_id (Super Bowl, Stanley Cup Final, MLS Cup, etc.) | T1 in mega-event variant | When the event is registered as a tentpole |
| **Allocation View** | event has `inventory_allocation` rows for the user's inventory | T1 with Allocation tab pre-selected | When broker holds a fixed-allocation in the event (season tickets) |

**Note on the WNBA / NFL / NHL caveat**: when ESPN player data is missing for a league, T1 still renders — just with the player chips degraded to text per `data-reality-2026-05-08.md`. Detection doesn't change.

---

## 2. The `detect_view_scope()` function

### 2.1 Backend signature

```sql
CREATE FUNCTION public.detect_view_scope(
  p_event_id        bigint,
  p_user_id         uuid,         -- for allocation/custom-zone awareness
  p_referrer_scope  text DEFAULT NULL  -- 'performer' | 'venue' | 'metro' | 'tour' | NULL
) RETURNS jsonb
```

Returns:

```json
{
  "primary_view": "event_workbench",
  "primary_mode": null,
  "primary_url": "#event/3845925",
  "secondary_scopes": [
    {"view": "series", "label": "7-game series · NYK-PHI R2",
     "url": "#series/m_4451_nbap_r2", "score": 0.95},
    {"view": "allocation", "label": "Knicks home allocation · 8 of 41 sold",
     "url": "#event/3845925?tab=allocation", "score": 0.80},
    {"view": "performer", "label": "New York Knicks · 12 active events",
     "url": "#performer/new-york-knicks", "score": 0.65}
  ],
  "scope_metadata": {
    "matchup_id": 4451,
    "series_id": "m_4451_nbap_r2",
    "season_id": "knicks_2026_home",
    "tour_id": null,
    "is_mega_event": false,
    "is_in_allocation": true,
    "allocation_id": 17
  },
  "last_event_in_scope": false,
  "next_event_in_scope_id": 3845926
}
```

### 2.2 Detection logic (pseudocode)

```python
def detect_view_scope(event_id, user_id, referrer_scope):
    event = SELECT * FROM events WHERE id = event_id
    
    # Primary view selection — ordered by specificity
    if referrer_scope == 'performer':
        primary = 'performer'
    elif referrer_scope == 'venue':
        primary = 'venue'
    elif referrer_scope == 'metro':
        primary = 'metro'
    elif is_in_major_event_calendar(event):
        primary = 'event_workbench'  # but with mega-event mode flag
        mode = 'mega_event'
    elif user_has_allocation_in_event(user_id, event_id):
        primary = 'event_workbench'
        primary_tab = 'allocation'
    else:
        primary = 'event_workbench'  # default
    
    # Secondary scopes — ALL applicable scopes returned with a score
    secondaries = []
    
    if (series := find_series(event_id)) is not None:
        secondaries.append({
            'view': 'series',
            'label': f"{series.game_count}-game series · {series.matchup_label}",
            'url': f"#series/{series.id}",
            'score': 0.95  # very high — series context usually matters
        })
    
    if (tour := find_tour(event_id)) is not None:
        secondaries.append({
            'view': 'tour',
            'label': f"{tour.name} · stop {tour.stop_number} of {tour.total_stops}",
            'url': f"#tour/{tour.id}",
            'score': 0.90
        })
    
    if (multi := find_multi_day(event_id)) is not None:
        secondaries.append({
            'view': 'multi_day',
            'label': f"{multi.name} · day {multi.day} of {multi.total_days}",
            'url': f"#multi-day/{multi.id}",
            'score': 0.85
        })
    
    if user_has_allocation_in_event(user_id, event_id):
        alloc = get_allocation_summary(user_id, event_id)
        secondaries.append({
            'view': 'allocation',
            'label': f"{alloc.scope_label} · {alloc.sold}/{alloc.total} sold",
            'url': f"#event/{event_id}?tab=allocation",
            'score': 0.80
        })
    
    if event.primary_performer_id:
        perf = get_performer_summary(event.primary_performer_id, user_id)
        secondaries.append({
            'view': 'performer',
            'label': f"{perf.name} · {perf.active_events} active events",
            'url': f"#performer/{perf.slug}",
            'score': 0.65
        })
    
    if event.venue_id:
        venue = get_venue_summary(event.venue_id)
        secondaries.append({
            'view': 'venue',
            'label': f"{venue.name} · {venue.upcoming_count} upcoming",
            'url': f"#venue/{venue.slug}",
            'score': 0.55
        })
    
    # Filter out the primary view from secondaries (no self-reference)
    secondaries = [s for s in secondaries if s['view'] != primary]
    
    return {
        'primary_view': primary,
        'primary_mode': mode if 'mode' in locals() else None,
        'primary_url': build_primary_url(primary, event_id, user_id),
        'secondary_scopes': sorted(secondaries, key=lambda s: -s['score']),
        'scope_metadata': {...},
    }
```

### 2.3 New endpoint

```
GET /api/broker/events/{id}/scope?referrer={performer|venue|metro|tour|null}
```

Wraps the function. Cached 60s per (event_id, user_id, referrer) — the data underlying scope detection doesn't change rapidly.

### 2.4 Cron / pre-warming

For the home dashboard's top-movers + watchlist rows: pre-compute scope detection for all visible events on a 5-min cron. Lets the home rows display scope hints (small icons indicating "this is a series game / tour stop / etc.") without per-row API calls.

---

## 3. UI affordances — how scope hints render

### 3.1 Top-of-event banner (the primary affordance)

Right after the event hero, before the chart band, a single horizontal banner showing applicable secondary scopes:

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ 🎯 Series: NYK-PHI R2 · 7 games · Open Series view →                                  │
│ 🎟 Allocation: Knicks home · 8 of 41 sold ($87K recovered) · Open Allocation tab →    │
│ 🏟 Performer: New York Knicks · 12 active events · Open Performer Console →           │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

Each row → one-click jump to that secondary scope. Top 3 (by score) shown by default; "+ N more" expands the rest.

The banner can be collapsed via a chevron (per-user `localStorage.scope_banner_v1`).

### 3.2 Breadcrumb chips — context preservation

When user came from a non-event entry point, the breadcrumb shows their path:

```
Home › NBA › Knicks › G5 vs PHI
```

Click any segment → goes back to that scope. The terminal preserves scope hints across navigation (a side rail keeps "you came from Knicks → still showing Knicks-related context").

### 3.3 Auto-populated sidebars

When primary is T1 but a series/tour/season scope ALSO applies, a thin **right-side scope rail** (200px) appears with mini-context:

```
┌────────────────┐
│  THIS SERIES   │
│  G1 ✓ played   │
│  G2 ✓ played   │
│  G3 ✓ played   │
│  G4 ✓ played   │
│  G5 ⚡ NOW     │  ← current
│  G6 ⚪ Fri     │
│  G7 ⚪ if-nec  │
│                │
│ [Open Series →]│
└────────────────┘
```

The rail collapses to a tab handle when the broker wants more chart real estate. Persisted per-user.

### 3.4 Smart breadcrumb rewriting

If the user navigated `Home › NBA › Knicks G5` AND the scope detection finds this is a series, the breadcrumb auto-augments to:

```
Home › NBA › Knicks › Series R2 · G5
```

(without the user explicitly choosing the series).

---

## 4. URL routing patterns

### 4.1 Hash-based routes

| Hash pattern | Lands on | Scope hints |
|---|---|---|
| `#event/{id}` | T1 default | Detect at load; banner shows applicable secondaries |
| `#event/{id}?tab=allocation` | T1 with Allocation tab pre-selected | Same |
| `#event/{id}?context=series:{series_id}` | T1 with series rail expanded | Series sub-context |
| `#event/{id}?context=tour:{tour_id}` | T1 with tour rail expanded | Tour sub-context |
| `#performer/{slug}` | T2 Performer Console | All performer's events shown |
| `#performer/{slug}/event/{id}` | T1 with performer breadcrumb preserved | Performer rail visible |
| `#venue/{slug}` | T3 Venue Pulse | All venue events |
| `#venue/{slug}/event/{id}` | T1 with venue breadcrumb preserved | Venue rail |
| `#series/{series_id}` | T6 Series mode | All games in series; click any → T1 with series context |
| `#tour/{tour_id}` | T6 Tour mode | All stops; click any → T1 with tour context |
| `#season/{performer_slug}/{year}` | T6 Season mode | All season events |
| `#multi-day/{event_link_id}` | T6 Multi-day mode | F1 weekend / tennis tournament / golf major |
| `#metro/{metro_id}` | T5 Metro Watchlist | Tonight's slate; click event → T1 with metro context |
| `#queue/{filter_hash}` | T4 Pricing Queue | Queue with filter |

### 4.2 Same-tab vs new-tab semantics

- **Plain click** → navigates same tab
- **Cmd-click / Middle-click** → opens new tab with the new scope
- **Browser back button** → preserves scope context (URL contains all state)
- **Refresh** → re-detects scope (fresh data); banner re-renders

### 4.3 Cross-context inheritance

Clicking from a series page into a single event → the new T1 view has the series rail expanded by default (because referrer was `series`). Reduces click count when broker wants to alternate between series-overview and per-game detail.

---

## 5. Per-event-type detection examples

### 5.1 NBA playoff game (Knicks G5)

```
detect_view_scope(3845925, user_id, NULL)
→ primary: event_workbench
  primary_url: #event/3845925
  secondaries: [
    {series: NYK-PHI R2, score: 0.95},
    {allocation: Knicks home, score: 0.80, only if user holds},
    {performer: Knicks, score: 0.65},
    {venue: MSG, score: 0.55}
  ]
```

UI: banner shows "Series · Allocation · Performer". Right rail shows G1-G7 mini-timeline.

### 5.2 Madonna concert in Brooklyn (tour stop 13)

```
detect_view_scope(madonna_brooklyn_id, user_id, NULL)
→ primary: event_workbench
  secondaries: [
    {tour: Eras-Echo Tour, stop 13/47, score: 0.90},
    {performer: Madonna, score: 0.65},
    {venue: Barclays Center, score: 0.55},
    {metro: nyc, score: 0.40}
  ]
```

UI: banner top hint = tour stop. Right rail = "tour-map mini" showing recent stops + upcoming.

### 5.3 F1 Miami Sunday race

```
detect_view_scope(f1_miami_race_id, user_id, NULL)
→ primary: event_workbench
  secondaries: [
    {multi_day: Miami GP weekend, day 3 of 3, score: 0.85},
    {performer: F1 — Miami Grand Prix, score: 0.65},
    {venue: Miami International Autodrome, score: 0.55}
  ]
```

UI: banner = "F1 weekend · day 3 of 3 · Open Multi-day view". Right rail = practice / qualifying / race day-by-day panel.

### 5.4 Super Bowl

```
detect_view_scope(super_bowl_id, user_id, NULL)
→ primary: event_workbench
  primary_mode: mega_event
  secondaries: [
    {performer: Chiefs, score: 0.65},
    {performer: Eagles, score: 0.65},
    {venue: SoFi, score: 0.55}
  ]
```

UI: T1 in mega-event mode (slow cadence, multi-week countdown, comp-SB strip). Mega-event mode auto-derives from `major_event_calendar`.

### 5.5 Hamilton Tuesday-night Broadway

```
detect_view_scope(hamilton_tue_id, user_id, NULL)
→ primary: event_workbench
  secondaries: [
    {season: Hamilton Broadway 2026 (long-run), score: 0.90},
    {performer: Hamilton, score: 0.65},
    {venue: Richard Rodgers Theatre, score: 0.55},
    {allocation: Subscription package #4421 (if user holds), score: 0.80}
  ]
```

UI: banner highlights long-run season aggregate. Right rail = weekly heatmap of upcoming Hamilton dates.

### 5.6 Performer entry — clicked "Knicks" name

```
referrer_scope = 'performer'
→ primary: performer  (T2 Performer Console)
  primary_url: #performer/new-york-knicks
  secondaries: [
    {venue: MSG, score: 0.55},
    {season: Knicks 2026 home, score: 0.80}
  ]
```

UI: T2 Performer Console with home-events-this-season prominent. Each event drill opens T1 with `referrer=performer` for breadcrumb preservation.

### 5.7 Metro entry — clicked "Tonight in NYC"

```
referrer_scope = 'metro'
→ primary: metro  (T5)
  primary_url: #metro/nyc
  secondaries: []
```

UI: T5 Metro Watchlist. Click any event → T1 with `referrer=metro` so the metro context rail shows competing events.

---

## 6. Edge cases

### 6.1 Multiple secondary scopes — how to limit

**Problem**: a Knicks G5 in the playoffs that's ALSO Christmas Day at MSG with the user's allocation triggered.

**Solution**: top 3 by score in the banner; "+N more" expander. Series + Allocation + Mega-event are the three the user MOST cares about.

### 6.2 No applicable scope (one-off event)

**Problem**: a brand-new event from a never-tracked performer at an obscure venue.

**Solution**: banner doesn't render. Just T1 with no extra context.

### 6.3 Conflicting scopes (rare)

**Problem**: an event in two overlapping multi-day campaigns (rare — e.g., a tennis player's tournament that ALSO counts toward an Olympics).

**Solution**: detection function returns BOTH; banner shows both, scored by recency/proximity.

### 6.4 Stale scope detection cache

**Problem**: a series ends, but `series_xref` cache hasn't refreshed.

**Solution**: cache invalidates when `event.lifecycle_status` changes (cron triggers it on game-end).

### 6.5 User has allocation in some games of a series but not others

**Problem**: broker holds Knicks home games G1/G2/G5/G7 but not G3/G4 (those are in Phil).

**Solution**: scope detection per-event. G5 banner shows allocation; G3 banner doesn't. Series view shows the broker's allocation overlay across cards (the broker can see "I have inventory in 4 of these 7").

---

## 7. Schema additions for auto-populate

| # | Object | Purpose |
|---|---|---|
| 1 | `series_xref` table | Maps event_id → series_id (the proposed table from `terminal-only-redesign §4`) |
| 2 | `multi_day_event_link` table | Maps event_id → (campaign_id, day_number, total_days) for F1/tennis/golf |
| 3 | `tour_metadata` (deferred) | Maps event_id → (tour_id, stop_number, total_stops) |
| 4 | `season_xref` (lightweight) | Auto-derived from `events.primary_performer_id + season_year + is_home`. Could be a view. |
| 5 | `inventory_allocation` (already proposed) | Per-user per-event-set allocation tracking |
| 6 | `detect_view_scope()` function | The aggregator described above |
| 7 | `scope_detection_cache` table | Cached results per (event_id, user_id, referrer) — TTL 60s |

---

## 8. Implementation priority

The detect_view_scope function is implementable TODAY for several scopes:

| Scope | Required data | Status |
|---|---|---|
| Single event (default) | `events` | ✅ ready |
| Series | `matchup_xref` + name parsing | ✅ ready (matchup_xref has 445 rows) |
| Allocation | `inventory_allocation` (NEW) | 🔴 needs schema |
| Mega-event | `major_event_calendar` | ✅ ready (14 rows live) |
| Performer | `events.primary_performer_id` | ✅ ready |
| Venue | `events.venue_id` | ✅ ready |
| Metro | `metro_id_lookup` (NEW) | 🟡 needs seed |
| Tour | `tour_metadata` (deferred) | 🔴 needs ingest |
| Multi-day | `multi_day_event_link` (NEW) | 🔴 needs schema |
| Season | derived from existing fields | ✅ ready |

**Ship sequence recommendation**:
1. **Phase 1** — series + performer + venue + season (all data exists today). Banner renders for these. Single endpoint covers ~80% of cases.
2. **Phase 2** — allocation (after `inventory_allocation` ships). High value for season ticket holders.
3. **Phase 3** — mega-event (just wires the existing `major_event_calendar` to the banner). Quick win.
4. **Phase 4** — metro after `metro_id_lookup` seeded.
5. **Phase 5** — tour + multi-day after their respective table ingests.

---

## 9. Connection to the existing terminal

The 6 templates in `static/_proposals/templates.html` are the rendering targets. Auto-populate adds a thin LAYER on top:

- Every event entry-point fires `detect_view_scope()` on click.
- The banner element (per §3.1) renders ABOVE the chart band on T1 with up to 3 scope hints.
- Right-side scope rail (per §3.3) renders when user came from a non-default scope OR when scope score > 0.85.
- Tab strip at top (existing) gets a small "scope" indicator on tabs that have an applicable scope (e.g., the workbench tab gets a series icon when on a series-game).

No template rewrite needed. Just adding the banner element + side rail + scope indicator and wiring the API call.

---

## 10. Status

Filed by: design · 2026-05-08

Answers Julian's "how do we auto-populate views" question with a 3-step pipeline: click → backend `detect_view_scope()` → frontend renders primary + secondary scope affordances. Ship sequence respects current data state — series/performer/venue/season are ready today.

Companion to: `terminal-only-redesign-2026-05-08.md`, `simulations-edge-and-ui-2026-05-08.md`.

Awaiting Julian's review and direction on whether to extend the templates.html skeleton with banner + scope-rail elements next, or focus on shop.html / undelivered.html media polish first.
