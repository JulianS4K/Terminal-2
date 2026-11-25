-- Migration 20261125174500 · level:data-collection · lane:A1 (data plane: the AXS watch) · writes:axs_watch_config(+stop_before_start, if absent) · reads:none · pre:20261125150000
--
-- RECORD: mig 20261125150000 REACHED PROD HERE, NOT WHEN IT MERGED.
--
-- 20261125150000 (stop_before_start) was merged in PR #1209 and deliberately NOT applied, because the database
-- was dropping connections that afternoon. 20261125173500 (the 180-day horizon) was then applied while
-- declaring 20261125150000 as its pre-requisite, so the fill deployed to prod referenced
-- axs_watch_config.stop_before_start, a column that did not exist there. Every axs_watch_fill call raised
--     ERROR: record "v_cfg" has no field "stop_before_start"
-- from 17:35Z until this was applied at 17:45Z. Nothing ran in that window — axs_watch_fill_daily fires at
-- 03:20Z — so no fill was lost; the next one would have failed. Found by the dry run taken straight after the
-- horizon apply, which is why the window was ten minutes and not ten hours.
--
-- THE LESSON, for the next session: a migration's `pre:` list is a claim about the REPO, not about prod. Check
-- the columns and functions a migration reads actually exist in prod before applying it, especially when an
-- earlier migration in the chain was intentionally held back. The harness cannot catch this — it builds from
-- zero in dependency order, so it is green either way.
--
-- Applied to prod 2026-11-25: the column at 17:45Z (name axs_watch_stop_before_start_column), then
-- axs_watch_next() from 20261125150000 at 17:47Z (name axs_watch_next_stop_before_start). Both halves of
-- 20261125150000 are now live and prod matches PR #1209. This file is idempotent and a no-op in a from-zero
-- build, where 20261125150000 runs in order and adds the column first.
--
-- rollback: none; see 20261125150000.

ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS stop_before_start interval NOT NULL DEFAULT interval '6 hours'
  CHECK (stop_before_start >= interval '0');
