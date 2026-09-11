-- Migration 20260910630000 · level:secondary-sales · lane:D7 · writes:n2s_cover_queue,n2s_profitable_cover,n2s_integration_doc,n2s_error_code · reads:gotickets_listings_snapshots,seatgeek_listings_snapshots · pre:20260910620000
--
-- Already applied to prod · via MCP 2026-09-10 under operator direction (this corrected
-- form, view anchor c.sub_zone). ⚠ The enrichment UPDATE injected below was hot-fixed
-- minutes later by 20260910640000 — it scanned the full snapshot history and wedged
-- cron 602. Apply 640000 immediately after this one on any fresh environment.
-- ============================================================================
-- Migration 20260910630000 — surface listing view quality (obstructed/limited)
--
-- Lane: D7 · Pre-reqs: 20260910510000, 20260910600000, 20260910620000
--
-- An obstructed-view substitute against a clear-view sold seat classifies as
-- GATE 1 "Index" today: same section, same-or-better row, cheaper, "actionable
-- directly". It is a genuine downgrade that needs the buyer's consent, and
-- nothing in the payload said so. Same failure shape as the tier-crossing
-- downgrade closed in 20260910620000, in a dimension the cascade never looked
-- at.
--
-- ── ⚠ WE ARE BLIND ON TEVO, WHICH IS MOST OF THE BOOK ──────────────────────
-- Of the four sub sources only two carry any view signal:
--   seatgeek  has_limited_view (boolean, SG's own `lv` flag) + seller_notes
--   gotickets notes (free text)
--   tevo      NOTHING — see below
--   ticketsdata NOTHING (and the vendor is off)
-- TEvo's API DOES return public_notes: core/helpers.py reads it, and
-- core/store_events.py:158 states outright "public_notes: None — not mirrored
-- to listings_snapshots". The column does not exist on listings_snapshots, so
-- for TEvo the answer is not "clear", it is "we never looked" — and TEvo was
-- 10 of the 11 rows on the feed when this was written.
--
-- That is why sub_view is a THREE-state field and not a boolean. Collapsing
-- "we checked and it is fine" together with "we have no data" is precisely the
-- error that would let an obstructed seat ship as clean. A boolean cannot
-- express the difference; NULL-as-false expresses it wrongly.
--
-- Capturing TEvo public_notes is an A1 change (listings_snapshots + the
-- collector are A1's data plane, PROJECT_BIBLE §2), so it is NOT made here.
-- Until it is, every TEvo row reads 'unknown' and the manual says why.
--
-- ── ⚠ WHY THIS SITS IN THE QUEUE AND NOT IN THE CASCADE ────────────────────
-- View quality is a property of the LISTING, not of how the listing matched
-- the obligation. Threading two more columns through n2s_cover_candidates
-- would mean ten anchored edits inside the 250-line function whose last four
-- revisions each cost a 60s-timeout debugging cycle, to compute something that
-- does not participate in the match at all. The queue is refreshed from the
-- same snapshot rows, keyed on (source, listing id, event, captured_at), so
-- the lookup is exact and the cascade is untouched.
--
-- It is also deliberately NOT folded into cover_label. The label answers "what
-- may I do with this match"; this answers "what is this seat". A consumer that
-- filters gates should not have to parse a label to find out the seat is
-- obstructed — it is its own column, and any gate can carry it.
-- ============================================================================

-- ── the classifier ─────────────────────────────────────────────────────────
-- The pattern is NOT new: it is the one already used by the scanner's
-- confidence rule (20260811273000 / 280000 et al). One fact, one home — if the
-- vocabulary is ever widened it must be widened here and there together.
CREATE OR REPLACE FUNCTION public.n2s_view_of(p_notes text, p_limited_view boolean)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
    -- an explicit vendor flag outranks free text in both directions
    WHEN p_limited_view IS TRUE THEN 'obstructed'
    WHEN p_notes ~* 'obstruct|limited|partial|restricted|obov|side view|behind|pole|no view'
      THEN 'obstructed'
    WHEN p_limited_view IS FALSE THEN 'clear'
    -- notes present and saying nothing about the view is weak evidence, but it
    -- IS evidence: the seller wrote a disclosure field and did not disclose.
    WHEN p_notes IS NOT NULL AND btrim(p_notes) <> '' THEN 'clear'
    ELSE 'unknown'
  END;
$function$;

COMMENT ON FUNCTION public.n2s_view_of(text, boolean) IS
  'Three-state view quality for a listing: obstructed / clear / unknown. NEVER collapse to a boolean — "unknown" means the source carries no view data at all (every TEvo row, because public_notes is not mirrored to listings_snapshots), and reading that as "clear" is how an obstructed seat ships as clean. Pattern is shared with the scanner confidence rule; widen both together.';

REVOKE ALL ON FUNCTION public.n2s_view_of(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.n2s_view_of(text, boolean) TO service_role, authenticated;

-- ── queue columns ──────────────────────────────────────────────────────────
ALTER TABLE public.n2s_cover_queue
  ADD COLUMN IF NOT EXISTS sub_notes text,
  ADD COLUMN IF NOT EXISTS sub_view  text;

COMMENT ON COLUMN public.n2s_cover_queue.sub_view IS
  'obstructed | clear | unknown. "unknown" is not "clear" — see n2s_view_of().';
COMMENT ON COLUMN public.n2s_cover_queue.sub_notes IS
  'Raw seller note the classification was drawn from, kept so a human can read the actual wording rather than trusting the regex.';

-- ── enrich inside the refresh, after the INSERT ────────────────────────────
-- Two statements rather than one clever join. The baseline pass is what makes
-- TEvo and TicketsData read 'unknown' instead of NULL: a NULL here would be
-- indistinguishable from "not refreshed yet" downstream, and would invite a
-- COALESCE(sub_view,'clear') somewhere later.
DO $do$
DECLARE d text; n text;
BEGIN
  d := pg_get_functiondef('public.n2s_cover_queue_refresh()'::regprocedure);

  n := 'GET DIAGNOSTICS v_n = ROW_COUNT;';
  IF position(n in d) = 0 THEN
    RAISE EXCEPTION 'anchor (GET DIAGNOSTICS after the queue INSERT) not found — refresh body changed, re-derive this migration';
  END IF;

  d := replace(d, n, n || E'\n' ||
    '  -- view quality: baseline every covered row to ''unknown'', then correct' || E'\n' ||
    '  -- the two sources that actually publish a signal. See n2s_view_of().' || E'\n' ||
    '  UPDATE public.n2s_cover_queue q SET sub_view = ''unknown''' || E'\n' ||
    '   WHERE q.sub_listing_id IS NOT NULL;' || E'\n' ||
    '' || E'\n' ||
    '  UPDATE public.n2s_cover_queue q' || E'\n' ||
    '     SET sub_notes = v.notes,' || E'\n' ||
    '         sub_view  = public.n2s_view_of(v.notes, v.lv)' || E'\n' ||
    '    FROM (' || E'\n' ||
    '      SELECT ''gotickets''::text AS src, g.gt_listing_id::text AS lid,' || E'\n' ||
    '             g.tevo_event_id AS eid, g.captured_at, g.notes, NULL::boolean AS lv' || E'\n' ||
    '        FROM public.gotickets_listings_snapshots g' || E'\n' ||
    '       WHERE g.tevo_event_id IN (SELECT DISTINCT tevo_event_id FROM public.n2s_cover_queue)' || E'\n' ||
    '      UNION ALL' || E'\n' ||
    '      SELECT ''seatgeek'', sg.sglid::text, sg.tevo_event_id, sg.captured_at,' || E'\n' ||
    '             sg.seller_notes, sg.has_limited_view' || E'\n' ||
    '        FROM public.seatgeek_listings_snapshots sg' || E'\n' ||
    '       WHERE sg.tevo_event_id IN (SELECT DISTINCT tevo_event_id FROM public.n2s_cover_queue)' || E'\n' ||
    '    ) v' || E'\n' ||
    '   WHERE v.src = q.sub_source' || E'\n' ||
    '     AND v.lid = q.sub_listing_id' || E'\n' ||
    '     AND v.eid = q.tevo_event_id' || E'\n' ||
    '     AND v.captured_at = q.captured_at;' || E'\n' ||
    '' || E'\n' ||
    '  -- and into the LABEL, so a consumer that only reads cover_label still' || E'\n' ||
    '  -- sees it. Safe to append unconditionally: the refresh DELETEs the whole' || E'\n' ||
    '  -- queue and rebuilds it every run, so the suffix cannot accumulate.' || E'\n' ||
    '  UPDATE public.n2s_cover_queue q' || E'\n' ||
    '     SET cover_label = q.cover_label || '' obstructed view''' || E'\n' ||
    '   WHERE q.sub_view = ''obstructed'' AND q.cover_label IS NOT NULL;' || E'\n');

  EXECUTE d;
END $do$;

-- ── expose on the view the panel and API read ──────────────────────────────
DO $do$
DECLARE v text; n text;
BEGIN
  v := pg_get_viewdef('public.v_n2s_orders'::regclass, true);

  -- ⚠ The queue is aliased `c` on this view (`LEFT JOIN n2s_cover_queue c`),
  -- and 20260910520000 appended the gate columns as `c.cover_gate … c.sub_zone`.
  -- The first cut of this migration anchored on `n.sub_zone` (n = n2s_items,
  -- which has no such column). A pre-flight check of the anchors against
  -- prod on 2026-09-10 showed this assertion would refuse it, so it was
  -- corrected BEFORE apply — the broken form was never run against prod.
  n := 'c.sub_zone';
  IF position(n in v) = 0 THEN
    RAISE EXCEPTION 'anchor (c.sub_zone on v_n2s_orders) not found — 20260910520000 appended it; re-derive this migration';
  END IF;
  -- CREATE OR REPLACE VIEW can only APPEND columns, which is what this is:
  -- two new names after the last one 20260910520000 added.
  v := replace(v, n, n || ',' || E'\n' || '    c.sub_notes,' || E'\n' || '    c.sub_view');

  EXECUTE 'CREATE OR REPLACE VIEW public.v_n2s_orders AS ' || v;
END $do$;

-- ── carry to the external feed ─────────────────────────────────────────────
ALTER TABLE public.n2s_profitable_cover
  ADD COLUMN IF NOT EXISTS sub_notes text,
  ADD COLUMN IF NOT EXISTS sub_view  text;

COMMENT ON COLUMN public.n2s_profitable_cover.sub_view IS
  'obstructed | clear | unknown. "unknown" means the source published no view data (all TEvo rows today) — it is NOT a statement that the seat is clear.';

DO $do$
DECLARE d text; n text;
BEGIN
  d := pg_get_functiondef('public.n2s_profitable_cover_sync()'::regprocedure);

  -- src list
  n := 'v.cover_gate, v.cover_label, v.order_zone, v.sub_zone';
  IF position(n in d) = 0 THEN
    RAISE EXCEPTION 'anchor 1 (src gate columns) not found — re-derive this migration';
  END IF;
  d := replace(d, n, n || ', v.sub_notes, v.sub_view');

  -- insert column list
  n := 'cover_gate, cover_label, order_zone, sub_zone)';
  IF position(n in d) = 0 THEN
    RAISE EXCEPTION 'anchor 2 (INSERT column list) not found — re-derive this migration';
  END IF;
  d := replace(d, n, 'cover_gate, cover_label, order_zone, sub_zone, sub_notes, sub_view)');

  -- select list feeding it
  n := '           cover_gate, cover_label, order_zone, sub_zone' || E'\n' || '      FROM src';
  IF position(n in d) = 0 THEN
    RAISE EXCEPTION 'anchor 3 (SELECT list before FROM src) not found — re-derive this migration';
  END IF;
  d := replace(d, n, '           cover_gate, cover_label, order_zone, sub_zone, sub_notes, sub_view'
                     || E'\n' || '      FROM src');

  -- conflict update
  n := 'order_zone = EXCLUDED.order_zone, sub_zone = EXCLUDED.sub_zone,';
  IF position(n in d) = 0 THEN
    RAISE EXCEPTION 'anchor 4 (ON CONFLICT gate columns) not found — re-derive this migration';
  END IF;
  d := replace(d, n, n || E'\n' ||
    '      sub_notes = EXCLUDED.sub_notes, sub_view = EXCLUDED.sub_view,');

  -- change detection: a listing that becomes obstructed MUST emit an event
  n := 'EXCLUDED.sub_zone)';
  IF position(n in d) = 0 THEN
    RAISE EXCEPTION 'anchor 5 (IS DISTINCT FROM tail) not found — re-derive this migration';
  END IF;
  d := replace(d, 't.cover_gate, t.cover_label, t.order_zone, t.sub_zone)',
                  't.cover_gate, t.cover_label, t.order_zone, t.sub_zone, t.sub_view)');
  d := replace(d, 'EXCLUDED.sub_zone)', 'EXCLUDED.sub_zone, EXCLUDED.sub_view)');

  EXECUTE d;
END $do$;

-- ── error codes ────────────────────────────────────────────────────────────
INSERT INTO public.n2s_error_code
  (code, category, severity, title, meaning, emitted_by, what_to_do, sort_order)
VALUES
 ('N2S-V100', 'view', 'warn', 'Substitute has an obstructed or limited view',
  $doc$sub_view = 'obstructed'. The source discloses a limited, obstructed, partial or restricted view for this listing — SeatGeek through its own limited-view flag, GoTickets through the seller's note. sub_notes carries the wording verbatim. This is INDEPENDENT of the gate: a gate 1 row, same section and same-or-better row, can still be obstructed.$doc$,
  'n2s_view_of() over seatgeek.has_limited_view / seller_notes and gotickets.notes',
  $doc$Offer it to the buyer before purchasing, whatever the gate says. Gate 1 means the geometry matches, not that the seat is equivalent. Read sub_notes and quote the seller's actual wording to the buyer rather than the word "obstructed" alone.$doc$,
  400),
 ('N2S-V200', 'view', 'info', 'View quality unknown for this substitute',
  $doc$sub_view = 'unknown'. The source publishes no view data at all, so the seat has NOT been checked. This is the majority of rows today: TEvo's API returns public_notes but we do not mirror it into listings_snapshots, so every TEvo substitute reads 'unknown'. TicketsData is the same and is currently off.$doc$,
  'n2s_view_of() where the source carries neither a flag nor notes',
  $doc$Do NOT read this as "clear" — it means nobody looked. If the buyer is sensitive to sightlines, check the listing on the source before offering. The fix is upstream: mirroring TEvo public_notes into listings_snapshots would turn most of these into a real answer.$doc$,
  410)
ON CONFLICT (code) DO UPDATE SET
  category = EXCLUDED.category, severity = EXCLUDED.severity,
  title = EXCLUDED.title, meaning = EXCLUDED.meaning,
  emitted_by = EXCLUDED.emitted_by, what_to_do = EXCLUDED.what_to_do,
  sort_order = EXCLUDED.sort_order;

-- ── manual: a step of its own, because it cuts across every gate ───────────
INSERT INTO public.n2s_integration_doc (step_no, slug, title, body)
VALUES (10, 'view-quality', 'Sightlines — read this alongside the label', $doc$Two columns describe the SEAT, independently of how it matched the obligation:

  sub_view   obstructed | clear | unknown
  sub_notes  the seller's own wording, verbatim, where there is any

*** THIS IS A SEPARATE AXIS FROM THE GATE. *** A gate 1 "Index" row is the same section and the same-or-better row, and it can still be an obstructed seat. The gate answers what may be done with the MATCH; sub_view answers what the SEAT is. A row that is gate 1 and obstructed is the most dangerous row in the feed, because the gate invites you to buy it directly. Offer any obstructed substitute to the buyer first, whatever the gate says (N2S-V100).

*** "unknown" IS NOT "clear". *** It means the source published no view data and the seat has not been checked. Today that is most of the book: our TEvo feed carries no seller notes at all, so every TEvo substitute reads 'unknown' (N2S-V200). SeatGeek publishes a limited-view flag and seller notes; GoTickets publishes seller notes. If you treat 'unknown' as an all-clear you will eventually hand a buyer an obstructed seat that we never claimed was fine.

*** READ sub_notes, NOT JUST sub_view. *** 'obstructed' is our classification of the seller's text against a fixed vocabulary (obstructed, limited, partial, restricted, obov, side view, behind, pole, no view). The text itself is more useful to a buyer than the label: "behind the stage-left speaker stack" and "slight side view" are both 'obstructed' here and are very different conversations.

There is no filtering on this field. Nothing is withheld for being obstructed — it is labelled and sent, and the decision is yours.$doc$)
ON CONFLICT (slug) DO UPDATE SET
  step_no = EXCLUDED.step_no, title = EXCLUDED.title, body = EXCLUDED.body;

-- keep the remaining steps in order: everything at or after the old step 10
-- shifts down by one to make room. Idempotent because the slug is the key and
-- the numbers are recomputed from the fixed order, not incremented in place.
WITH ordered AS (
  SELECT slug, row_number() OVER (ORDER BY
           CASE slug
             WHEN 'overview' THEN 1 WHEN 'endpoints' THEN 2 WHEN 'credentials' THEN 3
             WHEN 'set-password' THEN 4 WHEN 'read-current-state' THEN 5
             WHEN 'subscribe-realtime' THEN 6 WHEN 'interpret-events' THEN 7
             WHEN 'gates' THEN 8 WHEN 'zones' THEN 9 WHEN 'view-quality' THEN 10
             WHEN 'columns' THEN 11 WHEN 'error-codes' THEN 12
             WHEN 'troubleshooting' THEN 13 WHEN 'guarantees' THEN 14
           END) AS n
    FROM public.n2s_integration_doc)
UPDATE public.n2s_integration_doc d SET step_no = o.n
  FROM ordered o WHERE o.slug = d.slug AND d.step_no IS DISTINCT FROM o.n;

-- ── the label carries it too ───────────────────────────────────────────────
-- sub_view is the column a machine should branch on, but cover_label is what a
-- human reads and what a thin consumer may be displaying alone. A seat defect
-- that only exists in a column nobody rendered is not surfaced.
--
-- ⚠ Only 'obstructed' becomes a suffix. 'unknown' stays a column and nothing
-- more: it is the state of MOST rows today (every TEvo listing), and a suffix
-- carried by the majority stops carrying information — it would train readers
-- to skip the tail of every label, which is where " repost single" and
-- " zone unverified" live. The label is a workflow instruction, and 'unknown'
-- does not change the action; 'obstructed' does.
UPDATE public.n2s_integration_doc
   SET body = replace(
         replace(body, 'Two suffixes can be appended to any of those:',
                       'Three suffixes can be appended to any of those:'),
         'rule could not be checked. It does NOT mean a zone was crossed.',
         'rule could not be checked. It does NOT mean a zone was crossed.' || E'\n' ||
         '  ... obstructed view          the source discloses a limited / obstructed / partial view for' || E'\n' ||
         '                               this listing. INDEPENDENT of the gate — a gate 1 row can carry it.')
 WHERE slug = 'gates'
   AND body LIKE '%It does NOT mean a zone was crossed.%'
   AND body NOT LIKE '%obstructed view%';

UPDATE public.n2s_integration_doc
   SET body = replace(body,
        'There is no filtering on this field.',
        'The label carries it as well: any row with sub_view = ''obstructed'' has " obstructed view" appended to cover_label, so a consumer displaying only the label still sees the defect. ''unknown'' is deliberately NOT suffixed — it is the state of most rows, and a suffix on the majority stops carrying information. Branch on sub_view if you want to act on it.' || E'\n\n' ||
        'There is no filtering on this field.')
 WHERE slug = 'view-quality'
   AND body NOT LIKE '%appended to cover_label%';

UPDATE public.n2s_error_code
   SET what_to_do = $doc$Offer it to the buyer before purchasing, whatever the gate says. Gate 1 means the geometry matches, not that the seat is equivalent. The label also ends " obstructed view" so a label-only consumer still sees it. Read sub_notes and quote the seller's actual wording to the buyer rather than the word "obstructed" alone — "behind the stage-left speaker stack" and "slight side view" are both 'obstructed' here and are very different conversations.$doc$
 WHERE code = 'N2S-V100';
