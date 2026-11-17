-- Migration 20260910600000 · level:secondary-sales · lane:D7 · writes:n2s_profitable_cover,n2s_integration_doc,n2s_error_code · reads:v_n2s_orders · pre:20260910520000
-- ============================================================================
-- Migration 20260910600000 — carry the gate label onto the EXTERNAL feed
--
-- Lane: D7 · Pre-reqs: 20260910510000, 20260910520000
--
-- The gate cascade classified every cover, 20260910510000 carried the label
-- into n2s_cover_queue and 20260910520000 onto v_n2s_orders — but the one
-- surface that leaves the building, n2s_profitable_cover, still carried none
-- of it. The manual's "gates" step already instructs integrators to read
-- cover_label before acting; the feed never sent one. That is a documented
-- field that does not exist, which is worse than an undocumented one.
--
-- It matters because the missing field is the SAFETY field. At the time of
-- writing 7 of the 11 rows on the wire are gates 3 and 5 — the buyer is being
-- moved to another section in the same zone, or up to five rows further back —
-- and those must be OFFERED and accepted before the purchase. A receiver
-- reading profit-descending with a buy_url and no label reads "$1,126 profit,
-- go buy it", which is precisely the wrong action.
--
-- Additive only: four new columns, nothing renamed, retyped or re-pointed, so
-- an existing receiver selecting the columns it knows is unaffected.
--
-- ⚠ Only the ODD gates can ever appear here. n2s_profitable_cover is fed from
-- v_n2s_orders WHERE cover_cost < 0, i.e. profitable; gates 2/4/6 are the
-- at-or-under-200%-of-sale arms, which are by definition not profitable. The
-- manual is corrected to say so rather than listing six gates a reader of this
-- feed will never see.
-- ============================================================================

ALTER TABLE public.n2s_profitable_cover
  ADD COLUMN IF NOT EXISTS cover_gate  smallint,
  ADD COLUMN IF NOT EXISTS cover_label text,
  ADD COLUMN IF NOT EXISTS order_zone  text,
  ADD COLUMN IF NOT EXISTS sub_zone    text;

COMMENT ON COLUMN public.n2s_profitable_cover.cover_gate IS
  'Which gate of the cascade matched (1..6, first match wins). Filter on this, '
  'not on the label text. 1 = exact section, actionable directly. >= 3 moves '
  'the buyer and must be offered to them BEFORE purchase. Only 1/3/5 reach '
  'this feed — the even gates are above cost and are not published here.';
COMMENT ON COLUMN public.n2s_profitable_cover.cover_label IS
  'Human-readable form of cover_gate, plus the " repost single" suffix when '
  'sub_qty exceeds the obligation. Wording may be clarified; gate numbers are '
  'never re-pointed, so branch on cover_gate.';
COMMENT ON COLUMN public.n2s_profitable_cover.order_zone IS
  'Curated zone the SOLD seat sits in, or NULL when the venue has no curated '
  'zones or the section matched more than one.';
COMMENT ON COLUMN public.n2s_profitable_cover.sub_zone IS
  'Curated zone of the substitute. On a gate 3/4 row this equals order_zone by '
  'construction; on other gates it is context only.';

