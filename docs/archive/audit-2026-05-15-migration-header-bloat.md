# Migration Header Bloat — 2026-05-15 Audit

Author: C1. Charter: bot_chat 139 first deliverable. Calibration case study for [docs/token-discipline-rules.md](docs/token-discipline-rules.md).

## Findings

| Migration | Header lines | Verdict | Reduction |
|---|---|---|---|
| `20260515310000_get_broker_event_page_rpc.sql` | **45** | over budget by 30 | propose 10 lines (−78%) |
| `20260515320000_d0_read_access_grants.sql` | **72** | over budget by 57 | propose 12 lines (−83%) |
| `20260515330000_health_check_pg_net_errors.sql` | **7** | compliant — **model example** | — |

Total trim: 105 → 29 header lines (76% reduction) across the 3.

## 310000 — proposed trim

```sql
-- Migration 20260515310000 · admin · Audit/Push · writes:get_broker_event_page() · pre:20260515300000
-- D0 Event Detail Page MVP: single RPC flattening 5 broker/event/{id}/* endpoints into one JSONB
-- (overview, chart_data, zones, orders, cadences).
--
-- AUTH GATE: auth.jwt()->>'email' LIKE '%@s4kent.com' (mirrors app.py require_auth).
-- SECURITY DEFINER — anon role on static CDN; email gate inside body; search_path per §6 SECDEF.
--
-- COMPOSES: get_broker_event_detail, get_event_zones_rollup, derive_event_lifecycle.
-- Design rationale + deferred-for-v2 list + app.py line refs → PR #115 description.
```

Cut: D0 Path C history (5 lines), 5-endpoint mapping table (6 lines, redundant — names are in COMPOSES), DESIGN NOTE on Python post-processing (6 lines → PR description), DEFERRED-for-v2 list (5 lines → PR description), See-app.py-lines references (4 lines → PR description).

Keep: top matter, AUTH gate, SECDEF justification, COMPOSES list, search_path note.

## 320000 — proposed trim

```sql
-- Migration 20260515320000 · admin · Audit/Push · writes:RLS+GRANT on 10 D0 read tables · pre:20260515310000
-- D0 SQL read access for visualization. Tier-1 (RLS-gated PostgREST direct reads). Tier-2/3 deferred.
--
-- AUTH GATE: auth.jwt()->>'email' LIKE '%@s4kent.com'. service_role bypasses RLS (no backend impact).
--
-- TIER-1 WHITELIST (low-cardinality reference + observability):
--   events, event_xref, sg_events_canonical, aq_event_map, aq_venue_map, aq_performer_map,
--   performer_metadata, venue_assets, cron_policy, cron_gate_decisions.
--
-- NOT in whitelist: order tables (PII), heavy snapshot/metrics tables, bot_chat, system schemas.
-- Post-apply verification SQL → PR #115 description.
```

Cut: ARCHITECTURE explanation (Tier-1/2/3 description: 7 lines → PR description), D0 frontend flow detail (5 lines), EXPLICITLY NOT IN WHITELIST item-by-item list (16 lines → one-line category summary), POST-APPLY VERIFICATION SQL block (20 lines of comments containing a verification query → put the query in a separate audit appendix or PR description, not inside the migration).

Keep: top matter, AUTH gate, service_role note, Tier-1 whitelist (this is structural — the table names ARE the migration's surface).

## 330000 — model

Already 7 lines and compliant. Pattern to emulate: structural intent in 1–2 sentences, threshold value, integration plan, done. Body of the migration is self-documenting from the function name + comment.

## Why these grew

Both 310000 and 320000 carry significant rationale because they encode operator-directive context that wasn't yet captured in a stable doc. The right place for that context is `docs/release-discipline.md` (anti-drift patterns), the PR description (point-in-time decisions), or a `docs/d0-*-decisions.md` (architecture). The migration header is for what the next reader needs to apply or troubleshoot the migration — not the meeting minutes that led to it.

## Disposition

- A1 noted in bot_chat 139 the headers predate the discipline. **Retroactive trim is low priority** — leave 310000 + 320000 as-is. Future migrations follow the rulebook.
- 330000 is the on-ramp example; the rulebook references it.
- C1 daily Step 9 (added to runbook) catches new violations within 24h.

## Self-audit

This doc itself is 60 lines, well under any reasonable doc budget. The rulebook is 65 lines. Both are calibrated to be linkable from migration headers + `bot_chat` posts (the pointer pattern referenced in the rules).
