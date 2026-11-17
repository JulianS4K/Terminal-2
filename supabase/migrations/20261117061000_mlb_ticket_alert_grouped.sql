-- Migration 20261117061000 · level:data-collection · lane:A1 (data plane — MLB schedule) · writes:mlb_ticket_alert_tick() · reads:mlb_ticket_change,mlb_ticket_game,mlb_ticket_event,mlb_ticket_team,n2s_autobuy_config,vault.decrypted_secrets · pre:20261117060000
--
-- The alert digest lists one line per change. The first v2 tick on prod (2026-11-17 05:36 UTC)
-- showed why that does not hold up: Arizona published all 81 of its 2027 home game times at once,
-- and the digest would have been 80 lines of "time changed — … at AZ …: TBD → …".
-- Now a club's changes of one kind collapse into one line once there are more than five of them:
--   • time changed — AZ: 81 games, 2027-03-26 to 2027-09-26 (e.g. TBD → 2027-04-02 18:40:00)
-- Five or fewer still get a line each. The subject still counts every change; the
-- "… and N more" tail now counts lines past 80, not changes.

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public.mlb_ticket_alert_tick()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  cfg     public.mlb_ticket_config;
  v_to    text[];
  v_from  text;
  rk      text;
  v_ids   bigint[];
  v_text  text;
  v_n     integer;
  v_lines integer;
  resp    extensions.http_response;
  addr    text;
BEGIN
  SELECT * INTO cfg FROM public.mlb_ticket_config;
  IF NOT coalesce(cfg.alerts_enabled, false) THEN RETURN 0; END IF;
  SELECT coalesce(cfg.alert_email_to, a.email_to), a.email_from INTO v_to, v_from FROM public.n2s_autobuy_config a;
  SELECT max(decrypted_secret) FILTER (WHERE name = 'RESEND_API_KEY') INTO rk FROM vault.decrypted_secrets;
  IF rk IS NULL OR v_from IS NULL OR coalesce(cardinality(v_to), 0) = 0 THEN RETURN 0; END IF;

  SELECT array_agg(id ORDER BY detected_at), count(*) INTO v_ids, v_n
    FROM public.mlb_ticket_change WHERE notable AND alerted_at IS NULL;
  IF coalesce(v_n, 0) = 0 THEN RETURN 0; END IF;

  WITH c AS (
    SELECT c.kind, c.entity, c.detected_at, c.old_value, c.new_value,
           coalesce(g.home_abbrev, t.abbrev, '?')        AS club,
           coalesce(g.game_date, ev.event_date)          AS d,
           coalesce(g.away_abbrev || ' at ' || g.home_abbrev || ' ' || g.game_date,
                    ev.title || ' · ' || ev.venue_name || ' ' || ev.event_date,
                    'schedule ' || c.schedule_id)        AS label,
           CASE WHEN c.old_value IS NOT NULL OR c.new_value IS NOT NULL
                THEN coalesce(c.old_value, '—') || ' → ' || coalesce(c.new_value, '—') END AS delta,
           count(*) OVER (PARTITION BY c.kind, coalesce(g.home_abbrev, t.abbrev, '?')) AS grp_n
      FROM public.mlb_ticket_change c
      LEFT JOIN public.mlb_ticket_game g ON c.entity IN ('game', 'promotion') AND g.schedule_id = c.schedule_id
      LEFT JOIN public.mlb_ticket_event ev ON c.entity = 'event' AND ev.schedule_id = c.schedule_id
      LEFT JOIN public.mlb_ticket_team t ON t.team_id = ev.team_id
     WHERE c.id = ANY (v_ids)),
  lines AS (
    SELECT c.kind, c.club, min(c.detected_at) AS at,
           '• ' || replace(c.kind, '_', ' ') || ' — ' || c.club || ': ' || count(*) || ' ' ||
           CASE WHEN bool_and(c.entity = 'event') THEN 'events' ELSE 'games' END ||
           coalesce(', ' || min(c.d) || ' to ' || max(c.d), '') ||
           coalesce(' (e.g. ' || (array_agg(c.delta ORDER BY c.d) FILTER (WHERE c.delta IS NOT NULL))[1] || ')', '') AS line
      FROM c WHERE c.grp_n > 5 GROUP BY c.kind, c.club
    UNION ALL
    SELECT c.kind, c.club, c.detected_at,
           '• ' || replace(c.kind, '_', ' ') || ' — ' || c.label || coalesce(': ' || c.delta, '')
      FROM c WHERE c.grp_n <= 5)
  SELECT (SELECT string_agg(x.line, E'\n' ORDER BY x.kind, x.club, x.at)
            FROM (SELECT * FROM lines ORDER BY kind, club, at LIMIT 80) x),
         (SELECT count(*) FROM lines)
    INTO v_text, v_lines;
  IF v_lines > 80 THEN v_text := v_text || E'\n… and ' || (v_lines - 80) || ' more (GET /api/v1/subs/mlb/changes).'; END IF;

  PERFORM set_config('http.timeout_msec', '5000', true);
  FOREACH addr IN ARRAY v_to LOOP
    BEGIN
      resp := extensions.http(('POST', 'https://api.resend.com/emails',
                ARRAY[extensions.http_header('Authorization', 'Bearer ' || rk)], 'application/json',
                jsonb_build_object('from', v_from, 'to', jsonb_build_array(addr),
                                   'subject', 'MLB tickets: ' || v_n || ' update' || CASE WHEN v_n = 1 THEN '' ELSE 's' END,
                                   'text', v_text)::text)::extensions.http_request);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
  UPDATE public.mlb_ticket_change SET alerted_at = now() WHERE id = ANY (v_ids);
  RETURN v_n;
END $$;

REVOKE ALL ON FUNCTION public.mlb_ticket_alert_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mlb_ticket_alert_tick() TO service_role;

COMMIT;

-- VERIFY: SELECT kind, count(*) FROM mlb_ticket_change WHERE notable AND alerted_at IS NULL GROUP BY 1;
--   after :17 the same query returns nothing, and the e-mail has one line per (kind, club) group.
-- ROLLBACK: re-apply 20261117060000's mlb_ticket_alert_tick().
