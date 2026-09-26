-- ============================================================================
-- Migration 20260926060000 — Exos (Bridge / D4): abandoned-checkout reminder
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_checkout_reminders (new), exos_mail_prefs (new),
--              exos_orgs (+checkout_reminders_enabled),
--              exos_mail (+list_unsubscribe; template allowlist +'checkout-abandoned'),
--              FUNCTION exos_send_checkout_reminders (new, cron / service_role),
--              FUNCTION exos_mail_unsubscribe (new, anon + authenticated),
--              FUNCTION exos_set_marketing_emails (new, authenticated),
--              cron.schedule (exos_send_checkout_reminders, when pg_cron present)
--           R: exos_checkout_sessions, exos_events, exos_ticket_tiers,
--              exos_event_addons, exos_tickets, auth.users,
--              exos_effective_available()
-- Pre-reqs: 20260702123100 (exos_checkout_sessions), 20260702123030 (quotas /
--           exos_effective_available), 20260911070000 (reminder cron pattern),
--           20260925010000 (last exos_mail template allowlist),
--           20260926010000 (account deletion clears buyer_email)
--
-- A buyer who opens Stripe Checkout and walks away gets ONE mail ("still want
-- tickets?") with a link that refills the cart. Once per buyer per event, ever.
--
-- Who gets it (all must hold; exos_send_checkout_reminders):
--   * the buyer's LATEST checkout session for the event is 'expired' (Stripe
--     checkout.session.expired, marked by stripe-webhook) and was created
--     between p_max_age (24h) and p_min_age (1h) ago. Sessions expire 30 min
--     after creation, so this is "expired at least ~30 min ago, at most a day";
--   * the event is published and hasn't started; the tier is public and inside
--     its sales window; exos_effective_available says it still has a seat;
--   * the buyer's auth email is confirmed, and the session still carries a
--     buyer_email (account deletion NULLs it, so closed accounts drop out);
--   * the buyer holds / bought no live ticket for the event since that session,
--     and has no newer session for it (paid, pending or expired);
--   * the org hasn't turned reminders off (exos_orgs.checkout_reminders_enabled,
--     default on) and the buyer hasn't unsubscribed (exos_mail_prefs);
--   * no reminder was ever recorded for (buyer, event) — exos_checkout_reminders
--     PK is the once-only gate, claimed with ON CONFLICT DO NOTHING.
--
-- The link uses the SPA's checkout-link format (src/lib/checkoutLink.ts):
--   {{app_url}}/checkout?event=<id>&products=<tier>:<qty>,<addon>:<qty>&promoter=…&utm_*
-- SQL doesn't know the app's public URL, so the body carries the literal
-- {{app_url}} placeholder and exos-mail-drain fills it from EXOS_APP_URL.
-- Every reminder has an unsubscribe link ({{app_url}}/unsubscribe?t=<token>)
-- in the body and in exos_mail.list_unsubscribe (sent as List-Unsubscribe).
-- The opt-out only covers this kind of mail; tickets, transfers and event
-- changes are transactional and always sent.
--
-- Template allowlist: rebuilt as the union of whatever the live CHECK holds
-- plus the last known list (20260925010000) plus 'checkout-abandoned', so no
-- existing value is ever dropped whichever order migrations land in.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ROLLBACK: cron.unschedule('exos_send_checkout_reminders'); DROP FUNCTION
--   exos_send_checkout_reminders(interval, interval, int), exos_mail_unsubscribe(text),
--   exos_set_marketing_emails(boolean); DROP TABLE exos_checkout_reminders,
--   exos_mail_prefs; ALTER TABLE exos_orgs DROP COLUMN checkout_reminders_enabled;
--   ALTER TABLE exos_mail DROP COLUMN list_unsubscribe (template value may stay).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Org toggle (owner-writable through the existing exos_orgs_upd RLS).
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_orgs
  ADD COLUMN IF NOT EXISTS checkout_reminders_enabled boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN public.exos_orgs.checkout_reminders_enabled IS
  'Send buyers one "finish your order" mail after an abandoned checkout (exos_send_checkout_reminders). Default on.';

