# Bridge (D4 / Exos) extraction plan — sketch

**Status:** proposal / not started. Sketched 2026-07-02 for the equity-separation
conversation. No code moved. This is the technical substrate for asserting that
the Bridge is a distinct play from the terminal/storefront — the repo structure
should be *visibly in motion* before the question is asked in the meeting.

**Decision needed from operator before execution** — this crosses every lane,
splits a Supabase project, and rewrites deploy wiring. Do not execute without
explicit go-ahead and a step-by-step confirmation loop.

---

## 1. What "Bridge" is, concretely (verified footprint)

Per `.github/CODEOWNERS` and the tree:

- **App code:** `d4_bridge/` (React app + build output), `static/bridge/`
- **Edge functions:** `supabase/functions/exos-{api,checkout,connect-onboard,distribute,mail-drain,webhook-drain}/` (6)
- **Migrations:** every `*exos*` migration in `supabase/migrations/`
- **Data:** `exos_*` tables — currently in the SAME Supabase project as broker
  intel (`hzrizjeaxlqcxfrtczpq`). **This is the crux of #1**: diligence sees
  Exos as a subdirectory of company tooling, one history, one DB, one deploy.
- **NOT Bridge:** the A1/D0 `*bridge*` names (`sg_to_tevo_search_bridge`,
  `espn_bridge`, …) — those are broker-side and stay.

⚠️ **A1 must produce the authoritative `exos_*` table inventory** before any DB
split — CODEOWNERS globs cover files, not the table list. This plan assumes that
inventory exists as step 0.

## 2. Target end state

- New repo `exos-bridge` (or chosen name): owns `d4_bridge/`, `static/bridge/`,
  the 6 `exos-*` functions, the `*exos*` migrations — carrying git history.
- New Supabase project owning the `exos_*` schema.
- Terminal-2 keeps everything else; the `d4_bridge`/`exos` CODEOWNERS block,
  the `area:bridge` labeler rule, and the D4 CI legs are removed here.
- Any genuinely shared surface (auth model, a handful of reference tables) is
  named explicitly and reached across a defined boundary, not by co-tenancy.

## 3. Code extraction (history-preserving)

Use `git filter-repo` (not `filter-branch`) on a fresh clone:

```
git clone <terminal-2> exos-bridge && cd exos-bridge
git filter-repo \
  --path d4_bridge/ \
  --path static/bridge/ \
  --path supabase/functions/exos-api/ \
  --path supabase/functions/exos-checkout/ \
  --path supabase/functions/exos-connect-onboard/ \
  --path supabase/functions/exos-distribute/ \
  --path supabase/functions/exos-mail-drain/ \
  --path supabase/functions/exos-webhook-drain/ \
  --path-glob 'supabase/migrations/*exos*'
```

Then, in Terminal-2, a companion PR **removes** those same paths (so the split
is clean, not a copy). Sequence the removal PR *after* the new repo is stood up
and green, never before.

Caveats to resolve first:
- **Shared imports:** confirm `d4_bridge/` doesn't import from `core/` /
  `routers/` / root clients. If it does, either vendor the dependency into the
  new repo or expose it as a small published contract. Grep before filtering.
- **Migration interleaving:** `*exos*` migrations share the global timestamp
  line with broker migrations. In isolation their relative order is preserved;
  verify none has a cross-schema dependency on a non-exos object.

## 4. Supabase project split (A1-led — highest risk)

1. Stand up the new project; apply the `*exos*` migrations to it from zero.
2. Migrate `exos_*` data (`pg_dump`/`COPY` of just those tables).
3. Repoint the 6 edge functions + `d4_bridge` config at the new project URL/keys.
4. Cut over, verify, then drop `exos_*` from the old project in a final,
   separately-reviewed migration (A1 applies — D-tier has no DB-apply authority).
5. RLS: re-establish `exos_*` policies in the new project; they no longer share
   the broker JWT/email gate, so the auth model for Bridge is now its own.

## 5. Fallout to fix in Terminal-2 (this repo) after the split

- `.github/CODEOWNERS` — remove the D4/Bridge block.
- `.github/labeler.yml` — remove `area:bridge`.
- `.github/workflows/tests.yml` — the "TypeScript (D4 bridge)" job leaves with
  the code; drop it here.
- Any `render*.yaml` / deploy wiring for the bridge surface.
- `docs/d4_bridge_charter.md` + `d_tier_unification_*` docs — relocate or
  cross-link.

## 6. Sequencing for the meeting

Minimum "visibly in motion" before the conversation, without betting the DB:
1. **Now (low risk):** create the new repo with history via filter-repo; push it.
   The separate history *exists* — that alone changes the diligence story.
2. **Now (low risk):** land the CODEOWNERS/labeler/CI removals here as a draft PR
   gated behind the new repo going live.
3. **Deliberate (A1, gated):** the Supabase project split — the real work, done
   carefully after the meeting establishes the direction.

Steps 1–2 are reversible and cheap; step 4 is the irreversible one and should
follow an explicit decision, not precede it.
