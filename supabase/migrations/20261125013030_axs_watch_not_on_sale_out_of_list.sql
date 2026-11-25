-- Migration 20261125013030 · level:data-collection · lane:A1 (data plane: the AXS watch, routed to this session by the operator) · writes:axs_watch_config(+not_on_sale_recheck,+onsale_delay),axs_watch_not_on_sale()(new),axs_watch_upcoming_sale()(new),axs_watch_fill()(replaced: an upcoming sale is retired and not picked),primary_poll_event(AXS rows: retired by the fill),axs_watch_audit(rows) · reads:axs_watch_poll,axs_export_event · pre:20261124190000 (the fill this re-creates),20261125010000
--
-- AN EVENT THAT IS NOT ON SALE YET HAS NO PLACE IN THE LIST OF 200.
-- Operator 2026-11-25: "Exclude upcoming sales from 200.list"; "Look at the axs discovery feed itself"; "Check on
-- sale date and add to queue 3 days after those dates hit".
--
-- 15 of the 193 watched events answered "Tickets for this event are not currently on sale" / "not on sale yet" at
-- every read (the 14 RodeoHouston concerts of March 2027 and a Kings game on sale 2027-01-27). They held 15 places
-- and were read every 6 hours (mig 20261125010000) to learn nothing.
--
-- WHAT SAYS AN EVENT IS NOT ON SALE.
--   THE AXS DISCOVERY FEED (axs_watch_upcoming_sale). The export labels an event (`status`) and dates its sale
--   (`onsale_utc`, filled for 7,445 of the 7,472 live AXS-sold events). The label alone is wrong: 28 watched events
--   were "Coming Soon" and 12 of them had tickets listed. With the date it is exact on the watched list: "Coming
--   Soon" with no on-sale date or one still ahead, 15 events, all 15 answering not on sale; "Coming Soon" with an
--   on-sale date already passed, 13 events, 12 with tickets (a label the export has not refreshed). So:
--     an event with an on-sale date is an upcoming sale until onsale_delay (3 days) after that date, whatever its
--     label: it joins the list three days after it goes on sale, once the first rush has settled;
--     an event with no on-sale date is an upcoming sale while it is labelled Coming Soon.
--   This costs no read.
--   THE READ (axs_watch_not_on_sale), for what the feed misses: the read's answer says not on sale ("not currently
--   on sale", "not on sale yet", "coming soon"), or says no tickets are currently available under a Coming Soon
--   label (the same answer under "Buy Tickets" is a sold-out show, which stays).
-- THE FILL (nightly, 03:20 UTC):
--   retires a watched event the feed marks as an upcoming sale, unless its last read found tickets, and one whose
--   last read says not on sale (audit: retire / not_on_sale);
--   does not pick an event the feed marks as an upcoming sale: it comes into the list by itself three days after
--   its on-sale date, or, with no date, when its label changes;
--   does not pick an event whose last read, within not_on_sale_recheck (7 days), said not on sale, unless that read
--   was made before the event's on-sale date. After the 7 days it is picked once more, read, and retired again the
--   next night if it is still not on sale.
-- The places freed are refilled only within each venue's quota, as before: RodeoHouston has no event on sale (all 20
-- of its live events are upcoming sales by the feed), so its 14 places stay empty until its quota is given to
-- another venue (axs_watch_venue) or its concerts go on sale.
--
-- rollback: re-apply axs_watch_fill() from 20261124190000; DROP FUNCTION axs_watch_not_on_sale(text, text, text),
--           axs_watch_upcoming_sale(text, timestamptz, interval);
--           the column can stay. The retired events return at the next fill.

ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS not_on_sale_recheck interval NOT NULL DEFAULT interval '7 days'
  CHECK (not_on_sale_recheck >= interval '1 day' AND not_on_sale_recheck <= interval '13 days');
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS onsale_delay interval NOT NULL DEFAULT interval '3 days'
  CHECK (onsale_delay >= interval '0' AND onsale_delay <= interval '30 days');
COMMENT ON COLUMN public.axs_watch_config.onsale_delay IS
  'how long after its on-sale date an event may join the list (mig 20261125013030; operator: "add to queue 3 days after those dates hit")';
