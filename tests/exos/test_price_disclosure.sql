-- ============================================================================
-- Price-disclosure record (mig 20260926070000). Self-contained (af… prefix),
-- rolled back at the end.
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_price_disclosure.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

INSERT INTO public.exos_orgs (id, name, slug) VALUES ('af000000-0000-0000-0000-0000000002a1', 'AF PD Org', 'af-pd');
INSERT INTO public.exos_org_memberships (org_id, user_id, role) VALUES
  ('af000000-0000-0000-0000-0000000002a1', 'af000000-0000-0000-0000-000000000201', 'owner'),
  ('af000000-0000-0000-0000-0000000002a1', 'af000000-0000-0000-0000-000000000202', 'finance'),
  ('af000000-0000-0000-0000-0000000002a1', 'af000000-0000-0000-0000-000000000203', 'scanner'),
  ('af000000-0000-0000-0000-0000000002a1', 'af000000-0000-0000-0000-000000000205', 'manager');
INSERT INTO public.exos_events (id, org_id, name, status, starts_at) VALUES
  ('af000000-0000-0000-0000-0000000002e1', 'af000000-0000-0000-0000-0000000002a1', 'PD Show', 'published', now() + interval '5 days');
INSERT INTO public.exos_ticket_tiers (id, event_id, name, price, capacity) VALUES
  ('af000000-0000-0000-0000-0000000002d1', 'af000000-0000-0000-0000-0000000002e1', 'GA', 40, 100);
INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
  ('af000000-0000-0000-0000-000000000204', 'af-pd-buyer@x.com', now());
INSERT INTO public.exos_checkout_sessions (session_id, event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, amount_cents, status)
VALUES ('af-pd-1', 'af000000-0000-0000-0000-0000000002e1', 'af000000-0000-0000-0000-0000000002d1', 'af000000-0000-0000-0000-0000000002a1',
        'af000000-0000-0000-0000-000000000204', 'af-pd-buyer@x.com', 2, 9670, 'pending'),
       ('af-pd-2', 'af000000-0000-0000-0000-0000000002e1', 'af000000-0000-0000-0000-0000000002d1', 'af000000-0000-0000-0000-0000000002a1',
        'af000000-0000-0000-0000-000000000204', 'af-pd-buyer@x.com', 1, 4335, 'pending');

-- PD1. Record what was shown: 2 x GA at $40 + 8.375% tax = $43.35 all-in, 1 parking at $10 (no tax).
DO $$
DECLARE v int;
BEGIN
  v := public.exos_record_price_disclosure('af-pd-1', 'USD', jsonb_build_array(
    jsonb_build_object('kind','ticket','item_id','af000000-0000-0000-0000-0000000002d1','name','GA','quantity',2,
                       'face_unit_cents',4000,'tax_cents',670,'tax_included',false,'fee_cents',0,'unit_all_in_cents',4335),
    jsonb_build_object('kind','addon','item_id','not-a-uuid','name','Parking','quantity',1,
                       'face_unit_cents',1000,'tax_cents',0,'fee_cents',0,'unit_all_in_cents',1000)));
  ASSERT v = 9670, 'PD1: total shown = 2*4335 + 1000, got ' || v;
  ASSERT (SELECT currency = 'usd' AND org_id = 'af000000-0000-0000-0000-0000000002a1' AND charged_cents IS NULL AND NOT charge_mismatch
            FROM public.exos_price_disclosures WHERE session_id = 'af-pd-1'), 'PD1: header';
  ASSERT (SELECT count(*) FROM public.exos_price_disclosure_lines WHERE session_id = 'af-pd-1') = 2, 'PD1: two lines';
  ASSERT (SELECT line_total_cents = 8670 AND fee_cents = 0 AND tax_cents = 670 AND kind = 'ticket'
            FROM public.exos_price_disclosure_lines WHERE session_id = 'af-pd-1' AND line_no = 1), 'PD1: ticket line';
  ASSERT (SELECT item_id IS NULL AND item_name = 'Parking' FROM public.exos_price_disclosure_lines
           WHERE session_id = 'af-pd-1' AND line_no = 2), 'PD1: bad item id stored as NULL';
  -- First write wins: a retry with other numbers changes nothing.
  v := public.exos_record_price_disclosure('af-pd-1', 'usd', jsonb_build_array(
    jsonb_build_object('name','GA','quantity',1,'face_unit_cents',1,'unit_all_in_cents',1)));
  ASSERT v = 9670 AND (SELECT count(*) FROM public.exos_price_disclosure_lines WHERE session_id = 'af-pd-1') = 2,
    'PD1: retry is a no-op';
  RAISE NOTICE 'OK  PD1 disclosure row + lines written, first write wins';
END $$;

-- PD2. Bad input is refused.
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_record_price_disclosure('af-missing', 'usd', '[{"name":"x","quantity":1,"face_unit_cents":1,"unit_all_in_cents":1}]');
    RAISE EXCEPTION 'PD2: unknown session accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%not found%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.exos_record_price_disclosure('af-pd-2', 'usd', '[]');
    RAISE EXCEPTION 'PD2: empty lines accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%1 to 50 lines%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.exos_record_price_disclosure('af-pd-2', 'usd', '[{"name":"x","quantity":1,"face_unit_cents":-5,"unit_all_in_cents":1}]');
    RAISE EXCEPTION 'PD2: negative price accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_price_disclosures WHERE session_id = 'af-pd-2'), 'PD2: nothing half-written';
  RAISE NOTICE 'OK  PD2 bad input refused';
