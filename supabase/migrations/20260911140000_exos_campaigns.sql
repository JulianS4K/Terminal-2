-- ============================================================================
-- Migration 20260911140000 — Exos (Bridge / D4): organizer email campaigns
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_campaigns (NEW), exos_campaign_recipients (NEW),
--           exos_marketing_optouts (NEW),
--           exos_mail (W: template allowlist +'campaign'; INSERT rows),
--           exos_tickets (R), exos_events (R), exos_org_follows (R),
--           exos_waitlist (R), auth.users (R),
--           exos_campaign_save / exos_campaign_cancel / exos_campaign_send /
--           exos_campaign_audience_count (new, staff RPCs),
--           exos_marketing_optout (new, anon-callable by token),
--           exos_send_scheduled_campaigns (new, cron / service_role),
--           cron.schedule (exos_send_scheduled_campaigns, when pg_cron present)
-- Pre-reqs: 20260520160000 (exos_mail), 20260520140000 (exos_org_follows),
--           20260616180000 (exos_waitlist), 20260911051000 (11-value template
--           allowlist — rebuilt here as the full union + 'campaign'),
--           20260515250000 (cron_should_fire)
--
-- Stage 5 (organizer side) item 1 — "text and email campaigns". Announcements
-- reach the holders of ONE event, immediately, with no audience choice and no
-- opt-out. A campaign is the marketing counterpart:
--
--   * Audience segments, resolved SERVER-SIDE at send time (never a client
--     list — no open relay):
--       holders         non-voided ticket holders of the event
--       no_shows        holders whose ticket is still 'active' after start
--       waitlist        waiting / notified / offered joiners of the event
--       followers       the org's followers
--       past_attendees  anyone scanned in at any of the org's events
--       all_buyers      anyone holding a non-voided ticket at any org event
--     Optionally intersected with a second event ("holders of X who also…")
--     is NOT in v1; audience jsonb = {"kind": <one of the above>}.
--   * Opt-out: every campaign mail carries an unsubscribe link with a
--     per-recipient token; exos_marketing_optout(token) (anon-callable) records
--     (org, email) and every later audience resolution excludes it. Opt-outs
--     are per ORG (the sender), not platform-wide — transactional mail
--     (tickets, reminders, transfers) is never affected.
--   * Send now or schedule: status draft → scheduled → sending → sent
--     (or cancelled / failed). The cron claims due rows atomically.
--   * SMS: `channel = 'sms'` is accepted at save time so the organizer can draft,
--     but exos_campaign_send refuses it until a provider is configured
--     (operator decision pending — no vault secret, no client). Nothing is
--     silently dropped: the refusal text says exactly that.
--   * Body is plain text (organizer-supplied), tag-escaped, newlines → <br>.
--     Event name / org name are server-derived. The public base URL for the
--     unsubscribe link is supplied by the client (its own origin + /bridge),
--     validated https, ≤ 200 chars, and stored on the campaign row — only
--     owner/manager can send, and they can already put any link in the body.
--
-- ROLLBACK: cron.unschedule('exos_send_scheduled_campaigns'); DROP FUNCTION
--   exos_send_scheduled_campaigns(), exos_campaign_send(uuid,text),
--   exos_campaign_cancel(uuid), exos_campaign_save(uuid,uuid,uuid,text,text,jsonb,text,text,timestamptz),
--   exos_campaign_audience_count(uuid,uuid,jsonb), exos_marketing_optout(uuid),
--   _exos_campaign_audience(uuid,uuid,jsonb), _exos_campaign_send_core(uuid);
--   DROP TABLE exos_campaign_recipients, exos_campaigns, exos_marketing_optouts;
--   re-add the 20260911051000 template CHECK.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_marketing_optouts (
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  email      text NOT NULL CHECK (email = lower(email)),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, email)
);
ALTER TABLE public.exos_marketing_optouts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_marketing_optouts FROM anon, authenticated;
-- No client policies: written only by exos_marketing_optout(); read only inside
-- audience resolution. Staff see the effect as a smaller audience count.

