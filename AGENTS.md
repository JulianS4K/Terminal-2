# AGENTS.md

both agents read first. both agents append on action. keep cave-man.

## OWN

- **cowork** = supabase/migrations/ supabase/functions/ docs/ AGENTS.md SESSION_*.md
- **code** = app.py bot.py evo_client.py static/ requirements.txt Procfile
- **shared** (ask before edit) = README.md .gitignore

## RULES

1. `git pull --rebase origin main` before push. always.
2. no edit other agent's path without leaving WAIT note here first.
3. .claude/ gitignored. never commit worktrees.
4. work in C:\Users\julia\code\Terminal-2. never OneDrive.
5. append to LOG below at end of every session. newest entry on top.
6. tag tasks: DOING / DONE / WAIT / NEXT / BLOCKED.

## STATE (truth, not history)

- Live URL terminal = railway https://terminal-2-production.up.railway.app
- Live URL retail chat = same domain /chat
- Supabase project = hzrizjeaxlqcxfrtczpq (Terminal .5)
- chat edge fn = v19
- collect-listings edge fn = v9
- seed-home-venues edge fn = v1
- bulk-add-watchlist edge fn = v1
- migrations applied through 20260507000011_fifa_aliases
- watchlist = 48 performers (37 NFL added today)
- performer_home_venues = 135 (NBA/NHL/NFL/MLB/WNBA; MLS missing)
- chat_aliases = 193 (incl 35 FIFA)

## LOG

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
- NEXT chat fn v20 — wire extract_chat_entities into request flow as system hint
- NEXT ESPN/odds ingest (#50) — broker-only data; populate performer_external_ids first
- NEXT OSS LLM swap (#45) — Groq/Together/DeepSeek; OpenAI-compat adapter
- NEXT multi-channel sales (#56) — SMS / WhatsApp / Messenger adapters
- NEXT playoff series state (#57) — depends on ESPN ingest

### 2026-05-XX code

(claude code: append here on next session)
