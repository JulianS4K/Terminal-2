# Project Kanban — 2026-05-14 snapshot

End-of-day handoff board. Synthesizes today's wins, what's blocking on operator, and what's queued for the next session. Keep this terse — each card is `<one line>: <one line>`.

---

## ✅ DONE today

### Data ingestion
- **Vivid orders pull live** — `vivid_orders_queue/process` + cron jobid 130/131 (T2 :16,:46 / :26,:56) — 821 rows backfilled ($208,937 gross, 2,265 tix)
- **TickPick orders pull live** — Apps Script → Supabase RPC (`tickpick_orders_ingest_from_apps_script`) — 909 rows landed ($284,975 gross)
- **ESPN crons restored** — jobid 128 + 129 recreated after 2026-05-09 silent drop; backfilled 30 event_snaps + 126 injuries
- **Cron hierarchy applied** — 5 tiers (T0–T4), 74 active jobs, peak concurrent ≤20, 12+ worker slots reserved for B2-B4

### Cross-source mapping
- **3 NOT VALID FKs declared** — `vivid_orders` / `tickpick_orders` / `seatgeek_orders` `.tevo_event_id → events(id)`
- **TickPick coord+datetime matcher v1** — 176 / 909 (19.4%) at conf 0.95; FK constraint VALIDATEd
- **Column comments documenting internal-only IDs** — all 4 order tables, plus `evo_orders.evo_order_id`

### Security / hygiene
- **Advisor lints 486 → 0 ERROR** — PR #94 (139 SECDEF views), PR #95 (215 fn search_path), PR #96 (3 asset SECDEFs), PR #97 (121 RLS deny-all), plus today's regression fixes for 7 phase-15b views + 3 pgcrypto-using fns + `v_bot_chat_unresolved`
- **RLS deny-all** on 121 tables (PR #97)
- **APPSCRIPT_INGEST_SECRET rotated** after chat exposure incident
- **Release health-check function** live: `public.release_health_check()` — <1s smoke harness for regression detection

### Coordination
- **bot_chat** rows 119, 120, 121 (audit summary, credential rotation, matcher v1) — A1 lane
- **10 stale bot_chat items resolved** today (rows 25, 33, 62, 94, 102, 105, 108, 109, 112, 116)
- **PR #101 consolidating** all admin work (8 commits / 11 migrations); CI green, MERGEABLE

---

## 🟡 IN FLIGHT (operator action)

| # | Owner | Item | Blocker |
|---|---|---|---|
| K1 | Operator | **Merge PR #101** | one-click; CI green |
| K2 | Operator | **Install `installSupabaseSyncTrigger()`** in Apps Script | enables 30-min TickPick auto-sync |
| K3 | Operator | **TEVO vault cleanup** — pick whether `TEVO_API_SECRET` is stale or canonical (vs `TEVO_SECRET` which 6 fns currently use, has stray `<` prefix) | bot_chat #119 has options |
| K4 | Operator | **Row 65 advisor decision** — keep paused or delete `master-cascade-2min` (#38, 15.5% DB time) + `zone-backfill-isolated-10min` (#98, 14.3%) | still paused since 2026-05-13 |
| K5 | Operator (optional) | **Rotate legacy anon JWT** — public-by-design but was pasted in chat | heavier; affects all clients using it |

---

## 📥 NEXT SESSION queue (A1 picks up)

### High-value, low-risk
| # | Item | Why now |
|---|---|---|
| N1 | **Periodic re-run of TickPick coord matcher** | 552 orders sit at "venue mapped, no event in ±4h"; auto-recover as TEvo pull extends. Just re-apply migration 20260515160000 (idempotent — skips already-matched rows). |
| N2 | **Feed 174 unknown TickPick venues into `venue_geocode_queue`** | Pull `raw->'venue'->>'name' + city + state` for unmatched orders; geocode jobs 46/47 will resolve them |
| N3 | **VALIDATE the remaining 55 NOT VALID FKs** | Off-hours batch; <30s total per audit doc estimate |
| N4 | **Re-resolve old bot_chat items 65/68/71/76/87/95/96/97** (other-lane) | Most are months old; check current state, mark resolved if work landed |

### Medium-value, scoped
| # | Item | Scope |
|---|---|---|
| N5 | **Vivid → TEvo matcher** | Free-text venue only; needs geocode-haversine cascade. Per `plan zany-skipping-fox.md` Future Work. |
| N6 | **SG seller_listings → TEvo matcher** | Already have `sg_events_canonical.tevo_event_id` populated for some events; bridge to seller_listings |
| N7 | **`events.occurs_at_local` TEXT → timestamptz** | 32 dependent views need staged drop/recreate (deferred per audit-2026-05-14 Section 4 row 112 part 2) |
| N8 | **Polymorphic `order_listing_xref` table** | The full "mapping key" per zany-skipping-fox.md — when operator gives green light |

### Cleanup
| # | Item |
|---|---|
| N9 | `event_match_attempts` prune sweep (29 stale records per audit doc §5.1) |
| N10 | `bot_chat.in_reply_to` covering index |
| N11 | `compute_event_breakdowns` REVOKE EXECUTE from anon/authenticated (54.7% DB time at peak; audit doc §5.5) |
| N12 | VACUUM (ANALYZE) the 4 never-vacuumed big tables |

---

## 🔮 BACKLOG (no commitment)

- **Coord-aware future matcher v2** — generalize TickPick's tier-1 approach to vivid (post-geocode) and SG
- **Auto-retry sweep cron** — daily T3 job that re-runs `match_order_to_listing` on unmatched orders within 30d of `ordered_at`
- **`v_order_match_coverage` view** — per-source dashboard of tier distribution + unmatched-reason histogram
- **Operator-curated section-name alias seeds** — top-30 venues by ticket volume; otherwise pure organic bootstrap from Tier-1 successes
- **Auto-flagging for bot_chat aging** — daily report of items unresolved >7 days
- **Cross-source order-tracking dashboard for D2** — fed by `unified_orders` + the polymorphic xref

---

## 🎯 Streamlining commitments (see `docs/release-discipline.md`)

Two automatic guards introduced today to prevent the regression patterns we saw:

1. **`release_health_check()` SQL fn** — call BEFORE + AFTER every migration; diff for regression signals. <1s. Catches: cron failures, silent crons, pgcrypto search_path discipline, SECDEF view discipline, FK validity drift, data staleness, queue backlog.
2. **`migration_drift_check()` SQL fn** — surfaces applied-migration set; CI workflow joins against on-disk `supabase/migrations/*.sql` to detect codification drift.

Recommended cadence:
- After every `apply_migration` MCP call → run `release_health_check()` snapshot
- Once a day → `migration_drift_check()` in CI (workflow TBD)
- Once a week → review `bot_chat` items unresolved >7 days
