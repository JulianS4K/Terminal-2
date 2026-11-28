-- A raw TicketsData body can be kept, for named events only.
--
-- Operator 2026-11-27: "capture the raw response poll both those events". Two receipts for
-- Trans-Siberian Orchestra at Toyota Center on 2026-12-11 19:30 (axs 1579101) disagree with
-- what we publish, and every cross-check available inside the database is now exhausted:
--   * FLOOR D row 25 seats 7-8  -- receipt $82.00 face + $25.00 fees; we hold $66.00 + $21.00
--   * section 119 row 17 seats 3-5 -- receipt $77.00 + $22.00; we hold $66.00 + $21.00
-- Our per-tier fee schedule is RIGHT ($77 pairs with $22, $89 with $25, and the receipts
-- match those pairings exactly), so the fault is which TIER a seat lands in, not the fees.
-- Section 119 reads 115/89/77/77/77/66/66/66/57... down the rows, a clean ladder, with the
-- $77 -> $66 boundary sitting two rows higher than the receipts say it should.
--
-- The leading explanation is the shared offer: 1579099 (15:00) and 1579101 (19:30) both carry
-- offer_id 91860776 and identical listings, and a matinee is normally cheaper than an evening,
-- which is exactly the shape of the error -- every seat one band low. An earlier note (7669)
-- dismissed this because the shared pool contained precisely the seats the operator bought;
-- that reasoning was wrong, because both performances share one physical seat map, so a
-- seat-level match says nothing about which performance's offer was read.
--
-- Settling it needs the body, and nothing retains one: axs_watch_poll keeps metadata only, and
-- axs_event_snapshots and ticketsdata_listings_snapshots are both empty. So this adds a
-- capture that is OFF BY DEFAULT and never fires unless an operator names an event.
--
-- axs_watch_config.raw_capture_ids defaults to '{}', so with no ids listed nothing is stored
-- and the ack path is unchanged. The capture is bounded: at most one row per ack, and
-- axs_watch_fill already prunes this table alongside the others.

ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS raw_capture_ids text[] NOT NULL DEFAULT '{}'::text[];

CREATE TABLE IF NOT EXISTS public.axs_watch_raw_capture (
  id            bigserial PRIMARY KEY,
  axs_event_id  text        NOT NULL,
  captured_at   timestamptz NOT NULL DEFAULT now(),
  status_code   integer,
  body          jsonb       NOT NULL
);
CREATE INDEX IF NOT EXISTS axs_watch_raw_capture_event_at
  ON public.axs_watch_raw_capture (axs_event_id, captured_at DESC);

REVOKE ALL ON TABLE public.axs_watch_raw_capture FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.axs_watch_raw_capture TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.axs_watch_raw_capture_id_seq TO service_role;

-- in-place surgery on the ack, so this file and prod cannot drift
DO $surgery$
DECLARE
  v_def text; v_old text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_queue_ack';
  IF v_def IS NULL THEN
    RAISE EXCEPTION 'axs_queue_ack is not present -- refusing to guess at its body';
  END IF;
  IF v_def ~ 'axs_watch_raw_capture' THEN
    RAISE NOTICE 'the capture is already wired in; nothing to do';
    RETURN;
  END IF;

  v_old := '  v_settled := public.axs_watch_settle_one(q.axs_event_id, p_status_code, p_content,';
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'expected the settle call exactly once in axs_queue_ack, found %', v_hits;
  END IF;

  v_new := replace(v_def, v_old,
    '  -- operator-named raw capture (mig 20261127220000). Off unless the id is listed, and' || E'\n' ||
    '  -- deliberately before the settle so a parse failure cannot cost us the body.' || E'\n' ||
    '  INSERT INTO public.axs_watch_raw_capture (axs_event_id, status_code, body)' || E'\n' ||
    '  SELECT q.axs_event_id, p_status_code, p_content' || E'\n' ||
    '    FROM public.axs_watch_config c' || E'\n' ||
    '   WHERE q.axs_event_id = ANY (c.raw_capture_ids) AND p_content IS NOT NULL;' || E'\n' ||
    E'\n' || v_old);
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_queue_ack';
  IF v_def !~ 'axs_watch_raw_capture' THEN
    RAISE EXCEPTION 'read-back: the capture is not in the deployed ack';
  END IF;
  IF (length(v_def) - length(replace(v_def, 'axs_watch_settle_one', ''))) / length('axs_watch_settle_one') <> 1 THEN
    RAISE EXCEPTION 'read-back: the settle call is no longer exactly once';
  END IF;
END $surgery$;
