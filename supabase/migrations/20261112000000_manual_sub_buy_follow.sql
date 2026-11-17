-- Migration 20261112000000 · level:secondary-sales · lane:D0 · writes:manual_sub_buy,manual_sub_buy_follow_claim,manual_sub_buy_follow_record · reads:none · pre:20261111020000
--
-- MANUAL sub buy: follow each bought order until the seller confirms or rejects it.
--
-- Operator 2026-11-12: "when evo autobuys must return back order information ... and check
-- status till order is confirmed/rejected, also return seat numbers where possible".
--
-- Until now a bought row stopped at EVO's first answer (buy_state 'pending'): whether the
-- seller then accepted was checked by hand. Now core/manual_sub_buy.py re-reads the order
-- (GET /v9/orders/{id} — a read, RULE 2 untouched) until it is final and stores what came back:
--   outcome          none (never bought) | pending | confirmed | rejected | canceled
--   seller_state / order_state / rejection_reason      EVO's own words
--   order_total_usd  what EVO actually charged (can exceed price x qty: fees)
--   bought_section / bought_row / seats                seat numbers where the seller gave them
--
-- 'confirmed' = seller_state accepted or completed. A REJECTED or CANCELED order bought
-- nothing, so its row moves to state 'stopped' (reason seller_rejected / order_canceled): it
-- stops counting toward the day's spend and frees the one-live-request-per-sale lock, so the
-- sale can be covered again. buy_order_id stays on the row for the record.
--
-- updated_at is deliberately NOT touched by a follow-up while the row stays 'bought': the
-- daily spend ceiling counts bought rows by the New York date of updated_at, and a status
-- check on yesterday's buy must not move its spend into today.
--
-- Check pace per order: every 30 s for the first 20 checks, then every 5 min up to 60, then
-- every 30 min; given up 7 days after the buy. Rows bought before this migration are picked
-- up once and settle on their current EVO state.
--
-- No upstream call is made from SQL in this migration.
--
-- rollback: DROP FUNCTION public.manual_sub_buy_follow_record(bigint, jsonb), public.manual_sub_buy_follow_claim();
--           ALTER TABLE public.manual_sub_buy DROP COLUMN outcome, DROP COLUMN seller_state, DROP COLUMN order_state,
--             DROP COLUMN order_total_usd, DROP COLUMN bought_section, DROP COLUMN bought_row, DROP COLUMN seats,
--             DROP COLUMN rejection_reason, DROP COLUMN status_checked_at, DROP COLUMN status_checks, DROP COLUMN final_at;

ALTER TABLE public.manual_sub_buy
  ADD COLUMN IF NOT EXISTS outcome           text NOT NULL DEFAULT 'none'
                                             CHECK (outcome IN ('none', 'pending', 'confirmed', 'rejected', 'canceled')),
  ADD COLUMN IF NOT EXISTS seller_state      text,
  ADD COLUMN IF NOT EXISTS order_state       text,
  ADD COLUMN IF NOT EXISTS order_total_usd   numeric,
  ADD COLUMN IF NOT EXISTS bought_section    text,
  ADD COLUMN IF NOT EXISTS bought_row        text,
  ADD COLUMN IF NOT EXISTS seats             jsonb,
  ADD COLUMN IF NOT EXISTS rejection_reason  text,
  ADD COLUMN IF NOT EXISTS status_checked_at timestamptz,
  ADD COLUMN IF NOT EXISTS status_checks     integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS final_at          timestamptz;

UPDATE public.manual_sub_buy SET outcome = 'pending'
 WHERE state = 'bought' AND outcome = 'none' AND buy_order_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS manual_sub_buy_follow_idx
  ON public.manual_sub_buy (status_checked_at) WHERE state = 'bought' AND final_at IS NULL;