-- Repointed sync: the four columns ride through src, the INSERT list, the
-- conflict update, AND the change-detection tuple. The last one is the part
-- that is easy to miss — without it a row that is re-gated (same listing, new
-- classification) would not count as changed, so no UPDATE, so no Realtime
-- event, and a subscriber would sit on a stale label indefinitely.
CREATE OR REPLACE FUNCTION public.n2s_profitable_cover_sync()
 RETURNS TABLE(inserted integer, updated integer, deleted integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_ins int := 0; v_upd int := 0; v_del int := 0;
BEGIN
  WITH src AS (
    SELECT v.n2s_id, v.order_number, v.n2s_order_key, v.s4k_source,
           v.event_name, v.event_date, v.venue, v.tevo_event_id,
           v.section, v.order_row, v.quantity, v.sold_ea,
           v.sub_source, v.sub_listing_id, v.sub_section, v.sub_row,
           v.sub_qty, v.sub_avail, v.sub_ea, v.sub_total, v.buy_url,
           round(-v.cover_cost, 2) AS profit,
           v.cover_gate, v.cover_label, v.order_zone, v.sub_zone
      FROM public.v_n2s_orders v
     WHERE v.has_cover AND v.cover_cost < 0
  ),
  gone AS (
    DELETE FROM public.n2s_profitable_cover t
     WHERE NOT EXISTS (SELECT 1 FROM src s WHERE s.n2s_id = t.n2s_id)
    RETURNING 1
  ),
  ups AS (
    INSERT INTO public.n2s_profitable_cover AS t (
      n2s_id, order_number, order_key, marketplace, event_name, event_date,
      venue, tevo_event_id, sold_section, sold_row, sold_qty, sold_price_each,
      sub_source, sub_listing_id, sub_section, sub_row, sub_qty, sub_lot_size,
      sub_price_each, sub_total, buy_url, profit,
      cover_gate, cover_label, order_zone, sub_zone)
    SELECT n2s_id, order_number, n2s_order_key, s4k_source, event_name,
           event_date, venue, tevo_event_id, section, order_row, quantity,
           sold_ea, sub_source, sub_listing_id, sub_section, sub_row, sub_qty,
           sub_avail, sub_ea, sub_total, buy_url, profit,
           cover_gate, cover_label, order_zone, sub_zone
      FROM src
    ON CONFLICT (n2s_id) DO UPDATE SET
      order_number = EXCLUDED.order_number, order_key = EXCLUDED.order_key,
      marketplace = EXCLUDED.marketplace, event_name = EXCLUDED.event_name,
      event_date = EXCLUDED.event_date, venue = EXCLUDED.venue,
      tevo_event_id = EXCLUDED.tevo_event_id,
      sold_section = EXCLUDED.sold_section, sold_row = EXCLUDED.sold_row,
      sold_qty = EXCLUDED.sold_qty, sold_price_each = EXCLUDED.sold_price_each,
      sub_source = EXCLUDED.sub_source, sub_listing_id = EXCLUDED.sub_listing_id,
      sub_section = EXCLUDED.sub_section, sub_row = EXCLUDED.sub_row,
      sub_qty = EXCLUDED.sub_qty, sub_lot_size = EXCLUDED.sub_lot_size,
      sub_price_each = EXCLUDED.sub_price_each, sub_total = EXCLUDED.sub_total,
      buy_url = EXCLUDED.buy_url, profit = EXCLUDED.profit,
      cover_gate = EXCLUDED.cover_gate, cover_label = EXCLUDED.cover_label,
      order_zone = EXCLUDED.order_zone, sub_zone = EXCLUDED.sub_zone,
      updated_at = now()
    WHERE (t.sub_source, t.sub_listing_id, t.sub_section, t.sub_row,
           t.sub_qty, t.sub_price_each, t.buy_url, t.profit,
           t.cover_gate, t.cover_label, t.order_zone, t.sub_zone)
       IS DISTINCT FROM
          (EXCLUDED.sub_source, EXCLUDED.sub_listing_id, EXCLUDED.sub_section,
           EXCLUDED.sub_row, EXCLUDED.sub_qty, EXCLUDED.sub_price_each,
           EXCLUDED.buy_url, EXCLUDED.profit,
           EXCLUDED.cover_gate, EXCLUDED.cover_label, EXCLUDED.order_zone,
           EXCLUDED.sub_zone)
    RETURNING (xmax = 0) AS was_insert
  )
  SELECT (SELECT count(*) FROM ups WHERE was_insert)::int,
         (SELECT count(*) FROM ups WHERE NOT was_insert)::int,
         (SELECT count(*) FROM gone)::int
    INTO v_ins, v_upd, v_del;

  RETURN QUERY SELECT COALESCE(v_ins,0), COALESCE(v_upd,0), COALESCE(v_del,0);
END $function$;

-- ---------------------------------------------------------------------------
-- Manual: the columns step now lists the label, and stops citing a retired code
-- ---------------------------------------------------------------------------
UPDATE public.n2s_integration_doc SET body = $doc$To ACT on a row you need six columns, and one that tells you whether you may act at all:

  cover_label    — READ THIS FIRST. What may be done with the row. See the label step.
  order_number   — the marketplace order we owe
  order_key      — the CRM order reference; use THIS to pull the order up in the CRM in real time. It is not always the same string as order_number.
  sub_section    — section of the replacement seats to buy
  sub_row        — row of the replacement seats
  sub_qty        — HOW MANY TO BUY (see the warning below)
  buy_url        — deep link to the exact listing on the source marketplace

*** cover_label / cover_gate ARE NOT OPTIONAL METADATA. *** cover_gate 1 keeps the buyer in the exact section they purchased and is actionable directly. cover_gate 3 and 5 MOVE the buyer, and the substitute must be offered and accepted BEFORE you purchase. Sorting this feed by profit and buying from the top will, today, act on rows that need the buyer's consent first.

*** IF cover_label IS NULL, FAIL CLOSED. *** A null label means the row lost its classification somewhere in the pipeline, not that it is safe. Treat it as offer-required and report it (error code N2S-G900). Never read a missing label as gate 1.

*** sub_qty IS NOT ALWAYS sold_qty. *** When a lot one seat larger than the obligation is cheaper in total than an exact match, the pipeline selects it deliberately and we absorb the spare seat. In that case sub_qty = sold_qty + 1. BUY sub_qty. Buying sold_qty instead will fail, because that lot is only sellable whole — which is precisely why it was cheap.

Context columns: marketplace, event_name, event_date, venue, tevo_event_id, sold_section, sold_row, sold_qty, sold_price_each, sub_source, sub_listing_id, sub_lot_size, sub_price_each, sub_total, order_zone, sub_zone, first_seen_at, updated_at.

order_zone / sub_zone name the curated seating zone each side sits in, or are NULL where the venue has no curated zones or the section matched more than one. They are the evidence behind a gate 3 label; they are not themselves an instruction.

profit = (sold_price_each x sold_qty) - sub_total, in USD. Every row in this table has profit > 0; covers that cost more than the sale are filtered out before you ever see them (error code N2S-G200).$doc$
WHERE slug = 'columns';

-- ---------------------------------------------------------------------------
-- Manual: the label step says which gates this feed can actually carry
-- ---------------------------------------------------------------------------
UPDATE public.n2s_integration_doc SET body = $doc$Every cover carries a cover_label and a cover_gate. It is not a quality score; it is a WORKFLOW INSTRUCTION telling you what may be done with the row. Six gates, checked in order, first match wins:

  1  Index                       exact section, same row or better, PROFITABLE
  2  S4KTrading                  exact section, same row or better, at or under 200% of sale
  3  Index offer subs            same curated ZONE, same row or better, PROFITABLE
  4  offer subs s4ktrading       same curated ZONE, same row or better, under 200%
  5  Index Down offer subs       up to 5 rows further back, PROFITABLE
  6  Down offer subs S4KTrading  up to 5 rows further back, under 200%

*** THIS FEED CARRIES GATES 1, 3 AND 5 ONLY. *** n2s_profitable_cover is the profitable book, and gates 2/4/6 are the arms that cost more than the sale. They are listed above because they exist in the pipeline and in the error codes, not because they will appear in your rows. If you ever read an even gate here, something is wrong — report it.

*** "offer subs" IN A LABEL MEANS DO NOT JUST BUY IT. *** Gate 1 keeps the buyer in the exact section they purchased, so it is actionable directly. Gates 3 and 5 MOVE the buyer — a different section within the same zone, or up to five rows further back — so the buyer must be OFFERED the substitute and accept it before you purchase. Acting on a gate 3 or 5 row without asking is how you turn a covered order into a dispute.

*** "Index" vs "S4KTrading" IS PROFIT, NOT QUALITY. *** Index rows make money on the cover. S4KTrading rows cost more than the sale but stay within a 200% ceiling — they are a trading decision, not an error, and they do not reach this feed. Nothing above 200% is ever sent, on any gate, to any surface.

*** SUFFIX "repost single" MEANS YOU ARE BUYING A SPARE SEAT. *** The lot could not be split to the exact quantity owed, so sub_qty is one greater than the obligation and the spare is reposted for sale separately. BUY sub_qty, not sold_qty — see the columns step.

Filter on cover_gate (integer, stable) rather than parsing cover_label text. The label wording may be clarified; the gate numbers will not be re-pointed.$doc$
WHERE slug = 'gates';

-- ---------------------------------------------------------------------------
-- One new code: a feed row that arrives without its classification
-- ---------------------------------------------------------------------------
INSERT INTO public.n2s_error_code
  (code, category, severity, title, meaning, emitted_by, what_to_do, sort_order)
VALUES (
  'N2S-G900', 'gate', 'error', 'Feed row carries no gate label',
  $doc$A row in n2s_profitable_cover has cover_label or cover_gate NULL. Every published row is classified by the cascade before it is sent, so a null means the classification was lost between the queue and the feed — a pipeline fault on our side, not a property of the cover.$doc$,
  'n2s_profitable_cover.cover_label IS NULL',
  $doc$Do NOT act on the row, and do not treat the absence of a label as gate 1. Fail closed: handle it as offer-required, or hold it. Report the n2s_id and the timestamp; the fix is ours.$doc$,
  380)
ON CONFLICT (code) DO UPDATE SET
  category = EXCLUDED.category, severity = EXCLUDED.severity,
  title = EXCLUDED.title, meaning = EXCLUDED.meaning,
  emitted_by = EXCLUDED.emitted_by, what_to_do = EXCLUDED.what_to_do, sort_order = EXCLUDED.sort_order;
