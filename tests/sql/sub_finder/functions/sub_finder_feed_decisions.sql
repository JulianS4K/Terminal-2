CREATE OR REPLACE FUNCTION public.sub_finder_feed_decisions()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c      public.sub_finder_config;
  r      record;
  o      public.sub_finder_order;
  v_lbl  text;
  v_at   timestamptz;
  v_reb  numeric;
  v_out  jsonb;
  v_n    integer := 0;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT (c.enabled AND c.n2b_intake_enabled AND c.n2b_decisions_enabled) OR c.n2b_key_id IS NULL
     OR NOT (c.n2b_key_id = ANY (c.key_ids)) THEN
    RETURN 0;
  END IF;
  SELECT k.label INTO v_lbl FROM public.mcp_api_keys k WHERE k.id = c.n2b_key_id;
  FOR r IN
    SELECT n.n2s_id, n.order_number,
           lower(btrim(n.raw->>'sub_decision'))            AS decision,
           btrim(n.raw->>'sub_decided_at')                 AS decided_at,
           nullif(btrim(n.raw->>'sub_listing_id'), '')     AS listing_id,
           nullif(lower(btrim(n.raw->>'sub_market')), '')  AS market,
           (n.raw->'sub_confirm' = 'true'::jsonb)          AS confirm,     -- only a real JSON true
           n.raw->>'sub_rebate_amount'                     AS rebate_txt,
           left(nullif(btrim(n.raw->>'sub_decided_by'), ''), 80) AS decided_by
      FROM public.n2s_items n
     WHERE NOT coalesce(n.is_terminal, false) AND n.item_source IS DISTINCT FROM 'gmail'
       AND public.sub_finder_need2buy(n.status, n.status_label, n.raw)
       AND lower(btrim(n.raw->>'sub_decision')) IN ('buy', 'offer')
       AND coalesce(btrim(n.raw->>'sub_decided_at'), '') <> ''
       AND NOT EXISTS (SELECT 1 FROM public.sub_finder_feed_decision d
                        WHERE d.n2s_id = n.n2s_id AND d.decided_at = btrim(n.raw->>'sub_decided_at'))
     ORDER BY n.n2s_updated_at NULLS LAST, n.n2s_id LIMIT c.n2b_batch
  LOOP
    -- the lookup this decision answers: the watched one for this order, already answered
    SELECT * INTO o FROM public.sub_finder_order s
     WHERE s.key_id = c.n2b_key_id AND s.order_number = r.order_number AND s.watching
       AND s.state IN ('cover', 'no_cover')
     ORDER BY s.updated_at DESC LIMIT 1;
    CONTINUE WHEN NOT FOUND;                         -- no answer of ours yet: it waits, untouched
    v_out := NULL;
    BEGIN
      v_at := r.decided_at::timestamptz;
    EXCEPTION WHEN OTHERS THEN
      v_out := jsonb_build_object('error', 'invalid', 'detail', 'sub_decided_at is not a date and time');
    END;
    IF v_out IS NULL AND v_at < (SELECT j.created_at FROM public.sub_finder_job j WHERE j.job_id = o.job_id) THEN
      v_out := jsonb_build_object('error', 'stale', 'detail', 'this decision was made before our answer existed');
    ELSIF v_out IS NULL AND v_at > now() + interval '10 minutes' THEN
      v_out := jsonb_build_object('error', 'invalid', 'detail', 'sub_decided_at is in the future');
    ELSIF v_out IS NULL AND r.listing_id IS NULL THEN
      v_out := jsonb_build_object('error', 'invalid', 'detail', 'sub_listing_id is required');
    END IF;
    v_reb := NULL;
    IF v_out IS NULL AND coalesce(btrim(r.rebate_txt), '') <> '' THEN
      BEGIN
        v_reb := r.rebate_txt::numeric;
      EXCEPTION WHEN OTHERS THEN
        v_out := jsonb_build_object('error', 'invalid', 'detail', 'sub_rebate_amount is not a number');
      END;
    END IF;
    IF v_out IS NULL THEN
      BEGIN
        IF r.decision = 'buy' THEN
          v_out := public.sub_finder_buy_confirmed(
            c.n2b_key_id, coalesce(v_lbl, 'crm feed'), o.job_id, r.order_number, r.listing_id,
            coalesce('feed / ' || r.decided_by, 'feed'), r.confirm);
        ELSE
          v_out := public.sub_finder_gt_offer_confirmed(
            c.n2b_key_id, coalesce(v_lbl, 'crm feed'), r.order_number, r.listing_id, r.market,
            coalesce('feed / ' || r.decided_by, 'feed'), v_reb, r.confirm);
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_out := jsonb_build_object('error', 'failed', 'detail', left(SQLERRM, 200));
      END;
    END IF;
    INSERT INTO public.sub_finder_feed_decision
      (n2s_id, decided_at, order_number, key_id, decision, listing_id, market, confirm, rebate, decided_by, outcome, result)
    VALUES (r.n2s_id, r.decided_at, r.order_number, c.n2b_key_id, r.decision, r.listing_id, r.market,
            coalesce(r.confirm, false), v_reb, r.decided_by,
            coalesce(v_out->>'error', v_out->>'state', 'unknown'), v_out)
    ON CONFLICT DO NOTHING;
    UPDATE public.sub_finder_order SET updated_at = now() WHERE job_id = o.job_id AND idx = o.idx;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END
$function$

