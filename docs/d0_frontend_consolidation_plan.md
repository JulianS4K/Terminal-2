# D0 Frontend Consolidation Plan

Authored by D0 (2026-05-15). Plans the post-reorg work (per `bot_chat` row 157) across 3 frontend services and how D0 manages D1/D2 going forward. Companion to [d0_operating_constraints.md](d0_operating_constraints.md) + [edit_coordination_protocol.md](edit_coordination_protocol.md).

## State today

3 services, 3 code surfaces, 3 authoring lanes:

| Service | Code surface | Authored | Tech |
|---|---|---|---|
| `vibepass-terminal-test` | `static/terminal/*` | D0 | static CDN, vanilla JS, supabase-js client, uPlot |
| `vibepass-storefront-test` | `app.py /api/store/*` + `static/store/*` | D1 | FastAPI + vanilla JS |
| `d2-orders-dashboard` | `d2_dashboard/*` | D2 | FastAPI + vanilla JS, Supabase OAuth |

Subordinate state (rows 168, 169):
- D1: idle on storefront. Outstanding D0-coord items — (a) per-service Render plan flip to starter, (b) HEAD /store 405 cosmetic, (c) Sprint 3 legal pages.
- D2: idle. Outstanding — TickPick vault rotation (awaiting B1).

## Phases

### Phase 1 — Governance scaffolding (in flight)

- [x] `docs/d0_operating_constraints.md` (commit 39635fe)
- [x] `docs/edit_coordination_protocol.md` (commit a11e48e, demonstrated end-to-end with claim 166 / release 167)
- [x] this plan doc
- [ ] D0 sign-off announcement to D1/D2 with template comment
- [ ] Friday checkpoint cadence — first run end of week
- [ ] `docs/d0_roadmap.md` — single rolling roadmap, weekly update

### Phase 2 — Design system convergence (weeks 1-4)

Each app keeps its personality (terminal Bloomberg-dark, storefront consumer-friendly, dashboard ops-dense), but the **common color tokens converge** so cross-page navigation feels unified.

- Author `static/_shared/design-tokens.css` — root vars only (`--bg`, `--panel`, `--line`, `--text`, `--accent`, `--pos`, `--neg`, `--warn`). D0 writes.
- Terminal already uses these tokens. D2 dashboard adopts them in a follow-up (D2 lane, D0 sign-off). D1 storefront refactor is lower priority (public-facing UX is more sensitive).
- Auth: terminal + dashboard share Supabase OAuth + `@s4kent.com`. Storefront stays public (anonymous browse). No further convergence.

### Phase 3 — Code surface integration (weeks 4-12)

Open `static/_shared/` for files used by ≥2 apps:
- `design-tokens.css` (Phase 2)
- Eventually: shared `auth.js` (terminal's TerminalAuth pattern could extract), `nav-builder.js` for unified top-nav

Storefront mostly opts out (public-facing, different shape). Terminal + dashboard converge first.

### Phase 4 — Service rationalization (months 3-6)

Cost: 3 services × ~$14/mo starter once D1+D2 flip plans = $42/mo recurring.

Options:
- **A. Status quo** — 3 services. Clean separation; independent deploys. Highest cost.
- **B. Merge terminal + dashboard** — both operator-facing; single service mounts both at `/terminal` and `/dashboard`. Storefront stays separate (public traffic, different scaling profile).
- **C. Merge all** — one Python service. Cheapest; deploys coupled (storefront downtime = terminal downtime). Reject for prod risk.

**Recommend B in 3-6 months** once traffic + usage patterns are visible. Decision gate: total ops-side MAU >50, deploy frequency stabilizes.

### Phase 5 — Cross-page UX (open-ended)

Nice-to-haves, no commitments:
- Order in dashboard deep-links to event in terminal
- Shared search bar across storefront + terminal
- Unified user identity (already true via shared Supabase project)

## Governance going forward

### D0 sign-off on D1/D2 PRs

A1 won't merge D1/D2 PRs without a D0 sign-off comment. Template:

```
D0 sign-off: [APPROVE | REQUEST CHANGES | BLOCK]
Scope: <does the PR stay within the author lane's write surface?>
Surface: <does it break any cross-frontend expectation?>
CI: <pytest + scan + check status>
Notes: <one or two lines if needed>
```

- D0 reviews within 24h of PR open (business hours). After 24h, A1 can merge urgent fixes; D0 re-ups in PR comment post-fact.
- Override: B1 can sign-off for security-critical fixes if D0 unavailable.
- D0 own PRs don't need self-sign-off; A1 reviews per standard pusher protocol.

### Friday checkpoint cadence

Every Friday, D0 posts `bot_chat` `status` event summarizing:
1. PRs merged this week (by lane: D0, D1, D2)
2. Open PRs and their D0 sign-off status
3. Risk items
4. Next week's priorities

Mirrors C1's daily checkpoint at weekly scale.

### Rolling roadmap

`docs/d0_roadmap.md` — single roadmap for all 3 frontends. Sections:
- **Now** (current session)
- **Next** (1-2 weeks)
- **Later** (1-3 months)
- **Backlog** (everything else)

D1/D2 propose items via `bot_chat` `question` event; D0 prioritizes weekly.

### Cross-lane editing

All cross-lane file edits use the claim/release protocol ([edit_coordination_protocol.md](edit_coordination_protocol.md)). Demonstrated working in claim 166 / release 167 (D0 edit on `.gitleaksignore` — B1's surface).

### Token discipline (row 139, applies to D0)

- bot_chat entries ≤1500 chars when feasible (favor `in_reply_to` over re-summary)
- Commit messages: title <70 chars; body answers "why" not "what"
- Don't re-read just-edited files
- Batch parallel MCP queries in one message

### B1 touchpoints

- New public endpoints raised via `bot_chat` `question` for B1 audit
- New SECDEF functions need §6 guard (B1 enforces post-PR)
- B1's per-session anon-surface sweep covers all 3 frontends + DB

### Render write authority (D0)

Per CLAUDE.md §4 post-reorg, D0 has Render MCP write on:
- env-var changes on any of the 3 services
- redeploy triggers
- `update_web_service` (config, build cmd, branch, plan)

Logged via `bot_chat` `change_log` after each change (service ID + var name; never the value).

## Open items for D0 next (queued)

1. **Sign-off announcement** to D1/D2 via `bot_chat`, with the template above. Reply to row 157.
2. **`docs/d0_roadmap.md`** — first version listing the items below + D1/D2's outstanding work.
3. **D1 outstanding follow-through**:
   - Per-service Render plan flip ($14/mo starter on storefront — D0 can exec via Render MCP; verify intent with operator first)
   - HEAD /store 405 — low priority, D1 can address
   - Sprint 3 legal pages — prioritize via roadmap
4. **D2 outstanding follow-through**:
   - TickPick vault rotation — B1's lane, not D0
5. **Phase 2 kickoff** — author `static/_shared/design-tokens.css`, refactor terminal CSS to reference it

## References

- `bot_chat` row 157 — D-tier reorg directive
- `bot_chat` rows 168, 169 — D1 + D2 ack
- [d0_operating_constraints.md](d0_operating_constraints.md)
- [edit_coordination_protocol.md](edit_coordination_protocol.md)
- [terminal-redesign-2026-05-09.md](terminal-redesign-2026-05-09.md)
- [d1_retail_finish_punchlist.md](d1_retail_finish_punchlist.md) — D1's longer roadmap (subsumed into D0 roadmap going forward)

## Revision history

- 2026-05-15: initial — phases 1-5 + governance going forward
