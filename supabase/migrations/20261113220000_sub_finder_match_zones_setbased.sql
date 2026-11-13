-- Migration 20261113220000 · level:secondary-sales · lane:D0 · writes:sub_finder_match · reads:performer_zones,performer_zone_rules · pre:20261113130000
--
-- SUB FINDER: the match works out listing zones in one pass instead of one call per listing row.
--
-- Found 2026-11-13 running 28 PED lookups: GET /api/v1/subs/jobs/{id} and /orders/{n} answered
-- 500 after ~9 seconds and the job never left "pulling". sub_finder_match called
-- n2s_zone_of(performer, venue, section, row) once for every distinct (section, row) listed at
-- an event of an order without a strict cover: 14,977 calls for those 24 events at ~12 ms each
-- (the function is a nested SQL function that cannot be inlined), about three minutes, against
-- the API role's statement timeout. Small single-event lookups stayed under it, which is why
-- this did not show before.
--
-- The `lz` step now reads the zone rules of the events concerned once, normalises each rule and
-- each distinct listing section once, and joins. Same rule as n2s_zone_of, line for line:
--   section  exact (normalised) · numeric range · same letter prefix with a numeric suffix range
--   row      rule has no rows · one exact row (case-insensitive) · numeric range
--   zone     the single curated, non-FIFA zone that matches; none or several -> NULL
-- Checked read-only on prod before applying: 14,977 rows in 1.3 s, and 1,500 of them compared
-- against n2s_zone_of with 0 differences. n2s_zone_of itself is not touched (D7 uses it), and
-- the order's own zone (`oz`, one call per order) still goes through it.
-- One deliberate difference: a numeric section / row is read as a number only up to 9 digits,
-- where n2s_zone_of would raise an integer overflow.
--
-- The patch anchors on the SELECT inside `lz` (prod's copy of the function has no comments,
-- the repo's has one above it), and nests the new steps inside `lz` as its own WITH.
-- sub_finder_match is patched in place; the patch fails loudly if the block it replaces is not
-- there exactly once, and does nothing on a second run.
--
-- rollback: re-apply sub_finder_match from 20261113130000.

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.sub_finder_match(uuid, boolean)'::regprocedure);
  v_old text := $o$    SELECT d.eid, d.section, d.seat_row, public.n2s_zone_of(e.primary_performer_id, e.venue_id, d.section, d.seat_row) AS z
    FROM (SELECT DISTINCT l.eid, l.section, l.seat_row FROM _sf_l l
          WHERE l.eid IN (SELECT tevo_event_id FROM need)) d
    JOIN public.events e ON e.id = d.eid
  $o$;
  v_new text := $n$    WITH zev AS (
    -- zones of every listed (section, row) at the events concerned, set-based (20261113220000):
    -- the same rule as n2s_zone_of, without one function call per listing row
    SELECT e.id AS eid, e.primary_performer_id AS perf, e.venue_id AS ven
    FROM public.events e WHERE e.id IN (SELECT tevo_event_id FROM need)
  ), zrule AS (
    SELECT v.eid, z.name, r.row_from, r.row_to,
           public._sec_norm(r.section_from) AS nf, public._sec_norm(r.section_to) AS nt,
           CASE WHEN r.section_from ~ '^[0-9]{1,9}$' AND r.section_to ~ '^[0-9]{1,9}$' THEN r.section_from::int END AS i_from,
           CASE WHEN r.section_from ~ '^[0-9]{1,9}$' AND r.section_to ~ '^[0-9]{1,9}$' THEN r.section_to::int END AS i_to,
           public._sec_prefix(r.section_from) AS pf, public._sec_prefix(r.section_to) AS pt,
           public._sec_suffix(r.section_from) AS sf, public._sec_suffix(r.section_to) AS st,
           CASE WHEN r.row_from ~ '^[0-9]{1,9}$' AND r.row_to ~ '^[0-9]{1,9}$' THEN r.row_from::int END AS r_from,
           CASE WHEN r.row_from ~ '^[0-9]{1,9}$' AND r.row_to ~ '^[0-9]{1,9}$' THEN r.row_to::int END AS r_to
    FROM zev v
    JOIN public.performer_zones z ON z.performer_id = v.perf AND z.venue_id = v.ven
                                 AND z.source = 'curated' AND z.name NOT ILIKE '%fifa%'
    JOIN public.performer_zone_rules r ON r.zone_id = z.id
  ), zdist AS (
    SELECT DISTINCT l.eid, l.section, l.seat_row FROM _sf_l l WHERE l.eid IN (SELECT eid FROM zev)
  ), zsec AS (
    SELECT s.eid, s.section, public._sec_norm(s.section) AS ns,
           CASE WHEN s.section ~ '^[0-9]{1,9}$' THEN s.section::int END AS i_s,
           public._sec_prefix(s.section) AS ps, public._sec_suffix(s.section) AS ss
    FROM (SELECT DISTINCT eid, section FROM zdist) s
  ), zmatch AS (
    SELECT s.eid, s.section, r.name, r.row_from, r.row_to, r.r_from, r.r_to
    FROM zsec s JOIN zrule r ON r.eid = s.eid
     AND ( (r.nf = r.nt AND s.ns = r.nf)
        OR (r.i_from IS NOT NULL AND s.i_s IS NOT NULL AND s.i_s BETWEEN r.i_from AND r.i_to)
        OR (r.pf <> '' AND r.pf = r.pt AND r.pf = s.ps
            AND r.sf IS NOT NULL AND r.st IS NOT NULL AND s.ss IS NOT NULL AND s.ss BETWEEN r.sf AND r.st) )
  )
    SELECT d.eid, d.section, d.seat_row,
           CASE WHEN count(DISTINCT m.name) = 1 THEN min(m.name) END AS z
    FROM zdist d
    LEFT JOIN zmatch m ON m.eid = d.eid AND m.section = d.section
     AND ( (m.row_from IS NULL AND m.row_to IS NULL)
        OR (lower(coalesce(m.row_from, '')) = lower(coalesce(m.row_to, ''))
            AND lower(coalesce(d.seat_row, '')) = lower(coalesce(m.row_from, '')))
        OR (m.r_from IS NOT NULL
            AND (CASE WHEN d.seat_row ~ '^[0-9]{1,9}$' THEN d.seat_row::int END) BETWEEN m.r_from AND m.r_to) )
    GROUP BY d.eid, d.section, d.seat_row
  $n$;
BEGIN
  IF position('zmatch' IN v_def) > 0 THEN RETURN; END IF;                      -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_match: the lz block to replace was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;

-- The scratch table the match reads (_sf_l, a temp table filled per call) had no statistics, so
-- the planner treated thousands of listings as a handful and chose nested loops for the
-- zone joins. Analyse it once it is loaded.
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.sub_finder_load_native(uuid, interval)'::regprocedure);
  v_old text := $o$  GET DIAGNOSTICS v_n = ROW_COUNT;
$o$;
  v_new text := $n$  GET DIAGNOSTICS v_n = ROW_COUNT;
  ANALYZE _sf_l;                                   -- no statistics on a fresh temp table (20261113220000)
$n$;
BEGIN
  IF position('ANALYZE _sf_l' IN v_def) > 0 THEN RETURN; END IF;               -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_load_native: the line to patch was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;

-- The TicketsData step refills _sf_l inside sub_finder_settle and matches again, so the match
-- analyses the table itself too: whatever filled it, it is planned with real row counts.
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.sub_finder_match(uuid, boolean)'::regprocedure);
  v_old text := $o$BEGIN
  WITH o AS ($o$;
  v_new text := $n$BEGIN
  ANALYZE _sf_l;                                   -- a fresh temp table has no statistics (20261113220000)
  WITH o AS ($n$;
BEGIN
  IF position('ANALYZE _sf_l' IN v_def) > 0 THEN RETURN; END IF;               -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_match: the line to patch was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;