-- Hand out ONE bought order that is due a status check, and stamp the check so two workers
-- do not both read it. NULL when nothing is due. Reads only: needs no enabled flag.
CREATE OR REPLACE FUNCTION public.manual_sub_buy_follow_claim()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  b public.manual_sub_buy%ROWTYPE;
BEGIN
  SELECT * INTO b FROM public.manual_sub_buy
   WHERE state = 'bought' AND final_at IS NULL AND buy_order_id ~ '^\d+$'
     AND created_at > now() - interval '7 days'
     AND (status_checked_at IS NULL OR status_checked_at < now() - CASE
            WHEN status_checks < 20 THEN interval '30 seconds'
            WHEN status_checks < 60 THEN interval '5 minutes'
            ELSE interval '30 minutes' END)
   ORDER BY status_checked_at NULLS FIRST, buy_id
   LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;
  UPDATE public.manual_sub_buy
     SET status_checked_at = now(), status_checks = status_checks + 1,
         outcome = CASE WHEN outcome = 'none' THEN 'pending' ELSE outcome END
   WHERE buy_id = b.buy_id;
  RETURN jsonb_build_object('buy_id', b.buy_id, 'buy_order_id', b.buy_order_id);
END $function$;

-- Store what the order read said. p_patch: {order_state, seller_state, order_total_usd,
-- bought_section, bought_row, seats: [..], rejection_reason}. Returns the outcome.
CREATE OR REPLACE FUNCTION public.manual_sub_buy_follow_record(p_buy_id bigint, p_patch jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_seller  text := lower(nullif(btrim(p_patch->>'seller_state'), ''));
  v_order   text := lower(nullif(btrim(p_patch->>'order_state'), ''));
  v_outcome text;
BEGIN
  v_outcome := CASE
    WHEN 'rejected' IN (v_seller, v_order) THEN 'rejected'
    WHEN v_seller IN ('canceled', 'cancelled') OR v_order IN ('canceled', 'cancelled') THEN 'canceled'
    WHEN v_seller IN ('accepted', 'completed') THEN 'confirmed'
    ELSE 'pending' END;
  UPDATE public.manual_sub_buy
     SET outcome          = v_outcome,
         seller_state     = COALESCE(v_seller, seller_state),
         order_state      = COALESCE(v_order, order_state),
         order_total_usd  = COALESCE((p_patch->>'order_total_usd')::numeric, order_total_usd),
         bought_section   = COALESCE(nullif(p_patch->>'bought_section', ''), bought_section),
         bought_row       = COALESCE(nullif(p_patch->>'bought_row', ''), bought_row),
         seats            = CASE WHEN jsonb_typeof(p_patch->'seats') = 'array' AND jsonb_array_length(p_patch->'seats') > 0
                                 THEN p_patch->'seats' ELSE seats END,
         rejection_reason = COALESCE(nullif(p_patch->>'rejection_reason', ''), rejection_reason),
         final_at         = CASE WHEN v_outcome = 'pending' THEN NULL ELSE now() END,
         -- a rejected or canceled order bought nothing: release the sale and the spend
         state            = CASE WHEN v_outcome IN ('rejected', 'canceled') THEN 'stopped' ELSE state END,
         reasons          = CASE WHEN v_outcome = 'rejected' THEN reasons || 'seller_rejected'::text
                                 WHEN v_outcome = 'canceled' THEN reasons || 'order_canceled'::text
                                 ELSE reasons END,
         updated_at       = CASE WHEN v_outcome IN ('rejected', 'canceled') THEN now() ELSE updated_at END
   WHERE buy_id = p_buy_id AND state = 'bought' AND final_at IS NULL;
  IF NOT FOUND THEN RETURN 'not_open'; END IF;
  RETURN v_outcome;
END $function$;

REVOKE ALL ON FUNCTION public.manual_sub_buy_follow_claim() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.manual_sub_buy_follow_record(bigint, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.manual_sub_buy_follow_claim() TO service_role;
GRANT EXECUTE ON FUNCTION public.manual_sub_buy_follow_record(bigint, jsonb) TO service_role;
