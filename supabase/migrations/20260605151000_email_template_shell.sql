-- Migration 20260603200000 · lane:D0 (author) → A1 (apply) · writes:render_email_html + build_watchlist_alert_email · reads:event_watchlist,events · pre:20260603190000 · auth:operator-requested 2026-06-03
--
-- D0 — ONE consistent, email-client-safe HTML shell for every outbound email, so
-- our mail stops being a grab-bag of bare <p> snippets (the exos templates each
-- hand-roll their own body). render_email_html() wraps any body content in a
-- shared 600px table-based layout with inline styles (Gmail/Outlook-safe): a
-- branded header, a heading, the body, an optional CTA button, and a footer.
--
-- build_watchlist_alert_email() uses the shell to format a user's tracked-event
-- alert digest — the recipient is the Google-OAuth email captured in
-- event_watchlist (see mig 20260603190000). This is the TEMPLATE/BUILDER; the
-- firing pipeline (queue into exos_mail → exos-mail-drain, cron-driven) is the
-- remaining operator/A1-gated wiring step (cron.* + edge deploy are gated).
-- exos_queue_mail (D4) can adopt render_email_html for consistency in a D4 PR.

-- ── Reusable email shell. Inline styles only; no <style>/external CSS (stripped
--    by most clients). Table layout for Outlook. p_cta_* optional (NULL = no button).
CREATE OR REPLACE FUNCTION public.render_email_html(
  p_heading   text,
  p_intro     text DEFAULT NULL,
  p_body_html text DEFAULT '',
  p_cta_label text DEFAULT NULL,
  p_cta_url   text DEFAULT NULL
) RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT
  '<!doctype html><html><head><meta charset="utf-8">'
  || '<meta name="viewport" content="width=device-width,initial-scale=1">'
  || '<title>' || coalesce(p_heading, 'S4K Terminal') || '</title></head>'
  || '<body style="margin:0;padding:0;background:#0a0a0a;'
  ||   'font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">'
  || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" '
  ||   'style="background:#0a0a0a;padding:24px 12px;"><tr><td align="center">'
  || '<table role="presentation" width="600" cellpadding="0" cellspacing="0" '
  ||   'style="max-width:600px;width:100%;background:#141414;border:1px solid #2a2a2a;border-radius:8px;overflow:hidden;">'
  -- header bar
  || '<tr><td style="background:#141414;border-bottom:1px solid #2a2a2a;padding:16px 24px;">'
  ||   '<span style="font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px;'
  ||   'letter-spacing:1px;color:#fbbf24;font-weight:600;">TERMINAL &middot; S4K</span></td></tr>'
  -- heading + intro
  || '<tr><td style="padding:24px 24px 8px;">'
  ||   '<h1 style="margin:0 0 6px;font-size:18px;line-height:1.3;color:#e5e5e5;">'
  ||     coalesce(p_heading, '') || '</h1>'
  ||   coalesce('<p style="margin:0;font-size:14px;line-height:1.5;color:#a3a3a3;">' || p_intro || '</p>', '')
  || '</td></tr>'
  -- body
  || '<tr><td style="padding:8px 24px 4px;font-size:14px;line-height:1.5;color:#d4d4d4;">'
  ||   coalesce(p_body_html, '') || '</td></tr>'
  -- optional CTA
  || coalesce(
       '<tr><td style="padding:16px 24px 24px;">'
       || '<a href="' || p_cta_url || '" '
       || 'style="display:inline-block;background:#fbbf24;color:#0a0a0a;text-decoration:none;'
       || 'font-weight:600;font-size:14px;padding:10px 20px;border-radius:6px;">'
       || coalesce(p_cta_label, 'Open Terminal') || '</a></td></tr>',
       '')
  -- footer
  || '<tr><td style="padding:16px 24px;border-top:1px solid #1f1f1f;'
  ||   'font-size:12px;line-height:1.5;color:#737373;">'
  ||   'You are receiving this because you track events on the S4K Terminal. '
  ||   'Manage or mute alerts from your watchlist on the home screen.'
  || '</td></tr>'
  || '</table></td></tr></table></body></html>'
$$;

-- ── Format a user's tracked-event alert digest using the shared shell.
--    Returns (subject, html). The recipient is p_user_email (the watchlist owner
--    / Google-OAuth email). Only alert-enabled rows are included.
CREATE OR REPLACE FUNCTION public.build_watchlist_alert_email(p_user_email text)
RETURNS TABLE (subject text, html text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rows_html text;
  v_n         int;
BEGIN
  SELECT count(*),
         string_agg(
           '<tr>'
           || '<td style="padding:8px 0;border-bottom:1px solid #1f1f1f;font-size:14px;color:#e5e5e5;">'
           ||   coalesce(e.name, w.event_name, 'Event ' || w.tevo_event_id)
           ||   coalesce('<br><span style="font-size:12px;color:#737373;">'
           ||     coalesce(e.venue_name, w.venue_name, '') || '</span>', '')
           || '</td>'
           || '<td style="padding:8px 0;border-bottom:1px solid #1f1f1f;font-size:13px;color:#a3a3a3;'
           ||   'text-align:right;white-space:nowrap;">'
           ||   coalesce(
                  to_char((coalesce(e.occurs_at_local, w.occurs_at_local))::timestamptz, 'Mon DD, HH24:MI'),
                  coalesce(e.occurs_at_local, w.occurs_at_local, '—')
                )
           || '</td></tr>',
           '' ORDER BY coalesce(e.occurs_at_local, w.occurs_at_local) ASC NULLS LAST)
    INTO v_n, v_rows_html
  FROM public.event_watchlist w
  LEFT JOIN public.events e ON e.id = w.tevo_event_id
  WHERE w.user_email = lower(p_user_email) AND w.alert_enabled;

  IF coalesce(v_n, 0) = 0 THEN
    RETURN;  -- nothing to send
  END IF;

  subject := format('S4K Terminal · %s tracked event%s update', v_n, CASE WHEN v_n = 1 THEN '' ELSE 's' END);
  html := public.render_email_html(
    p_heading   := format('%s tracked event%s', v_n, CASE WHEN v_n = 1 THEN '' ELSE 's' END),
    p_intro     := 'Here is the latest on the events you''re tracking.',
    p_body_html := '<table role="presentation" width="100%" cellpadding="0" cellspacing="0">'
                   || v_rows_html || '</table>',
    p_cta_label := 'Open watchlist',
    p_cta_url   := 'https://vibepass-terminal-test.onrender.com/terminal/index.html'
  );
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.render_email_html(text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.build_watchlist_alert_email(text)               FROM PUBLIC;
-- Server-side only (mailer runs as service_role); no anon/authenticated grant.
