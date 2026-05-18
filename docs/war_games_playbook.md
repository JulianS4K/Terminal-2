# War Games Playbook — Terminal-2 Adversarial Simulation

**Owner**: B1 (Security Manager) · **Last full pass**: 2026-05-17 (rotation 2 — added W-3 + W-9; cumulative 5 of 10 scenarios run) · **Update cadence**: per-session sweep step 19 (rotating scenario); scheduled-task candidate `b1-war-games-rotation` ([B1-NEXT-35])

Operator directive 2026-05-16: "do war games against code when idle to simulate bot attack vectors." This playbook catalogues 10 attack scenarios that B1 simulates safely (read-only / sandbox-only) to detect vulnerabilities **before** an attacker finds them.

## Principles

1. **All probes are read-only or sandboxed.** No actual exploitation against prod. We try the attack with B1's standard read-only tooling and observe whether the response indicates a real opening.
2. **Two threat models** — external attacker (internet access + publishable anon JWT) AND internal bot (lane-bound but possibly misaligned/compromised).
3. **Catch before attacker** — when a scenario surfaces a real opening, file SEC-CRIT/HIGH and fix before publishing the playbook section publicly. The catalogue itself is public-OK; the LIVE-EXPLOIT findings are not.
4. **Rotation** — per-session sweep picks 1-2 scenarios; full rotation completes in ~5-10 sessions.

## Scenario catalogue

### External attacker scenarios (threat model: internet access + anon JWT)

| # | Scenario | Test method (read-only) | Detection signal | Current status |
|---|---|---|---|---|
| **W-1** | **Anon-JWT-suffices on edge functions** | List every `supabase/functions/*/index.ts`; for each, grep for `requireCronSecret` import. Functions WITHOUT it rely only on Supabase platform `verify_jwt=true`, which accepts the publishable anon JWT. Cross-check against `_shared/cron-auth.ts` consumers. | List of edge functions reachable with anon JWT alone. | **PARTIAL DEMO 2026-05-16**: 3 found (match-sg-performers-to-tevo, why-noaa-weather-alerts, espn). Filed [B1-NEXT-32/33/34]. |
| **W-2** | **Anon-callable SECDEF privilege escalation** | `pg_proc` query for `prosecdef=true AND has_function_privilege('anon', ..., 'EXECUTE')=true AND has_guard=false AND has_body_gate=false`. Each match = anon caller bypasses RLS via SECDEF privileges. | Function names + cost of misuse (DB writes, paid API calls, etc.) | Continuous via per-session sweep step 5 — current set in [B1-NEXT-1..11, 29..31, 32]. |
| **W-3** | **Wholesale-field exfiltration via /api/store/* responses** | Spot-check 5 `/api/store/*` response payloads (sample via curl with the anon JWT). Grep for `wholesale_price`, `wholesale_min`, `brokerage_id`, `office_id`, `is_owned`, `is_ancillary`, TEvo signing tokens. | Any forbidden field appearing in retail-API response = wall breach per LANE_DISCIPLINE.md §D1. | **RUN 2026-05-17**: 1 informational finding. `/api/store/search` exposes `we_own` + `owned_tix` (semantically equivalent to forbidden `is_owned`). `/api/store/events` exposes the schema but values are null (TEvo-direct route). `/api/store/movers`, `/api/store/near` clean. May be intentional storefront-product behavior (broker storefront sells own inventory). Filed [B1-NEXT-39] / bot_chat 308 for D0/D1 product-intent clarification. |
| **W-4** | **Public-RPC payload leakage** | For every SECDEF anon-callable RPC (`get_*_public`, `release_health_check`, etc.): call it with anon JWT, inspect response, look for fields that shouldn't be in a public payload (PII, secrets, internal IDs that map to broker positions). | Forbidden field in public-RPC payload. | NOT YET RUN. |
| **W-5** | **Cost amplification via unbounded paid-API endpoints** | Find every edge function or `/api/*` route that calls an upstream paid API (TEvo, SeatGeek, etc.). Verify each has a per-caller rate limit OR a bounded budget OR is auth-gated. Caller-controlled `limit` / `page_count` parameters are a red flag. | List of cost-exposed endpoints. | **PARTIAL DEMO 2026-05-16**: 1 found (match-sg-performers-to-tevo — `limit=1-200`). Filed [B1-NEXT-32]. W-5 sweep extends to all paid-API callers. |
| **W-6** | **Secret recovery from git history** | Re-run `gitleaks` with `--no-redact` on `HEAD..HEAD~50`. Cross-reference against `.gitleaksignore`. Any new finding = leak. Existing finding = rotated-but-historical (operator decides if filter-repo warranted given the repo is public). | New gitleaks finding. | Continuous via `.github/workflows/secret-scan.yml` weekly run. War-game adds session-level recheck. |

### Internal bot attacker scenarios (threat model: lane-bound but misaligned/hallucinating)

| # | Scenario | Test method (read-only) | Detection signal | Current status |
|---|---|---|---|---|
| **W-7** | **Bot impersonation via spoofed `bot_chat.bot_lane`** | Spot-check last 50 `bot_chat` entries: does `bot_lane` match the git log committer of any `related_pr`? Does the message tone / phrasing match the claimed lane's known voice? (B1 voice is terse + audit-doc-style; D1 voice is storefront-flavored; etc.) | Mismatch: e.g., a row claiming `bot_lane='A1'` whose `related_pr` was authored by a `claude/d1-*` branch. | NOT YET RUN. |
| **W-8** | **Hallucination cascade detection** | Pick 5 most recent `bot_chat` entries that cite specific concrete claims (PR numbers, function names, table names, migration timestamps, commit SHAs). Verify each citation via `gh pr view` / `pg_proc` / `pg_tables` / `git cat-file`. Per B1's hallucination cross-check protocol. | Any citation that fails verification = hallucination that could propagate. | **DEMO 2026-05-16**: B1's own CLAUDE.md §1 view-def drift catch (PR #140 post-merge audit, bot_chat 233) was a self-hallucination caught by this protocol. Run pattern continuously. |
| **W-9** | **Lane-discipline violation in PR file lists** | For each open or recently-merged PR: get the `headRefName` and infer the authoring lane (e.g., `claude/d1-*` → D1; `a1/*` → A1). Cross-reference PR's changed files against `LANE_DISCIPLINE.md §<lane>` write-surface. Files outside the declared write surface = lane violation. | Any file changed outside the authoring lane's permitted write surface. | **RUN 2026-05-17** on PRs #196-#207: 0 violations. Meta-observation: D0 routinely authors migrations (#196, #199, #200, #202, #203, #205) for terminal-page RPCs. Allowed per CLAUDE.md §1 ("Author migrations as files in `supabase/migrations/` — application to prod is gated separately"), but LANE_DISCIPLINE.md doesn't explicitly describe this pattern — minor doc drift, not a security finding. PR #202's `app.py` diff is on `broker_movers()` (terminal-side, D0 lane post-reorg). |
| **W-10** | **Authority escalation via `bot_chat_resolve()` abuse** | Query `bot_chat` for `event_type='status'` or rows with `resolved_by` set. Verify the resolving lane has appropriate authority for the parent's domain (e.g., B1 can resolve `p0_security` / `flag`; A1 can resolve `change_log`; D-tier should NOT be resolving cross-lane flags). | A D-tier lane resolving an A1- or B1-addressed flag without comment. | NOT YET RUN. |

## Probe templates

### W-1 / W-5 probe (edge function auth + cost)

```bash
# List all edge functions
ls supabase/functions/ | grep -v _shared

# For each, check requireCronSecret presence
for fn in supabase/functions/*/index.ts; do
  echo "=== $fn ==="
  grep -c "requireCronSecret\|verify_jwt" "$fn"
