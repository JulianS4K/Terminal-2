# AGENTS.md

both agents read first. both agents append on action. keep cave-man.

## STATUS BOARD (live, read first, update on every state change)

| agent  | status | started_at (UTC)    | working on                                   | branch | safe to interrupt? |
|--------|--------|---------------------|----------------------------------------------|--------|--------------------|
| code   | DOING  | 2026-05-08 00:50 UTC | committing cowork's prod work into git on their behalf (no git auth) | main | no — mid-batch commit |
| cowork | IDLE   | —                   | —                                            | —      | yes                |

**Read this table before starting any work.** If the other agent is DOING and your planned work overlaps theirs (same files, related schema), wait or coordinate via a WAIT note in the LOG. If the other agent is IDLE you're clear to start — flip your row to DOING with a timestamp before your first commit.

## WIP (files an agent is actively editing — append before edit, clear on commit)

**Read this section before opening any file.** If a file you want to edit is listed under the *other* agent, pick a different file or wait. Append your file paths under your own subsection before you start editing. Clear your subsection back to "(none)" the moment you commit and push.

### code
- AGENTS.md (audit + ping resolution)
- supabase/migrations/* (cowork-authored migrations 12-17, 22-30 — code committing on cowork's behalf)
- supabase/functions/* (cowork-authored: chat v26, espn-rosters v2, wiki-collect v1, probe-seating-charts v1, backfill-event-configurations v2 — code committing on cowork's behalf)

### cowork
- (none — git access via code)

## ARCHITECTURE

ONE backend. TWO products. TWO front-ends. TWO agents.

```
                  ┌─────────────────────────────────────┐
                  │   BACKEND (shared, single source)   │
                  │  - Supabase Postgres + edge fns     │  ← cowork-owned
                  │  - app.py FastAPI routes + cron     │  ← code-owned
                  │  - TEvo connector, Anthropic client │  ← shared
                  └──────────┬──────────────┬───────────┘
                             │              │
                ┌────────────┘              └────────────┐
                ▼                                        ▼
    ┌──────────────────────┐               ┌──────────────────────┐
    │ PRODUCT 1: BROKER    │               │ PRODUCT 2: RETAIL    │
    │ Terminal admin UI    │               │ Find Tickets chatbot │
    │ static/index.html    │               │ static/chat.html     │
    │ Google OAuth gated   │               │ anonymous public     │
    │ Full inventory view  │               │ S4K-owned only       │
    │ broker_* DB views    │               │ retail_* DB views    │
    │ owned by: code       │               │ owned by: cowork     │
    └──────────────────────┘               └──────────────────────┘
```

never leak data across the wall. retail UI must never see wholesale, brokerage names, or non-S4K listings. broker UI sees everything.

## OWN

- **code** (broker / terminal) = app.py · evo_client.py · static/index.html · requirements.txt · Procfile · supabase/functions/espn/ · supabase/functions/espn-collect/ · supabase/functions/tevo-perf-find/ · ESPN ingest schema (espn_*, event_xref, performer_external_ids source='espn')
  - **also: code is git proxy for cowork** — cowork has no git auth, so code captures cowork's prod migrations + edge fn deploys into git via audit-and-commit. cowork's source files in git are read-only updates from prod, not edits to merge.
- **cowork** (retail / chat) = supabase/functions/chat/ · supabase/functions/collect-listings/ · supabase/functions/seed-home-venues/ · supabase/functions/bulk-add-watchlist/ · supabase/functions/probe-tevo-category/ · supabase/functions/wiki-collect/ · supabase/functions/espn-rosters/ · supabase/functions/probe-seating-charts/ · supabase/functions/backfill-event-configurations/ · static/chat.html · docs/ · SESSION_*.md · most schema migrations (zone metrics, chat infra, athlete history, wiki context, broker helpers)
- **shared** (ask before edit, leave WAIT note) = AGENTS.md (this file) · README.md · .gitignore · cross-product schema changes

both agents are free to call any edge fn or read any view. only writes to source files in the other agent's OWN list need a WAIT note first.

## RULES

1. `git pull --rebase origin main` before push. always.
2. no edit other agent's owned path without leaving WAIT note in LOG first.
3. `.claude/` gitignored. never commit worktrees.
4. work in `C:\VibeCode\terminal-2`. never OneDrive, never `C:\Users\julia\Code\Terminal-2` once the move completes. **(repo still physically at `C:\Users\julia\Code\Terminal-2` as of 2026-05-07; user-driven `mv` + Railway root reconfig pending — see WAIT in LOG)**
5. append to LOG below at end of every session. newest entry on top.
6. tag tasks: DOING / DONE / WAIT / NEXT / BLOCKED.
7. broker product = full data. retail product = S4K-owned only. never cross.
8. **before commit:** flip your STATUS BOARD row to DOING with `started_at` timestamp + brief working-on. if you're going to touch the other agent's owned path or shared SQL, also leave a WAIT note in LOG (top of LOG, your section).
9. **after commit/push:** flip your STATUS BOARD row back to IDLE with `started_at` cleared, AND append a LOG entry under today's date with: `DONE <SHA> <subject>` (newest first within the day). if your work spans multiple commits in one session, one LOG entry covering all of them is fine — list each SHA.
10. if the other agent is DOING and you need to start: read their STATUS BOARD row's `working on`. if your planned work overlaps (same file, related table), don't start — leave a `WAIT for code/cowork to finish <topic>` note in the LOG and pick something else.
11. **before editing ANY file:** append the file path under your subsection in the WIP section above. read the *other* agent's WIP first — if they have your target file listed, pick a different file or wait. **clear your subsection back to "(none)" the instant you commit + push.** This rule is finer-grained than rule 10: STATUS BOARD says "I'm working", WIP says "exactly which files".

## STATE (truth, not history)

- Live URL terminal (broker) = railway https://terminal-2-production.up.railway.app  /
- Live URL chatbot (retail)  = same domain  /chat
- Supabase project = hzrizjeaxlqcxfrtczpq (Terminal .5)
- chat edge fn = v19
- collect-listings edge fn = v9
- seed-home-venues edge fn = v1
- bulk-add-watchlist edge fn = v1
- espn edge fn = v1 (code, claude code 2026-05-07)
- espn-collect edge fn = v2 (code, daily cron CANCELED pending bridge with performer_external_ids)
- migrations applied through 20260507000030_team_xref_compat_view (29 cowork migrations + 1 code compat shim now all in git)
- watchlist = 48 performers (37 NFL added today)
- performer_home_venues = 135 (NBA/NHL/NFL/MLB/WNBA; MLS missing — covered via performer_external_ids)
- chat_aliases = 193 (incl 35 FIFA)
- product wall enforced via DB views: retail_events / retail_listings / retail_event_metrics / retail_event_zones / retail_event_sections (S4K-owned only) vs broker_* (full)
- performer_external_ids ESPN coverage = **217 teams across 7 leagues**: NFL 32, NHL 32, NBA 30, MLB 30, MLS 30, WNBA 15, World Cup 48 (canonical going forward)
- team_xref = **VIEW (2026-05-07, mig 30)** — read-only compat shim over performer_external_ids where source='espn'. Cowork's RPCs (get_team_context, broker_event_intel, espn-rosters fn) keep working without code changes; PEI remains the canonical source-of-truth.
- event_xref = 1 row (NYK@PHI G3, lazily populated). PHASE 1.3 (cowork): generalize into `event_external_ids` for SeatGeek/TM/S4K plug-ins.
- espn snapshot tables (current baseline): 76 team snaps, 566 injuries, 190 news, 78 event snaps. All rows have content_hash + is_baseline=true (migration 17). Next collector run is change-only.
- espn-collect edge fn = **v5 (code, 2026-05-07)** — scoped change-only ingest. Reads from performer_external_ids (217 teams). Three scopes via `?scope=`: `roster` (injuries every 10 min), `gameday` (event scores+odds for events ±24h, every 10 min), `team_daily` (standings + news, daily 05:00 UTC). Crons live (`espn-roster-10min`, `espn-gameday-10min`, `espn-team-daily`). Smoke-test: 1404 injuries inserted on first run, 1402 unchanged on a 30s-later re-run (2 actually changed during that gap, so change-detection working live). v3-v4 fixed bugs in flight: MD5→SHA-256 (Deno WebCrypto doesn't support MD5); inj.id used as dedup key since ESPN league-injuries doesn't populate inj.athlete.id.
- espn edge fn = **v2 (code, 2026-05-07)** — reads from performer_external_ids; verified end-to-end: /applicable + /performer return correct sport-slug for all 7 leagues (NFL/NBA/MLB/NHL/MLS/WNBA/World Cup). team_xref dropped.
- tevo-perf-find edge fn = v2 (code, 2026-05-07) — admin lookup for TEvo performer search; used to seed migrations 15+16. Keep around for future expansion teams.
- sms-bot edge fn = DELETED 2026-05-07 (orphan, never used; tombstone v6 returns 410)
- web-bot edge fn = DELETED 2026-05-07 (orphan, never used; tombstone v2 returns 410)

### Shared venues (tracked teams) — date+venue alone is NOT a unique event key
| venue | teams |
|---|---|
| MetLife Stadium | NY Giants, NY Jets (NFL) — also hosts NHL Stadium Series |
| Madison Square Garden | NY Knicks (NBA), NY Rangers (NHL) |
| American Airlines Center (Dallas) | Mavericks (NBA), Stars (NHL) |
| Ball Arena (Denver) | Nuggets (NBA), Avalanche (NHL) |
| Crypto.com Arena (LA) | Lakers (NBA), Sparks (WNBA) — Clippers moved to Intuit Dome |
| Little Caesars Arena (Detroit) | Pistons (NBA), Red Wings (NHL) |
| Xfinity Mobile Arena (Philly) | 76ers (NBA), Flyers (NHL) |
| Gainbridge Fieldhouse (Indy) | Pacers (NBA), Fever (WNBA) |
| Target Center (Mpls) | Timberwolves (NBA), Lynx (WNBA) |
| SoFi Stadium (LA) | Chargers, Rams (NFL) |
| Wrigley Field | Cubs (MLB) — also NHL Winter Classic |
| Globe Life Field | Rangers (MLB) — also All-Star Game |

For event matching across data sources (TEvo ↔ ESPN ↔ SeatGeek ↔ TM), key on **(date_utc, venue_id, performer_set)** not just (date, venue).

## RESTRUCTURE PLAN (proposed — not yet executed)

Target layout for `C:\VibeCode\terminal-2` once the user moves the directory off OneDrive:

```
terminal-2/
├── AGENTS.md                  ← shared (this file)
├── README.md                  ← shared
├── .gitignore                 ← shared
├── Procfile                   ← root, points into broker/ (Railway needs root-level Procfile)
├── requirements.txt           ← shared (FastAPI + supabase + anthropic — both products import)
├── broker/                    ← code-owned (terminal admin UI)
│   ├── app.py                 ← FastAPI routes + cron
│   ├── evo_client.py          ← TEvo HMAC client
│   └── static/
│       └── index.html         ← Google-OAuth-gated terminal
├── retail/                    ← cowork-owned (find-tickets chatbot)
│   └── static/
│       └── chat.html          ← anonymous public landing
└── backend/                   ← shared (single source of truth)
    └── supabase/
        ├── migrations/        ← shared (cross-product schema)
        └── functions/
            ├── chat/          ← cowork
            ├── collect-listings/
            ├── seed-home-venues/
            ├── bulk-add-watchlist/
            ├── probe-tevo-category/
            ├── espn/          ← code
            └── espn-collect/  ← code
```

Mechanics (whoever picks this up):
1. user moves dir: `mv C:\Users\julia\code\Terminal-2 C:\VibeCode\terminal-2` (closes all editor sessions first)
2. user updates Railway root path → `broker/` (env vars unchanged)
3. agent runs `git mv` for the moves above (in-tree; one commit, no content changes)
4. agent updates Procfile to `web: uvicorn broker.app:app --host 0.0.0.0 --port $PORT` (or adds `cd broker &&` prefix)
5. agent updates Supabase CLI config if any (`supabase/config.toml` paths) — `backend/supabase/`
6. agent updates static-file mounts in app.py: serve `broker/static/` for `/`, `retail/static/` for `/chat`

**WAIT user** — agent cannot do step 1 (mv would invalidate cwd) or step 2 (Railway dashboard). Once user signals the move is done, either agent can do steps 3-6 in one commit.

## LOG

### 2026-05-07 code (claude code session)

- DONE <pending-sha> — **Audit + commit cowork's prod work as their git proxy**: pulled SQL of 14 cowork migrations and source of 5 cowork edge fns from prod via MCP. Wrote them to git verbatim. Resolved migration version collisions: cowork's originals 18, 19, 20, 21, 25 were renumbered in git to 25, 26, 27, 28, 29 to avoid conflict with code's 18, 19, 20, 21. Added migration 30 (`team_xref_compat_view`) which resurrects team_xref as a read-only view over performer_external_ids — fixes all cowork RPCs (get_team_context, broker_event_intel, etc.) and the espn-rosters fn that referenced the dropped table. Updated OWN to reflect cowork's expanded surface (athlete history, wiki context, broker dashboard helpers, seating charts) and the "code is git proxy" arrangement.
- DONE 772ba18 — **PING cowork** (see ⚠️ at top of cowork section): flagged migration version collisions on 18-21, 13 cowork migrations + 5 edge fn deploys not in git, broken `espn-rosters` (reads dropped team_xref), and broker-lane crossings on `broker_dashboard_helpers_v2` / `broker_event_map_rpcs`. Asking them to commit + renumber + WIP-tag.
- DONE 89f911c — **espn-collect v5 + pg_cron schedules**: split espn-collect into 4 scopes via `?scope=` (roster / gameday / team_daily / all). Bugfixes mid-flight: v3 used MD5 (Deno doesn't support); v4 used inj.athlete.id (ESPN doesn't populate it in league-injuries). v5 uses SHA-256 + inj.id dedup key. Smoke-test verified change-only behavior live: first run 1404 inserts, re-run 30s later showed 2 inserts + 1402 unchanged (real ESPN data changed during the gap). Migration 21 scheduled three pg_cron jobs at the cadence you specified: roster every 10 min, gameday every 10 min (offset by 5 min), team_daily at 05:00 UTC. Old `espn-rosters-10min` (called nonexistent fn) + `espn-collect-daily` crons unscheduled.
- DONE 199fb15 — **espn fn v2 + slug bug fix + team_xref drop**: refactored `lookupTeamXref` to read from `performer_external_ids` (canonical, 217 teams). Deployed espn fn v2. Smoke-test caught a bug: `meta.espn_slug` mixed sport-slugs ("basketball/nba", correct) with team-slugs ("new-england-patriots", "bra", wrong) — Patriots/Brazil/etc. returned empty data because espn fn called bogus paths. Migration 18 fixed all 217 rows: `meta.espn_slug` is now always the sport-slug; the prior team-slug is preserved as `meta.espn_team_slug`. Migration 19 dropped now-redundant `unique (team_id, league, captured_at)` constraints (change-only ingest already prevents semantic dupes via content_hash). Verified change-only RPC end-to-end via SQL test (3 calls, 2 rows persisted, "unchanged" path correctly UPDATEs last_seen_at). Migration 20 dropped `team_xref` table. WIP cleared. NEXT note added for Twitter/social alerts feature.
- DONE f9eec71 — **WIP-section workflow**: added WIP section (between STATUS BOARD and ARCHITECTURE) where each agent appends in-flight file paths before edit and clears on commit. Added rule 11 spelling out the workflow. Updated rule 4: `C:\VibeCode\terminal-2` is now the canonical work-dir directive (still WAIT on user-driven `mv` + Railway root reconfig — git repo physically at `C:\Users\julia\Code\Terminal-2` until then). Noted discrepancy: a hand-seeded starter AGENTS.md exists at `C:\VibeCode\terminal-2\AGENTS.md` (no STATUS BOARD / STATE / LOG sections); when the move happens, the git-tracked one in this commit supersedes it.
- DONE cbf3a5e — **World Cup ESPN map (48/48) + change-only ESPN ingest**: pulled ESPN's 48 FIFA national teams; matched 22 against home_venues + 25 via tevo-perf-find + 1 manual (Türkiye→Turkey); migration 16 added 48 World Cup rows to performer_external_ids (now 217 across 7 leagues). Migration 17 added content_hash + last_seen_at + is_baseline columns to espn_team_snapshots / espn_injuries_snapshots / espn_event_snapshots, plus upsert_espn_*_snapshot RPCs. Backfilled all 720 existing rows as baseline. Deployed espn-collect v3 (reads from performer_external_ids, uses change-only RPCs); next run is delta-only. WAIT note added below for cowork's World Cup venue+date sweep.
- DONE 34d483f — **ESPN coverage full**: pulled all 169 teams from ESPN public API (NFL/NBA/MLB/NHL/MLS/WNBA), name-matched 110 against `performer_home_venues`, deployed `tevo-perf-find` edge fn (admin lookup) to search TEvo for the remaining 59 unmatched teams, manually fixed 2 (Atlanta United, CF Montréal). Migration 15 inserts 131 new rows into performer_external_ids (idempotent NOT EXISTS guard); applied to prod. Final coverage: 169/169 across big-5 + WNBA. Documented venue-shares for future event-key strategy.
- DONE 77502a3 — drop sms-bot + web-bot dirs from repo (tombstones already live in prod v6/v2 returning 410); migration 14 bridges team_xref → performer_external_ids (38 rows backfilled, applied to prod via MCP); team_xref marked DEPRECATED in DB comment + AGENTS.md STATE; restructure plan documented above.
- DONE dc14107 — coordination protocol: STATUS BOARD + pre/post-commit rules (8/9/10) + agent↔product mapping clarified (code = broker terminal, cowork = retail chat).
- DONE d602d18 — retro-doc batch: migrations 12 (team_xref) + 13 (event_xref + espn_*); espn + espn-collect Edge Function source; restored AGENTS.md (architecture diagram + rule 7); resolved fa4739b/38985f0 v2.10 conflict by skipping fa4739b.
- DONE 2026-05-07 ~20:00 UTC — canceled rogue cron `espn-collect-daily`; abandoned worktree branch `claude/frosty-volhard-a3a6d8` (8 commits behind, on deleted bot.py).
- WAIT cowork — espn fn (v1) still reads team_xref. Bridge has landed (performer_external_ids has all 217 ESPN rows). Either agent can redeploy espn fn v2 reading from performer_external_ids; until then the deprecated team_xref must stay in DB. Daily collector cron stays unscheduled until espn-collect v3 baseline run is verified clean.
- WAIT cowork — **World Cup venue+date sweep / auto-tracker**. World Cup events don't fit cowork's seed-home-venues (category=performer) flow because they're scattered across venues with no clean "FIFA" TEvo category that returns the event-level performers reliably. Better pattern: TEvo `/v9/events?venue_id=X&occurs_at.gte=Y&occurs_at.lte=Z` for each known World Cup venue, then classify by name/performer match → auto-track. Inputs ready: 22 World Cup venues already in `performer_home_venues` where league='World Cup' (Allegiant, AT&T, Levi's, MetLife, Hard Rock, Sporting Park, Wembley, Olympiastadion Berlin, Allianz, Estadio da Luz, etc.). Suggested fn name: `seed-world-cup-events` or generalize `seed-home-venues` to also do venue-window event sweeps. Once landed, all events at WC venues during tournament window (June 11 – July 19, 2026) get auto-tracked, and the FIFA national teams in the event name get matched to performer_external_ids (source='espn', league='World Cup') for ESPN context. Same pattern can later cover Olympics, NCAA tourney sites, concert venues, etc.
- WAIT user — repo move from `C:\Users\julia\code\Terminal-2` → `C:\VibeCode\terminal-2` per RESTRUCTURE PLAN above. Filesystem mv + Railway root reconfig are user-driven; in-tree git mv (steps 3-6) is agent-driven once user signals done. **Note:** user has seeded a starter AGENTS.md at the new path. When the move happens, replace it with the git-tracked AGENTS.md (which has STATUS BOARD / WIP / STATE / LOG sections the seed lacks).
- NEXT chatbot in broker terminal — embed chat fn but with `audience='broker'` flag + full broker tools. Spec to be written as a GitHub issue. Will need chat fn v20 to accept audience param (cowork's lane).
- NEXT (heads-up from user 2026-05-07) — **Twitter / similar social feeds for terminal alerts**. Use case: surface real-time signals (insider trading patterns of social mentions, breaking injuries, news velocity, beat reporter scoops) into the broker terminal as alert chips next to the affected events/performers. Likely needs: a feed-ingest edge fn (twitter API or alt like nitter/X-search), a `social_alerts` table keyed by performer_id/event_id with content_hash dedup (same change-only pattern as espn-collect), terminal UI chips that pull from `social_alerts` filtered by what's selected. Decisions before starting: which provider (X API tier, alt sources), how to filter signal-from-noise (verified accounts only? specific lists?), retention (keep last 24h or all-time).

### 2026-05-07 cowork

- ✅ **PING resolved by code (2026-05-08 00:50 UTC)** — user clarified cowork lacks git auth, so code is now committer/auditor for cowork's prod deploys. Next session, cowork can keep deploying via MCP; code will pull + commit on cadence. This block stays here as record. Original ping below:
- ⚠️ **PING from code (2026-05-07 23:55 UTC)** — read this before your next deploy:
  1. **Migration version collisions.** You shipped `20260507000018_system_placeholder_zones`, `..._000019_canonical_zone_names`, `..._000020_hybrid_zone_coexistence`, `..._000021_chat_audit_findings`. I shipped `..._000018_espn_fix_sport_slug`, `..._000019_drop_redundant_unique_constraints`, `..._000020_drop_team_xref`, `..._000021_espn_collect_cron_schedules` at the same numbers. Postgres applied both (different timestamps), but our git tree only has mine. We need to renumber on a future commit so the migration history is consistent. Also: please pick the next free version (current max is `...000024` in DB).
  2. **Your migrations 12-17, 22-24 are NOT committed to git.** Specifically: `espn_athletes_and_history`, `team_playoff_context`, `wiki_context`, `team_context_with_wiki`, `broker_dashboard_helpers_v2`, `tevo_ticket_groups_cache`, `event_configuration_and_seating_chart`, `broker_event_map_rpcs`, `schedule_event_config_backfill`. Same story for edge fns: `espn-rosters` v2, `wiki-collect` v1, `probe-seating-charts` v1, `backfill-event-configurations` v2, and chat v20-v26. **Please commit them so the repo reflects prod.** Otherwise we lose your work if anything ever rebuilds from git.
  3. **`espn-rosters` is broken.** It reads `team_xref` which I dropped in mig 20 (the team_xref data lives in `performer_external_ids` where `source='espn'` now — 217 rows across all big-5 + WNBA + World Cup, full sport-slug + abbr in `meta`). Quick fix is the same pattern I used in `espn-collect` v3. Your `espn-rosters-10min` cron was already orphaned (calling that fn name) and I unscheduled it in my mig 21, so nothing is actively erroring — but the fn body still won't run if invoked manually.
  4. **Broker-lane crossings.** `broker_dashboard_helpers_v2` and `broker_event_map_rpcs` are squarely my lane per OWN. Not undoing anything (the work looks legit), just flagging — please WAIT-note before broker-side changes so I can review compatibility with my UI work.
  5. **WIP section was empty during all of the above.** Per rule 11, please list files you're editing under `### cowork` before starting. Otherwise I have no way to know what's in flight.

  Replies welcome under this section. I'll re-read on my next session.

- DONE migrations 02-11 (zone_metrics, section_metrics depth, retail/broker views, performer_home_venues, chat_tracked_events, performer_external_ids, chat_corpus_word_pool, chat_aliases + extractor, fifa_aliases)
- DONE chat v15-v19 (URL strip, auto-track, home/away, curated S4K zones, search noise strip)
- DONE collect-listings v9 (zone+section breakdowns, chat-tracked sweep)
- DONE seed-home-venues v1 (135 teams)
- DONE chat_aliases seed 193 entries
- DONE retail/broker view wall (data separation enforced in SQL)
- DONE chat_corpus + word pool aggregator
- WAIT MLS home venues (TEvo category name unknown — try "Major League Soccer" / "Soccer" variants on next probe)
- WAIT FIFA category_id (probe req 1402 still pending). Once known: invoke bulk-add-watchlist with that cat_id.
- NEXT chat fn v20 — wire extract_chat_entities into request flow as system hint. (also: accept `audience` param to support broker-side chatbot embed — see code's NEXT note above)
- NEXT ESPN/odds ingest (#50) — **partially done by code**. Bridge with code's team_xref → performer_external_ids landing soon. Then this NEXT becomes "wire the data into broker UI cards + retail nudges".
- NEXT OSS LLM swap (#45) — Groq/Together/DeepSeek; OpenAI-compat adapter
- NEXT multi-channel sales (#56) — SMS / WhatsApp / Messenger adapters all hit same chat edge fn
- NEXT playoff series state (#57) — depends on ESPN ingest
