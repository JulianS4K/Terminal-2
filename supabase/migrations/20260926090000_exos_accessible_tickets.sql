-- ============================================================================
-- Migration 20260926090000 — Exos (Bridge / D4): accessible ticket options
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: exos_ticket_tiers (+accessible, +accessible_note)
--              exos_events (+accessibility jsonb)
--              exos_tickets (+access_needs, +access_needs_by)
--              exos_guest_list_entries (+access_needs)
--              VIEW exos_public_tiers, exos_public_events (columns appended in place)
--              FUNCTION exos_set_ticket_access_needs, exos_ticket_access_needs,
--                exos_event_access_requests, exos_set_guest_access_needs,
--                exos_promoter_set_guest_access_needs (new)
--              FUNCTION exos_event_door_extras, exos_promoter_guest_lists
--                (patched in place, one marker each)
-- Pre-reqs: 20260926050000 (guest lists, door extras, promoter lists)
--
-- What organizers and promoters get:
--   * A ticket type can be marked accessible, with a short note ("Wheelchair
--     space + 1 companion seat"). Buyers see it on the event page. Pair it with
--     visibility = hidden + a voucher to hand accessible seats out on request.
--   * Per-event access info: a fixed list of venue features (step-free entry,
--     accessible restrooms, ASL, ...) plus free-text notes and an access
--     contact, public on the event page.
--   * A ticket holder can tell the organizer what they need (a fixed list, no
--     free text: this is disability data, so only categories are kept). Staff
--     see it in the report and at the door; nobody else can read it.
--   * Guest-list entries carry the same needs; staff and the list's promoter
--     can set them, and the door sees them.
--
-- Privacy: exos_tickets RLS also lets the original buyer read a ticket after
-- they transfer it, so access_needs gets NO column grant. It's read only
-- through owner/staff RPCs, and a need counts only while the person who set
-- it still holds the ticket (access_needs_by = owner_id): a transfer drops
-- them without touching the transfer code.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Vocabularies (shared by the UI: src/lib/accessibility.ts)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_access_needs_ok(p text[])
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT p IS NOT NULL
     AND cardinality(p) <= 8
     AND p <@ ARRAY['wheelchair', 'companion', 'step_free', 'seat', 'asl',
                    'hearing', 'vision', 'service_animal']::text[]
$$;

CREATE OR REPLACE FUNCTION public._exos_accessibility_ok(p jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT p IS NOT NULL
     AND jsonb_typeof(p) = 'object'
     AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(p) k
                      WHERE k NOT IN ('features', 'notes', 'contact'))
     AND (NOT p ? 'features' OR (
            jsonb_typeof(p->'features') = 'array'
        AND jsonb_array_length(p->'features') <= 12
        AND NOT EXISTS (
              SELECT 1 FROM jsonb_array_elements(p->'features') f
               WHERE jsonb_typeof(f) <> 'string'
                  OR f #>> '{}' NOT IN ('step_free', 'wheelchair_spaces', 'accessible_restrooms',
                                        'accessible_parking', 'asl', 'captions', 'hearing_loop',
                                        'quiet_space', 'service_animals', 'seating'))))
     AND (NOT p ? 'notes' OR (jsonb_typeof(p->'notes') = 'string' AND length(p->>'notes') <= 500))
     AND (NOT p ? 'contact' OR (jsonb_typeof(p->'contact') = 'string' AND length(p->>'contact') <= 200))
