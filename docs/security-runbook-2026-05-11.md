# B1 Security Runbook — 2026-05-11 audit + fix push

> **Audience**: B1 (Security Manager Bot) per `docs/bot-hierarchy.mermaid`. **Carrier PR**: #57 on branch `claude/review-supabase-access-v8Dtl`. **Prior context**: `KANBAN.md` SECURITY BACKLOG section, this repo's audit chat 2026-05-10/11.
>
> A1 has landed code-side fixes for 14 of 16 audit entries. This runbook covers (a) the operator steps you must perform on Supabase / Railway / git BEFORE applying the migrations, (b) the items A1 could not fix in code that need your decision, and (c) verification steps for each CRIT.

---

## Section 1 — Operator prereqs (apply IN THIS ORDER)

These MUST happen before migration `20260511000200_security_anon_jwt_to_vault.sql` will apply. That migration asserts both vault secrets exist and aborts with a `RAISE EXCEPTION` otherwise.

### 1.1 Rotate `CRON_SECRET` to a fresh random value

```bash
# Generate
NEW_CRON_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
echo "$NEW_CRON_SECRET"  # save out-of-band, you'll paste it 3 places below

# (a) Railway env (terminal-2-production service)
railway variables --set "CRON_SECRET=$NEW_CRON_SECRET"

# (b) Supabase Edge Function secret
supabase secrets set CRON_SECRET="$NEW_CRON_SECRET"

# (c) Supabase vault (NEW — required by 20260511000200)
psql "$SUPABASE_DB_URL" -c "SELECT vault.create_secret('$NEW_CRON_SECRET', 'CRON_SECRET');"
# If row already exists in vault:
# psql "$SUPABASE_DB_URL" -c "SELECT vault.update_secret(s.id, '$NEW_CRON_SECRET') FROM vault.secrets s WHERE s.name='CRON_SECRET';"
```

**Why three places**: app.py reads from Railway env; edge functions read from Supabase Function secrets; cron jobs (after migration `20260511000200`) read from vault via `_cron_invoke_edge_fn`.

### 1.2 Seed `EDGE_FN_ANON_JWT` in vault

The current Supabase anon JWT lives in your dashboard → Settings → API → `anon` `public` key. Copy it.

```bash
ANON_JWT="<paste anon JWT from Supabase dashboard>"
psql "$SUPABASE_DB_URL" -c "SELECT vault.create_secret('$ANON_JWT', 'EDGE_FN_ANON_JWT');"
```

The anon JWT is semi-public per Supabase model, but moving it to vault means rotating it never requires a migration cycle again.

### 1.3 Set CORS allowlist env vars

Default in code permits localhost only. Production needs your real frontend origin(s).

```bash
# Railway (FastAPI)
railway variables --set "CORS_ALLOWED_ORIGINS=https://app.s4kent.com,https://terminal.s4kent.com"

# Supabase (chat edge fn)
supabase secrets set CHAT_ALLOWED_ORIGINS="https://app.s4kent.com,https://terminal.s4kent.com"
```

If you don't know the real origins yet, leave defaults — the API will refuse cross-origin requests, which is the safe failure mode.

### 1.4 Generate fresh password for `coworker_readonly`

Migration `20260511000000` will revoke LOGIN. After applying, re-issue:

```bash
NEW_PWD=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")
psql "$SUPABASE_DB_URL" -c "ALTER ROLE coworker_readonly WITH PASSWORD '$NEW_PWD' LOGIN;"
# Deliver $NEW_PWD to the UI coworker out-of-band (Slack DM, 1Password share, etc.)
# Do NOT commit it to any file in this repo.
```

### 1.5 Apply migrations IN ORDER

```bash
supabase db push  # or your usual migration tool
# Auto-apply set (timestamp-sorted, all in supabase/migrations/):
#   20260511000000  coworker_readonly NOLOGIN
#   20260511000100  SET search_path on DEFINER fns
#   20260511000200  anon JWT to vault + cron rebuild  <-- fails if 1.1+1.2 not done
#   20260511000300  RLS on internal tables
#
# Hand-apply set (lives in docs/proposed-migrations/, NOT auto-applied):
#   20260511000400  per-table RLS draft  <-- run §C verification first, then
#                                            copy into supabase/migrations/ and re-run
```

---

## Section 2 — Items A1 could not fix (your call)

### 2.1 [OPS-ONLY] Verify Supabase network restrictions / IP allowlist

