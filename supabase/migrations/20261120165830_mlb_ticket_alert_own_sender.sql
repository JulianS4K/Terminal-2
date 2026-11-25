-- Migration 20261120165830 · level:data-collection · lane:A1 (data plane — MLB schedule; operator-routed to the N2S session 2026-11-20) · writes:mlb_ticket_config,mlb_ticket_alert_tick() · reads:mlb_ticket_change,mlb_ticket_game,mlb_ticket_event,mlb_ticket_team,n2s_autobuy_config,vault.decrypted_secrets · pre:20261117061000
--
-- MLB ticket alerts get their own sender.
--
-- Operator 2026-11-20, receiving "MLB tickets: 194 updates" from "N2S Auto-buy
-- <onboarding@resend.dev>": "look at everything that reuses the template and make one for each
-- that uses it". mlb_ticket_alert_tick (20261117060000, regrouped 20261117061000) took its sender
-- and, unless mlb_ticket_config.alert_email_to was set, its recipients from n2s_autobuy_config.
--
-- Now the MLB alerts read only their own settings:
--   sender      mlb_ticket_config.alert_email_from, 'MLB ticket alerts <onboarding@resend.dev>'
--               (the same Resend address as before; only the name changes).
--   recipients  mlb_ticket_config.alert_email_to. Where it was NULL (= use N2S's list) it is
--               filled once here with n2s_autobuy_config.email_to, so the same people keep getting
--               these, and a later change to N2S's list no longer changes this one.
-- The digest itself (lines, grouping, subject) is unchanged.
--
-- VERIFY: SELECT alert_email_from, alert_email_to FROM mlb_ticket_config;
--         SELECT prosrc NOT LIKE '%n2s_autobuy_config%' FROM pg_proc WHERE proname = 'mlb_ticket_alert_tick';
-- ROLLBACK: re-apply 20261117061000's mlb_ticket_alert_tick();
--           ALTER TABLE public.mlb_ticket_config DROP COLUMN alert_email_from;
--           (alert_email_to keeps the copied list; set it back to NULL to follow N2S's list again.)

BEGIN;
SET LOCAL lock_timeout = '10s';

ALTER TABLE public.mlb_ticket_config
  ADD COLUMN IF NOT EXISTS alert_email_from text NOT NULL DEFAULT 'MLB ticket alerts <onboarding@resend.dev>';

UPDATE public.mlb_ticket_config c
   SET alert_email_to = a.email_to
  FROM public.n2s_autobuy_config a
 WHERE c.alert_email_to IS NULL;

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
  v_to := cfg.alert_email_to;
  v_from := cfg.alert_email_from;
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
