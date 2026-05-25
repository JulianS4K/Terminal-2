# D0 LLM Analysis Layer — Design Spec

**Author:** D0 · 2026-05-24 · status: draft for operator approval
**North star (operator directive 2026-05-24):** the LLM is a **force multiplier for the
broker's judgment** — it makes the human faster and sharper, and *the human always makes
the call*. It is **complementary, never a replacement for human insight.** It never
auto-acts, never becomes the source of truth, and never gathers data the human couldn't.

This spec exists so "add Grok / an LLM" is a *wiring* job against the existing read-RPC
surface — and so the force-multiplier principle is enforced in code, not just aspired to.

---

## 1. Design tenets (force-multiplier → enforceable rules)

| Tenet | What it means in build terms |
|---|---|
| **Human-in-the-loop** | LLM *surfaces, computes, summarizes, proposes* — the broker *decides + acts*. No autonomous pricing or actions. Any suggestion is framed as "consider," never "done." |
| **Grounded in truth** | Every figure comes from a **tool call** (the read RPCs). The LLM **quotes exact tool values verbatim** and the UI **renders the underlying numbers inline** so the human verifies at a glance. It never paraphrases or estimates a number. |
| **Augment, don't replace the dashboards** | Dense views (Movers, Event, ladder) stay for scanning / monitoring / exact data. The LLM owns the *long tail*: NL queries, synthesis, "explain / compare," ad-hoc views you'd otherwise hand-build. |
| **Compress the gather, not the judgment** | The LLM's job is to collapse "find → compute → summarize" so the broker spends their time on the call, not on data wrangling. Optimize for *time-to-insight*, then get out of the way. |
| **Transparent + honest about uncertainty** | Shows its work (which tools it called), cites sources, flags staleness / low confidence, and says "verify this / I don't know" rather than guessing. |
| **Read-only + identity-scoped** | Tools are read-only (lockdown rule #2). The LLM runs as **the user's** token → RLS scopes it. Never the `service_role` key; never data the human can't see. |

**Anti-goals (explicit):** auto-pricing; replacing the scan tables; being the number-of-record;
acting without the human; a chat that hides the data behind prose.

---

## 2. What it does / doesn't

- **Does:** natural-language queries over the data ("MLB events where SG median >20% over our ask"), synthesis ("summarize today's movers + why"), explain/compare, draft a pricing rationale, the long tail of one-off views.
- **Doesn't:** set or push prices, replace the dense scanning grid, serve as the authoritative number, take any irreversible action.

---

## 3. Tool surface (read RPCs exposed as LLM tools)

All SECURITY DEFINER, read-only, RLS-scoped. Reuse what exists — no new data plumbing:

| Tool | RPC | Returns |
|---|---|---|
| search | `terminal_search` | events / performers / venues typeahead |
| event detail | `get_broker_event_page_v2` | full event payload (pricing, our position, freshness) |
| event chart | `get_event_chart_extended` | price/inventory time-series + ESPN annotations |
| movers | `get_event_movers_with_sg` | book mark-to-market winners/losers |
| zones/splits | `get_event_sg_zones_splits` | section-level price ladder |
| performer / venue | `get_broker_performer_page` / `get_broker_venue_page` | aggregate rollups |
| blind spots | `get_blind_spots_sg_selling` / `_tevo_selling` | demand signals |
| weather | `get_event_weather_localized` | venue forecast + alerts |

The model calls these; it never queries raw tables or invents values.

---

## 4. Data scope (RLS) — the crux

Split the surface explicitly:
- **Shareable market intelligence** (events, TEvo/SG prices + medians, ESPN, weather, movers) → readable by any authenticated role.
- **Private book** (owned positions, our orders, owned-premium, P&L) → **only the owner's own**; never another user's chat. This boundary protects the edge — get it wrong and the LLM leaks your positions.

For the **single-operator phase (below)** this is trivial — it's your own session over your own data. The split only matters when "others" are added.

---

## 5. Grounding & safety contract (system prompt)

- "Always call a tool for any figure; quote the tool's exact value; never invent or round-without-saying-so."
- "Render the supporting numbers alongside any prose claim."
- "Flag stale data (use the `freshness` keys) and low-confidence inferences."
- "Never recommend an irreversible or money action as done — frame as the human's decision."
- Per-user token; per-IP rate limit; the 8s RPC ceiling stays in front; BYO-key optional (personal cost).

---

## 6. Open decisions (operator)

1. **Who are "others"?** invite/allowlist vs open signup (drives the auth change off the `@s4kent` single-gate).
2. **What can a personal chat see?** public intel only, or also their own private data?
3. **Vendor:** Grok / Claude / GPT — pick on tool-use reliability + cost (Grok's live-X data is a *bonus* for sentiment, not a deciding factor).
4. **Cost model:** BYO-key (personal usage) vs hosted.

---

## 7. Phased build (lowest-risk first)

1. **This spec** — tool surface + grounding rules approved.
2. **Operator analysis panel (single-user).** An in-terminal chat panel scoped to *your own* authenticated session + the read tools + one LLM. **No multi-tenancy, no RLS split, no new auth** — pure force-multiplier on your own data. Highest immediate value, lowest risk. *Recommended starting point.*
3. **RLS public/private split + per-user accounts** — when opening to others.
4. **BYO-chat via MCP** — power users plug their own chat client into the same tool surface.

Built once, the tool surface powers the in-app panel *and* the BYO-chat path.

---

## 8. Write / action layer — OFF now, explicit future goal

**Today: read-only, period.** The skill, every tool, and the whole terminal are read-only
(lockdown rule #2). No writes to terminal data; no writes/holds/orders to any upstream
marketplace (TEvo / SG / Vivid / TickPick). The LLM *proposes*; the human acts in the POS.

**Future goal (operator directive 2026-05-24):** a write / action layer — e.g. the **Pricing
Queue** (draft a price change here → human approves → push back to the marketplace) — *is* the
eventual goal. Deliberately off now; recorded so it isn't lost.

**Gates to flip it on (all required):**
- Explicit **operator authorization** to open a write path (lockdown rule #2).
- **Human approves every write.** The LLM may *draft* a change; it never auto-executes —
  per-action confirmation, never bulk-auto.
- Full **audit log** (who / what / when / old→new) + **reversibility / undo**.
- Per-user scope + rate limits; writes use the user's identity, never a shared elevated key.
- **Force-multiplier preserved:** even with write on, the human stays the decision-maker —
  the layer makes *execution* faster, never *autonomous*.

Until every gate is met, read-only stands.
