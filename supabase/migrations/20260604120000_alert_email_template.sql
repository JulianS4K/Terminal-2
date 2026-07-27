-- Migration 20260604120000 · lane:D0 (author) → A1 (apply) · writes:build_event_alert_email + preview_event_alert_email · reads:event_watchlist,event_alerts,events · pre:20260603200000 · auth:operator-requested 2026-06-04
--
-- D0 — the ALERT email itself: what a user gets when alerts fire on an event
-- they track. Built on render_email_html (mig 20260603200000) so it matches
-- every other email. build_event_alert_email() is the producer the (gated)
-- firing pipeline will call; preview_event_alert_email() lets the terminal show
-- the exact rendered email in-app (falls back to a sample when there's nothing
-- live, so the template is always reviewable).
--
-- Recipient = the watchlist owner's Google email. Only fires for users who track
-- the event AND have alert_enabled — so muting an event in the watchlist mutes
-- the email too.

-- ── The real alert email for one user + event. Empty (no row) when the user
--    doesn't track it / has alerts muted / there are no recent alerts. ──────────
CREATE OR REPLACE FUNCTION public.build_event_alert_email(p_user_email text, p_event_id bigint)
RETURNS TABLE (subject text, html text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_name text;
  v_rows text;
  v_n    int;
  v_top  text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.event_watchlist
    WHERE user_email = lower(p_user_email) AND tevo_event_id = p_event_id AND alert_enabled
  ) THEN
    RETURN;  -- not tracked / muted → nothing to send
  END IF;

  SELECT name INTO v_name FROM public.events WHERE id = p_event_id;
  v_name := coalesce(v_name, 'Event ' || p_event_id);

  SELECT count(*),
         -- highest-rank severity present, for the subject line
         (ARRAY['critical','warn','info'])[
            min(CASE lower(a.severity) WHEN 'critical' THEN 1 WHEN 'warn' THEN 2 ELSE 3 END)],
         string_agg(public._alert_email_row(a.severity, a.rule_key, a.message, a.fired_at),
                    '' ORDER BY a.fired_at DESC)
    INTO v_n, v_top, v_rows
  FROM (
    SELECT severity, rule_key, message, fired_at
    FROM public.event_alerts
    WHERE tevo_event_id = p_event_id AND fired_at > now() - interval '24 hours'
    ORDER BY fired_at DESC LIMIT 20
  ) a;

  IF coalesce(v_n, 0) = 0 THEN RETURN; END IF;

  subject := format('S4K Alert · %s · %s', upper(coalesce(v_top, 'INFO')), v_name);
  html := public.render_email_html(
    p_heading   := v_name,
    p_intro     := format('%s price alert%s in the last 24h on an event you track.',
                          v_n, CASE WHEN v_n = 1 THEN '' ELSE 's' END),
    p_body_html := '<table role="presentation" width="100%" cellpadding="0" cellspacing="0">'
                   || v_rows || '</table>',
    p_cta_label := 'View event',
    p_cta_url   := 'https://vibepass-terminal-test.onrender.com/event.html?event=' || p_event_id
  );
  RETURN NEXT;
END;
$$;

-- ── One alert row (shared by the real email + the sample preview). Inline styles
--    only (email-safe); message is HTML-escaped. ──────────────────────────────
CREATE OR REPLACE FUNCTION public._alert_email_row(p_sev text, p_rule text, p_msg text, p_at timestamptz)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT '<tr>'
    || '<td style="padding:9px 0;border-bottom:1px solid #1f1f1f;vertical-align:top;">'
    ||   '<span style="display:inline-block;font-size:11px;font-weight:700;padding:1px 7px;border-radius:3px;color:#0a0a0a;background:'
    ||     CASE lower(coalesce(p_sev,'info')) WHEN 'critical' THEN '#ef4444' WHEN 'warn' THEN '#f59e0b' ELSE '#60a5fa' END
    ||   ';">' || upper(coalesce(p_sev, 'INFO')) || '</span> '
    ||   '<span style="font-size:12px;color:#737373;font-family:monospace;">' || coalesce(p_rule, '') || '</span>'
    ||   '<div style="font-size:14px;color:#e5e5e5;margin-top:3px;">'
    ||     replace(replace(replace(coalesce(p_msg, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;') || '</div>'
    || '</td>'
    || '<td style="padding:9px 0;border-bottom:1px solid #1f1f1f;font-size:12px;color:#737373;text-align:right;white-space:nowrap;vertical-align:top;">'
    ||   to_char(p_at, 'Mon DD HH24:MI') || '</td>'
    || '</tr>'
$$;

-- ── In-app preview for the current caller. Shows the real email when there is
--    one; otherwise a sample so the design is always reviewable. ──────────────
CREATE OR REPLACE FUNCTION public.preview_event_alert_email(p_event_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_email text := public._wl_require_email();
  v_sub text; v_html text; v_name text;
BEGIN
  SELECT subject, html INTO v_sub, v_html
  FROM public.build_event_alert_email(v_email, p_event_id);

  IF v_html IS NULL THEN
    SELECT name INTO v_name FROM public.events WHERE id = p_event_id;
    v_name := coalesce(v_name, 'Sample Event');
    v_sub  := format('S4K Alert · WARN · %s', v_name);
    v_html := public.render_email_html(
      p_heading   := v_name,
      p_intro     := '2 price alerts in the last 24h on an event you track.  (Sample — no live alerts for this event yet.)',
      p_body_html := '<table role="presentation" width="100%" cellpadding="0" cellspacing="0">'
        || public._alert_email_row('warn', 'tevo_getin_drop_1h', 'Get-in dropped -19.3% in last hour ($30 → $24)', now() - interval '40 min')
        || public._alert_email_row('info', 'tevo_getin_surge_1h', 'Get-in surged 11.0% in last hour ($23 → $26)', now() - interval '3 hours')
        || '</table>',
      p_cta_label := 'View event',
      p_cta_url   := 'https://vibepass-terminal-test.onrender.com/event.html?event=' || p_event_id
    );
  END IF;

  RETURN jsonb_build_object('subject', v_sub, 'html', v_html, 'is_sample', (v_sub LIKE '%Sample%' OR v_sub IS NULL));
END;
$$;

REVOKE ALL ON FUNCTION public.build_event_alert_email(text, bigint)   FROM PUBLIC;
REVOKE ALL ON FUNCTION public._alert_email_row(text, text, text, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.preview_event_alert_email(bigint)       FROM PUBLIC;
-- build_* / _row are server-side (mailer = service_role). Only the preview is
-- exposed to the signed-in terminal.
GRANT EXECUTE ON FUNCTION public.preview_event_alert_email(bigint) TO authenticated;
