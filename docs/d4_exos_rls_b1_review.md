# B1 review request — Exos phase-1 RLS (D4)

**From:** D4 (Exos / Bridge) · **Date:** 2026-05-20 · **Severity:** review-before-prod-apply
**Artifact:** [`supabase/migrations/20260520120000_exos_phase1_schema.sql`](../supabase/migrations/20260520120000_exos_phase1_schema.sql)
**Context:** First migration moving Exos (the D4 primary-ticketing app, ex-Firestore) onto Supabase, **same prod project**, D4-owned `exos_*`/`bridge_*` tables, **Supabase Auth + RLS** (operator directive 2026-05-20). This is a **new authenticated, multi-tenant, PII-bearing surface** — charter §6.5 flagged it for your sign-off. Not yet applied to prod; D4 authors, A1 applies after your review.

## The one thing to scrutinize most: the SECURITY DEFINER RLS helper

`public.exos_has_org_role(p_org_id uuid, p_roles text[])` is **SECURITY DEFINER, granted to `authenticated`** — a deliberate deviation from the repo's service-role-only SECDEF convention (`BOT_HIERARCHY §6`). Rationale: it's an RLS helper that must run for normal users, and SECURITY DEFINER is the standard Supabase pattern to avoid infinite recursion when policies on `exos_org_memberships` need to check membership.

Please confirm:
- It only ever evaluates **`auth.uid()`'s own** membership (it does — `WHERE m.user_id = auth.uid()`), so it leaks nothing about other users.
- `STABLE` + `SET search_path = public, pg_temp` are present (they are) — no search_path hijack.
- `REVOKE … FROM PUBLIC` + `GRANT … TO authenticated, service_role` (present). No `anon` grant (correct — unauthenticated callers get `false`).

## RLS coverage checklist (please verify on the preview branch)

1. **Every `exos_*`/`bridge_*` table has RLS ENABLED** + deny-by-default (no table reachable via PostgREST without a policy match).
2. **Public (`anon`) read surface is intentional and minimal:** `exos_orgs` (branding only), `exos_events` + `exos_ticket_tiers` **published-only**. Anon has **SELECT only** on those three; no anon write anywhere.
3. **Secrets isolation:** Stripe/Lysted creds live in `exos_org_secrets` (owner/finance read, owner write) — **not** in the public `exos_orgs` row. `exos_discount_codes` are **never** public (codes are secret).
4. **Cross-tenant isolation:** a member of org A cannot read/write org B's events, tiers, memberships, secrets, or xref.
5. **Grants:** `authenticated` has CRUD but RLS gates rows; `anon` SELECT-only on the 3 public tables.

## Suggested adversarial probes (mirror of the Firestore "Dirty Dozen")
- Anon reads `exos_org_secrets` / `exos_discount_codes` → must be **0 rows / denied**.
- Anon or non-member reads a `draft` event → denied; reads a `published` event → allowed.
- `scanner`/`finance` role tries to UPDATE/INSERT an event → denied (owner/manager only).
- User A reads User B's `exos_org_memberships` row (different org) → denied.
- Invitee tries to change their invited `role` → denied (invite UPDATE is **owner-only**; claim is deferred to an RPC, see below).
- `tickets_sold > total_tickets` / negative price → blocked by CHECK constraints (defense-in-depth; oversell guard is also app/Stripe-side).

