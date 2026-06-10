---
description: Run the full RULE 2 read-only-lockdown audit (static scanner + runtime guard tests) and report pass/fail with specifics.
---

Run the repo's RULE 2 enforcement stack from the project root and report the result.

## Process

1. `python scripts/check_readonly.py` — static scan. Must print `RULE 2 clean` and exit 0.
2. `python -m pytest tests/test_readonly_guards.py -q` — runtime guard tests (all 9 clients raise on non-GET; SeatData POST is path-scoped to `/v0.4/events/event-request-add`; synthetic-violation tests prove the scanner catches each evasion class). If pytest or a dependency is missing, `pip install -r requirements.txt pytest` first.
3. Spot-check guard tokens: every `*_client.py` at repo root must contain `_assert_readonly_method` and `ALLOWED_HTTP_METHODS` (grep both).

## Report

State PASS or FAIL first. On FAIL, quote the exact violation lines (file:line) and name which layer caught it (static scanner vs runtime guard tests). On PASS, give the one-line counts the scanner prints (files scanned per language, migrations, clients guarded).

## Red flags

- NEVER "fix" a failure by weakening, deleting, or routing around a guard, widening `ALLOWED_HTTP_METHODS`, or editing `FORBIDDEN_HOSTS` — that is a security-CRIT change requiring explicit operator authorization (CLAUDE.md §2).
- A passing scanner with failing guard tests (or vice versa) is still a FAIL — both layers are mandatory.

## Verification

Before reporting PASS, confirm both commands actually ran and exited 0 in this session — never report from memory of a previous run.
