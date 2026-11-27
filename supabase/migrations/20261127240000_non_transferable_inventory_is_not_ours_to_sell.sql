-- Tickets that cannot be transferred are not inventory. Stop polling them, stop publishing
-- them, and give the place back.
--
-- Operator 2026-11-27, holding the AXS page for Amy Grant & Vince Gill at the Ryman:
--   "TICKETS FOR THIS EVENT ARE NON-TRANSFERABLE UNDER ANY CIRCUMSTANCE. RESALE WILL NOT BE
--    PERMITTED. TICKET PURCHASER'S I.D. WILL BE CHECKED AT ENTRY."
--   -> "review any that show that warning and stop publishing those events and replace"
--
-- We were publishing four of them to the CRM as ordinary sellable inventory (1380751,
-- 1381015, 1381023, 1381032 -- 64, 96, 95 and 102 listings). A broker who buys these cannot
-- deliver them. That is worse than a wrong price: a wrong price costs margin, this costs a
-- sale that cannot be fulfilled.
--
-- THE SIGNAL, measured rather than assumed. Raw captures (mig 20261127220000) of three Ryman
-- events and two transferable Trans-Siberian Orchestra events:
--
--                            Amy Grant (3 of 3)                    TSO (2 of 2)
--   delivery label   "AXS Mobile ID - Free (Non-Transferable)"   "AXS Mobile ID"
--   event.description  the warning text, verbatim                 null
--   ------------------------------------------------------------------------------
--   secondaryEnabled        true                                  true
--   is_resale_enabled       false                                 false
--   marketplace             false                                 false
--   isOnlyForMembers        false                                 false
--
-- The four flags that sound like they mean this are IDENTICAL on both kinds and are useless
-- for it. The delivery-method label is the structured tell; event.description confirms it in
-- prose. Both are read, either is sufficient.
--
-- WHAT HAPPENS ON DETECTION, modelled on the thin-inventory path (mig 20261126230000) because
-- the requirement is the same: the capture is deleted, the counts are zeroed and watch is
-- cleared, so the event leaves the polled set, stops producing listing rows, and hands its
-- place back to axs_watch_fill -- which is the "and replace" half of the instruction. Unlike
-- thin inventory this is not a condition that passes, so the event is also marked
-- non_transferable permanently and the fill will not pick it up again. Without that the fill
-- would re-add it at 03:20Z, the next read would retire it, and we would pay one read per
-- event per day forever.
--
-- There is NO config flag here, unlike mig 20261127230000. A wrong price is a judgement call
-- worth observing before acting on; unsellable inventory is not. The detector is two literal
-- string tests, proven on five captures with no false positive and no false negative.

BEGIN;

-- 1. the mark -----------------------------------------------------------------------------
ALTER TABLE public.primary_poll_event
  ADD COLUMN IF NOT EXISTS non_transferable boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.primary_poll_event.non_transferable IS
  'AXS says these tickets cannot be transferred and resale is not permitted, so they are not '
  'inventory: never polled, never published, never re-picked by the fill (mig 20261127240000).';

