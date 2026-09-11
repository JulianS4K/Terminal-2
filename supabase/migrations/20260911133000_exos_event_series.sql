-- ============================================================================
-- Migration 20260911133000 — Exos (Bridge / D4): recurring / timed-entry event series
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_event_series (NEW table, RLS: org-staff read, RPC-only write),
--           exos_events (W: +series_id, +series_index; INSERT clones),
--           exos_ticket_tiers (W: INSERT clones), exos_discount_codes (W: INSERT
--           clones, only where the table exists),
--           exos_public_events (VIEW replaced: +series_id, +series_index; only
--           where the view exists — re-asserts security_invoker + grants),
--           exos_occurs_at_local(timestamptz, text) (new, helper),
--           exos_create_event_series(uuid, timestamptz[], text, text, jsonb, boolean)
--           (new, owner/manager RPC)
-- Pre-reqs: 20260520120000 (exos_events / tiers), 20260703130000 (current
--           exos_public_events column list), 20260911051000 (reminder columns
--           cleared on clone — no-op where absent)
--
-- KANBAN D4-OPS-27 (Stage 3 — "large; ship the schema + create-flow first").
-- Every Exos event is a single dated row; there is no way to say "same show,
-- every Friday" or "museum entry, 10:00 / 11:00 / 12:00 slots". Both are the
-- SAME shape at the data layer — N dated events that share a template — so one
-- mechanism covers recurring runs and timed-entry slots:
--
--   * exos_event_series: the group. kind = 'recurring' | 'timed-entry', a
--     template_event_id, the generator rule the organizer used (jsonb, kept so
--     the UI can show "every Friday × 8" and extend later).
--   * exos_events.series_id / series_index: membership. The TEMPLATE becomes
--     member 0 and stays exactly as it is; each occurrence is a column-agnostic
--     CLONE of the template row (to_jsonb → jsonb_populate_record, so any future
--     event column is carried without touching this function) with:
--       starts_at / doors_at / ends_at shifted (template deltas preserved),
--       occurs_at_local recomputed in the event tz (§3 landmine: offset-bearing
--       text, must not land NULL), slug suffixed, tickets_sold 0, counters and
--       reminder markers cleared, status = template's (or draft when
--       p_publish = false), created_by = caller.
--     Tiers are cloned with sold = 0; discount codes with used_count = 0 and
--     unlocks_tier_ids cleared (they point at template tier ids).
--   * Calling it again on a template that is already in a series EXTENDS the
--     series (indexes continue) — "add more dates".
--   * Not in this migration (later stages): series-wide edit/cancel fan-out,
--     per-slot capacity templates, storefront grouping (the view now exposes
--     series_id so the customer session can group; flagged via bot_chat).
--
-- ROLLBACK: DROP FUNCTION exos_create_event_series(uuid,timestamptz[],text,text,jsonb,boolean),
--   exos_occurs_at_local(timestamptz,text); ALTER TABLE exos_events DROP COLUMN
--   series_id, DROP COLUMN series_index; DROP TABLE exos_event_series;
--   re-create exos_public_events from 20260703130000.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Series table + membership columns.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_event_series (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name              text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 200),
  kind              text NOT NULL DEFAULT 'recurring' CHECK (kind IN ('recurring','timed-entry')),
  template_event_id uuid REFERENCES public.exos_events (id) ON DELETE SET NULL,
  timezone          text,
  rule              jsonb,
  created_by        uuid,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_event_series_org_idx ON public.exos_event_series (org_id);
COMMENT ON TABLE public.exos_event_series IS
  'D4 mig 20260911133000: a recurring run or timed-entry slot set. Members are exos_events rows sharing series_id; the template is series_index 0. Written only by exos_create_event_series.';

ALTER TABLE public.exos_event_series ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS exos_event_series_sel ON public.exos_event_series;
CREATE POLICY exos_event_series_sel ON public.exos_event_series FOR SELECT TO authenticated
  USING (exos_is_admin()
         OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));
