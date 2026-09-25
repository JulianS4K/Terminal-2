-- ============================================================================
-- Edge-function audit fixes (mig 20260925020000): webhook claim/lease, API
-- rate limit, reconcile sweep bookkeeping, disputes recorded (not refunds).
-- Self-contained (own fixtures, rolled back), so it runs both in run_p0.sh and
-- against a copy of the real prod schema.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE
  v_uid uuid := 'ed9e0000-0000-0000-0000-000000000001';
  v_org uuid := 'ed9e0000-0000-0000-0000-0000000000a1';
  v_ev  uuid := 'ed9e0000-0000-0000-0000-0000000000e1';
  v_hk  uuid := 'ed9e0000-0000-0000-0000-0000000000b1';
  v_key uuid := 'ed9e0000-0000-0000-0000-0000000000c1';
BEGIN
  INSERT INTO auth.users (id) VALUES (v_uid) ON CONFLICT DO NOTHING;
  INSERT INTO public.exos_orgs (id, owner_uid, name, slug) VALUES (v_org, v_uid, 'Edge P1', 'edge-p1-test');
  INSERT INTO public.exos_events (id, org_id, name) VALUES (v_ev, v_org, 'Edge P1 event');
  INSERT INTO public.exos_webhooks (id, org_id, url) VALUES (v_hk, v_org, 'https://hooks.example.com/x');
  INSERT INTO public.exos_api_keys (id, org_id, key_prefix, key_hash) VALUES (v_key, v_org, 'sk_test_ed', 'edge-p1-hash');
END $$;

-- W1: claim is exclusive, leased, and reclaimable
DO $$
DECLARE
  v_hk uuid := 'ed9e0000-0000-0000-0000-0000000000b1';
  v_org uuid := 'ed9e0000-0000-0000-0000-0000000000a1';
  n int; r record; v_tok uuid;
BEGIN
  INSERT INTO public.exos_webhook_deliveries (id, webhook_id, org_id, event_type, payload, next_attempt_at) VALUES
    ('ed9e0000-0000-0000-0000-0000000000d1', v_hk, v_org, 'order.fulfilled', '{"a":1}', now() - interval '1 minute'),
    ('ed9e0000-0000-0000-0000-0000000000d2', v_hk, v_org, 'order.fulfilled', '{"a":2}', now() - interval '2 minutes'),
    ('ed9e0000-0000-0000-0000-0000000000d3', v_hk, v_org, 'order.fulfilled', '{"a":3}', now() + interval '1 hour');
  -- Keep unrelated queued rows (a prod copy may have some) out of the counts.
  UPDATE public.exos_webhook_deliveries SET next_attempt_at = now() + interval '1 day'
   WHERE status = 'pending' AND webhook_id <> v_hk;

  SELECT count(*) INTO n FROM public.exos_webhook_claim_batch(10);
  ASSERT n = 2, 'W1: two due rows claimed, got '||n;
  SELECT * INTO r FROM public.exos_webhook_deliveries WHERE id = 'ed9e0000-0000-0000-0000-0000000000d1';
  ASSERT r.status = 'sending' AND r.attempts = 1 AND r.claim_token IS NOT NULL AND r.claimed_at IS NOT NULL,
         'W1: claimed row is leased';
  v_tok := r.claim_token;
  SELECT count(*) INTO n FROM public.exos_webhook_claim_batch(10);
  ASSERT n = 0, 'W1: a second run claims nothing while the lease holds, got '||n;

  -- Lease expires (the run died) → reclaimed with a new token.
  UPDATE public.exos_webhook_deliveries SET claimed_at = now() - interval '20 minutes'
   WHERE id = 'ed9e0000-0000-0000-0000-0000000000d1';
  SELECT * INTO r FROM public.exos_webhook_claim_batch(10);
  ASSERT r.id = 'ed9e0000-0000-0000-0000-0000000000d1' AND r.attempts = 2 AND r.claim_token <> v_tok
         AND r.url = 'https://hooks.example.com/x' AND r.secret IS NOT NULL AND r.enabled,
         'W1: stale lease reclaimed with hook url/secret';

  -- Lease expired on the final attempt → dead, not retried forever.
  UPDATE public.exos_webhook_deliveries SET claimed_at = now() - interval '20 minutes', attempts = 8
   WHERE id = 'ed9e0000-0000-0000-0000-0000000000d2';
  SELECT count(*) INTO n FROM public.exos_webhook_claim_batch(10, 8);
  ASSERT n = 0, 'W1: exhausted row not claimed';
  ASSERT (SELECT status FROM public.exos_webhook_deliveries WHERE id = 'ed9e0000-0000-0000-0000-0000000000d2') = 'dead',
         'W1: exhausted stale lease goes dead';

  -- The not-yet-due row stayed pending.
  ASSERT (SELECT status FROM public.exos_webhook_deliveries WHERE id = 'ed9e0000-0000-0000-0000-0000000000d3') = 'pending',
         'W1: future row untouched';
  RAISE NOTICE 'OK  W1 webhook claim is exclusive, leased, reclaimable';
END $$;

-- R1: fixed-window rate limit per key
DO $$
DECLARE v_key uuid := 'ed9e0000-0000-0000-0000-0000000000c1'; i int;
BEGIN
  INSERT INTO public.exos_api_rate_windows (key_id, window_start, hits)
  VALUES (v_key, date_trunc('minute', now()) - interval '1 hour', 999);
  FOR i IN 1..3 LOOP
    ASSERT public.exos_api_rate_hit(v_key, 3), 'R1: hit '||i||' allowed';
  END LOOP;
  ASSERT NOT public.exos_api_rate_hit(v_key, 3), 'R1: 4th hit in the minute refused';
  ASSERT NOT EXISTS (SELECT 1 FROM public.exos_api_rate_windows
                      WHERE key_id = v_key AND window_start < date_trunc('minute', now())),
         'R1: old windows pruned';
  ASSERT NOT public.exos_api_rate_hit(NULL, 3), 'R1: null key refused';
  RAISE NOTICE 'OK  R1 API rate limit';