COMMENT ON COLUMN public.axs_watch_config.not_on_sale_recheck IS
  'how long an event whose last read said "not on sale" is kept off the list before it is tried once more (mig 20261125013030); under the 14 days the poll ledger is kept';

-- Whether a read's answer says the event is not on sale yet. p_status is the AXS export's label for the event.
CREATE OR REPLACE FUNCTION public.axs_watch_not_on_sale(p_outcome text, p_error text, p_status text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  SELECT coalesce(p_outcome = 'unparsed'
                  AND (p_error ~* 'not (currently |yet )?on sale|coming soon'
                       OR (p_error ~* 'no tickets are currently available' AND coalesce(p_status, '') ~* 'coming soon')), false)
$function$;

-- Whether the AXS discovery feed marks an event as an upcoming sale: with an on-sale date, until p_delay after it,
-- whatever the label; with none, while it is labelled Coming Soon.
CREATE OR REPLACE FUNCTION public.axs_watch_upcoming_sale(p_status text, p_onsale timestamptz, p_delay interval)
 RETURNS boolean
 LANGUAGE sql
 STABLE PARALLEL SAFE
AS $function$
  SELECT CASE WHEN p_onsale IS NOT NULL THEN p_onsale > now() - coalesce(p_delay, interval '0')
              ELSE coalesce(p_status ~* 'coming soon', false) END
$function$;

REVOKE ALL ON FUNCTION public.axs_watch_not_on_sale(text, text, text), public.axs_watch_upcoming_sale(text, timestamptz, interval) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_not_on_sale(text, text, text), public.axs_watch_upcoming_sale(text, timestamptz, interval) TO service_role;

CREATE OR REPLACE FUNCTION public.axs_watch_fill(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_cfg public.axs_watch_config%ROWTYPE;
  v     record;
  v_have integer; v_room integer; v_need integer; v_added integer; v_retired integer := 0; v_total_added integer := 0;
  v_short jsonb := '[]'::jsonb;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('axs_watch_fill')) THEN
    RETURN jsonb_build_object('skipped', 'another axs_watch_fill is running');
  END IF;
  SELECT * INTO v_cfg FROM public.axs_watch_config;

  -- 1. retire: the event has passed, the export no longer lists it or no longer says AXS sells it, three reads
  --    in a row said AXS does not sell it (not_axs) or it is over (expired), or it is not on sale yet (mig
  --    20261125013030): its last read said so, or the discovery feed marks it as an upcoming sale and no read has
  --    found tickets
  DROP TABLE IF EXISTS _aw_retire;
  CREATE TEMP TABLE _aw_retire ON COMMIT DROP AS
  SELECT t.source_event_id, t.venue_name,
         CASE WHEN e.axs_event_id IS NULL THEN 'not_in_export'
              WHEN e.gone_at IS NOT NULL OR e.removed_utc IS NOT NULL THEN 'gone'
              WHEN NOT coalesce(e.axs_ticketed, false) THEN 'not_axs_sold'
              WHEN coalesce(e.event_date_utc, t.start_utc, (t.event_date + 1)::timestamptz) < now() - interval '6 hours' THEN 'passed'
              WHEN public.axs_watch_not_on_sale(lr.outcome, lr.error, e.status)
                   OR (public.axs_watch_upcoming_sale(e.status, e.onsale_utc, v_cfg.onsale_delay) AND NOT (t.poll_status = 'ok' AND coalesce(t.listing_count, 0) > 0))
                   THEN 'not_on_sale'
              ELSE 'not_axs_or_expired' END AS why
    FROM public.primary_poll_event t
    LEFT JOIN public.axs_export_event e ON e.axs_event_id::text = t.source_event_id
    -- the last read; one made before the event's on-sale date says nothing about the sale, and is not counted
    LEFT JOIN LATERAL (SELECT w.outcome, w.error FROM public.axs_watch_poll w
                        WHERE w.axs_event_id = t.source_event_id AND w.checked_at IS NOT NULL
                          AND (e.onsale_utc IS NULL OR w.checked_at > e.onsale_utc)
                        ORDER BY w.checked_at DESC LIMIT 1) lr ON true
   WHERE t.source = 'axs'
     AND (e.axs_event_id IS NULL OR e.gone_at IS NOT NULL OR e.removed_utc IS NOT NULL OR NOT coalesce(e.axs_ticketed, false)
          OR coalesce(e.event_date_utc, t.start_utc, (t.event_date + 1)::timestamptz) < now() - interval '6 hours'
          OR public.axs_watch_not_on_sale(lr.outcome, lr.error, e.status)
          OR (public.axs_watch_upcoming_sale(e.status, e.onsale_utc, v_cfg.onsale_delay) AND NOT (t.poll_status = 'ok' AND coalesce(t.listing_count, 0) > 0))
          OR (SELECT count(*) = 3 AND bool_and(w.outcome IN ('not_axs', 'expired'))
                FROM (SELECT w.outcome FROM public.axs_watch_poll w
                       WHERE w.axs_event_id = t.source_event_id AND w.checked_at IS NOT NULL
                       ORDER BY w.fired_at DESC LIMIT 3) w));
  SELECT count(*) INTO v_retired FROM _aw_retire;
  IF p_apply THEN
    INSERT INTO public.axs_watch_audit (run_id, action, axs_event_id, venue, note)
    SELECT v_run, 'retire', r.source_event_id, r.venue_name, r.why FROM _aw_retire r;
    DELETE FROM public.primary_poll_event t USING _aw_retire r WHERE t.source = 'axs' AND t.source_event_id = r.source_event_id;
    -- the export's match arriving later than the row: fill-only, as the mapper does for the other sources
    UPDATE public.primary_poll_event t
       SET tevo_event_id = e.tevo_event_id, tevo_match_method = 'axs_export', tevo_matched_at = now()
      FROM public.axs_export_event e
     WHERE t.source = 'axs' AND t.tevo_event_id IS NULL
       AND e.axs_event_id::text = t.source_event_id AND e.tevo_event_id IS NOT NULL;
  END IF;

  -- 2. refill each venue to its quota, soonest first, within the list's size
  -- smallest quota first: when the list's size caps the total, the biggest venue gives, not the operator's two Soldier Field picks
  FOR v IN SELECT * FROM public.axs_watch_venue WHERE enabled ORDER BY quota, axs_venue_id LOOP
    SELECT count(*) INTO v_have
      FROM public.primary_poll_event t JOIN public.axs_export_event e ON e.axs_event_id::text = t.source_event_id
     WHERE t.source = 'axs' AND e.venue_id = v.axs_venue_id
       AND NOT EXISTS (SELECT 1 FROM _aw_retire r WHERE r.source_event_id = t.source_event_id);
    SELECT v_cfg.target_events - count(*) INTO v_room
      FROM public.primary_poll_event t WHERE t.source = 'axs'
       AND NOT EXISTS (SELECT 1 FROM _aw_retire r WHERE r.source_event_id = t.source_event_id);
    v_need := least(greatest(v.quota - v_have, 0), greatest(v_room, 0));
    CONTINUE WHEN v_need = 0;
    DROP TABLE IF EXISTS _aw_pick;
    CREATE TEMP TABLE _aw_pick ON COMMIT DROP AS
    SELECT e.axs_event_id, e.event_title, e.event_date_local, e.event_date_utc, e.event_timezone, e.venue_name, e.venue_city,
           e.venue_state, e.event_url, e.tevo_event_id
      FROM public.axs_export_event e
     WHERE e.venue_id = v.axs_venue_id
       AND e.gone_at IS NULL AND e.removed_utc IS NULL AND coalesce(e.axs_ticketed, false)
       AND e.event_date_utc > now() AND e.event_url IS NOT NULL
       AND e.event_date_local ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' AND left(e.event_date_local, 10)::date >= v_cfg.watch_from
       AND public.axs_watch_rule_ok(e.major_category, e.event_title)
       AND NOT EXISTS (SELECT 1 FROM public.primary_poll_event t WHERE t.source = 'axs' AND t.source_event_id = e.axs_event_id::text
                          AND NOT EXISTS (SELECT 1 FROM _aw_retire r WHERE r.source_event_id = t.source_event_id))
       AND NOT EXISTS (SELECT 1 FROM _aw_retire r WHERE r.source_event_id = e.axs_event_id::text)
       -- not an upcoming sale: the discovery feed marks it as one (until onsale_delay after its on-sale date; with
       -- no date, while labelled Coming Soon), or the event's last read (within not_on_sale_recheck, 7 days, and made
       -- after its on-sale date, if it has one) said it is not on sale. After that it is tried once more.
       AND NOT public.axs_watch_upcoming_sale(e.status, e.onsale_utc, v_cfg.onsale_delay)
       AND NOT EXISTS (SELECT 1
                         FROM (SELECT w.outcome, w.error, w.checked_at FROM public.axs_watch_poll w
                                WHERE w.axs_event_id = e.axs_event_id::text AND w.checked_at IS NOT NULL
                                ORDER BY w.checked_at DESC LIMIT 1) lr
                        WHERE lr.checked_at > now() - v_cfg.not_on_sale_recheck
                          AND (e.onsale_utc IS NULL OR lr.checked_at > e.onsale_utc)
                          AND public.axs_watch_not_on_sale(lr.outcome, lr.error, e.status))
       -- not an event TicketsData has said three times (in the 14 days the ledger keeps) that AXS does not sell or that is over
       AND (SELECT count(*) FROM public.axs_watch_poll w WHERE w.axs_event_id = e.axs_event_id::text AND w.outcome IN ('not_axs', 'expired')) < 3
     ORDER BY e.event_date_utc, e.axs_event_id
     LIMIT v_need;
    SELECT count(*) INTO v_added FROM _aw_pick;
    IF v_added < v_need THEN
      v_short := v_short || jsonb_build_object('venue', v.venue_name, 'quota', v.quota, 'short_by', v_need - v_added);
      IF p_apply THEN
        INSERT INTO public.axs_watch_audit (run_id, action, venue, note)
        VALUES (v_run, 'short', v.venue_name, format('quota %s, %s eligible upcoming events short', v.quota, v_need - v_added));
      END IF;
    END IF;
    IF p_apply AND v_added > 0 THEN
      INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_local_time, start_utc, timezone,
          venue_name, venue_city, venue_state, ticket_url, tevo_event_id, tevo_match_method, tevo_matched_at, announced_at)
      SELECT 'axs', p.axs_event_id::text, p.event_title,
             CASE WHEN p.event_date_local ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN left(p.event_date_local, 10)::date END,
             CASE WHEN p.event_date_local ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}' THEN substr(p.event_date_local, 12, 5)::time END,
             p.event_date_utc, p.event_timezone, p.venue_name, p.venue_city, p.venue_state, p.event_url,
             p.tevo_event_id, CASE WHEN p.tevo_event_id IS NOT NULL THEN 'axs_export' END,
             CASE WHEN p.tevo_event_id IS NOT NULL THEN now() END,
             now()                       -- the mapper is not asked: the export's own match is the AXS match
        FROM _aw_pick p
      ON CONFLICT (source, source_event_id) DO NOTHING;
      INSERT INTO public.axs_watch_audit (run_id, action, axs_event_id, venue, note)
      SELECT v_run, 'add', p.axs_event_id::text, p.venue_name, left(p.event_date_local, 16) || ' ' || p.event_title FROM _aw_pick p;
    END IF;
    v_total_added := v_total_added + v_added;
  END LOOP;

  -- 3. the run: the feed serves the watched events and no other; the ledger forgets old requests
  IF p_apply THEN
    PERFORM public.primary_poll_run_done('axs', replace(v_run::text, '-', ''),
              coalesce((SELECT jsonb_agg(t.source_event_id) FROM public.primary_poll_event t WHERE t.source = 'axs'), '[]'::jsonb));
    DELETE FROM public.axs_watch_poll WHERE fired_at < now() - interval '14 days';
    DELETE FROM public.axs_watch_audit WHERE at < now() - interval '90 days';
  END IF;

  RETURN jsonb_build_object('run', v_run, 'apply', p_apply, 'retired', v_retired, 'added', v_total_added,
           'watched', CASE WHEN p_apply THEN (SELECT count(*) FROM public.primary_poll_event t WHERE t.source = 'axs')
                           ELSE (SELECT count(*) FROM public.primary_poll_event t WHERE t.source = 'axs') - v_retired + v_total_added END,
           'short', v_short);
END $function$;

REVOKE ALL ON FUNCTION public.axs_watch_fill(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_fill(boolean) TO service_role;
