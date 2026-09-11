-- ============================================================================
-- Migration 20260910490000 — retain cover history (append-only)
--
-- Lane: D7 · Pre-reqs: 20260910510000 is a FOLLOW-UP that adds the gate columns
-- this appender reads; on a from-zero replay the ALTER in 510000 lands first
-- because of its later timestamp only if that ordering holds — see the note at
-- the bottom.
--
-- Operator 2026-09-10: "actually store all the data ... i want to track it."
--
-- ── REMOVING THE AGE CAP DOES NOT ACHIEVE TRACKING ─────────────────────────
-- n2s_profitable_cover is a CURRENT-STATE table synced by diff: when a cover
-- stops being profitable, is bought, or its obligation resolves, the sync
-- DELETEs the row — with or without an age cap. Verified before building:
-- zero history tables existed and the feed's oldest row was ~3h old. So the cap
-- removal (20260910500000) and this append-only history are two separate
-- things, and only this one is "tracking".
--
-- ── ⚠ THE FEED STILL DELETES, ON PURPOSE ──────────────────────────────────
-- History is a SEPARATE table. n2s_profitable_cover keeps its diff semantics
-- because the published consumer contract depends on them: a DELETE event
-- means "un-flag this, the cover is gone", and a quiet minute emitting nothing
-- is what makes an event meaningful. Making the feed append-only would silently
-- break both. Track in history; act on the feed.
--
-- ── WHY HISTORY FOLLOWS THE QUEUE, NOT THE FEED ───────────────────────────
-- n2s_cover_queue carries ALL gates while the feed carries only the profitable
-- subset. Tracking only what was profitable would answer "what did we act on"
-- but not "what did we see and decline", which is most of the value.
--
-- ── CHANGE-DETECTED, NOT TICK-SAMPLED ─────────────────────────────────────
-- Appending every cover every minute would be ~102k rows/day of near-identical
-- data. A row is written only when the observed state CHANGES for an
-- obligation, plus one 'gone' marker when a cover disappears. Same information,
-- far less volume, and it reads as a timeline rather than a sampling.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.n2s_cover_history (
  id             bigserial PRIMARY KEY,
  observed_at    timestamptz NOT NULL DEFAULT now(),
  event_kind     text NOT NULL,              -- appeared | changed | gone
  n2s_id         bigint NOT NULL,
  order_number   text,
  order_key      text,
  marketplace    text,
  event_name     text,
  event_date     date,
  venue          text,
  tevo_event_id  bigint,
  sold_section   text,
  sold_row       text,
  sold_qty       integer,
  sold_price_each numeric,
  sub_source     text,
  sub_listing_id text,
  sub_section    text,
  sub_row        text,
  sub_qty        integer,
  sub_avail      integer,
  sub_price_each numeric,
  sub_total      numeric,
  cover_cost     numeric,
  cover_gate     integer,
  cover_label    text,
  order_zone     text,
  sub_zone       text,
  buy_url        text,
  captured_at    timestamptz
);

COMMENT ON TABLE public.n2s_cover_history IS
  'Append-only timeline of every cover the pipeline has seen, ALL gates (not just the profitable subset). Written on change only — appeared / changed / gone — never on an unchanged tick, and NEVER deleted or updated. This is the tracking surface; n2s_profitable_cover remains current-state-only because its consumer contract depends on DELETE meaning "un-flag this".';

CREATE INDEX IF NOT EXISTS n2s_cover_history_n2s_time
  ON public.n2s_cover_history (n2s_id, observed_at DESC);
CREATE INDEX IF NOT EXISTS n2s_cover_history_time
  ON public.n2s_cover_history (observed_at DESC);
CREATE INDEX IF NOT EXISTS n2s_cover_history_gate
  ON public.n2s_cover_history (cover_gate, observed_at DESC);

ALTER TABLE public.n2s_cover_history ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS n2s_cover_history_read ON public.n2s_cover_history;
CREATE POLICY n2s_cover_history_read ON public.n2s_cover_history
  FOR SELECT TO authenticated USING (true);
REVOKE ALL ON public.n2s_cover_history FROM PUBLIC, anon;
GRANT SELECT ON public.n2s_cover_history TO authenticated;