**Status**: not actionable from code. Needs Supabase Dashboard.

**Action**: Supabase Dashboard → Project Settings → Database → "Network restrictions". Set an allowlist:
- Railway egress IPs (from Railway docs)
- Your home / office IPs
- Optionally: Supabase region IPs if any internal services reach Postgres

If "open to internet" is required for any reason, document why and accept the residual risk in a follow-up KANBAN row.

**Why this matters even after the code fixes**: the `coworker_readonly` placeholder password (now revoked) and any future weak credential is only exploitable if the host is reachable. Network allowlist is the second perimeter.

### 2.2 [OPS-ONLY] Decide on git-history rewrite

The leaked `CRON_SECRET` literal `thisisevochronsecret123!` exists in commit `5297739` and possibly earlier. The current code rotates the value and redacts the file, but anyone who already cloned has the old value forever.

**Options**:

| Option | When to pick | Cost |
|---|---|---|
| Leave history alone | Repo is private to a small trusted set, and the new `CRON_SECRET` value is unrelated to the leaked one | Zero — but old clones can use the old value if it's ever re-set |
| `git filter-repo --replace-text` to scrub the literal | Repo is or might become public; or you want defense-in-depth | Force-push window, all collaborators must re-clone, all open PRs become orphan |

**Recommendation**: leave history alone IF the repo stays private AND you've rotated the value (you have, per §1.1). The window of exposure is "anyone who cloned between 5297739 and the rotation". For a private repo with 2-3 contributors, that's a known set.

### 2.3 [SEC-LOW] `get_app_secret` whitelist documentation

Landed in this push — see §3.2 below. No action needed from you beyond reviewing the new section in `MIGRATION_CONVENTIONS.md`.

---

## Section 3 — Additional fixes A1 landed in this push

(These complete the "can fix" set. See `KANBAN.md` for the original 14.)

### 3.1 [SEC-MED] `slowapi` rate-limit on `/api/store/*` and auth-burning routes

Adds `slowapi` dependency and a per-IP limiter:
- `/api/store/events` — 60/min
- `/api/store/events/{event_id}` — 60/min
- `/api/store/share` (POST) — 10/min (was the spam vector)
- `/api/store/share/{share_id}` (DELETE) — 10/min
- `/api/store/share/{share_id}` (GET, public read) — 60/min
- `/api/config` — 30/min (this route burns Supabase auth on every call)

If `slowapi` is unavailable in the deploy env, the limiter is no-op (degrades to "unlimited" but app still serves) — see graceful import in `app.py`.

### 3.2 [SEC-LOW] Vault secret governance section in `MIGRATION_CONVENTIONS.md`

New section 7 ("Vault secrets — whitelist + rotation policy") added. Covers:
- How to add a new vault secret (extend `upsert_app_secret` whitelist + add to metadata view)
- How to rotate (`vault.update_secret` only)
- How to read (`get_app_secret` whitelist enforcement)
- Audit query: "which secrets exist, who can read them, when last rotated"

### 3.3 [SEC-HIGH] Per-table RLS draft for domain tables

Draft migration at `docs/proposed-migrations/20260511000400_security_rls_domain_tables_draft.sql` (kept OUT of `supabase/migrations/` so `supabase db push` cannot apply it accidentally). **Marked DRAFT** — DO NOT copy into `supabase/migrations/` until you've run the §C verification queries. It enables RLS on each domain table with a policy that mirrors the current effective access:
- `events`, `performers`, `venues`, `listings_snapshots` → `FOR SELECT TO anon, authenticated USING (true)` (matches existing PostgREST behavior)
- All other domain tables → `ENABLE RLS` with NO policy (service-role only)

**B1 must verify** before applying:
1. `SELECT schemaname, tablename, rowsecurity FROM pg_tables WHERE schemaname='public' AND tablename = ANY(...)` against prod to confirm the diff is what we expect.
2. Run the FastAPI test suite (or hit `/api/store/events` from a logged-in browser) before AND after; any 500 means a table the app reads got locked too tight.
3. If a table needs anon access, add a `CREATE POLICY ... FOR SELECT TO anon USING (true)` to the migration body before applying.

The draft is conservative — it errs on the side of locking down. Easier to add a missing anon policy in a follow-up than to debug a quietly-public table.

---

## Section 4 — Verification checklist (run after migrations apply)

Order = same as the CRIT order in KANBAN.

### CRIT-1 — leaked `CRON_SECRET`