-- ---------------------------------------------------------------------------
-- 2. Per-user marketing opt-out + unsubscribe token.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_mail_prefs (
  user_id           uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  marketing_opt_out boolean NOT NULL DEFAULT false,
  unsubscribe_token text NOT NULL UNIQUE
    DEFAULT replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
    CHECK (unsubscribe_token ~ '^[0-9a-f]{64}$'),
  opted_out_at      timestamptz,
  updated_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.exos_mail_prefs IS
  'Per-user opt-out from non-transactional Exos mail (today: checkout-abandoned). Token backs the unsubscribe link.';
ALTER TABLE public.exos_mail_prefs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_mail_prefs FROM PUBLIC, anon, authenticated;
GRANT SELECT (user_id, marketing_opt_out, opted_out_at, updated_at) ON public.exos_mail_prefs TO authenticated;
GRANT ALL ON public.exos_mail_prefs TO service_role;
DROP POLICY IF EXISTS exos_mail_prefs_sel_own ON public.exos_mail_prefs;
CREATE POLICY exos_mail_prefs_sel_own ON public.exos_mail_prefs FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- ---------------------------------------------------------------------------
-- 3. Once-only ledger: one row per (buyer, event), forever.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_checkout_reminders (
  buyer_uid  uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  event_id   uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  session_id text NOT NULL,
  mail_id    uuid,
  sent_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (buyer_uid, event_id)
);
COMMENT ON TABLE public.exos_checkout_reminders IS
  'Abandoned-checkout reminders already queued. The PK is the once-per-buyer-per-event gate.';
ALTER TABLE public.exos_checkout_reminders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_checkout_reminders FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_checkout_reminders TO service_role;
CREATE INDEX IF NOT EXISTS exos_checkout_reminders_event_idx ON public.exos_checkout_reminders (event_id);

-- Prod's default privileges also hand new tables to the read-only analytics roles.
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly','analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH t IN ARRAY ARRAY['exos_mail_prefs','exos_checkout_reminders'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END LOOP;
    END IF;
  END LOOP;
END $$;

-- Scan support: expired sessions by age, and "newer session for this buyer+event".
CREATE INDEX IF NOT EXISTS exos_checkout_sessions_expired_idx
  ON public.exos_checkout_sessions (created_at) WHERE status = 'expired';
CREATE INDEX IF NOT EXISTS exos_checkout_sessions_buyer_event_idx
  ON public.exos_checkout_sessions (buyer_uid, event_id, created_at);

-- ---------------------------------------------------------------------------
-- 4. exos_mail: List-Unsubscribe target + template allowlist.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_mail ADD COLUMN IF NOT EXISTS list_unsubscribe text
  CHECK (list_unsubscribe IS NULL OR length(list_unsubscribe) <= 500);
COMMENT ON COLUMN public.exos_mail.list_unsubscribe IS
  'Unsubscribe URL (may start with {{app_url}}); exos-mail-drain sends it as the List-Unsubscribe header.';

DO $$
DECLARE
  v_def  text;
  v_live text[];
  v_vals text[];
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
   WHERE c.conrelid = 'public.exos_mail'::regclass AND c.conname = 'exos_mail_template_check';
  -- The live list, however it was written: IN (...) / ARRAY[...] render as
  -- quoted literals ('a'::text); an array literal renders as '{a,b}'.
  IF strpos(coalesce(v_def, ''), '''{') > 0 THEN
    v_live := string_to_array(substring(v_def FROM '''\{([^}]*)\}'''), ',');
  ELSE
    SELECT array_agg(m[1]) INTO v_live
      FROM regexp_matches(coalesce(v_def, ''), '''([^'']+)''', 'g') AS m;
  END IF;
  IF 'checkout-abandoned' = ANY (coalesce(v_live, '{}'::text[])) THEN
    RETURN;  -- already allowed; leave the live list alone
  END IF;
  SELECT array_agg(DISTINCT x ORDER BY x) INTO v_vals FROM (
    SELECT btrim(unnest(coalesce(v_live, '{}'::text[])), ' "') AS x
    UNION
    SELECT unnest(ARRAY[
      'transfer-initiated','transfer-claimed','org-invite','event-cancelled','event-updated',
      'event-announce','ticket-issued','waitlist-open','event-announcement','event-rescheduled',
      'event-reminder','order-failed','checkout-abandoned'])
  ) u WHERE x <> '';
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  EXECUTE format('ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check '
                 'CHECK (template = ANY (ARRAY[%s]))',
                 (SELECT string_agg(quote_literal(x), ',' ORDER BY x) FROM unnest(v_vals) x));
END $$;

-- ---------------------------------------------------------------------------
-- 5. Unsubscribe by token (the mail link; the buyer may be signed out).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_mail_unsubscribe(p_token text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_n int;
BEGIN
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{64}$' THEN
    RETURN false;
  END IF;
  UPDATE public.exos_mail_prefs
     SET marketing_opt_out = true,
         opted_out_at      = coalesce(opted_out_at, now()),
         updated_at        = now()
   WHERE unsubscribe_token = p_token;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END $$;
REVOKE ALL ON FUNCTION public.exos_mail_unsubscribe(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_mail_unsubscribe(text) TO anon, authenticated, service_role;

-- Signed-in self service (profile toggle): true = receive, false = opt out.
CREATE OR REPLACE FUNCTION public.exos_set_marketing_emails(p_enabled boolean)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_set_marketing_emails: not authenticated' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.exos_mail_prefs AS p (user_id, marketing_opt_out, opted_out_at)
  VALUES (v_uid, NOT coalesce(p_enabled, true), CASE WHEN coalesce(p_enabled, true) THEN NULL ELSE now() END)
  ON CONFLICT (user_id) DO UPDATE
    SET marketing_opt_out = EXCLUDED.marketing_opt_out,
        opted_out_at      = CASE WHEN EXCLUDED.marketing_opt_out THEN coalesce(p.opted_out_at, now()) END,
        updated_at        = now();
  RETURN coalesce(p_enabled, true);
END $$;
REVOKE ALL ON FUNCTION public.exos_set_marketing_emails(boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_marketing_emails(boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Cron entry point.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_send_checkout_reminders(
  p_min_age interval DEFAULT interval '1 hour',
  p_max_age interval DEFAULT interval '24 hours',
  p_limit   int      DEFAULT 200
) RETURNS TABLE (candidates int, mails_queued int, failed int)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_start   timestamptz := clock_timestamp();
  r         record;
  v_cand    int := 0;
  v_sent    int := 0;
  v_failed  int := 0;
  v_avail   int;
  v_qty     int;
  v_token   text;
  v_prod    text;
  v_query   text;
  v_unsub   text;
  v_tz      text;
  v_when    text;
  v_ev_html text;
  v_tier    text;
  v_mail    uuid;
BEGIN
  -- session_user: inside SECURITY DEFINER current_user is always the definer.
  IF session_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_send_checkout_reminders: service role only' USING ERRCODE = '42501';
  END IF;
  IF NOT public.cron_should_fire('exos_send_checkout_reminders') THEN
    RETURN QUERY SELECT 0, 0, 0; RETURN;
  END IF;

  FOR r IN
    SELECT s.session_id, s.buyer_uid, s.event_id, s.tier_id, s.quantity, s.addons,
           s.promoter_id, lower(u.email) AS email,
           e.name AS ev_name, e.starts_at, e.timezone, t.name AS tier_name
      FROM public.exos_checkout_sessions s
      JOIN public.exos_events e       ON e.id = s.event_id
      JOIN public.exos_orgs o         ON o.id = e.org_id
      JOIN public.exos_ticket_tiers t ON t.id = s.tier_id AND t.event_id = s.event_id
      JOIN auth.users u               ON u.id = s.buyer_uid
     WHERE s.status = 'expired'
       AND s.created_at <= now() - p_min_age
       AND s.created_at >= now() - p_max_age
       AND coalesce(s.buyer_email, '') <> ''
       AND u.email IS NOT NULL AND u.email_confirmed_at IS NOT NULL
       AND e.status = 'published' AND e.starts_at > now()
       AND o.checkout_reminders_enabled
       AND t.visibility = 'public'
       AND (t.sales_start IS NULL OR t.sales_start <= now())
       AND (t.sales_end   IS NULL OR t.sales_end   >  now())
       AND NOT EXISTS (SELECT 1 FROM public.exos_checkout_reminders cr
                        WHERE cr.buyer_uid = s.buyer_uid AND cr.event_id = s.event_id)
       AND NOT EXISTS (SELECT 1 FROM public.exos_mail_prefs mp
                        WHERE mp.user_id = s.buyer_uid AND mp.marketing_opt_out)
       -- only the buyer's latest attempt for this event counts
       AND NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions s2
                        WHERE s2.buyer_uid = s.buyer_uid AND s2.event_id = s.event_id
                          AND s2.created_at > s.created_at)
       AND NOT EXISTS (SELECT 1 FROM public.exos_tickets k
                        WHERE k.event_id = s.event_id
                          AND (k.buyer_id = s.buyer_uid OR k.owner_id = s.buyer_uid)
                          AND k.status <> 'voided'
                          AND k.created_at >= s.created_at)
     ORDER BY s.created_at
     LIMIT greatest(coalesce(p_limit, 200), 1)
  LOOP
    v_avail := public.exos_effective_available(r.tier_id);   -- NULL = uncapped
    CONTINUE WHEN v_avail IS NOT NULL AND v_avail < 1;
    v_cand := v_cand + 1;

    BEGIN
      -- Once-only claim. A concurrent run that got here first wins.
      INSERT INTO public.exos_checkout_reminders (buyer_uid, event_id, session_id)
      VALUES (r.buyer_uid, r.event_id, r.session_id)
      ON CONFLICT DO NOTHING;
      CONTINUE WHEN NOT FOUND;

      INSERT INTO public.exos_mail_prefs (user_id) VALUES (r.buyer_uid) ON CONFLICT (user_id) DO NOTHING;
      SELECT unsubscribe_token INTO v_token FROM public.exos_mail_prefs WHERE user_id = r.buyer_uid;

      -- products=<tier>:<qty>[,<addon>:<qty>...] (checkoutLink.ts; ids are UUIDs, no escaping needed)
      v_qty  := least(greatest(coalesce(r.quantity, 1), 1), 10, coalesce(v_avail, 10));
      v_prod := r.tier_id::text || ':' || v_qty;
      SELECT v_prod || coalesce(string_agg(',' || a.id::text || ':' || least(x.qty, 10), '' ORDER BY a.sort_order, a.id), '')
        INTO v_prod
        FROM (SELECT (el->>'addon_id') AS addon_id, sum((el->>'quantity')::int) AS qty
                FROM jsonb_array_elements(CASE WHEN jsonb_typeof(r.addons) = 'array' THEN r.addons ELSE '[]'::jsonb END) el
               WHERE (el->>'addon_id') ~* '^[0-9a-f-]{36}$' AND (el->>'quantity') ~ '^[0-9]{1,3}$'
               GROUP BY 1) x
        JOIN public.exos_event_addons a ON a.id = x.addon_id::uuid
       WHERE a.event_id = r.event_id AND a.visibility = 'public' AND x.qty > 0;

      v_query := 'event=' || r.event_id::text || '&amp;products=' || replace(replace(v_prod, ':', '%3A'), ',', '%2C')
              || CASE WHEN r.promoter_id IS NOT NULL THEN '&amp;promoter=' || r.promoter_id ELSE '' END
              || '&amp;utm_source=exos&amp;utm_medium=email&amp;utm_campaign=checkout-abandoned';
      v_unsub := '{{app_url}}/unsubscribe?t=' || v_token;

      v_tz := coalesce(nullif(r.timezone, ''), 'UTC');
      BEGIN
        v_when := to_char(r.starts_at AT TIME ZONE v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM');
      EXCEPTION WHEN invalid_parameter_value THEN
        v_tz := 'UTC';
        v_when := to_char(r.starts_at AT TIME ZONE 'UTC', 'FMDay, FMMonth FMDD "at" FMHH12:MI AM');
      END;

      v_ev_html := replace(replace(replace(coalesce(r.ev_name, 'the event'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
      v_tier    := replace(replace(replace(coalesce(r.tier_name, 'tickets'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');

      INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status, list_unsubscribe)
      VALUES ('checkout-abandoned', r.email,
        left('Still want tickets for ' || coalesce(r.ev_name, 'the event') || '?', 200),
        '<p>You started an order for <strong>' || v_ev_html || '</strong> (' || v_tier || ') ' ||
        'but didn''t finish, so the tickets went back on sale. There are still some left.</p>' ||
        '<p>The show is ' || v_when || ' (' || v_tz || ').</p>' ||
        '<p><a href="{{app_url}}/checkout?' || v_query || '">Finish your order</a></p>' ||
        '<p style="color:#888;font-size:12px">We only send this once for each event. ' ||
        '<a href="' || v_unsub || '">Unsubscribe</a> from reminders like this one.</p>',
        NULL, 'pending', v_unsub)
      RETURNING id INTO v_mail;

      UPDATE public.exos_checkout_reminders SET mail_id = v_mail
       WHERE buyer_uid = r.buyer_uid AND event_id = r.event_id;
      v_sent := v_sent + 1;
    EXCEPTION WHEN OTHERS THEN
      -- the savepoint rolls back the claim too, so the next run retries it
      v_failed := v_failed + 1;
      RAISE WARNING 'exos_send_checkout_reminders: session % failed: % (%)', r.session_id, SQLERRM, SQLSTATE;
    END;
    EXIT WHEN clock_timestamp() - v_start > interval '20 seconds';
  END LOOP;

  RETURN QUERY SELECT v_cand, v_sent, v_failed;
END $$;
REVOKE ALL ON FUNCTION public.exos_send_checkout_reminders(interval, interval, int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_send_checkout_reminders(interval, interval, int) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. Cron, hourly at :17 (off the busy :00/:05 marks). Guarded so a preview
--    branch / CI Postgres without pg_cron applies.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos_send_checkout_reminders') THEN
      PERFORM cron.unschedule('exos_send_checkout_reminders');
    END IF;
    PERFORM cron.schedule('exos_send_checkout_reminders', '17 * * * *',
                          $cron$SELECT * FROM public.exos_send_checkout_reminders();$cron$);
  END IF;
END $$;
