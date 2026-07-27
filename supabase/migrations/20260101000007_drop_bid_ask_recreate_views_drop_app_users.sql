-- 1) Drop dependent views, drop bid_ask_proxy column, recreate views without it.
-- 2) Drop the unused app_users table (zero references in app.py / frontend / edge fns).
-- bid_ask_proxy was always 0 — TEvo API doesn't expose true wholesale to this token.
-- price_dispersion + tail_premium + owned_share replaced it as real signals.

drop view if exists event_series;
drop view if exists latest_event_metrics;

alter table event_metrics drop column if exists bid_ask_proxy;

create or replace view event_series as
 SELECT event_id,
    captured_at,
    tickets_count,
    groups_count,
    sections_count,
    retail_min,
    retail_p25,
    retail_median,
    retail_mean,
    retail_p75,
    retail_p90,
    retail_max,
    wholesale_median,
    wholesale_mean,
    getin_price,
    top5_concentration
   FROM event_metrics;

create or replace view latest_event_metrics as
 SELECT DISTINCT ON (event_id) event_id,
    captured_at,
    tickets_count,
    groups_count,
    sections_count,
    median_group_size,
    ancillary_groups,
    ancillary_tickets,
    retail_min,
    retail_p25,
    retail_median,
    retail_mean,
    retail_p75,
    retail_p90,
    retail_max,
    retail_sum,
    wholesale_min,
    wholesale_median,
    wholesale_mean,
    wholesale_max,
    getin_price,
    top5_concentration,
    price_dispersion,
    tail_premium,
    owned_groups_count,
    owned_tickets_count,
    owned_share,
    owned_median_retail
   FROM event_metrics
  ORDER BY event_id, captured_at DESC;

drop table if exists app_users;
