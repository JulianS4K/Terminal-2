-- ============================================================================
-- Abandoned-checkout reminder (mig 20260926060000). Self-contained: seeds its
-- own org / events / buyers under the af… prefix and rolls everything back.
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_abandoned_checkout.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- Orgs: O1 reminders on (default), O2 turned off.
INSERT INTO public.exos_orgs (id, name, slug) VALUES
  ('af000000-0000-0000-0000-0000000000a1', 'AF Org', 'af-org'),
  ('af000000-0000-0000-0000-0000000000a2', 'AF Quiet', 'af-quiet');
UPDATE public.exos_orgs SET checkout_reminders_enabled = false WHERE id = 'af000000-0000-0000-0000-0000000000a2';

-- Events: E1 upcoming, E2 already started, E3 draft, E4 upcoming in O2.
INSERT INTO public.exos_events (id, org_id, name, status, starts_at, timezone) VALUES
  ('af000000-0000-0000-0000-0000000000e1', 'af000000-0000-0000-0000-0000000000a1', 'Rock & <Roll>', 'published', now() + interval '10 days', 'America/New_York'),
  ('af000000-0000-0000-0000-0000000000e2', 'af000000-0000-0000-0000-0000000000a1', 'Past', 'published', now() - interval '1 hour', 'UTC'),
  ('af000000-0000-0000-0000-0000000000e3', 'af000000-0000-0000-0000-0000000000a1', 'Draft', 'draft', now() + interval '10 days', 'UTC'),
  ('af000000-0000-0000-0000-0000000000e4', 'af000000-0000-0000-0000-0000000000a2', 'Quiet', 'published', now() + interval '10 days', 'UTC');

-- Tiers: t1 open; t2 sold out; t3 sales ended; t4 hidden; t5..t7 on E2..E4.
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, sold, visibility, sales_end) VALUES
  ('af000000-0000-0000-0000-0000000000d1', 'af000000-0000-0000-0000-0000000000e1', 'GA', 20, 100, 0, 'public', NULL),
  ('af000000-0000-0000-0000-0000000000d2', 'af000000-0000-0000-0000-0000000000e1', 'VIP', 90, 5, 5, 'public', NULL),
  ('af000000-0000-0000-0000-0000000000d3', 'af000000-0000-0000-0000-0000000000e1', 'Early', 10, 100, 0, 'public', now() - interval '1 day'),
  ('af000000-0000-0000-0000-0000000000d4', 'af000000-0000-0000-0000-0000000000e1', 'Secret', 10, 100, 0, 'hidden', NULL),
  ('af000000-0000-0000-0000-0000000000d5', 'af000000-0000-0000-0000-0000000000e2', 'GA', 20, 100, 0, 'public', NULL),
  ('af000000-0000-0000-0000-0000000000d6', 'af000000-0000-0000-0000-0000000000e3', 'GA', 20, 100, 0, 'public', NULL),
  ('af000000-0000-0000-0000-0000000000d7', 'af000000-0000-0000-0000-0000000000e4', 'GA', 20, 100, 0, 'public', NULL);
INSERT INTO public.exos_event_addons (id, event_id, name, price, visibility) VALUES
  ('af000000-0000-0000-0000-0000000000c1', 'af000000-0000-0000-0000-0000000000e1', 'Parking', 15, 'public'),
  ('af000000-0000-0000-0000-0000000000c2', 'af000000-0000-0000-0000-0000000000e1', 'Backstage', 99, 'hidden');

-- Buyers 01..16. 02 has no confirmed email.
INSERT INTO auth.users (id, email, email_confirmed_at)
SELECT ('af000000-0000-0000-0000-0000000001' || lpad(n::text, 2, '0'))::uuid,
       'AF' || n || '@X.com', CASE WHEN n = 2 THEN NULL ELSE now() - interval '30 days' END
  FROM generate_series(1, 16) n;

