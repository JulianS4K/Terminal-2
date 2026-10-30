-- Migration 20261027180000 · level:ops · lane:A1 (data plane — SeatGeek sales ingest) · writes:pinned_sales_poll_tick()(replace) · reads:v_listings_poll_pinned_events,sg_events_canonical,sg_broker_pending,net._http_response · pre:20261027033528 (pinned sales poll)
--
-- ============================================================================
-- pinned_sales_poll_tick: one final pull in the hour before tip-off
--
-- WHY: the first hours of the poller showed SeatGeek answering 400 "The event with the given
-- event_id has expired" for Warriors at Nuggets 1 h 45 m after the start — before the
-- post-game pull (> 2 h after start) could fire. Other games still answered 2–3 h after the
-- start, so expiry is not at a fixed time. A pull inside the last hour before tip guarantees
-- each game's near-final sale history; the post-game pull stays and adds the late sales
-- when the event has not expired yet.
--
-- CHANGE: candidates 0–1 h before the start whose last sales pull is older than (start − 1 h)
-- are due, and share the front of the queue with post-game pulls. Returns pre_tip count.
--
-- ROLLBACK: re-apply pinned_sales_poll_tick from 20261027033528.
-- ============================================================================

SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public.pinned_sales_poll_tick(p_max integer DEFAULT 4)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r           RECORD;
  v_caller    text;
  v_token     text;
  v_remaining integer;
  v_req       bigint;
  v_n         integer := 0;
  v_post      integer := 0;
  v_pre       integer := 0;
BEGIN
  -- inside SECURITY DEFINER current_user is the owner; check the caller's role
  v_caller := CASE WHEN coalesce(current_setting('role', true), 'none') IN ('', 'none')
                   THEN session_user::text ELSE current_setting('role', true) END;
  IF v_caller NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: pinned_sales_poll_tick is service-only (caller %)', v_caller USING ERRCODE = '42501';
  END IF;

  v_token := public.get_app_secret('SEATGEEK_API_TOKEN');
  IF coalesce(v_token, '') = '' OR p_max <= 0 THEN
    RETURN jsonb_build_object('sales', 0, 'skipped', 'no_token_or_zero_max');
  END IF;

  -- same guard as the pinned SG listings leg: back off while the shared token is nearly spent
  SELECT (h.headers->>'ratelimit-remaining')::int INTO v_remaining
    FROM public.sg_broker_pending p JOIN net._http_response h ON h.id = p.request_id
   WHERE h.headers ? 'ratelimit-remaining' AND h.created > now() - interval '10 seconds'
   ORDER BY h.id DESC LIMIT 1;
  IF coalesce(v_remaining, 99) < 3 THEN
    RETURN jsonb_build_object('sales', 0, 'sg_ratelimit_remaining', v_remaining);
  END IF;

  FOR r IN
    WITH c AS (
      SELECT m.sg_event_id, v.occurs_at, v.hours_to_event AS h, bp.last_fired,
             (v.hours_to_event < -2) AS post_game,
             (v.hours_to_event BETWEEN 0 AND 1) AS pre_tip,
             CASE WHEN v.hours_to_event <= 48      THEN 360
                  WHEN v.hours_to_event <= 24 * 14 THEN 1440
                  ELSE 4320 END AS required_min
        FROM public.v_listings_poll_pinned_events v
        JOIN LATERAL (SELECT min(sc.sg_event_id) AS sg_event_id FROM public.sg_events_canonical sc
                       WHERE sc.tevo_event_id = v.tevo_event_id) m ON m.sg_event_id IS NOT NULL
        LEFT JOIN LATERAL (SELECT max(p.fired_at) AS last_fired FROM public.sg_broker_pending p
                            WHERE p.sg_event_id = m.sg_event_id AND p.scope = 'sales') bp ON true
       WHERE 'sg' = ANY (v.sources))
    SELECT c.sg_event_id, c.post_game, c.pre_tip
      FROM c
     WHERE CASE WHEN c.post_game
                THEN c.last_fired IS NULL OR c.last_fired < c.occurs_at + interval '2 hours'
                -- final pull in the hour before tip: SeatGeek can expire an event within ~2 h
                -- of the start, so the post-game pull is not guaranteed to land
                WHEN c.pre_tip
                THEN c.last_fired IS NULL OR c.last_fired < c.occurs_at - interval '1 hour'
                ELSE c.last_fired IS NULL OR c.last_fired < now() - make_interval(mins => c.required_min) END
     ORDER BY (c.post_game OR c.pre_tip) DESC,
              public._pinned_poll_priority(c.last_fired, c.required_min, greatest(c.h, 0)) DESC NULLS LAST,
              c.h
     LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/sales?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000) INTO v_req;
    INSERT INTO public.sg_broker_pending (sg_event_id, scope, request_id, fired_at)
    VALUES (r.sg_event_id, 'sales', v_req, now());
    v_n := v_n + 1;
    IF r.post_game THEN v_post := v_post + 1; END IF;
    IF r.pre_tip THEN v_pre := v_pre + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object('sales', v_n, 'post_game', v_post, 'pre_tip', v_pre, 'sg_ratelimit_remaining', v_remaining);
END $$;

REVOKE ALL ON FUNCTION public.pinned_sales_poll_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pinned_sales_poll_tick(integer) TO service_role;
