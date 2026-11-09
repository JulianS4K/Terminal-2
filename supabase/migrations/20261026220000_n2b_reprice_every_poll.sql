-- Migration 20261026220000 · level:secondary-sales · lane:D7 · writes:n2s_pull_all_sources · reads:n2s_items · pre:20261009180000
--
-- PED (N2B, Gmail Need2Buy/WaitToBuy) rows re-price on every poll, like N2S.
--
-- Operator 2026-10-26: "for ped update every time we poll those events". A PED
-- sale stays open until it is bought, filled or cancelled (the label comes
-- off), so its listings must stay current the whole time. 20261009180000 held
-- it to one re-pull every 4 hours; this drops that, so an N2B row is swept on
-- the caller's p_sweep_after like any other open row (n2s_pipeline_tick: 2
-- minutes). N2S rows are still swept first, and n2s_covers still lets N2S
-- orders claim listings before N2B ones, so PED never delays a timed order.
-- The upstream calls are the existing GET-only pulls (n2s_pull_events, which
-- skips an event pulled inside p_refresh_after).

DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  v_def := pg_get_functiondef('public.n2s_pull_all_sources(integer, interval, interval, boolean, integer)'::regprocedure);
  IF md5(v_def) <> '9e26899e2e25bc39450cf40e52728704' THEN
    RAISE EXCEPTION 'n2s_pull_all_sources changed since this migration was written (md5 %)', md5(v_def);
  END IF;
  v_new := replace(v_def,
$a$       -- mig 20261009180000: N2B (no timer) re-prices every 4 hours
       AND i.sources_pulled_at < now() - CASE WHEN i.status = 'n2b' THEN interval '4 hours'
                                              ELSE p_sweep_after END
$a$,
$b$       -- mig 20261026220000: N2B (PED, no timer) re-prices on every poll too,
       -- until the Gmail label comes off; N2S rows still sort first below.
       AND i.sources_pulled_at < now() - p_sweep_after
$b$);
  IF v_new = v_def OR v_new LIKE '%interval ''4 hours''%' THEN
    RAISE EXCEPTION 'n2s_pull_all_sources: anchor not found';
  END IF;
  EXECUTE v_new;
END $mig$;

-- rollback: re-apply the 20261009180000 replacement, i.e. put back
--   AND i.sources_pulled_at < now() - CASE WHEN i.status = 'n2b' THEN interval '4 hours'
--                                          ELSE p_sweep_after END
