-- Let the FK-blocked SeatGeek orders keep their own event id, by giving the catalogue the events
-- they are for.
--
-- Operator: "continue fix". This is the remainder mig 20260915080000 named and did not fix: 351
-- orders (202 distinct SeatGeek events) still cannot store their sg_event_id, because
-- seatgeek_orders_sg_event_id_fkey requires the id to exist in sg_events_canonical and these
-- events were never catalogued. They are the rows still on the fuzzy path, and they are measurably
-- the bad half of the book: 60.6% day-accurate against 99.9% for rows that do carry an id.
--
-- TWO WAYS TO FIX IT, and why this one. Relaxing the foreign key would also let the id be stored,
-- but it makes sg_event_id a column that may or may not resolve, which is a schema change with
-- consequences for every consumer that joins through it. Seeding the catalogue instead keeps the
-- FK meaningful and is well-supported by the table itself: only sg_event_id and sg_event_name are
-- NOT NULL, both come straight from SeatGeek's own order payload, and the table already carries a
-- `has_orders` flag -- the catalogue was always meant to learn about events this way.
--
-- THE DATE COLUMN IS A TRAP AND IS HANDLED EXPLICITLY. sg_events_canonical.sg_event_date is the
-- known UTC landmine (PROJECT_BIBLE §3): across the existing catalogue it holds a UTC date, which
-- is what caused 2,253 rows to sit a day ahead of the mirror. The ORDER payload's event.date is
-- local wall time (an NBA game reads 19:00, the local tip-off). Writing that local date into a
-- column whose other rows are UTC would put two different meanings in one column -- a new landmine
-- created while fixing an old one.
--
-- So these rows do not depend on that column at all. raw_event_jsonb is populated with an explicit
-- datetime_local built from event.date + event.time, and the mapper's SG surface already prefers
-- it: `coalesce(nullif(left(raw_event_jsonb->>'datetime_local',10),'')::date, sg_event_date)`
-- (mig 20260914221000). sg_event_date is still filled, with the local date, so the row is not
-- half-empty -- but nothing reads it in preference to the explicit field.
--
-- match_status stays 'pending' and tevo_event_id NULL: this migration creates catalogue rows, it
-- does not map them. The cascade maps them on its next pass like any other SG row, and 139 of the
-- 202 have a TEvo event at that venue on that day waiting for it.
--
-- Seeded rows are marked sg_category = NULL and has_orders = true, so they are distinguishable
-- from poller-sourced rows. If the SeatGeek catalogue poller later fetches one properly it
-- overwrites the placeholder fields and keeps the id -- the ON CONFLICT below is deliberately
-- fill-only on everything except updated_at, so a real pull always wins.

CREATE OR REPLACE FUNCTION public.sg_canonical_seed_from_orders(p_apply boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_seed int := 0; v_n int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '160000', true);

  DROP TABLE IF EXISTS _sgseed;
  CREATE TEMP TABLE _sgseed ON COMMIT DROP AS
  SELECT DISTINCT ON ((o.raw->'event'->>'seatgeek_event_id')::bigint)
         (o.raw->'event'->>'seatgeek_event_id')::bigint AS sg_event_id,
         nullif(trim(coalesce(o.raw->'event'->>'name', o.sg_event_name, '')), '') AS sg_event_name,
         nullif(trim(coalesce(o.raw->'event'->>'venue', o.sg_venue, '')), '')     AS sg_venue_name,
         coalesce(nullif(o.raw->'event'->>'date','')::date, o.sg_event_date)      AS local_date,
         nullif(o.raw->'event'->>'time','')                                       AS local_time
    FROM public.seatgeek_orders o
   WHERE o.sg_event_id IS NULL
     AND o.raw->'event'->>'seatgeek_event_id' ~ '^[0-9]+$'
     AND NOT EXISTS (SELECT 1 FROM public.sg_events_canonical c
                      WHERE c.sg_event_id = (o.raw->'event'->>'seatgeek_event_id')::bigint)
   ORDER BY (o.raw->'event'->>'seatgeek_event_id')::bigint, o.pulled_at DESC;

  DELETE FROM _sgseed WHERE sg_event_name IS NULL;   -- NOT NULL in the catalogue

  SELECT count(*) INTO v_seed FROM _sgseed;

  IF p_apply THEN
    INSERT INTO public.sg_events_canonical
           (sg_event_id, sg_event_name, sg_venue_name, sg_event_date, raw_event_jsonb,
            has_orders, match_status, created_at, updated_at)
    SELECT s.sg_event_id, s.sg_event_name, s.sg_venue_name, s.local_date,
           jsonb_build_object('datetime_local',
             s.local_date::text || 'T' || coalesce(s.local_time, '00:00:00'),
             'seeded_from', 'seatgeek_orders'),
           true, 'pending', now(), now()
      FROM _sgseed s
    ON CONFLICT (sg_event_id) DO UPDATE
      SET sg_venue_name    = coalesce(public.sg_events_canonical.sg_venue_name, excluded.sg_venue_name),
          sg_event_date    = coalesce(public.sg_events_canonical.sg_event_date, excluded.sg_event_date),
          raw_event_jsonb  = coalesce(public.sg_events_canonical.raw_event_jsonb, excluded.raw_event_jsonb),
          has_orders       = true,
          updated_at       = now();
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_seed := v_n;
  END IF;

  RETURN jsonb_build_object('applied', p_apply, 'events_seeded', v_seed);
END $fn$;

REVOKE ALL ON FUNCTION public.sg_canonical_seed_from_orders(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sg_canonical_seed_from_orders(boolean) TO service_role;

COMMENT ON FUNCTION public.sg_canonical_seed_from_orders(boolean) IS
  'Creates sg_events_canonical rows for SeatGeek events we only know about from orders, so those orders can satisfy the sg_event_id foreign key and bind by identity. Carries an explicit raw_event_jsonb.datetime_local so nothing depends on the UTC-ambiguous sg_event_date. Never maps; match_status stays pending. Dry run by default (mig 20260915110000).';
