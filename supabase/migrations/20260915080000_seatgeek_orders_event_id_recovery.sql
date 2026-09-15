-- Recover seatgeek_orders.sg_event_id from the payload it was already storing, then re-point the
-- tevo bindings that were guessed in its absence.
--
-- Operator: "fix both" -- the second being the defect surfaced while building the staged cascade:
-- seatgeek_orders is not an identity source, so it had to be dropped from cascade stage 1.
--
-- WHAT WAS WRONG. 1,968 of 2,368 rows carried NO sg_event_id, yet EVERY ONE of them carried the
-- event object in `raw`. The id was never missing from the feed; it was being looked for under
-- the wrong key. SeatGeek's seller-order payload nests it as `event.seatgeek_event_id`, not
-- `event.id`, and `event.id` / `datetime_local` / `datetime_utc` are all absent from this shape.
-- All 1,968 are recoverable, so this is a backfill, not a re-fetch.
--
-- THE CURRENT INGEST IS ALREADY CORRECT -- checked before writing any code, because a backfill
-- over a still-broken writer just refills with nulls tomorrow. seatgeek_client.py reads
-- `ev.get("seatgeek_event_id")` and the webhook RPC (mig 20260516210200) reads
-- `o->'event'->>'seatgeek_event_id'`. So the parser was never the problem.
--
-- THE REAL CAUSE IS A FOREIGN KEY, and the first version of this migration hit it head-on:
-- seatgeek_orders_sg_event_id_fkey requires sg_event_id to exist in sg_events_canonical. An
-- order for a SeatGeek event we have not catalogued therefore CANNOT store its own event id --
-- the insert would be rejected -- so the id is dropped and the row falls back to the fuzzy
-- aq_short_event_id path. The missing id is a SYMPTOM of catalogue coverage, not of parsing.
--
-- That splits the 1,968 rows in two:
--   1,617 whose event IS in sg_events_canonical  -> recoverable now, and this migration does it
--     351 whose event is NOT                     -> still cannot hold their id, and are left
--                                                   alone. They need the SeatGeek event
--                                                   ingested first; that is the same catalogue
--                                                   coverage gap behind the 15.1% figure in
--                                                   KANBAN, and is not fixed here.
--
-- WHY IT MATTERED SO MUCH. With no event id, nothing could bind these orders by identity, so
-- tevo_event_id was filled through aq_short_event_id -- the old universal matcher's fuzzy
-- name/venue/date guess. That guess is wrong a lot:
--
--   1,527 rows have an identity answer waiting in sg_events_canonical
--     510  are currently unmapped and simply gain one
--     390  agree with what the fuzzy match already said
--     627  DISAGREE -- and where the local day can adjudicate, identity is right 624 times
--          and the incumbent 0 times.
--
-- That is the same defect from the other end: of 733 future mapped rows only 386 (53%) sat on
-- the TEvo event's own local day. Three of the concrete errors it produced, found by parity in
-- mig 20260915070000: "NHL Preseason - Washington Capitals at Boston Bruins" bound to "Mt. Joy",
-- "Charli XCX" bound to "Juanes", "Baltimore Orioles at Yankees" bound to "Tampa Bay Rays at
-- Yankees".
--
-- THE RE-POINT IS AN OVERWRITE, so it is guarded, logged and reversible:
--   * only where a canonical IDENTITY answer exists (c.tevo_event_id via the recovered id),
--   * only where it differs from what the row holds,
--   * every write recorded in seatgeek_orders_tevo_correction_log with old_tevo_id, so the whole
--     batch can be put back with a single UPDATE ... FROM the log.
-- No name matching, no fuzzy scoring, no date arithmetic. The SeatGeek event id came from
-- SeatGeek and sg_events_canonical's binding of it is the mapper's own answer for that id.

ALTER TABLE public.seatgeek_orders
  ADD COLUMN IF NOT EXISTS sg_event_id_source text;   -- 'feed' | 'raw_backfill'