CREATE TABLE IF NOT EXISTS public.exos_campaigns (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id        uuid REFERENCES public.exos_events (id) ON DELETE CASCADE,
  name            text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
  channel         text NOT NULL DEFAULT 'email' CHECK (channel IN ('email','sms')),
  audience        jsonb NOT NULL DEFAULT '{"kind":"holders"}'::jsonb,
  subject         text NOT NULL CHECK (char_length(subject) BETWEEN 1 AND 160),
  body            text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 4000),
  base_url        text CHECK (base_url IS NULL OR (base_url ~ '^https://' AND char_length(base_url) <= 200)),
  status          text NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft','scheduled','sending','sent','cancelled','failed')),
  scheduled_at    timestamptz,
  sent_at         timestamptz,
  recipient_count integer NOT NULL DEFAULT 0 CHECK (recipient_count >= 0),
  error           text,
  created_by      uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_campaigns_org_idx   ON public.exos_campaigns (org_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_campaigns_event_idx ON public.exos_campaigns (event_id, created_at DESC);
CREATE INDEX IF NOT EXISTS exos_campaigns_due_idx   ON public.exos_campaigns (scheduled_at)
  WHERE status = 'scheduled';
COMMENT ON TABLE public.exos_campaigns IS
  'D4 mig 20260911140000: organizer marketing campaign (email; sms modeled, send gated). Audience resolved server-side at send; opt-outs honoured per org.';

ALTER TABLE public.exos_campaigns ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_campaigns_sel ON public.exos_campaigns;
CREATE POLICY exos_campaigns_sel ON public.exos_campaigns FOR SELECT TO authenticated
  USING (exos_is_admin() OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','content']));
REVOKE ALL ON public.exos_campaigns FROM anon, authenticated;
GRANT SELECT ON public.exos_campaigns TO authenticated;

CREATE TABLE IF NOT EXISTS public.exos_campaign_recipients (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL REFERENCES public.exos_campaigns (id) ON DELETE CASCADE,
  org_id      uuid NOT NULL,
  email       text NOT NULL,
  user_id     uuid,
  token       uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  mail_id     uuid,
  status      text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','optout')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (campaign_id, email)
);
CREATE INDEX IF NOT EXISTS exos_campaign_recipients_campaign_idx ON public.exos_campaign_recipients (campaign_id);
ALTER TABLE public.exos_campaign_recipients ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_campaign_recipients FROM anon, authenticated;
-- No client policies: recipient emails are PII; the campaign row carries the count.

-- ---------------------------------------------------------------------------
-- 2. Template allowlist — full union + 'campaign'.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check CHECK (template IN (
  'transfer-initiated','transfer-claimed','org-invite',
  'event-cancelled','event-updated',
  'event-announce','ticket-issued','waitlist-open',
  'event-announcement','event-rescheduled',
  'event-reminder','campaign'));

-- ---------------------------------------------------------------------------
-- 3. Audience resolution (internal). Distinct lowercased emails, opt-outs
--    removed. p_event_id may be NULL for org-level kinds.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_campaign_audience(
  p_org_id uuid, p_event_id uuid, p_audience jsonb
) RETURNS TABLE (email text, user_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_kind text := coalesce(p_audience ->> 'kind', 'holders');
BEGIN
  IF v_kind IN ('holders','no_shows','waitlist') AND p_event_id IS NULL THEN
    RAISE EXCEPTION '_exos_campaign_audience: audience % needs an event', v_kind;
  END IF;
  IF v_kind NOT IN ('holders','no_shows','waitlist','followers','past_attendees','all_buyers') THEN
    RAISE EXCEPTION '_exos_campaign_audience: unknown audience kind %', v_kind;
  END IF;

  RETURN QUERY
  WITH raw AS (
    -- holders: non-voided holders of the event
    SELECT lower(u.email) AS email, u.id AS user_id
      FROM public.exos_tickets t JOIN auth.users u ON u.id = t.owner_id
     WHERE v_kind = 'holders' AND t.event_id = p_event_id AND t.status <> 'voided'
    UNION
    -- no_shows: still 'active' (never scanned) once the event has started
    SELECT lower(u.email), u.id
      FROM public.exos_tickets t
      JOIN public.exos_events e ON e.id = t.event_id
      JOIN auth.users u ON u.id = t.owner_id
     WHERE v_kind = 'no_shows' AND t.event_id = p_event_id AND t.status = 'active'
       AND e.starts_at IS NOT NULL AND e.starts_at <= now()
    UNION
    -- waitlist: anyone still hoping for a seat
    SELECT lower(w.email), w.user_id
      FROM public.exos_waitlist w
     WHERE v_kind = 'waitlist' AND w.event_id = p_event_id
       AND w.status IN ('waiting','notified','offered')
    UNION
    -- followers of the org
    SELECT lower(u.email), u.id
      FROM public.exos_org_follows f JOIN auth.users u ON u.id = f.follower_uid
     WHERE v_kind = 'followers' AND f.org_id = p_org_id
    UNION
    -- past_attendees: scanned in at any org event
    SELECT lower(u.email), u.id
      FROM public.exos_tickets t JOIN auth.users u ON u.id = t.owner_id
     WHERE v_kind = 'past_attendees' AND t.org_id = p_org_id AND t.status = 'used'
    UNION
    -- all_buyers: any non-voided ticket at any org event
    SELECT lower(u.email), u.id
      FROM public.exos_tickets t JOIN auth.users u ON u.id = t.owner_id
     WHERE v_kind = 'all_buyers' AND t.org_id = p_org_id AND t.status <> 'voided'
  )
  SELECT DISTINCT ON (r.email) r.email, r.user_id
    FROM raw r
   WHERE r.email IS NOT NULL AND r.email <> ''
     AND NOT EXISTS (SELECT 1 FROM public.exos_marketing_optouts o
                      WHERE o.org_id = p_org_id AND o.email = r.email)
   ORDER BY r.email, r.user_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_campaign_audience(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_campaign_audience(uuid, uuid, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Staff: audience preview count.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_campaign_audience_count(
  p_org_id uuid, p_event_id uuid DEFAULT NULL, p_audience jsonb DEFAULT '{"kind":"holders"}'::jsonb
) RETURNS int
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_campaign_audience_count: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(p_org_id, ARRAY['owner','manager','content'])) THEN
    RAISE EXCEPTION 'exos_campaign_audience_count: not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_event_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_events WHERE id = p_event_id AND org_id = p_org_id) THEN
    RAISE EXCEPTION 'exos_campaign_audience_count: event not in this org';
  END IF;
  SELECT count(*) INTO v_n FROM public._exos_campaign_audience(p_org_id, p_event_id, p_audience);
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_campaign_audience_count(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_campaign_audience_count(uuid, uuid, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Staff: save (create / update a draft or schedule), cancel.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_campaign_save(
  p_id           uuid,
  p_org_id       uuid,
  p_event_id     uuid,
  p_name         text,
  p_channel      text,
  p_audience     jsonb,
  p_subject      text,
  p_body         text,
  p_scheduled_at timestamptz DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_id     uuid := p_id;
  v_status text;
  v_cur    text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_campaign_save: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(p_org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_campaign_save: not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_channel NOT IN ('email','sms') THEN
    RAISE EXCEPTION 'exos_campaign_save: channel must be email or sms';
  END IF;
  IF p_event_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_events WHERE id = p_event_id AND org_id = p_org_id) THEN
    RAISE EXCEPTION 'exos_campaign_save: event not in this org';
  END IF;
  -- Validate the audience shape now so a bad kind fails at save, not at send.
  PERFORM 1 FROM public._exos_campaign_audience(p_org_id, p_event_id, coalesce(p_audience, '{"kind":"holders"}'::jsonb)) LIMIT 0;

  IF p_scheduled_at IS NOT NULL AND p_scheduled_at <= now() THEN
    RAISE EXCEPTION 'exos_campaign_save: scheduled time must be in the future';
  END IF;
  v_status := CASE WHEN p_scheduled_at IS NULL THEN 'draft' ELSE 'scheduled' END;

  IF v_id IS NULL THEN
    INSERT INTO public.exos_campaigns (org_id, event_id, name, channel, audience, subject, body, status, scheduled_at, created_by)
    VALUES (p_org_id, p_event_id, btrim(p_name), p_channel, coalesce(p_audience, '{"kind":"holders"}'::jsonb),
            btrim(p_subject), btrim(p_body), v_status, p_scheduled_at, v_uid)
    RETURNING id INTO v_id;
  ELSE
    SELECT status INTO v_cur FROM public.exos_campaigns WHERE id = v_id AND org_id = p_org_id FOR UPDATE;
    IF v_cur IS NULL THEN
      RAISE EXCEPTION 'exos_campaign_save: campaign not found';
    END IF;
    IF v_cur NOT IN ('draft','scheduled') THEN
      RAISE EXCEPTION 'exos_campaign_save: campaign is % — only drafts and scheduled campaigns can be edited', v_cur;
    END IF;
    UPDATE public.exos_campaigns
       SET event_id = p_event_id, name = btrim(p_name), channel = p_channel,
           audience = coalesce(p_audience, audience), subject = btrim(p_subject), body = btrim(p_body),
           status = v_status, scheduled_at = p_scheduled_at, updated_at = now()
     WHERE id = v_id;
  END IF;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_campaign_save(uuid, uuid, uuid, text, text, jsonb, text, text, timestamptz) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_campaign_save(uuid, uuid, uuid, text, text, jsonb, text, text, timestamptz) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_campaign_cancel(p_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid; v_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_campaign_cancel: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id, status INTO v_org, v_status FROM public.exos_campaigns WHERE id = p_id FOR UPDATE;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_campaign_cancel: campaign not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_campaign_cancel: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_status NOT IN ('draft','scheduled') THEN
    RAISE EXCEPTION 'exos_campaign_cancel: campaign is % — cannot cancel', v_status;
  END IF;
  UPDATE public.exos_campaigns SET status = 'cancelled', updated_at = now() WHERE id = p_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_campaign_cancel(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_campaign_cancel(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Send core (internal). Caller has already claimed the row as 'sending'.
--    Resolves the audience, writes recipient rows (token per recipient), queues
--    one exos_mail per recipient with the unsubscribe footer. Returns the count.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_campaign_send_core(p_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c          public.exos_campaigns%ROWTYPE;
  v_org_name text;
  v_ev_name  text;
  v_safe_org text;
  v_safe_ev  text;
  v_safe_bod text;
  v_subj     text;
  v_html     text;
  v_n        int := 0;
  r          record;
  v_mail     uuid;
BEGIN
  SELECT * INTO c FROM public.exos_campaigns WHERE id = p_id;
  IF c.id IS NULL THEN RETURN 0; END IF;
  IF c.channel <> 'email' THEN
    RAISE EXCEPTION 'SMS sending is not configured yet — this campaign was saved but not sent. Email campaigns send today; SMS needs an operator-configured provider.';
  END IF;

  SELECT name INTO v_org_name FROM public.exos_orgs WHERE id = c.org_id;
  IF c.event_id IS NOT NULL THEN
    SELECT name INTO v_ev_name FROM public.exos_events WHERE id = c.event_id;
  END IF;
  v_safe_org := replace(replace(coalesce(v_org_name, 'the organizer'), '<', '&lt;'), '>', '&gt;');
  v_safe_ev  := replace(replace(coalesce(v_ev_name, ''), '<', '&lt;'), '>', '&gt;');
  v_safe_bod := replace(replace(replace(c.body, '<', '&lt;'), '>', '&gt;'), chr(10), '<br>');
  v_subj     := left(c.subject, 200);

  FOR r IN SELECT a.email, a.user_id FROM public._exos_campaign_audience(c.org_id, c.event_id, c.audience) a LOOP
    INSERT INTO public.exos_campaign_recipients (campaign_id, org_id, email, user_id)
    VALUES (p_id, c.org_id, r.email, r.user_id)
    ON CONFLICT (campaign_id, email) DO NOTHING
    RETURNING id INTO v_mail;  -- reuse var: recipient id (NULL when re-run)
    IF v_mail IS NULL THEN CONTINUE; END IF;

    v_html := (CASE WHEN v_safe_ev <> '' THEN '<p style="color:#888;font-size:12px">' || v_safe_ev || '</p>' ELSE '' END)
           || '<p>' || v_safe_bod || '</p>'
           || '<p style="color:#888;font-size:12px">Sent by ' || v_safe_org || ' via Bridge.'
           || CASE WHEN c.base_url IS NOT NULL
                   THEN ' <a href="' || c.base_url || '/unsubscribe/' ||
                        (SELECT token FROM public.exos_campaign_recipients WHERE id = v_mail)::text ||
                        '">Unsubscribe from ' || v_safe_org || ' emails</a>.'
                   ELSE ' To stop these emails, open the Bridge app and unfollow the organizer.'
              END
           || '</p>';

    INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
    VALUES ('campaign', r.email, v_subj, v_html, c.created_by, 'pending')
    RETURNING id INTO v_mail;
    UPDATE public.exos_campaign_recipients SET mail_id = v_mail
     WHERE campaign_id = p_id AND email = r.email;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_campaign_send_core(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._exos_campaign_send_core(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Staff: send now.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_campaign_send(p_id uuid, p_base_url text DEFAULT NULL)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid; v_status text; v_channel text; v_n int; v_base text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_campaign_send: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id, status, channel INTO v_org, v_status, v_channel FROM public.exos_campaigns WHERE id = p_id FOR UPDATE;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_campaign_send: campaign not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_campaign_send: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_status NOT IN ('draft','scheduled') THEN
    RAISE EXCEPTION 'exos_campaign_send: campaign is % — already sent or cancelled', v_status;
  END IF;
  -- Refuse BEFORE claiming the row: a RAISE out of this function rolls back any
  -- status write made here, so the campaign simply stays a draft (the cron path
  -- catches and records 'failed' itself, since it does not re-raise).
  IF v_channel <> 'email' THEN
    RAISE EXCEPTION 'SMS sending is not configured yet — this campaign was saved but not sent. Email campaigns send today; SMS needs an operator-configured provider.';
  END IF;
  v_base := nullif(rtrim(btrim(coalesce(p_base_url, '')), '/'), '');
  IF v_base IS NOT NULL AND (v_base !~ '^https://[^/?#\s]+(/[^?#\s]*)?$' OR char_length(v_base) > 200) THEN
    RAISE EXCEPTION 'exos_campaign_send: base url must be a plain https origin/path';
  END IF;

  UPDATE public.exos_campaigns
     SET status = 'sending', base_url = coalesce(v_base, base_url), updated_at = now()
   WHERE id = p_id;
  -- Any error inside the core propagates and unwinds the 'sending' claim above.
  v_n := public._exos_campaign_send_core(p_id);
  UPDATE public.exos_campaigns
     SET status = 'sent', sent_at = now(), recipient_count = v_n, updated_at = now()
   WHERE id = p_id;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_campaign_send(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_campaign_send(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. Cron: claim due scheduled campaigns and send them. 20s wall-clock budget.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_send_scheduled_campaigns()
RETURNS TABLE (campaigns_sent int, mails_queued int, campaigns_failed int)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_start timestamptz := clock_timestamp(); v_id uuid; v_n int;
        v_sent int := 0; v_mails int := 0; v_failed int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_send_scheduled_campaigns: service role only' USING ERRCODE = '42501';
  END IF;
  IF NOT public.cron_should_fire('exos_send_scheduled_campaigns') THEN
    RETURN QUERY SELECT 0, 0, 0; RETURN;
  END IF;
  FOR v_id IN
    UPDATE public.exos_campaigns
       SET status = 'sending', updated_at = now()
     WHERE status = 'scheduled' AND scheduled_at IS NOT NULL AND scheduled_at <= now()
    RETURNING id
  LOOP
    BEGIN
      v_n := public._exos_campaign_send_core(v_id);
      UPDATE public.exos_campaigns
         SET status = 'sent', sent_at = now(), recipient_count = v_n, updated_at = now()
       WHERE id = v_id;
      v_sent := v_sent + 1; v_mails := v_mails + v_n;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.exos_campaigns SET status = 'failed', error = left(SQLERRM, 500), updated_at = now() WHERE id = v_id;
      v_failed := v_failed + 1;
    END;
    EXIT WHEN clock_timestamp() - v_start > interval '20 seconds';
  END LOOP;
  RETURN QUERY SELECT v_sent, v_mails, v_failed;
END $$;
REVOKE ALL ON FUNCTION public.exos_send_scheduled_campaigns() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_send_scheduled_campaigns() TO service_role;

-- ---------------------------------------------------------------------------
-- 9. Opt-out by token (anon-callable — the link is in an email). Idempotent.
--    Returns the masked email so the page can confirm without leaking it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_marketing_optout(p_token uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid; v_email text;
BEGIN
  SELECT org_id, email INTO v_org, v_email FROM public.exos_campaign_recipients WHERE token = p_token;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_marketing_optout: unknown or expired link';
  END IF;
  INSERT INTO public.exos_marketing_optouts (org_id, email) VALUES (v_org, v_email)
  ON CONFLICT DO NOTHING;
  RETURN left(v_email, 2) || '…@' || split_part(v_email, '@', 2);
END $$;
REVOKE ALL ON FUNCTION public.exos_marketing_optout(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_marketing_optout(uuid) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 10. Cron. Guarded so CI Postgres without pg_cron applies.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos_send_scheduled_campaigns') THEN
      PERFORM cron.unschedule('exos_send_scheduled_campaigns');
    END IF;
    PERFORM cron.schedule('exos_send_scheduled_campaigns', '9,24,39,54 * * * *',
                          $cron$SELECT * FROM public.exos_send_scheduled_campaigns();$cron$);
  END IF;
END $$;