$$;
REVOKE ALL ON FUNCTION public._exos_access_needs_ok(text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._exos_accessibility_ok(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_access_needs_ok(text[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public._exos_accessibility_ok(jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_ticket_tiers
  ADD COLUMN IF NOT EXISTS accessible boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS accessible_note text;
ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS accessibility jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.exos_tickets
  ADD COLUMN IF NOT EXISTS access_needs text[] NOT NULL DEFAULT '{}'::text[],
  ADD COLUMN IF NOT EXISTS access_needs_by uuid;
ALTER TABLE public.exos_guest_list_entries
  ADD COLUMN IF NOT EXISTS access_needs text[] NOT NULL DEFAULT '{}'::text[];

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_ticket_tiers_accessible_note_chk') THEN
    ALTER TABLE public.exos_ticket_tiers ADD CONSTRAINT exos_ticket_tiers_accessible_note_chk
      CHECK (accessible_note IS NULL OR length(accessible_note) <= 140);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_events_accessibility_chk') THEN
    ALTER TABLE public.exos_events ADD CONSTRAINT exos_events_accessibility_chk
      CHECK (public._exos_accessibility_ok(accessibility));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_tickets_access_needs_chk') THEN
    ALTER TABLE public.exos_tickets ADD CONSTRAINT exos_tickets_access_needs_chk
      CHECK (public._exos_access_needs_ok(access_needs));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_guest_list_entries_access_needs_chk') THEN
    ALTER TABLE public.exos_guest_list_entries ADD CONSTRAINT exos_guest_list_entries_access_needs_chk
      CHECK (public._exos_access_needs_ok(access_needs));
  END IF;
END $$;

-- Column grants follow the existing per-column pattern (mig 20260925021000).
GRANT SELECT (accessible, accessible_note) ON public.exos_ticket_tiers TO anon, authenticated;
GRANT INSERT (accessible, accessible_note), UPDATE (accessible, accessible_note)
  ON public.exos_ticket_tiers TO authenticated;
GRANT SELECT (accessibility) ON public.exos_events TO anon, authenticated;
GRANT INSERT (accessibility), UPDATE (accessibility) ON public.exos_events TO authenticated;
-- Deliberately no grant on exos_tickets.access_needs / access_needs_by (see header).

-- ---------------------------------------------------------------------------
-- 3. Public views: append the new columns to whatever the live definition is
--    (prod's column list differs from older chains), keeping its options.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
  d text;
  opts text;
  i int;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('exos_public_tiers',  't.accessible', ',
    t.accessible,
    t.accessible_note'),
      ('exos_public_events', 'accessibility', ',
    accessibility')) AS v(view_name, probe, cols)
  LOOP
    IF to_regclass('public.' || r.view_name) IS NULL THEN
      RAISE NOTICE '%: view not present here, skipping', r.view_name;   -- stub test schemas
      CONTINUE;
    END IF;
    d := pg_get_viewdef(('public.' || r.view_name)::regclass);
    IF position(r.probe || E'\n' in d) > 0 OR position(r.probe || ',' in d) > 0 THEN
      RAISE NOTICE '%: already has the access columns, skipping', r.view_name;
      CONTINUE;
    END IF;
    -- The select list ends at the outermost FROM, which pg_get_viewdef puts on
    -- its own line after the last column.
    i := position(E'\n   FROM ' in d);
    IF i = 0 THEN
      RAISE EXCEPTION '%: unexpected view definition', r.view_name;
    END IF;
    d := left(d, i - 1) || r.cols || substr(d, i);
    SELECT coalesce(' WITH (' || array_to_string(c.reloptions, ', ') || ')', '') INTO opts
      FROM pg_class c WHERE c.oid = ('public.' || r.view_name)::regclass;
    EXECUTE format('CREATE OR REPLACE VIEW public.%I%s AS %s', r.view_name, opts, d);
  END LOOP;
END $$;
DO $$
BEGIN
  IF to_regclass('public.exos_public_tiers') IS NOT NULL AND to_regclass('public.exos_public_events') IS NOT NULL THEN
    GRANT SELECT ON public.exos_public_tiers, public.exos_public_events TO anon, authenticated;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4. Ticket holder: set / read my needs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_set_ticket_access_needs(p_ticket_id uuid, p_needs text[])
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_owner  uuid;
  v_status text;
  v_needs  text[];
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_set_ticket_access_needs: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT owner_id, status INTO v_owner, v_status FROM public.exos_tickets WHERE id = p_ticket_id;
  IF v_owner IS NULL OR v_owner <> auth.uid() THEN
    RAISE EXCEPTION 'exos_set_ticket_access_needs: not the ticket owner' USING ERRCODE = '42501';
  END IF;
  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'exos_set_ticket_access_needs: ticket is %', v_status;
  END IF;
  SELECT coalesce(array_agg(DISTINCT n ORDER BY n), '{}'::text[]) INTO v_needs
    FROM unnest(coalesce(p_needs, '{}'::text[])) n WHERE n IS NOT NULL;
  IF NOT public._exos_access_needs_ok(v_needs) THEN
    RAISE EXCEPTION 'exos_set_ticket_access_needs: unknown access need' USING ERRCODE = '22023';
  END IF;
  UPDATE public.exos_tickets
     SET access_needs = v_needs,
         access_needs_by = CASE WHEN cardinality(v_needs) = 0 THEN NULL ELSE auth.uid() END
   WHERE id = p_ticket_id;
  RETURN v_needs;
END $$;

CREATE OR REPLACE FUNCTION public.exos_ticket_access_needs(p_ticket_id uuid)
RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT CASE WHEN t.access_needs_by = t.owner_id THEN t.access_needs ELSE '{}'::text[] END
    FROM public.exos_tickets t
   WHERE t.id = p_ticket_id AND t.owner_id = auth.uid()
$$;
REVOKE ALL ON FUNCTION public.exos_set_ticket_access_needs(uuid, text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.exos_ticket_access_needs(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_set_ticket_access_needs(uuid, text[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_ticket_access_needs(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Staff: who asked for what (report panel + CSV)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_event_access_requests(p_event_id uuid)
RETURNS TABLE (source text, ref_id uuid, name text, detail text, needs text[], checked_in boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_event_access_requests: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT (public.exos_is_admin()
                           OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'scanner'])) THEN
    RAISE EXCEPTION 'exos_event_access_requests: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT 'ticket'::text, t.id,
           coalesce(nullif(t.attendee_name, ''), p.display_name, 'Ticket holder')::text,
           coalesce(t.tier_name, '')::text,
           t.access_needs, (t.status = 'used')
      FROM public.exos_tickets t
      LEFT JOIN public.exos_profiles p ON p.id = t.owner_id
     WHERE t.event_id = p_event_id AND t.status IN ('active', 'used')
       AND cardinality(t.access_needs) > 0 AND t.access_needs_by = t.owner_id
    UNION ALL
    SELECT 'guest'::text, g.id, g.guest_name::text, l.name::text, g.access_needs, (g.arrived > 0)
      FROM public.exos_guest_list_entries g
      JOIN public.exos_guest_lists l ON l.id = g.list_id
     WHERE g.event_id = p_event_id AND cardinality(g.access_needs) > 0
    ORDER BY 3;
END $$;
REVOKE ALL ON FUNCTION public.exos_event_access_requests(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_access_requests(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Guest-list entries: staff and the list's promoter set needs
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._exos_clean_needs(p text[])
RETURNS text[] LANGUAGE plpgsql IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v text[];
BEGIN
  SELECT coalesce(array_agg(DISTINCT n ORDER BY n), '{}'::text[]) INTO v
    FROM unnest(coalesce(p, '{}'::text[])) n WHERE n IS NOT NULL;
  IF NOT public._exos_access_needs_ok(v) THEN
    RAISE EXCEPTION 'exos: unknown access need' USING ERRCODE = '22023';
  END IF;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public._exos_clean_needs(text[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_set_guest_access_needs(p_entry_id uuid, p_needs text[])
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_list uuid; v text[];
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_set_guest_access_needs: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT list_id INTO v_list FROM public.exos_guest_list_entries WHERE id = p_entry_id;
  IF v_list IS NULL OR NOT public._exos_guest_list_can_edit(v_list) THEN
    RAISE EXCEPTION 'exos_set_guest_access_needs: not allowed' USING ERRCODE = '42501';
  END IF;
  v := public._exos_clean_needs(p_needs);
  UPDATE public.exos_guest_list_entries SET access_needs = v WHERE id = p_entry_id;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION public.exos_promoter_set_guest_access_needs(p_token uuid, p_entry_id uuid, p_needs text[])
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_list uuid; v text[];
BEGIN
  SELECT list_id INTO v_list FROM public.exos_guest_list_entries WHERE id = p_entry_id;
  IF v_list IS NULL THEN
    RAISE EXCEPTION 'exos: that guest isn''t on your list' USING ERRCODE = '42501';
  END IF;
  PERFORM public._exos_promoter_list(p_token, v_list);   -- raises unless the list is this promoter's and open
  v := public._exos_clean_needs(p_needs);
  UPDATE public.exos_guest_list_entries SET access_needs = v WHERE id = p_entry_id;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_guest_access_needs(uuid, text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.exos_promoter_set_guest_access_needs(uuid, uuid, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_set_guest_access_needs(uuid, text[]) TO authenticated, service_role;
-- Promoter links are signed-out (token) like exos_promoter_add_guest.
GRANT EXECUTE ON FUNCTION public.exos_promoter_set_guest_access_needs(uuid, uuid, text[]) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Door download + promoter portal carry the needs (patched in place)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  fn regprocedure := to_regprocedure('public.exos_event_door_extras(uuid)');
  d  text;
  o1 text := $o$'note', g.note) ORDER BY g.guest_name)$o$;
  n1 text := $n$'note', g.note, 'access_needs', to_jsonb(g.access_needs)) ORDER BY g.guest_name)$n$;
  o2 text := $o$       WHERE g.event_id = p_event_id), '[]'::jsonb));$o$;
  n2 text := $n$       WHERE g.event_id = p_event_id), '[]'::jsonb),
    -- Access needs by ticket (mig 20260926090000): only while the holder who
    -- set them still holds the ticket.
    'ticket_access', coalesce((
      SELECT jsonb_object_agg(t.id, to_jsonb(t.access_needs))
        FROM public.exos_tickets t
       WHERE t.event_id = p_event_id AND t.status IN ('active', 'used')
         AND cardinality(t.access_needs) > 0 AND t.access_needs_by = t.owner_id), '{}'::jsonb));$n$;
BEGIN
  IF fn IS NULL THEN
    RAISE EXCEPTION 'exos_event_door_extras not present: apply 20260926050000 first';
  END IF;
  d := pg_get_functiondef(fn);
  IF position('ticket_access' in d) > 0 THEN
    RAISE NOTICE 'exos_event_door_extras: already carries access needs, skipping';
  ELSE
    IF (length(d) - length(replace(d, o1, ''))) / length(o1) <> 1
       OR (length(d) - length(replace(d, o2, ''))) / length(o2) <> 1 THEN
      RAISE EXCEPTION 'exos_event_door_extras: unexpected body, patch markers not found once';
    END IF;
    EXECUTE replace(replace(d, o1, n1), o2, n2);
  END IF;

  fn := to_regprocedure('public.exos_promoter_guest_lists(uuid)');
  IF fn IS NULL THEN
    RAISE EXCEPTION 'exos_promoter_guest_lists not present: apply 20260926050000 first';
  END IF;
  d := pg_get_functiondef(fn);
  o1 := $o$'arrived', g.arrived) ORDER BY g.guest_name)$o$;
  n1 := $n$'arrived', g.arrived, 'access_needs', to_jsonb(g.access_needs)) ORDER BY g.guest_name)$n$;
  IF position('access_needs' in d) > 0 THEN
    RAISE NOTICE 'exos_promoter_guest_lists: already carries access needs, skipping';
  ELSE
    IF (length(d) - length(replace(d, o1, ''))) / length(o1) <> 1 THEN
      RAISE EXCEPTION 'exos_promoter_guest_lists: unexpected body, patch marker not found once';
    END IF;
    EXECUTE replace(d, o1, n1);
  END IF;
END $$;
