-- Migration 20260604130000 · lane:D0 (author) → A1 (apply + schedule crons) · writes:event_watchlist.alert_cadence/last_alerted_at + dispatch fns + event_watchlist_set_cadence + event_watchlist_list(v2) · reads:event_alerts,events · enqueues:exos_mail (CROSS-LANE → D4, see note) · pre:20260604120000 · auth:operator-requested 2026-06-04
--
-- D0 — alert DELIVERY with three per-event cadences so users aren't spammed:
--   • instant — emailed as alerts fire (dispatch runs every 2 min with the engine)
--   • hourly  — one summary email/user/hour across their hourly-cadence events
--   • daily   — one summary email/user/day  across their daily-cadence events
-- Mute = alert_enabled=false (off). Cadence is per watchlist row.
--
-- Delivery reuses the existing Resend mailer: dispatch builds the HTML (shared
-- render_email_html shell) and enqueues into public.exos_mail, which the
-- already-deployed exos-mail-drain edge fn sends. ⚠ exos_mail is a D4-owned
-- table — this is a deliberate CROSS-LANE write of a generic transactional
-- queue; coordinated with A1/D4 (bot_chat). If D4 prefers isolation, swap the
-- two INSERT INTO exos_mail statements for a D0-owned outbox + drainer.
--
-- ⚠ CRON IS OPERATOR-GATED: the three cron.schedule lines are at the bottom,
-- COMMENTED. A1 runs them after apply (and wires cron_policy/cron_should_fire
-- to taste). Apply of this migration alone schedules nothing.

-- ── 1. Per-event cadence + instant watermark ────────────────────────────────
ALTER TABLE public.event_watchlist
  ADD COLUMN IF NOT EXISTS alert_cadence text NOT NULL DEFAULT 'instant',
  ADD COLUMN IF NOT EXISTS last_alerted_at timestamptz;