-- Sessions. Default: expired, created 2h ago, buyer_email set.
CREATE TEMP TABLE af_s (sid text, ev text, tier text, buyer int, qty int, status text, age interval, email text, addons jsonb, promoter text);
INSERT INTO af_s VALUES
  ('af-s01a','e1','d1', 1, 1,'expired','5 hours', 'af1@x.com', NULL, NULL),          -- older attempt
  ('af-s01', 'e1','d1', 1, 2,'expired','2 hours', 'af1@x.com',
     '[{"addon_id":"af000000-0000-0000-0000-0000000000c1","quantity":1,"unit_price_cents":1500},{"addon_id":"af000000-0000-0000-0000-0000000000c2","quantity":1}]', 'dj-kay'),
  ('af-s02', 'e1','d1', 2, 1,'expired','2 hours', 'af2@x.com', NULL, NULL),          -- unconfirmed email
  ('af-s03', 'e1','d1', 3, 1,'expired','2 hours', 'af3@x.com', NULL, NULL),          -- bought since
  ('af-s04', 'e1','d1', 4, 1,'expired','2 hours', 'af4@x.com', NULL, NULL),          -- unsubscribed
  ('af-s05', 'e1','d1', 5, 1,'expired','3 hours', 'af5@x.com', NULL, NULL),          -- newer session exists
  ('af-s05b','e1','d1', 5, 1,'pending','10 minutes','af5@x.com', NULL, NULL),
  ('af-s06', 'e1','d2', 6, 1,'expired','2 hours', 'af6@x.com', NULL, NULL),          -- tier sold out
  ('af-s07', 'e2','d5', 7, 1,'expired','2 hours', 'af7@x.com', NULL, NULL),          -- event started
  ('af-s08', 'e3','d6', 8, 1,'expired','2 hours', 'af8@x.com', NULL, NULL),          -- event not published
  ('af-s09', 'e4','d7', 9, 1,'expired','2 hours', 'af9@x.com', NULL, NULL),          -- org turned it off
  ('af-s10', 'e1','d1',10, 1,'expired','30 minutes','af10@x.com', NULL, NULL),       -- too recent
  ('af-s11', 'e1','d1',11, 1,'expired','30 hours','af11@x.com', NULL, NULL),         -- too old
  ('af-s12', 'e1','d1',12, 1,'expired','2 hours', NULL, NULL, NULL),                 -- account deleted (email wiped)
  ('af-s13', 'e1','d3',13, 1,'expired','2 hours', 'af13@x.com', NULL, NULL),         -- sales ended
  ('af-s14', 'e1','d4',14, 1,'expired','2 hours', 'af14@x.com', NULL, NULL),         -- hidden tier
  ('af-s15', 'e1','d1',15, 1,'fulfilled','2 hours','af15@x.com', NULL, NULL),        -- paid, not abandoned
  ('af-s16', 'e1','d1',16, 1,'failed','2 hours', 'af16@x.com', NULL, NULL);          -- failed, not expired
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email,
  quantity, amount_cents, status, created_at, addons, promoter_id)
SELECT s.sid, ('af000000-0000-0000-0000-0000000000' || s.ev)::uuid, ('af000000-0000-0000-0000-0000000000' || s.tier)::uuid,
       e.org_id, ('af000000-0000-0000-0000-0000000001' || lpad(s.buyer::text, 2, '0'))::uuid, s.email,
       s.qty, 2000 * s.qty, s.status, now() - s.age, s.addons, s.promoter
  FROM af_s s JOIN public.exos_events e ON e.id = ('af000000-0000-0000-0000-0000000000' || s.ev)::uuid;

-- Buyer 3 bought a ticket after the abandoned session.
INSERT INTO public.exos_tickets (event_id, org_id, tier_id, buyer_id, owner_id, status, price_paid, order_ref, barcode_secret)
VALUES ('af000000-0000-0000-0000-0000000000e1', 'af000000-0000-0000-0000-0000000000a1', 'af000000-0000-0000-0000-0000000000d1',
        'af000000-0000-0000-0000-000000000103', 'af000000-0000-0000-0000-000000000103', 'active', 20, 'af-paid', 'test-secret');

-- AC1. Signed-in self opt-out (buyer 4); anon can't use it.
SELECT set_config('app.uid', 'af000000-0000-0000-0000-000000000104', false);
DO $$
BEGIN
  ASSERT public.exos_set_marketing_emails(false) = false, 'AC1: returns the new setting';
  ASSERT (SELECT marketing_opt_out FROM public.exos_mail_prefs WHERE user_id = 'af000000-0000-0000-0000-000000000104'),
    'AC1: opt-out stored';
  RAISE NOTICE 'OK  AC1 self opt-out';
END $$;
SELECT set_config('app.uid', '', false);
SET ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_set_marketing_emails(false);
    RAISE EXCEPTION 'AC1: anon changed mail prefs';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  AC1b anon blocked from exos_set_marketing_emails';
END $$;
RESET ROLE;

-- AC2. Only the service role / cron may run the sweep.
SET ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM * FROM public.exos_send_checkout_reminders();
    RAISE EXCEPTION 'AC2: authenticated ran the sweep';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM public.exos_checkout_reminders;
    RAISE EXCEPTION 'AC2: authenticated read exos_checkout_reminders';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM unsubscribe_token FROM public.exos_mail_prefs;
    RAISE EXCEPTION 'AC2: authenticated read unsubscribe tokens';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  AC2 sweep + ledger + tokens are service-only';
