# D4 / Exos — prod apply handoff (A1)

**Author:** D4 · **Date:** 2026-05-24 · **Branch:** `claude/d4-comprehensive-testing-wPECJ` (PR #323)
**Audience:** A1 (sole prod applier per `MIGRATION_CONVENTIONS.md §9`) + operator (secrets/cron).

This is the request to promote the **free-first** D4 ticketing core from "built + branch-verified" to **live on prod**. Everything below is authored and on the PR branch; none of it is applied yet. Stripe + distribution stay dormant.

---

## 0. TL;DR — readiness verdict

Code is near-ready and branch-verified. The live system is still **phase-1/2 only**: the entire hardening + growth + mail batch is unapplied, and **no `exos-*` edge function is deployed** (so mail queues but never sends). The path to "near production ready" is: **apply the batch → deploy the drainer → operator secrets → door rehearsal.**

---

## 1. Live on prod today (verified read-only 2026-05-24)

- **Tables:** `exos_orgs`, `exos_profiles`, `exos_events`, `exos_ticket_tiers`, `exos_tickets`, `exos_transfers`, `exos_event_checkins`, `exos_scan_rejects`, `exos_discount_codes`, `exos_org_memberships`, `exos_org_invites`, `exos_org_follows`, `exos_org_secrets`, `exos_mail`
- **Views:** `exos_public_orgs`, `exos_public_events`, `exos_public_tiers`
- **Functions:** `exos_mint_tickets`, `exos_void_ticket`, `exos_check_in_ticket` (⚠ **3-arg, pre-HMAC**), `exos_create/claim/cancel_transfer`, `exos_create_org`, `exos_claim_invite`, `exos_follow/unfollow_org`, `exos_has_org_role`, `exos_is_admin`, `exos_holds_ticket`, `exos_queue_mail`, `exos_touch_updated_at`
- **Last applied migration:** `20260523120000_exos_realtime_checkins`

## 2. ⚠ Apply mechanism — important

The prod migration ledger (`supabase_migrations.schema_migrations`) records the exos migrations under **apply-time** version numbers, **not** their filename timestamps (e.g. `20260520140000_exos_org_follows` is logged as version `20260523015225`). They were bootstrapped via the **MCP `apply_migration`** tool (or dashboard SQL), not `supabase db push`.

**Therefore: apply each migration below by running its SQL via `apply_migration` (MCP) or the dashboard SQL editor — do NOT `supabase db push`.** A CLI push would mismatch versions and try to re-run already-applied migrations.

---

## 3. Migration apply order (free-first batch)

Apply **in this order** (it is the dependency order). Apply one at a time; **stop on any error** and report. All files are under `supabase/migrations/`.

| # | File | Adds | Depends on |
|---|---|---|---|
| 1 | `20260523130000_exos_mail_drainer.sql` | `exos_mail` claim columns (`attempts`/`claimed_at`/`last_attempt_at`, `'sending'` status) + `exos_mail_claim_batch()` + `exos_mail_mark()` | `exos_mail` (live) |
| 2 | `20260523150000_exos_mint_event_cap.sql` | `exos_mint_tickets` CREATE OR REPLACE — enforces `total_tickets` atomically | phase-2 (live) |
| 3 | `20260523160000_exos_check_in_verify.sql` | **DROPs 3-arg `exos_check_in_ticket`, CREATEs 4-arg** with `p_barcode_payload` (server HMAC verify, malformed-payload reject) | phase-2 (live) |
| 4 | `20260523180000_exos_purchase_limits.sql` | `exos_assert_purchase_limit()` + wires it into `exos_mint_tickets` (cumulative per-account, blocks 2nd-buy; admin bypass) | #2, #3 |
| 5 | `20260523200000_exos_growth_primitives.sql` | `exos_orgs.marketing` jsonb + `exos_redeem_discount_code()` + `exos_announce_to_followers()` + distribution channel model | follows + mail (live) |
| 6 | `20260523210000_exos_mail_ticket_issued.sql` | `ticket-issued` template + `exos_queue_ticket_issued()` | #1, #5 |
| 7 | `20260523220000_exos_notify_holders.sql` | `exos_notify_event_holders()` | #1 |
| 8 | `20260523230000_exos_issue_to_email.sql` | `exos_issue_ticket_to_email()` (box-office comp to a named account) | #2, #6 |
| 9 | `20260524120000_exos_public_marketing.sql` | `exos_public_orgs` view + `marketing` (public-safe socials/pixel-ids) | #5 |
| 10 | `20260524130000_exos_security_hardening.sql` | pin `exos_touch_updated_at` search_path; revoke anon EXECUTE on `exos_has_org_role` | phase-1 (live) |

### ⛔ Do NOT apply (dormant by design — free-first excludes payments/distribution)
- `20260523170000_exos_stripe_checkout.sql`
- `20260523190000_exos_distribution.sql`

### Caller-compat note for #3
`20260523160000` `DROP`s the 3-arg `exos_check_in_ticket` and creates a 4-arg. The Bridge client (`tickets.ts` / `OrganizerCheckIn`) already passes the scanned payload. Confirm no other deployed caller relies on the 3-arg signature before applying (it's D4-scoped, so none expected). **B1 review requested** on this new server auth surface.

---

## 4. Post-apply smoke verification (read-only)

Run after the batch; all should return the expected rows:

```sql
-- New functions exist (expect 8 rows):
SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND proname IN (
  'exos_assert_purchase_limit','exos_mail_claim_batch','exos_mail_mark',
  'exos_redeem_discount_code','exos_announce_to_followers','exos_queue_ticket_issued',
  'exos_notify_event_holders','exos_issue_ticket_to_email') ORDER BY proname;

-- check_in_ticket is the 4-arg version (expect a row with 4 args incl. p_barcode_payload):
SELECT pg_get_function_arguments(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND proname='exos_check_in_ticket';

-- marketing column + public view expose it (expect 'marketing' in both):
SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='exos_orgs' AND column_name='marketing';
SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='exos_public_orgs' AND column_name='marketing';

-- anon EXECUTE on exos_has_org_role revoked (expect NO 'anon' row):
SELECT grantee FROM information_schema.routine_privileges
WHERE routine_name='exos_has_org_role' AND privilege_type='EXECUTE';
```

---

## 5. Edge function deploy + cron (mail delivery)

No `exos-*` edge function is deployed. Without the drainer, every queued mail (ticket-issued, transfer, announce, holder-notify) sits `pending` forever.

**A1 — deploy:** `supabase/functions/exos-mail-drain/index.ts` (cron-secret gated, service-role; mirrors `sg-seller-webhook`).

**Operator — edge-function secrets:**
- `RESEND_API_KEY` — Resend key (swap providers by editing `sendEmail()`)
- `EXOS_MAIL_FROM` — verified sender, e.g. `Bridge <tickets@yourdomain>`
- `CRON_SECRET` — already used repo-wide
- (`SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` injected by the platform)

**A1/operator — cron (`cron.*` is operator-gated):** the 2-min schedule snippet is in the function header:
```sql
select cron.schedule('exos-mail-drain-2min', '*/2 * * * *', $cron$
  do $b$ begin
    if not public.cron_should_fire('exos-mail-drain-2min') then return; end if;
    perform public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/exos-mail-drain', '{}'::jsonb);
  end $b$; $cron$);
```

---

## 6. Operator config (non-code, required for a 1000-person event)

- **D4-OPS-9 — Auth SMTP at scale.** ~1000 attendees each sign in (OTP/OAuth) to view their ticket. Supabase default SMTP rate-limits hard → mass OTP at the door throttles. **Configure a custom SMTP provider in Supabase Auth + raise rate limits.** Prefer magic-link/OAuth over email-OTP at the door, plus a pre-event "claim your ticket" nudge to spread sign-ins.

## 7. Frontend deploy (D0/A1)

Bridge SPA source fixes (D4-OPS-1/3/4/10 — SW scope, never-cache hosts, CSV void label, realtime check-ins) + the marketing/consent rendering in this PR only reach prod after a **rebuild → `static/bridge/`**: `npm --prefix d4_bridge run build` (with `.env.local` Supabase keys) then copy `dist/ → static/bridge/`.

## 8. Security advisor status

- **Hardened in this batch** (mig #10): `exos_touch_updated_at` search_path; anon EXECUTE on `exos_has_org_role` revoked.
- **Accepted by design (no action — B1-noted):** `security_definer_view` on the three `exos_public_*` views (they ARE the anon boundary — anon has no base-table SELECT, so they must stay definer); `rls_enabled_no_policy` on `exos_mail` (deny-all to clients is correct — SECDEF-written, service-role-read).

## 9. Go/no-go gate

**D4-OPS-11 — physical door rehearsal** on the deployed app, 2-3 devices: real RPC latency under concurrent scans, 1000-row offline-registry pull, cross-lane Realtime convergence, mass sign-in spike. DB-side load is already validated on a branch (8-lane concurrent check-in, 0 double-admits). **Gate free-event go-live on this rehearsal.**

## 10. Rollback

Each migration is a self-contained `CREATE OR REPLACE` / additive DDL except #3 (`DROP`+`CREATE` of `exos_check_in_ticket`). To roll back #3, re-apply the prior 3-arg definition from `20260520130000_exos_phase2_tickets.sql`. The mail-drainer columns (#1) and `marketing` column (#5/#9) are additive and safe to leave if a later step is reverted.