done

# Cross-reference functions with paid-API fetches
grep -rln "ticketevolution\.com\|api\.seatgeek\.com\|anthropic\.com\|api\.stripe\.com" supabase/functions/
```

### W-2 probe (SECDEF anon-callable)

```sql
-- Already integrated into per-session sweep step 5.
-- Run during war-games for full enumeration:
SELECT n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS fn,
       (pg_get_functiondef(p.oid) ~ 'current_user NOT IN') AS has_guard,
       (pg_get_functiondef(p.oid) ~ 'auth\.jwt|p_shared_secret|APPSCRIPT_INGEST_SECRET') AS has_body_gate
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.prosecdef
   AND has_function_privilege('anon', p.oid::regprocedure::text, 'EXECUTE')
 ORDER BY has_guard, has_body_gate, p.proname;
```

### W-3 probe (wall-rule egress check)

```bash
# Sample 5 /api/store responses with the anon JWT
ANON_JWT="<from /api/public/config>"
for endpoint in events search movers home near; do
  echo "=== /api/store/$endpoint ==="
  curl -s "https://vibepass-storefront-test.onrender.com/api/store/$endpoint" \
    -H "Authorization: Bearer $ANON_JWT" | \
    grep -iE "wholesale|brokerage_id|office_id|is_owned|is_ancillary|tevo_token|api_secret" || echo "(clean)"
done
```

### W-7 probe (impersonation cross-check)

```sql
-- Find bot_chat rows whose related_pr headRefName doesn't match the claimed bot_lane prefix
SELECT bc.id, bc.bot_lane, bc.related_pr
  FROM public.bot_chat bc
 WHERE bc.related_pr IS NOT NULL
   AND bc.created_at > now() - interval '7 days'
 ORDER BY bc.created_at DESC LIMIT 50;
