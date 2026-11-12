-- Migration 20261112010000 · level:secondary-sales · lane:D7 · writes:n2s_view_of,n2s_evo_notes,n2s_cover_queue_refresh,n2s_gt_order_dryrun,n2s_gt_order_dryrun_capture,n2s_evo_order_dryrun_capture,n2s_autobuy_notify_tick · reads:n2s_evo_current,n2s_gt_current,n2s_sg_current,n2s_covers,n2s_autobuy_exec · pre:20261112000000
--
-- N2S: the seller's own note on every suggested sub, in every output.
--
-- Operator 2026-11-12: "some suggestions prior had limited/obstructed view, add notes to output".
--   * The cover queue (subs page, v_n2s_orders, n2s_profitable_cover, the N2S MCP) read seller
--     notes for GoTickets and SeatGeek only. EVO subs, the only ones the auto-buyer buys, always
--     read sub_view 'unknown' with no text, although N2S's own EVO pull (n2s_evo_current,
--     20260927041700) has carried public_notes and view_type since September. The 20260910630000
--     note saying TEvo notes are not mirrored is out of date for N2S.
--   * The dry run read EVO public_notes for its obstructed_view skip but stored only the verdict
--     and ignored view_type, so its rows, the buy email and the approval message had no notes.
--   * n2s_view_of() matched 'limited' inside 'unlimited' (prod 2026-11-12: 9 EVO club listings,
--     "Includes unlimited food and soft drinks", read as obstructed) and 'behind' in "Behind home
--     bench" (2 SeatGeek listings). Checked against every note in the N2S current lists on
--     2026-11-12: every real disclosure (limited / obstructed / partial / side view) still matches.
--     The deal scanner's copy of this vocabulary (20260911162200, D0) is not changed here.
--
--   1. n2s_view_of(): 'limited' as a whole word; 'behind' only as 'behind (the) stage'.
--   2. n2s_evo_notes(public_notes, view_type): one text for an EVO listing, 'View: <type> · <notes>'.
--   3. n2s_cover_queue_refresh(): EVO subs get sub_notes / sub_view from n2s_evo_current.
--   4. n2s_gt_order_dryrun.sub_notes: the note the dry run judged, written by both capture
--      functions; the EVO one now judges view_type too (via n2s_evo_notes).
--   5. n2s_autobuy_notify_tick(): the buy email and the approval message show the seller notes.
--
-- Nothing here calls a market: RULE 2 unchanged. The guards below refuse to run if any function
-- changed since the anchors were checked against prod (2026-11-12, each anchor exactly once).
--
-- rollback: re-create n2s_view_of from 20260910630000, n2s_cover_queue_refresh from 20260927041700,
--           the two capture functions from 20261110070000 and n2s_autobuy_notify_tick from
--           20261109030000; n2s_evo_notes and the sub_notes column are harmless to leave.

-- ── 1. the classifier ──────────────────────────────────────────────────────
DO $do$
BEGIN
  IF md5(pg_get_functiondef('public.n2s_view_of(text, boolean)'::regprocedure)) <> '37343264b9d87c0b49361a105d7b47a6' THEN
    RAISE EXCEPTION 'n2s_view_of drifted from 20260910630000 — re-derive this migration';
  END IF;
END $do$;

CREATE OR REPLACE FUNCTION public.n2s_view_of(p_notes text, p_limited_view boolean)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
    -- an explicit vendor flag outranks free text in both directions
    WHEN p_limited_view IS TRUE THEN 'obstructed'
    -- \m: 'limited' as a word, not inside 'unlimited' (club food notes); 'behind' only for a
    -- stage, not "behind home bench" (20261112010000)
    WHEN p_notes ~* 'obstruct|\mlimited|partial|restricted|obov|side view|behind (the )?stage|pole|no view'
      THEN 'obstructed'
    WHEN p_limited_view IS FALSE THEN 'clear'
    -- notes present and saying nothing about the view is weak evidence, but it
    -- IS evidence: the seller wrote a disclosure field and did not disclose.
    WHEN p_notes IS NOT NULL AND btrim(p_notes) <> '' THEN 'clear'
    ELSE 'unknown'
  END;
$function$;