-- ── the appender ───────────────────────────────────────────────────────────
-- ⚠ ORDERING: this reads cover_gate/cover_label from n2s_cover_queue, which
-- 20260910510000 adds. It is plpgsql, so the body is not validated at CREATE
-- time and this migration applies cleanly ahead of that one — which is exactly
-- what happened in prod: the first live call failed with "column c.cover_gate
-- does not exist", and 510000 was written in response. A from-zero replay
-- reproduces the same order and the same end state, because 510000 lands
-- before the cron ever calls this.
CREATE OR REPLACE FUNCTION public.n2s_cover_history_append()
RETURNS TABLE(appeared integer, changed integer, gone integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_app int := 0; v_chg int := 0; v_gone int := 0;
BEGIN
  -- last known state per obligation, ignoring prior 'gone' markers so a cover
  -- that returns is recorded as 'appeared' again rather than 'changed'.
  WITH last AS (
    SELECT DISTINCT ON (h.n2s_id) h.*
      FROM public.n2s_cover_history h
     ORDER BY h.n2s_id, h.observed_at DESC, h.id DESC
  ),
  cur AS (SELECT * FROM public.n2s_cover_queue),
  ins AS (
    INSERT INTO public.n2s_cover_history (
      event_kind, n2s_id, order_number, order_key, marketplace, event_name,
      event_date, venue, tevo_event_id, sold_section, sold_row, sold_qty,
      sold_price_each, sub_source, sub_listing_id, sub_section, sub_row,
      sub_qty, sub_avail, sub_price_each, sub_total, cover_cost, cover_gate,
      cover_label, order_zone, sub_zone, buy_url, captured_at)
    SELECT CASE WHEN last.n2s_id IS NULL OR last.event_kind = 'gone'
                THEN 'appeared' ELSE 'changed' END,
           c.n2s_id, c.order_number, c.order_number, c.s4k_source, c.event_name,
           c.event_date, c.venue, c.tevo_event_id, c.section, c.order_row,
           c.quantity, c.sold_ea, c.sub_source, c.sub_listing_id, c.sub_section,
           c.sub_row, c.sub_qty, c.sub_avail, c.sub_ea, c.sub_total,
           c.cover_cost, c.cover_gate, c.cover_label, c.order_zone, c.sub_zone,
           c.buy_url, c.captured_at
      FROM cur c
      LEFT JOIN last ON last.n2s_id = c.n2s_id
     WHERE last.n2s_id IS NULL
        OR last.event_kind = 'gone'
        OR (last.sub_source, last.sub_listing_id, last.sub_section, last.sub_row,
            last.sub_qty, last.sub_price_each, last.cover_gate, last.cover_label)
           IS DISTINCT FROM
           (c.sub_source, c.sub_listing_id, c.sub_section, c.sub_row,
            c.sub_qty, c.sub_ea, c.cover_gate, c.cover_label)
    RETURNING event_kind
  ),
  dis AS (
    INSERT INTO public.n2s_cover_history (
      event_kind, n2s_id, order_number, order_key, marketplace, event_name,
      event_date, venue, tevo_event_id, sold_section, sold_row, sold_qty,
      sold_price_each, sub_source, sub_listing_id, sub_section, sub_row,
      sub_qty, sub_avail, sub_price_each, sub_total, cover_cost, cover_gate,
      cover_label, order_zone, sub_zone, buy_url, captured_at)
    SELECT 'gone', last.n2s_id, last.order_number, last.order_key,
           last.marketplace, last.event_name, last.event_date, last.venue,
           last.tevo_event_id, last.sold_section, last.sold_row, last.sold_qty,
           last.sold_price_each, last.sub_source, last.sub_listing_id,
           last.sub_section, last.sub_row, last.sub_qty, last.sub_avail,
           last.sub_price_each, last.sub_total, last.cover_cost, last.cover_gate,
           last.cover_label, last.order_zone, last.sub_zone, last.buy_url,
           last.captured_at
      FROM last
     WHERE last.event_kind <> 'gone'
       AND NOT EXISTS (SELECT 1 FROM cur c WHERE c.n2s_id = last.n2s_id)
    RETURNING 1
  )
  SELECT (SELECT count(*) FROM ins WHERE event_kind = 'appeared')::int,
         (SELECT count(*) FROM ins WHERE event_kind = 'changed')::int,
         (SELECT count(*) FROM dis)::int
    INTO v_app, v_chg, v_gone;

  RETURN QUERY SELECT COALESCE(v_app,0), COALESCE(v_chg,0), COALESCE(v_gone,0);
END $function$;

COMMENT ON FUNCTION public.n2s_cover_history_append() IS
  'Appends state changes from n2s_cover_queue into n2s_cover_history: appeared / changed / gone. Never rewrites or deletes. Runs after n2s_cover_queue_refresh() in the 1-minute chain; an unchanged tick writes nothing.';

REVOKE ALL ON FUNCTION public.n2s_cover_history_append() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_cover_history_append() TO service_role;