END $$;

-- M1 + D1: reconcile bookkeeping, dispute recorded without voiding
DO $$
DECLARE
  v_uid uuid := 'ed9e0000-0000-0000-0000-000000000001';
  v_org uuid := 'ed9e0000-0000-0000-0000-0000000000a1';
  v_ev  uuid := 'ed9e0000-0000-0000-0000-0000000000e1';
  r record; v text;
BEGIN
  INSERT INTO public.exos_checkout_sessions (session_id, event_id, org_id, buyer_uid, quantity, amount_cents, status)
  VALUES ('cs_edge_failed', v_ev, v_org, v_uid, 1, 5000, 'failed'),
         ('cs_edge_paid',   v_ev, v_org, v_uid, 1, 5000, 'fulfilled');
  INSERT INTO public.exos_order_payments (session_id, org_id, payment_intent, amount_cents, status)
  VALUES ('cs_edge_paid', v_org, 'pi_edge_paid', 5000, 'succeeded');

  ASSERT public.exos_reconcile_mark('cs_edge_failed', false, 'open') = 1, 'M1: first attempt';
  SELECT * INTO r FROM public.exos_checkout_sessions WHERE session_id = 'cs_edge_failed';
  ASSERT r.reconcile_checked_at IS NOT NULL AND r.reconcile_next_at > now() AND r.reconcile_done_at IS NULL,
         'M1: stamped + backed off, not done';
  PERFORM public.exos_reconcile_mark('cs_edge_failed', true, 'never charged');
  SELECT * INTO r FROM public.exos_checkout_sessions WHERE session_id = 'cs_edge_failed';
  ASSERT r.reconcile_attempts = 2 AND r.reconcile_done_at IS NOT NULL AND r.reconcile_note = 'never charged',
         'M1: done';
  UPDATE public.exos_checkout_sessions SET reconcile_attempts = 40 WHERE session_id = 'cs_edge_failed';
  PERFORM public.exos_reconcile_mark('cs_edge_failed', false);
  ASSERT (SELECT reconcile_next_at <= now() + interval '24 hours 1 minute' FROM public.exos_checkout_sessions
           WHERE session_id = 'cs_edge_failed'), 'M1: backoff capped at a day';
  RAISE NOTICE 'OK  M1 reconcile sweep bookkeeping';

  v := public.exos_record_dispute('cs_edge_paid', 'dp_1', 'needs_response', 'fraudulent', 5000, 'evt_1');
  SELECT * INTO r FROM public.exos_checkout_sessions WHERE session_id = 'cs_edge_paid';
  ASSERT v = 'needs_response' AND r.status = 'fulfilled' AND r.dispute_status = 'needs_response'
         AND r.disputed_at IS NOT NULL AND r.dispute_closed_at IS NULL,
         'D1: open dispute recorded, session stays fulfilled';
  ASSERT (SELECT meta->'dispute'->>'status' FROM public.exos_order_payments WHERE session_id = 'cs_edge_paid') = 'needs_response',
         'D1: payment row meta carries the dispute';
  v := public.exos_record_dispute('cs_edge_paid', 'dp_1', 'lost', 'fraudulent', 5000, 'evt_2');
  ASSERT v = 'lost' AND (SELECT dispute_closed_at IS NOT NULL FROM public.exos_checkout_sessions
                          WHERE session_id = 'cs_edge_paid'), 'D1: lost is closed';
  v := public.exos_record_dispute('cs_edge_paid', 'dp_1', 'needs_response', NULL, NULL, 'evt_1');
  ASSERT v = 'lost', 'D1: a replayed earlier event cannot reopen a closed dispute';
  ASSERT (SELECT status FROM public.exos_checkout_sessions WHERE session_id = 'cs_edge_paid') = 'fulfilled',
         'D1: recording never changes the order status';
  BEGIN
    PERFORM public.exos_record_dispute('cs_edge_paid', 'dp_1', 'Bad Status!');
    RAISE EXCEPTION 'D1: bad status accepted';
  EXCEPTION WHEN raise_exception THEN
    ASSERT SQLERRM LIKE '%invalid status%', 'D1: bad status refused';
  END;
  RAISE NOTICE 'OK  D1 dispute recorded, not a refund';
END $$;

-- G1: service_role only
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.exos_webhook_claim_batch(integer,integer,integer)', 'public.exos_api_rate_hit(uuid,integer)',
    'public.exos_reconcile_mark(text,boolean,text)', 'public.exos_record_dispute(text,text,text,text,integer,text)'
  ] LOOP
    ASSERT has_function_privilege('service_role', f, 'EXECUTE'), 'G1: service_role can run '||f;
    ASSERT NOT has_function_privilege('anon', f, 'EXECUTE'), 'G1: anon cannot run '||f;
    ASSERT NOT has_function_privilege('authenticated', f, 'EXECUTE'), 'G1: authenticated cannot run '||f;
    ASSERT (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure), 'G1: '||f||' is SECURITY DEFINER';
  END LOOP;
  ASSERT NOT has_table_privilege('anon', 'public.exos_api_rate_windows', 'SELECT'), 'G1: anon cannot read rate table';
  ASSERT NOT has_table_privilege('authenticated', 'public.exos_api_rate_windows', 'SELECT,INSERT'), 'G1: authenticated cannot touch rate table';
  ASSERT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.exos_api_rate_windows'::regclass), 'G1: RLS on';
  RAISE NOTICE 'OK  G1 grants';
END $$;

ROLLBACK;