END $$;

-- PD3. Charged side + mismatch flag.
DO $$
DECLARE mm boolean;
BEGIN
  mm := public.exos_record_price_charged('af-pd-1', 9670, 'usd');
  ASSERT mm = false, 'PD3: exact charge is not a mismatch';
  ASSERT (SELECT charged_cents = 9670 AND charged_at IS NOT NULL FROM public.exos_price_disclosures WHERE session_id = 'af-pd-1'),
    'PD3: charged stored';
  -- session 2: shown 4335, Stripe charged 4500 -> flagged
  PERFORM public.exos_record_price_disclosure('af-pd-2', 'usd', jsonb_build_array(
    jsonb_build_object('kind','ticket','name','GA','quantity',1,'face_unit_cents',4000,'tax_cents',335,'unit_all_in_cents',4335)));
  mm := public.exos_record_price_charged('af-pd-2', 4500, 'usd');
  ASSERT mm = true, 'PD3: over-charge flagged';
  mm := public.exos_record_price_charged('af-pd-2', 4500, 'usd');
  ASSERT mm = true, 'PD3: idempotent';
  -- a currency switch is a mismatch too
  mm := public.exos_record_price_charged('af-pd-1', 9670, 'EUR');
  ASSERT mm = true, 'PD3: currency change flagged';
  mm := public.exos_record_price_charged('af-pd-1', 9670, 'usd');
  ASSERT mm = false, 'PD3: back to matching';
  ASSERT public.exos_record_price_charged('af-nope', 100, 'usd') IS NULL, 'PD3: no record -> NULL';
  RAISE NOTICE 'OK  PD3 charged amount recorded, mismatch flagged';
END $$;

-- PD4. The shown side is frozen.
DO $$
BEGIN
  BEGIN
    UPDATE public.exos_price_disclosures SET total_shown_cents = 1 WHERE session_id = 'af-pd-1';
    RAISE EXCEPTION 'PD4: shown total edited';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    UPDATE public.exos_price_disclosure_lines SET unit_all_in_cents = 1, line_total_cents = 2 WHERE session_id = 'af-pd-1';
    RAISE EXCEPTION 'PD4: line edited';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  PD4 shown side immutable';
END $$;

-- PD5. Export: owner / manager / finance yes; scanner, stranger, anon no.
DO $$
DECLARE u text; n int;
BEGIN
  FOREACH u IN ARRAY ARRAY['af000000-0000-0000-0000-000000000201','af000000-0000-0000-0000-000000000202',
                           'af000000-0000-0000-0000-000000000205'] LOOP
    PERFORM set_config('app.uid', u, false);
    SELECT count(*) INTO n FROM public.exos_price_disclosure_export('af000000-0000-0000-0000-0000000002e1');
    ASSERT n = 3, 'PD5: expected 3 lines for ' || u || ', got ' || n;
  END LOOP;
  ASSERT (SELECT bool_or(charge_mismatch) AND bool_or(NOT charge_mismatch)
            FROM public.exos_price_disclosure_export('af000000-0000-0000-0000-0000000002e1')), 'PD5: mismatch column';
  ASSERT (SELECT session_status FROM public.exos_price_disclosure_export('af000000-0000-0000-0000-0000000002e1') LIMIT 1) = 'pending',
    'PD5: session status joined';
  FOREACH u IN ARRAY ARRAY['af000000-0000-0000-0000-000000000203','af000000-0000-0000-0000-000000000204'] LOOP
    PERFORM set_config('app.uid', u, false);
    BEGIN
      PERFORM * FROM public.exos_price_disclosure_export('af000000-0000-0000-0000-0000000002e1');
      RAISE EXCEPTION 'PD5: % exported', u;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  PERFORM set_config('app.uid', '', false);
  BEGIN
    PERFORM * FROM public.exos_price_disclosure_export('af000000-0000-0000-0000-0000000002e1');
    RAISE EXCEPTION 'PD5: no-uid export';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  PD5 export role-checked';
END $$;

SET ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM * FROM public.exos_price_disclosure_export('af000000-0000-0000-0000-0000000002e1');
    RAISE EXCEPTION 'PD6: anon exported';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM public.exos_price_disclosures;
    RAISE EXCEPTION 'PD6: anon read the table';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  PD6 anon blocked';
END $$;
RESET ROLE;
SET ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_record_price_disclosure('af-pd-2', 'usd', '[]');
    RAISE EXCEPTION 'PD7: authenticated wrote a disclosure';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_record_price_charged('af-pd-2', 1, 'usd');
    RAISE EXCEPTION 'PD7: authenticated set charged';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM 1 FROM public.exos_price_disclosure_lines;
    RAISE EXCEPTION 'PD7: authenticated read lines directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  PD7 writers are service-only';
END $$;
RESET ROLE;

ROLLBACK;
