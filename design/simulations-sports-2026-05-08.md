# Sports simulations — fresh exercise (2026-05-08)

> **Audience**: claude design + Julian (code).
>
> **Scope**: ~30 sports scenarios across 7 sport groupings (NBA / NFL / MLB / NHL / WNBA / MLS / F1+Tennis+Golf) — 5 each. Run as a fresh simulation pass, not a port of the non-sports doc.
>
> **Companion**: `design/simulations-non-sports-2026-05-08.md` (Concerts / Comedy / Theater).
>
> **Mandate (Julian, 2026-05-08)**:
> - Sports gets the FULL data deck: EVO + SD + SG + ESPN team + ESPN player + ESPN injuries + ESPN news + (future) weather.
> - Per-event view stays as the workhorse (T1) — but DON'T just rerun non-sports through it; sports has structurally different work.
> - Real-time injury updates on charts, real-time sales on charts, price-move dots, news markers.
> - Allocation View becomes a HEADLINE surface here — season tickets, partial plans, multi-game packages are the dominant inventory pattern.
> - Custom user-created zones still relevant.
> - Day-trader feel.

---

## 0a. Data reality 2026-05-08 (calibration after Supabase pass)

ESPN athlete data is currently populated for 3 leagues only:

| League | espn_athletes rows | Player-driven sims supported? |
|---|---:|---|
| MLB | 545 | 🟢 fully (deepest coverage) |
| NBA | 281 | 🟢 fully |
| MLS | 31 | 🟡 thin — works for biggest names |
| NFL | 0 | 🔴 player-overlay sims degrade to team/news/standings only |
| NHL | 0 | 🔴 same — no athlete data; team-level fine |
| WNBA | 0 | 🔴 same — see WNBA-1 caveat below |
| World Cup | (news only) | 🟡 594 news rows but no athlete tracking |

**`espn_team_snapshots` (365), `espn_injury_snapshot_latest` (1973 active), `espn_news` (594) cover the linked leagues fully** — so team-level signals work for all sports above. It's specifically the player-row scenarios (a star scratched, a pitcher matchup, a single-star draws) that need calibration. Each scenario below carries a **Data caveat** line where reality differs from intent.

`major_event_calendar` is also live (14 tentpole rows: Super Bowl, Stanley Cup Final, MLS Cup, etc.) — Mega-event mode auto-detects from this, no new schema needed for that piece.

The 30 sim shapes hold. Where data is thin, the sim documents what to render today vs after ingest catches up.

---

## 0. TL;DR

Sports differs from non-sports in 6 structural ways the simulations exercise:

1. **ESPN is foundational.** Every sports event can layer team standings + injuries + player news + game importance. Non-sports has none of this.
2. **Season tickets dominate.** Most professional-sports inventory is bought as fixed allocations (season tickets, half-season, partial plans). The Allocation View is the broker's primary work surface for many days.
3. **Live game state matters intra-day.** A star scratched 90min before tipoff swings prices instantly. Non-sports doesn't have this.
4. **Tournament structures.** NBA In-Season Tournament, MLS Concacaf/US Open/Leagues Cup, NFL playoff brackets, WNBA Commissioner's Cup. Each is its own scope.
5. **Multi-day single events.** F1 weekends, tennis tournaments, golf majors — one buy covers multiple days, demand profile is per-day.
6. **Demand swings on standings/elimination.** Late-season win/loss outcomes swing 5+ events at once across the league. No equivalent in concerts.

Each section below picks 5 scenarios that exercise those differences. The Allocation View, real-time injury overlay, and ESPN context band are referenced repeatedly because they appear in nearly every scenario.

---

## 1. What's different from the non-sports doc

| Element | Non-sports | Sports |
|---|---|---|
| ESPN block | hidden by default | always visible (when has_espn=true), and often the loudest signal on the page |
| Allocation View | sometimes (residencies, holiday runs) | almost always — season tickets are the default inventory pattern |
| Real-time injury overlay | n/a | live news markers on the chart, animated when a status changes |
| Standings/elimination context | n/a | a "playoff position" pill on the event hero, color-shifts as standings change |
| Game-importance flag | n/a | derived from ESPN: rivalry / playoff stage / division-implication / record-chase / clinch-game / elimination-game |
| Comparable matchups | "last 5 similar shows" (perf+venue) | "last 5 G5s in this matchup" — series-position-aware via `find_similar_events` |
| Weather | rarely matters | matters for outdoor sports (NFL, MLB, MLS, F1) — NOAA `why_signals` overlay when wired |
| Player-level data | rarely (athlete-on-tour edge case) | always available; star injury news drives demand |
| Multi-day pass | rare (Coachella exception) | frequent (F1 weekend, tennis grand slam, golf major) |
| Tournament context | n/a | NBA IST, MLS Concacaf+USopen+LeaguesCup, NFL/NHL/MLB playoff brackets |

---

## 2. NBA — 5 scenarios

### NBA-1 · Star scratched 90min before tipoff

- **Persona / intent**: pricer + ops together. Joel Embiid listed as DOUBTFUL → OUT at 5:00pm for a 7:00pm tipoff. Ticket prices need to react in real-time. The broker has to decide: dump aggressively now or wait for the secondary scratch (sometimes the star plays anyway).
- **Scope**: 3 — single event, holistic + REAL-TIME injury overlay
- **Data sources**: EVO (sub-30s tick), ESPN injuries (live status changes — pulled every 2min via cascade), Twitter (live "Embiid out" mentions FUTURE), historical comparable scratches from `find_similar_events`.
- **Primary view**: T1 Event Workbench in **DENSE** mode — chart range default 6h, refresh 10s, ESPN injury panel pinned to top-right, big "INJURY ALERT" banner if status changes within last 30min.
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Auto-Pricer · **Comparable Scratches** (new: filtered to recent games where star was scratched <2h before tipoff)
  - Hide: long-history chart (irrelevant in next 2h)
  - Show: ESPN injury feed widget — last 5 status changes with timestamp
