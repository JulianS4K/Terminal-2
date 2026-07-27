-- Migration 20260709160000 · lane:D0 (author) → A1 (apply) · writes:sg_unmatched_performer_stat_card,refresh_sg_unmatched_performer_stat_card,get_sg_unmatched_stat_cards,cron(sg-unmatched-stat-card-refresh) · reads:sg_events_canonical,seatgeek_event_metrics,seatgeek_performer_xref · pre:none · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (creates a table + cron + backfills)
--
-- D0 — SeatGeek UNMATCHED performer stat-card (separate from the EVO-canonical
-- performer_stat_card).
--
-- Scope: performers that appear ONLY on SeatGeek events with NO TEvo/EVO
-- mapping (sg_events_canonical.tevo_event_id IS NULL) and are NOT already in
-- seatgeek_performer_xref. Matched SG performers already roll into the canonical
-- performer_stat_card via performer_metrics_daily — this table is the "no EVO
-- match" complement the operator asked for.
--
-- Performer parsing reuses v_sg_unmatched_candidate_performers' name logic
-- (split "A at/vs B", drop parking/theater-tour/co-headliner noise), then joins
-- each unmatched sg_event to seatgeek_event_metrics for price (listings_all_*).
-- Only ~13% of unmatched SG events currently carry price, so price columns are
-- populated where available (priced_event_count tracks coverage); the rest are
-- counts-only. Name-keyed (SG unmatched performers have no stable id).
--
-- AXS + Eventbrite were scoped alongside SG but are NOT built here: unmatched
-- AXS events carry no performer reference (axs_events has no artist column, and
-- axs_performers is an unlinked seed list), and the Eventbrite discovered-events
-- feed carries no price. Both need a prerequisite (a name→performer matcher /
-- price ingestion) before a meaningful stat table exists — tracked separately.