-- ── 2. one note text for an EVO listing ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_evo_notes(p_public_notes text, p_view_type text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT NULLIF(concat_ws(' · ',
           'View: ' || NULLIF(btrim(p_view_type), ''),
           NULLIF(btrim(p_public_notes), '')), '');
$function$;

COMMENT ON FUNCTION public.n2s_evo_notes(text, text) IS
  'The seller''s note on an EVO ticket group as one text: "View: <view_type> · <public_notes>", NULL when both are empty. Fed to n2s_view_of() and shown to people as sub_notes. 20261112010000.';

REVOKE ALL ON FUNCTION public.n2s_evo_notes(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.n2s_evo_notes(text, text) TO service_role, authenticated;

-- ── 3. the cover queue reads EVO notes too ─────────────────────────────────
DO $do$
BEGIN
  IF md5(pg_get_functiondef('public.n2s_cover_queue_refresh()'::regprocedure)) <> '2327b2e57a9b47616c5cf6d69a50863c' THEN
    RAISE EXCEPTION 'n2s_cover_queue_refresh drifted from 20260927041700 — re-derive this migration';
  END IF;
END $do$;

CREATE OR REPLACE FUNCTION public.n2s_cover_queue_refresh()
 RETURNS TABLE(rows_written integer, orders_covered integer, total_cover_cost numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int := 0;
BEGIN
  DELETE FROM public.n2s_cover_queue;

  INSERT INTO public.n2s_cover_queue (
    n2s_id, order_number, s4k_source, n2s_status, fail_reason, timer_expired,
    event_name, event_date, venue, tevo_event_id, section, order_row, quantity,
    sold_ea, sub_source, sub_listing_id, sub_section, sub_row, sub_qty,
    sub_avail, sub_ea, sub_total, cover_cost, rows_closer, buy_url,
    captured_at, cover_rank, fifo_position, refreshed_at,
    cover_gate, cover_label, order_zone, sub_zone)
  SELECT c.n2s_id, c.order_number, c.s4k_source, c.n2s_status, c.fail_reason,
         c.timer_expired, c.event_name, c.event_date, c.venue, c.tevo_event_id,
         c.section, c.order_row, c.quantity, c.sold_ea, c.sub_source,
         c.sub_listing_id, c.sub_section, c.sub_row, c.sub_qty, c.sub_avail,
         c.sub_ea, c.sub_total, c.cover_cost, c.rows_closer, c.buy_url,
         c.captured_at, c.cover_rank, c.fifo_position, now(),
         c.cover_gate, c.cover_label, c.order_zone, c.sub_zone
    FROM public.n2s_covers() c;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  -- view quality: baseline every covered row to 'unknown', then correct
  -- the three sources that publish a signal. See n2s_view_of().
  UPDATE public.n2s_cover_queue q SET sub_view = 'unknown'
   WHERE q.sub_listing_id IS NOT NULL;

  UPDATE public.n2s_cover_queue q
     SET sub_notes = s.notes,
         sub_view  = public.n2s_view_of(s.notes, s.lv)
    FROM (
      -- one primary-key lookup per covered row in the N2S current lists
      SELECT q2.n2s_id, x.notes, x.lv
        FROM public.n2s_cover_queue q2
        CROSS JOIN LATERAL (
          (SELECT g.notes, NULL::boolean AS lv
             FROM public.n2s_gt_current g
            WHERE q2.sub_source = 'gotickets'
              AND g.tevo_event_id = q2.tevo_event_id
              AND g.gt_listing_id::text = q2.sub_listing_id
            LIMIT 1)
          UNION ALL
          (SELECT sc.seller_notes, sc.has_limited_view
             FROM public.n2s_sg_current sc
            WHERE q2.sub_source = 'seatgeek'
              AND sc.tevo_event_id = q2.tevo_event_id
              AND sc.sglid::text   = q2.sub_listing_id
            LIMIT 1)
          UNION ALL
          -- 20261112010000: EVO public_notes + view_type, as the dry run reads them
          (SELECT public.n2s_evo_notes(ec.public_notes, ec.view_type), NULL::boolean
             FROM public.n2s_evo_current ec
            WHERE q2.sub_source = 'tevo'
              AND ec.event_id = q2.tevo_event_id
              AND ec.tevo_ticket_group_id::text = q2.sub_listing_id
            LIMIT 1)
        ) x
       WHERE q2.sub_listing_id IS NOT NULL
         AND q2.sub_source IN ('gotickets', 'seatgeek', 'tevo')
    ) s
   WHERE s.n2s_id = q.n2s_id;

  -- and into the LABEL, so a consumer that only reads cover_label still
  -- sees it. Safe to append unconditionally: the refresh DELETEs the whole
  -- queue and rebuilds it every run, so the suffix cannot accumulate.
  UPDATE public.n2s_cover_queue q
     SET cover_label = q.cover_label || ' obstructed view'
   WHERE q.sub_view = 'obstructed' AND q.cover_label IS NOT NULL;

  RETURN QUERY
    SELECT v_n,
           (SELECT count(*)::int FROM public.n2s_cover_queue),
           (SELECT round(COALESCE(sum(cover_cost), 0), 2) FROM public.n2s_cover_queue);
END $function$;

COMMENT ON COLUMN public.n2s_cover_queue.sub_notes IS
  'Raw seller note the classification was drawn from (EVO: n2s_evo_notes(public_notes, view_type), since 20261112010000), kept so a human can read the actual wording rather than trusting the regex.';

-- ── 4. the dry run keeps the note it judged ────────────────────────────────
ALTER TABLE public.n2s_gt_order_dryrun ADD COLUMN IF NOT EXISTS sub_notes text;

COMMENT ON COLUMN public.n2s_gt_order_dryrun.sub_notes IS
  'The seller''s note on the sub listing as the dry run read it (EVO: n2s_evo_notes(public_notes, view_type); GoTickets: notes). sub_view is n2s_view_of() of it. NULL on rows before 20261112010000.';

DO $do$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.n2s_gt_order_dryrun_capture'::regproc);
  IF md5(d) <> '1d1180a59bda8d0ebdeed8c5d8c29e18' THEN
    RAISE EXCEPTION 'n2s_gt_order_dryrun_capture drifted from 20261110070000 — re-derive this migration';
  END IF;
  d := replace(d, 'live_pulled_at, sub_view,', 'live_pulled_at, sub_view, sub_notes,');
  d := replace(d, 'r.live_pulled_at, v_view,', 'r.live_pulled_at, v_view, r.live_notes,');
  EXECUTE d;
END $do$;

DO $do$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.n2s_evo_order_dryrun_capture'::regproc);
  IF md5(d) <> 'a95dfe1cb497559c04ca8b8bd2a0f961' THEN
    RAISE EXCEPTION 'n2s_evo_order_dryrun_capture drifted from 20261110070000 — re-derive this migration';
  END IF;
  -- view_type is judged too: a group typed e.g. 'Obstructed' with no note text was 'unknown'
  d := replace(d, 'e.public_notes AS live_notes',
                  'public.n2s_evo_notes(e.public_notes, e.view_type) AS live_notes');
  d := replace(d, 'live_pulled_at, sub_view,', 'live_pulled_at, sub_view, sub_notes,');
  d := replace(d, 'r.live_pulled_at, v_view,', 'r.live_pulled_at, v_view, r.live_notes,');
  EXECUTE d;
END $do$;

-- ── 5. the buy email and the approval message carry the notes ──────────────
DO $do$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.n2s_autobuy_notify_tick()'::regprocedure);
  IF md5(d) <> '89f9e0494ea4a82583777c08e5f50c92' THEN
    RAISE EXCEPTION 'n2s_autobuy_notify_tick drifted from 20261109030000 — re-derive this migration';
  END IF;
  -- buy email: a "Seller notes:" line above the confirm-by line
  d := replace(d,
    $r$|| 'Sub must confirm by %s ET or the sale is not accepted.',$r$,
    $r$|| E'Seller notes: %s\n' || 'Sub must confirm by %s ET or the sale is not accepted.',$r$);
  d := replace(d,
    $r$to_char(e.sub_confirm_by AT TIME ZONE 'America/New_York', 'HH24:MI:SS'));$r$,
    $r$COALESCE((SELECT x.sub_notes FROM public.n2s_gt_order_dryrun x WHERE x.dryrun_id = e.dryrun_id), 'none listed'),
                     to_char(e.sub_confirm_by AT TIME ZONE 'America/New_York', 'HH24:MI:SS'));$r$);
  -- approval message (text / WhatsApp): the first 120 characters
  d := replace(d,
    $r$'Sub must confirm by %s ET. Approve: n2s_autobuy_approve(%s, true)',$r$,
    $r$'Seller notes: %s. Sub must confirm by %s ET. Approve: n2s_autobuy_approve(%s, true)',$r$);
  d := replace(d,
    $r$to_char(e.sub_confirm_by AT TIME ZONE 'America/New_York', 'HH24:MI'), e.n2s_id);$r$,
    $r$COALESCE(left((SELECT x.sub_notes FROM public.n2s_gt_order_dryrun x WHERE x.dryrun_id = e.dryrun_id), 120), 'none listed'),
                   to_char(e.sub_confirm_by AT TIME ZONE 'America/New_York', 'HH24:MI'), e.n2s_id);$r$);
  IF position('Seller notes: %s\n' in d) = 0 OR position('Seller notes: %s. Sub' in d) = 0 THEN
    RAISE EXCEPTION 'n2s_autobuy_notify_tick anchors not found — re-derive this migration';
  END IF;
  EXECUTE d;
END $do$;