CREATE TABLE IF NOT EXISTS public.seatgeek_orders_tevo_correction_log (
  sg_order_id   text PRIMARY KEY,
  old_tevo_id   bigint,
  new_tevo_id   bigint NOT NULL,
  sg_event_id   bigint NOT NULL,
  reason        text   NOT NULL,
  corrected_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.seatgeek_orders_tevo_correction_log IS
  'Every seatgeek_orders.tevo_event_id re-pointed from a recovered SeatGeek event id. old_tevo_id makes the batch reversible (mig 20260915080000).';

CREATE OR REPLACE FUNCTION public.seatgeek_orders_recover_event_id(p_apply boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_filled int := 0; v_corrected int := 0; v_gained int := 0; v_agree int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '160000', true);

  IF p_apply THEN
    -- 1. fill the id. Fill-only: a row that already has one is never touched, so a value the
    --    feed supplied always beats one reconstructed here.
    -- the FK is why this needs the EXISTS: an id for an uncatalogued SeatGeek event cannot be
    -- stored at all, so those rows keep their NULL rather than failing the whole batch.
    UPDATE public.seatgeek_orders o
       SET sg_event_id = (o.raw->'event'->>'seatgeek_event_id')::bigint,
           sg_event_id_source = 'raw_backfill'
     WHERE o.sg_event_id IS NULL
       AND o.raw->'event'->>'seatgeek_event_id' ~ '^[0-9]+$'
       AND EXISTS (SELECT 1 FROM public.sg_events_canonical c
                    WHERE c.sg_event_id = (o.raw->'event'->>'seatgeek_event_id')::bigint);
    GET DIAGNOSTICS v_filled = ROW_COUNT;

    UPDATE public.seatgeek_orders o SET sg_event_id_source = 'feed'
     WHERE o.sg_event_id IS NOT NULL AND o.sg_event_id_source IS NULL;

    -- 2. rows that had NO mapping simply gain the identity answer
    UPDATE public.seatgeek_orders o
       SET tevo_event_id = c.tevo_event_id
      FROM public.sg_events_canonical c
     WHERE c.sg_event_id = o.sg_event_id AND c.tevo_event_id IS NOT NULL
       AND o.tevo_event_id IS NULL;
    GET DIAGNOSTICS v_gained = ROW_COUNT;

    -- 3. rows whose fuzzy binding disagrees with identity: log first, then re-point
    INSERT INTO public.seatgeek_orders_tevo_correction_log (sg_order_id, old_tevo_id, new_tevo_id, sg_event_id, reason)
    SELECT o.sg_order_id, o.tevo_event_id, c.tevo_event_id, o.sg_event_id, 'canonical_identity'
      FROM public.seatgeek_orders o
      JOIN public.sg_events_canonical c ON c.sg_event_id = o.sg_event_id
     WHERE c.tevo_event_id IS NOT NULL
       AND o.tevo_event_id IS NOT NULL
       AND o.tevo_event_id <> c.tevo_event_id
    ON CONFLICT (sg_order_id) DO UPDATE
      SET old_tevo_id = excluded.old_tevo_id, new_tevo_id = excluded.new_tevo_id,
          sg_event_id = excluded.sg_event_id, corrected_at = now();

    UPDATE public.seatgeek_orders o
       SET tevo_event_id = c.tevo_event_id
      FROM public.sg_events_canonical c
     WHERE c.sg_event_id = o.sg_event_id AND c.tevo_event_id IS NOT NULL
       AND o.tevo_event_id IS NOT NULL AND o.tevo_event_id <> c.tevo_event_id;
    GET DIAGNOSTICS v_corrected = ROW_COUNT;
  ELSE
    SELECT count(*) INTO v_filled FROM public.seatgeek_orders o
     WHERE o.sg_event_id IS NULL AND o.raw->'event'->>'seatgeek_event_id' ~ '^[0-9]+$'
       AND EXISTS (SELECT 1 FROM public.sg_events_canonical c
                    WHERE c.sg_event_id = (o.raw->'event'->>'seatgeek_event_id')::bigint);
    SELECT count(*) FILTER (WHERE o.tevo_event_id IS NULL),
           count(*) FILTER (WHERE o.tevo_event_id IS NOT NULL AND o.tevo_event_id <> c.tevo_event_id),
           count(*) FILTER (WHERE o.tevo_event_id = c.tevo_event_id)
      INTO v_gained, v_corrected, v_agree
      FROM public.seatgeek_orders o
      JOIN public.sg_events_canonical c
        ON c.sg_event_id = coalesce(o.sg_event_id, nullif(o.raw->'event'->>'seatgeek_event_id','')::bigint)
     WHERE c.tevo_event_id IS NOT NULL;
  END IF;

  RETURN jsonb_build_object('applied', p_apply, 'ids_filled', v_filled,
                            'mappings_gained', v_gained, 'mappings_corrected', v_corrected,
                            'already_agreed', v_agree);
END $fn$;

REVOKE ALL ON FUNCTION public.seatgeek_orders_recover_event_id(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.seatgeek_orders_recover_event_id(boolean) TO service_role;

COMMENT ON FUNCTION public.seatgeek_orders_recover_event_id(boolean) IS
  'Backfills seatgeek_orders.sg_event_id from raw.event.seatgeek_event_id, then binds/re-points tevo_event_id from sg_events_canonical by IDENTITY on that id. Overwrites are logged to seatgeek_orders_tevo_correction_log and reversible from old_tevo_id. Dry run by default (mig 20260915080000).';