DO $$ BEGIN
  ALTER TABLE public.event_watchlist
    ADD CONSTRAINT event_watchlist_cadence_chk CHECK (alert_cadence IN ('instant','hourly','daily'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ── 2. Per-event alert email gains a `since` window (instant uses the watermark;
--    callers passing 2 args still resolve via the default). Drop the old 2-arg
--    overload first (a defaulted new param would otherwise be ambiguous). ──────
DROP FUNCTION IF EXISTS public.build_event_alert_email(text, bigint);
CREATE OR REPLACE FUNCTION public.build_event_alert_email(
  p_user_email text, p_event_id bigint, p_since timestamptz DEFAULT now() - interval '24 hours'
) RETURNS TABLE (subject text, html text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_name text; v_rows text; v_n int; v_top text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.event_watchlist
                 WHERE user_email = lower(p_user_email) AND tevo_event_id = p_event_id AND alert_enabled) THEN
    RETURN;
  END IF;
  SELECT name INTO v_name FROM public.events WHERE id = p_event_id;
  v_name := coalesce(v_name, 'Event ' || p_event_id);
  SELECT count(*),
         (ARRAY['critical','warn','info'])[min(CASE lower(a.severity) WHEN 'critical' THEN 1 WHEN 'warn' THEN 2 ELSE 3 END)],
         string_agg(public._alert_email_row(a.severity, a.rule_key, a.message, a.fired_at), '' ORDER BY a.fired_at DESC)
    INTO v_n, v_top, v_rows
  FROM (SELECT severity, rule_key, message, fired_at FROM public.event_alerts
        WHERE tevo_event_id = p_event_id AND fired_at > p_since ORDER BY fired_at DESC LIMIT 20) a;
  IF coalesce(v_n,0) = 0 THEN RETURN; END IF;
  subject := format('S4K Alert · %s · %s', upper(coalesce(v_top,'INFO')), v_name);
  html := public.render_email_html(
    p_heading := v_name,
    p_intro   := format('%s price alert%s on an event you track.', v_n, CASE WHEN v_n=1 THEN '' ELSE 's' END),
    p_body_html := '<table role="presentation" width="100%" cellpadding="0" cellspacing="0">' || v_rows || '</table>',
    p_cta_label := 'View event',
    p_cta_url := 'https://vibepass-terminal-test.onrender.com/event.html?event=' || p_event_id);
  RETURN NEXT;
END;
$$;

-- ── 3. Cross-event summary email (hourly / daily), grouped by event ──────────
CREATE OR REPLACE FUNCTION public.build_user_alert_summary_email(
  p_user_email text, p_cadence text, p_since timestamptz
) RETURNS TABLE (subject text, html text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_body text; v_total int; v_events int; v_label text := CASE p_cadence WHEN 'hourly' THEN 'Hourly' ELSE 'Daily' END;
BEGIN
  WITH ev AS (
    SELECT w.tevo_event_id, coalesce(e.name, w.event_name, 'Event ' || w.tevo_event_id) AS nm
    FROM public.event_watchlist w LEFT JOIN public.events e ON e.id = w.tevo_event_id
    WHERE w.user_email = lower(p_user_email) AND w.alert_enabled AND w.alert_cadence = p_cadence
  ),
  al AS (
    SELECT a.tevo_event_id, count(*) n,
           string_agg(public._alert_email_row(a.severity, a.rule_key, a.message, a.fired_at), '' ORDER BY a.fired_at DESC) rows
    FROM public.event_alerts a JOIN ev ON ev.tevo_event_id = a.tevo_event_id
    WHERE a.fired_at > p_since
    GROUP BY a.tevo_event_id
  )
  SELECT count(*), coalesce(sum(al.n),0)::int,
         string_agg(
           '<div style="margin:18px 0 2px;font-size:15px;color:#fbbf24;font-weight:600;">' || ev.nm || '</div>'
           || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0">' || al.rows || '</table>',
           '' ORDER BY ev.nm)
    INTO v_events, v_total, v_body
  FROM al JOIN ev ON ev.tevo_event_id = al.tevo_event_id;

  IF coalesce(v_events,0) = 0 THEN RETURN; END IF;
  subject := format('S4K %s alert summary · %s alert%s across %s event%s',
                    v_label, v_total, CASE WHEN v_total=1 THEN '' ELSE 's' END,
                    v_events, CASE WHEN v_events=1 THEN '' ELSE 's' END);
  html := public.render_email_html(
    p_heading := v_label || ' alert summary',
    p_intro   := format('%s alert%s across %s tracked event%s in the last %s.',
                        v_total, CASE WHEN v_total=1 THEN '' ELSE 's' END,
                        v_events, CASE WHEN v_events=1 THEN '' ELSE 's' END,
                        CASE p_cadence WHEN 'hourly' THEN 'hour' ELSE '24 hours' END),
    p_body_html := v_body,
    p_cta_label := 'Open watchlist',
    p_cta_url := 'https://vibepass-terminal-test.onrender.com/index.html');
  RETURN NEXT;
END;
$$;

-- ── 4. Dispatchers (cron-driven; server-side, enqueue into exos_mail) ────────
CREATE OR REPLACE FUNCTION public.alert_dispatch_instant()
RETURNS int LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE r record; v_sub text; v_html text; v_max timestamptz; v_since timestamptz; v_cnt int := 0;
BEGIN
  FOR r IN SELECT user_email, tevo_event_id, last_alerted_at FROM public.event_watchlist
           WHERE alert_enabled AND alert_cadence = 'instant'
  LOOP
    v_since := coalesce(r.last_alerted_at, now() - interval '15 min');
    SELECT max(fired_at) INTO v_max FROM public.event_alerts
     WHERE tevo_event_id = r.tevo_event_id AND fired_at > v_since;
    IF v_max IS NULL THEN CONTINUE; END IF;        -- nothing new
    SELECT subject, html INTO v_sub, v_html FROM public.build_event_alert_email(r.user_email, r.tevo_event_id, v_since);
    IF v_html IS NOT NULL THEN
      INSERT INTO public.exos_mail (to_email, template, subject, html)
      VALUES (r.user_email, 'alert-instant', v_sub, v_html);
      v_cnt := v_cnt + 1;
    END IF;
    UPDATE public.event_watchlist SET last_alerted_at = v_max
     WHERE user_email = r.user_email AND tevo_event_id = r.tevo_event_id;
  END LOOP;
  RETURN v_cnt;
END;
$$;

CREATE OR REPLACE FUNCTION public.alert_dispatch_summary(p_cadence text)
RETURNS int LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE r record; v_sub text; v_html text; v_since timestamptz; v_cnt int := 0;
BEGIN
  IF p_cadence NOT IN ('hourly','daily') THEN RAISE EXCEPTION 'bad cadence %', p_cadence; END IF;
  v_since := now() - CASE p_cadence WHEN 'hourly' THEN interval '1 hour' ELSE interval '24 hours' END;
  FOR r IN SELECT DISTINCT user_email FROM public.event_watchlist
           WHERE alert_enabled AND alert_cadence = p_cadence
  LOOP
    SELECT subject, html INTO v_sub, v_html FROM public.build_user_alert_summary_email(r.user_email, p_cadence, v_since);
    IF v_html IS NOT NULL THEN
      INSERT INTO public.exos_mail (to_email, template, subject, html)
      VALUES (r.user_email, 'alert-' || p_cadence, v_sub, v_html);
      v_cnt := v_cnt + 1;
    END IF;
  END LOOP;
  RETURN v_cnt;
END;
$$;

-- ── 5. FE: set per-event cadence + expose cadence in the list ────────────────
CREATE OR REPLACE FUNCTION public.event_watchlist_set_cadence(p_event_id bigint, p_cadence text)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_email text := public._wl_require_email();
BEGIN
  IF p_cadence NOT IN ('instant','hourly','daily') THEN
    RAISE EXCEPTION 'bad cadence %', p_cadence USING ERRCODE = '22023';
  END IF;
  UPDATE public.event_watchlist SET alert_cadence = p_cadence
   WHERE user_email = v_email AND tevo_event_id = p_event_id;
  RETURN p_cadence;
END;
$$;

-- event_watchlist_list now also returns alert_cadence (additive).
CREATE OR REPLACE FUNCTION public.event_watchlist_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE v_email text := public._wl_require_email(); v_rows jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(r ORDER BY (r->>'occurs_at_local') ASC NULLS LAST, (r->>'added_at') DESC), '[]'::jsonb)
    INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'tevo_event_id', w.tevo_event_id,
      'event_name', coalesce(e.name, w.event_name),
      'occurs_at_local', coalesce(e.occurs_at_local, w.occurs_at_local),
      'venue_name', coalesce(e.venue_name, w.venue_name),
      'venue_location', e.venue_location,
      'performer', e.primary_performer_name,
      'alert_enabled', w.alert_enabled,
      'alert_cadence', w.alert_cadence,
      'added_at', w.added_at
    ) AS r
    FROM public.event_watchlist w LEFT JOIN public.events e ON e.id = w.tevo_event_id
    WHERE w.user_email = v_email
  ) q;
  RETURN jsonb_build_object('user_email', v_email, 'count', jsonb_array_length(v_rows), 'items', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION public.build_user_alert_summary_email(text, text, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.alert_dispatch_instant()         FROM PUBLIC;
REVOKE ALL ON FUNCTION public.alert_dispatch_summary(text)     FROM PUBLIC;
REVOKE ALL ON FUNCTION public.event_watchlist_set_cadence(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.event_watchlist_set_cadence(bigint, text) TO authenticated;
-- build_* + dispatch_* stay server-side (cron / service_role only).

-- ── 6. CRON (A1 / operator — gated; run after apply) ─────────────────────────
-- select cron.schedule('alert-dispatch-instant', '*/2 * * * *',
--   $$ select public.alert_dispatch_instant(); $$);
-- select cron.schedule('alert-dispatch-hourly',  '4 * * * *',
--   $$ select public.alert_dispatch_summary('hourly'); $$);
-- select cron.schedule('alert-dispatch-daily',   '0 13 * * *',
--   $$ select public.alert_dispatch_summary('daily'); $$);
-- (Wrap each body with cron_should_fire('<jobname>') + a cron_policy row to
--  match the repo cron convention — PROJECT_BIBLE §7. exos-mail-drain already
--  sends whatever lands in exos_mail.)
