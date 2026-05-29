# 3-Agent Sync Audit — 2026-05-08

**Trigger**: User instructed "run an audit on all code, note this is where all 3 agents sync. look for other chats agents may have created due to instruction lacking and see what they have."

**Performed by**: code (auditor role).

The role split (code / copilot / claude design) was formalized in commit `2324f39` only ~1 hour ago. Before that, copilot was working as `cowork` with the same proxy-commit arrangement, but the chat protocol was looser. This audit looks at what slipped through.

---

## Headline findings

1. **6 copilot migrations applied to prod that were not in git.** Now captured.
2. **1 copilot edge function (`tevo-fallback-search`) deployed to prod with no source in git.** Now captured.
3. **Strategic context I had no awareness of: a planned migration from TEvo to SeatGeek API.** Two long planning docs sitting in `docs/seatgeek/` (1,400 lines combined) that have been driving copilot's data-model decisions while I was building deeper into TEvo. Flagging now.
4. **One stray file** at the repo root (`/index.ts`, looks like an old `collect` edge fn) — orphaned, not urgent.
5. **No claude-design artifacts found yet** (agent only formalized 1 hour ago; expected).

Drift count is low considering the volume of copilot work — but the fact that I didn't know SeatGeek migration was in the project plan is a non-trivial gap in my situational awareness as auditor.

---

## A · Migrations missing from git, now captured

All 6 were applied to prod via copilot's direct Supabase MCP access. Source pulled from `supabase_migrations.schema_migrations.statements` and committed verbatim into `supabase/migrations/`.

| applied (UTC)        | name                                                       | what it does | git file (newly created) |
|---|---|---|---|
| 2026-05-08 02:39 | `20260508019000_s4k_popularity_boost_and_athlete_aliases` | Adds `s4k_popularity_boost` column to `performer_metadata` (10 for big-5 venue performers, sums with TEvo popularity for ranking). Expands `chat_aliases` CHECK to allow `'athlete'` kind. Bridges 857 ESPN athletes → TEvo `performer_id` via `team_xref` view, both full-name and last-name aliases (with surname collision filter). Updates `get_chat_suggestion_chips` to use combined boost. | `supabase/migrations/20260508019000_s4k_popularity_boost_and_athlete_aliases.sql` |
| 2026-05-08 02:55 | `20260508020000_manual_search_rpcs_for_frontend` | Adds `search_performers_typeahead`, `search_performers_for_chat`, `search_events_by_date` RPCs for the chatbot's manual express-lane dropdown ("Performer:" + "Date:" row below chat). Note: superseded later same day by `20260508021000_s4k_inventory_only_filters` which added `sellable_events_count`. | `supabase/migrations/20260508020000_manual_search_rpcs_for_frontend.sql` |
| 2026-05-08 17:05 | `20260508022000_expand_user_zone_token_to_curated` | `#106 fix`. New `expand_user_zone_token_to_zones(performer_id, venue_id, user_token)` RPC: when user says generic "lowers" / "100 level", returns array of curated zone names that match (e.g. Knicks @ MSG: "lowers" → `['100 Corner','100 End','100 Garbage','Risers 6-8','Risers 9+']`). Falls back to canonical system zone if no curated. | `supabase/migrations/20260508022000_expand_user_zone_token_to_curated.sql` |
| 2026-05-08 17:15 | `20260508023000_leads_and_rest_wrappers` | **Major addition.** New `leads` table for "reserve via rep" submissions — HARD RESTRICT no auto-purchase. Plus 6 public REST wrappers for the retail web flow: `get_event_zones_public`, `get_event_listings_public`, `get_events_by_performer_public`, `get_events_by_venue_public`, `get_performer_landing_public`, `submit_lead_public`. RLS policies set: anon can INSERT into leads, authenticated can SELECT, service_role full access. **This is a new product surface — retail website beyond the chatbot.** | `supabase/migrations/20260508023000_leads_and_rest_wrappers.sql` |
| 2026-05-08 17:16 | `20260508023500_fix_get_event_zones_public_numeric_cast` | Numeric-cast fix on the zones-public RPC return columns. | `supabase/migrations/20260508023500_fix_get_event_zones_public_numeric_cast.sql` |
| 2026-05-08 17:17 | `20260508023700_simplify_submit_lead_drop_bot_messages_mirror` | Drops the bot_messages mirror in `submit_lead_public` — leads has its own table, no need to pollute. (bot_messages.direction CHECK only allows 'in'/'out' anyway, the mirror would have failed.) | `supabase/migrations/20260508023700_simplify_submit_lead_drop_bot_messages_mirror.sql` |

**Total**: 6 SQL files, ~750 lines of schema landing in git that was previously prod-only.

---

## B · Edge function missing from git, now captured

