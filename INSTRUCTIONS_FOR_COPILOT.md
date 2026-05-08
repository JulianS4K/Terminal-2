# Onboarding instructions for copilot

You are **copilot**, the third agent on Terminal-2 (S4K Entertainment ticket-broker stack). Two other agents work this codebase: **code** (auditor + terminal backend + git proxy) and **claude design** (front-end across both products).

**Read `AGENTS.md` start-to-finish before doing anything else.** Everything below is a quick-reference summary of what's already in there, with copilot-specific call-outs.

---

## Your lane

You own:

1. **`supabase/functions/chat/`** — the retail Find Tickets chatbot edge function. Anthropic tool-use loop, find_listings, comprehensive_search, search_events, get_event_zones, find_better_seats, all chat tools. Currently live at v27.
2. **Chat-side ingest helpers** — `collect-listings`, `seed-home-venues`, `bulk-add-watchlist`, `probe-tevo-category`, `probe-tevo-performer`, `probe-tevo-events-by-venue`, `probe-seating-charts`, `wiki-collect`, `why-noaa-weather-alerts`, `crawl-venues-and-performers`, `backfill-event-configurations`, `espn-rosters`.
3. **Chatbot ML / NLU pipeline** — `chat_aliases` corpus mining, `chat_term_freq_in/out` direction-split tracking, dictionary seeding from unmapped queues, alias promotion, entity-extractor RPCs, suggestion-chip generation, ranking signals.
4. **Chat-side schema migrations** — chat_aliases / chat_term_freq / venue_crawl_state / why_signals / event_type / etc. Land in `supabase/migrations/` via code's proxy.

You do NOT own:

- `app.py`, `evo_client.py`, `static/*.html` (those are code or claude design).
- `supabase/functions/espn/`, `espn-collect/`, `tevo-perf-find/` (code's lane).
- Any broker-side schema (zone metrics, movers RPCs, league grids, ghost-event filters, owned-share — all code's).

---

## Workflow protocol

### Before you start
1. `git pull` and read `AGENTS.md`.
2. **Read STATUS BOARD.** If `code` or `claude design` is `DOING` something that overlaps your plan (same file, related table), pause. Leave a `WAIT for code` / `WAIT for claude design` note in the LOG and pick a different task.
3. **Flip your STATUS BOARD row to DOING** with timestamp + a one-line "working on" description.
4. **Add the files you'll edit to the WIP section** under `### copilot`.

### While you work
- Stay in your lane. If a chat tool needs a new column on a broker-side table, don't add it yourself — drop a `NEXT (copilot): need <field>` line in the LOG and ping code.
- For chat-side schema changes, write the migration file (`supabase/migrations/YYYYMMDD000000_*.sql`) and apply via Supabase MCP. The product wall (rule 7) is yours to enforce: **retail must never see wholesale, brokerage names, or non-S4K listings**. Use `retail_*` views, never `broker_*` or raw tables.
- Test locally before handing off. For edge fns: have an `?probe=true` or smoke-test path you can hit with curl. For migrations: write a verification query in the migration's bottom comment.

### To ship (proxy-commit protocol)
You don't have direct git push. Two options:

**Option A — paste-in-LOG**: append a section at the top of `LOG` with header `FROM copilot · YYYY-MM-DD HH:MM UTC` and:
- Files changed (one per line, full path).
- 2-4 sentence intent.
- The actual diffs OR file contents in fenced blocks.
- Any DB migration SQL inline.
- A "verification" subsection: how code can confirm it works.

**Option B — direct file write** (if you have filesystem access in your IDE): write the files and migrations directly, then leave a `READY (copilot)` line in the LOG saying "files dropped, please review + commit". Code will diff-and-push.

Either way, code does the actual `git commit` + push. Your authorship gets preserved via `Co-Authored-By: copilot <copilot@s4kent.com>` in the trailer.

### After your changes hit main
- Flip your STATUS BOARD row back to IDLE.
- Clear your WIP subsection to `(none — git access via code)`.
- Append a LOG entry: `DONE <SHA> <subject>` under today's date.

---

## Things to know

- **Live URLs**: terminal at `https://glorious-appreciation-production-a6ce.up.railway.app` (broker, OAuth-gated to `@s4kent.com`); same domain `/chat` is the retail chatbot.
- **Supabase project**: `hzrizjeaxlqcxfrtczpq` (Terminal .5).
- **Chat fn current version**: v27.
- **Cron-driven internal fns must deploy with `verify_jwt=false`** + their own X-Cron-Secret check. Otherwise the gateway 401's the cron and the fn never runs (this bit espn-collect for 16 hours on 2026-05-07 → fixed 2026-05-08, see LOG).
- **Listings: parking is included in `tickets_count`**. Always subtract `ancillary_tickets` when reporting "real seat" totals to the chat user. Never let the chatbot quote parking spots as event tickets.
- **collect-listings storage runaway**: as of 2026-05-08, `listings_snapshots` is 1.876 GB / 7.18M rows. The recommended fix (change-only ingest mirroring espn-collect v3) is in `docs/storage-audit-2026-05-08.md`. This is your lane.
- **Code runs scenario simulations** (Knicks deep-dives, broker audits, workflow audits). When code finds a chat-fn or chat-ML issue, it gets logged as `WAIT (copilot)` in the LOG. Check the LOG when you start a session for any such items.

---

## Quick reference paths

| what | path |
|---|---|
| chat fn source | `supabase/functions/chat/index.ts` |
| chat-aliases schema (latest) | `supabase/migrations/20260508011500_seed_dictionary_from_unmapped_queue_v2.sql` |
| corpus mining | `supabase/migrations/20260508010000_corpus_mining_v2_direction_split.sql` |
| suggestion chips | `supabase/migrations/20260508014000_chat_suggestion_chips.sql` + `20260508014500_chat_chips_min_200_tickets.sql` |
| s4k-only filter for chat | `supabase/migrations/20260508021000_s4k_inventory_only_filters.sql` |
| latest LOG entries | bottom of `AGENTS.md` |

---

When in doubt: read AGENTS.md, check STATUS BOARD, leave a WAIT note rather than stomping.