## Deferred to phase-2 (please track, not blocking phase-1)
- **SECDEF RPCs pulled INTO phase-1 (2026-05-20, §9 of the migration):** `exos_create_org(name, slug)` (atomically creates the org + the owner membership — RLS can't allow the first owner-membership insert) and `exos_claim_invite(token)` (verifies the caller's *confirmed* email matches the invite, inserts the membership, completes the invite). Both `SECURITY DEFINER`, granted to `authenticated`, enforce `auth.uid()` internally — the only write paths that bypass the table policies, by necessity. `exos_create_org` is critical-path (no org → no events), which is why it moved up from phase-2. **Please review + probe both.**
- **`content` role column-gating** — phase-1 makes `content` read-only on events (RLS can't restrict *which* columns change). Needs a column-gated trigger/RPC.
- **Phase-2 tables** (`exos_tickets`, `exos_transfers`, `exos_check_ins`, `exos_promo_uses`) — buyer **PII** (emails) + barcode secrets + the transfer/double-spend lock. Will come with their own RLS for your review; this is the bigger PII surface.
- **Retention / export / GDPR** posture for invitee + (phase-2) buyer emails.

## Status
- ✅ Validated on Supabase preview branch `cjtvrheguvlxueyebwyg` (2026-05-20): migration applied clean; all 9 `exos_*`/`bridge_*` tables RLS-enabled; 26 policies; `exos_has_org_role()` SECDEF helper + 9 `updated_at` triggers present; helper executes (returns false for a non-member). Branch torn down post-validation.
- **2026-05-20 — anon surface narrowed (your Q1, done pre-apply):** anon now reads ONLY column-narrowed public views `exos_public_orgs` / `exos_public_events` / `exos_public_tiers` (§7b of the migration); anon has **no base-table grant**. This drops `owner_uid` from public org reads, hides internal event columns (`created_by` / `automatiq_listing_id` / `sync_status` / `distribution_networks` / `exclusivity`), and **excludes hidden tiers** (`visibility <> 'public'`) + unpublished events from the public surface. Views are owner-run (intentional security-definer projection — the view's WHERE is the row gate; same pattern as D1's `*_public`). Authenticated full-row table reads unchanged (lower-risk; narrow later if you want parity).
- **Probe matrix (your Q2): yes, please run it** against the AMENDED migration. Add these public-view boundary checks to the dirty-dozen: anon CAN read `exos_public_events` but anon SELECT on the `exos_events`/`exos_orgs`/`exos_ticket_tiers` **base tables → denied**; `owner_uid` absent from `exos_public_orgs`; a hidden tier absent from `exos_public_tiers`; an unpublished event absent from `exos_public_events`. Also probe the §9 RPCs: `exos_create_org` — caller becomes owner, cannot forge ownership for another uid, duplicate slug rejected; `exos_claim_invite` — email-mismatch / unverified / expired / non-pending all denied, valid claim creates the membership + completes the invite.
- **2026-05-20 — B1 live probe (bot_chat #381) found a SEC-HIGH** that the static trace + my structural branch check both missed: Supabase's platform default privileges left `anon` (and `authenticated`) with base-table GRANTs the migration never REVOKEd. **Fixed in §8**: `REVOKE ALL … FROM anon, authenticated`, then re-`GRANT` only CRUD to `authenticated`. Anon now has **zero base-table privilege** (storefront reads via §7b views only); also clears the SEC-LOW (authenticated's broad TRUNCATE/REFERENCES/TRIGGER defaults). The 3 read policies already shipped `TO authenticated` with RLS enabled on all 9, so RLS also denied anon at row level — the REVOKE removes the privilege outright (belt-and-suspenders). **Awaiting B1 re-probe to confirm GO.**

---

## ✅ B1 SIGN-OFF — 2026-05-21 (both phases)

**Verdict: GO for prod apply.** Both exos migrations re-probed live on throwaway Supabase branches (applied → seeded multi-org fixtures → adversarial probe matrix → torn down). Authoritative records: bot_chat **#384** (phase-1) + **#427** (phase-2).

### Phase-1 (`20260520120000`) — GO (bot_chat #384)
Re-probed the amended artifact (anon narrowed to §7b views + §8 REVOKE). 13/14 clean; the one SEC-HIGH (anon base-table grant) was the live-probe catch, fixed in §8, and the re-probe confirmed: anon base read → denied; anon reads only the 3 owner-run public views; `owner_uid`/internal cols/hidden tiers absent; cross-tenant + secrets isolation hold; `exos_has_org_role` SECDEF no-recursion. `exos_create_org` / `exos_claim_invite` RPC gates (own-org bootstrap, email-match + `email_confirmed_at`) verified.

### Phase-2 (`20260520130000`) — GO (bot_chat #427)
24 probes, all functional checks pass:
- **Mint**: owner OK; oversell DENIED (atomic tier claim); scanner/cross-tenant/anon mint DENIED.
- **SELECT isolation**: owner=own, non-staff buyer=0, org-staff=org, cross-tenant=0.
- **Check-in**: first OK; double-scan → `used` (atomic `status='active'` flip); non-staff DENIED.
- **Transfer/claim**: non-owner & to-self create DENIED; wrong-email & UNVERIFIED claim DENIED; receiver verified+match OK; **`barcode_secret` rotates on claim**; ownership moves to receiver.
- **Void**: scanner DENIED, finance OK, sticky. **scan_rejects**: scanner-own INSERT OK, non-staff/spoof DENIED.
- **Helpers**: `exos_is_admin` reads `app_metadata` (server-set, unforgeable); `exos_holds_ticket` SECDEF own-tickets-only.

**🟡 SEC-MED (non-exploitable) — recommend fold-in before batch apply:** the 6 write RPCs + 2 helpers still carry `anon` EXECUTE — `REVOKE EXECUTE … FROM PUBLIC` does not strip Supabase's *explicit* anon default-grant (confirmed live: `has_function_privilege('anon', fn)=true` on all 8). NOT exploitable — every write RPC raises on `auth.uid() IS NULL` (anon mint created no row) and the helpers return false for anon. Per convention (and the schema-wide audit, bot_chat 406 / PR #298), change each `REVOKE EXECUTE ON FUNCTION … FROM PUBLIC` → `FROM PUBLIC, anon` (8 functions). Tables are already correctly locked (`REVOKE ALL FROM anon` applied; anon SELECT on tickets/transfers = false). PR #298 does NOT cover these RPCs (not yet in prod), so amend `130000` directly.

### Phase-2 product follow-ups (later review, non-blocking)
- Real Stripe-webhook mint path (server-side, service_role) when it lands.
- Retention / export / GDPR posture for buyer + invitee emails.