- **Real-time elements**:
  - Injury overlay on chart — every status change drops a dot at the timestamp + price snapshot at that moment
  - Sales tape — every clearance shows on the chart
  - Auto-recompute owned-premium every 30s
  - Toast banner if status changes ("Embiid OUT — 17:02:34")
- **Allocation note**: if seats are part of season-ticket allocation, "cost basis already covered" indicator turns green (you can dump at any price; it's bonus). If random buys, cost-basis floor matters.
- **Custom zones**: rarely — too fast for analytical setup
- **2-sec answer**: how much demand has dropped in the 5min since the news

### NBA-2 · NBA In-Season Tournament — group stage night

- **Persona / intent**: pricer covering 4 IST games happening simultaneously. The format makes some games more important than others (a winner advances; a loser eliminated). Pricer wants to see all 4 + cross-correlate.
- **Scope**: 7 — single category, holistic; filtered to "tonight's IST games"
- **Data sources**: EVO per-game, ESPN standings (IST group standings — different from regular season standings), ESPN injuries, news.
- **Primary view**: NEW **Tournament Mode** in T6 — tournament bracket visualization on top showing all 4 nights' games + their group standings + advancement implications. Click a game → drilldown to T1.
- **Tabs / hide-shows**:
  - Tabs: All IST games · Group A · Group B · Group C · Group D · East/West splits
  - Hide-show: regular-season standings (toggleable; some pricers want both)
  - Show: "Win-and-in" / "Loss-and-out" tags on individual games
- **Real-time elements**: when one game ends mid-evening, the OTHER 3 games' standings re-shuffle — instant price reaction in the unfinished games. Show this as a "Standings shift" toast.
- **Allocation note**: IST games for season ticket holders are part of the regular-season allocation. The IST premium (small but real) goes 100% to the broker since the holder paid season-pricing.
- **Custom zones**: standard NBA zones from venue
- **2-sec answer**: which IST game has the steepest demand because of late-night standings implications

### NBA-3 · Playoff Series Game 5 — series tied 2-2

- **Persona / intent**: series pricer mid-playoff. G5 with series tied 2-2 is the most-pivotal regular game (winner is one game from advancing). Demand always spikes vs G1.
- **Scope**: 4 — series; reuses T6 series mode
- **Data sources**: EVO per-game (G1-G5), ESPN injuries (still live), `matchup_history` for prior G5 outcomes between these teams, `find_similar_events` for "playoff G5 with series tied 2-2"
- **Primary view**: T6 Series mode — 7 columns G1..G7. Played games (G1-G4) shown grayed with retail-then-decay arc; G5 column highlighted as "now"; G6/G7 contingent.
- **Tabs / hide-shows**:
  - Tabs: Series timeline · Cross-series comparables · Comp G5s historical
  - Hide-show: per-game ESPN context band (toggleable)
  - Show: a "series momentum" chart underneath — 4-game results visualized as +/- swings
- **Real-time elements**: live injury feed for both teams' rosters; sales tape on G5; if series score CHANGES (G5 ends mid-evening), G6/G7 prices reprice instantly.
- **Allocation note**: playoff packages are common (separate from regular-season allocation). A broker may have G1-G7 home-game allocation for one team. Allocation View shows "5 of 7 sold; remaining G6 if necessary" with corresponding cost-basis math.
- **Custom zones**: standard NBA zones
- **2-sec answer**: how does this G5 price vs comparable historical G5s with series tied 2-2

### NBA-4 · Christmas Day — multi-game holiday slate

- **Persona / intent**: pricer covering NBA's 5-game Christmas Day slate. Premium across the board (it's a Holiday Game flag). But each game has its own context.
- **Scope**: 7 — single category, holistic; filtered to date=Christmas Day
- **Data sources**: EVO per-game, ESPN team rivalries (Lakers-Warriors is bigger than other matchups), holiday-flag derived from `events.occurs_at_local`.
- **Primary view**: a **dedicated holiday slate view** — 5 game cards in a row, each showing premium-vs-baseline (current retail vs same-matchup non-Christmas median).
- **Tabs / hide-shows**:
  - Tabs: Christmas slate · Premium vs baseline · Per-game drill
  - Hide-show: rivalry weight indicator (some matchups have higher weight than others)
- **Real-time elements**: per-game sales velocity ticker; rivalry flag changes if standings shift mid-day.
- **Allocation note**: Christmas Day games for season ticket holders are part of the package. Broker often holds ALL 5 Christmas games at MSG/Lakers etc as part of premium-game lineup; the holiday premium is the "extra value" layer above season-pricing.
- **Custom zones**: less common — these are big single-day events
- **2-sec answer**: which Christmas game's premium is biggest opportunity vs baseline

### NBA-5 · Trade deadline — star traded mid-season

