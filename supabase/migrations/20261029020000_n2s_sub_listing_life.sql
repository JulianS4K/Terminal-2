-- Migration 20261029020000 · level:secondary-sales · lane:D7 · writes:n2s_sub_listing_life,v_n2s_sub_listing_life,cron · reads:n2s_cover_history,n2s_gt_current,n2s_evo_current,n2s_sg_current · pre:20261028223000
--
-- How long do N2S sub listings stay live on the market?
--
-- Operator direction 2026-10-29: "track how long the n2s listings are live".
-- Before an auto-buyer can be trusted we need to know how long a cover we
-- found is still buyable. n2s_cover_history cannot answer it: its 'gone'
-- means the cover left OUR queue (sold, window closed, or a better cover
-- replaced it), not that the listing left the market.
--
-- Source of truth = the full-inventory pulls N2S already makes per event
-- (n2s_gt_current / n2s_evo_current / n2s_sg_current, one row per listing,
-- pulled_at = the last pull that still had it, 1-hour retention). No new
-- upstream calls: this only reads what the pollers already landed.
--
-- One row per (sub_source, sub_listing_id, tevo_event_id) that was ever an
-- N2S cover. Each minute n2s_sub_listing_life_tick():
--   * enrols new covers from n2s_cover_history 'appeared' rows;
--   * for open rows, reads the listing's row and the event's latest pull:
--       listing present in the latest pull  → last_seen_at / price / qty
--       event re-pulled, listing absent     → gone_at = that pull
--       qty drops below what we need        → short_at (first time)
--   * an event that is no longer polled (order window over) leaves the row
--     open; it is CENSORED at last_event_pull_at — "still live when we
--     stopped looking", not "never sold".
-- live_s = (gone_at or last_seen_at) - first_cover_at.
--
-- Reads only; nothing is sent to any market.
--
-- rollback: SELECT cron.unschedule('n2s_sub_listing_life_1min');
--           DROP VIEW v_n2s_sub_listing_life; DROP FUNCTION n2s_sub_listing_life_tick();
--           DROP TABLE n2s_sub_listing_life;

CREATE TABLE IF NOT EXISTS public.n2s_sub_listing_life (
  sub_source         text        NOT NULL,
  sub_listing_id     text        NOT NULL,
  tevo_event_id      bigint      NOT NULL,
  first_cover_at     timestamptz NOT NULL,
  n2s_ids            bigint[]    NOT NULL DEFAULT '{}',
  best_gate          integer,
  sub_qty            integer,
  first_price        numeric,
  last_price         numeric,
  price_changes      integer     NOT NULL DEFAULT 0,
  first_seen_at      timestamptz,
  last_seen_at       timestamptz,
  last_qty           integer,
  short_at           timestamptz,
  gone_at            timestamptz,
  last_event_pull_at timestamptz,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (sub_source, sub_listing_id, tevo_event_id)
);

CREATE INDEX IF NOT EXISTS n2s_sub_listing_life_open
  ON public.n2s_sub_listing_life (first_cover_at) WHERE gone_at IS NULL;

ALTER TABLE public.n2s_sub_listing_life ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_sub_listing_life FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.n2s_sub_listing_life TO service_role;

CREATE OR REPLACE FUNCTION public.n2s_sub_listing_life_tick()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_since timestamptz;
  v_n int;
