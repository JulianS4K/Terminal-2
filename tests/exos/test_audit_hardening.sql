-- ============================================================================
-- Regression test for mig 20260924200848. ASSERT-guarded; ON_ERROR_STOP aborts.
-- Actors: victim-org owner 11111111…, attacker 22222222… (own org),
--         buyer 33333333…, attacker's alt 44444444…
-- ============================================================================
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('11111111-1111-1111-1111-111111111111','victim@x',   now()),
  ('22222222-2222-2222-2222-222222222222','attacker@x', now()),
  ('33333333-3333-3333-3333-333333333333','buyer@x',    now()),
  ('44444444-4444-4444-4444-444444444444','alt@x',      now());
INSERT INTO public.exos_orgs (id, name, slug, owner_uid) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001','Victim','victim','11111111-1111-1111-1111-111111111111'),
  ('bbbbbbbb-0000-0000-0000-000000000001','Attacker','attacker','22222222-2222-2222-2222-222222222222');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','owner'),
  ('bbbbbbbb-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','owner');
INSERT INTO public.exos_events (id, org_id, name, status, doors_at, starts_at, created_by, currency) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001','Victim Show','published',
   now() + interval '1 day', now() + interval '1 day 2 hours','11111111-1111-1111-1111-111111111111','USD'),
  ('bbbbbbbb-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000001','Attacker Show','published',
   now() + interval '1 day', now() + interval '1 day 2 hours','22222222-2222-2222-2222-222222222222','USD');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity, ticket_type, visibility) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000002','GA',30,100,'paid','public'),
  ('bbbbbbbb-0000-0000-0000-000000000003','bbbbbbbb-0000-0000-0000-000000000002','GA',30,100,'paid','public');

-- ── 1. quota mapping stays inside one org + event ───────────────────────────
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid','22222222-2222-2222-2222-222222222222', true);
SELECT set_config('app.jwt','{"email":"attacker@x"}', true);
DO $$
DECLARE q uuid; raised boolean;
BEGIN
  -- own quota on own event: allowed
  INSERT INTO public.exos_quotas (event_id, org_id, name, size)
    VALUES ('bbbbbbbb-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000001','zero',0)
    RETURNING id INTO q;
  INSERT INTO public.exos_quota_tiers (quota_id, tier_id) VALUES (q, 'bbbbbbbb-0000-0000-0000-000000000003');

  -- own quota mapped onto the victim's tier: refused
  raised := false;
  BEGIN
    INSERT INTO public.exos_quota_tiers (quota_id, tier_id) VALUES (q, 'aaaaaaaa-0000-0000-0000-000000000003');
  EXCEPTION WHEN insufficient_privilege THEN raised := true;
  END;
  ASSERT raised, 'mapping a quota onto another org''s tier must be refused';

  -- quota under own org but pointed at the victim's event: refused
  raised := false;
  BEGIN
    INSERT INTO public.exos_quotas (event_id, org_id, name, size)
      VALUES ('aaaaaaaa-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000001','x',0);
  EXCEPTION WHEN insufficient_privilege THEN raised := true;
  END;
  ASSERT raised, 'a quota must belong to an event of its own org';
  RAISE NOTICE 'quota mapping scoped to own org/event ok';
END $$;
COMMIT;

-- ── 2. double transfer: only the transfer the ticket points at can be claimed
DO $$
DECLARE t uuid; tr_buyer uuid; tr_alt uuid; raised boolean := false; own uuid;
BEGIN
  INSERT INTO public.exos_tickets (event_id, org_id, tier_id, tier_name, owner_id, buyer_id, status, barcode_secret)
    VALUES ('bbbbbbbb-0000-0000-0000-000000000002','bbbbbbbb-0000-0000-0000-000000000001',
            'bbbbbbbb-0000-0000-0000-000000000003','GA',
            '22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222','active','s0')
    RETURNING id INTO t;

  PERFORM set_config('app.uid','22222222-2222-2222-2222-222222222222', true);
  PERFORM set_config('app.jwt','{"email":"attacker@x"}', true);
  tr_buyer := public.exos_create_transfer(t, 'buyer@x');
  -- simulate the lost race: a second pending transfer row for the same ticket
  INSERT INTO public.exos_transfers (ticket_id, org_id, sender_id, sender_email, receiver_email, status, event_id)
    VALUES (t, 'bbbbbbbb-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
            'attacker@x', 'alt@x', 'pending', 'bbbbbbbb-0000-0000-0000-000000000002')
    RETURNING id INTO tr_alt;

  PERFORM set_config('app.uid','33333333-3333-3333-3333-333333333333', true);
  PERFORM set_config('app.jwt','{"email":"buyer@x"}', true);
  PERFORM public.exos_claim_transfer(tr_buyer);

  PERFORM set_config('app.uid','44444444-4444-4444-4444-444444444444', true);
  PERFORM set_config('app.jwt','{"email":"alt@x"}', true);
  BEGIN
    PERFORM public.exos_claim_transfer(tr_alt);
  EXCEPTION WHEN raise_exception THEN raised := true;
  END;
  ASSERT raised, 'a sibling transfer must not claim a ticket the sender no longer owns';
  SELECT owner_id INTO own FROM public.exos_tickets WHERE id = t;
  ASSERT own = '33333333-3333-3333-3333-333333333333', 'the buyer must keep the ticket';

  -- a second create_transfer while one is pending is refused
  raised := false;
  PERFORM set_config('app.uid','33333333-3333-3333-3333-333333333333', true);
  PERFORM set_config('app.jwt','{"email":"buyer@x"}', true);
  PERFORM public.exos_create_transfer(t, 'alt@x');
  BEGIN
    PERFORM public.exos_create_transfer(t, 'victim@x');
  EXCEPTION WHEN raise_exception THEN raised := true;
  END;
  ASSERT raised, 'only one pending transfer per ticket';
  RAISE NOTICE 'transfer race closed ok';
END $$;

-- ── 3. waitlist rows can't be edited directly ───────────────────────────────
INSERT INTO public.exos_waitlist (id, event_id, user_id, email, status)
  VALUES ('cccccccc-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000002',
          '33333333-3333-3333-3333-333333333333','buyer@x','waiting');
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('app.uid','33333333-3333-3333-3333-333333333333', true);
SELECT set_config('app.jwt','{"email":"buyer@x"}', true);
DO $$
DECLARE raised boolean := false;
BEGIN
  BEGIN
    UPDATE public.exos_waitlist SET created_at = '2000-01-01' WHERE id = 'cccccccc-0000-0000-0000-000000000001';
  EXCEPTION WHEN insufficient_privilege THEN raised := true;
  END;
  ASSERT raised, 'authenticated must not UPDATE waitlist rows directly (queue jumping)';
  RAISE NOTICE 'waitlist self-edit blocked ok';
END $$;
COMMIT;

-- ── 4. the two late ticket columns are readable (RLS still scopes rows) ────
DO $$
BEGIN
  ASSERT has_column_privilege('authenticated','public.exos_tickets','attendee_name','SELECT'),
         'authenticated must be able to SELECT exos_tickets.attendee_name';
  ASSERT has_column_privilege('authenticated','public.exos_tickets','released_at','SELECT'),
         'authenticated must be able to SELECT exos_tickets.released_at';
  ASSERT NOT has_column_privilege('authenticated','public.exos_tickets','barcode_secret','SELECT'),
         'barcode_secret must stay ungranted';
  RAISE NOTICE 'late ticket column grants ok';
END $$;

SELECT '*** EXOS AUDIT-HARDENING TEST PASSED ***';
