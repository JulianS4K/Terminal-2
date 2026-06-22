# D4 — The Bridge: Lane Charter & System Architecture

**Status:** ACTIVATING — supersedes the "UNASSIGNED / future · AR codes, custom ticketing" placeholder in `PROJECT_BIBLE.md §2` + `README.md`. (Governance-doc status flips are A1-owned — see §8.)
**Lane:** D4 · `bot_level = data-collection` · reports to C1 (hierarchy), subordinate-coding posture under D0 for any shared frontend surface.
**Author:** D4 · **Date:** 2026-05-20
**Source thesis:** *The Bridge — Strategic Opportunity Report* (Julian, Mar 2026, **Confidential**). Held externally (operator's `Downloads`); **not committed to this repo** — it carries BD/financial detail (prospect lists, projections, partner terms) that does not belong in source control. This charter reproduces only the **technical/product architecture** needed to scope the engineering lane.
**Reconciles with:** `CLAUDE.md` (lockdown invariants), `PROJECT_BIBLE.md §2`, `PROJECT_BIBLE.md §2`, `PROJECT_BIBLE.md`.

> **Placeholder correction:** prior governance docs labeled D4 "AR codes, custom ticketing." "AR" was a garble of the **QR-code check-in** the venue-intake platform provides. This charter is the real scope.

---

## 1. Mission

S4K is a top-tier **secondary** (resale) operator — Top Seller on ~10 retail channels, $20M+/mo — but has **no venue-facing intake layer** connecting that distribution machine to primary (organizer-owned) inventory. **The Bridge** closes that gap: a white-labeled primary-ticketing storefront the venue controls, wired on the back end to S4K's existing distribution rails, so organizer inventory fans out across all retail channels the moment it goes on sale — with the venue keeping pricing control, revenue, and buyer data.

D4 owns the **engineering** of the Bridge: the integration layer that did not previously exist. The off-the-shelf ticketing platform (Hi.Events / pretix) supplies checkout, ticket delivery, QR check-in, and Stripe; **D4 builds the differentiated glue**, not a ticketing platform from scratch.

---

## 2. The product — two prongs + the differentiated build

| Prong | What the venue sees | What it is underneath |
|---|---|---|
| **1 — Venue intake** | A branded primary-ticketing storefront under their own identity; their fans, data, pricing. | A **forked, white-labeled Hi.Events** (or pretix) instance, invisible to buyers. Supplies checkout / delivery / QR check-in / Stripe-direct payouts. |
| **2 — Distribution** | "List once, sell everywhere" — inventory appears across all retail channels simultaneously, non-exclusive, no switching. | The **Bridge integration layer (D4)** pushing normalized inventory into S4K's order/listing clients, which list it on the channels. |

**The differentiated build (the only thing D4 writes from scratch):**
1. **Inventory ingest** — capture on-sale / inventory-change events from the intake platform (webhook + REST reconcile).
2. **Floor-price control** — per-event floor calibration (venue/operator-set in P1); enforce floor on every downstream listing. *D0 pricing-intelligence feed is a later enhancement — D4 is independent from D0 for now.*
3. **Multi-platform push** — translate one normalized inventory record into per-channel listing calls.
4. **Oversell / sync guard** — never let the sum of live secondary listings exceed remaining primary inventory; reconcile on every primary sale and every secondary sale.
5. **Buyer-data capture** — every transaction (any channel) returns name/contact/purchase-history into the venue's fan database.

---

## 3. System architecture

```
                         VENUE (organizer)
                              │  sets inventory + pricing
                              ▼
        ┌───────────────────────────────────────────────┐
        │ PRONG 1 · VENUE INTAKE  (white-label)           │   ← own service / repo (the fork)
        │ Hi.Events | pretix fork                         │
        │ checkout · delivery · QR check-in · Stripe      │
        └───────────────────────┬───────────────────────┘
                                 │ on-sale / inventory-change (webhook + REST reconcile)
                                 ▼
        ┌───────────────────────────────────────────────┐
        │ D4 · BRIDGE INTEGRATION LAYER  (net-new)        │
        │   inventory ingest + normalize                  │
        │   floor-price control  (venue/operator-set · P1) │
        │   multi-platform push      ──► D2 clients        │
        │   oversell / sync guard                         │
        │   buyer-data capture       ──► venue fan DB      │
        └─────────┬───────────────────────────┬──────────┘
                  │                            │
                  ▼                            ▼
   (LATER · deferred) D0             D2 ORDER / LISTING CLIENTS
   D4 independent from D0 for now    evo (TEvo) · seatgeek · tickpick ·
   — P1 floors venue/operator-set    vivid · gotickets · (seatdata) · …
                                            │ list inventory (WRITE — gated, §6.1)
                                                ▼
                                 PRONG 2 · RETAIL CHANNELS (~10)
                                 StubHub · SeatGeek · AXS · Gametime · TEvo ·
                                 Vivid · GoTickets · Ticket Network · TM Resale · TickPick

         D1 STOREFRONT ─────────────────────► PHASE 2: S4K-owned aggregate consumer site
```

---

## 4. What we reuse vs. what D4 builds

| Bridge capability | Where it lives today | Reuse / net-new |
|---|---|---|
| Floor-price intelligence, demand signals, sales/listings history | **D0** SECDEF RPCs + SG/TEvo firehoses | **LATER** — D4 independent from D0 for now; P1 floors are venue/operator-set |
| Distribution rails to retail channels | **D2** order clients (`evo_client.py`, `seatgeek_client.py`, `tickpick_client.py`, `vivid_client.py`, `gotickets_client.py`) | **Reuse the clients; add a WRITE/listing path** (gated — §6.1) |
| Consumer aggregate site (Phase 2) | **D1** storefront (`static/store/*`, `/api/store/*`) | **Reuse / extend** |
| Cross-source event identity (so a Bridge event = a catalog event = SG/TEvo events) | **A1/C1** canonical: `aq_event_map`, `event_xref`, `seatgeek_event_xref`, matchers | **Reuse** |
| Venue intake storefront (checkout / QR / Stripe) | **pretix** (recommended) or Hi.Events fork — see [`d4_intake_platform_eval.md`](archive/d4_intake_platform_eval.md). Existing `hi-events` Render svc is **not** our fork — stand up new. | **Net-new (fork; separate repo)** |
| **Bridge integration layer** (ingest, floor control, push, oversell guard, buyer capture) | — | **Net-new — this is D4's build** |

---

## 5. Phase roadmap → repo deliverables

| Phase | Thesis intent | D4 engineering deliverables |
|---|---|---|
| **P1 — Distributor** (the 4–6 wk build) | Venue lists on their branded page; inventory distributes to all channels; floor controls; buyer capture. First clients onboarded at no fee. | Fork + brand intake platform; `bridge_*` tables + xref into `aq_event_map`; inventory-ingest webhook/edge fn; floor-control service (venue/operator-set in P1; D0 feed deferred); multi-platform push via D2 clients (**needs §6.1 carve-out**); oversell guard; buyer-capture pipeline; post-event distribution report. |
| **P2 — Owned retail** | S4K-owned aggregate consumer site for indie live events; fan database becomes the direct-marketing channel; per-venue branded pages. | Extend **D1** storefront into the aggregate catalog; venue pages; fan-DB-backed marketing surface. Driven by P1 transaction data. |
| **P3 — Financial layer** | Venue payouts + AP via the Global Rewards virtual-card rails (rewards on payout; corporate-card AP). | Payout/AP integration layer. **Out of D4's initial engineering scope** — flagged as a future sub-project; likely its own lane or E-tier adjacency given financial/regulatory profile. |
| **Later — Automatiq** | Broker-automation tier (autopricing / POS / marketplace distribution automation), per operator. | Lands as a **later D1 distribution addition** alongside the storefront. Evaluate over the Bridge rails once P1 distribution is proven. Not P1. |

---

## 6. Governance reconciliation — the hard rules this product crosses

The Bridge is a deliberate departure from the current "read-only everything" lockdown posture. These must be resolved with the operator / A1 / B1 **before** the corresponding code ships.

### 6.1 Upstream WRITE authorization (crosses `CLAUDE.md` lockdown rule #2) — **the blocker**
The entire product depends on **creating listings/inventory on upstream platforms** (SG / TickPick / Vivid / TEvo / GoTickets …). Today **all upstream APIs are read-only**; order/listing POSTs are forbidden without explicit operator authorization. Proposed path, modeled on **D1's Sprint-2 RULE-2 carve-out** (`d1_operating_constraints.md`):
- WRITE capability lives in **sibling modules** (e.g. `*_listing_client.py`), never by loosening the existing read-only guards in D2's clients.
- Per-client `ALLOWED_*_METHODS = frozenset({...})` with the **narrowest** endpoint scope (list create / update / delete only).
- Read-only guard tests (`tests/test_readonly_guards.py`) stay green for the original clients.
- B1 architectural sign-off + **explicit operator authorization per platform** before enabling each one.

*Operator status (2026-05-20): upstream stays **read-only for now**; revisit the carve-out when we decide to proceed.*

### 6.2 Cross-lane invocation of D2's clients
The order clients are **D2's** write surface. D4 must not edit them directly. Pattern (mirrors how D1 *imports + calls* `evo_client.py` read methods): D4 builds an **orchestration layer** that imports the D2-owned listing modules; D2 remains the author/owner of those modules; cross-lane changes go via PR comment / `bot_chat`.

### 6.3 D4 deploy target
Per `PROJECT_BIBLE.md §2`, D4 gets **its own deploy target** when scoped — not D1's storefront service. Candidates: a new Render service (`vibepass-bridge-*`) for the integration layer; the venue-intake fork likely deploys separately (own repo/service). **A1 owns provisioning.** Confirm whether the existing `hi-events` service is the intended fork (§8).

### 6.4 D4 table namespace / single-writer
D4 writes only its own `bridge_*` namespace (single-writer rule, `PROJECT_BIBLE.md §2 §4`). It **reads** D0/A1/C1 tables and **xrefs** into the canonical key (`aq_event_map`) rather than forking identity.

### 6.5 Buyer PII & data ownership (B1)
Buyer-data capture introduces a **new PII surface** (name/contact/purchase history per the thesis's "organizer owns all data" promise). RLS, retention, export, and GDPR posture require B1 review before the capture pipeline ships.

---

## 7. Proposed D4 namespace & surfaces (pending A1/B1 sign-off)

| Surface | Proposed | Notes |
|---|---|---|
| Code dir | `d4_bridge/` (or `bridge/`) | Integration-layer service code. |
| Listing clients | `*_listing_client.py` siblings to D2's read clients | §6.1 carve-out; D2 co-owns. |
| Tables | `bridge_clients`, `bridge_events`, `bridge_inventory`, `bridge_distributions`, `bridge_buyers`, `bridge_event_xref`, `bridge_pull_log` | Single-writer (D4). `bridge_event_xref` propagates into canonical via A1 drift triggers. |
| Edge functions | `supabase/functions/bridge-*` | Inventory-ingest webhook, distribution push, reconcile. Must carry `requireCronSecret` / proper auth (lockdown rule #7). |
| Migration pattern | `*_bridge_*.sql` | Authored by D4; **applied to prod by A1 only**. |
| Render service | `vibepass-bridge-*` | A1 provisions; D4 gets write scope on its own service when live. |
| Intake fork | separate repo (TBD: Hi.Events vs pretix) | Engineering-team stack-familiarity call per thesis §4.3. |

---

## 8. Open decisions / prerequisites (need operator / A1 / B1 input)

1. **Hi.Events vs pretix** — **D4 recommends pretix** for long-term extensibility (plugin system + Python stack-fit); full analysis in [`d4_intake_platform_eval.md`](archive/d4_intake_platform_eval.md). The thesis exec-brief leaned **Hi.Events** for speed-to-prototype — operator confirms the final pick.
2. **Existing `hi-events` Render service** — **resolved (2026-05-20): not our fork. D4 stands up new** regardless of platform pick.
3. **Upstream-write authorization** (§6.1) — operator go/no-go to begin a per-platform listing-write carve-out, and which platforms first. Note: TEvo is itself a B2B distribution hub that may fan out to multiple downstream points-of-sale — clarify which channels are **direct API integrations** vs. **reached via TEvo / a POS hub** (avoids assuming 10 separate direct integrations).
4. **Repo location of the fork** — separate repo (recommended; AGPL-3.0 + different stack) vs. monorepo subdir.
5. **Lane mapping** — **resolved (2026-05-20)**: storefront is **D1** (not D2); **D4 is independent from D0 for now**; D2 = distribution rails; **Automatiq distribution lands as a later D1 addition**.
6. **Governance status flips** (A1-owned): flip D4 from "UNASSIGNED/future" → "ACTIVE" across `PROJECT_BIBLE.md §2` + `README.md`; claim an aging-sweep minute slot (`CLAUDE.md §5` registry). D4 drafts; **A1 lands** (governance-doc owner; push to `main` is per-task per `PROJECT_BIBLE §2.3`).

---

## 9. Out of scope for D4 (the engineering lane)

The thesis is a business strategy document. The following are **operator / BD scope**, not D4 engineering: warm-intro acquisition, revenue-share model, contracts/LOE, prospect outreach, partnership talks (Opendate etc.), and the Global Rewards commercial relationship. D4 builds the rails; it does not run go-to-market.

---

## 10. References

- *The Bridge — Strategic Opportunity Report* (Julian, Mar 2026, Confidential — external).
- `docs/d4_operating_constraints.md` — D4 lane self-contract (read/write surfaces, forbidden actions).
- `CLAUDE.md` — lockdown invariants (esp. rule #2 upstream read-only, rule #7 edge-fn auth).
- `PROJECT_BIBLE.md §2` §D4 + §6 (deploy ownership) · `PROJECT_BIBLE.md §2` (push matrix, single-writer).
- `PROJECT_BIBLE.md` §4 (D0 SECDEF RPCs), §5 (cross-source bridge topology), §3 (column landmines).
- `d1_operating_constraints.md` — Sprint-2 RULE-2 carve-out (template for §6.1 upstream-write).
- Hi.Events: `github.com/HiEventsDev/hi.events` · pretix: `github.com/pretix/pretix`.

## Revision history

| Date | Change |
|---|---|
| 2026-05-20 | Initial charter — D4 activation. Bridge thesis → technical architecture; governance departures (§6) enumerated; namespace + open decisions drafted for operator/A1/B1. Authored by D4 as a self-contract; A1 reviews via PR. |