REVOKE ALL ON public.exos_event_series FROM anon, authenticated;
GRANT SELECT ON public.exos_event_series TO authenticated;

ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS series_id    uuid REFERENCES public.exos_event_series (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS series_index integer CHECK (series_index IS NULL OR series_index >= 0);
CREATE INDEX IF NOT EXISTS exos_events_series_idx ON public.exos_events (series_id, series_index)
  WHERE series_id IS NOT NULL;
COMMENT ON COLUMN public.exos_events.series_id IS
  'Series membership (exos_event_series). NULL = standalone event. The template is series_index 0.';

-- ---------------------------------------------------------------------------
-- 2. occurs_at_local helper — the D0-consistent offset-bearing local string
--    ("YYYY-MM-DDTHH:MM:SS±HH:MM"). NULL on a bad timezone rather than an error.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_occurs_at_local(p_at timestamptz, p_tz text)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp
AS $$
DECLARE v_local timestamp; v_off interval; v_sign text; v_h int; v_m int;
BEGIN
  IF p_at IS NULL OR nullif(p_tz, '') IS NULL THEN RETURN NULL; END IF;
  BEGIN
    v_local := p_at AT TIME ZONE p_tz;
  EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
  END;
  v_off  := v_local - (p_at AT TIME ZONE 'UTC');
  v_sign := CASE WHEN v_off < interval '0' THEN '-' ELSE '+' END;
  v_h    := abs(extract(hour   FROM v_off))::int;
  v_m    := abs(extract(minute FROM v_off))::int;
  RETURN to_char(v_local, 'YYYY-MM-DD"T"HH24:MI:SS') || v_sign || lpad(v_h::text, 2, '0') || ':' || lpad(v_m::text, 2, '0');
END $$;
REVOKE ALL ON FUNCTION public.exos_occurs_at_local(timestamptz, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_occurs_at_local(timestamptz, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Create / extend a series from a template event.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_create_event_series(
  p_template_event_id uuid,
  p_starts_at         timestamptz[],
  p_kind              text    DEFAULT 'recurring',
  p_name              text    DEFAULT NULL,
  p_rule              jsonb   DEFAULT NULL,
  p_publish           boolean DEFAULT NULL
) RETURNS TABLE (event_id uuid, starts_at timestamptz, series_index int)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_tpl       public.exos_events%ROWTYPE;
  v_tpl_j     jsonb;
  v_series    uuid;
  v_next      int;
  v_tz        text;
  v_d_doors   interval;
  v_d_ends    interval;
  v_occ       timestamptz;
  v_occs      timestamptz[];
  v_new       uuid;
  v_status    text;
  v_slug      text;
  v_t         record;
  v_has_codes boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_create_event_series: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_kind NOT IN ('recurring','timed-entry') THEN
    RAISE EXCEPTION 'exos_create_event_series: kind must be recurring or timed-entry';
  END IF;
  SELECT * INTO v_tpl FROM public.exos_events WHERE id = p_template_event_id;
  IF v_tpl.id IS NULL THEN
    RAISE EXCEPTION 'exos_create_event_series: template event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_tpl.org_id, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_create_event_series: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_tpl.status = 'cancelled' THEN
    RAISE EXCEPTION 'exos_create_event_series: template event is cancelled';
  END IF;
  IF v_tpl.starts_at IS NULL THEN
    RAISE EXCEPTION 'exos_create_event_series: template event has no start time';
  END IF;

  -- Distinct, sorted, future-of-nothing (any time is allowed — a back-dated
  -- occurrence is the organizer's call), minus the template's own start AND
  -- minus any date already in the series (an "extend" call that repeats dates
  -- must not fail on the deterministic slug, nor duplicate slug-less events).
  SELECT array_agg(DISTINCT o ORDER BY o) INTO v_occs
    FROM unnest(coalesce(p_starts_at, '{}')) AS o
   WHERE o IS NOT NULL AND o <> v_tpl.starts_at
     AND (v_tpl.series_id IS NULL OR NOT EXISTS (
           SELECT 1 FROM public.exos_events m
            WHERE m.series_id = v_tpl.series_id AND m.starts_at = o));
  IF coalesce(array_length(v_occs, 1), 0) = 0 THEN
    RAISE EXCEPTION 'exos_create_event_series: no new occurrences — every date given is the template or already in this series';
  END IF;
  IF array_length(v_occs, 1) > 200 THEN
    RAISE EXCEPTION 'exos_create_event_series: max 200 occurrences per call';
  END IF;

  -- Validate the template timezone up front so occurs_at_local is never NULL
  -- on a clone; a bad name degrades to UTC with a warning, matching the app.
  v_tz := coalesce(nullif(v_tpl.timezone, ''), 'UTC');
  BEGIN
    PERFORM now() AT TIME ZONE v_tz;
  EXCEPTION WHEN invalid_parameter_value THEN
    RAISE WARNING 'exos_create_event_series: template % has an invalid timezone (%) — using UTC', v_tpl.id, v_tz;
    v_tz := 'UTC';
  END;
  v_d_doors := v_tpl.doors_at - v_tpl.starts_at;
  v_d_ends  := v_tpl.ends_at  - v_tpl.starts_at;
  v_status  := CASE WHEN p_publish IS TRUE THEN 'published'
                    WHEN p_publish IS FALSE THEN 'draft'
                    ELSE v_tpl.status END;

  -- Series row: reuse when the template already belongs to one (extend).
  v_series := v_tpl.series_id;
  IF v_series IS NULL THEN
    INSERT INTO public.exos_event_series (org_id, name, kind, template_event_id, timezone, rule, created_by)
    VALUES (v_tpl.org_id, left(coalesce(nullif(p_name, ''), v_tpl.name), 200), p_kind,
            v_tpl.id, v_tz, p_rule, v_uid)
    RETURNING id INTO v_series;
    UPDATE public.exos_events SET series_id = v_series, series_index = 0 WHERE id = v_tpl.id;
    v_next := 1;
  ELSE
    UPDATE public.exos_event_series
       SET rule = coalesce(p_rule, rule), updated_at = now()
     WHERE id = v_series;
    SELECT coalesce(max(e.series_index), 0) + 1 INTO v_next
      FROM public.exos_events e WHERE e.series_id = v_series;
  END IF;

  -- Column-agnostic template: strip per-run state. NOTE jsonb_populate_record
  -- yields NULL (not the column DEFAULT) for an absent key, so only NULLABLE
  -- columns may be stripped; NOT NULL DEFAULT columns get an explicit value in
  -- the override object below (tickets_sold, checkin_test_mode). Unknown keys
  -- are ignored, so overrides for columns a narrower schema lacks are harmless.
  v_tpl_j := to_jsonb(v_tpl)
             - 'cancelled_at' - 'cancel_reason'
             - 'reminder_24h_sent_at' - 'reminder_2h_sent_at' - 'reminder_manual_sent_at'
             - 'automatiq_listing_id' - 'sync_status' - 'checkin_test_until';

  v_has_codes := to_regclass('public.exos_discount_codes') IS NOT NULL;

  FOREACH v_occ IN ARRAY v_occs LOOP
    v_new  := gen_random_uuid();
    v_slug := CASE WHEN v_tpl.slug IS NULL THEN NULL
                   ELSE left(v_tpl.slug, 60) || '-' || to_char(v_occ AT TIME ZONE v_tz, 'YYYYMMDD-HH24MI') END;

    INSERT INTO public.exos_events
    SELECT * FROM jsonb_populate_record(NULL::public.exos_events, v_tpl_j || jsonb_build_object(
      'id',              v_new,
      'slug',            v_slug,
      'status',          v_status,
      'starts_at',       v_occ,
      'doors_at',        CASE WHEN v_d_doors IS NULL THEN NULL ELSE v_occ + v_d_doors END,
      'ends_at',         CASE WHEN v_d_ends  IS NULL THEN NULL ELSE v_occ + v_d_ends  END,
      'occurs_at_local', public.exos_occurs_at_local(v_occ, v_tz),
      'tickets_sold',    0,
      'checkin_test_mode', false,
      'series_id',       v_series,
      'series_index',    v_next,
      'created_by',      v_uid,
      'created_at',      now(),
      'updated_at',      now()));

    -- Tiers: same shape, fresh id, nothing sold.
    FOR v_t IN SELECT to_jsonb(t) AS j FROM public.exos_ticket_tiers t
                WHERE t.event_id = v_tpl.id ORDER BY t.sort_order, t.name LOOP
      INSERT INTO public.exos_ticket_tiers
      SELECT * FROM jsonb_populate_record(NULL::public.exos_ticket_tiers,
        (v_t.j - 'id' - 'created_at' - 'updated_at') || jsonb_build_object(
          'id', gen_random_uuid(), 'event_id', v_new, 'sold', 0,
          'created_at', now(), 'updated_at', now()));
    END LOOP;

    -- Discount codes (prod only; the offline harness has no such table).
    IF v_has_codes THEN
      EXECUTE format($q$
        INSERT INTO public.exos_discount_codes
        SELECT * FROM jsonb_populate_record(NULL::public.exos_discount_codes,
          (to_jsonb(d) - 'id' - 'created_at' - 'updated_at') || jsonb_build_object(
            'id', gen_random_uuid(), 'event_id', %L::uuid, 'used_count', 0,
            'unlocks_tier_ids', NULL, 'created_at', now(), 'updated_at', now()))
          FROM public.exos_discount_codes d WHERE d.event_id = %L::uuid
      $q$, v_new, v_tpl.id);
    END IF;

    event_id := v_new; starts_at := v_occ; series_index := v_next;
    RETURN NEXT;
    v_next := v_next + 1;
  END LOOP;
  RETURN;
END $$;
REVOKE ALL ON FUNCTION public.exos_create_event_series(uuid, timestamptz[], text, text, jsonb, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_create_event_series(uuid, timestamptz[], text, text, jsonb, boolean) TO authenticated;

COMMENT ON FUNCTION public.exos_create_event_series(uuid, timestamptz[], text, text, jsonb, boolean) IS
  'D4 mig 20260911133000: clone a template event (+tiers, +discount codes) once per occurrence into a series (creates or extends exos_event_series). Owner/manager/admin. Column-agnostic clone; occurs_at_local recomputed in the event tz.';

-- ---------------------------------------------------------------------------
-- 4. Public view: expose membership so the storefront can group a series.
--    Only where the view exists (prod); the offline harness has no views.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.exos_public_events') IS NOT NULL THEN
    EXECUTE $v$
      CREATE OR REPLACE VIEW public.exos_public_events AS
        SELECT id, org_id, name, slug, description, occurs_at_local, starts_at, doors_at,
               ends_at, timezone, currency, venue_name, venue_location, venue_address,
               primary_performer_name, performer_names, artist_links, event_type, category,
               genres, subgenres, image_url, branding, purchase_limits, total_tickets,
               tickets_sold, series_id, series_index
        FROM public.exos_events
        WHERE status = 'published'
    $v$;
    EXECUTE 'ALTER VIEW public.exos_public_events SET (security_invoker = true)';
    EXECUTE 'REVOKE ALL ON public.exos_public_events FROM anon, authenticated';
    EXECUTE 'GRANT SELECT ON public.exos_public_events TO anon, authenticated';
    -- security_invoker: the anon column grant on the base table must include
    -- the two new columns or the view errors for anon.
    EXECUTE 'GRANT SELECT (series_id, series_index) ON public.exos_events TO anon, authenticated';
  END IF;
END $$;
