# Security Audit 2026-05-16 — Code Review (B1)

Operator directive: "audit code for security." First broad B1 code audit since the testing-unified architecture landed (PR #168/#169). Scope: `app.py`, `d2_dashboard/main.py`, all `supabase/functions/*`, recent migrations (since 2026-05-15), `static/store/*`, `static/terminal/*`.

## TL;DR

- **1 SEC-CRIT**: `match-sg-performers-to-tevo` edge function — anon-JWT-suffices auth + caller-controlled limit + paid TEvo API call = cost-exploitation vector
- **1 SEC-HIGH**: `why-noaa-weather-alerts` edge function — anon-JWT-suffices auth + unbounded INSERT into `why_signals` = DB integrity / DoS
- **3 SEC-MED**: `espn` edge function wildcard CORS; D2 `AUTH_DISABLED` env-toggle drift risk; CSP `style-src 'unsafe-inline'`
- **2 SEC-LOW**: test files lack CSP; one test-page `innerHTML` pattern
- **Positive**: PR #57 XSS fix intact; CRON_SECRET correct; all `/api/store|broker|admin/*` gated; no SQL injection / RCE / open redirect / secret logging found in scope.

3 new B1-NEXT items filed (32, 33, 34). The 5 SEC-MED/LOW items are tracked but not urgent.

---

## Section 1 — SEC-CRIT: `match-sg-performers-to-tevo` cost-exploitation

**File**: [`supabase/functions/match-sg-performers-to-tevo/index.ts`](../supabase/functions/match-sg-performers-to-tevo/index.ts:126)

**Finding**: The `Deno.serve` handler (line 126) immediately fetches TEvo credentials and calls `/v9/performers/search` based on caller-supplied `limit` (1–200) without any auth gate beyond Supabase platform `verify_jwt=true` default.

**Why "anon JWT" is effectively unauthenticated**: Supabase platform-level `verify_jwt=true` accepts ANY valid Supabase JWT. The project's anon JWT is publishable by design (browser clients need it) and is exposed via `/api/public/config` (`app.py:475`). Any internet caller can fetch the anon key and use it as a Bearer token to invoke this edge function.

**Exploit**:
```
curl -X GET 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/match-sg-performers-to-tevo?limit=200' \
  -H 'Authorization: Bearer <anon-jwt-from-/api/public/config>'
```
→ 200 paid TEvo `/v9/performers/search` calls per invocation. Repeated calls drain TEvo credits.

**Mitigation**: add `requireCronSecret(req)` from [`supabase/functions/_shared/cron-auth.ts`](../supabase/functions/_shared/cron-auth.ts) as the second line of the handler (mirror the 12 other edge functions that already do this).

**B1-NEXT-32** filed.

---

## Section 2 — SEC-HIGH: `why-noaa-weather-alerts` unbounded DB inserts

**File**: [`supabase/functions/why-noaa-weather-alerts/index.ts`](../supabase/functions/why-noaa-weather-alerts/index.ts:30)

**Finding**: `Deno.serve` handler accepts POST requests with no auth gate beyond platform `verify_jwt=true` (same anon-JWT-suffices problem as Section 1). The handler iterates US states, fetches NOAA alerts (free public API, no credential leak), and INSERTs rows into `why_signals` table via service-role client.

**Exploit**: any internet caller with the anon JWT POSTs to the endpoint repeatedly. Each call writes potentially 100+ rows to `why_signals`. No idempotency gate visible in the handler scope read. DB bloat / cron interference.

**Blast radius**: limited to `why_signals` table (operational, not customer-facing). NOAA API is rate-limited but cheap; the cost vector is DB write amplification, not credential burn.

**Mitigation**: same — add `requireCronSecret(req)` body-level check.

**B1-NEXT-33** filed.

---

## Section 3 — SEC-MED: `espn` edge function wildcard CORS

**File**: [`supabase/functions/espn/index.ts:27`](../supabase/functions/espn/index.ts)

**Finding**: `"access-control-allow-origin": "*"` without an auth gate (relies on Supabase platform `verify_jwt=true` per default).

**Why not higher severity**: ESPN's public API is free (no credential leak); the function does not write to DB. The risk is purely defense-in-depth — the `chat` edge function uses a `CHAT_ALLOWED_ORIGINS` env-var allowlist (per `_shared/cron-auth.ts` hardening from PR #57), and the `espn` function should follow the same pattern for consistency.

**Mitigation**: replace wildcard with `process.env.ESPN_ALLOWED_ORIGINS` allowlist, default `["http://localhost:5173"]` for dev.

**B1-NEXT-34** filed.

---

## Section 4 — SEC-MED: D2 `AUTH_DISABLED` env-toggle drift risk

**File**: [`d2_dashboard/main.py`](../d2_dashboard/main.py)

**Finding**: D2's `require_auth` implementation has its own `AUTH_DISABLED` env-variable check, independent from `app.py`'s. Under the testing-unified architecture (PR #168), both auth implementations live in the SAME app process — but the kill-switches are independent. Risk:
- Operator sets `AUTH_DISABLED=true` on Render to debug app.py routes
- D2's check still gates `/api/d2/*` routes (different env-var read or different logic)
- OR: operator disables app.py's gate but D2's stays on → asymmetric behavior

**Why MED**: not exploitable today (both default to fail-closed in prod via the `RAILWAY_ENVIRONMENT` / `RENDER` detection). Risk is operator confusion in a debug scenario.

**Mitigation observations**:
- D2's `require_auth` has BETTER hardening than app.py's: validates `aud="authenticated"` (rejects service-role / anon tokens) and `email_confirmed_at` (rejects unconfirmed signups). app.py should adopt these checks for parity.
- OR: unify on a single shared `require_auth` dependency injected from `app.py` for the whole unified runtime (cleaner long-term).

Filed as observation only — not in KANBAN unless operator wants follow-up. Logged in this doc + bot_chat broadcast for cross-lane awareness.

---

## Section 5 — SEC-MED: CSP `style-src 'unsafe-inline'`

**Files**: [`static/store/index.html`](../static/store/index.html), [`static/store/event.html`](../static/store/event.html), [`static/store/shares.html`](../static/store/shares.html), `app.py` `_SecurityHeadersMiddleware`

**Finding**: production CSP has `style-src 'self' 'unsafe-inline'`. The agent that audited frontend flagged this; it's an accepted compromise for retail HTML but allows DOM-based style injection.

**Why MED not LOW**: `script-src` correctly does NOT have `'unsafe-inline'` (PR #57 fix held), so this gap doesn't enable XSS-class exploits. The risk is timing-based side channels or UI spoofing via injected styles — narrow surface.

**Mitigation**: move inline `<style>` blocks to external stylesheets, drop `'unsafe-inline'` from `style-src`. ~2h work; deferred.

Filed in `KANBAN.md` SECURITY BACKLOG under existing CSP cleanup item (no new B1-NEXT needed).

---

## Section 6 — SEC-LOW: test-page CSP + innerHTML

**Files**: `static/store/test/*.html`, [`static/store/test/share.html:197`](../static/store/test/share.html)

**Findings**:
- Test HTML files (`/static/store/test/*`) lack the `Content-Security-Policy` meta tag that production pages have. They're publicly accessible if the deploy serves them (`/store/test/share` etc.).
- `static/store/test/share.html:197` uses `status.innerHTML = statusPill(s);` where `statusPill()` returns hardcoded HTML templates (no data interpolation; safe in practice). Pattern is still suboptimal.

**Why LOW**: hardcoded templates → no RCE. Missing CSP on test pages → no XSS surface unless test code introduces a sink. Defense-in-depth fix.

**Mitigation**: option (a) — exclude `/static/store/test/*` from Render deploy entirely (operator decision); option (b) — add CSP meta + switch to `textContent`. Filed as low-priority hygiene; no new B1-NEXT.

---

## Section 7 — Verified positives (no fix needed)

These were checked and confirmed compliant:

| Surface | Pattern | Status |
|---|---|---|
| `app.py` CRON_SECRET enforcement | `hmac.compare_digest(x_cron_secret, CRON_SECRET)` with both-non-empty check | ✅ fail-closed + constant-time |
| `app.py` CORS | `_validate_cors_origins` rejects `*` at boot; allowlist from `CORS_ALLOWED_ORIGINS` env | ✅ secure |
| `app.py` security headers | CSP + X-Content-Type-Options + Referrer-Policy + X-Frame-Options + Permissions-Policy + HSTS | ✅ complete (modulo §5 finding) |
| All `/api/store/*` routes | Public-by-design (unbrokered catalog) | ✅ no wholesale fields leaked |
| All `/api/broker/*` routes | `Depends(require_auth)` consistent | ✅ gated |
| All `/api/admin/*` routes | `_require_cron_or_auth(authorization, x_cron_secret)` | ✅ gated |
| D2 `/api/d2/orders, /cron-freshness, /health, /metrics, /sales-feed` | `Depends(require_auth)` consistent | ✅ gated |
| `/api/d2/config-public` | Public-by-design (mirrors `/api/public/config`) | ✅ no secrets beyond anon JWT |
| Frontend XSS (PR #57 fix verification) | `escapeHtml()` + `textContent` paths in `static/store/store.js` | ✅ intact |
| Frontend secrets | No `xoxb-*`, `sk-*`, `Bearer ...` literals; only the intentional anon JWT via `/api/public/config` | ✅ clean |
| URL parameter handling | `encodeURIComponent` + `clampInt/clampFloat` validators | ✅ no open redirects |
| `localStorage` / `sessionStorage` | Not used | ✅ no persistent client secrets |
| SQL injection | All DB calls use Supabase SDK `.rpc()` / `.table().select().eq()` parameterization | ✅ no string-format SQL |
| `eval` / `exec` / `pickle` / `yaml.load` | Only innocuous `__import__("datetime")` for timestamp formatting | ✅ no unsafe deserialization |
| Edge functions auth (12 of 15) | `requireCronSecret` from `_shared/cron-auth.ts` | ✅ post-PR-#57 hardening held |
| Cron bodies | `cron_should_fire` gate + vault-read for `CRON_SECRET` | ✅ no hardcoded literals |
| `pg_net.http_get/post` calls | Credentials in Authorization headers, not URL query strings | ✅ no log-recoverable secrets |

---

## Section 8 — Audit scope NOT covered (deferred)

- Per-migration deep review for migrations >7 days old. Today's audit covered post-2026-05-15 (none new beyond PR #110's retrofit set).
- Render env-var inventory (names only — operator-side; B1 read-only on Render).
- GitHub Actions secrets (B1's existing `gh api .../actions/secrets` probe returns empty; presumed permission-filtered).
- Edge function deploy state vs `git` source-of-truth (would require running the `sync-check.yml` workflow result).
- Full RLS coverage audit on domain tables (`events`, `performers`, `venues`, `listings_snapshots`) — pre-existing SEC-HIGH item in KANBAN.

---

## Section 9 — B1-NEXT entries filed this audit

- **[B1-NEXT-32] SEC-CRIT** — Add `requireCronSecret` body-gate to `match-sg-performers-to-tevo` edge function. Cost-exploitation vector via paid TEvo API. Cross-lane to A1 (edge-fn owner). File PR comment + flag.
- **[B1-NEXT-33] SEC-HIGH** — Add `requireCronSecret` body-gate to `why-noaa-weather-alerts` edge function. Unbounded `why_signals` INSERTs. Cross-lane to A1.
- **[B1-NEXT-34] SEC-MED** — Replace wildcard CORS in `espn` edge function with `ESPN_ALLOWED_ORIGINS` env-var allowlist. Defense-in-depth, consistency with `chat`. Cross-lane to A1.

3 observation-only items NOT filed in KANBAN (covered in this doc):
- D2 vs app.py `AUTH_DISABLED` env-toggle drift risk (Section 4)
- CSP `style-src 'unsafe-inline'` (Section 5; existing CSP cleanup item)
- Test-page CSP gap + innerHTML pattern (Section 6)

---

## Section 10 — Recommendations beyond findings

Cross-cutting:

1. **Edge-function auth standard** — codify the "verify_jwt platform default is NOT sufficient for paid-API or DB-write edge functions" rule in `PROJECT_BIBLE.md §1` or `MIGRATION_CONVENTIONS.md`. Body-level `requireCronSecret` (or equivalent) is mandatory for any function that writes DB or hits paid upstream. The 3 findings above all violate this implicit rule; codifying makes the next audit clearer.
2. **Unify `require_auth` between `app.py` and `d2_dashboard/main.py`** — D2's hardening (aud + email_confirmed_at) is good and should be adopted in app.py. Or refactor to a single shared dependency under testing-unified architecture.
3. **PR-comment cross-lane protocol** — these 3 SEC findings should be filed as PR comments to A1 (per B1's standard cross-lane protocol from charter). Tracked in bot_chat broadcast.

---

**Owner**: B1 (Security Manager)
**Filed**: 2026-05-16
**PR**: pending (single PR adds this audit doc + 3 KANBAN entries + bot_chat broadcast)
