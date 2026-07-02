-- Migration 20260702160000 · lane:A1 (operator-directed) · writes(DDL):espn_scoreboard_queue(); reschedules cron td_enqueue_peak_sg + td_sg_burn_teardown · reads:cron.job · pre:20260616181000_wc_listings_catchup · auth:operator-requested 2026-07-02 ("full coverage for all wc games via espn and td")
--
-- ## Applied to prod 2026-07-02 via MCP apply_migration (operator-directed). Idempotent.
--
-- Full World Cup coverage across the two requested sources:
--
-- (1) ESPN — enroll the FIFA World Cup scoreboard. espn_scoreboard_queue() had a
--     hardcoded league list (NBA/NFL/MLB/NHL/WNBA + MLS only); no soccer WC, so
--     espn_event_snapshots carried ZERO World Cup matches. Verified live 2026-07-02:
--     GET soccer/fifa.world/scoreboard -> HTTP 200, league "FIFA World Cup", returns
--     every match for the queried date window. Adding one VALUES row
--     ('soccer','fifa.world','FIFA_WC', v_back..v_far) makes the existing cadence
--     collect the whole tournament automatically: espn_scoreboard_queue_4h fires it,
--     espn_scoreboard_process_5min drains scores/state/odds/attendance into
--     espn_event_snapshots (espn_league='FIFA_WC'). The v_back(-30d)..v_far(+270d)
--     range spans the entire event series (Jun 11 - Jul 19) in a single fetch.
--
-- (2) TD — extend the SeatGeek-via-TicketsData "sg_burn" window from 2026-07-09 to
--     2026-07-20 so SG data keeps flowing through the Semis (Jul 14-15), Third-Place
--     (Jul 18) and Final (Jul 19). The window is enforced by two cron bodies
--     (td_enqueue_peak_sg gates `now() < DATE`; td_sg_burn_teardown tears the override
--     down `now() >= DATE`); both are rescheduled here with the later date, bodies
--     otherwise byte-identical to the originals (migration 20260619* / sg_burn setup).
--     Blast radius today = the 22 active WC SG xref rows only (all other SG xref rows
--     are inactive), so this does not broaden non-WC SG-burn spend.
--
-- Idempotent: CREATE OR REPLACE FUNCTION + cron.schedule (upsert by jobname). Re-run safe.

-- ============================================================================
-- (1) ESPN: add FIFA World Cup to the scoreboard queue league list
-- ============================================================================
CREATE OR REPLACE FUNCTION public.espn_scoreboard_queue(p_lookahead_days integer DEFAULT 270)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  cfg RECORD; v_req bigint; v_count int := 0;
  v_back text   := to_char(current_date - 30, 'YYYYMMDD');
  v_mid  text   := to_char(current_date + 30, 'YYYYMMDD');
  v_far  text   := to_char(current_date + p_lookahead_days, 'YYYYMMDD');
BEGIN
  FOR cfg IN
    SELECT * FROM (VALUES
      ('basketball','nba','NBA',          v_back || '-' || v_far),
      ('football','nfl','NFL',            v_back || '-' || v_far),
      ('baseball','mlb','MLB',            v_back || '-' || v_mid),
      ('baseball','mlb','MLB',            v_mid  || '-' || v_far),
      ('hockey','nhl','NHL',              v_back || '-' || v_far),
      ('basketball','wnba','WNBA',        v_back || '-' || v_far),
      ('soccer','usa.1','MLS',            v_back || '-' || v_far),
      ('soccer','fifa.world','FIFA_WC',   v_back || '-' || v_far)   -- 2026 World Cup (added 2026-07-02)
    ) AS x(sport, league_path, league_label, date_range)
  LOOP
    SELECT net.http_get(
      url := 'https://site.api.espn.com/apis/site/v2/sports/' || cfg.sport || '/' || cfg.league_path || '/scoreboard',
      params := jsonb_build_object('dates', cfg.date_range, 'limit', '1000'),
      headers := jsonb_build_object('Accept','application/json','User-Agent','terminal-2-broker (julian@s4kent.com)'),
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO espn_scoreboard_pending(espn_league, request_id) VALUES (cfg.league_label, v_req);
    v_count := v_count + 1;
    PERFORM pg_sleep(0.5);
  END LOOP;
  RETURN v_count;
END $function$;

-- ============================================================================
-- (2) TD: extend the sg_burn window 2026-07-09 -> 2026-07-20 (through the Final)
-- ============================================================================
SELECT cron.schedule('td_enqueue_peak_sg', '5-59/10 * * * *', $cron$do $b$ begin
  if now() < timestamptz '2026-07-20' then
    perform public.td_enqueue_peak('SG','sg_burn');
  end if;
end $b$;$cron$);

SELECT cron.schedule('td_sg_burn_teardown', '20 12 * * *', $cron$do $b$ begin
  if now() >= timestamptz '2026-07-20' then
    update public.integration_policy
       set enabled=false, updated_by='td_sg_burn_teardown', updated_at=now()
     where key='td_seatgeek_emergency_override';
    update public.ticketsdata_event_xref
       set active=false, updated_at=now()
     where platform='SG' and meta->>'seed'='sg_burn';
    perform cron.unschedule('td_enqueue_peak_sg');
    perform cron.unschedule('td_sg_burn_teardown');
  end if;
end $b$;$cron$);
