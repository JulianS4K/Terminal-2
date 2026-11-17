-- Migration 20261114000000 · level:secondary-sales · lane:D0 · writes:sub_finder_td_pull,sub_finder_td_seed_log,sub_finder_config,sub_finder_event_local_date,sub_finder_td_seeds,sub_finder_td_writeback,sub_finder_settle · reads:aq_event_map,sg_events_canonical,events,n2s_sg_current,td_budget_ok,td_reports_budget_ok,td_charge_credit,event_mapper_apply · pre:20261113460000
--
-- SUB FINDER: the search of the other marketplaces (TicketsData /match), rebuilt on what the
-- event mappers already learned.
--
-- Operator 2026-11-14: "why didnt mapper map to seatgeek, which maps to tickets data which maps
-- to stubhub?" · "look at the event mappers first and see how they map first before you fix
-- sub finder ticketsdata search, then include all lessons and fix".
--
-- What happened: five orders for one show got "no_event_link". The sub finder started /match
-- only from a StubHub id (aq_event_map.sh_event_id); this show's map rows held a Vivid id and
-- nothing else. The loop that fills StubHub ids (SeatGeek link -> /match -> StubHub, Vivid) has
-- not run since 2026-11-02 (no cron calls sg_match_map_tick; the td_match_* crons are off), and
-- the show is not in our SeatGeek catalogue. 1,130 future events hold a SeatGeek link but no
-- StubHub id; 337 hold only a Vivid id.
--
-- Lessons taken from the mappers (migs 20260609120000, 20260619163000..20260619200000,
-- 20260704180055, 20260912051500, 20260915013000; PROJECT_BIBLE §3), and what is done here:
--   1. SEEDS. The mappers found only a SeatGeek link worked (2026-06-19). Checked again
--      2026-11-14 on /match engine v3.15: a bare StubHub id (8 of 8 sub finder searches) and a
--      bare Vivid id (a show never asked about before: confidence 100, right date) both work.
--      So the search starts from a StubHub id, else a SeatGeek link, else a Vivid id
--      (sub_finder_td_seeds), and when one fails it tries the next, at most td_max_seeds (2).
--   2. SAME EVENT? A confident answer can be another night of a run or another event at the
--      venue (1.3% of the mappers' confident answers carried a different date than our event).
--      An answer is used only when status = success, match_confidence >= td_min_confidence (80,
--      the mappers' own bar), it is not 'ambiguous_same_day', and its date is our event's local
--      date. Otherwise: 'low_confidence' / 'wrong_event', and its listings are not used.
--   3. SEVERAL MAP ROWS, CONFLICTING IDS. One event can have several map rows with the ids split
--      across them, and 47 events carry two StubHub ids (main and parking, split doubleheaders).
--      Every row is read; an id that is one of several is tried last, and if it matches but
--      shows nothing the next link is tried.
--   4. FAILED LINKS ARE NOT RETRIED BLINDLY (a failed seed was once fired 44 times). A link that
--      gives a wrong or unusable answer is logged and not asked again for 14 days, by any job.
--   5. RATE LIMIT. 429 is not a failure: the same link is asked again, twice at most. 402 (no
--      credit left) stops the job's remaining searches.
--   6. CREDITS. Each answered search costs 12 credits and a report. The shared guard is checked
--      before a search (td_budget_ok / td_reports_budget_ok: 'no_budget') and the shared ledger
--      is charged after (td_charge_credit), as the mappers do. The sub finder did neither.
--   7. THE MAP LEARNS. A validated answer at confidence >= 90 gives its StubHub and Vivid ids
--      to the event map through the map's own guarded function (event_mapper_apply: fill-only,
--      never when another row binds that id to a different event). SeatGeek ids are not written
--      back: they have the worst history of wrong-night bindings. Switch: td_writeback.
--   8. PARKING. No search is spent on a parking event; parking listings were already dropped.
--   9. SEATGEEK LISTINGS from the answer are now kept for an event our own SeatGeek feed has
--      nothing for (it has no link to it); before they were always thrown away.
--
-- An event with none of the three links still reads 'no_event_link'. Nothing here calls a
-- market other than TicketsData's read-only /match. Functions are shipped whole
-- (MIGRATION_CONVENTIONS 6a).
--
-- rollback: re-apply sub_finder_settle from 20261113260000's result; the new columns and
--           functions are harmless to leave.

ALTER TABLE public.sub_finder_td_pull
  ADD COLUMN IF NOT EXISTS seed             text,                              -- stubhub | seatgeek | vivid
  ADD COLUMN IF NOT EXISTS ambiguous        boolean NOT NULL DEFAULT false,    -- one of several ids of its kind for the event
  ADD COLUMN IF NOT EXISTS tried            text[]  NOT NULL DEFAULT '{}',     -- every link asked for this event in this job
  ADD COLUMN IF NOT EXISTS retries          integer NOT NULL DEFAULT 0,        -- rate-limit retries of the current link
  ADD COLUMN IF NOT EXISTS match_confidence numeric,
  ADD COLUMN IF NOT EXISTS match_date       date,
  ADD COLUMN IF NOT EXISTS learned          text;                              -- what the answer gave the event map
UPDATE public.sub_finder_td_pull SET seed = 'stubhub', tried = ARRAY[event_url] WHERE seed IS NULL;

CREATE TABLE IF NOT EXISTS public.sub_finder_td_seed_log (
  id            bigserial PRIMARY KEY,
  event_url     text NOT NULL,
  tevo_event_id bigint,
  note          text NOT NULL,              -- unusable_answer | low_confidence | wrong_event
  at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sub_finder_td_seed_log_url ON public.sub_finder_td_seed_log (event_url, at);
ALTER TABLE public.sub_finder_td_seed_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sub_finder_td_seed_log FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.sub_finder_td_seed_log IS
  'Links that gave TicketsData /match a wrong or unusable answer for the sub finder; not asked again for 14 days. 20261114000000.';

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS td_min_confidence           numeric NOT NULL DEFAULT 80,
  ADD COLUMN IF NOT EXISTS td_max_seeds                integer NOT NULL DEFAULT 2 CHECK (td_max_seeds BETWEEN 1 AND 3),
  ADD COLUMN IF NOT EXISTS td_writeback                boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS td_writeback_min_confidence numeric NOT NULL DEFAULT 90;

-- our event's date where it happens (events.occurs_at_local is local wall time, as text)
CREATE OR REPLACE FUNCTION public.sub_finder_event_local_date(p_tevo_event_id bigint)
 RETURNS date
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN e.occurs_at_local::text ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN left(e.occurs_at_local::text, 10)::date END
    FROM public.events e WHERE e.id = p_tevo_event_id
$$;

-- the links a search of the other marketplaces can start from, best first
CREATE OR REPLACE FUNCTION public.sub_finder_td_seeds(p_tevo_event_id bigint)
 RETURNS TABLE(seed text, url text, ambiguous boolean, ord integer)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  WITH m AS (
    SELECT a.id, a.sh_event_id, a.sg_event_id, a.vivid_event_id
      FROM public.aq_event_map a WHERE a.tevo_event_id = p_tevo_event_id
  ), cand AS (
    SELECT 'stubhub' AS seed, 'https://www.stubhub.com/event/' || m.sh_event_id AS url, 1 AS kind, min(m.id) AS first_id,
           (SELECT count(DISTINCT x.sh_event_id) FROM m x WHERE x.sh_event_id IS NOT NULL) > 1 AS ambiguous
      FROM m WHERE m.sh_event_id IS NOT NULL GROUP BY m.sh_event_id
    UNION ALL
    SELECT 'seatgeek', c.sg_url, 2, min(c.sg_event_id),
           (SELECT count(DISTINCT x.sg_event_id) FROM m x WHERE x.sg_event_id IS NOT NULL) > 1
      FROM public.sg_events_canonical c
     WHERE c.sg_url ~ '^https?://(www\.)?seatgeek\.com/'
       AND (c.sg_event_id IN (SELECT m.sg_event_id FROM m WHERE m.sg_event_id IS NOT NULL)
            OR c.tevo_event_id = p_tevo_event_id)
     GROUP BY c.sg_url
    UNION ALL
    SELECT 'vivid', 'https://www.vividseats.com/production/' || m.vivid_event_id, 3, min(m.id),
           (SELECT count(DISTINCT x.vivid_event_id) FROM m x WHERE x.vivid_event_id IS NOT NULL) > 1
      FROM m WHERE m.vivid_event_id IS NOT NULL GROUP BY m.vivid_event_id
  )
  SELECT c.seed, c.url, c.ambiguous, row_number() OVER (ORDER BY c.ambiguous, c.kind, c.first_id, c.url)::integer
    FROM cand c
   WHERE NOT EXISTS (SELECT 1 FROM public.events e WHERE e.id = p_tevo_event_id AND e.name ~* '\mparking\M')
     AND NOT EXISTS (SELECT 1 FROM public.sub_finder_td_seed_log l
                      WHERE l.event_url = c.url AND l.at > now() - interval '14 days')
$$;

-- a validated answer's StubHub and Vivid ids go to the event map through the map's own guarded
-- function; an error there never costs the search its answer
CREATE OR REPLACE FUNCTION public.sub_finder_td_writeback(p_tevo_event_id bigint, p_matches jsonb, p_local_date date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  r     record;
  v_res text;
  v_out text := '';
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('stubhub', substring(coalesce(p_matches->>'stubhub', '')    FROM '/event/([0-9]{4,18})')),
      ('vivid',   substring(coalesce(p_matches->>'vividseats', '') FROM '/production/([0-9]{4,18})'))) v(src, id)
  LOOP
    CONTINUE WHEN r.id IS NULL;
    BEGIN
      v_res := public.event_mapper_apply(r.src, r.id::bigint, p_tevo_event_id, NULL, NULL, p_local_date);
      IF coalesce(v_res, '') <> '' THEN v_out := v_out || r.src || ' ' || r.id || ': ' || v_res || ' '; END IF;
    EXCEPTION WHEN OTHERS THEN
      v_out := v_out || r.src || ' ' || r.id || ': error ';
    END;
  END LOOP;
  RETURN nullif(btrim(v_out), '');
END
$$;

REVOKE ALL ON FUNCTION public.sub_finder_event_local_date(bigint), public.sub_finder_td_seeds(bigint),
                       public.sub_finder_td_writeback(bigint, jsonb, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_event_local_date(bigint), public.sub_finder_td_seeds(bigint),
                          public.sub_finder_td_writeback(bigint, jsonb, date) TO service_role;

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
$function$;