-- 2. the detector -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.axs_watch_non_transferable(p_body jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $fn$
  SELECT coalesce(
      EXISTS (SELECT 1
                FROM jsonb_array_elements(
                       CASE WHEN jsonb_typeof(p_body->'delivery_methods') = 'array'
                            THEN p_body->'delivery_methods' ELSE '[]'::jsonb END) d
               WHERE coalesce(d->>'label', '') ~* 'non[- ]?transferable')
   OR coalesce(p_body->'event'->>'description', '')
        ~* 'non[- ]?transferable|resale will not be permitted',
   false)
$fn$;

REVOKE ALL ON FUNCTION public.axs_watch_non_transferable(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_non_transferable(jsonb) TO service_role;

-- 3. the settle acts on it, in place ------------------------------------------------------
DO $surgery$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_settle_one(text,integer,jsonb,boolean,text,boolean,text)'::regprocedure);
  decl_old CONSTANT text := '  v_perf text;';
  decl_new CONSTANT text := '  v_perf text; v_nontrans boolean := false;';
  set_old  CONSTANT text := '    v_perf := public.axs_watch_wrong_performance(body);';
  set_new  CONSTANT text := '    v_perf := public.axs_watch_wrong_performance(body);' || E'\n' ||
                            '    v_nontrans := public.axs_watch_non_transferable(body);';
  act_old  CONSTANT text := '  IF p_status_code = 200 AND coalesce(p_charge, true) THEN';
  act_new  CONSTANT text :=
    '  -- mig 20261127240000: inventory that cannot be transferred is not ours to sell. The' || E'\n' ||
    '  -- capture goes, the place goes back to the fill, and the mark keeps it from returning.' || E'\n' ||
    '  IF v_nontrans THEN' || E'\n' ||
    '    DELETE FROM public.primary_poll_listing_piece pc' || E'\n' ||
    '     WHERE pc.source = ''axs'' AND pc.source_event_id = p_event_id;' || E'\n' ||
    '    DELETE FROM public.primary_poll_listing l' || E'\n' ||
    '     WHERE l.source = ''axs'' AND l.source_event_id = p_event_id;' || E'\n' ||
    '    UPDATE public.primary_poll_event e' || E'\n' ||
    '       SET non_transferable = true, watch = false,' || E'\n' ||
    '           listing_count = 0, listed_quantity = 0, median_price = NULL,' || E'\n' ||
    '           total_available = 0, price_min = NULL, price_max = NULL,' || E'\n' ||
    '           poll_status = ''pending'', poll_ok_at = NULL' || E'\n' ||
    '     WHERE e.source = ''axs'' AND e.source_event_id = p_event_id;' || E'\n' ||
    '    IF NOT EXISTS (SELECT 1 FROM public.axs_watch_audit a' || E'\n' ||
    '                    WHERE a.action = ''non_transferable'' AND a.axs_event_id = p_event_id) THEN' || E'\n' ||
    '      INSERT INTO public.axs_watch_audit (run_id, action, axs_event_id, venue, note)' || E'\n' ||
    '      VALUES (gen_random_uuid(), ''non_transferable'', p_event_id,' || E'\n' ||
    '              nullif(body->''event''->''venue''->>''name'', ''''),' || E'\n' ||
    '              ''retired: AXS says these tickets are non-transferable and resale is not permitted'');' || E'\n' ||
    '    END IF;' || E'\n' ||
    '  END IF;' || E'\n' ||
    '  IF p_status_code = 200 AND coalesce(p_charge, true) THEN';
  n int;
BEGIN
  IF position('axs_watch_non_transferable' in src) > 0 THEN
    RAISE EXCEPTION 'settle already calls axs_watch_non_transferable';
  END IF;
  n := (length(src) - length(replace(src, decl_old, ''))) / length(decl_old);
  IF n <> 1 THEN RAISE EXCEPTION 'settle v_perf declare anchor matched % times, expected 1', n; END IF;
  n := (length(src) - length(replace(src, set_old, ''))) / length(set_old);
  IF n <> 1 THEN RAISE EXCEPTION 'settle detector-call anchor matched % times, expected 1', n; END IF;
  n := (length(src) - length(replace(src, act_old, ''))) / length(act_old);
  IF n <> 1 THEN RAISE EXCEPTION 'settle charge anchor matched % times, expected 1', n; END IF;
  src := replace(src, decl_old, decl_new);
  src := replace(src, set_old, set_new);
  src := replace(src, act_old, act_new);
  EXECUTE src;
END $surgery$;

-- 4. the feed says why, in place ----------------------------------------------------------
DO $surgery$
DECLARE
  v_ev text; v_opts text[];
  old_arm CONSTANT text := E'            WHEN (t.poll_status = \'pending\'::text) THEN \'not_polled\'::text\n';
  new_arm CONSTANT text := E'            WHEN COALESCE(t.non_transferable, false) THEN \'non_transferable\'::text\n'
                        || E'            WHEN (t.poll_status = \'pending\'::text) THEN \'not_polled\'::text\n';
  n int;
BEGIN
  SELECT pg_get_viewdef('v_primary_poll_events_feed'::regclass) INTO v_ev;
  SELECT reloptions INTO v_opts FROM pg_class WHERE relname = 'v_primary_poll_events_feed';
  IF v_ev ~ 'non_transferable' THEN
    RAISE NOTICE 'the events feed already reports non_transferable; nothing to do';
    RETURN;
  END IF;
  n := (length(v_ev) - length(replace(v_ev, old_arm, ''))) / length(old_arm);
  IF n <> 1 THEN RAISE EXCEPTION 'events feed: not_polled arm matched % times, expected 1', n; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_primary_poll_events_feed AS '
          || replace(v_ev, old_arm, new_arm);
  -- CREATE OR REPLACE VIEW does not carry reloptions over (learned the hard way, mig 20261127213000)
  IF v_opts @> ARRAY['security_invoker=true'] THEN
    EXECUTE 'ALTER VIEW public.v_primary_poll_events_feed SET (security_invoker = true)';
  END IF;
END $surgery$;

-- 5. the fill does not pick one up again --------------------------------------------------
DO $surgery$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_fill(boolean)'::regprocedure);
  old_tail CONSTANT text :=
    '     AND NOT public.axs_watch_event_dead(e.axs_event_id::text, left(e.event_date_local, 10)::date);';
  new_tail CONSTANT text :=
    '     AND NOT public.axs_watch_event_dead(e.axs_event_id::text, left(e.event_date_local, 10)::date)' || E'\n' ||
    '     -- mig 20261127240000: never re-pick inventory that cannot be transferred' || E'\n' ||
    '     AND NOT EXISTS (SELECT 1 FROM public.primary_poll_event nt' || E'\n' ||
    '                      WHERE nt.source = ''axs'' AND nt.source_event_id = e.axs_event_id::text' || E'\n' ||
    '                        AND nt.non_transferable);';
  n int;
BEGIN
  IF position('non_transferable' in src) > 0 THEN
    RAISE NOTICE 'the fill already excludes non-transferable events; nothing to do';
    RETURN;
  END IF;
  n := (length(src) - length(replace(src, old_tail, ''))) / length(old_tail);
  IF n <> 1 THEN RAISE EXCEPTION 'fill candidate anchor matched % times, expected 1', n; END IF;
  EXECUTE replace(src, old_tail, new_tail);
END $surgery$;

-- 6. the run already retired by hand is recorded as what it is ----------------------------
UPDATE public.primary_poll_event e
   SET non_transferable = true
 WHERE e.source = 'axs'
   AND EXISTS (SELECT 1 FROM public.axs_watch_audit a
                WHERE a.axs_event_id = e.source_event_id
                  AND a.note ILIKE '%non-transferable%');

-- 7. read back ----------------------------------------------------------------------------
DO $verify$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_settle_one(text,integer,jsonb,boolean,text,boolean,text)'::regprocedure);
  fil text := pg_get_functiondef('public.axs_watch_fill(boolean)'::regprocedure);
  v_ev text;
  nt jsonb := jsonb_build_object(
    'delivery_methods', jsonb_build_array(
      jsonb_build_object('label', 'AXS Mobile ID - Free (Non-Transferable)', 'type', 'FlashSeats')),
    'event', jsonb_build_object('description', 'TICKETS FOR THIS EVENT ARE NON-TRANSFERABLE UNDER ANY CIRCUMSTANCE.'));
  okj jsonb := jsonb_build_object(
    'delivery_methods', jsonb_build_array(
      jsonb_build_object('label', 'AXS Mobile ID', 'type', 'FlashSeats')),
    'event', jsonb_build_object('description', NULL));
  label_only jsonb := jsonb_build_object(
    'delivery_methods', jsonb_build_array(jsonb_build_object('label', 'Print at Home (non transferable)')));
  descr_only jsonb := jsonb_build_object(
    'event', jsonb_build_object('description', 'Resale will not be permitted for this show.'));
BEGIN
  SELECT pg_get_viewdef('v_primary_poll_events_feed'::regclass) INTO v_ev;
  IF NOT public.axs_watch_non_transferable(nt) THEN
    RAISE EXCEPTION 'detector missed a non-transferable body';
  END IF;
  IF public.axs_watch_non_transferable(okj) THEN
    RAISE EXCEPTION 'detector flagged a transferable body';
  END IF;
  IF NOT public.axs_watch_non_transferable(label_only) THEN
    RAISE EXCEPTION 'detector missed the label-only case';
  END IF;
  IF NOT public.axs_watch_non_transferable(descr_only) THEN
    RAISE EXCEPTION 'detector missed the description-only case';
  END IF;
  IF public.axs_watch_non_transferable('{}'::jsonb) THEN
    RAISE EXCEPTION 'detector flagged an empty body';
  END IF;
  IF position('axs_watch_non_transferable' in src) = 0 THEN
    RAISE EXCEPTION 'read-back: the settle does not call the detector';
  END IF;
  IF position('non_transferable = true, watch = false' in src) = 0 THEN
    RAISE EXCEPTION 'read-back: the settle does not retire a non-transferable event';
  END IF;
  IF v_ev !~ 'non_transferable' THEN
    RAISE EXCEPTION 'read-back: the events feed does not report non_transferable';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'v_primary_poll_events_feed'
                   AND reloptions @> ARRAY['security_invoker=true']) THEN
    RAISE EXCEPTION 'read-back: the events feed lost security_invoker=true';
  END IF;
  IF position('non_transferable' in fil) = 0 THEN
    RAISE EXCEPTION 'read-back: the fill does not exclude non-transferable events';
  END IF;
END $verify$;

COMMIT;
