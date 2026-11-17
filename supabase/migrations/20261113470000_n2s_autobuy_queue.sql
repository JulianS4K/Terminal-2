-- Migration 20261113470000 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_exec,n2s_autobuy_config,n2s_autobuy_job_json,n2s_autobuy_queue_job,n2s_autobuy_queue_result,n2s_autobuy_live_claim · reads:manual_sub_buy_file_n2s,n2s_items,n2s_gt_order_dryrun · pre:20261113440000,20261113460000
--
-- ONE BUYER, stage 3, the N2S auto-buyer's side: N2S may FILE its buys into the one queue
-- (manual_sub_buy, lane D0) instead of sending them from its own worker.
--
-- Operator 2026-11-13: "allow stage 3, n2s gets priority in queue". Interface agreed with
-- lane D0 in bot_chat 6689 / 6691 / 6695; their side is mig 20261113440000.
--
-- NOTHING HERE CHANGES WHAT RUNS WHEN APPLIED. n2s_autobuy_config.buyer is added as 'own' (the
-- N2S worker buys, as today). Only with buyer = 'queue', flipped by hand once lane D0's worker
-- is deployed, does the claim file buys instead of handing them out.
--
--   1. n2s_autobuy_exec.phase gains 'queued': filed into the one queue, not sent yet. Not
--      'buying': the claim's stale-lease sweep turns an expired 'buying' row into buy_unknown
--      and flips the kill switch, and a row waiting in the queue holds no lease of ours.
--      Nothing that reads phases treats 'queued' as bought: the poll, the outcome emails, the
--      results feed (rows with a purchase id only) and the shared spend / EVO in-flight counts
--      (lane D0 counts the queue's own row while it is being bought) all skip it.
--   2. n2s_autobuy_config.buyer ('own' | 'queue', default 'own').
--   3. n2s_autobuy_job_json(exec_id, action): the {action, row, cfg} job the claim hands its
--      worker, moved out of the claim word for word, so the claim and the queue build it one way.
--   4. n2s_autobuy_live_claim (md5-guarded anchor patch on the 2026-11-13 prod text, which holds
--      lane D0's sub_buy_gate anchor from 20261113430000):
--        - with buyer = 'queue', a buy the claim would hand out is filed instead
--          (manual_sub_buy_file_n2s(exec_id, NULL, NULL): lane D0 computes buy_by =
--          sub_confirm_by - GREATEST(min_confirm_window_s, seller_window_in_hand_s), our rule in
--          bot_chat 6691 E, and the ceiling = sub_total_usd + est_tax_usd). The live run is spent
--          when filed, as for our own buy. Filed: phase 'queued', no lease, the claim returns
--          NULL (the deployed worker reads NULL as idle). Not filed (NULL back: the sale already
--          has a live buy, the row was filed before, or its time has passed): phase 'stopped',
--          reason queue_file_refused, and the run goes back to its source. One row per call:
--          one filing per tick, as one buy per tick today.
--        - the job is built by n2s_autobuy_job_json (same JSON as before).
--   5. n2s_autobuy_queue_job(exec_id): the job for a 'queued' row, read when lane D0's claim
--      hands it out (fresh config, the row, this source's caps). NULL for any other row.
--   6. n2s_autobuy_queue_result(exec_id, state, patch): the queue's result on our row, in lane
--      D0's transaction (manual_sub_buy_record, and their claim for queue_expired and
--      worker_lost_mid_buy). Acts on a 'queued' row:
--        bought  -> buy_sent with the purchase id, state and charged total; our poll then
--                   follows it and accepts the sale exactly as for our own buy. Without a
--                   purchase id, or when n2s_result said buy_unknown -> buy_unknown.
--        stopped -> stopped with the reasons; the run goes back unless the market refused the
--                   buy (buy_failed), the same rule as n2s_autobuy_live_record.
--        unknown -> buy_unknown and OUR kill switch.
--      A repeat changes nothing. A bought / unknown for a row that is no longer 'queued' and
--      does not already carry that purchase (a person stopped it while the queue was buying) is
--      a purchase nobody follows: buy_unknown, reason queue_result_late, kill switch.
--      'unknown' flips the kill switch on every call, a repeat included (fail closed).
--
-- The Python half (core/n2s_autobuy_live.py, same PR): pre_buy() runs every N2S guard and
-- builds the one request; n2s_result() reads the market's answer into the patch this function
-- takes. Lane D0's worker calls both; our own worker uses the same two functions.
--
-- Nothing here calls a market.
--
-- rollback: UPDATE n2s_autobuy_config SET buyer = 'own' stops new filings at once. Full: re-create
--           n2s_autobuy_live_claim from its prod text (md5 66e87bc133122fd63259639a162a5070), then
--           DROP FUNCTION n2s_autobuy_queue_result(bigint, text, jsonb), n2s_autobuy_queue_job(bigint),
--           n2s_autobuy_job_json(bigint, text); drop the buyer column; restore the phase check
--           without 'queued' (once no row is queued).

-- ── 1. the 'queued' phase ──────────────────────────────────────────────────
ALTER TABLE public.n2s_autobuy_exec DROP CONSTRAINT IF EXISTS n2s_autobuy_exec_phase_check;
ALTER TABLE public.n2s_autobuy_exec ADD CONSTRAINT n2s_autobuy_exec_phase_check
  CHECK (phase = ANY (ARRAY['queued', 'buying', 'buy_sent', 'sub_accepted', 'accepted', 'stopped', 'buy_unknown',
                            'accept_failed', 'accept_unknown']));

-- ── 2. who sends the buy ───────────────────────────────────────────────────
ALTER TABLE public.n2s_autobuy_config ADD COLUMN IF NOT EXISTS buyer text NOT NULL DEFAULT 'own';
ALTER TABLE public.n2s_autobuy_config DROP CONSTRAINT IF EXISTS n2s_autobuy_config_buyer_check;
ALTER TABLE public.n2s_autobuy_config ADD CONSTRAINT n2s_autobuy_config_buyer_check CHECK (buyer IN ('own', 'queue'));
COMMENT ON COLUMN public.n2s_autobuy_config.buyer IS
  '''own'' = the N2S live worker sends its buys; ''queue'' = the claim files them into the one queue (manual_sub_buy, lane D0) and the sub finder''s worker sends them. Flip to queue only once that worker is deployed. 20261113470000.';

-- ── 3. the job, built one way ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_autobuy_job_json(p_exec_id bigint, p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c      public.n2s_autobuy_config%ROWTYPE;
  e      public.n2s_autobuy_exec%ROWTYPE;
  v_sale text;
  v_gt   boolean;
  v_gt_event bigint;
BEGIN
  SELECT * INTO e FROM public.n2s_autobuy_exec WHERE exec_id = p_exec_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id;
  SELECT n2s_order_key INTO v_sale FROM public.n2s_items WHERE n2s_id = e.n2s_id;
  v_gt := (e.sub_source = 'gotickets');
  SELECT d.gt_event_id INTO v_gt_event FROM public.n2s_gt_order_dryrun d WHERE d.dryrun_id = e.dryrun_id;

  RETURN jsonb_build_object(
    'action', p_action,
    'row', to_jsonb(e) || jsonb_build_object('sale_order_key', v_sale, 'gt_event_id', v_gt_event),
    'cfg', jsonb_build_object(
      -- this sub source's caps (20261113400000: GoTickets has its own)
      'per_order_cap_usd', CASE WHEN v_gt THEN c.gt_per_order_cap_usd ELSE c.per_order_cap_usd END,
      'daily_cap_usd', CASE WHEN v_gt THEN c.gt_daily_cap_usd ELSE c.daily_cap_usd END,
      'max_buys_per_day', c.max_buys_per_day, 'max_failures_per_day', c.max_failures_per_day,
      'approval_over_usd', c.approval_over_usd,
      'project_cap_usd', CASE WHEN v_gt THEN c.gt_project_cap_usd ELSE c.project_cap_usd END,
      'min_event_lead_s', extract(epoch FROM c.min_event_lead)::int,
      'min_confirm_window_s', c.min_confirm_window_s, 'buy_sources', to_jsonb(c.buy_sources),
      'evo_buyer_office_id', c.evo_buyer_office_id, 'evo_reviewer_id', c.evo_reviewer_id,
      'evo_email_address_id', c.evo_email_address_id,
      'tax_quote', c.tax_quote,
      'gt_buyer_email', c.gt_buyer_email, 'gt_buyer_phone', c.gt_buyer_phone,
      'gt_billing_address', c.gt_billing_address, 'gt_recipient', c.gt_recipient,
      'gt_gift_card_ids', to_jsonb(c.gt_gift_card_ids)));
END $function$;

REVOKE ALL ON FUNCTION public.n2s_autobuy_job_json(bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_autobuy_job_json(bigint, text) TO service_role;

-- ── 4. the claim files the buy when buyer = 'queue' ────────────────────────
DO $do$
DECLARE d text; n int; p_from int; p_to int;
  a_decl  CONSTANT text := E'  v_gt_event bigint;\nBEGIN\n';
  a_queue CONSTANT text := E'  IF v_act IS NULL THEN RETURN NULL; END IF;\n';
  a_from  CONSTANT text := E'  SELECT n2s_order_key INTO v_sale FROM public.n2s_items WHERE n2s_id = e.n2s_id;\n';
  a_to    CONSTANT text := E'      \'gt_gift_card_ids\', to_jsonb(c.gt_gift_card_ids)));\n';
BEGIN
  d := pg_get_functiondef('public.n2s_autobuy_live_claim()'::regprocedure);
  IF md5(d) <> '66e87bc133122fd63259639a162a5070' THEN
    RAISE EXCEPTION 'n2s_autobuy_live_claim drifted from its 2026-11-13 prod text (20261113430000) — re-derive this migration';
  END IF;
  FOREACH n IN ARRAY ARRAY[
      (length(d) - length(replace(d, a_decl, ''))) / length(a_decl),
      (length(d) - length(replace(d, a_queue, ''))) / length(a_queue),
      (length(d) - length(replace(d, a_from, ''))) / length(a_from),
      (length(d) - length(replace(d, a_to, ''))) / length(a_to)] LOOP
    IF n <> 1 THEN RAISE EXCEPTION 'n2s_autobuy_live_claim: an anchor is not there exactly once'; END IF;
  END LOOP;
  p_from := strpos(d, a_from);
  p_to := strpos(d, a_to) + length(a_to);
  IF p_to <= p_from THEN RAISE EXCEPTION 'n2s_autobuy_live_claim: job anchors out of order'; END IF;
  -- the job (the claim's tail, from reading the sale key to the end of the JSON) -> one call
  d := left(d, p_from - 1)
       || E'  -- 20261113470000: built by n2s_autobuy_job_json, as the one queue builds it (n2s_autobuy_queue_job)\n'
       || E'  RETURN public.n2s_autobuy_job_json(e.exec_id, v_act);\n'
       || substr(d, p_to);
  d := replace(d, a_decl, E'  v_gt_event bigint;\n  v_filed bigint;  -- 20261113470000\nBEGIN\n');
  d := replace(d, a_queue, a_queue || $q$
  -- 20261113470000 (one buyer, stage 3): with buyer = 'queue' the buy is FILED into the one
  -- queue (manual_sub_buy, lane D0) and that worker sends it after running every N2S guard
  -- again (core/n2s_autobuy_live.pre_buy). The live run is spent now, as for our own buy. No
  -- lease is taken: a queued row is not 'buying', so the stale-lease sweep never touches it.
  -- NULL back = not filed: the row stops and the run goes back to its source.
  IF v_act = 'buy' AND c.buyer = 'queue' THEN
    v_filed := public.manual_sub_buy_file_n2s(e.exec_id, NULL, NULL);
    IF v_filed IS NULL THEN
      UPDATE public.n2s_autobuy_exec
         SET phase = 'stopped', reasons = reasons || 'queue_file_refused'::text,
             live_started_at = COALESCE(live_started_at, now()), live_updated_at = now()
       WHERE exec_id = e.exec_id;
      IF e.sub_source = 'gotickets' THEN
        UPDATE public.n2s_autobuy_config SET gt_live_runs_used = GREATEST(gt_live_runs_used - 1, 0), updated_at = now() WHERE id;
      ELSE
        UPDATE public.n2s_autobuy_config SET live_runs_used = GREATEST(live_runs_used - 1, 0), updated_at = now() WHERE id;
      END IF;
    ELSE
      UPDATE public.n2s_autobuy_exec
         SET phase = 'queued', live_started_at = COALESCE(live_started_at, now()), live_updated_at = now()
       WHERE exec_id = e.exec_id;
    END IF;
    RETURN NULL;          -- nothing for this worker to do: the deployed worker reads NULL as idle
  END IF;
$q$);
  EXECUTE d;
END $do$;

-- ── 5. the job for a queued row, at hand-out ───────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_autobuy_queue_job(p_exec_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.n2s_autobuy_job_json(e.exec_id, 'buy')
    FROM public.n2s_autobuy_exec e
   WHERE e.exec_id = p_exec_id AND e.mode = 'live' AND e.phase = 'queued';
$function$;

REVOKE ALL ON FUNCTION public.n2s_autobuy_queue_job(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_autobuy_queue_job(bigint) TO service_role;

-- ── 6. the queue's result on our row ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_autobuy_queue_result(p_exec_id bigint, p_state text, p_patch jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  e        public.n2s_autobuy_exec%ROWTYPE;
  v_patch  jsonb := CASE WHEN jsonb_typeof(p_patch) = 'object' THEN p_patch ELSE '{}'::jsonb END;
  v_order  text;
  v_total  text;
  v_err    text;
  v_reason text[];
  v_phase  text;
BEGIN
  IF p_state IS NULL OR p_state NOT IN ('bought', 'stopped', 'unknown') THEN
    RAISE EXCEPTION 'n2s_autobuy_queue_result: bad state %', p_state;
  END IF;
  v_order  := NULLIF(btrim(v_patch ->> 'buy_order_id'), '');
  -- n2s_result() sends buy_total_usd / live_error; the queue's own patch says bought_total_usd / error
  v_total  := COALESCE(v_patch ->> 'buy_total_usd', v_patch ->> 'bought_total_usd');
  v_err    := left(COALESCE(v_patch ->> 'live_error', v_patch ->> 'error'), 1000);
  v_reason := CASE WHEN jsonb_typeof(v_patch -> 'reasons') = 'array'
                   THEN ARRAY(SELECT jsonb_array_elements_text(v_patch -> 'reasons')) ELSE '{}' END;

  SELECT * INTO e FROM public.n2s_autobuy_exec WHERE exec_id = p_exec_id FOR UPDATE;
  IF NOT FOUND THEN
    IF p_state = 'unknown' THEN    -- fail closed even for a row we cannot find
      UPDATE public.n2s_autobuy_config SET kill_switch = true, updated_at = now() WHERE id;
    END IF;
    RETURN 'not_found';
  END IF;

  IF e.mode IS DISTINCT FROM 'live' OR e.phase IS DISTINCT FROM 'queued' THEN
    IF p_state = 'unknown' THEN
      UPDATE public.n2s_autobuy_config SET kill_switch = true, updated_at = now() WHERE id;
    END IF;
    -- a purchase reported for a row that has left the queue and does not carry it: nobody would
    -- follow it or accept the sale for it. Fail closed.
    IF p_state IN ('bought', 'unknown') AND e.phase IS DISTINCT FROM 'buy_unknown'
       AND (v_order IS NULL OR e.buy_order_id IS DISTINCT FROM v_order) THEN
      UPDATE public.n2s_autobuy_exec
         SET phase = 'buy_unknown', buy_order_id = COALESCE(buy_order_id, v_order),
             reasons = reasons || 'queue_result_late'::text,
             live_error = COALESCE(v_err, format('the one queue reported %s after this row left the queue (phase %s): check %s',
                                                  p_state, COALESCE(e.phase, 'none'),
                                                  CASE e.sub_source WHEN 'gotickets' THEN 'GoTickets' ELSE 'EVO' END)),
             lease_until = NULL, lease_token = NULL, live_updated_at = now()
       WHERE exec_id = p_exec_id;
      UPDATE public.n2s_autobuy_config SET kill_switch = true, updated_at = now() WHERE id;
      RETURN 'buy_unknown';
    END IF;
    RETURN COALESCE(e.phase, 'not_queued');                   -- a repeat: nothing changes
  END IF;

  v_phase := CASE
    WHEN p_state = 'bought' AND v_order IS NOT NULL AND v_patch ->> 'phase' IS DISTINCT FROM 'buy_unknown' THEN 'buy_sent'
    WHEN p_state = 'stopped' AND v_order IS NULL THEN 'stopped'
    ELSE 'buy_unknown' END;   -- unknown; bought without a purchase id; a stop that carries one
  IF v_phase = 'buy_unknown' AND NOT ('buy_unknown' = ANY (v_reason)) THEN
    v_reason := v_reason || 'buy_unknown'::text;
  END IF;

  UPDATE public.n2s_autobuy_exec
     SET phase           = v_phase,
         buy_order_id    = COALESCE(buy_order_id, v_order),
         buy_state       = COALESCE(v_patch ->> 'buy_state', buy_state),
         buy_total_usd   = COALESCE(buy_total_usd, CASE WHEN v_total ~ '^[0-9]{1,9}(\.[0-9]{1,4})?$' THEN v_total::numeric END),
         sale_state      = COALESCE(v_patch ->> 'sale_state', sale_state),
         live_error      = COALESCE(v_err, CASE WHEN v_phase = 'buy_unknown' THEN
                             format('outcome unknown in the one queue: check %s for this purchase',
                                    CASE sub_source WHEN 'gotickets' THEN 'GoTickets' ELSE 'EVO' END) END, live_error),
         reasons         = reasons || v_reason,
         live_started_at = CASE WHEN v_phase = 'buy_sent' THEN now() ELSE COALESCE(live_started_at, now()) END,
         lease_until     = NULL,
         lease_token     = NULL,
         live_updated_at = now()
   WHERE exec_id = p_exec_id;

  -- stopped before the buy went out (no purchase id, no market refusal): the run goes back to
  -- the source it was taken from (n2s_autobuy_live_record's rule)
  IF v_phase = 'stopped' AND NOT ('buy_failed' = ANY (v_reason)) THEN
    IF e.sub_source = 'gotickets' THEN
      UPDATE public.n2s_autobuy_config SET gt_live_runs_used = GREATEST(gt_live_runs_used - 1, 0), updated_at = now() WHERE id;
    ELSE
      UPDATE public.n2s_autobuy_config SET live_runs_used = GREATEST(live_runs_used - 1, 0), updated_at = now() WHERE id;
    END IF;
  END IF;
  IF v_phase = 'buy_unknown' THEN
    UPDATE public.n2s_autobuy_config SET kill_switch = true, updated_at = now() WHERE id;
  END IF;
  RETURN v_phase;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_autobuy_queue_result(bigint, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_autobuy_queue_result(bigint, text, jsonb) TO service_role;
