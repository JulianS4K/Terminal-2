-- Migration 20260812130000 · lane:A1/D0 (author) → applier (apply)
--   writes: v_event_state_features [view — the per-event signal assembly / "feature store"]
--   reads: events, sg_events_canonical, performer_metadata, performer_espn_team_xref,
--          v_event_team_standings, event_sentiment, v_event_betting_odds_latest,
--          v_event_weather, v_event_espn_injuries
--   auth: read-only SECURITY INVOKER view (RLS/grants of the underlying relations apply)
--
-- WHY (operator-directed 2026-08-12). North-star of the deal-prediction system: "track all
-- variables on an event." This is the FEATURE STORE — one row per upcoming event assembling
-- every live, event-level signal into a single state vector, so the end-of-life (event-day)
-- price + ROI predictor (next migration) scores a listing from one join instead of re-deriving
-- from 40+ tables each run. It also becomes the training panel: snapshot this over time, attach
-- the realized event-day clearing price when each event matures, and you have labeled data to
-- FIT the predictor's weights (replacing the hand-set impact priors).
--
-- SIGNALS (raw — transforms + impact weights live in the SCORER, not here, so weights can be
-- refit without touching the store). Each is LEFT-joined and null when absent; the scorer
-- coalesces missing → neutral, so the model degrades gracefully:
--   * contention  — home team games_back / win_pct / streak (ESPN standings via performer xref)
--   * order-flow  — event_sentiment.sentiment_index (ticket-book velocity; leading)
--   * outcome     — betting/prediction-market home_win_prob, over_under (NULL until ~days out)
--   * weather     — nearest-to-event precip_pct / wind_mph / temp_f (NULL until forecast range)
--   * availability— count of ESPN injuries with status 'Out'
--
-- HORIZON NOTE: at the deal horizon (weeks out) odds + weather are NULL by nature (books open
-- late, forecasts reach ~7-14d); contention + order-flow carry the far-out signal, odds/weather
-- switch on as the event approaches. Home team = events.primary_performer_id (the venue's team).
--
-- This is the inspectable v1 (a VIEW). The production feature store is a MATERIALIZED snapshot
-- refreshed on the 10-min cadence for events whose median price clears the $25 gate — a fast
-- follow once the scorer consumes this shape.
--
-- ROLLBACK: DROP VIEW public.v_event_state_features.

CREATE OR REPLACE VIEW public.v_event_state_features AS
WITH base AS (
  SELECT e.id AS tevo_event_id, sgc.sg_event_name AS event_name,
         sgc.sg_datetime_utc, sgc.sg_datetime_utc::date AS event_date,
         GREATEST((sgc.sg_datetime_utc::date - (now() AT TIME ZONE 'utc')::date), 0)::int AS dte_now,
         e.primary_performer_id AS pid, e.venue_id,
         CASE WHEN e.event_type='game' THEN 'Sports'
              WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
              ELSE 'Other' END AS category
  FROM public.events e
  JOIN public.sg_events_canonical sgc ON sgc.tevo_event_id = e.id
  LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
  WHERE sgc.sg_datetime_utc >= now() - interval '1 day'          -- upcoming events only (bounds the view)
)
SELECT b.tevo_event_id, b.event_name, b.event_date, b.dte_now, b.category, b.pid AS primary_performer_id, b.venue_id,
       -- contention (ESPN standings, home team)
       st.games_back AS home_games_back, st.win_pct AS home_win_pct, st.streak AS home_streak,
       -- order-flow (ticket-book velocity)
       fl.sentiment_index, fl.tix_per_hour, fl.getin_per_hour,
       -- outcome importance (betting / prediction market) — NULL until near-event
       od.home_win_prob AS mkt_home_win_prob, od.spread AS mkt_spread, od.over_under AS mkt_over_under, od.odds_provider,
       -- weather (nearest snapshot to event) — NULL until within forecast range
       wx.precip_pct AS wx_precip_pct, wx.wind_mph AS wx_wind_mph, wx.temp_f AS wx_temp_f, wx.is_forecast AS wx_is_forecast,
       -- availability (injuries)
       coalesce(inj.out_count, 0) AS injuries_out_count,
       now() AS assembled_at
FROM base b
LEFT JOIN LATERAL (
  SELECT s.games_back, s.win_pct, s.streak
  FROM public.performer_espn_team_xref x
  JOIN public.v_event_team_standings s ON s.tevo_event_id = b.tevo_event_id AND s.espn_team_id = x.espn_team_id
  WHERE x.tevo_performer_id = b.pid
  ORDER BY s.captured_at DESC LIMIT 1
) st ON true
LEFT JOIN LATERAL (
  SELECT es.sentiment_index, es.tix_per_hour, es.getin_per_hour
  FROM public.event_sentiment es WHERE es.event_id = b.tevo_event_id
  ORDER BY es.captured_at DESC LIMIT 1
) fl ON true
LEFT JOIN LATERAL (
  SELECT o.home_win_prob, o.spread, o.over_under, o.odds_provider
  FROM public.v_event_betting_odds_latest o WHERE o.tevo_event_id = b.tevo_event_id LIMIT 1
) od ON true
LEFT JOIN LATERAL (
  SELECT w.precip_pct, w.wind_mph, w.temp_f, w.is_forecast
  FROM public.v_event_weather w WHERE w.tevo_event_id = b.tevo_event_id
  ORDER BY abs(coalesce(w.minutes_offset, 999999)) LIMIT 1
) wx ON true
LEFT JOIN LATERAL (
  SELECT count(*) AS out_count
  FROM public.v_event_espn_injuries i
  WHERE i.tevo_event_id = b.tevo_event_id AND i.status ILIKE '%out%'
) inj ON true;

COMMENT ON VIEW public.v_event_state_features IS
  'Deal-prediction FEATURE STORE (v1 view): one row per upcoming event assembling every live event-level signal into a state vector — contention (ESPN standings), order-flow (event_sentiment velocity), outcome importance (betting/prediction-market odds, NULL until near-event), weather (nearest snapshot, NULL until forecast range), injuries-out. Raw signals only; transforms + impact weights live in the EOL scorer so weights refit without touching this. Home team = primary_performer_id. Intended to be filtered/joined per event; the production form is a materialized 10-min snapshot gated at median>$25. D0/A1 mig 20260812130000.';