BEGIN
  -- 1. enrol covers seen since the last enrolment (10-minute overlap; idempotent).
  SELECT COALESCE(max(first_cover_at), now() - interval '2 hours') - interval '10 minutes'
    INTO v_since FROM public.n2s_sub_listing_life;

  INSERT INTO public.n2s_sub_listing_life AS l
         (sub_source, sub_listing_id, tevo_event_id, first_cover_at, n2s_ids, best_gate, sub_qty, first_price, last_price)
  SELECT h.sub_source, h.sub_listing_id, h.tevo_event_id, min(h.observed_at),
         array_agg(DISTINCT h.n2s_id), min(h.cover_gate), max(h.sub_qty),
         (array_agg(h.sub_price_each ORDER BY h.observed_at))[1],
         (array_agg(h.sub_price_each ORDER BY h.observed_at DESC))[1]
    FROM public.n2s_cover_history h
   WHERE h.event_kind = 'appeared'
     AND h.observed_at >= v_since
     AND h.sub_source IN ('gotickets', 'tevo', 'seatgeek')
     AND h.sub_listing_id IS NOT NULL
     AND h.tevo_event_id IS NOT NULL
   GROUP BY 1, 2, 3
  ON CONFLICT (sub_source, sub_listing_id, tevo_event_id) DO UPDATE
     SET n2s_ids   = ARRAY(SELECT DISTINCT unnest(l.n2s_ids || excluded.n2s_ids)),
         best_gate = LEAST(l.best_gate, excluded.best_gate),
         sub_qty   = GREATEST(l.sub_qty, excluded.sub_qty);

  -- 2. observe open rows against the latest market pulls.

  UPDATE public.n2s_sub_listing_life l
     SET last_event_pull_at = GREATEST(l.last_event_pull_at, x.event_pull),
         first_seen_at = COALESCE(l.first_seen_at, x.seen_at),
         last_seen_at  = GREATEST(l.last_seen_at, x.seen_at),
         -- count market-side changes only (the first market read sets the baseline)
         price_changes = l.price_changes + CASE WHEN l.first_seen_at IS NOT NULL AND x.price IS NOT NULL
                                                 AND x.price <> l.last_price THEN 1 ELSE 0 END,
         last_price    = COALESCE(x.price, l.last_price),
         last_qty      = COALESCE(x.qty, l.last_qty),
         short_at      = COALESCE(l.short_at,
                           CASE WHEN x.qty IS NOT NULL AND x.qty < COALESCE(l.sub_qty, 1) THEN x.seen_at END),
         gone_at       = CASE WHEN x.event_pull IS NOT NULL
                               AND (x.seen_at IS NULL OR x.event_pull > x.seen_at)
                               AND x.event_pull > COALESCE(l.last_seen_at, l.first_cover_at)
                              THEN x.event_pull END,
         updated_at    = now()
    FROM (
      SELECT o.sub_source, o.sub_listing_id, o.tevo_event_id, ev.event_pull, li.seen_at, li.price, li.qty
        FROM public.n2s_sub_listing_life o
        LEFT JOIN LATERAL (
          SELECT g.pulled_at AS seen_at, g.all_in_price AS price, g.quantity AS qty
            FROM public.n2s_gt_current g
           WHERE o.sub_source = 'gotickets' AND g.tevo_event_id = o.tevo_event_id AND g.gt_listing_id::text = o.sub_listing_id
          UNION ALL
          SELECT e.pulled_at, e.retail_price, e.quantity
            FROM public.n2s_evo_current e
           WHERE o.sub_source = 'tevo' AND e.event_id = o.tevo_event_id AND e.tevo_ticket_group_id::text = o.sub_listing_id
          UNION ALL
          SELECT s.pulled_at, s.retail_price_all_in, s.quantity
            FROM public.n2s_sg_current s
           WHERE o.sub_source = 'seatgeek' AND s.tevo_event_id = o.tevo_event_id AND s.sglid::text = o.sub_listing_id
          LIMIT 1) li ON true
        LEFT JOIN LATERAL (
          SELECT CASE o.sub_source
                   WHEN 'gotickets' THEN (SELECT max(g.pulled_at) FROM public.n2s_gt_current g WHERE g.tevo_event_id = o.tevo_event_id)
                   WHEN 'tevo'      THEN (SELECT max(e.pulled_at) FROM public.n2s_evo_current e WHERE e.event_id = o.tevo_event_id)
                   ELSE                  (SELECT max(s.pulled_at) FROM public.n2s_sg_current s WHERE s.tevo_event_id = o.tevo_event_id)
                 END AS event_pull) ev ON true
       WHERE o.gone_at IS NULL AND o.first_cover_at > now() - interval '6 hours') x
   WHERE l.sub_source = x.sub_source AND l.sub_listing_id = x.sub_listing_id AND l.tevo_event_id = x.tevo_event_id;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_sub_listing_life_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_sub_listing_life_tick() TO service_role;

CREATE OR REPLACE VIEW public.v_n2s_sub_listing_life
WITH (security_invoker = true) AS
SELECT l.*,
       extract(epoch FROM (COALESCE(l.gone_at, l.last_seen_at) - l.first_cover_at))::int AS live_s,
       extract(epoch FROM (l.short_at - l.first_cover_at))::int                         AS buyable_s,
       (l.gone_at IS NULL)                                                               AS censored
  FROM public.n2s_sub_listing_life l;

REVOKE ALL ON public.v_n2s_sub_listing_life FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_n2s_sub_listing_life TO service_role;

SELECT cron.schedule('n2s_sub_listing_life_1min', '* * * * *',
                     $$SELECT public.n2s_sub_listing_life_tick();$$);
