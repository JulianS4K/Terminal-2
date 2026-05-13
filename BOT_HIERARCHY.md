# BOT_HIERARCHY.md

**Quick-reference chart for who-does-what and who-can-push-where. Updated 2026-05-13.**

If the chart in this doc disagrees with `docs/bot-hierarchy.mermaid` or `DOCUMENTATION_INDEX.md` — this doc wins (DOCUMENTATION_INDEX was last refreshed 2026-05-10 with the old `code/canonical/broadway/storefront` naming and is partially stale; the lane reassignments in `bot_chat` rows 50-58 superseded it).

---

## 1. Hierarchy at a glance

```
                     ┌──────────────────────────────┐
                     │            A1                │  admin
                     │  Audit / Push (Admin)        │  sole prod pusher
                     └──────────────┬───────────────┘
                                    │ delegates security audits to
                                    ▼
                     ┌──────────────────────────────┐
                     │            B1                │  security
                     │  Security Manager            │  prod push only for CRIT patches
                     └──────────────┬───────────────┘
                                    │ oversees data + sales lanes via
                                    ▼
                     ┌──────────────────────────────┐
                     │            C1                │  supervisor
                     │  Canonical (Data + Chat)     │  preview branches only
                     └──┬──────┬──────┬──────┬──────┘
                        │      │      │      │
       ┌────────────────┘      │      │      └─────────────────┐
       ▼                       ▼      ▼                        ▼
  ┌────────┐            ┌─────────┐ ┌─────────┐         ┌────────────┐
  │  D0    │            │   D1    │ │   D2    │         │     D4     │
  │ Term FE│            │ Consumer│ │  Order  │         │ Ticketing  │
  │ (RO    │            │  Retail │ │ Clients │         │ infra      │
  │  ref)  │            │  + Rndr │ │         │         │ UNASSIGNED │
  └────────┘            └─────────┘ └────┬────┘         └────────────┘
                                         │
                                         │ sub
                                         ▼
                                    ┌─────────┐
                                    │   D3    │
                                    │Broadway │
                                    │Scraper  │
                                    └─────────┘
```

All D-tier lanes use `bot_level = data-collection` in `bot_chat`. The hierarchy ranks
the sub-relationships within that level.

---

## 2. Lane roster (current state)