END $$;
RESET ROLE;
SET ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM * FROM public.exos_send_checkout_reminders();
    RAISE EXCEPTION 'AC2: anon ran the sweep';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  AC2b anon blocked from the sweep';
END $$;
RESET ROLE;

-- AC3. The sweep: exactly buyer 1 qualifies, with a cart-refill link.
DO $$
DECLARE r record; m record; tok text;
BEGIN
  SELECT * INTO r FROM public.exos_send_checkout_reminders();
  ASSERT r.mails_queued = 1 AND r.failed = 0, format('AC3: expected 1 mail / 0 failed, got %s / %s', r.mails_queued, r.failed);
  SELECT * INTO m FROM public.exos_mail WHERE template = 'checkout-abandoned';
  ASSERT m.to_email = 'af1@x.com', 'AC3: sent to the confirmed auth email, lower-cased: ' || m.to_email;
  ASSERT m.subject = 'Still want tickets for Rock & <Roll>?', 'AC3: subject uses the raw name: ' || m.subject;
  ASSERT m.html LIKE '%Rock &amp; &lt;Roll&gt;%', 'AC3: body escapes the event name';
  ASSERT m.html LIKE '%{{app_url}}/checkout?event=af000000-0000-0000-0000-0000000000e1&amp;products='
                  || 'af000000-0000-0000-0000-0000000000d1%3A2%2Caf000000-0000-0000-0000-0000000000c1%3A1&amp;promoter=dj-kay%',
    'AC3: link refills the LATEST cart (qty 2 + public add-on only, promoter kept): ' || m.html;
  ASSERT m.html NOT LIKE '%af000000-0000-0000-0000-0000000000c2%', 'AC3: hidden add-on left out';
  SELECT unsubscribe_token INTO tok FROM public.exos_mail_prefs WHERE user_id = 'af000000-0000-0000-0000-000000000101';
  ASSERT tok ~ '^[0-9a-f]{64}$', 'AC3: token minted';
  ASSERT m.list_unsubscribe = '{{app_url}}/unsubscribe?t=' || tok, 'AC3: List-Unsubscribe target';
  ASSERT m.html LIKE '%/unsubscribe?t=' || tok || '%', 'AC3: unsubscribe link in the body';
  ASSERT (SELECT session_id FROM public.exos_checkout_reminders
           WHERE buyer_uid = 'af000000-0000-0000-0000-000000000101'
             AND event_id = 'af000000-0000-0000-0000-0000000000e1') = 'af-s01', 'AC3: ledger row';
  ASSERT (SELECT mail_id FROM public.exos_checkout_reminders
           WHERE buyer_uid = 'af000000-0000-0000-0000-000000000101') = m.id, 'AC3: ledger links the mail';
  RAISE NOTICE 'OK  AC3 eligible buyer gets one mail with a refill link';
END $$;

-- AC4. Each exclusion rule, one buyer per rule.
DO $$
DECLARE
  rules text[] := ARRAY['02 unconfirmed email','03 bought since','04 unsubscribed','05 newer session',
    '06 tier sold out','07 event started','08 not published','09 org toggle off','10 too recent',
    '11 too old','12 email wiped','13 sales ended','14 hidden tier','15 paid','16 failed'];
  rule text;
BEGIN
  FOREACH rule IN ARRAY rules LOOP
    ASSERT NOT EXISTS (SELECT 1 FROM public.exos_mail
                        WHERE template = 'checkout-abandoned' AND to_email = 'af' || ltrim(left(rule, 2), '0') || '@x.com'),
      'AC4: mailed despite rule ' || rule;
    ASSERT NOT EXISTS (SELECT 1 FROM public.exos_checkout_reminders
                        WHERE buyer_uid = ('af000000-0000-0000-0000-0000000001' || left(rule, 2))::uuid),
      'AC4: ledger row despite rule ' || rule;
  END LOOP;
  RAISE NOTICE 'OK  AC4 all % exclusion rules hold', array_length(rules, 1);
END $$;

-- AC5. Once per buyer per event, ever: a re-run and a fresh abandoned
--      attempt in the window both send nothing more.
DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM public.exos_send_checkout_reminders();
  ASSERT r.mails_queued = 0, 'AC5: re-run queued ' || r.mails_queued;
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, status, created_at)
  VALUES ('af-s01c', 'af000000-0000-0000-0000-0000000000e1', 'af000000-0000-0000-0000-0000000000d1',
          'af000000-0000-0000-0000-0000000000a1', 'af000000-0000-0000-0000-000000000101', 'af1@x.com', 1, 2000, 'expired',
          now() - interval '90 minutes');
  SELECT * INTO r FROM public.exos_send_checkout_reminders();
  ASSERT r.mails_queued = 0, 'AC5: second abandoned attempt re-mailed';
  ASSERT (SELECT count(*) FROM public.exos_mail WHERE template = 'checkout-abandoned') = 1, 'AC5: still one mail';
  RAISE NOTICE 'OK  AC5 once-only';
