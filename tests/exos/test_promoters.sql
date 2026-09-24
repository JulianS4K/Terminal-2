-- ============================================================================
-- Promoters (mig 20260924233000). Runs after test_event_geo.sql in the same
-- DB; reuses the f1 org (owner f1…0b) and its paid "dj-kay" tickets from
-- test_checkout_attribution.sql (2 tickets at $20).
-- ============================================================================
\set ON_ERROR_STOP on

INSERT INTO auth.users(id,email,email_confirmed_at) VALUES
  ('f1000000-0000-0000-0000-0000000000cc','f1stranger@x.com',now());
INSERT INTO public.exos_org_memberships(org_id,user_id,role)
  SELECT 'f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-00000000000b','owner'
  WHERE NOT EXISTS (SELECT 1 FROM public.exos_org_memberships
                     WHERE org_id='f1000000-0000-0000-0000-000000000001' AND user_id='f1000000-0000-0000-0000-00000000000b');
-- Another promoter's sale on the same event, to prove kits don't mix.
INSERT INTO public.exos_tickets(event_id,org_id,tier_id,buyer_id,owner_id,status,price_paid,order_ref,promoter_id)
  VALUES ('f1000000-0000-0000-0000-0000000000e1','f1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-0000000000d9',
          'f1000000-0000-0000-0000-00000000000b','f1000000-0000-0000-0000-00000000000b','active',35,'f1-other','mo-b');

-- R1. Only owners / managers create promoters.
SELECT set_config('app.uid','f1000000-0000-0000-0000-0000000000cc',false);
DO $$
BEGIN
  BEGIN
    PERFORM public.exos_upsert_promoter('f1000000-0000-0000-0000-000000000001','dj-kay','DJ Kay');
    RAISE EXCEPTION 'R1: a stranger created a promoter';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  RAISE NOTICE 'OK  R1 strangers cannot create promoters';
END $$;

SELECT set_config('app.uid','f1000000-0000-0000-0000-00000000000b',false);
SELECT public.exos_upsert_promoter('f1000000-0000-0000-0000-000000000001','dj-kay','DJ Kay','Kay@Example.com');
SELECT public.exos_upsert_promoter('f1000000-0000-0000-0000-000000000001','mo-b','Mo B');

-- R2. The kit shows the promoter's own sales only, and needs the token.
DO $$
DECLARE tok uuid; kit jsonb; ev jsonb;
BEGIN
  SELECT kit_token INTO tok FROM public.exos_promoters WHERE code='dj-kay';
  ASSERT (SELECT email FROM public.exos_promoters WHERE code='dj-kay') = 'kay@example.com', 'R2: email normalized';
  kit := public.exos_promoter_kit(tok);
  ASSERT kit->'promoter'->>'code' = 'dj-kay', 'R2: right promoter';
  SELECT e INTO ev FROM jsonb_array_elements(kit->'events') e WHERE e->>'event_id' = 'f1000000-0000-0000-0000-0000000000e1';
  ASSERT (ev->>'tickets')::int = 2 AND (ev->>'gross')::numeric = 40, 'R2: own sales only, got ' || ev::text;
  ASSERT public.exos_promoter_kit(gen_random_uuid()) IS NULL, 'R2: a wrong token sees nothing';
  RAISE NOTICE 'OK  R2 private kit: own sales, token required';
END $$;

-- R3. Pausing closes the kit; rotating the token kills the old link.
DO $$
DECLARE pid uuid; old_tok uuid; new_tok uuid;
BEGIN
  SELECT id, kit_token INTO pid, old_tok FROM public.exos_promoters WHERE code='dj-kay';
  PERFORM public.exos_set_promoter_status(pid, 'paused');
  ASSERT public.exos_promoter_kit(old_tok) IS NULL, 'R3: paused kit closed';
  PERFORM public.exos_set_promoter_status(pid, 'active', true);
  SELECT kit_token INTO new_tok FROM public.exos_promoters WHERE id=pid;
  ASSERT new_tok <> old_tok AND public.exos_promoter_kit(old_tok) IS NULL AND public.exos_promoter_kit(new_tok) IS NOT NULL,
         'R3: rotated token replaces the old one';
  RAISE NOTICE 'OK  R3 pause + rotate';
END $$;

-- R4. Leaderboard for staff, ranked; strangers refused.
DO $$
DECLARE top text;
BEGIN
  SELECT code INTO top FROM public.exos_org_promoter_stats('f1000000-0000-0000-0000-000000000001') LIMIT 1;
  ASSERT top = 'dj-kay', 'R4: dj-kay (2 tickets) leads, got ' || coalesce(top,'null');
  ASSERT (SELECT tickets FROM public.exos_org_promoter_stats('f1000000-0000-0000-0000-000000000001') WHERE code='mo-b') = 1, 'R4: mo-b has 1';
  RAISE NOTICE 'OK  R4 leaderboard';
END $$;
SELECT set_config('app.uid','f1000000-0000-0000-0000-0000000000cc',false);
DO $$
BEGIN
  BEGIN
    PERFORM * FROM public.exos_org_promoter_stats('f1000000-0000-0000-0000-000000000001');
    RAISE EXCEPTION 'R4: a stranger read the leaderboard';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
SELECT set_config('app.uid','',false);

-- R5. The public link-in-bio card: name for active promoters only.
DO $$
DECLARE pid uuid; card jsonb;
BEGIN
  card := public.exos_public_promoter('f1-org', 'mo-b');
  ASSERT card->'promoter'->>'name' = 'Mo B' AND card->'org'->>'slug' = 'f1-org', 'R5: active promoter card';
  ASSERT public.exos_public_promoter('f1-org', 'nobody') IS NULL, 'R5: unknown code';
  ASSERT public.exos_public_promoter('other-org', 'mo-b') IS NULL, 'R5: code is scoped to its org';
  ASSERT NOT (card ? 'kit_token') AND NOT (card->'promoter' ? 'email'), 'R5: no private fields';
  PERFORM set_config('app.uid','f1000000-0000-0000-0000-00000000000b',false);
  SELECT id INTO pid FROM public.exos_promoters WHERE code='mo-b';
  PERFORM public.exos_set_promoter_status(pid, 'paused');
  ASSERT public.exos_public_promoter('f1-org', 'mo-b') IS NULL, 'R5: paused promoter hidden';
  PERFORM public.exos_set_promoter_status(pid, 'active');
  PERFORM set_config('app.uid','',false);
  RAISE NOTICE 'OK  R5 public promoter card';
END $$;