| Lane | Identity / role | Worktree branch | bot_level | Status |
|---|---|---|---|---|
| **A1** | Audit / Push (Admin) | `mystifying-lederberg-ea407b` | `admin` | ACTIVE |
| **B1** | Security Manager | `review-supabase-access-v8Dtl` | `security` | ACTIVE (SECURITY BACKLOG drain) |
| **C1** | Canonical (Data + Chat supervisor) | `audit-datasets-schemas-auoc3` | `supervisor` | ACTIVE (PR #51 phase 13) |
| **D0** | Terminal FE / read-only reference + prediction guide | `audit-datasets-schemas-auoc3` (reassigned) | `data-collection` | ACTIVE |
| **D1** | Consumer Retail (storefront + search + share-links) | `eloquent-chatterjee-aaedf0` | `data-collection` | ACTIVE (PR #54 merged) |
| **D2** | Order Clients (seatdata + evo + sg + tickpick + vivid ORDERS, no listings) | `review-unified-order-suite-FA0qA` | `data-collection` | ACTIVE (PR #56) |
| **D3** | Broadway Scraper (sub of D2) | `broadway-scraper-eChQ6` | `data-collection` | ACTIVE (PR #52) |
| **D4** | Our ticketing infra (AR codes, custom ticketing) | — | — | UNASSIGNED |

---

## 3. Push restrictions matrix

| | Prod DB (Supabase main project) | Prod git (`main` branch) | Render workspace | Edge functions | Vault / secrets |
|---|---|---|---|---|---|
| **A1** | ✅ via MCP | ✅ merge any PR | ✅ (until D1 takes over) | ✅ deploy | ✅ rotate/set |
| **B1** | ✅ **CRIT security only** | ✅ for sec PRs | ❌ | ✅ for sec | ✅ |
| **C1** | ❌ preview only; A1 applies | ❌ A1 merges | ❌ | ❌ A1 deploys | ❌ |
| **D0** | ❌ preview only | ❌ A1 merges | ❌ | ❌ | ❌ |
| **D1** | ❌ preview only | ❌ A1 merges | ✅ **sole owner** | ❌ A1 deploys | ❌ |
| **D2** | ❌ preview only | ❌ A1 merges | ❌ | ❌ | ❌ |
| **D3** | ❌ preview only | ❌ A1 merges | ❌ | ❌ | ❌ |

**Two hard rules surface from this:**
- **Only A1 pushes prod DB and merges to `main`.** B1 is the exception for CRIT security only.
- **Only D1 touches Render.** D0/D2/D3/D4 may NOT push to Render, provision services there, modify env vars, or configure crons in the Render workspace.

---

## 4. Single-writer table ownership (writes)

Single-writer rule: the lane that created a table owns its writes. Others can read or call write-RPCs.

| Lane | Tables they write (illustrative — not exhaustive) |
|---|---|
| **A1** | `event_xref`, `*_xref`, performance crons, audit views, sweep functions (`sweep_old_listings`, `sweep_duplicate_listings`, etc.), `latest_event_metrics` matview, FRED macro tables |
| **B1** | `pg_policies` (via migrations), `secrets`-related, RLS configs |
| **C1** | `events`, `*_canonical`, `*_resolved` sidecars (e.g. `seatgeek_orders_resolved`), `bot_chat`, dashboard matviews, `seatgeek_event_xref` (canonical authority — D2's sidecar is the canonical write path, not parallel writes on `seatgeek_orders.tevo_event_id`) |
| **D0** | (read-only reference) |
| **D1** | `share_links`, storefront `app.py` (no DB tables directly) |
| **D2** | `evo_orders`, `evo_order_items`, `seatgeek_orders` (raw), `tickpick_orders`, `vivid_orders`, `seatdata_sales_snapshots`. **Sidecar pattern**: D2 writes to `*_orders` raw, C1 resolves into `*_resolved` sidecar. D2 will NOT add parallel `tevo_event_id` write paths — sidecar is canonical (2026-05-12 decision). |
| **D3** | `broadway_*` tables |

When in doubt, post a `question` in `bot_chat` and A1 / C1 will adjudicate.

---

## 5. Code-review + push workflow (the fast path)

For any change a lane wants in prod:

1. **Branch** — `claude/<lane>-<purpose>-<id>`, off `main`.
2. **Migration header** (required, one line, see `MIGRATION_CONVENTIONS.md` §3):
   `-- Migration <ts> · level:<X> · lane:<Y> · writes:<...> · reads:<...> · pre:<...>`
3. **PR** — use `.github/PULL_REQUEST_TEMPLATE.md` (declares Level + Lane + Tables + Pre-reqs + Test plan).
4. **Apply to preview branch** via MCP, never to the main project_id.
5. **bot_chat log** — `change_log` event with PR# linked.
6. **Hand to A1 for review + push** — A1 reviews, applies migration to prod via MCP, merges PR, posts close-out `change_log`.

Critical security patches: B1 may apply directly with `event_type='p0_security'` and a post-mortem in the same `bot_chat` row.

---

## 6. SECURITY DEFINER function convention (PR #67/#68 — adopted 2026-05-13)

Every SECURITY DEFINER function ships in **one migration** with three lines together, every time:

```sql
CREATE OR REPLACE FUNCTION public.my_function(...)
RETURNS ... LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$ BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'my_function: caller % not authorized', current_user;
  END IF;
  -- function body
END $$;

REVOKE EXECUTE ON FUNCTION public.my_function(...) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.my_function(...) TO service_role;
```

Belt-and-suspenders: grant gate (primary) + body assertion (defense-in-depth). To be folded into `MIGRATION_CONVENTIONS.md` §6/§12 next pass.

---

## 7. Quick links

- `MIGRATION_CONVENTIONS.md` — the full rules (13 sections, the canonical reference)
- `START_HERE.md` — 2-min bootstrap, hard rules
- `DOCUMENTATION_INDEX.md` — full doc map (note: 2026-05-10 vintage, partial drift on lane names)
- `docs/bot-hierarchy.mermaid` — visual diagram (refreshed 2026-05-13)
- `bot_chat` rows 50-58 — lane-assignment broadcasts that established this hierarchy
- `bot_chat` row 57 — INFRA OWNERSHIP RULE (D1 Render-exclusive)
- `bot_chat` row 64 — sidecar-canonical decision (D2 will not add parallel writes)

Owner: A1. Update when a lane assignment changes or a new bot is rostered.
