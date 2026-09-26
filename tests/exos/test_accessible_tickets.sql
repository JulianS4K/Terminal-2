-- ============================================================================
-- Accessible ticket options (mig 20260926090000). Self-contained (ac… prefix),
-- rolled back at the end.
--   A1 accessible tier + event access info are public; bad values rejected
--   A2 holder sets needs; only known needs; not someone else's ticket
--   A3 needs are not readable from the table, only via owner/staff RPCs
--   A4 a transfer drops the old holder's needs
--   A5 staff list + door download carry ticket and guest needs
--   A6 guest needs: staff and the list's promoter only
--   psql -d <db> -v ON_ERROR_STOP=1 -f tests/exos/test_accessible_tickets.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
GRANT USAGE ON SCHEMA auth TO anon, authenticated;
-- Stub chains have no profiles table (prod does); rolled back with everything else.
CREATE TABLE IF NOT EXISTS public.exos_profiles (id uuid PRIMARY KEY, display_name text);

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('ac000000-0000-0000-0000-0000000000a0','ac-owner@x.com',now()),
  ('ac000000-0000-0000-0000-0000000000a1','ac-scanner@x.com',now()),
  ('ac000000-0000-0000-0000-0000000000a2','ac-buyer@x.com',now()),
  ('ac000000-0000-0000-0000-0000000000a3','ac-friend@x.com',now()),
  ('ac000000-0000-0000-0000-0000000000a4','ac-stranger@x.com',now());
INSERT INTO public.exos_orgs(id,name,slug,owner_uid) VALUES
  ('ac000000-0000-0000-0000-000000000001','AC Org','ac-org','ac000000-0000-0000-0000-0000000000a0');
INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  ('ac000000-0000-0000-0000-000000000001','ac000000-0000-0000-0000-0000000000a0','owner'),
  ('ac000000-0000-0000-0000-000000000001','ac000000-0000-0000-0000-0000000000a1','scanner');
INSERT INTO public.exos_events(id,org_id,name,slug,status,accessibility) VALUES
  ('ac000000-0000-0000-0000-0000000000e1','ac000000-0000-0000-0000-000000000001','AC Night','ac-night','published',
   '{"features":["step_free","accessible_restrooms","asl"],"notes":"Lift at the side door.","contact":"access@ac.org"}');
INSERT INTO public.exos_ticket_tiers(id,event_id,name,price,capacity,accessible,accessible_note) VALUES
  ('ac000000-0000-0000-0000-0000000000d1','ac000000-0000-0000-0000-0000000000e1','GA',0,100,false,NULL),
  ('ac000000-0000-0000-0000-0000000000d2','ac000000-0000-0000-0000-0000000000e1','Wheelchair space',0,4,true,'Space + 1 companion seat');
INSERT INTO public.exos_tickets(id,event_id,org_id,tier_id,tier_name,buyer_id,owner_id,status,barcode_secret,price_paid,order_ref,attendee_name) VALUES
  ('ac000000-0000-0000-0000-0000000000c1','ac000000-0000-0000-0000-0000000000e1','ac000000-0000-0000-0000-000000000001',
   'ac000000-0000-0000-0000-0000000000d2','Wheelchair space','ac000000-0000-0000-0000-0000000000a2','ac000000-0000-0000-0000-0000000000a2',
   'active',gen_random_uuid()::text,0,'ac-o1','Robin'),
  ('ac000000-0000-0000-0000-0000000000c2','ac000000-0000-0000-0000-0000000000e1','ac000000-0000-0000-0000-000000000001',
   'ac000000-0000-0000-0000-0000000000d1','GA','ac000000-0000-0000-0000-0000000000a2','ac000000-0000-0000-0000-0000000000a2',
   'active',gen_random_uuid()::text,0,'ac-o1',NULL);
INSERT INTO public.exos_promoters(id,org_id,code,name) VALUES
  ('ac000000-0000-0000-0000-0000000000b1','ac000000-0000-0000-0000-000000000001','ac-nina','Nina'),
  ('ac000000-0000-0000-0000-0000000000b2','ac000000-0000-0000-0000-000000000001','ac-omar','Omar');