| function | version | created | notes |
|---|---|---|---|
| `tevo-fallback-search` | v1 | 2026-05-08 | When local S4K-filtered search returns 0 results, hits TEvo's broader marketplace as a fallback so chat doesn't lose customer interest. 5 modes: `suggestions`, `events_by_q`, `events_by_performer`, `events_by_venue`, `events_near`. Source pulled from prod, written to `supabase/functions/tevo-fallback-search/index.ts`. **`verify_jwt: true`** — different from collect-listings/espn-collect pattern, so any cron driving this would need an Authorization header. No cron exists for it currently. |

---

## C · Strategic context I missed: SeatGeek migration

`docs/seatgeek/` contains two long planning docs that were never surfaced through AGENTS.md or LOG before today:

| file | size | content |
|---|---|---|
| `kanban-tasks.md` | 819 lines | EPIC-level kanban backlog for migrating from TEvo to SeatGeek. P0 items include "Audit current `/events` usage (10K cap going live Jan 2026)", "Decide bulk vs delta vs hybrid strategy", "Implement bulk download client". |
| `migration-guide.md` | 581 lines | Reference for both SeatGeek APIs: Platform v2 (public catalog) and Ticket Export v1 (Primary client inventory + transfers). Architecture diagram, breaking changes, known gaps. |

**Immediate impact on my audit duties:**

- My broker-side ranking work (movers, league grids, owned-share badges, the metric workbench) has all been built on TEvo data shapes. If we migrate to SeatGeek, every `event_metrics` row we produce now is on a deprecated source.
- The recent leads + REST wrappers (mig 20260508023000) might be designed with SeatGeek data shapes already in mind. I haven't checked yet.
- The trial countdown (8 days / $4.58) on Railway is a separate timer from this — but if SeatGeek migration is on the roadmap, the priorities shift away from "ship more TEvo features" and toward "audit our TEvo dependence + plan the cutover."

**Action**: I'll add a `STRATEGIC` block to AGENTS.md so this isn't lost again.

---

## D · Stray + orphaned files

| path | what | action |
|---|---|---|
| `/index.ts` (repo root, 12,850 bytes) | Old `evo collector` edge function source. Predates AGENTS.md. Belongs in `supabase/functions/collect/index.ts` or similar. | **Skipped this audit** — not urgent. Logged here for cleanup later. |
| `SESSION_2026-05-07.md` (repo root) | Cowork's session notes from when this all kicked off. Useful historical context, leave in place. | No action needed. |

---

## E · Edge functions deployed but with stale or missing git source

I checked all 22 deployed functions. Most that copilot owns are at v1 and we have local source from earlier audit-and-commit passes. One thing worth flagging:

- `crawl-venues-and-performers` v2 — git has v2 captured from earlier session, looks aligned.
- `tevo-fallback-search` v1 — **was missing from git, now captured (this audit).**
- `collect/index.ts` — there's a stray `/index.ts` at repo root that LOOKS like the source for this fn. Should be moved into `supabase/functions/collect/`. **Skipped this audit** — function deployment is fine, just file organization is off.

No deployed function has a SHA mismatch with git source (within human inspection of file size + first-line comments).

---

## F · No claude-design artifacts yet

Expected — that role only formalized at `2324f39` ~1h ago. Going forward:
- Watch for new `static/*.html` files the agent might add.
- Watch for `static/css/` or `static/js/` subdirectories if design extracts assets.
- Check `INSTRUCTIONS_FOR_CLAUDE_DESIGN.md` is being followed (especially: don't write backend, leave NEXT notes instead).

---

## What I'm shipping in this commit

1. **6 missing migration files** captured into `supabase/migrations/`.
2. **`tevo-fallback-search/index.ts`** captured into `supabase/functions/`.
3. **This audit doc** (`docs/sync-audit-2026-05-08.md`).
4. **AGENTS.md update**: new STRATEGIC block flagging the SeatGeek migration so it doesn't fall off my radar again.
5. **AGENTS.md STATE update**: current migration count (78 in git after this commit), edge fn versions including tevo-fallback-search.

## What I'm NOT shipping (deliberate skip)

- Move/delete of stray `/index.ts` at repo root — low priority, can be done in cleanup pass later.
- Deploy of any updated function — captures are read-only, none of the prod state changes here.
- Re-run of any cron — none needed, all functions executing.

---

## Lessons / process notes for the 3-agent era

- **Periodic sync audits like this one need to be on a cadence.** Every time copilot or claude design works without code's proxy in the loop (e.g. direct Supabase MCP calls, direct deploys), drift accumulates silently. Suggest weekly minimum, daily during heavy work.
- **AGENTS.md needs a STRATEGIC section.** Things like "we're migrating off TEvo to SeatGeek by Q3" are project-level context every agent should see at the top of the file — not buried in `docs/seatgeek/`.
- **The proxy-commit protocol (RULES #12) only works if copilot/design actually use it.** When they bypass and write directly to prod, code's audit pass is the only catch. Need to make the proxy-commit path frictionless enough that they default to it.