-- ============================================================
-- 1. Table (name-keyed)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.sg_unmatched_performer_stat_card (
  performer_name      text PRIMARY KEY,
  as_of               date,
  category            text,
  event_count         integer,     -- unmatched SG events for this performer
  priced_event_count  integer,     -- of those, how many carry price
  getin_min           numeric,
  price_median        numeric,     -- median of per-event listings_all_median
  price_p90           numeric,     -- p90 of per-event listings_all_median
  market_tickets      bigint,
  listings_count      bigint,
  venues              text[],
  computed_at         timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.sg_unmatched_performer_stat_card ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.sg_unmatched_performer_stat_card FROM anon, authenticated;

-- ============================================================
-- 2. Refresh — parse unmatched SG performers + join SG price
-- ============================================================
CREATE OR REPLACE FUNCTION public.refresh_sg_unmatched_performer_stat_card()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_n integer;
BEGIN
  TRUNCATE public.sg_unmatched_performer_stat_card;

  INSERT INTO public.sg_unmatched_performer_stat_card
    (performer_name, as_of, category, event_count, priced_event_count,
     getin_min, price_median, price_p90, market_tickets, listings_count, venues, computed_at)
  WITH src AS (
    SELECT sg_event_id, sg_category, sg_venue_name,
           regexp_replace(sg_event_name, '\s*\([^)]*\)\s*$', '', 'g') AS clean_name
    FROM public.sg_events_canonical WHERE tevo_event_id IS NULL
  ),
  sides AS (
    SELECT sg_event_id, sg_category, sg_venue_name,
      CASE WHEN clean_name ~* '\s+at\s+'     THEN regexp_split_to_array(clean_name, '\s+at\s+')
           WHEN clean_name ~* '\s+vs\.?\s+'  THEN regexp_split_to_array(clean_name, '\s+vs\.?\s+')
           ELSE ARRAY[clean_name] END AS sides
    FROM src
  ),
  exploded AS (
    SELECT sg_event_id, sg_category, sg_venue_name, btrim(s.s) AS raw_perf
    FROM sides, LATERAL unnest(sides.sides) s(s)
  ),
  co_split AS (
    SELECT sg_event_id, sg_category, sg_venue_name,
      CASE WHEN sg_category = ANY (ARRAY['mlb','nhl','nba','mls','wnba','ncaa_football','ncaa_basketball','nfl','nascar','nfl_preseason'])
           THEN ARRAY[raw_perf]
           ELSE regexp_split_to_array(raw_perf, '\s+(with|feat\.?|ft\.?)\s+|\s+&\s+') END AS perfs
    FROM exploded
  ),
  raw_candidates AS (
    SELECT sg_event_id, sg_category, sg_venue_name,
           btrim(regexp_replace(p.p, '^.*?:\s*', '')) AS raw_name
    FROM co_split, LATERAL unnest(co_split.perfs) p(p)
  ),
  classified AS (
    SELECT sg_event_id, sg_category, sg_venue_name, raw_name,
      CASE
        WHEN raw_name ~* '^Parking '  THEN 'parking'
        WHEN raw_name ~* '\s+Parking$' THEN 'parking'
        WHEN sg_category = 'parking'  THEN 'parking'
        WHEN raw_name ~* '\s+the\s+Musical' THEN 'theater_tour'
        WHEN raw_name ~* '^(Dear\s+Evan\s+Hansen|The\s+Book\s+of\s+Mormon|Hamilton|Wicked|The\s+Lion\s+King|Hadestown|Six|Frozen)\s+\w+$' THEN 'theater_tour'
        ELSE 'normal' END AS skip_reason
    FROM raw_candidates
  ),
  norm AS (
    SELECT sg_event_id, sg_category, sg_venue_name,
      regexp_replace(regexp_replace(regexp_replace(regexp_replace(
        raw_name, '\s+Preseason$', '', 'i'),
        '^(.+)\s+\1$', '\1', 'i'),
        '\s*-\s*(Citi\s+Presale|Saturday\s+Only|Sunday\s+Only|Saturday(?:\s+Evening)?(?:\s+Session)?(?:\s*-\s*Stadium\s*\d+)?|Sunday\s*-\s*Stadium\s*\d+)\s*$', '', 'i'),
        '\s+Weekend\s+\d+$', '', 'i') AS performer_name
    FROM classified WHERE skip_reason = 'normal'
  ),
  joined AS (
    SELECT n.performer_name, n.sg_category, n.sg_venue_name, n.sg_event_id,
           m.listings_all_min, m.listings_all_median, m.listings_all_tickets, m.listings_count
    FROM norm n
    LEFT JOIN public.seatgeek_event_metrics m ON m.sg_event_id = n.sg_event_id
  )
  SELECT
    performer_name, current_date,
    (array_agg(DISTINCT sg_category))[1],
    count(DISTINCT sg_event_id)::int,
    count(DISTINCT sg_event_id) FILTER (WHERE listings_all_median IS NOT NULL)::int,
    round(min(listings_all_min)::numeric, 2),
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY listings_all_median)::numeric, 2),
    round(percentile_cont(0.9) WITHIN GROUP (ORDER BY listings_all_median)::numeric, 2),
    sum(listings_all_tickets)::bigint,
    sum(listings_count)::bigint,
    (array_agg(DISTINCT sg_venue_name))[1:3],
    now()
  FROM joined
  WHERE length(performer_name) > 1 AND performer_name <> 'many more'
    AND NOT EXISTS (SELECT 1 FROM public.seatgeek_performer_xref x
                    WHERE lower(x.sg_performer_name) = lower(joined.performer_name))
  GROUP BY performer_name;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$func$;

REVOKE ALL ON FUNCTION public.refresh_sg_unmatched_performer_stat_card() FROM PUBLIC;

-- ============================================================
-- 3. Read RPC — top unmatched SG performers (gated)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_sg_unmatched_stat_cards(p_limit integer DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text; v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.market_tickets DESC NULLS LAST, s.event_count DESC), '[]'::jsonb)
  INTO v_result
  FROM (SELECT * FROM public.sg_unmatched_performer_stat_card
        ORDER BY market_tickets DESC NULLS LAST, event_count DESC
        LIMIT greatest(1, least(coalesce(p_limit,100), 500))) s;
  RETURN v_result;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_sg_unmatched_stat_cards(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_sg_unmatched_stat_cards(integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_sg_unmatched_stat_cards(integer) IS
  'D0 SeatGeek unmatched-performer stat-cards (no EVO/TEvo mapping), top by market tickets. @s4kent.com-gated SECDEF read.';

-- ============================================================
-- 4. Backfill + schedule (:40, after the other stat-card refreshes)
-- ============================================================
SELECT public.refresh_sg_unmatched_performer_stat_card();

DO $cron$
BEGIN
  PERFORM cron.unschedule('sg-unmatched-stat-card-refresh');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$cron$;

SELECT cron.schedule('sg-unmatched-stat-card-refresh', '40 */4 * * *', $cron$
  SELECT public.refresh_sg_unmatched_performer_stat_card();
$cron$);
