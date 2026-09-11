-- ============================================================================
-- Migration 20260910550000 — long-term profit/loss-potential metrics
--
-- Lane: D7 · Pre-reqs: 20260910490000
-- Operator 2026-09-10: "keep the history and match data, i want to track
-- metrics of profit/loss potential long term."
--
-- ── TWO SURFACES, BECAUSE ONE ANSWERS HALF THE QUESTION ───────────────────
-- n2s_cover_history records only obligations that GOT a cover. It answers
-- "what money was on the table" but is structurally blind to "what we could
-- not cover at all" — and an uncovered obligation is the LARGER exposure,
-- because it still has to be settled at whatever the market asks. A P&L series
-- built from history alone would look BETTER the worse we did: fewer covers
-- found = fewer loss rows recorded.
--
--   v_n2s_pnl_daily   — a VIEW over history: potential per day/gate. No write
--                       path, always consistent with history.
--   n2s_book_snapshot — a periodic snapshot of the WHOLE book, covered and
--                       uncovered, so exposure is trackable. A view cannot do
--                       this: the uncovered state is retained nowhere, so it
--                       must be captured as it happens.
--
-- First snapshot on the live book made the point immediately: 135 open
-- obligations, 55 covered, 80 not — with $96,064.71 of sold value carrying no
-- priced cover at all, a number history alone could never surface.
--
-- ⚠ "POTENTIAL" IS THE OPERATIVE WORD. These are covers the pipeline FOUND and
-- priced, not purchases — the pipeline never buys. Read every figure as "what
-- was available at that moment"; do not present it as realised P&L.
-- ============================================================================

CREATE OR REPLACE VIEW public.v_n2s_pnl_daily AS
SELECT date_trunc('day', h.observed_at)::date       AS day,
       h.cover_gate,
       min(h.cover_label)                            AS example_label,
       count(*) FILTER (WHERE h.event_kind = 'appeared') AS covers_appeared,
       count(DISTINCT h.n2s_id)                      AS obligations,
       count(*) FILTER (WHERE h.cover_cost < 0)      AS profitable_observations,
       count(*) FILTER (WHERE h.cover_cost >= 0)     AS loss_observations,
       round(-sum(h.cover_cost) FILTER (WHERE h.cover_cost < 0), 2)  AS potential_profit,
       round( sum(h.cover_cost) FILTER (WHERE h.cover_cost >= 0), 2) AS potential_loss,
       round(sum(h.sold_price_each * h.sold_qty), 2) AS sold_value_seen,
       round(sum(h.sub_total), 2)                    AS cover_value_seen
  FROM public.n2s_cover_history h
 WHERE h.event_kind <> 'gone'          -- a 'gone' row repeats the last state
 GROUP BY 1, 2;

COMMENT ON VIEW public.v_n2s_pnl_daily IS
  'Per-day, per-gate profit/loss POTENTIAL from n2s_cover_history. These are covers the pipeline found and priced, NEVER purchases. Excludes event_kind=''gone'' because those rows repeat the last observed state and would double-count. Blind to obligations that never got a cover: pair with n2s_book_snapshot for exposure.';

CREATE TABLE IF NOT EXISTS public.n2s_book_snapshot (
  id                    bigserial PRIMARY KEY,
  taken_at              timestamptz NOT NULL DEFAULT now(),
  open_obligations      integer NOT NULL,
  mapped                integer NOT NULL,
  covered               integer NOT NULL,
  uncovered             integer NOT NULL,
  profitable_covers     integer NOT NULL,
  sold_value_open       numeric,
  cover_value_covered   numeric,
  potential_profit      numeric,
  potential_loss        numeric,
  uncovered_sold_value  numeric,
  by_gate               jsonb
);

COMMENT ON TABLE public.n2s_book_snapshot IS
  'Periodic snapshot of the WHOLE N2S book, covered and uncovered. Exists because n2s_cover_history only records obligations that got a cover, so a series built from history alone would improve as coverage got WORSE. uncovered_sold_value is the exposure carrying no priced cover at all.';

CREATE INDEX IF NOT EXISTS n2s_book_snapshot_time ON public.n2s_book_snapshot (taken_at DESC);
ALTER TABLE public.n2s_book_snapshot ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS n2s_book_snapshot_read ON public.n2s_book_snapshot;
CREATE POLICY n2s_book_snapshot_read ON public.n2s_book_snapshot
  FOR SELECT TO authenticated USING (true);
REVOKE ALL ON public.n2s_book_snapshot FROM PUBLIC, anon;
GRANT SELECT ON public.n2s_book_snapshot TO authenticated;

CREATE OR REPLACE FUNCTION public.n2s_book_snapshot_take()
RETURNS public.n2s_book_snapshot
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
  INSERT INTO public.n2s_book_snapshot (
    open_obligations, mapped, covered, uncovered, profitable_covers,
    sold_value_open, cover_value_covered, potential_profit, potential_loss,
    uncovered_sold_value, by_gate)
  SELECT count(*),
         count(*) FILTER (WHERE v.tevo_event_id IS NOT NULL),
         count(*) FILTER (WHERE v.has_cover),
         count(*) FILTER (WHERE NOT v.has_cover),
         count(*) FILTER (WHERE v.cover_cost < 0),
         round(sum(v.sold_ea * v.quantity), 2),
         round(sum(v.sub_total) FILTER (WHERE v.has_cover), 2),
         round(-sum(v.cover_cost) FILTER (WHERE v.cover_cost < 0), 2),
         round( sum(v.cover_cost) FILTER (WHERE v.cover_cost >= 0), 2),
         round(sum(v.sold_ea * v.quantity) FILTER (WHERE NOT v.has_cover), 2),
         (SELECT jsonb_object_agg(g::text, n)
            FROM (SELECT cover_gate AS g, count(*) AS n
                    FROM public.v_n2s_orders
                   WHERE cover_gate IS NOT NULL GROUP BY 1) x)
    FROM public.v_n2s_orders v
  RETURNING *;
$function$;

COMMENT ON FUNCTION public.n2s_book_snapshot_take() IS
  'Takes one whole-book snapshot into n2s_book_snapshot. Hourly is plenty — this is a trend series, not a feed. Figures are POTENTIAL (found and priced), never purchases.';

REVOKE ALL ON FUNCTION public.n2s_book_snapshot_take() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_book_snapshot_take() TO service_role;

-- Hourly at :37 — deliberately off the :00/:02/:05/:07 marks, the saturated
-- cluster in this project (MIGRATION_CONVENTIONS / PR checklist).
SELECT cron.schedule('n2s_book_snapshot_hourly', '37 * * * *',
                     $j$SELECT public.n2s_book_snapshot_take();$j$);
