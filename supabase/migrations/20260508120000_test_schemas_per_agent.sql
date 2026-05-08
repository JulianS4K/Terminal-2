-- 20260508120000_test_schemas_per_agent.sql
-- Code-owned (auditor).
--
-- Test schemas for the 3-agent era. User chose Option C (schema-level
-- isolation in current prod project) per 2026-05-08:
--   "C. Schema-level isolation in current prod — DB only (separate
--    copilot_test schema, etc.). free. SQL only, no infra. medium —
--    same edge fns + crons; agents could still touch public"
--
-- One schema per agent. Each agent does iterative work in their own schema.
-- When ready, they hand off via the proxy-commit protocol; code reviews and
-- promotes the work to `public` on prod.
--
-- Convention enforced by AGENTS.md + code's audit pass; Postgres doesn't
-- prevent any agent from touching `public` (per user's explicit choice).
-- Code's job as auditor is to catch violations.
--
-- No crons run in these schemas. No edge fn deploys point at them. They
-- exist purely as DB sandboxes.

CREATE SCHEMA IF NOT EXISTS code_staging;
CREATE SCHEMA IF NOT EXISTS copilot_test;
CREATE SCHEMA IF NOT EXISTS design_test;

GRANT USAGE, CREATE ON SCHEMA code_staging TO service_role;
GRANT USAGE, CREATE ON SCHEMA copilot_test TO service_role;
GRANT USAGE, CREATE ON SCHEMA design_test  TO service_role;

GRANT SELECT, INSERT, UPDATE, DELETE, TRIGGER, REFERENCES
  ON ALL TABLES    IN SCHEMA code_staging TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE, TRIGGER, REFERENCES
  ON ALL TABLES    IN SCHEMA copilot_test TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE, TRIGGER, REFERENCES
  ON ALL TABLES    IN SCHEMA design_test  TO service_role;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA code_staging TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA copilot_test TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA design_test  TO service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA code_staging
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA copilot_test
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA design_test
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA code_staging
  GRANT EXECUTE ON FUNCTIONS TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA copilot_test
  GRANT EXECUTE ON FUNCTIONS TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA design_test
  GRANT EXECUTE ON FUNCTIONS TO service_role;

CREATE TABLE code_staging._readme (id int PRIMARY KEY DEFAULT 1, content text);
INSERT INTO code_staging._readme VALUES (1,
$readme$
SCHEMA: code_staging
OWNER: code (auditor + terminal backend)
PURPOSE: Code's own sandbox for staging migrations + project simulations
         before promoting to public.

Workflow:
  1. Draft a migration here against copies of public.* tables.
  2. Run scenario simulations + audits against the staging copy.
  3. When verified, apply the same migration to public via the normal
     supabase/migrations/ path + MCP apply_migration.

Not polled by any cron. No edge fn writes here.
$readme$);

CREATE TABLE copilot_test._readme (id int PRIMARY KEY DEFAULT 1, content text);
INSERT INTO copilot_test._readme VALUES (1,
$readme$
SCHEMA: copilot_test
OWNER: copilot (retail chat backend + chatbot ML/NLU)
PURPOSE: Copilot's sandbox for chat-side schema changes before they go to public.

Workflow:
  1. Build / iterate in copilot_test.* freely.
  2. When ready, write a migration file targeting public.* with the final
     shape, drop it as `FROM copilot · timestamp` block in AGENTS.md LOG
     (see RULE 12: proxy-commit protocol).
  3. Code reviews, applies to public, deploys associated edge fn changes,
     pushes to git.

DO NOT write directly to public.*. Reads from public are fine; writes are
code-only per ACCESS MATRIX in AGENTS.md.
$readme$);

CREATE TABLE design_test._readme (id int PRIMARY KEY DEFAULT 1, content text);
INSERT INTO design_test._readme VALUES (1,
$readme$
SCHEMA: design_test
OWNER: claude design (front-end across both products)
PURPOSE: Mostly empty. Design rarely needs a DB sandbox — most work
         happens in static/*.html. This schema exists for the rare case
         where a UI prototype needs a fixture table or a stub RPC.

Workflow:
  - Create stub tables / mock data here for UI prototypes.
  - When the UI needs a real backend endpoint, drop a NEXT note in LOG:
      NEXT (claude design): need /api/<endpoint> returning {...}
    Code or copilot will pick it up.

DO NOT write directly to public.*. Same rule as copilot_test.
$readme$);

GRANT SELECT ON code_staging._readme TO service_role, anon, authenticated;
GRANT SELECT ON copilot_test._readme  TO service_role, anon, authenticated;
GRANT SELECT ON design_test._readme   TO service_role, anon, authenticated;

COMMENT ON SCHEMA code_staging IS 'Code agent sandbox (auditor + terminal backend). See _readme.';
COMMENT ON SCHEMA copilot_test IS 'Copilot agent sandbox (chat backend + ML/NLU). See _readme.';
COMMENT ON SCHEMA design_test  IS 'Claude-design agent sandbox (front-end). See _readme.';
