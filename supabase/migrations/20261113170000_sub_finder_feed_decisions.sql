-- Migration 20261113170000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_feed_decision,sub_finder_feed_decisions,sub_finder_refresh,sub_finder_order_json · reads:n2s_items,sub_finder_order · pre:20261113160000
--
-- SUB FINDER: the CRM's decision is read from its own N2S feed.
--
-- Operator 2026-11-13: "Build the CRM feed decision reading". A need2buy item in the CRM's
-- Need-to-Sub feed (which we poll every 30 seconds, 20261113160000) may now carry the CRM's
-- answer to what we found, so the CRM does not have to call the buy / offer-sub routes:
--
--   sub_decision        'buy' | 'offer' | 'none' (none, or absent: nothing is done)
--   sub_listing_id      the listing_id of the cover it chose, as we returned it
--   sub_market          its market (optional; needed when two markets share a listing id)
--   sub_confirm         JSON true: a person has seen the cover's flags and accepts them
--   sub_rebate_amount   dollars, 0 allowed (offers; required when the sub is rows back)
--   sub_decided_by      who decided (optional)
--   sub_decided_at      a UTC instant: THE KEY. A decision is carried out once per
--                       (item, sub_decided_at); to decide again, send a new instant
--
-- sub_finder_feed_decisions() (called by the one-minute refresh, after the intake):
--   * only open CRM-feed items labelled need2buy, whose order has a lookup we already answered
--     under sub_finder_config.n2b_key_id;
--   * a decision made BEFORE that lookup was created is never carried out (it cannot be an
--     answer to it), nor one dated more than 10 minutes in the future;
--   * 'buy'   -> sub_finder_buy_confirmed(...)       exactly what POST /orders/{n}/buy calls
--     'offer' -> sub_finder_gt_offer_confirmed(...)  exactly what POST /orders/{n}/offer-sub calls
--     so every rule of those routes holds: the key's buy / offer permission, the cover must be
--     one we quoted, the order must match our own records, the sale must still be live, one
--     buy / one live offer per order, flags need sub_confirm, rows back need a rebate amount;
--   * what happened is written to sub_finder_feed_decision and shown on the order as
--     `feed_decision` (so a refusal such as confirm_needed is visible to the CRM);
--   * a decision is consumed whatever the outcome: a refused one is not retried by itself.
-- At most n2b_batch decisions a round. OFF until n2b_decisions_enabled is true.
--
-- sub_finder_refresh and sub_finder_order_json are patched in place; each patch fails loudly
-- if the line it edits is not there exactly once, and does nothing on a second run.
--
-- rollback: UPDATE sub_finder_config SET n2b_decisions_enabled = false;
--           re-apply sub_finder_refresh (20261113160000) and sub_finder_order_json (20261113140000) without these lines;
--           DROP FUNCTION public.sub_finder_feed_decisions(); DROP TABLE public.sub_finder_feed_decision;
--           ALTER TABLE public.sub_finder_config DROP COLUMN n2b_decisions_enabled;

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS n2b_decisions_enabled boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS public.sub_finder_feed_decision (
  n2s_id       bigint      NOT NULL,                -- n2s_items.n2s_id
  decided_at   text        NOT NULL,                -- the CRM's sub_decided_at, as sent
  order_number text        NOT NULL,
  key_id       bigint      NOT NULL,
  decision     text        NOT NULL,
  listing_id   text,
  market       text,
  confirm      boolean     NOT NULL DEFAULT false,
  rebate       numeric,
  decided_by   text,
  outcome      text        NOT NULL,                -- 'requested' or the refusal's error code
  result       jsonb,                               -- what the buy / offer function answered
  acted_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (n2s_id, decided_at)
);
CREATE INDEX IF NOT EXISTS sub_finder_feed_decision_order_idx ON public.sub_finder_feed_decision (order_number, key_id, acted_at DESC);
ALTER TABLE public.sub_finder_feed_decision ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sub_finder_feed_decision FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.sub_finder_feed_decision IS
  'Decisions read from the CRM N2S feed (sub_decision / sub_decided_at) and what carrying each out answered '
  '(20261113170000). One row per (item, sub_decided_at): a decision is carried out once.';

CREATE OR REPLACE FUNCTION public.sub_finder_feed_decisions()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
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
$$;
REVOKE ALL ON FUNCTION public.sub_finder_feed_decisions() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_feed_decisions() TO service_role;

-- the refresh job carries out the decisions right after the intake
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.sub_finder_refresh()'::regprocedure);
  v_old text := $o$PERFORM public.sub_finder_n2b_intake();$o$;
  v_new text := $n$PERFORM public.sub_finder_n2b_intake();
  -- and the CRM's decisions on them (sub_decision in the same feed, 20261113170000)
  PERFORM public.sub_finder_feed_decisions();$n$;
BEGIN
  IF position('sub_finder_feed_decisions' IN v_def) > 0 THEN RETURN; END IF;  -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_refresh: the line to patch was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;

-- every order shows what became of the last decision read from the feed
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.sub_finder_order_json(public.sub_finder_order)'::regprocedure);
  v_old text := $o$'notes', o.crm_notes,$o$;
  v_new text := $n$'notes', o.crm_notes,
    -- the last decision read from your N2S feed for this order, and what carrying it out answered
    'feed_decision', (SELECT jsonb_build_object(
                         'decision', d.decision, 'listing_id', d.listing_id, 'decided_at', d.decided_at,
                         'decided_by', d.decided_by, 'outcome', d.outcome,
                         'detail', d.result->>'detail', 'flags', d.result->'flags',
                         'acted_at', to_char(d.acted_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
                        FROM public.sub_finder_feed_decision d
                       WHERE d.order_number = o.order_number AND d.key_id = o.key_id
                       ORDER BY d.acted_at DESC LIMIT 1),$n$;
BEGIN
  IF position('feed_decision' IN v_def) > 0 THEN RETURN; END IF;              -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_order_json: the line to patch was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;