```
Then cross-check each `related_pr` via `gh pr view <N> --json headRefName` and verify the branch prefix matches `bot_lane`.

### W-8 probe (hallucination spot-check) — per charter protocol

| Claim type | Verification |
|---|---|
| File path | `Glob` or `ls` |
| Function name | `SELECT FROM pg_proc WHERE proname='...'` |
| Migration timestamp | `ls supabase/migrations/<ts>*` |
| PR number | `gh pr view <N>` |
| `bot_chat` row ID | `SELECT id FROM public.bot_chat WHERE id=<N>` |
| Commit SHA | `git cat-file -e <sha>^{commit}` |

### W-9 probe (lane-discipline check)

```bash
# For a target PR, get changed files
gh pr view <N> --json files,headRefName --jq '.files[].path'

# Cross-reference against LANE_DISCIPLINE.md §<inferred-lane>
# Manual review at first; could be scripted with a per-lane write-surface dictionary
```

## Reporting protocol

- **Clean scenario run** → no bot_chat post; counts toward rotation coverage.
- **Real opening found** (SEC-CRIT/HIGH) → immediate `flag` or `p0_security` in `bot_chat` + KANBAN B1-NEXT entry + cross-lane PR comment per standard B1 protocol.
- **Suggestive-but-not-exploitable signal** (SEC-MED/LOW) → KANBAN entry, no urgent bot_chat post.

## Rotation

The 10 scenarios rotate across per-session sweeps (step 19). Quarterly: full 10/10 pass. The scheduled-task version (`b1-war-games-rotation`, [B1-NEXT-35]) would automate the cadence.

## Scenarios NOT in scope (deferred)

- **Supply-chain attacks** (npm / pip / Action dependency confusion) — handled by Dependabot once enabled ([B1-NEXT-12]).
- **Render workspace tampering** — D1 / D2 / A1 service-owner responsibility; B1 monitors via `docs/render_security_posture.md` diffs.
- **Operator-side attacks** (compromised laptop, leaked GitHub PAT) — out of B1's lane.
- **Physical / social engineering** — out of scope.

## First run findings (2026-05-16)

| Scenario | Run? | Outcome |
|---|---|---|
| W-1 | ✅ via parent code audit | 3 unauth edge functions found (match-sg-performers-to-tevo / why-noaa-weather-alerts / espn). Filed B1-NEXT-32/33/34. **CLOSED by A1 PR #174 (merged 2026-05-16 21:48 UTC)** — `requireCronSecret` retrofitted; the platform-verify_jwt rule codified as PROJECT_BIBLE.md §1 hard rule #7. |
| W-2 | ✅ continuous via sweep step 5 | 14 SECDEF without guard (11 retrofit candidates + 3 new from drift sync). Filed B1-NEXT-1..11, 29..31. |
| W-3 | not yet run | Wall-rule egress check on /api/store/*. Next session. |
| W-4 | not yet run | Public-RPC payload leakage scan. Next session. |
| W-5 | ✅ via W-1 | 1 cost-exposed endpoint (match-sg-performers-to-tevo). Filed + closed alongside W-1. |
| W-6 | continuous via gitleaks workflow | Weekly main scan + per-PR. No new findings since 2026-05-15. |
| W-7 | ✅ run 2026-05-16 | 25 most-recent bot_chat with `related_pr` cross-checked against branch prefixes — **all consistent**. No impersonation detected. |
| W-8 | ✅ via charter protocol | B1's own CLAUDE.md §1 view-def hallucination caught (bot_chat 233). |
| W-9 | ✅ run 2026-05-16 | Last 10 merged PRs lane-discipline checked — **all consistent** (D1 in `static/store/*`, D0 in `static/terminal/*`, A1 in governance/edge-fn/cross-cutting, shared `app.py` between A1+D1, B1 in own inventories). Discovered PR #174 in progress closing W-1 findings — surfacing via this scenario is a nice cross-effect. |
| W-10 | not yet run | Authority-escalation audit on `bot_chat_resolve()` callers. Next session. |

### Net first-run health

- **0 new SEC findings beyond what the parent code audit already flagged.**
- **3 SEC findings from W-1/W-5 already FIXED in the same session** by A1 PR #174 — operationally ideal cycle (B1 detect → A1 fix → B1 verify, all within ~3 hours).
- W-7/W-9 cleanly showed the existing lane-discipline + bot-impersonation defenses are working.
- 5 of 10 scenarios deferred to next sessions for rotation.

## Filed [B1-NEXT-35]

Operator decision: create scheduled task `b1-war-games-rotation` that rotates 1-2 scenarios per fire. Cadence proposal: every 4h (avoids bot_chat-aging-sweep noise; gives rotation full coverage daily). Posts to `#terminal-2-admin` (B1's lane-primary per bot_chat 207) on findings; silent on clean runs.

---

**Owner**: B1 · **Filed**: 2026-05-16 · **Reference**: `docs/security-audit-2026-05-16-code-review.md` (parent audit that originated W-1/W-5 demo)