-- A1 ---------------------------------------------------------------------------
-- The public views exist on prod-shaped schemas; stub chains skip those checks.
DO $$
BEGIN
  IF to_regclass('public.exos_public_tiers') IS NOT NULL AND to_regclass('public.exos_public_events') IS NOT NULL THEN
    ASSERT (SELECT accessible AND accessible_note = 'Space + 1 companion seat' FROM public.exos_public_tiers
             WHERE id = 'ac000000-0000-0000-0000-0000000000d2'), 'A1: accessible tier is public';
    ASSERT (SELECT accessibility->'features' ? 'asl' FROM public.exos_public_events
             WHERE id = 'ac000000-0000-0000-0000-0000000000e1'), 'A1: access info is public';
  ELSE
    RAISE NOTICE 'A1: no public views in this schema, view checks skipped';
  END IF;
  BEGIN
    UPDATE public.exos_events SET accessibility = '{"features":["teleporter"]}' WHERE id = 'ac000000-0000-0000-0000-0000000000e1';
    RAISE EXCEPTION 'A1: unknown feature accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.exos_events SET accessibility = '{"secret":"x"}' WHERE id = 'ac000000-0000-0000-0000-0000000000e1';
    RAISE EXCEPTION 'A1: unknown key accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    UPDATE public.exos_ticket_tiers SET accessible_note = repeat('x', 141) WHERE id = 'ac000000-0000-0000-0000-0000000000d2';
    RAISE EXCEPTION 'A1: long note accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'OK  A1 accessible tier + access info public, bad values rejected';
END $$;
SET LOCAL ROLE anon;
DO $$
BEGIN
  IF to_regclass('public.exos_public_tiers') IS NOT NULL AND to_regclass('public.exos_public_events') IS NOT NULL THEN
    ASSERT (SELECT count(*) FROM public.exos_public_tiers WHERE accessible) >= 1, 'A1: anon reads the accessible flag';
    ASSERT (SELECT accessibility->>'contact' FROM public.exos_public_events
             WHERE id = 'ac000000-0000-0000-0000-0000000000e1') = 'access@ac.org', 'A1: anon reads the access contact';
  END IF;
END $$;
RESET ROLE;

-- A2 ---------------------------------------------------------------------------
SELECT set_config('app.uid','ac000000-0000-0000-0000-0000000000a2',true);
DO $$
DECLARE v text[];
BEGIN
  v := public.exos_set_ticket_access_needs('ac000000-0000-0000-0000-0000000000c1', ARRAY['wheelchair','companion','wheelchair']);
  ASSERT v = ARRAY['companion','wheelchair'], 'A2: deduped + sorted, got ' || v::text;
  ASSERT public.exos_ticket_access_needs('ac000000-0000-0000-0000-0000000000c1') = ARRAY['companion','wheelchair'], 'A2: owner reads back';
  BEGIN
    PERFORM public.exos_set_ticket_access_needs('ac000000-0000-0000-0000-0000000000c2', ARRAY['jetpack']);
    RAISE EXCEPTION 'A2: unknown need accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'OK  A2 holder sets needs, unknown needs rejected';
