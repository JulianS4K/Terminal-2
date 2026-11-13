-- Migration 20261113150000 · level:secondary-sales · lane:D0 · writes:manual_sub_buy_config,manual_sub_buy,manual_sub_buy_claim,manual_sub_buy_record · reads:none · pre:20261113110000
--
-- MANUAL SUB BUY: the EVO tax quote's first run is a test.
--
-- Operator 2026-11-13: "Add tax quote but on its first run just do to test result so we can
-- confirm it's shape." EVO's Tax Quotes / Create (POST /v9/tax_quotes, 20261113110000) has
-- never been called with our credential; what we know of its answer comes from EVO's docs.
--
--   manual_sub_buy_config.tax_quote_test   (default false) with it on, and tax_quote off, the
--                     buy worker asks EVO for a quote on the next buy and STORES WHAT CAME BACK,
--                     exactly as it came (or the error), in manual_sub_buy.quote_raw. It changes
--                     nothing else: the quote is not checked against any ceiling, its signature
--                     is not sent, and the buy goes ahead exactly as it would without it.
--   once only         the claim hands the worker the test flag only while no row has a
--                     quote_raw yet. After the first answer is stored, no more test quotes are
--                     asked: a person reads the stored answer, and then turns tax_quote on (the
--                     real check) or leaves it off.
--
-- manual_sub_buy_claim and manual_sub_buy_record are patched in place; each patch fails loudly
-- if the line it edits is not there exactly once, and does nothing on a second run.
--
-- rollback: re-apply manual_sub_buy_claim and manual_sub_buy_record from 20261113110000;
--           ALTER TABLE public.manual_sub_buy DROP COLUMN quote_raw;
--           ALTER TABLE public.manual_sub_buy_config DROP COLUMN tax_quote_test;

ALTER TABLE public.manual_sub_buy_config
  ADD COLUMN IF NOT EXISTS tax_quote_test boolean NOT NULL DEFAULT false;

ALTER TABLE public.manual_sub_buy
  ADD COLUMN IF NOT EXISTS quote_raw jsonb;      -- EVO's tax quote answer as it came (the test run)

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.manual_sub_buy_claim()'::regprocedure);
  v_old text := $o$'tax_quote', c.tax_quote));$o$;
  v_new text := $n$'tax_quote', c.tax_quote,
                              -- the first run is a test: ask, store the answer, change nothing else
                              'tax_quote_test', c.tax_quote_test AND NOT c.tax_quote
                                AND NOT EXISTS (SELECT 1 FROM public.manual_sub_buy q WHERE q.quote_raw IS NOT NULL)));$n$;
BEGIN
  IF position('tax_quote_test' IN v_def) > 0 THEN RETURN; END IF;             -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'manual_sub_buy_claim: the cfg line to patch was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.manual_sub_buy_record(bigint, uuid, jsonb)'::regprocedure);
  v_old text := $o$quote_total_usd  = COALESCE((p_patch->>'quote_total_usd')::numeric, quote_total_usd),$o$;
  v_new text := $n$quote_total_usd  = COALESCE((p_patch->>'quote_total_usd')::numeric, quote_total_usd),
         quote_raw        = COALESCE(p_patch->'quote_raw', quote_raw),$n$;
BEGIN
  IF position('quote_raw' IN v_def) > 0 THEN RETURN; END IF;                  -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'manual_sub_buy_record: the line to patch was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;