- **Persona / intent**: pricer reacting to a trade announcement. Donovan Mitchell traded from Cleveland to Miami at 3pm. Demand crater for Cavs upcoming home games (5 in next 30 days), spike for Heat games. Cross-event impact across two teams.
- **Scope**: 8 — TWO single-performer scopes, simultaneously (Cavs full schedule + Heat full schedule)
- **Data sources**: EVO across both teams' upcoming events, ESPN player snapshots (live update of which roster Mitchell is on), Twitter/Reddit (FUTURE — trade reaction sentiment), historical comparable trades.
- **Primary view**: a NEW **Trade Impact Mode** — split-screen: Cavs upcoming schedule (left) and Heat upcoming schedule (right), each showing per-event price + 6h delta. Above: a banner with the trade announcement timestamp + "X events affected".
- **Tabs / hide-shows**:
  - Tabs: Cavs (departing team) · Heat (incoming team) · Combined timeline
  - Hide-show: ESPN player history (Mitchell's career stats overlay)
  - Show: "comparable trade impact" panel — last 3 mid-season trades and their +/- impact on per-event demand
- **Real-time elements**: live trade-reaction sentiment; sales velocity per team over next 60min after announcement.
- **Allocation note**: cost basis for season ticket allocations doesn't change, but the per-event "expected sale price" model needs to be retrained — the entire allocation's remaining-games-value just shifted.
- **Custom zones**: per-team standard
- **2-sec answer**: which 3 events have the most $ at risk from the trade (regardless of direction)

---

## 3. NFL — 5 scenarios

### NFL-1 · Sunday slate — 8 simultaneous games

- **Persona / intent**: pricer monitoring 8 NFL games at 1pm ET kickoff. Different time zones, different markets, different importance levels. Need a HUD.
- **Scope**: 7 — single category, holistic; filtered to "this Sunday"
- **Data sources**: EVO per-game, ESPN standings (impacts playoff seeding), injuries, weather (FUTURE — outdoor games matter).
- **Primary view**: NEW **Sunday HUD Mode** — 8 game tiles in a 4×2 grid. Each tile: matchup logos, current retail, premium vs baseline, weather alert, injury alert, S4K share. Tiles flash when something changes.
- **Tabs / hide-shows**:
  - Tabs: 1pm slate · 4pm slate · Sunday Night · Monday Night · Thursday Night
  - Hide-show: weather panel per game (default on for outdoor games only)
  - Show: per-game seeding implication tag ("Win = clinch division")
- **Real-time elements**: pre-game injury inactives (released 90min before kickoff); weather alerts (rain in Buffalo); sales velocity ticker per tile.
- **Allocation note**: NFL home-team allocation = 9 games (8 reg + 1 preseason). Sunday slate of road games for season ticket holders doesn't apply. But brokers OFTEN hold Sunday Ticket aggregates from multiple teams.
- **Custom zones**: per-stadium standard zones (NFL stadium zones are well-categorized)
- **2-sec answer**: which game has the most-changing demand right now — flag the leader

### NFL-2 · Monday Night Football singleton

- **Persona / intent**: pricer with a single big primetime game. ESPN MNF context is huge — analyst chatter, prime-time injury reports, betting interest.
- **Scope**: 3 — single event, holistic
- **Data sources**: EVO, ESPN injuries (real-time), ESPN news, weather (FUTURE), Twitter MNF chatter (FUTURE)
- **Primary view**: T1 Event Workbench in **prime-time variant** — bigger ESPN context band, extra "media coverage" panel showing ESPN news pipeline (analyst predictions, betting line moves).
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Auto-Pricer · ESPN Live Feed
  - Hide-show: weather radar (when outdoor)
  - Show: "Vegas line move" overlay (when wired) — betting line moves often correlate with ticket price moves
- **Real-time elements**: live injury feed; weather updates 30min before kickoff; pre-game inactive list (NFL inactives drop 90min before).
- **Allocation note**: MNF home games are part of season-ticket allocation. The MNF premium goes to broker.
- **Custom zones**: stadium-standard
- **2-sec answer**: how is the broadcast/analyst coverage moving demand right now

### NFL-3 · Wild Card weekend — 6-game playoff bracket

- **Persona / intent**: pricer mid-playoffs. Wild Card weekend is 3 days, 6 games. The losers are eliminated; winners advance to Divisional Round. Each game's outcome reshuffles the bracket.
- **Scope**: NEW — **playoff bracket mode**, hierarchical (Wild Card → Divisional → Conf Championship → Super Bowl)
- **Data sources**: EVO across all bracket games, ESPN standings + bracket position, `matchup_history`.
- **Primary view**: NEW **Playoff Bracket Mode** — visual bracket with each round's games. Played games shown as completed; current round highlighted. Click any future-round slot → see "if X advances" pricing scenarios.
- **Tabs / hide-shows**:
  - Tabs: Bracket · This weekend's games · Future rounds (contingent on outcomes)
  - Hide-show: contingent-game prices with "if home team advances" multiplier
  - Show: Super Bowl tracker as the bracket's terminal node
- **Real-time elements**: when a Wild Card game ends, the Divisional round's matchups CRYSTALLIZE — instant price reaction in those events.
- **Allocation note**: playoff packages are separate from regular-season; brokers buy "if-necessary" bundles speculatively.
- **Custom zones**: stadium-standard
- **2-sec answer**: which contingent future-round game has the most asymmetric upside

### NFL-4 · Super Bowl — single most-priced event of the year

- **Persona / intent**: high-stakes pricer. SB is one event but priced over weeks (locks in 2 weeks before kickoff). Daily price moves matter; the demand build-up is its own analytical phenomenon.
- **Scope**: 3 — single event, holistic + multi-week countdown
- **Data sources**: EVO (deep tick), SD (rare comparable: prior SBs), SG, ESPN matchup context, weather, betting lines (FUTURE).
- **Primary view**: T1 Event Workbench in **mega-event mode** — 30-day default chart range, daily resolution, no intraday refresh (this thing moves on a slower cadence). Extra panels: "comparable SBs" and "media coverage tracker".
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Auto-Pricer · Comparable SBs · Media tracker
  - Hide-show: VIP/hospitality breakout (SB has unique zones — "On-Field Cabana", "Champions Club")
  - Show: weeks-to-kickoff timeline at top
- **Real-time elements**: less real-time than other sports (the event is too far out). Daily updates instead.
- **Allocation note**: SB tickets aren't part of any season-ticket allocation; they're individual auctions. Allocation View hidden.
- **Custom zones**: SB-specific premium zones (manually defined per year)
- **2-sec answer**: where does this SB's price track vs the comparable SBs (Super Bowl LVI, LVII, LVIII)

### NFL-5 · Season-ticket holder full home schedule (the foundational allocation case)

- **Persona / intent**: pricer managing a 9-game home-schedule allocation (8 reg + 1 preseason). 4 seats × 9 games = 36 ticket records. Core inventory pattern.
- **Scope**: 10 — fixed-allocation across multiple events; with cost-basis math
- **Data sources**: EVO across all 9 games, ESPN game-importance for each game, weather, historical YoY for each home-game slot.
- **Primary view**: NEW **Allocation Workbench** — top: cost-basis math (package cost ÷ 9 games = $X per-game break-even). Bottom: 9-game timeline showing per-game current-retail vs break-even.
- **Tabs / hide-shows**:
  - Tabs: Allocation timeline · Per-game drill · Bundle vs individual decision · Sold-from-allocation history
  - Hide-show: "remaining games at risk" computed value (if I sold marquee games at premium, am I left with 6 weak games at break-even?)
  - Show: weather risk indicator per game (early/late season weather risk)
- **Real-time elements**: per-game sales velocity; standings-impact alerts (if Week-13 game becomes a clinch-game, demand jumps)
- **Allocation note**: THIS IS the allocation case. The whole view is allocation-aware.
- **Custom zones**: 4 specific seats (Sec 215, Row 6, Seats 1-4) — same physical location for all 9 games
- **2-sec answer**: am I on track to recover cost basis + target margin from the remaining unsold games

---

## 4. MLB — 5 scenarios

### MLB-1 · Yankees season-ticket holder — 81 home games

- **Persona / intent**: the BIGGEST allocation case in sports. 4 seats × 81 home games = 324 ticket records. Pricer needs to see the whole season as one asset.
- **Scope**: 10 — fixed-allocation, full season
- **Data sources**: EVO per-game, ESPN team standings + opponent-strength per game, weather forecast for outdoor games, pitcher matchup data (probable pitchers).
- **Primary view**: full-season **Allocation Calendar** — 81-game grid (~6 months). Each cell color-coded by "current retail vs break-even". Click any cell → T1 Event Workbench for that game.
- **Tabs / hide-shows**:
  - Tabs: Calendar · Sold-from-allocation history · Bundle math (if I sell remaining N games as a partial package vs individually) · Per-month rollup
  - Hide-show: pitcher-matchup per-game annotations (Cole vs Skubal day = premium)
  - Show: weekend vs weekday flag, day-game vs night-game flag
- **Real-time elements**: standings-driven demand changes (clinching scenarios in September)
- **Allocation note**: the whole thing is allocation-driven
- **Custom zones**: 4 specific seats × 81 games
- **2-sec answer**: pace-of-recovery for the full-season investment

### MLB-2 · Subway Series weekend (Yankees-Mets, 3 games)

- **Persona / intent**: pricer for a 3-game rivalry stand. Yankees host Mets at the Stadium for 3 consecutive nights. Premium across all 3 (rivalry tag), but Friday night is the highest-demand.
- **Scope**: 4 — series; cross-game pricing
- **Data sources**: EVO, ESPN matchup history (Yankees-Mets historical pricing), pitcher matchups for each of 3 games, attendance baseline.
- **Primary view**: T6 Series mode (3 columns instead of 7). Historical Yankees-Mets games as comparables.
- **Tabs / hide-shows**:
  - Tabs: 3-game stand · Per-game drill · Subway Series historical
  - Hide-show: pitcher-matchup column per game
- **Real-time elements**: per-game sales velocity; if a starter scratch happens, demand reacts
- **Allocation note**: these games are inside the 81-game home allocation. The rivalry premium is bonus.
- **Custom zones**: standard Yankees zones
- **2-sec answer**: which of the 3 games has the largest premium-over-baseline

### MLB-3 · Doubleheader — 2 games same day

- **Persona / intent**: rare scenario — two MLB games same day at same venue (often happens when a previous game is postponed). 2 events sharing 1 day, often shared inventory.
- **Scope**: 4 — series (2-game) + UNIQUE same-day complication
- **Data sources**: EVO for both games, ESPN, weather (single forecast covers both).
- **Primary view**: NEW **Doubleheader Mode** — 2 events shown as adjacent cards, with the same physical seat allocation showing for BOTH games (the "doubleheader package" is one ticket valid for both, OR two separate tickets — depends on team policy).
- **Tabs / hide-shows**:
  - Tabs: Game 1 · Game 2 · Combined "doubleheader package" if applicable
  - Hide-show: same-day weather (one forecast)
- **Real-time elements**: shared sales tape if it's a single doubleheader package; separate if individual.
- **Allocation note**: VERY important — does the season-ticket holder's seat get them BOTH games (traditional doubleheader) or just one (split doubleheader)? Allocation logic differs.
- **Custom zones**: standard
- **2-sec answer**: is the doubleheader policy "single ticket for both" or "separate tickets"

### MLB-4 · Rain delay / postponement — same-game re-pricing

- **Persona / intent**: ops + pricer pair. Game scheduled tonight gets postponed at 5pm. All inventory needs to migrate to the makeup date (tomorrow afternoon). Pricer needs to reset.
- **Scope**: 3 — single event, holistic + LIFECYCLE TRANSITION
- **Data sources**: EVO, ESPN scheduling, weather forecast for makeup date, ticket-validity policy (does original ticket hold for makeup?)
- **Primary view**: T1 in **postponement mode** — banner across the top: "POSTPONED → makeup at [new date/time]". The chart range shifts to span both the original schedule and the makeup. All inventory shows with "valid for makeup" indicator.
- **Tabs / hide-shows**:
  - Tabs: Postponement details · Makeup date · Refund-eligible inventory
  - Hide-show: "auto-migrate to makeup" toggle (if team policy = ticket holds for makeup)
- **Real-time elements**: postponement announcement timestamp; makeup-date weather forecast updates.
- **Allocation note**: season-ticket allocation auto-migrates by team policy; random buys may not.
- **Custom zones**: standard
- **2-sec answer**: how much of our inventory needs immediate action vs auto-migrate

### MLB-5 · Pitcher matchup pricing — Cole vs deGrom

- **Persona / intent**: mid-season pricer. Game-day pitching matchup is announced 2 days before. Cole vs deGrom is +20% over a generic matchup of same teams.
- **Scope**: 3 — single event, holistic + PITCHER OVERLAY
- **Data sources**: EVO, ESPN player snapshots (probable starters), historical pitcher-vs-pitcher pricing (when both are starting), Twitter (FUTURE).
- **Primary view**: T1 in **pitcher-matchup variant** — pitcher headshots + season ERA / strikeouts shown prominently in hero band. Below: "comp games where these two started" as horizontal cards.
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Pitcher matchup history
  - Hide-show: ESPN team standings (toggleable; pitcher matchup eclipses standings on these games)
  - Show: pitcher-headshot block in hero
- **Real-time elements**: live injury feed for pitchers (a late scratch crashes demand fast); per-game sales velocity.
- **Allocation note**: standard MLB allocation
- **Custom zones**: standard
- **2-sec answer**: how does this pricing compare to historical Cole-vs-deGrom games

---

## 5. NHL — 5 scenarios

### NHL-1 · Stanley Cup Final Game 7

- **Persona / intent**: highest-stakes single-game pricing. Game 7 of the Final is the most-priced regular game of the year (after maybe SB+World Series G7).
- **Scope**: 3 — single event, holistic; reuses Series mode comp panel
- **Data sources**: EVO (deep tick), ESPN, `matchup_history` for prior G7 Finals.
- **Primary view**: T1 with **mega-stakes mode** — bigger ESPN context, mega "winner-take-all" banner, comp G7s historical strip.
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Auto-Pricer · Comp G7 Finals
  - Hide-show: regular-season standings (irrelevant)
  - Show: Cup-history sidebar (when has each franchise last won?)
- **Real-time elements**: pre-game injury feed; sales tape moves continuously the day of.
- **Allocation note**: not part of season allocation; speculative buy.
- **Custom zones**: arena-specific premium tiers
- **2-sec answer**: where does this G7 price vs the last 5 SC G7s

### NHL-2 · Winter Classic — outdoor game, weather-foundational

- **Persona / intent**: pricer for an outdoor NHL game. Weather is the FOUNDATIONAL signal — temperature, snow forecast, wind drive demand and refund-policy decisions.
- **Scope**: 3 — single event, holistic + WEATHER FOUNDATIONAL
- **Data sources**: EVO, ESPN, NOAA weather (FUTURE — multi-day forecast updating hourly).
- **Primary view**: T1 in **outdoor event mode** — weather panel pinned to top, multi-day forecast strip, "weather-impact" annotation on the chart.
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Weather forecast · Comp outdoor games
  - Hide-show: indoor-only data (irrelevant)
  - Show: "kickoff conditions" predicted forecast at game-time
- **Real-time elements**: weather forecast updates hourly; bad-weather alert if storm probability rises.
- **Allocation note**: Winter Classic is a special event — outside normal season allocation.
- **Custom zones**: outdoor-stadium-specific (different from arena)
- **2-sec answer**: how is the weather forecast moving demand

### NHL-3 · Trade deadline NHL — same pattern as NBA

- **Persona / intent**: similar to NBA-5 but NHL-specific. NHL trade deadline is a fixed date with HEAVY trading volume in the days before.
- **Scope**: 8 — performer-cross-event impact
- **Data sources**: EVO, ESPN player news, Twitter trade rumors (FUTURE).
- **Primary view**: same Trade Impact Mode as NBA-5 but with NHL teams.
- **Tabs / hide-shows**: same as NBA-5
- **Real-time elements**: live trade announcements crashing/spiking team demands.
- **Allocation note**: same
- **Custom zones**: NHL-arena-standard
- **2-sec answer**: which 3 NHL events have the most $ at risk

### NHL-4 · Original Six rivalry — Bruins vs Canadiens

- **Persona / intent**: regular-season rivalry premium. Bruins-Canadiens is +25% over generic Bruins game.
- **Scope**: 3 — single event with rivalry overlay
- **Data sources**: EVO, ESPN team rivalry data, `matchup_history`.
- **Primary view**: T1 with **rivalry banner** — rivalry-premium tag on hero, comp matchups strip.
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Comp rivalry games
  - Show: rivalry-premium computed value
- **Real-time elements**: standard sales tape + injury feed
- **Allocation note**: standard
- **Custom zones**: arena-standard
- **2-sec answer**: how does this rivalry game's premium compare to the last 5 of this matchup

### NHL-5 · Playoff race elimination scenarios — last 2 weeks

- **Persona / intent**: late-season pricer. 2 teams fighting for last wild-card spot. Each team's remaining games matter cumulatively. Demand for clinch-eligible games swings wildly on competitor outcomes.
- **Scope**: 8 — single performer (one team's remaining schedule) with cross-event correlation
- **Data sources**: EVO, ESPN standings (live updates), `event_lifecycle`.
- **Primary view**: NEW **Elimination Mode** — schedule-strip + "playoff position" tracker showing how each remaining game changes elimination math. "Win-and-in" / "must-win" / "elimination-game" tags per game.
- **Tabs / hide-shows**:
  - Tabs: Schedule · Elimination scenarios · Cross-team competitor schedule
  - Hide-show: tied-team's schedule (toggleable — competitor's wins/losses change THIS team's standings)
- **Real-time elements**: when a competitor's game ends, this team's standings shift, triggering price reaction in upcoming games.
- **Allocation note**: season-ticket games — standard
- **Custom zones**: arena-standard
- **2-sec answer**: which of the next 5 games has highest elimination-stakes demand

---

## 6. WNBA — 5 scenarios

### WNBA-1 · Caitlin Clark / single-star draws — **degraded to team-level today**

- **Data caveat (2026-05-08)**: WNBA athletes are not yet ingested (`espn_athletes` = 0 WNBA rows). The original sim assumed Clark-specific status drives the view. **Today this degrades to a team-level proxy**: Indiana Fever's home/away pricing premium acts as the demand signal. When WNBA athletes get ingested, the sim resumes the original shape (player-overlay panel, Clark status as primary driver).
- **Persona / intent**: pricer reacting to star-team-driven demand. Fever home games trade 3-5x non-Fever WNBA games — driven by Clark's presence, but the player attribution is currently team-level not athlete-level in our data.
- **Scope**: 8 — single performer (Indiana Fever)
- **Data sources today**: EVO, ESPN team snapshots (Indiana Fever record + standings), ESPN news (594 news rows include 33 WNBA), team-level injury (when WNBA team rosters land). Twitter (FUTURE — Clark mentions).
- **Data sources after WNBA athlete ingest**: add `espn_athletes` row for Clark + `espn_injury_snapshot_latest` filtered to her athlete_id.
- **Primary view today**: T1 in **single-team-driven variant** — large team-record + streak panel (where ESPN team data IS populated for WNBA), 33 news rows surfaced as a "WNBA news" feed when relevant. The "with Clark / without Clark" comparison stays in the design as a stub — it activates when athlete data lands.
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Star-impact comparable games (placeholder when athlete data missing)
  - Show: team news feed; team standings; record vs season
  - Hide-show: athlete-status block (default hidden when `espn_athletes` for the team is empty)
- **Real-time elements**: WNBA news ticker; team-level injury news.
- **Allocation note**: Fever season tickets exist; Allocation View applies.
- **Custom zones**: WNBA-arena standard
- **2-sec answer (today)**: is Indiana Fever home demand still elevated this game vs season average. **(Future, after athlete ingest)**: is Clark playing tonight + what's the corresponding premium.

### WNBA-2 · Playoff series — best-of-5 → best-of-7

- **Persona / intent**: WNBA playoff series pricing. Smaller scale than NBA but same structural dynamics.
- **Scope**: 4 — series
- **Data sources**: EVO, ESPN playoff context.
- **Primary view**: T6 Series mode — adapted to best-of-5 (5 columns) or best-of-7.
- **Tabs / hide-shows**: similar to NBA-3
- **Real-time elements**: similar
- **Allocation note**: WNBA playoff packages exist
- **Custom zones**: arena-standard
- **2-sec answer**: where does this series-tied G3 price vs comparable WNBA G3s

### WNBA-3 · WNBA All-Star Game

- **Persona / intent**: single annual event. Premium pricing similar to other all-star events.
- **Scope**: 3 — single event, holistic
- **Data sources**: EVO, ESPN all-star roster, comp prior all-stars.
- **Primary view**: T1 with **all-star variant** — roster panel showing both team rosters + their season stats.
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Comp all-stars
  - Show: all-star roster annotations
- **Real-time elements**: roster announcements drop; injury status of named all-stars.
- **Allocation note**: not part of season allocation
- **Custom zones**: special all-star zones (often customized per host venue)
- **2-sec answer**: where does pricing track vs prior 5 WNBA all-stars

### WNBA-4 · Commissioner's Cup — WNBA's in-season tournament

- **Persona / intent**: parallel to NBA In-Season Tournament. WNBA's mid-season cup. Different demand profile from regular-season games.
- **Scope**: 7 — category, holistic; filtered to Cup games
- **Data sources**: EVO, ESPN standings + Cup-specific standings.
- **Primary view**: similar to NBA IST mode — bracket/group visualization.
- **Tabs / hide-shows**: similar to NBA-2
- **Real-time elements**: standings shift mid-night
- **Allocation note**: Cup games are inside season-ticket allocation
- **Custom zones**: arena-standard
- **2-sec answer**: which Cup game has best margin opportunity

### WNBA-5 · Final regular-season — milestone game potential

- **Persona / intent**: late-season game where a star might break a record (most points in season, etc.). Demand spikes if record is plausible.
- **Scope**: 3 — single event with milestone overlay
- **Data sources**: EVO, ESPN player stats with active-record-watch flags.
- **Primary view**: T1 with **milestone-watch panel** — "X points needed to break record" countdown.
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Player record watch
  - Show: per-game stat-tracker
- **Real-time elements**: in-game stat updates if record is broken mid-game; demand swings post-game depending.
- **Allocation note**: standard
- **Custom zones**: arena-standard
- **2-sec answer**: how plausible is the record-break tonight + what's the demand premium

---

## 7. MLS — 5 scenarios

### MLS-1 · Messi-driven Inter Miami away game — performer-overlay

- **Persona / intent**: pricer for an MLS road game where Inter Miami visits. Messi presence drives 4-8x demand. Single-player demand explosion.
- **Scope**: 3 — single event with performer overlay
- **Data sources**: EVO, ESPN player snapshots (Messi availability), Twitter (FUTURE).
- **Primary view**: T1 with **mega-star panel** — Messi-status (playing/rested/injured), career stats, recent performances.
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Comp Messi away games · Without-Messi pricing comparison
  - Show: Messi-status indicator pinned at top
- **Real-time elements**: live availability status; sales tape jumps if Messi is named to starting XI vs rested.
- **Allocation note**: home-team's season ticket holders may have these games but the Messi premium is bonus.
- **Custom zones**: stadium-standard
- **2-sec answer**: is Messi confirmed to play, and what's the corresponding premium

### MLS-2 · Concacaf Champions League knockout

- **Persona / intent**: pricer for an international tournament match. Cross-league competition. Different demand profile (smaller US fanbase for Concacaf, big for visiting Liga MX team).
- **Scope**: 7 — category, holistic; filtered to "Concacaf KO games"
- **Data sources**: EVO, ESPN — but Concacaf data may be partial in our schema. Twitter (FUTURE — international fan sentiment).
- **Primary view**: T1 with **international tournament variant** — bracket panel + foreign-team fanbase indicator.
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Concacaf bracket · Comp prior KO games
  - Hide-show: ESPN-team (toggleable; might not have Concacaf detail)
- **Real-time elements**: bracket-state changes if other Concacaf games end before this one.
- **Allocation note**: Concacaf is OUTSIDE regular MLS season allocation — special event.
- **Custom zones**: stadium-standard
- **2-sec answer**: how does foreign-team fanbase travel-likelihood affect demand

### MLS-3 · US Open Cup match — knockout against lower-division team

- **Persona / intent**: pricer for a USOC game. Demand soft because lower-division opponent, until the giant-killing storyline emerges.
- **Scope**: 3 — single event
- **Data sources**: EVO, ESPN, comp historical USOC games.
- **Primary view**: T1 with **lower-division-opponent flag** — opponent details panel (which division, recent form, "Cinderella story" indicator if applicable).
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Comp USOC games
  - Hide-show: Cinderella alert if visiting team is on a USOC run
- **Real-time elements**: news-driven demand spike if lower-division team gains attention.
- **Allocation note**: USOC is outside MLS season allocation
- **Custom zones**: stadium-standard
- **2-sec answer**: is this game a "soft" USOC or a "Cinderella drawing attention" USOC

### MLS-4 · Leagues Cup — MLS vs Liga MX cross-league

- **Persona / intent**: cross-league tournament pricing. Half MLS / half Liga MX teams. Different demand profile per matchup.
- **Scope**: 7 — category, holistic; filtered to Leagues Cup games
- **Data sources**: EVO, ESPN (limited Liga MX coverage), Twitter (FUTURE — cross-border fan sentiment).
- **Primary view**: T1 with **cross-league overlay** — Liga MX team fanbase strength indicator + comp prior Leagues Cup games.
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Leagues Cup bracket
  - Hide-show: per-team data quality indicator (Liga MX coverage may be partial)
- **Real-time elements**: bracket updates as games end; Twitter cross-border buzz (FUTURE).
- **Allocation note**: Leagues Cup is outside regular MLS allocation
- **Custom zones**: stadium-standard
- **2-sec answer**: which Leagues Cup matchup has biggest fan-travel demand

### MLS-5 · MLS Cup Final

- **Persona / intent**: championship game. Single biggest MLS event. Pricing builds over a 2-week run-up.
- **Scope**: 3 — single event, multi-week countdown
- **Data sources**: EVO, ESPN, comp prior MLS Cups, weather (often outdoor).
- **Primary view**: T1 in mega-event mode — similar to Super Bowl variant.
- **Tabs / hide-shows**:
  - Tabs: Tickets · View-by-Zone · Comp prior MLS Cups · Media tracker
  - Show: weeks-to-kickoff timeline
- **Real-time elements**: daily-cadence updates (this is a slow-build event).
- **Allocation note**: Cup Final is speculative — outside any season allocation.
- **Custom zones**: Cup-specific premium zones
- **2-sec answer**: pacing vs prior MLS Cups

---

## 8. F1 / Tennis / Golf — 5 scenarios (multi-day single-event sports)

### MD-1 · F1 race weekend — 3-day event

- **Persona / intent**: F1 weekend pricer. 3 days (Practice/Qualifying/Race) + multi-day weekend pass + per-day options.
- **Scope**: 4 — series-like, 3-day; with bundle math
- **Data sources**: EVO across all 3 days + weekend pass SKU, ESPN driver data (limited), weather (FUTURE — track conditions).
- **Primary view**: NEW **Multi-day event mode** — 3-day timeline + a Bundle math panel comparing weekend pass vs per-day sum.
- **Tabs / hide-shows**:
  - Tabs: Per-day · Weekend bundle · Bundle math · Comp F1 weekends
  - Hide-show: weather radar (track conditions)
- **Real-time elements**: weather updates; driver injury news (rare but possible).
- **Allocation note**: F1 weekend bundles are common. Allocation View for buyers who hold the full weekend pass.
- **Custom zones**: track-specific zones (Hairpin / Pit Straight / Final Sector)
- **2-sec answer**: is the weekend bundle still discounted enough to convert vs per-day sum

### MD-2 · Tennis Grand Slam day session — US Open

- **Persona / intent**: 2-week tournament pricer. Day-by-day demand cycle (early rounds soft, semis/finals premium). Ground passes vs stadium passes.
- **Scope**: 6 — single venue, all events; filtered to US Open dates
- **Data sources**: EVO per-day + per-session, ESPN player rankings + injuries.
- **Primary view**: 2-week calendar with per-day sessions; per-session pricing tier.
- **Tabs / hide-shows**:
  - Tabs: Calendar · Per-session drill · Round-by-round demand
  - Hide-show: ground-pass vs stadium-pass split
- **Real-time elements**: top-seed losses cascade to demand drops in later rounds; live mid-match news.
- **Allocation note**: tournament packages exist (full-grounds for 2 weeks).
- **Custom zones**: court-by-court (Arthur Ashe vs Louis Armstrong vs Grandstand)
- **2-sec answer**: where in the round-by-round demand curve is this session

### MD-3 · Major golf tournament — The Masters

- **Persona / intent**: 4-day major + practice rounds. Weekly badge structure. Premium for moving-day Saturday + Sunday.
- **Scope**: 4 — 4-day series
- **Data sources**: EVO per-day, ESPN player leaderboard data, weather.
- **Primary view**: 4-day timeline with leaderboard-driven demand annotations (weekend leaderboard names = demand drivers).
- **Tabs / hide-shows**:
  - Tabs: Per-day · Practice rounds · Tournament rounds · Comp prior Masters
  - Hide-show: weekly-badge bundle math
- **Real-time elements**: leaderboard updates Friday afternoon spike Saturday demand.
- **Allocation note**: weekly badges are the equivalent of season tickets; full-week badge holders have all 4 tournament days.
- **Custom zones**: course-specific (Amen Corner, 18th green, etc.)
- **2-sec answer**: who's leading the leaderboard and how is it moving Saturday demand

### MD-4 · Drive-to-Survive driver-driven demand

- **Persona / intent**: F1 race where a popular driver (Hamilton's last race, Verstappen with momentum) drives outsized demand at a particular stop.
- **Scope**: 3 — single event with driver-overlay
- **Data sources**: EVO, ESPN driver data (limited), Twitter (FUTURE — driver-specific sentiment).
- **Primary view**: T1 with **driver-overlay panel** — driver season stats + career arc + retirement rumors.
- **Tabs / hide-shows**:
  - Tabs: Tickets · Per-zone · Driver impact
  - Show: driver-fan-travel indicator
- **Real-time elements**: driver-news spikes; qualifying-result-driven demand shifts (pole-sitter draws fans).
- **Allocation note**: standard
- **Custom zones**: track-specific
- **2-sec answer**: is the driver narrative spiking demand at this race

### MD-5 · Tennis player ranking shift — top seed loses early

- **Persona / intent**: pricer monitoring a tournament where the top seed loses in R2. Demand for later-round sessions that "would have featured" the top seed crashes.
- **Scope**: 6 — single venue, multi-day; with cascade impact
- **Data sources**: EVO per-session, ESPN player tracking, live match scores.
- **Primary view**: tournament view with **cascade visualization** — when a top seed loses, downstream session demand shifts visualized.
- **Tabs / hide-shows**:
  - Tabs: Calendar · Cascade impact · Sessions affected
  - Hide-show: alternate-storyline detection (other top seeds advancing pick up slack)
- **Real-time elements**: live match scoring; immediate cascade reaction.
- **Allocation note**: standard
- **Custom zones**: court-specific
- **2-sec answer**: how much downstream demand was lost from this upset

---

## 9. Cross-sport UI patterns surfaced

Patterns repeating across sports (mostly NEW vs the non-sports doc):

1. **Allocation View as a top surface** — season tickets, partial plans, weekly badges are everywhere. Visible as a top-level mode toggle, not a buried sub-tab.
2. **Real-time injury overlay on charts** — every sports event needs this. Live status changes annotated as dots/markers on the price line at the moment-of-change.
3. **ESPN context band** — always visible (when has_espn=true). Different from non-sports' Wiki-replacement.
4. **Tournament Mode** — NEW for NBA IST, NFL playoff bracket, NHL playoff race, MLS Concacaf+USOC+Leagues Cup, WNBA Cup, MD-tournaments. Bracket-aware visualization with cascade-effect.
5. **Standings shift toast** — when a competitor's game ends and the active team's standings change, a banner alerts the pricer.
6. **Trade Impact Mode** — split-screen for cross-team trades.
7. **Sunday HUD Mode** — multi-game simultaneous monitoring (NFL Sunday, MLB doubleheader-day, NBA back-to-back evenings).
8. **Mega-event mode** — Super Bowl, Stanley Cup G7, MLS Cup Final, Masters, Wimbledon final. Slower cadence, multi-week buildup.
9. **Postponement mode** — lifecycle transition handling for rain delays / weather-cancellations.
10. **Star-overlay panels** — Caitlin Clark, Messi, top-seed tennis players, F1 driver narratives. The performer is the demand driver.
11. **Pitcher-matchup variant** (MLB-only) — pitcher-headshots in hero band.
12. **Outdoor-event variant** (NHL Winter Classic, NFL outdoor, MLB, MLS) — weather panel pinned, multi-day forecast.
13. **Multi-day event mode** (F1, tennis, golf) — bundle math + per-day breakdown.
14. **Elimination Mode** — late-season teams fighting for playoff spots; cross-team standings dependency.
15. **Pre-game inactives drop** — NFL (90min), NBA (1h), MLB (lineups). A pre-game window where injury reports drop and prices react.

---

## 10. Schema additions surfaced by sports sims

Beyond what was already in `terminal-only-redesign-2026-05-08.md`:

| # | Addition | Why |
|---|---|---|
| 1 | `inventory_allocation` table | Per Julian's many-to-many addition to non-sports doc; foundational for sports |
| 2 | `tournament_xref` | Map events to tournament structure (NBA IST, MLS Concacaf, NFL playoffs, etc.). Includes round + advancement info. **NOTE 2026-05-08**: `major_event_calendar` is already live (14 tentpole rows: SB, SCF, MLS Cup, etc.) — Mega-event mode for major-event detection auto-derives from this; tournament_xref is the broader structure layer. |
| 3 | `game_importance_flag` derivations | Rivalry / clinch-scenario / elimination / record-watch — derived nightly from ESPN context |
| 4 | `pre_game_inactives` table | NFL inactives release, NBA injury report, MLB lineup. Time-stamped. Drives the 90min-before alert. |
| 5 | `weather_forecast` (NOAA exposed) | Per-event-per-day forecast. Updated hourly. **NOTE 2026-05-08**: `why_signals` table exists with weather schema (3 stub rows) — infrastructure ready, more data ingest pending. |
| 6 | `pitcher_matchup` table (MLB-specific) | Probable starters per game. Drives the pitcher-overlay panel. |
| 7 | `player_active_record_watch` | Players approaching career milestones. Drives WNBA-5 milestone-watch panel. |
| 8 | `trade_event` log | Per-trade audit log with timestamp + players-affected + teams-affected. Drives Trade Impact Mode. |
| 9 | `standings_snapshot_intraday` | Current standings as games end. Drives Standings Shift toasts and Elimination Mode. |
| 10 | `multi_day_event_link` table | F1 weekend / tennis tournament / golf major: link 3-7 events as a "weekend bundle" with shared inventory. |

---

## 11. Status

Filed by: design · 2026-05-08
Companion to `simulations-non-sports-2026-05-08.md`. Fresh exercise — different scenarios, different surfaces, different schema needs.
No code changes. No backend writes.
30 sims across 7 sport groupings + 15 cross-sport UI patterns + 10 schema additions.
Ready for review and to drive prioritization on the Allocation View + Tournament Mode + real-time injury overlay implementations.

Edge-case + UI-element simulations (the third doc Julian asked for) come next when greenlit.