END $$;
SELECT set_config('app.uid','ac000000-0000-0000-0000-0000000000a4',true);
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_set_ticket_access_needs('ac000000-0000-0000-0000-0000000000c1', ARRAY['asl']);
    RAISE EXCEPTION 'A2: stranger set needs';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  ASSERT public.exos_ticket_access_needs('ac000000-0000-0000-0000-0000000000c1') IS NULL, 'A2: stranger reads nothing';
  BEGIN
    PERFORM public.exos_event_access_requests('ac000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'A2: stranger read the access list';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;

-- A3 ---------------------------------------------------------------------------
SELECT set_config('app.uid','ac000000-0000-0000-0000-0000000000a2',true);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  BEGIN
    PERFORM access_needs FROM public.exos_tickets WHERE id = 'ac000000-0000-0000-0000-0000000000c1';
    RAISE EXCEPTION 'A3: access_needs readable from the table';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  ASSERT public.exos_ticket_access_needs('ac000000-0000-0000-0000-0000000000c1') = ARRAY['companion','wheelchair'],
    'A3: RPC works as authenticated';
  RAISE NOTICE 'OK  A3 needs readable only through RPCs';
END $$;
RESET ROLE;

-- A4 ---------------------------------------------------------------------------
-- Ticket c1 changes hands (as the transfer claim does: owner_id moves).
UPDATE public.exos_tickets SET owner_id = 'ac000000-0000-0000-0000-0000000000a3' WHERE id = 'ac000000-0000-0000-0000-0000000000c1';
SELECT set_config('app.uid','ac000000-0000-0000-0000-0000000000a3',true);
DO $$
BEGIN
  ASSERT public.exos_ticket_access_needs('ac000000-0000-0000-0000-0000000000c1') = '{}'::text[], 'A4: new holder starts blank';
  PERFORM public.exos_set_ticket_access_needs('ac000000-0000-0000-0000-0000000000c1', ARRAY['seat']);
  ASSERT public.exos_ticket_access_needs('ac000000-0000-0000-0000-0000000000c1') = ARRAY['seat'], 'A4: new holder sets own';
  RAISE NOTICE 'OK  A4 a transfer drops the old holder''s needs';
END $$;
-- The old holder gets the ticket back without re-stating: their old needs stay dropped.
UPDATE public.exos_tickets SET owner_id = 'ac000000-0000-0000-0000-0000000000a2' WHERE id = 'ac000000-0000-0000-0000-0000000000c1';
SELECT set_config('app.uid','ac000000-0000-0000-0000-0000000000a2',true);
DO $$
BEGIN
  ASSERT public.exos_ticket_access_needs('ac000000-0000-0000-0000-0000000000c1') = '{}'::text[], 'A4: needs set by someone else never show';
  PERFORM public.exos_set_ticket_access_needs('ac000000-0000-0000-0000-0000000000c1', ARRAY['wheelchair']);
  PERFORM public.exos_set_ticket_access_needs('ac000000-0000-0000-0000-0000000000c2', '{}');
  -- A change of owner also clears the attendee name (mig 20260911060000); name it again.
  PERFORM public.exos_set_ticket_attendee('ac000000-0000-0000-0000-0000000000c1', 'Robin');
END $$;

-- A5 + A6 ----------------------------------------------------------------------
SELECT set_config('app.uid','ac000000-0000-0000-0000-0000000000a0',true);   -- owner
DO $$
DECLARE l_nina uuid; l_staff uuid; g_nina uuid; g_staff uuid; tok uuid; tok_o uuid; x jsonb; v text[];
BEGIN
  l_nina := public.exos_upsert_guest_list('ac000000-0000-0000-0000-0000000000e1','Nina''s list',5,
                                          'ac000000-0000-0000-0000-0000000000b1',false,2);
  l_staff := public.exos_upsert_guest_list('ac000000-0000-0000-0000-0000000000e1','Staff comps');
  g_staff := public.exos_add_guest(l_staff, 'Dana Staff');
  v := public.exos_set_guest_access_needs(g_staff, ARRAY['asl']);
  ASSERT v = ARRAY['asl'], 'A6: staff sets guest needs';

  SELECT kit_token INTO tok FROM public.exos_promoters WHERE code = 'ac-nina';
  SELECT kit_token INTO tok_o FROM public.exos_promoters WHERE code = 'ac-omar';
  g_nina := public.exos_promoter_add_guest(tok, l_nina, 'Sam Guest', 1);
  ASSERT public.exos_promoter_set_guest_access_needs(tok, g_nina, ARRAY['step_free','service_animal']) = ARRAY['service_animal','step_free'],
    'A6: promoter sets own guest needs';
  BEGIN
    PERFORM public.exos_promoter_set_guest_access_needs(tok_o, g_nina, ARRAY['asl']);
    RAISE EXCEPTION 'A6: another promoter set needs on Nina''s guest';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_promoter_set_guest_access_needs(tok, g_staff, ARRAY['asl']);
    RAISE EXCEPTION 'A6: promoter set needs on a staff list guest';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(public.exos_promoter_guest_lists(tok)) l,
                               jsonb_array_elements(l->'entries') e
                  WHERE e->>'guest_name' = 'Sam Guest' AND e->'access_needs' ? 'step_free'), 'A6: promoter portal shows needs';

  -- A5: staff list
  ASSERT (SELECT count(*) FROM public.exos_event_access_requests('ac000000-0000-0000-0000-0000000000e1')) = 3,
    'A5: 1 ticket + 2 guests with needs';
  ASSERT EXISTS (SELECT 1 FROM public.exos_event_access_requests('ac000000-0000-0000-0000-0000000000e1')
                  WHERE source = 'ticket' AND name = 'Robin' AND detail = 'Wheelchair space' AND needs = ARRAY['wheelchair']),
    'A5: ticket row carries name, ticket type, needs';
  RAISE NOTICE 'OK  A6 guest needs: staff + own promoter only; portal shows them';
END $$;
SELECT set_config('app.uid','ac000000-0000-0000-0000-0000000000a1',true);   -- scanner
DO $$
DECLARE x jsonb;
BEGIN
  x := public.exos_event_door_extras('ac000000-0000-0000-0000-0000000000e1');
  ASSERT x->'ticket_access'->'ac000000-0000-0000-0000-0000000000c1' = '["wheelchair"]'::jsonb, 'A5: door sees ticket needs';
  ASSERT NOT (x->'ticket_access' ? 'ac000000-0000-0000-0000-0000000000c2'), 'A5: tickets without needs left out';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(x->'guests') g
                  WHERE g->>'guest_name' = 'Dana Staff' AND g->'access_needs' = '["asl"]'::jsonb), 'A5: door sees guest needs';
  ASSERT (SELECT count(*) FROM public.exos_event_access_requests('ac000000-0000-0000-0000-0000000000e1')) = 3,
    'A5: scanner reads the access list';
  RAISE NOTICE 'OK  A5 staff list + door download carry needs';
END $$;
SET LOCAL ROLE anon;
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_event_access_requests('ac000000-0000-0000-0000-0000000000e1');
    RAISE EXCEPTION 'A5: anon may call the access list';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.exos_set_ticket_access_needs('ac000000-0000-0000-0000-0000000000c1', ARRAY['asl']);
    RAISE EXCEPTION 'A5: anon may set needs';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;

ROLLBACK;
