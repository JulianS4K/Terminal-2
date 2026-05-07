# AGENTS.md

both agents read first. both agents append on action. keep cave-man.

## STATUS BOARD (live, read first, update on every state change)

| agent  | status | started_at (UTC)    | working on                                   | branch | safe to interrupt? |
|--------|--------|---------------------|----------------------------------------------|--------|--------------------|
| code   | IDLE   | —                   | —                                            | —      | yes                |
| cowork | IDLE   | —                   | —                                            | —      | yes                |

**Read this table before starting any work.** If the other agent is DOING and your planned work overlaps theirs (same files, related schema), wait or coordinate via a WAIT note in the LOG. If the other agent is IDLE you're clear to start — flip your row to DOING with a timestamp before your first commit.

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

- **code** (broker / terminal) = app.py · evo_client.py · static/index.html · requirements.txt · Procfile · ESPN ingest (espn / espn-collect edge fns + team_xref / event_xref / espn_*) until the bridge into performer_external_ids lands
- **cowork** (retail / chat) = supabase/migrations/ · supabase/functions/chat/ · supabase/functions/collect-listings/ · supabase/functions/seed-home-venues/ · supabase/functions/bulk-add-watchlist/ · supabase/functions/probe-tevo-category/ · static/chat.html · docs/ · SESSION_*.md
- **shared** (ask before edit, leave WAIT note) = AGENTS.md (this file) · README.md · .gitignore · supabase/migrations/ for cross-product schema changes

both agents are free to call any edge fn or read any view. only writes to source files in the other agent's OWN list need a WAIT note first.

## RULES

1. `git pull --rebase origin main` before push. always.
2. no edit other agent's owned path without leaving WAIT note in LOG first.
3. `.claude/` gitignored. never commit worktrees.
4. work in `C:\Users\julia\code\Terminal-2`. never OneDrive. **(planned move to `C:\VibeCode\terminal-2` — see WAIT in LOG)**
5. append to LOG below at end of every session. newest entry on top.
6. tag tasks: DOING / DONE / WAIT / NEXT / BLOCKED.
7. broker product = full data. retail product = S4K-owned only. never cross.
8. **before commit:** flip your STATUS BOARD row to DOING with `started_at` timestamp + brief working-on. if you're going to touch the other agent's owned path or shared SQL, also leave a WAIT note in LOG (top of LOG, your section).
9. **after commit/push:** flip your STATUS BOARD row back to IDLE with `started_at` cleared, AND append a LOG entry under today's date with: `DONE <SHA> <subject>` (newest first within the day). if your work spans multiple commits in one session, one LOG entry covering all of them is fine — list each SHA.
10. if the other agent is DOING and you need to start: read their STATUS BOARD row's `working on`. if your planned work overlaps (same file, related table), don't start — leave a `WAIT for code/cowork to finish <topic>` note in the LOG and pick something else.

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
- migrations applied through 20260507000014_espn_bridge_to_performer_external_ids
- watchlist = 48 performers (37 NFL added today)
- performer_home_venues = 135 (NBA/NHL/NFL/MLB/WNBA; MLS missing)
- chat_aliases = 193 (incl 35 FIFA)
- product wall enforced via DB views: retail_events / retail_listings / retail_event_metrics / retail_event_zones / retail_event_sections (S4K-owned only) vs broker_* (full)
- performer_external_ids = 38 ESPN rows (backfilled from team_xref on 2026-05-07; canonical going forward)
- team_xref = 38 rows — DEPRECATED. read performer_external_ids where source='espn' instead. drop after espn fn switches reads.
- event_xref = 1 row (NYK@PHI G3, lazily populated)
- espn snapshot tables (last collector run): 38 team snaps, 283 injuries, 190 news, 0 event snaps
- sms-bot edge fn = DELETED 2026-05-07 (orphan, never used; tombstone v6 returns 410)
- web-bot edge fn = DELETED 2026-05-07 (orphan, never used; tombstone v2 returns 410)

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

- DONE <pending-sha> — drop sms-bot + web-bot dirs from repo (tombstones already live in prod v6/v2 returning 410); migration 14 bridges team_xref → performer_external_ids (38 rows backfilled, applied to prod via MCP); team_xref marked DEPRECATED in DB comment + AGENTS.md STATE; restructure plan documented above.
- DONE dc14107 — coordination protocol: STATUS BOARD + pre/post-commit rules (8/9/10) + agent↔product mapping clarified (code = broker terminal, cowork = retail chat).
- DONE d602d18 — retro-doc batch: migrations 12 (team_xref) + 13 (event_xref + espn_*); espn + espn-collect Edge Function source; restored AGENTS.md (architecture diagram + rule 7); resolved fa4739b/38985f0 v2.10 conflict by skipping fa4739b.
- DONE 2026-05-07 ~20:00 UTC — canceled rogue cron `espn-collect-daily`; abandoned worktree branch `claude/frosty-volhard-a3a6d8` (8 commits behind, on deleted bot.py).
- WAIT cowork — espn fn (v1) still reads team_xref. Bridge has landed (performer_external_ids has all 38 ESPN rows). Either agent can redeploy espn fn v2 reading from performer_external_ids; until then the deprecated team_xref must stay in DB. Daily collector cron stays unscheduled until cadence confirmed.
- WAIT user — repo move from `C:\Users\julia\code\Terminal-2` → `C:\VibeCode\terminal-2` per RESTRUCTURE PLAN above. Filesystem mv + Railway root reconfig are user-driven; in-tree git mv (steps 3-6) is agent-driven once user signals done.
- NEXT chatbot in broker terminal — embed chat fn but with `audience='broker'` flag + full broker tools. Spec to be written as a GitHub issue. Will need chat fn v20 to accept audience param (cowork's lane).

### 2026-05-07 cowork

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
