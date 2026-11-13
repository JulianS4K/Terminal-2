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
      INSERT INTO public.sub_finder_td_pull (job_id, tevo_event_id, event_url)
      SELECT p_job_id, e.tevo_event_id, 'https://www.stubhub.com/event/' || x.sh_event_id
      FROM (SELECT tevo_event_id, count(*) AS n, count(*) FILTER (WHERE state = 'no_cover') AS n0 FROM public.sub_finder_order
            WHERE job_id = p_job_id AND public.sub_finder_td_wanted(c.td_scope, state, best) GROUP BY 1) e
      JOIN LATERAL (SELECT a.sh_event_id FROM public.aq_event_map a
                    WHERE a.tevo_event_id = e.tevo_event_id AND a.sh_event_id IS NOT NULL
                    ORDER BY a.id LIMIT 1) x ON true
      ORDER BY e.n0 DESC, e.n DESC, e.tevo_event_id LIMIT c.td_max_events_per_job
      ON CONFLICT DO NOTHING;
      UPDATE public.sub_finder_order o
         SET td_state = CASE
               WHEN EXISTS (SELECT 1 FROM public.sub_finder_td_pull p
                            WHERE p.job_id = o.job_id AND p.tevo_event_id = o.tevo_event_id) THEN 'queued'
               WHEN EXISTS (SELECT 1 FROM public.aq_event_map a
                            WHERE a.tevo_event_id = o.tevo_event_id AND a.sh_event_id IS NOT NULL) THEN 'over_limit'
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
    SELECT p.tevo_event_id, p.fired_at, h.id AS resp_id, h.status_code, h.content, h.timed_out
    FROM public.sub_finder_td_pull p
    LEFT JOIN net._http_response h ON h.id = p.request_id
    WHERE p.job_id = p_job_id AND p.request_id IS NOT NULL AND p.resolved_at IS NULL
      AND (h.id IS NOT NULL OR p.fired_at < now() - make_interval(secs => c.td_timeout_s))
  LOOP
    BEGIN
      IF r.resp_id IS NULL OR r.status_code IS DISTINCT FROM 200 OR r.content !~ '^\s*\{' THEN
        RAISE EXCEPTION 'no usable answer';
      END IF;
      INSERT INTO _sf_l
      SELECT CASE pl.key WHEN 'vividseats' THEN 'vivid' ELSE pl.key END, 'ticketsdata', r.tevo_event_id,
             x->>'listing_id', x->>'section', x->>'row', (x->>'quantity')::int, (x->>'price_total')::numeric,
             ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(x->'available_lots') = 'array'
                                                         THEN x->'available_lots' ELSE '[]'::jsonb END)::int),
             now(), r.content::jsonb->'matches'->>pl.key,
             CASE WHEN pl.key IN ('stubhub', 'viagogo') THEN 'before buyer fees' END
      FROM jsonb_each(r.content::jsonb->'fetch_results'->'normalized') pl,
           jsonb_array_elements(CASE WHEN jsonb_typeof(pl.value->'offers') = 'array'
                                     THEN pl.value->'offers' ELSE '[]'::jsonb END) x
      WHERE pl.key NOT IN ('seatgeek', 'dice')              -- SeatGeek is already searched natively
        AND NOT coalesce((x->'flags'->>'parking')::boolean, false)
        AND x->>'section' IS NOT NULL AND x->>'row' IS NOT NULL
        AND (x->>'quantity') ~ '^\d+$' AND (x->>'price_total') ~ '^\d+(\.\d+)?$';
      UPDATE public.sub_finder_td_pull
         SET resolved_at = now(), status_code = r.status_code,
             offers = (SELECT count(*) FROM _sf_l WHERE eid = r.tevo_event_id)
       WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id;
      UPDATE public.sub_finder_order SET td_state = 'searched', rematch = rematch OR state = 'cover'
       WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id AND td_state = 'queued';
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.sub_finder_td_pull
         SET resolved_at = now(), status_code = r.status_code,
             note = CASE WHEN r.resp_id IS NULL THEN 'timeout' WHEN r.timed_out THEN 'timeout'
                         WHEN r.status_code = 429 THEN 'rate_limited' ELSE 'unusable_answer' END
       WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id;
      UPDATE public.sub_finder_order SET td_state = 'failed'
       WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id AND td_state = 'queued';
    END;
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
     AND EXISTS (SELECT 1 FROM public.sub_finder_td_pull WHERE job_id = p_job_id AND request_id IS NULL) THEN
    v_user := public.get_app_secret('TICKETSDATA_USERNAME');
    v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');
    FOR r IN SELECT tevo_event_id, event_url FROM public.sub_finder_td_pull
              WHERE job_id = p_job_id AND request_id IS NULL
              ORDER BY tevo_event_id LIMIT c.td_concurrency - v_open
    LOOP
      IF coalesce(v_user, '') = '' OR coalesce(v_pass, '') = '' THEN
        UPDATE public.sub_finder_td_pull SET resolved_at = now(), note = 'no_credentials'
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

