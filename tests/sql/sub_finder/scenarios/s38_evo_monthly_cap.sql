\echo the EVO project cap counts this calendar month (ET) only; GoTickets keeps its lifetime cap (20261121060000)
UPDATE n2s_autobuy_config
   SET mode = 'live', kill_switch = false, buy_sources = '{tevo,gotickets}',
       live_sell_markets = '{evo,gotickets,seatgeek,vivid,tickpick}',
       per_order_cap_usd = 1000, daily_cap_usd = 1000, project_cap_usd = 5000,
       gt_per_order_cap_usd = 666, gt_daily_cap_usd = 666, gt_project_cap_usd = 666,
       live_runs_used = 1, live_runs_allowed = 1000000, gt_live_runs_used = 0, gt_live_runs_allowed = 1,
       max_buys_per_day = 1000000, max_failures_per_day = 2, approval_over_usd = 1000, min_confirm_window_s = 90,
       project_stopped = false, gt_project_stopped = false;
-- the start of this ET month, as a timestamptz
CREATE FUNCTION pg_temp.month_start() RETURNS timestamptz LANGUAGE sql AS $$
  SELECT date_trunc('month', now() AT TIME ZONE 'America/New_York') AT TIME ZONE 'America/New_York' $$;
-- bought before: $4,900 of EVO last month, $146.52 of EVO this month, $600 of GoTickets last month
INSERT INTO n2s_autobuy_exec (exec_id, mode, state, phase, sub_source, sub_listing_id, tevo_event_id, sub_total_usd, est_tax_usd, buy_order_id, created_at)
VALUES (801, 'live', 'live_buy', 'accepted', 'tevo', 'L-801', 9801, 4900, 0, '19400001', pg_temp.month_start() - interval '5 days'),
       (802, 'live', 'live_buy', 'accepted', 'tevo', 'L-802', 9802, 146.52, 0, '19464447', pg_temp.month_start() + interval '1 minute'),
       (803, 'live', 'live_buy', 'accepted', 'gotickets', 'G-803', 9803, 600, 0, '8348959', pg_temp.month_start() - interval '5 days');
-- one sale and one would-buy cover per case
CREATE FUNCTION pg_temp.would_buy(p_id bigint, p_source text, p_market text, p_cost numeric) RETURNS text LANGUAGE plpgsql AS $$
DECLARE e record;
BEGIN
  INSERT INTO n2s_items (n2s_id, order_number, n2s_order_key, tevo_event_id, event_name, event_dt, alert_at)
  VALUES (p_id, 'O-' || p_id, 'O-' || p_id, 9000 + p_id, 'case ' || p_id, (now() + interval '3 days')::timestamp, now());
  INSERT INTO n2s_gt_order_dryrun (dryrun_id, n2s_id, decision, sub_source, s4k_source, sub_listing_id, sub_qty,
                                   sold_ea, sold_qty, quoted_ea, live_price_ea, live_pulled_at, tevo_event_id,
                                   gt_event_id, order_number, event_name)
  VALUES (p_id, p_id, 'would_buy', p_source, p_market, 'S-' || p_id, 2, p_cost, 2, p_cost / 2, p_cost / 2, now(),
          9000 + p_id, 77, 'O-' || p_id, 'case ' || p_id);
  SELECT * INTO e FROM n2s_autobuy_exec WHERE n2s_id = p_id;
  RETURN format('%s sub: %s %s, project spent before $%s', p_source, e.state,
                CASE WHEN cardinality(e.reasons) = 0 THEN '(no reasons)' ELSE array_to_string(e.reasons, ',') END,
                e.project_spent_before);
END $$;
SELECT pg_temp.would_buy(1, 'tevo', 'GoTickets', 300);
SELECT pg_temp.would_buy(2, 'gotickets', 'SeatGeek', 100);
SELECT 'evo stopped: ' || project_stopped || ', gotickets stopped: ' || gt_project_stopped FROM n2s_autobuy_config;

\echo a stop the EVO cap made last month is lifted by the first would-buy of this month
UPDATE n2s_autobuy_config
   SET project_stopped = true, project_stopped_at = pg_temp.month_start() - interval '1 hour',
       project_stopped_reason = 'Project spend reached $5000.00 of the $5000 cap (dryrun 700)', stop_emailed_at = now();
SELECT pg_temp.would_buy(3, 'tevo', 'Vivid Seats', 200);
SELECT 'evo stopped: ' || project_stopped || ', reason: ' || coalesce(project_stopped_reason, '-')
       || ', stop email cleared: ' || (stop_emailed_at IS NULL) FROM n2s_autobuy_config;

\echo the over-cap wording is lifted too
UPDATE n2s_autobuy_config
   SET project_stopped = true, project_stopped_at = pg_temp.month_start() - interval '1 hour',
       project_stopped_reason = 'dryrun 701: $700.00 would take project spend from $4600.00 past the $5000 cap';
SELECT pg_temp.would_buy(4, 'tevo', 'TickPick', 150);
SELECT 'evo stopped: ' || project_stopped FROM n2s_autobuy_config;

\echo a cap stop made this month stays
UPDATE n2s_autobuy_config
   SET project_stopped = true, project_stopped_at = now(),
       project_stopped_reason = 'Project spend reached $5000.00 of the $5000 cap (dryrun 702)';
SELECT pg_temp.would_buy(5, 'tevo', 'EVO', 100);
SELECT 'evo stopped: ' || project_stopped FROM n2s_autobuy_config;

\echo a stop for any other reason stays, even from last month
UPDATE n2s_autobuy_config
   SET project_stopped = true, project_stopped_at = pg_temp.month_start() - interval '1 hour',
       project_stopped_reason = 'operator: hold buying';
SELECT pg_temp.would_buy(6, 'tevo', 'GoTickets', 100);
SELECT 'evo stopped: ' || project_stopped || ', reason: ' || project_stopped_reason FROM n2s_autobuy_config;
