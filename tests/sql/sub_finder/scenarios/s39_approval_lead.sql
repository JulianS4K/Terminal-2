\echo no approval for a cover whose event is more than 24 hours away (20261121063000)
UPDATE n2s_autobuy_config
   SET mode = 'live', kill_switch = false, buy_sources = '{tevo,gotickets}',
       live_sell_markets = '{evo,gotickets,seatgeek,vivid,tickpick}',
       per_order_cap_usd = 2000, daily_cap_usd = 10000, gt_per_order_cap_usd = 2000, gt_daily_cap_usd = 10000,
       project_cap_usd = 20000, live_runs_used = 1, live_runs_allowed = 1000000,
       gt_live_runs_used = 0, gt_live_runs_allowed = 1000000, max_buys_per_day = 1000000,
       max_failures_per_day = 2, approval_over_usd = 1000, min_confirm_window_s = 90,
       project_stopped = false, gt_project_stopped = false;
SELECT 'approval over $' || approval_over_usd || ', free from ' || approval_free_lead FROM n2s_autobuy_config;
-- one sale and one would-buy cover, its event p_lead from now
CREATE FUNCTION pg_temp.would_buy(p_id bigint, p_source text, p_cost numeric, p_lead interval) RETURNS text LANGUAGE plpgsql AS $$
DECLARE e record; j jsonb;
BEGIN
  INSERT INTO n2s_items (n2s_id, order_number, n2s_order_key, tevo_event_id, event_name, event_dt, alert_at)
  VALUES (p_id, 'O-' || p_id, 'O-' || p_id, 9000 + p_id, 'case ' || p_id, (now() + p_lead) AT TIME ZONE 'UTC', now());
  INSERT INTO n2s_gt_order_dryrun (dryrun_id, n2s_id, decision, sub_source, s4k_source, sub_listing_id, sub_qty,
                                   sold_ea, sold_qty, quoted_ea, live_price_ea, live_pulled_at, tevo_event_id,
                                   gt_event_id, order_number, event_name)
  VALUES (p_id, p_id, 'would_buy', p_source, 'Vivid Seats', 'S-' || p_id, 2, p_cost, 2, p_cost / 2, p_cost / 2, now(),
          9000 + p_id, 77, 'O-' || p_id, 'case ' || p_id);
  SELECT * INTO e FROM n2s_autobuy_exec WHERE n2s_id = p_id;
  j := n2s_autobuy_job_json(e.exec_id, 'buy');
  RETURN format('%s $%s, event in %s: %s %s; worker approval_over_usd %s', p_source, p_cost, p_lead, e.state,
                CASE WHEN cardinality(e.reasons) = 0 THEN '(no reasons)' ELSE array_to_string(e.reasons, ',') END,
                j->'cfg'->>'approval_over_usd');
END $$;
SELECT pg_temp.would_buy(1, 'tevo', 1500, interval '3 days');
SELECT pg_temp.would_buy(2, 'gotickets', 1500, interval '30 hours');
SELECT pg_temp.would_buy(3, 'tevo', 1500, interval '18 hours');
SELECT pg_temp.would_buy(4, 'tevo', 800, interval '18 hours');

\echo the per-order cap still applies to a cover far out
SELECT pg_temp.would_buy(5, 'tevo', 2100, interval '3 days');

\echo the 24 hours is a setting
UPDATE n2s_autobuy_config SET approval_free_lead = interval '48 hours';
SELECT pg_temp.would_buy(6, 'tevo', 1500, interval '30 hours');