```bash
# Old value should be rejected
curl -i -X POST "https://terminal-2-production.up.railway.app/api/admin/collect-orders" \
  -H "X-Cron-Secret: thisisevochronsecret123!"
# Expect: 401 Unauthorized

# New value should be accepted (cron runs as expected)
psql "$SUPABASE_DB_URL" -c "SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;"
# Expect: status='succeeded' for the EVO orders job
```

### CRIT-2 — `coworker_readonly` password

```bash
# Old placeholder must be rejected
PGPASSWORD='CHANGE_ME_BEFORE_HANDOFF' psql -h db.<project>.supabase.co -U coworker_readonly -d postgres -c 'SELECT 1'
# Expect: FATAL: password authentication failed

# Pre-rotation: LOGIN is denied entirely
PGPASSWORD='anything' psql -h db.<project>.supabase.co -U coworker_readonly -d postgres -c 'SELECT 1'
# Expect: FATAL: role "coworker_readonly" is not permitted to log in

# Post-rotation (you ran §1.4): new password works
PGPASSWORD="$NEW_PWD" psql -h db.<project>.supabase.co -U coworker_readonly -d postgres -c 'SELECT 1'
# Expect: returns 1
```

### CRIT-3 — `/api/store/share*` auth

```bash
# Unauth call must be rejected
curl -i -X POST "$BASE/api/store/share" -d '{"event_id":1}' -H 'Content-Type: application/json'
# Expect: 401 missing bearer token

curl -i -X DELETE "$BASE/api/store/share/abc123"
# Expect: 401 missing bearer token

curl -i "$BASE/api/store/shares"
# Expect: 401 missing bearer token

# With valid Bearer JWT — should succeed (or 404 for missing share)
curl -i -X DELETE "$BASE/api/store/share/abc123" -H "Authorization: Bearer $JWT"
# Expect: 404 share link not found (not 401)
```

### CRIT-4 — fail-closed cron auth

```bash
# Edge fn with no x-cron-secret header
curl -i -X POST "https://<project>.functions.supabase.co/collect"
# Expect: 401 unauthorized (was: ran successfully if env unset)

# Edge fn with wrong header
curl -i -X POST "https://<project>.functions.supabase.co/collect" -H "X-Cron-Secret: wrong"
# Expect: 401 unauthorized
```

### CRIT-5 — DOM-XSS in `store.js`

Hardest to verify automatically. Manual check:

1. Open `https://<host>/store/event/12345?zones=<img src=x onerror=alert(1)>` in a browser.
2. Confirm no alert pops AND the chip renders the literal text `<img src=x onerror=alert(1)>`.
3. Check DevTools → Sources → look for any remaining `.innerHTML =` with template literals in `store.js` (should be only the empty-string clear cases).

### HIGHs/MEDs

- Supabase Studio → Authentication → Logs: confirm `chat` rate-limit failures now return 429 not 200.
- `SELECT relname, relrowsecurity FROM pg_class JOIN pg_namespace n ON n.oid=relnamespace WHERE n.nspname='public' AND relkind='r' AND NOT relrowsecurity;` — should be a small/known set (domain tables you've explicitly chosen to leave open).
- `SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prosecdef AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) c WHERE c LIKE 'search_path=%');` — should return zero rows.

---

## Section 5 — Escalation

If applying any migration fails:

| Failure | Action |
|---|---|
| `20260511000000` errors | Role doesn't exist — safe to skip; the migration is wrapped in `IF EXISTS`. |
| `20260511000100` errors | A function signature changed — re-grep with the sweep block and ALTER explicitly. |
| `20260511000200` raises `EDGE_FN_ANON_JWT not in vault` | You forgot §1.2. Seed and re-apply. |
| `20260511000200` raises `CRON_SECRET not in vault` | You forgot §1.1.c. Seed and re-apply. |
| `20260511000300` errors | A pattern matched a table the app actively writes to from anon — REVOKE the LOGIN-side write and restore via service_role only. Open an issue against this branch. |
| `20260511000400` (when manually applied) errors or breaks the app | Apply REVERT: `ALTER TABLE x DISABLE ROW LEVEL SECURITY;` per affected table, then iterate on the policy in a follow-up. The migration is marked DRAFT and held in `docs/proposed-migrations/` for this reason — copy into `supabase/migrations/` only after §C verification. |

If anything's unclear or the prod state differs from what this runbook assumes, **stop and ping A1 in a PR comment** before forcing through.