END $$;

-- AC6. Seats freeing up later makes a previously sold-out buyer eligible
--      (proves the sold-out exclusion is the capacity check, not something else).
DO $$
DECLARE r record;
BEGIN
  UPDATE public.exos_ticket_tiers SET sold = 3 WHERE id = 'af000000-0000-0000-0000-0000000000d2';
  SELECT * INTO r FROM public.exos_send_checkout_reminders();
  ASSERT r.mails_queued = 1, 'AC6: freed seat -> reminder, got ' || r.mails_queued;
  ASSERT EXISTS (SELECT 1 FROM public.exos_mail WHERE template = 'checkout-abandoned' AND to_email = 'af6@x.com'
                   AND html LIKE '%d2%3A1%'), 'AC6: buyer 6 mailed';
  RAISE NOTICE 'OK  AC6 availability re-checked each run';
END $$;

-- AC7. Unsubscribe link: anon, by token; bad tokens do nothing.
SET ROLE anon;
DO $$
BEGIN
  ASSERT public.exos_mail_unsubscribe('nope') = false, 'AC7: malformed token';
  ASSERT public.exos_mail_unsubscribe(repeat('0', 64)) = false, 'AC7: unknown token';
  RAISE NOTICE 'OK  AC7a bad tokens refused';
END $$;
RESET ROLE;
SELECT set_config('test.tok', (SELECT unsubscribe_token FROM public.exos_mail_prefs
                                WHERE user_id = 'af000000-0000-0000-0000-000000000101'), false);
SET ROLE anon;
DO $$
BEGIN
  ASSERT public.exos_mail_unsubscribe(current_setting('test.tok')) = true, 'AC7: token unsubscribes';
  ASSERT public.exos_mail_unsubscribe(current_setting('test.tok')) = true, 'AC7: idempotent';
  RAISE NOTICE 'OK  AC7b token unsubscribe (anon)';
END $$;
RESET ROLE;
DO $$
BEGIN
  ASSERT (SELECT marketing_opt_out AND opted_out_at IS NOT NULL FROM public.exos_mail_prefs
           WHERE user_id = 'af000000-0000-0000-0000-000000000101'), 'AC7: flag stored';
  RAISE NOTICE 'OK  AC7c opt-out recorded';
END $$;

-- AC8. Template allowlist: every earlier template still accepted, plus the new one.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['transfer-initiated','transfer-claimed','org-invite','event-cancelled','event-updated',
      'event-announce','ticket-issued','waitlist-open','event-announcement','event-rescheduled',
      'event-reminder','order-failed','checkout-abandoned'] LOOP
    INSERT INTO public.exos_mail (template, to_email, subject, html) VALUES (t, 'af-tpl@x.com', 's', 'h');
  END LOOP;
  BEGIN
    INSERT INTO public.exos_mail (template, to_email, subject, html) VALUES ('not-a-template', 'af-tpl@x.com', 's', 'h');
    RAISE EXCEPTION 'AC8: unknown template accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'OK  AC8 allowlist keeps all old templates';
END $$;

-- AC9. Re-applying the migration keeps a template some OTHER migration added
--      (written as an array literal) and stays a no-op for the rest.
DO $$
BEGIN
  DELETE FROM public.exos_mail WHERE template = 'checkout-abandoned';
  ALTER TABLE public.exos_mail DROP CONSTRAINT exos_mail_template_check;
  ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check CHECK (template = ANY (
    '{transfer-initiated,transfer-claimed,org-invite,event-cancelled,event-updated,event-announce,ticket-issued,waitlist-open,event-announcement,event-rescheduled,event-reminder,order-failed,zz-foreign}'::text[]));
END $$;
\ir ../../supabase/migrations/20260926060000_exos_abandoned_checkout.sql
DO $$
BEGIN
  INSERT INTO public.exos_mail (template, to_email, subject, html) VALUES ('zz-foreign', 'af-tpl@x.com', 's', 'h');
  INSERT INTO public.exos_mail (template, to_email, subject, html) VALUES ('checkout-abandoned', 'af-tpl@x.com', 's', 'h');
  INSERT INTO public.exos_mail (template, to_email, subject, html) VALUES ('event-reminder', 'af-tpl@x.com', 's', 'h');
  RAISE NOTICE 'OK  AC9 re-apply unions with the live list';
END $$;

ROLLBACK;
