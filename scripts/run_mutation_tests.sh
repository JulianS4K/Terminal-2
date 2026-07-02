#!/usr/bin/env bash
# Mutation testing (testing-recommendation #6) — a ONE-SHOT diagnostic, not a
# CI gate. 100% line coverage on the shipped surface is real, but line coverage
# can be assertion-weak: a test can execute a line without pinning its behavior
# (AI-generated tests are especially prone to this). mutmut mutates the source
# (flip a comparison, swap a boundary, drop a call) and re-runs the tests; a
# SURVIVING mutant is a change no test caught — i.e. a test that's theater.
#
# Scoped to the two security-critical modules the review named: core/auth.py
# (allowed-domain gate, human-token HMAC) and core/ratelimit.py (the limiter
# whose runtime-failure path had the only red finding). Run it, then read the
# surviving mutants and strengthen the assertions they expose.
#
# Config lives in setup.cfg's [mutmut] section (source paths + the tight test
# runner). mutmut 3.x is config-driven, not flag-driven.
#
# Usage:
#   pip install mutmut
#   bash scripts/run_mutation_tests.sh          # run the mutation campaign
#   mutmut results                              # list survivors
#   mutmut show <id>                            # inspect one survivor's diff
#
# Deliberately NOT in CI: a full campaign is minutes-long and the output is for
# a human to act on, not a pass/fail wall. Re-run after touching either module.
set -euo pipefail
cd "$(dirname "$0")/.."

export PYTHONPATH=.
# Test creds so `import server` (pulled in transitively) doesn't sys.exit; the
# targeted tests never make a real call.
export AUTH_DISABLED=true
export SUPABASE_URL="https://example.invalid"
export SUPABASE_SERVICE_ROLE_KEY="test-key"
export TEVO_TOKEN="test-token"
export TEVO_SECRET="test-secret"

exec mutmut run
