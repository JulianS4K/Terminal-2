-- Migration 20261113420000 · level:secondary-sales · lane:D7 · writes:n2s_evo_tax_rate,n2s_landed_total(text,numeric,integer,numeric),n2s_evo_venue_tax_rate,n2s_cover_candidates · reads:evo_venue_tax,sub_finder_config,evo_orders,events · pre:20261113070000,20261113400000
--
-- N2S prices EVO covers WITH the expected sales tax, from the same per-venue table the sub
-- finder uses.
--
-- Operator 2026-11-13: "for evo look at the tax code in api out code and incorporate". The sub
-- finder (20261113070000) keeps evo_venue_tax: one rate per venue, learned hourly from our own
-- EVO purchases ('observed', the highest tax / subtotal seen) or set by the operator ('manual',
-- never overwritten), with sub_finder_config.evo_tax_default_pct for any other venue; and it
-- prices every EVO cover as listed price x (1 + tax%) in its total, profit, gate and 200% rule.
-- N2S had its own copy of the rate (n2s_evo_venue_tax_rate, 20261112020000) and used it ONLY at
-- the auto-buy enqueue: the cover ranking, the gates, the cover queue / history and the CRM feed
-- priced EVO covers without tax, so at a taxed venue an EVO cover could rank above a cheaper
-- GoTickets one or pass a profit gate it fails once taxed. Today the two rates agree
-- (Camp Randall 5.5%, Boone Pickens 9.31%); this makes them one.
--
--   1. n2s_evo_tax_rate(venue_id): the sub finder's rate for a venue, as a fraction
--      (sub_finder_evo_tax_pct('evo', venue) / 100). SECURITY DEFINER so N2S's invoker functions
--      (callable by authenticated) can read it without a grant on the sub finder's tables.
--   2. n2s_landed_total(src, ea, qty, tax_rate): the existing landed total plus, for an EVO
--      ('tevo') listing, ea x qty x tax_rate (the tax is on the ticket subtotal, as EVO charges it).
--   3. n2s_cover_candidates: each order reads its venue's rate once (o.evo_tax) and every landed
--      total (tier-3 test, sub_total, profitable, the 200% cap, ranking, cover_cost) carries it.
--      `sub_ea` stays the listed price (the dry run / enqueue / worker re-check the listed price,
--      and the enqueue adds the tax once to quoted_ea x qty, so nothing is taxed twice).
--      Anchor patch, md5-guarded against the prod text.
--   4. n2s_evo_venue_tax_rate(event) (the auto-buy enqueue's rate): a manual row wins; otherwise
--      the higher of the sub finder's rate and our own purchases' highest rate at the venue
--      (still read live, so a venue taxed minutes ago counts before the hourly refresh), capped
--      at 30% like the table. md5-guarded.
-- inbox_n2b_cover_candidates (the N2B inbox) still prices without tax; not changed here.
--
-- Nothing here calls a market.
--
-- rollback: re-create n2s_cover_candidates and n2s_evo_venue_tax_rate from their prod text before
--           this migration (md5 ca494238… / 3a0e03bc…); DROP FUNCTION
--           public.n2s_landed_total(text, numeric, integer, numeric), public.n2s_evo_tax_rate(bigint).

-- ── 1. the sub finder's rate, for N2S ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_evo_tax_rate(p_venue_id bigint)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(public.sub_finder_evo_tax_pct('evo', p_venue_id), 0) / 100.0;
$$;
REVOKE ALL ON FUNCTION public.n2s_evo_tax_rate(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_evo_tax_rate(bigint) TO authenticated, service_role;

-- ── 2. landed total with the EVO tax ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_landed_total(p_src text, p_ea numeric, p_qty integer, p_tax_rate numeric)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT public.n2s_landed_total(p_src, p_ea, p_qty)
         + CASE WHEN p_src = 'tevo' THEN p_ea * p_qty * COALESCE(p_tax_rate, 0) ELSE 0 END;
$$;
REVOKE ALL ON FUNCTION public.n2s_landed_total(text, numeric, integer, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_landed_total(text, numeric, integer, numeric) TO authenticated, service_role;

-- ── 3. the cover ranking prices EVO with tax ───────────────────────────────
DO $do$
DECLARE d text; n int;
  a_ven  CONSTANT text := E'           e.venue_id,\n';
  a_mm   CONSTANT text := 'public.n2s_landed_total(mm.src, mm.ea, mm.buy_qty)';
  a_u    CONSTANT text := 'public.n2s_landed_total(u.src, u.ea, u.quantity + 1)';
BEGIN
  d := pg_get_functiondef('public.n2s_cover_candidates(bigint[], interval, integer, text[])'::regprocedure);
  IF md5(d) <> 'ca494238b56eea525eea0ae8dca2f562' THEN
    RAISE EXCEPTION 'n2s_cover_candidates drifted from its 2026-11-13 prod text — re-derive this migration';
  END IF;
  n := (length(d) - length(replace(d, a_ven, ''))) / length(a_ven);
  IF n <> 1 THEN RAISE EXCEPTION 'n2s_cover_candidates: % venue anchors (want 1)', n; END IF;
  n := (length(d) - length(replace(d, a_mm, ''))) / length(a_mm);
  IF n <> 3 THEN RAISE EXCEPTION 'n2s_cover_candidates: % mm landed anchors (want 3)', n; END IF;
  n := (length(d) - length(replace(d, a_u, ''))) / length(a_u);
  IF n <> 1 THEN RAISE EXCEPTION 'n2s_cover_candidates: % tier-3 landed anchors (want 1)', n; END IF;
  d := replace(d, a_ven, a_ven || E'           public.n2s_evo_tax_rate(e.venue_id) AS evo_tax,  -- 20261113420000: EVO sales tax\n');
  d := replace(d, a_mm, 'public.n2s_landed_total(mm.src, mm.ea, mm.buy_qty, mm.evo_tax)');
  d := replace(d, a_u, 'public.n2s_landed_total(u.src, u.ea, u.quantity + 1, u.evo_tax)');
  EXECUTE d;
END $do$;

-- ── 4. the auto-buy enqueue's rate reads the same table ────────────────────
DO $do$
BEGIN
  IF md5(pg_get_functiondef('public.n2s_evo_venue_tax_rate(bigint)'::regprocedure)) <> '3a0e03bc408dc70ec59d5ed7a44b7ca2' THEN
    RAISE EXCEPTION 'n2s_evo_venue_tax_rate drifted from 20261112020000 — re-derive this migration';
  END IF;
END $do$;

CREATE OR REPLACE FUNCTION public.n2s_evo_venue_tax_rate(p_tevo_event_id bigint)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_venue bigint; v_manual numeric; v_live numeric;
BEGIN
  SELECT e.venue_id INTO v_venue FROM public.events e WHERE e.id = p_tevo_event_id;
  -- 20261113420000: the operator's own rate for the venue always wins
  SELECT t.tax_pct / 100.0 INTO v_manual FROM public.evo_venue_tax t WHERE t.venue_id = v_venue AND t.source = 'manual';
  IF v_manual IS NOT NULL THEN
    RETURN LEAST(v_manual, 0.30);
  END IF;
  -- our own purchases at this venue, read live (a venue taxed since the hourly refresh still counts)
  SELECT max(o.tax / o.subtotal) INTO v_live
    FROM public.evo_orders o
    JOIN public.events oe
      ON oe.id = COALESCE(o.tevo_event_id, NULLIF(o.raw #>> '{shipments,0,items,0,ticket_group,event,id}', '')::bigint)
   WHERE oe.venue_id = v_venue AND o.buyer_brokerage_id = 1768
     AND o.subtotal > 0 AND o.tax > 0;
  RETURN LEAST(GREATEST(COALESCE(public.n2s_evo_tax_rate(v_venue), 0), COALESCE(v_live, 0)), 0.30);
EXCEPTION WHEN OTHERS THEN
  RETURN 0;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_evo_venue_tax_rate(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_evo_venue_tax_rate(bigint) TO service_role;
