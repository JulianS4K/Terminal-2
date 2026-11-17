CREATE OR REPLACE FUNCTION public.sub_finder_settle(p_job_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  c      public.sub_finder_config;
  j      public.sub_finder_job;
  r      record;
  v_open integer;
  v_user text;
  v_pass text;
  v_c    jsonb;
  v_conf numeric;
  v_date date;
  v_note text;
  v_n    integer;
  v_next record;
  v_budget boolean;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  SELECT * INTO j FROM public.sub_finder_job WHERE job_id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF j.status = 'done' THEN RETURN 'done'; END IF;

  PERFORM public.sub_finder_scratch();   -- the listings to rank, empty

  IF j.status = 'pulling' THEN
    -- j.pulled = false: routine polling already had every event, so there is nothing to wait for
    IF j.pulled AND now() < j.created_at + make_interval(secs => c.settle_min_s) THEN RETURN 'pulling'; END IF;
    IF j.pulled AND now() < j.created_at + make_interval(secs => c.settle_timeout_s) AND EXISTS (
         -- an event we had to pull for (no routine data), whose pull is still out or has not
         -- answered at all since the job began
         SELECT 1 FROM (SELECT DISTINCT tevo_event_id FROM public.sub_finder_order
                        WHERE job_id = p_job_id AND tevo_event_id IS NOT NULL) e
         WHERE NOT EXISTS (SELECT 1 FROM public.n2s_evo_current x
                           WHERE x.event_id = e.tevo_event_id AND x.pulled_at > j.created_at - c.refresh_fresh)
           AND (EXISTS (SELECT 1 FROM public.n2s_mkt_pull p
                        WHERE p.tevo_event_id = e.tevo_event_id
                          AND p.fired_at >= j.created_at - c.pull_refresh AND p.resolved_at IS NULL)
             OR NOT EXISTS (SELECT 1 FROM public.n2s_mkt_pull p
                            WHERE p.tevo_event_id = e.tevo_event_id
                              AND p.fired_at >= j.created_at - c.pull_refresh AND p.resolved_at IS NOT NULL))) THEN
      RETURN 'pulling';
    END IF;
    PERFORM public.sub_finder_load_native(p_job_id);
    PERFORM public.sub_finder_match(p_job_id);

    -- TicketsData: only events that still have an uncovered order, cheapest way in first
    -- (most uncovered orders per credit), capped per job.
    IF c.td_enabled THEN
      -- 20261114000000: the search starts from whichever link we hold for the event (StubHub,
      -- then SeatGeek, then Vivid), not only a StubHub id
      INSERT INTO public.sub_finder_td_pull (job_id, tevo_event_id, event_url, seed, ambiguous, tried)
      SELECT p_job_id, e.tevo_event_id, x.url, x.seed, x.ambiguous, ARRAY[x.url]
      FROM (SELECT tevo_event_id, count(*) AS n, count(*) FILTER (WHERE state = 'no_cover') AS n0 FROM public.sub_finder_order
            WHERE job_id = p_job_id AND public.sub_finder_td_wanted(c.td_scope, state, best) GROUP BY 1) e
      JOIN LATERAL (SELECT sd.seed, sd.url, sd.ambiguous FROM public.sub_finder_td_seeds(e.tevo_event_id) sd
                    ORDER BY sd.ord LIMIT 1) x ON true
      ORDER BY e.n0 DESC, e.n DESC, e.tevo_event_id LIMIT c.td_max_events_per_job
      ON CONFLICT DO NOTHING;
      UPDATE public.sub_finder_order o
         SET td_state = CASE
               WHEN EXISTS (SELECT 1 FROM public.sub_finder_td_pull p
                            WHERE p.job_id = o.job_id AND p.tevo_event_id = o.tevo_event_id) THEN 'queued'
               WHEN EXISTS (SELECT 1 FROM public.sub_finder_td_seeds(o.tevo_event_id)) THEN 'over_limit'
               ELSE 'no_event_link' END
       WHERE o.job_id = p_job_id AND public.sub_finder_td_wanted(c.td_scope, o.state, o.best);
      -- a queued order is not answered yet: hold it back as 'pending' until TicketsData is in
      UPDATE public.sub_finder_order SET state = 'pending'
       WHERE job_id = p_job_id AND td_state = 'queued' AND state = 'no_cover';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.sub_finder_td_pull WHERE job_id = p_job_id) THEN
      UPDATE public.sub_finder_job SET status = 'done', done_at = now(), updated_at = now() WHERE job_id = p_job_id;
      RETURN 'done';
    END IF;
    UPDATE public.sub_finder_job SET status = 'pulling_td', updated_at = now() WHERE job_id = p_job_id;
    PERFORM public.sub_finder_scratch();
  END IF;

  -- ── pulling_td ──────────────────────────────────────────────────────────────────────────
  -- 1. land every answer that has arrived (or give up on one that is overdue)
  FOR r IN
    SELECT p.tevo_event_id, p.fired_at, p.event_url, p.seed, p.ambiguous, p.tried, p.retries,
           h.id AS resp_id, h.status_code, h.content, h.timed_out
    FROM public.sub_finder_td_pull p
    LEFT JOIN net._http_response h ON h.id = p.request_id
    WHERE p.job_id = p_job_id AND p.request_id IS NOT NULL AND p.resolved_at IS NULL
      AND (h.id IS NOT NULL OR p.fired_at < now() - make_interval(secs => c.td_timeout_s))
  LOOP
    v_note := NULL; v_c := NULL; v_conf := NULL; v_date := NULL; v_n := 0;
    BEGIN
      IF r.resp_id IS NULL OR coalesce(r.timed_out, false) THEN v_note := 'timeout';
      ELSIF r.status_code = 429 THEN v_note := 'rate_limited';
      ELSIF r.status_code = 402 THEN v_note := 'quota_exhausted';
      ELSIF r.status_code IS DISTINCT FROM 200 OR r.content !~ '^\s*\{' THEN v_note := 'unusable_answer';
      ELSE
        v_c := r.content::jsonb;
        IF v_c->>'status' IS DISTINCT FROM 'success' THEN
          v_note := 'unusable_answer';
        ELSE
          -- TicketsData charges for every answered search, whatever we then make of it
          BEGIN
            PERFORM public.td_charge_credit(12, r.tevo_event_id, NULL, '/match', 200,
                      CASE WHEN (v_c->>'quota_remaining') ~ '^[0-9]{1,9}$' THEN (v_c->>'quota_remaining')::int END,
                      1,
                      CASE WHEN (v_c->>'reports_remaining') ~ '^[0-9]{1,9}$' THEN (v_c->>'reports_remaining')::int END);
          EXCEPTION WHEN OTHERS THEN NULL;                  -- the ledger must never cost us the answer
          END;
          -- Is it the same event? The mappers learned this the hard way: a confident answer can
          -- still be another night of a run, or a different event at the same venue.
          v_conf := CASE WHEN (v_c->>'match_confidence') ~ '^[0-9]+(\.[0-9]+)?$' THEN (v_c->>'match_confidence')::numeric END;
          v_date := CASE WHEN (v_c->'event_details'->>'date') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                         THEN (v_c->'event_details'->>'date')::date END;
          IF v_conf IS NULL OR v_conf < c.td_min_confidence OR v_c->>'match_type' = 'ambiguous_same_day' THEN
            v_note := 'low_confidence';
          ELSIF v_date IS NULL OR v_date IS DISTINCT FROM public.sub_finder_event_local_date(r.tevo_event_id) THEN
            v_note := 'wrong_event';
          END IF;
        END IF;
      END IF;
      IF v_note IS NULL THEN
        INSERT INTO _sf_l
        SELECT CASE pl.key WHEN 'vividseats' THEN 'vivid' ELSE pl.key END, 'ticketsdata', r.tevo_event_id,
               x->>'listing_id', x->>'section', x->>'row', (x->>'quantity')::int, (x->>'price_total')::numeric,
               ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(x->'available_lots') = 'array'
                                                           THEN x->'available_lots' ELSE '[]'::jsonb END)::int),
               now(), v_c->'matches'->>pl.key,
               CASE WHEN pl.key IN ('stubhub', 'viagogo') THEN 'before buyer fees' END
        FROM jsonb_each(v_c->'fetch_results'->'normalized') pl,
             jsonb_array_elements(CASE WHEN jsonb_typeof(pl.value->'offers') = 'array'
                                       THEN pl.value->'offers' ELSE '[]'::jsonb END) x
        WHERE pl.key <> 'dice'
          -- SeatGeek is searched from our own feed; its TicketsData listings are kept only for an
          -- event our own SeatGeek feed has nothing for (no link to it)
          AND (pl.key <> 'seatgeek'
               OR NOT EXISTS (SELECT 1 FROM public.n2s_sg_current sgc WHERE sgc.tevo_event_id = r.tevo_event_id))
          AND NOT coalesce((x->'flags'->>'parking')::boolean, false)
          AND x->>'section' IS NOT NULL AND x->>'row' IS NOT NULL
          AND (x->>'quantity') ~ '^\d+$' AND (x->>'price_total') ~ '^\d+(\.\d+)?$';
        SELECT count(*) INTO v_n FROM _sf_l WHERE eid = r.tevo_event_id;
        -- one of several links for this event (a parking or twin listing) that shows nothing: try the next
        IF v_n = 0 AND r.ambiguous THEN v_note := 'no_offers'; END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_note := 'unusable_answer';
    END;

    IF v_note IS NULL THEN
      UPDATE public.sub_finder_td_pull
         SET resolved_at = now(), status_code = r.status_code, offers = v_n, note = NULL,
             match_confidence = v_conf, match_date = v_date,
             -- what the answer taught the event map (fill-only, through the map's own guarded function)
             learned = CASE WHEN c.td_writeback AND v_conf >= c.td_writeback_min_confidence
                            THEN public.sub_finder_td_writeback(r.tevo_event_id, v_c->'matches', v_date) END
       WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id;
      UPDATE public.sub_finder_order SET td_state = 'searched', rematch = rematch OR state = 'cover'
       WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id AND td_state = 'queued';
      CONTINUE;
    END IF;

    -- rate limited: the same link again, at most twice more
    IF v_note = 'rate_limited' AND r.retries < 2 THEN
      UPDATE public.sub_finder_td_pull
         SET request_id = NULL, fired_at = NULL, retries = retries + 1, status_code = r.status_code, note = v_note
       WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id;
      CONTINUE;
    END IF;
    -- a link that gave a wrong or unusable answer is not asked again for 14 days, by any job
    IF v_note IN ('unusable_answer', 'low_confidence', 'wrong_event') THEN
      INSERT INTO public.sub_finder_td_seed_log (event_url, tevo_event_id, note) VALUES (r.event_url, r.tevo_event_id, v_note);
    END IF;
    -- another link for the same event, if we hold one
    IF v_note IN ('unusable_answer', 'low_confidence', 'wrong_event', 'no_offers', 'timeout')
       AND cardinality(r.tried) < c.td_max_seeds THEN
      SELECT sd.seed, sd.url, sd.ambiguous INTO v_next FROM public.sub_finder_td_seeds(r.tevo_event_id) sd
       WHERE sd.url <> ALL (r.tried) ORDER BY sd.ord LIMIT 1;
      IF FOUND THEN
        UPDATE public.sub_finder_td_pull
           SET event_url = v_next.url, seed = v_next.seed, ambiguous = v_next.ambiguous, tried = tried || v_next.url,
               request_id = NULL, fired_at = NULL, retries = 0, status_code = r.status_code, note = v_note
         WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id;
        CONTINUE;
      END IF;
    END IF;
    -- a link that matched the event but shows no listings is an answer, not a failure
    IF v_note = 'no_offers' THEN
      UPDATE public.sub_finder_td_pull
         SET resolved_at = now(), status_code = r.status_code, offers = 0, note = NULL,
             match_confidence = v_conf, match_date = v_date
       WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id;
      UPDATE public.sub_finder_order SET td_state = 'searched', rematch = rematch OR state = 'cover'
       WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id AND td_state = 'queued';
      CONTINUE;
    END IF;
    UPDATE public.sub_finder_td_pull
       SET resolved_at = now(), status_code = r.status_code, note = v_note,
           match_confidence = v_conf, match_date = v_date
     WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id;
    UPDATE public.sub_finder_order SET td_state = 'failed'
     WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id AND td_state = 'queued';
    -- the plan has no credit left: do not fire the rest
    IF v_note = 'quota_exhausted' THEN
      UPDATE public.sub_finder_td_pull SET resolved_at = now(), note = 'quota_exhausted'
       WHERE job_id = p_job_id AND request_id IS NULL AND resolved_at IS NULL;
      UPDATE public.sub_finder_order o SET td_state = 'failed'
       WHERE o.job_id = p_job_id AND o.td_state = 'queued'
         AND EXISTS (SELECT 1 FROM public.sub_finder_td_pull p WHERE p.job_id = o.job_id AND p.tevo_event_id = o.tevo_event_id
                       AND p.note = 'quota_exhausted');
    END IF;
  END LOOP;
  -- match the orders whose event has now answered (the rest stay pending)
  IF EXISTS (SELECT 1 FROM public.sub_finder_order
             WHERE job_id = p_job_id AND ((state = 'pending' AND td_state IN ('searched', 'failed'))
                                         OR (rematch AND state = 'cover' AND td_state = 'searched'))) THEN
    PERFORM public.sub_finder_match(p_job_id, true);   -- a failed pull has no rows: those end 'no_cover'
  END IF;

  -- 2. fire the next ones, never more in flight (across all jobs) than the account allows
  SELECT count(*) INTO v_open FROM public.sub_finder_td_pull
   WHERE request_id IS NOT NULL AND resolved_at IS NULL
     AND fired_at > now() - make_interval(secs => c.td_timeout_s);
  IF v_open < c.td_concurrency
     AND EXISTS (SELECT 1 FROM public.sub_finder_td_pull WHERE job_id = p_job_id AND request_id IS NULL AND resolved_at IS NULL) THEN
    v_user := public.get_app_secret('TICKETSDATA_USERNAME');
    v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');
    -- the same credit and report guard every other TicketsData caller obeys (20261114000000)
    v_budget := coalesce(public.td_budget_ok(), false) AND coalesce(public.td_reports_budget_ok(), false);
    FOR r IN SELECT tevo_event_id, event_url FROM public.sub_finder_td_pull
              WHERE job_id = p_job_id AND request_id IS NULL AND resolved_at IS NULL
              ORDER BY tevo_event_id LIMIT c.td_concurrency - v_open
    LOOP
      IF NOT v_budget OR coalesce(v_user, '') = '' OR coalesce(v_pass, '') = '' THEN
        UPDATE public.sub_finder_td_pull SET resolved_at = now(), note = CASE WHEN NOT v_budget THEN 'no_budget' ELSE 'no_credentials' END
         WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id;
        UPDATE public.sub_finder_order SET td_state = 'failed', state = CASE WHEN state = 'pending' THEN 'no_cover' ELSE state END, updated_at = now()
         WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id AND td_state = 'queued';
      ELSE
        UPDATE public.sub_finder_td_pull
           SET fired_at = now(),
               request_id = net.http_get(
                 url := 'https://ticketsdata.com/match',
                 params := jsonb_build_object('event_url', r.event_url, 'username', v_user, 'password', v_pass),
                 headers := '{}'::jsonb,
                 timeout_milliseconds := c.td_timeout_s * 1000 - 5000)
         WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id;
      END IF;
    END LOOP;
  END IF;

  -- 3. finished when nothing is left to fire or to wait for
  IF NOT EXISTS (SELECT 1 FROM public.sub_finder_td_pull WHERE job_id = p_job_id AND resolved_at IS NULL) THEN
    UPDATE public.sub_finder_job SET status = 'done', done_at = now(), updated_at = now() WHERE job_id = p_job_id;
    RETURN 'done';
  END IF;
  RETURN 'pulling_td';
END
$function$

