-- ============================================================================
-- Migration 20260925010000 — Exos (Bridge / D4): second round of trial-run
--                            fixes, private profiles, promoter social handles
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_attach_referral, exos_claim_transfer,
--              exos_check_in_ticket, exos_cancel_transfer, exos_fulfill_checkout,
--              exos_queue_mail, exos_notify_waitlist, exos_issue_comp_batch,
--              exos_reschedule_event, exos_send_event_announcement,
--              _exos_waitlist_offer_core (patched in place);
--              exos_upsert_promoter (+p_socials, +p_allow_tagging),
--              exos_promoter_kit, exos_public_promoter (return handles),
--              exos_promoter_set_socials (new);
--              TABLE exos_promoters (+socials, +allow_tagging),
--              exos_profiles (+is_public; SELECT policy narrowed),
--              exos_mail (template 'order-failed')
-- Pre-reqs: 20260925003000
--
-- From the 2026-09-25 trial (EXP KANBAN "Stabilization"):
--  1. exos_attach_referral credited any recent order, paid ones included, to
--     any code. Paid orders get their referral at fulfillment from the
--     checkout session; attach is now free claims only.
--  2. A claimed transfer moved buyer_id to the recipient but kept the old
--     buyer_email, so exports and webhooks named the wrong person.
--  3. Test-window scans (before doors) used up real tickets, so the holder
--     was "already used" at the door. They now verify everything and answer
--     {ok:true, reason:'test-scan', test:true} without consuming the ticket or
--     writing a check-in. Once doors open, scans are real as before.
--  4. Mail: cancelling a transfer withdraws its unsent "someone sent you a
--     ticket" mail; the copy says Exos, not "the Bridge app"; a buyer whose
--     paid order fails at fulfillment (sold out in a race) is told their
--     order didn't go through and the charge is refunded.
-- Operator decisions (2026-09-25):
--  5. Profiles are private by default. A profile is readable by its owner,
--     by staff of an org the person holds a ticket with (door names, rosters),
--     by people sharing an org with them, and by anyone once is_public is set.
--  6. Shares tag the organizer and promoter automatically where allowed.
--     Promoters get public handles (instagram / tiktok / x) plus an
--     allow_tagging switch they or the organizer can turn off. The organizer's
--     handles already live in exos_orgs.marketing.socials; the SPA reads
--     marketing.allowTagging (default on).
--
-- Every patch asserts one match and is skipped once applied (re-run safe).
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- Patch helper: replace exactly one occurrence of p_old in a function body.
-- A function that doesn't exist is skipped (the offline harness's stub schema
-- lacks a few; prod has all of them).
CREATE OR REPLACE FUNCTION pg_temp.exos_patch(p_sig text, p_marker text, p_old text, p_new text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE p_fn regprocedure := to_regprocedure(p_sig); v_def text; v_hits int;
BEGIN
  IF p_fn IS NULL THEN
    RAISE NOTICE '%: not present, skipped', p_sig;
    RETURN;
  END IF;
  v_def := pg_get_functiondef(p_fn);
  IF position(p_marker in v_def) > 0 THEN
    RAISE NOTICE '%: already patched (%)', p_fn, p_marker;
    RETURN;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION '%: expected one match for patch "%", found %', p_fn, p_marker, v_hits;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
END $$;

-- 1. referrals attach to free claims only -------------------------------------
SELECT pg_temp.exos_patch('public.exos_attach_referral(text, text)',
  'free claims only',
  '     AND t.created_at > now() - interval ''30 minutes'';',
  '     AND t.created_at > now() - interval ''30 minutes''
     -- free claims only: paid orders take ?ref= from their checkout session
     AND coalesce(t.price_paid, 0) = 0
     AND NOT EXISTS (SELECT 1 FROM public.exos_checkout_sessions cs WHERE cs.session_id = t.order_ref);');

-- 2. a claimed transfer carries the recipient's email ---------------------------
SELECT pg_temp.exos_patch('public.exos_claim_transfer(uuid)',
  'buyer_email         = v_email',
  '         buyer_id            = v_uid,',
  '         buyer_id            = v_uid,
         buyer_email         = v_email,');

-- 3. test-window scans don't consume tickets --------------------------------------
SELECT pg_temp.exos_patch(
  'public.exos_check_in_ticket(uuid, text, text, text, uuid)',
  'test-scan',
  '  UPDATE public.exos_tickets
     SET status = ''used'', check_in_at = now()
   WHERE id = p_ticket_id AND status = ''active'';',
  '  -- Before doors, the test window only proves the scanner works: the ticket
  -- stays unused and no check-in is recorded.
  IF v_test AND v_open_at IS NOT NULL AND now() < v_open_at THEN
    RETURN jsonb_build_object(''ok'', true, ''reason'', ''test-scan'', ''test'', true);
  END IF;

  UPDATE public.exos_tickets
     SET status = ''used'', check_in_at = now()
   WHERE id = p_ticket_id AND status = ''active'';');

-- 4a. cancelling a transfer withdraws its unsent mail ------------------------------
SELECT pg_temp.exos_patch('public.exos_cancel_transfer(uuid)',
  'withdraw the unsent',
  '  UPDATE public.exos_transfers SET status = ''cancelled'' WHERE id = p_transfer_id;',
  '  UPDATE public.exos_transfers SET status = ''cancelled'' WHERE id = p_transfer_id;
  -- withdraw the unsent "someone sent you a ticket" mail
  DELETE FROM public.exos_mail
   WHERE template = ''transfer-initiated'' AND status = ''pending''
     AND to_email = lower(trim(tr.receiver_email)) AND created_by = tr.sender_id
     AND created_at >= tr.created_at;');

-- 4b. mail copy: Exos, not "the Bridge app" ----------------------------------------
DO $$
DECLARE
  f regprocedure;
  v_def text;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('exos_queue_mail', 'exos_notify_waitlist', 'exos_issue_comp_batch',
                         'exos_reschedule_event', 'exos_send_event_announcement', '_exos_waitlist_offer_core')
  LOOP
    v_def := pg_get_functiondef(f);
    IF v_def ~ 'Bridge' THEN
      v_def := replace(v_def, 'the Bridge app', 'Exos');
      v_def := replace(v_def, 'on Bridge', 'on Exos');
      EXECUTE v_def;
    END IF;
  END LOOP;
END $$;

-- 4c. a paid order that fails at fulfillment tells the buyer -----------------------
DO $$
BEGIN
  ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
  ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check CHECK (template = ANY (ARRAY[
    'transfer-initiated', 'transfer-claimed', 'org-invite', 'event-cancelled', 'event-updated',
    'event-announce', 'ticket-issued', 'waitlist-open', 'event-announcement', 'event-rescheduled',
    'event-reminder', 'order-failed']));
END $$;

SELECT pg_temp.exos_patch('public.exos_fulfill_checkout(text)',
  '''order-failed''',
  '    UPDATE public.exos_checkout_sessions
       SET status = ''failed'', failure_reason = left(v_fail, 500)
     WHERE session_id = p_session_id;
    RETURN ''{}''::uuid[];',
  '    UPDATE public.exos_checkout_sessions
       SET status = ''failed'', failure_reason = left(v_fail, 500)
     WHERE session_id = p_session_id;
    IF coalesce(s.buyer_email, '''') <> '''' THEN
      SELECT name INTO v_evname FROM public.exos_events WHERE id = s.event_id;
      v_safe := replace(replace(coalesce(v_evname, ''your event''), ''<'', ''&lt;''), ''>'', ''&gt;'');
      BEGIN
        INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
        VALUES (''order-failed'', lower(s.buyer_email),
          left(''Your order for '' || v_safe || '' didn''''t go through'', 200),
          ''<p>Sorry, the tickets you picked for <strong>'' || v_safe ||
          ''</strong> sold out while you were paying, so your order didn''''t go through. '' ||
          ''Your payment is being refunded in full; it can take 5 to 10 days to show up.</p>'',
          s.buyer_uid, ''pending'');
      EXCEPTION WHEN others THEN NULL;
      END;
    END IF;
    RETURN ''{}''::uuid[];');

-- 5. profiles are private by default -----------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.exos_profiles') IS NULL THEN
    RAISE NOTICE 'exos_profiles: not present, skipped';
    RETURN;
  END IF;
  ALTER TABLE public.exos_profiles ADD COLUMN IF NOT EXISTS is_public boolean NOT NULL DEFAULT false;
  DROP POLICY IF EXISTS exos_profiles_sel ON public.exos_profiles;
  CREATE POLICY exos_profiles_sel ON public.exos_profiles
  FOR SELECT TO authenticated
  USING (
    id = auth.uid()
    OR is_public
    OR public.exos_is_admin()
    -- org staff see the people holding tickets to their events (door names)
    OR EXISTS (SELECT 1 FROM public.exos_tickets t
                WHERE t.owner_id = exos_profiles.id
                  AND public.exos_has_org_role(t.org_id, ARRAY['owner', 'manager', 'scanner', 'finance']))
    -- teammates see each other
    OR EXISTS (SELECT 1 FROM public.exos_org_memberships m
                WHERE m.user_id = exos_profiles.id AND m.disabled IS NOT TRUE
                  AND public.exos_has_org_role(m.org_id, ARRAY['owner', 'manager', 'finance', 'scanner', 'content']))
  );
END $$;

-- 6. promoter handles + tagging consent --------------------------------------------
ALTER TABLE public.exos_promoters
  ADD COLUMN IF NOT EXISTS socials jsonb,
  ADD COLUMN IF NOT EXISTS allow_tagging boolean NOT NULL DEFAULT true;
CREATE OR REPLACE FUNCTION public.exos_socials_valid(p jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT p IS NULL OR (
    jsonb_typeof(p) = 'object'
    AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(p) k WHERE k NOT IN ('instagram', 'tiktok', 'x'))
    AND coalesce(p->>'instagram', 'a') ~ '^[A-Za-z0-9._]{1,30}$'
    AND coalesce(p->>'tiktok', 'a') ~ '^[A-Za-z0-9._]{1,24}$'
    AND coalesce(p->>'x', 'a') ~ '^[A-Za-z0-9_]{1,15}$');
$$;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_promoters_socials_chk') THEN
    ALTER TABLE public.exos_promoters ADD CONSTRAINT exos_promoters_socials_chk
      CHECK (public.exos_socials_valid(socials));
  END IF;
END $$;

-- Handles arrive as "@name", "name" or a profile URL; store the bare name.
CREATE OR REPLACE FUNCTION public.exos_clean_socials(p jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT nullif(jsonb_strip_nulls(jsonb_build_object(
    'instagram', nullif(regexp_replace(regexp_replace(btrim(coalesce(p->>'instagram', '')),
                   '^(https?://)?(www\.)?instagram\.com/', '', 'i'), '^@|/.*$', '', 'g'), ''),
    'tiktok',    nullif(regexp_replace(regexp_replace(btrim(coalesce(p->>'tiktok', '')),
                   '^(https?://)?(www\.)?tiktok\.com/@?', '', 'i'), '^@|/.*$', '', 'g'), ''),
    'x',         nullif(regexp_replace(regexp_replace(btrim(coalesce(p->>'x', '')),
                   '^(https?://)?(www\.)?(x|twitter)\.com/', '', 'i'), '^@|/.*$', '', 'g'), ''))),
    '{}'::jsonb);
$$;
REVOKE ALL ON FUNCTION public.exos_clean_socials(jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_clean_socials(jsonb) TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.exos_upsert_promoter(uuid, text, text, text);
CREATE OR REPLACE FUNCTION public.exos_upsert_promoter(
  p_org_id uuid, p_code text, p_name text, p_email text DEFAULT NULL,
  p_socials jsonb DEFAULT NULL, p_allow_tagging boolean DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_upsert_promoter: not allowed' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.exos_promoters AS p (org_id, code, name, email, created_by, socials, allow_tagging)
  VALUES (p_org_id, btrim(p_code), btrim(p_name), NULLIF(lower(btrim(coalesce(p_email, ''))), ''), auth.uid(),
          public.exos_clean_socials(p_socials), coalesce(p_allow_tagging, true))
  ON CONFLICT (org_id, code) DO UPDATE SET
    name = EXCLUDED.name, email = EXCLUDED.email,
    -- NULL means "leave as is", so an older caller can't wipe handles
    socials = CASE WHEN p_socials IS NULL THEN p.socials ELSE EXCLUDED.socials END,
    allow_tagging = coalesce(p_allow_tagging, p.allow_tagging),
    updated_at = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_upsert_promoter(uuid, text, text, text, jsonb, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_upsert_promoter(uuid, text, text, text, jsonb, boolean) TO authenticated, service_role;

-- The promoter sets their own handles and consent from their private page.
CREATE OR REPLACE FUNCTION public.exos_promoter_set_socials(p_token uuid, p_socials jsonb, p_allow_tagging boolean)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_out jsonb;
BEGIN
  UPDATE public.exos_promoters
     SET socials = public.exos_clean_socials(p_socials),
         allow_tagging = coalesce(p_allow_tagging, allow_tagging),
         updated_at = now()
   WHERE kit_token = p_token AND status = 'active'
  RETURNING jsonb_build_object('socials', socials, 'allow_tagging', allow_tagging) INTO v_out;
  IF v_out IS NULL THEN
    RAISE EXCEPTION 'exos_promoter_set_socials: link not active' USING ERRCODE = '42501';
  END IF;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.exos_promoter_set_socials(uuid, jsonb, boolean) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_set_socials(uuid, jsonb, boolean) TO anon, authenticated, service_role;

-- Kit: the promoter sees their own handles and switch.
SELECT pg_temp.exos_patch('public.exos_promoter_kit(uuid)',
  '''allow_tagging'', p.allow_tagging',
  '''promoter'', jsonb_build_object(''name'', p.name, ''code'', p.code),',
  '''promoter'', jsonb_build_object(''name'', p.name, ''code'', p.code,
                                  ''socials'', coalesce(p.socials, ''{}''::jsonb), ''allow_tagging'', p.allow_tagging),');

-- Public card: handles only when the promoter allows tagging.
SELECT pg_temp.exos_patch('public.exos_public_promoter(text, text)',
  'CASE WHEN p.allow_tagging',
  '''promoter'', jsonb_build_object(''name'', p.name, ''code'', p.code),',
  '''promoter'', jsonb_build_object(''name'', p.name, ''code'', p.code,
                                  ''socials'', CASE WHEN p.allow_tagging THEN coalesce(p.socials, ''{}''::jsonb) ELSE ''{}''::jsonb END),');
