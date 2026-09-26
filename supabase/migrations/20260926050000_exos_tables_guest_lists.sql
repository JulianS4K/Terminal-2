-- ============================================================================
-- Migration 20260926050000 — Exos (Bridge / D4): nightlife table packages and
--                            guest lists (promoter-fed, door check-in, offline)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_ticket_tiers (+ kind, party_size, min_spend_cents,
--              section_label; trigger exos_tiers_table_lock)
--              TABLE exos_tickets (trigger exos_tickets_table_guard)
--              TABLE exos_table_bookings, exos_guest_lists,
--                    exos_guest_list_entries, exos_guest_list_checkins (new)
--              FUNCTION exos_tier_party_size, exos_tier_is_table,
--                _exos_book_tables, _exos_tables_release_order,
--                _exos_guest_list_can_edit, _exos_guest_insert,
--                exos_public_table_tiers, exos_event_tables, exos_assign_table,
--                exos_cancel_table_booking, exos_upsert_guest_list,
--                exos_delete_guest_list, exos_add_guest, exos_update_guest,
--                exos_remove_guest, exos_promoter_guest_lists,
--                exos_promoter_add_guest, exos_promoter_remove_guest,
--                exos_guest_check_in, exos_event_door_extras (new)
--              FUNCTION exos_quota_available, exos_effective_available,
--                exos_assert_quota, exos_fulfill_checkout,
--                exos_claim_free_tickets, exos_refund_checkout,
--                exos_release_ticket (patched in place, one marker each)
--           R: exos_events, exos_orgs, exos_org_memberships, exos_promoters,
--              exos_cart_holds, exos_vouchers, exos_quota_tiers, exos_quotas
-- Pre-reqs: 20260925021000 (patch pattern + current fulfill / claim bodies),
--           20260924233000 (exos_promoters.kit_token),
--           20260924210103 (quota-aware mints), 20260924215000 (XF001 fulfill)
--
-- A. TABLES. A table package is a tier with kind = 'table'. Its capacity and
--    sold count TABLES; party_size is the admissions each table includes;
--    the tier price is the deposit per table (normal checkout when payments
--    are live, the free claim path for RSVP tables); min_spend_cents and
--    section_label are informational (shown to the buyer and the door).
--    Buying N tables mints N x party_size admission tickets to the buyer
--    (the host) in one order, and one exos_table_bookings row per table that
--    the organizer later labels ("Table 12"). Inventory units:
--      * tier-local availability (exos_tier_available) stays in tables:
--        capacity - sold - held - voucher-blocked, all counted in tables;
--      * a shared quota counts admissions: tickets already count one row per
--        admission, and holds / blocked vouchers on a table tier now count
--        quantity x party_size (exos_quota_available);
--      * exos_effective_available converts the quota's admissions back into
--        whole tables for a table tier (floor(avail / party_size)), so
--        exos_create_hold / exos_seats_available keep taking a quantity in
--        the tier's own unit; exos_assert_quota multiplies by party_size;
--      * the event house cap (total_tickets / tickets_sold) counts admissions.
--    For every non-table tier exos_tier_party_size() is 1, so all of the
--    above is arithmetically unchanged. exos-checkout needs no change: it
--    already charges price x quantity and holds `quantity` units of the tier.
--    Only the two whole-order paths (fulfillment, free claim) may mint a
--    table tier's tickets; a guard trigger refuses any other path (box
--    office mint, comps, issue-to-email) instead of letting it mint one
--    ticket that counts as a whole table. Kind and party size lock once the
--    tier has sales. Refunds free the table; a single table ticket can't be
--    self-released (the organizer cancels a free table as a whole).
--
-- B. GUEST LISTS. Per event, named, owned by an org member or a promoter,
--    with an optional head cap (guest + plus-ones). Promoters add names to
--    their own lists from their portal token (same bearer-token pattern as
--    exos_promoter_kit). The door (owner / manager / scanner) searches names
--    and checks in the guest and any number of their plus-ones, never more
--    than 1 + plus_ones in total; each arrival carries an optional client
--    ref so an offline replay is idempotent. Scanners never edit lists and
--    never see guest emails / phones. Guest-list heads do NOT consume ticket
--    inventory by default (operator decision: default off). A list created
--    with counts_toward_capacity = true takes its heads out of the event
--    house cap (exos_events.tickets_sold vs total_tickets) as names are
--    added, and gives them back on removal; tiers and quotas are untouched.
--    exos_event_door_extras is the offline download: table labels by ticket
--    and every guest-list entry, in one door-role-gated call.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- Patch helper: every replacement asserts its match count, the whole function
-- is skipped once its marker is present.
CREATE OR REPLACE FUNCTION pg_temp.tg_patch(p_sig text, p_marker text, p_old text[], p_new text[], p_hits int[])
RETURNS void LANGUAGE plpgsql AS $$
DECLARE fn regprocedure := to_regprocedure(p_sig); d text; n int; i int;
BEGIN
  IF fn IS NULL THEN
    RAISE EXCEPTION '%: not present (apply its migration first)', p_sig;
  END IF;
  d := pg_get_functiondef(fn);
  IF position(p_marker in d) > 0 THEN
    RAISE NOTICE '%: already patched (%)', fn, p_marker;
    RETURN;
  END IF;
  FOR i IN 1..array_length(p_old, 1) LOOP
    n := (length(d) - length(replace(d, p_old[i], ''))) / length(p_old[i]);
    IF n <> p_hits[i] THEN
      RAISE EXCEPTION '%: patch % expected % match(es), found %', fn, i, p_hits[i], n;
    END IF;
    d := replace(d, p_old[i], p_new[i]);
  END LOOP;
  IF position(p_marker in d) = 0 THEN
    RAISE EXCEPTION '%: marker % missing after patch', fn, p_marker;
  END IF;
  EXECUTE d;
END $$;

-- A1. Table columns on tiers ---------------------------------------------------

ALTER TABLE public.exos_ticket_tiers ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'standard';
ALTER TABLE public.exos_ticket_tiers ADD COLUMN IF NOT EXISTS party_size integer;
ALTER TABLE public.exos_ticket_tiers ADD COLUMN IF NOT EXISTS min_spend_cents integer;
ALTER TABLE public.exos_ticket_tiers ADD COLUMN IF NOT EXISTS section_label text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_ticket_tiers_kind_chk') THEN
    ALTER TABLE public.exos_ticket_tiers ADD CONSTRAINT exos_ticket_tiers_kind_chk
      CHECK (kind IN ('standard', 'table'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_ticket_tiers_table_chk') THEN
    ALTER TABLE public.exos_ticket_tiers ADD CONSTRAINT exos_ticket_tiers_table_chk
      CHECK ((party_size IS NULL OR party_size BETWEEN 1 AND 50)
             AND (kind <> 'table' OR party_size IS NOT NULL)
             AND (min_spend_cents IS NULL OR min_spend_cents BETWEEN 0 AND 100000000)
             AND (section_label IS NULL OR length(section_label) BETWEEN 1 AND 60));
  END IF;
END $$;

COMMENT ON COLUMN public.exos_ticket_tiers.kind IS
  'standard | table. A table tier''s capacity/sold count tables; each table mints party_size tickets. mig 20260926050000.';
COMMENT ON COLUMN public.exos_ticket_tiers.min_spend_cents IS
  'Table minimum spend in cents (informational: shown to buyer and door, not charged). mig 20260926050000.';

-- Anon reads tiers through column grants; the table fields are public.
GRANT SELECT (kind, party_size, min_spend_cents, section_label) ON public.exos_ticket_tiers TO anon;

CREATE OR REPLACE FUNCTION public.exos_tier_is_table(p_tier_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$ SELECT coalesce((SELECT kind = 'table' FROM public.exos_ticket_tiers WHERE id = p_tier_id), false) $$;

-- Admissions per unit of the tier: party_size for a table, 1 for anything else.
CREATE OR REPLACE FUNCTION public.exos_tier_party_size(p_tier_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT coalesce((SELECT CASE WHEN kind = 'table' THEN greatest(coalesce(party_size, 1), 1) ELSE 1 END
                     FROM public.exos_ticket_tiers WHERE id = p_tier_id), 1)
$$;
REVOKE ALL ON FUNCTION public.exos_tier_is_table(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.exos_tier_party_size(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_tier_is_table(uuid) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.exos_tier_party_size(uuid) TO anon, authenticated, service_role;

-- Kind / party size are the unit of every sale already made: lock them.
CREATE OR REPLACE FUNCTION public.exos_tg_tier_table_lock()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF (NEW.kind IS DISTINCT FROM OLD.kind OR NEW.party_size IS DISTINCT FROM OLD.party_size)
     AND (OLD.sold > 0
          OR EXISTS (SELECT 1 FROM public.exos_tickets t WHERE t.tier_id = OLD.id)
          OR EXISTS (SELECT 1 FROM public.exos_cart_holds h
                      WHERE h.tier_id = OLD.id AND h.status = 'active' AND h.expires_at > now())) THEN
    RAISE EXCEPTION 'exos: this tier has sales, so its table setting and party size can''t change'
      USING ERRCODE = '23514';
  END IF;
  IF NEW.kind <> 'table' THEN
    NEW.party_size := NULL;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_tier_table_lock() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tiers_table_lock ON public.exos_ticket_tiers;
CREATE TRIGGER exos_tiers_table_lock BEFORE UPDATE OF kind, party_size ON public.exos_ticket_tiers
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_tier_table_lock();

-- A2. Bookings ---------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.exos_table_bookings (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  tier_id     uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE SET NULL,
  order_ref   text NOT NULL,
  host_uid    uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  ticket_ids  uuid[] NOT NULL,
  party_size  integer NOT NULL CHECK (party_size BETWEEN 1 AND 50),
  label       text CHECK (label IS NULL OR length(btrim(label)) BETWEEN 1 AND 40),
  status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'cancelled')),
  assigned_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  assigned_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_table_bookings_event_idx ON public.exos_table_bookings (event_id);
CREATE INDEX IF NOT EXISTS exos_table_bookings_order_idx ON public.exos_table_bookings (order_ref);
CREATE INDEX IF NOT EXISTS exos_table_bookings_tier_idx ON public.exos_table_bookings (tier_id);
CREATE INDEX IF NOT EXISTS exos_table_bookings_host_idx ON public.exos_table_bookings (host_uid);
-- One live booking per table number per event.
CREATE UNIQUE INDEX IF NOT EXISTS exos_table_bookings_label_uq
  ON public.exos_table_bookings (event_id, lower(btrim(label)))
  WHERE label IS NOT NULL AND status = 'active';

ALTER TABLE public.exos_table_bookings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_table_bookings FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_table_bookings TO service_role;
GRANT SELECT ON public.exos_table_bookings TO authenticated;
DROP POLICY IF EXISTS exos_table_bookings_read ON public.exos_table_bookings;
CREATE POLICY exos_table_bookings_read ON public.exos_table_bookings
  FOR SELECT TO authenticated
  USING (host_uid = (SELECT auth.uid())
         OR public.exos_is_admin()
         OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance']));
DROP TRIGGER IF EXISTS exos_table_bookings_touch ON public.exos_table_bookings;
CREATE TRIGGER exos_table_bookings_touch BEFORE UPDATE ON public.exos_table_bookings
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- Only the whole-order paths mint a table tier's tickets. They announce the
-- order they are minting (transaction-local setting, cleared by
-- _exos_book_tables); any other insert for a table tier is refused.
CREATE OR REPLACE FUNCTION public.exos_tg_table_ticket_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF public.exos_tier_is_table(NEW.tier_id)
     AND coalesce(current_setting('exos.table_mint', true), '') IS DISTINCT FROM coalesce(NEW.order_ref, '-') THEN
    RAISE EXCEPTION 'exos: a table is sold as a whole (checkout or the free table claim), not as single tickets'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_table_ticket_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS exos_tickets_table_guard ON public.exos_tickets;
CREATE TRIGGER exos_tickets_table_guard BEFORE INSERT ON public.exos_tickets
  FOR EACH ROW WHEN (NEW.tier_id IS NOT NULL) EXECUTE FUNCTION public.exos_tg_table_ticket_guard();

-- Split an order's tickets into one booking per table. No-op for other tiers.
-- Internal: called by the SECURITY DEFINER mint paths only.
CREATE OR REPLACE FUNCTION public._exos_book_tables(
  p_tier_id uuid, p_order_ref text, p_host uuid, p_ticket_ids uuid[], p_tables integer)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_party int;
  v_n     int := coalesce(array_length(p_ticket_ids, 1), 0);
  v_ev    uuid;
  v_org   uuid;
  i       int;
BEGIN
  PERFORM set_config('exos.table_mint', '', true);
  IF p_tier_id IS NULL OR NOT public.exos_tier_is_table(p_tier_id) THEN
    RETURN 0;
  END IF;
  v_party := public.exos_tier_party_size(p_tier_id);
  IF coalesce(p_tables, 0) < 1 OR v_n <> v_party * p_tables THEN
    RAISE EXCEPTION 'table order % has % tickets for % table(s) of %', p_order_ref, v_n, p_tables, v_party
      USING ERRCODE = 'XF001';
  END IF;
  SELECT t.event_id, e.org_id INTO v_ev, v_org
    FROM public.exos_ticket_tiers t JOIN public.exos_events e ON e.id = t.event_id
   WHERE t.id = p_tier_id;
  FOR i IN 0..p_tables - 1 LOOP
    INSERT INTO public.exos_table_bookings (event_id, org_id, tier_id, order_ref, host_uid, ticket_ids, party_size)
    VALUES (v_ev, v_org, p_tier_id, p_order_ref, p_host,
            p_ticket_ids[i * v_party + 1 : (i + 1) * v_party], v_party);
  END LOOP;
  RETURN p_tables;
END $$;
REVOKE ALL ON FUNCTION public._exos_book_tables(uuid, text, uuid, uuid[], integer) FROM PUBLIC, anon, authenticated, service_role;

-- After a refund voided an order's tickets: cancel its tables, and give a
-- table back to the tier unless someone from it was already checked in.
CREATE OR REPLACE FUNCTION public._exos_tables_release_order(p_order_ref text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE b record; v_n int := 0;
BEGIN
  FOR b IN
    SELECT * FROM public.exos_table_bookings
     WHERE order_ref = p_order_ref AND status = 'active'
       AND NOT EXISTS (SELECT 1 FROM public.exos_tickets t
                        WHERE t.id = ANY (ticket_ids) AND t.status IN ('active', 'used', 'transferred'))
     FOR UPDATE
  LOOP
    UPDATE public.exos_table_bookings SET status = 'cancelled' WHERE id = b.id;
    IF b.tier_id IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM public.exos_tickets t WHERE t.id = ANY (b.ticket_ids) AND t.check_in_at IS NOT NULL) THEN
      UPDATE public.exos_ticket_tiers SET sold = greatest(0, sold - 1) WHERE id = b.tier_id;
    END IF;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public._exos_tables_release_order(text) FROM PUBLIC, anon, authenticated, service_role;

-- A3. Quota arithmetic in admissions ------------------------------------------

SELECT pg_temp.tg_patch('public.exos_quota_available(uuid)', 'exos_tier_party_size',
  ARRAY['SELECT COALESCE(SUM(h.quantity), 0) INTO v_held',
        'SELECT COALESCE(SUM(v.max_uses - v.used_count), 0) INTO v_blocked'],
  ARRAY['SELECT COALESCE(SUM(h.quantity * public.exos_tier_party_size(h.tier_id)), 0) INTO v_held',
        'SELECT COALESCE(SUM((v.max_uses - v.used_count) * public.exos_tier_party_size(v.tier_id)), 0) INTO v_blocked'],
  ARRAY[1, 1]);

SELECT pg_temp.tg_patch('public.exos_effective_available(uuid)', 'exos_tier_party_size',
  ARRAY['v_qav := public.exos_quota_available(r.quota_id);'],
  ARRAY['v_qav := public.exos_quota_available(r.quota_id) / public.exos_tier_party_size(p_tier_id);  -- whole tables for a table tier'],
  ARRAY[1]);

SELECT pg_temp.tg_patch('public.exos_assert_quota(uuid, integer)', 'exos_tier_party_size',
  ARRAY['IF v_lock IS NOT NULL AND v_lock < p_quantity THEN'],
  ARRAY['IF v_lock IS NOT NULL AND v_lock < p_quantity * public.exos_tier_party_size(p_tier_id) THEN'],
  ARRAY[1]);

-- A4. Whole-order mint paths -------------------------------------------------

SELECT pg_temp.tg_patch('public.exos_fulfill_checkout(text)', 'exos_tier_party_size',
  ARRAY['tickets_sold + s.quantity',
        'FOR i IN 1..s.quantity LOOP',
        '/ 100 / s.quantity, 2)',
        E'    IF s.addons IS NOT NULL AND jsonb_typeof(s.addons) = ''array'' THEN'],
  ARRAY['tickets_sold + s.quantity * public.exos_tier_party_size(s.tier_id)',
        E'PERFORM set_config(''exos.table_mint'', p_session_id, true);\n    FOR i IN 1..s.quantity * public.exos_tier_party_size(s.tier_id) LOOP',
        '/ 100 / (s.quantity * public.exos_tier_party_size(s.tier_id)), 2)',
        E'    -- A table order: one booking per table (mig 20260926050000).\n    PERFORM public._exos_book_tables(s.tier_id, p_session_id, s.buyer_uid, v_ids, s.quantity);\n\n    IF s.addons IS NOT NULL AND jsonb_typeof(s.addons) = ''array'' THEN'],
  ARRAY[2, 1, 1, 1]);

SELECT pg_temp.tg_patch('public.exos_claim_free_tickets(uuid, uuid, integer, text, text, text)', 'exos_tier_party_size',
  ARRAY[E'  v_uid        uuid := auth.uid();',
        'tickets_sold + p_quantity',
        'FOR i IN 1..p_quantity LOOP',
        E'coalesce(nullif(p_order_ref, ''''), ''free_'' || gen_random_uuid()::text),',
        E'  RETURN v_ids;\nEND'],
  ARRAY[E'  v_uid        uuid := auth.uid();\n  v_tref       text := coalesce(nullif(p_order_ref, ''''), ''free_'' || gen_random_uuid()::text);',
        'tickets_sold + p_quantity * public.exos_tier_party_size(p_tier_id)',
        E'PERFORM set_config(''exos.table_mint'', v_tref, true);\n  FOR i IN 1..p_quantity * public.exos_tier_party_size(p_tier_id) LOOP',
        E'CASE WHEN public.exos_tier_is_table(p_tier_id) THEN v_tref\n           ELSE coalesce(nullif(p_order_ref, ''''), ''free_'' || gen_random_uuid()::text) END,',
        E'  -- A table claim: one booking per table (mig 20260926050000).\n  PERFORM public._exos_book_tables(p_tier_id, v_tref, v_uid, v_ids, p_quantity);\n\n  RETURN v_ids;\nEND'],
  ARRAY[1, 2, 1, 1, 1]);

-- A5. Give tables back correctly ---------------------------------------------

SELECT pg_temp.tg_patch('public.exos_refund_checkout(text, text)', '_exos_tables_release_order',
  ARRAY['UPDATE public.exos_ticket_tiers SET sold = greatest(0, sold - 1) WHERE id = r.tier_id;',
        E'  IF v_n > 0 THEN'],
  ARRAY[E'IF NOT public.exos_tier_is_table(r.tier_id) THEN\n        UPDATE public.exos_ticket_tiers SET sold = greatest(0, sold - 1) WHERE id = r.tier_id;\n      END IF;',
        E'  -- Table tiers count tables, not tickets (mig 20260926050000).\n  PERFORM public._exos_tables_release_order(p_session_id);\n\n  IF v_n > 0 THEN'],
  ARRAY[1, 1]);

SELECT pg_temp.tg_patch('public.exos_release_ticket(uuid)', 'exos_tier_is_table',
  ARRAY[E'  IF v_staff THEN\n    v_reason := ''released-by-staff'';'],
  ARRAY[E'  IF public.exos_tier_is_table(t.tier_id) THEN\n    RAISE EXCEPTION ''exos_release_ticket: this ticket is part of a table — the organizer cancels the whole table'';\n  END IF;\n\n  IF v_staff THEN\n    v_reason := ''released-by-staff'';'],
  ARRAY[1]);

-- A6. Table RPCs ---------------------------------------------------------------

-- Buyer side: the table facts of an event's public tiers.
CREATE OR REPLACE FUNCTION public.exos_public_table_tiers(p_event_id uuid)
RETURNS TABLE (tier_id uuid, party_size integer, min_spend_cents integer, section_label text,
               tables_left integer)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT t.id, t.party_size, t.min_spend_cents, t.section_label,
         public.exos_effective_available(t.id)
    FROM public.exos_ticket_tiers t
    JOIN public.exos_events e ON e.id = t.event_id
   WHERE t.event_id = p_event_id AND t.kind = 'table'
     AND t.visibility = 'public' AND e.status = 'published'
   ORDER BY t.sort_order, t.name;
$$;
REVOKE ALL ON FUNCTION public.exos_public_table_tiers(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_public_table_tiers(uuid) TO anon, authenticated, service_role;

-- Organizer list of sold tables (owner / manager / finance).
CREATE OR REPLACE FUNCTION public.exos_event_tables(p_event_id uuid)
RETURNS TABLE (booking_id uuid, tier_id uuid, tier_name text, section_label text,
               party_size integer, min_spend_cents integer, label text, status text,
               host_email text, host_name text, tickets integer, checked_in integer,
               created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT (public.exos_is_admin()
                           OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance'])) THEN
    RAISE EXCEPTION 'exos_event_tables: not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT b.id, b.tier_id, tr.name, tr.section_label, b.party_size, tr.min_spend_cents,
           b.label, b.status, h.buyer_email, h.attendee_name,
           (SELECT count(*)::int FROM public.exos_tickets t
             WHERE t.id = ANY (b.ticket_ids) AND t.status IN ('active', 'used', 'transferred')),
           (SELECT count(*)::int FROM public.exos_tickets t
             WHERE t.id = ANY (b.ticket_ids) AND t.check_in_at IS NOT NULL AND t.status <> 'voided'),
           b.created_at
      FROM public.exos_table_bookings b
      LEFT JOIN public.exos_ticket_tiers tr ON tr.id = b.tier_id
      LEFT JOIN LATERAL (SELECT t.buyer_email, t.attendee_name FROM public.exos_tickets t
                          WHERE t.id = b.ticket_ids[1]) h ON true
     WHERE b.event_id = p_event_id
     ORDER BY b.status, b.label NULLS LAST, b.created_at;
END $$;
REVOKE ALL ON FUNCTION public.exos_event_tables(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_tables(uuid) TO authenticated, service_role;

-- Give a sold table its number / name (owner / manager). Empty clears it.
CREATE OR REPLACE FUNCTION public.exos_assign_table(p_booking_id uuid, p_label text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE b public.exos_table_bookings%ROWTYPE; v_label text := nullif(btrim(coalesce(p_label, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_assign_table: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO b FROM public.exos_table_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND OR NOT (public.exos_is_admin() OR public.exos_has_org_role(b.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_assign_table: not allowed' USING ERRCODE = '42501';
  END IF;
  IF b.status <> 'active' THEN
    RAISE EXCEPTION 'exos_assign_table: this table was cancelled';
  END IF;
  IF v_label IS NOT NULL AND length(v_label) > 40 THEN
    RAISE EXCEPTION 'exos_assign_table: keep the table name under 40 characters';
  END IF;
  BEGIN
    UPDATE public.exos_table_bookings
       SET label = v_label, assigned_by = auth.uid(), assigned_at = now()
     WHERE id = p_booking_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'exos_assign_table: % is already assigned to another booking', v_label USING ERRCODE = '23505';
  END;
END $$;
REVOKE ALL ON FUNCTION public.exos_assign_table(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_assign_table(uuid, text) TO authenticated, service_role;

-- Cancel a FREE table as a whole (owner / manager): voids its unused tickets
-- and gives the table back. A paid table is refunded instead.
CREATE OR REPLACE FUNCTION public.exos_cancel_table_booking(p_booking_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE b public.exos_table_bookings%ROWTYPE; v_n int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_cancel_table_booking: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO b FROM public.exos_table_bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND OR NOT (public.exos_is_admin() OR public.exos_has_org_role(b.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_cancel_table_booking: not allowed' USING ERRCODE = '42501';
  END IF;
  IF b.status <> 'active' THEN
    RETURN 0;
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_tickets t WHERE t.id = ANY (b.ticket_ids) AND coalesce(t.price_paid, 0) <> 0) THEN
    RAISE EXCEPTION 'exos_cancel_table_booking: this table was paid for — refund the order instead';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_tickets t WHERE t.id = ANY (b.ticket_ids)
              AND (t.check_in_at IS NOT NULL OR t.pending_transfer_id IS NOT NULL)) THEN
    RAISE EXCEPTION 'exos_cancel_table_booking: someone from this table is checked in or mid-transfer';
  END IF;
  UPDATE public.exos_tickets
     SET status = 'voided', voided_at = now(), voided_by = auth.uid(), voided_reason = 'table-cancelled'
   WHERE id = ANY (b.ticket_ids) AND status = 'active';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE public.exos_table_bookings SET status = 'cancelled' WHERE id = b.id;
  IF b.tier_id IS NOT NULL THEN
    UPDATE public.exos_ticket_tiers SET sold = greatest(0, sold - 1) WHERE id = b.tier_id;
  END IF;
  UPDATE public.exos_events SET tickets_sold = greatest(0, tickets_sold - v_n) WHERE id = b.event_id;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_cancel_table_booking(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_cancel_table_booking(uuid) TO authenticated, service_role;

-- B1. Guest lists ------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.exos_guest_lists (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id               uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id                 uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name                   text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  owner_uid              uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  promoter_id            uuid REFERENCES public.exos_promoters (id) ON DELETE SET NULL,
  cap                    integer CHECK (cap IS NULL OR cap BETWEEN 1 AND 5000),
  max_plus_ones          integer NOT NULL DEFAULT 5 CHECK (max_plus_ones BETWEEN 0 AND 20),
  counts_toward_capacity boolean NOT NULL DEFAULT false,
  status                 text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  closes_at              timestamptz,
  created_by             uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_guest_lists_event_idx ON public.exos_guest_lists (event_id);
CREATE INDEX IF NOT EXISTS exos_guest_lists_promoter_idx ON public.exos_guest_lists (promoter_id) WHERE promoter_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_guest_lists_owner_idx ON public.exos_guest_lists (owner_uid) WHERE owner_uid IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.exos_guest_list_entries (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  list_id           uuid NOT NULL REFERENCES public.exos_guest_lists (id) ON DELETE CASCADE,
  event_id          uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id            uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  guest_name        text NOT NULL CHECK (length(btrim(guest_name)) BETWEEN 1 AND 80),
  email             text CHECK (email IS NULL OR (length(email) <= 254 AND email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')),
  phone             text CHECK (phone IS NULL OR phone ~ '^[0-9+() .-]{3,32}$'),
  plus_ones         integer NOT NULL DEFAULT 0 CHECK (plus_ones BETWEEN 0 AND 20),
  arrived           integer NOT NULL DEFAULT 0,
  arrived_at        timestamptz,
  note              text CHECK (note IS NULL OR length(note) <= 200),
  added_by          uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  added_by_promoter uuid REFERENCES public.exos_promoters (id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_guest_list_entries_arrived_chk CHECK (arrived >= 0 AND arrived <= plus_ones + 1)
);
CREATE INDEX IF NOT EXISTS exos_guest_list_entries_list_idx ON public.exos_guest_list_entries (list_id);
CREATE INDEX IF NOT EXISTS exos_guest_list_entries_event_idx ON public.exos_guest_list_entries (event_id);

-- Append-only arrival log; client_ref makes an offline replay idempotent.
CREATE TABLE IF NOT EXISTS public.exos_guest_list_checkins (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_id   uuid NOT NULL REFERENCES public.exos_guest_list_entries (id) ON DELETE CASCADE,
  event_id   uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  count      integer NOT NULL CHECK (count BETWEEN 1 AND 21),
  client_ref uuid UNIQUE,
  source     text NOT NULL DEFAULT 'online' CHECK (source IN ('online', 'offline-sync')),
  scanned_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_guest_list_checkins_entry_idx ON public.exos_guest_list_checkins (entry_id);
CREATE INDEX IF NOT EXISTS exos_guest_list_checkins_event_idx ON public.exos_guest_list_checkins (event_id);

DO $$
DECLARE t text; r text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_guest_lists', 'exos_guest_list_entries', 'exos_guest_list_checkins'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    -- Guest names / phones: keep them away from prod's read-only analytics roles.
    FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END IF;
    END LOOP;
  END LOOP;
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON public.exos_table_bookings FROM %I', r);
    END IF;
  END LOOP;
END $$;
GRANT SELECT ON public.exos_guest_lists, public.exos_guest_list_entries TO authenticated;

-- Who may edit a list's names: owner / manager, or the org member who owns
-- the list (any role but scanner). Scanners check in; they never edit.
CREATE OR REPLACE FUNCTION public._exos_guest_list_can_edit(p_list_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.exos_guest_lists l
     WHERE l.id = p_list_id
       AND (public.exos_is_admin()
            OR public.exos_has_org_role(l.org_id, ARRAY['owner', 'manager'])
            OR (l.owner_uid = auth.uid()
                AND public.exos_has_org_role(l.org_id, ARRAY['owner', 'manager', 'finance', 'content']))))
$$;
REVOKE ALL ON FUNCTION public._exos_guest_list_can_edit(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._exos_guest_list_can_edit(uuid) TO authenticated, service_role;

DROP POLICY IF EXISTS exos_guest_lists_read ON public.exos_guest_lists;
CREATE POLICY exos_guest_lists_read ON public.exos_guest_lists
  FOR SELECT TO authenticated
  USING (public.exos_is_admin()
         OR public.exos_has_org_role(org_id, ARRAY['owner', 'manager'])
         OR (owner_uid = (SELECT auth.uid())
             AND public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance', 'content'])));
DROP POLICY IF EXISTS exos_guest_list_entries_read ON public.exos_guest_list_entries;
CREATE POLICY exos_guest_list_entries_read ON public.exos_guest_list_entries
  FOR SELECT TO authenticated
  USING (public._exos_guest_list_can_edit(list_id));
DROP TRIGGER IF EXISTS exos_guest_lists_touch ON public.exos_guest_lists;
CREATE TRIGGER exos_guest_lists_touch BEFORE UPDATE ON public.exos_guest_lists
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();
DROP TRIGGER IF EXISTS exos_guest_list_entries_touch ON public.exos_guest_list_entries;
CREATE TRIGGER exos_guest_list_entries_touch BEFORE UPDATE ON public.exos_guest_list_entries
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- Heads (guest + plus-ones) currently on a list.
CREATE OR REPLACE FUNCTION public._exos_guest_list_heads(p_list_id uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$ SELECT coalesce(sum(1 + plus_ones), 0)::int FROM public.exos_guest_list_entries WHERE list_id = p_list_id $$;
REVOKE ALL ON FUNCTION public._exos_guest_list_heads(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- Take / give back heads from the event house cap for a counting list.
CREATE OR REPLACE FUNCTION public._exos_guest_capacity(p_event_id uuid, p_delta integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF p_delta > 0 THEN
    UPDATE public.exos_events
       SET tickets_sold = tickets_sold + p_delta
     WHERE id = p_event_id AND (total_tickets = 0 OR tickets_sold + p_delta <= total_tickets);
    IF NOT FOUND THEN
      RAISE EXCEPTION 'exos: the event is at capacity' USING ERRCODE = '23514';
    END IF;
  ELSIF p_delta < 0 THEN
    UPDATE public.exos_events SET tickets_sold = greatest(0, tickets_sold + p_delta) WHERE id = p_event_id;
  END IF;
END $$;
REVOKE ALL ON FUNCTION public._exos_guest_capacity(uuid, integer) FROM PUBLIC, anon, authenticated, service_role;

-- Shared insert: validates, locks the list, enforces cap + plus-one limit.
CREATE OR REPLACE FUNCTION public._exos_guest_insert(
  p_list_id uuid, p_guest_name text, p_email text, p_phone text, p_plus_ones integer,
  p_note text, p_added_by uuid, p_promoter uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  l      public.exos_guest_lists%ROWTYPE;
  v_ev   text;
  v_pl   int := coalesce(p_plus_ones, 0);
  v_id   uuid;
BEGIN
  SELECT * INTO l FROM public.exos_guest_lists WHERE id = p_list_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos: guest list not found';
  END IF;
  SELECT status INTO v_ev FROM public.exos_events WHERE id = l.event_id;
  IF v_ev = 'cancelled' THEN
    RAISE EXCEPTION 'exos: the event was cancelled' USING ERRCODE = '23514';
  END IF;
  IF nullif(btrim(coalesce(p_guest_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'exos: add the guest''s name';
  END IF;
  IF v_pl < 0 OR v_pl > l.max_plus_ones THEN
    RAISE EXCEPTION 'exos: this list allows up to % plus-one(s)', l.max_plus_ones USING ERRCODE = '23514';
  END IF;
  IF l.cap IS NOT NULL AND public._exos_guest_list_heads(l.id) + 1 + v_pl > l.cap THEN
    RAISE EXCEPTION 'exos: the list is full (% of % spots taken)', public._exos_guest_list_heads(l.id), l.cap
      USING ERRCODE = '23514';
  END IF;
  IF l.counts_toward_capacity THEN
    PERFORM public._exos_guest_capacity(l.event_id, 1 + v_pl);
  END IF;
  INSERT INTO public.exos_guest_list_entries
    (list_id, event_id, org_id, guest_name, email, phone, plus_ones, note, added_by, added_by_promoter)
  VALUES (l.id, l.event_id, l.org_id, left(btrim(p_guest_name), 80),
          nullif(lower(btrim(coalesce(p_email, ''))), ''), nullif(btrim(coalesce(p_phone, '')), ''),
          v_pl, nullif(btrim(coalesce(p_note, '')), ''), p_added_by, p_promoter)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public._exos_guest_insert(uuid, text, text, text, integer, text, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

-- Create or edit a list (owner / manager).
CREATE OR REPLACE FUNCTION public.exos_upsert_guest_list(
  p_event_id uuid, p_name text, p_cap integer DEFAULT NULL, p_promoter_id uuid DEFAULT NULL,
  p_counts_toward_capacity boolean DEFAULT false, p_max_plus_ones integer DEFAULT 5,
  p_list_id uuid DEFAULT NULL, p_status text DEFAULT 'open', p_closes_at timestamptz DEFAULT NULL,
  p_owner_uid uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_org   uuid;
  v_owner uuid;
  v_id    uuid;
  l       public.exos_guest_lists%ROWTYPE;
  v_heads int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_upsert_guest_list: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_upsert_guest_list: not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_promoter_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_promoters WHERE id = p_promoter_id AND org_id = v_org) THEN
    RAISE EXCEPTION 'exos_upsert_guest_list: that promoter is not part of this organization';
  END IF;
  IF p_status NOT IN ('open', 'closed') THEN
    RAISE EXCEPTION 'exos_upsert_guest_list: bad status %', p_status;
  END IF;
  v_owner := coalesce(p_owner_uid, CASE WHEN p_promoter_id IS NULL THEN auth.uid() END);
  IF v_owner IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_org_memberships m
        WHERE m.org_id = v_org AND m.user_id = v_owner AND m.disabled IS NOT TRUE
          AND m.role IN ('owner', 'manager', 'finance', 'content')) THEN
    RAISE EXCEPTION 'exos_upsert_guest_list: the list owner must be an org member who can edit (not a scanner)';
  END IF;

  IF p_list_id IS NULL THEN
    INSERT INTO public.exos_guest_lists
      (event_id, org_id, name, owner_uid, promoter_id, cap, max_plus_ones, counts_toward_capacity,
       status, closes_at, created_by)
    VALUES (p_event_id, v_org, btrim(p_name), v_owner, p_promoter_id, p_cap, coalesce(p_max_plus_ones, 5),
            coalesce(p_counts_toward_capacity, false), p_status, p_closes_at, auth.uid())
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;

  SELECT * INTO l FROM public.exos_guest_lists WHERE id = p_list_id AND event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_upsert_guest_list: list not found for this event';
  END IF;
  v_heads := public._exos_guest_list_heads(l.id);
  IF p_cap IS NOT NULL AND p_cap < v_heads THEN
    RAISE EXCEPTION 'exos_upsert_guest_list: % spots are already taken — the cap can''t go lower', v_heads
      USING ERRCODE = '23514';
  END IF;
  IF coalesce(p_counts_toward_capacity, false) <> l.counts_toward_capacity AND v_heads > 0 THEN
    RAISE EXCEPTION 'exos_upsert_guest_list: "counts toward capacity" can only change while the list is empty'
      USING ERRCODE = '23514';
  END IF;
  UPDATE public.exos_guest_lists
     SET name = btrim(p_name), owner_uid = v_owner, promoter_id = p_promoter_id, cap = p_cap,
         max_plus_ones = coalesce(p_max_plus_ones, 5),
         counts_toward_capacity = coalesce(p_counts_toward_capacity, false),
         status = p_status, closes_at = p_closes_at
   WHERE id = l.id;
  RETURN l.id;
END $$;
REVOKE ALL ON FUNCTION public.exos_upsert_guest_list(uuid, text, integer, uuid, boolean, integer, uuid, text, timestamptz, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_upsert_guest_list(uuid, text, integer, uuid, boolean, integer, uuid, text, timestamptz, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_delete_guest_list(p_list_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE l public.exos_guest_lists%ROWTYPE;
BEGIN
  SELECT * INTO l FROM public.exos_guest_lists WHERE id = p_list_id FOR UPDATE;
  IF NOT FOUND OR NOT (public.exos_is_admin() OR public.exos_has_org_role(l.org_id, ARRAY['owner', 'manager'])) THEN
    RAISE EXCEPTION 'exos_delete_guest_list: not allowed' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_guest_list_entries WHERE list_id = l.id AND arrived > 0) THEN
    RAISE EXCEPTION 'exos_delete_guest_list: guests on this list already arrived — close it instead';
  END IF;
  IF l.counts_toward_capacity THEN
    PERFORM public._exos_guest_capacity(l.event_id, -public._exos_guest_list_heads(l.id));
  END IF;
  DELETE FROM public.exos_guest_lists WHERE id = l.id;
END $$;
REVOKE ALL ON FUNCTION public.exos_delete_guest_list(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_delete_guest_list(uuid) TO authenticated, service_role;

-- Staff / list-owner edits of names.
CREATE OR REPLACE FUNCTION public.exos_add_guest(
  p_list_id uuid, p_guest_name text, p_email text DEFAULT NULL, p_phone text DEFAULT NULL,
  p_plus_ones integer DEFAULT 0, p_note text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_add_guest: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT public._exos_guest_list_can_edit(p_list_id) THEN
    RAISE EXCEPTION 'exos_add_guest: not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN public._exos_guest_insert(p_list_id, p_guest_name, p_email, p_phone, p_plus_ones, p_note, auth.uid(), NULL);
END $$;
REVOKE ALL ON FUNCTION public.exos_add_guest(uuid, text, text, text, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_add_guest(uuid, text, text, text, integer, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_update_guest(
  p_entry_id uuid, p_guest_name text, p_email text DEFAULT NULL, p_phone text DEFAULT NULL,
  p_plus_ones integer DEFAULT 0, p_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  en   public.exos_guest_list_entries%ROWTYPE;
  l    public.exos_guest_lists%ROWTYPE;
  v_pl int := coalesce(p_plus_ones, 0);
  v_d  int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_update_guest: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO en FROM public.exos_guest_list_entries WHERE id = p_entry_id;
  IF NOT FOUND OR NOT public._exos_guest_list_can_edit(en.list_id) THEN
    RAISE EXCEPTION 'exos_update_guest: not allowed' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO l FROM public.exos_guest_lists WHERE id = en.list_id FOR UPDATE;
  SELECT * INTO en FROM public.exos_guest_list_entries WHERE id = p_entry_id FOR UPDATE;
  IF nullif(btrim(coalesce(p_guest_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'exos_update_guest: add the guest''s name';
  END IF;
  IF v_pl < 0 OR v_pl > l.max_plus_ones THEN
    RAISE EXCEPTION 'exos_update_guest: this list allows up to % plus-one(s)', l.max_plus_ones USING ERRCODE = '23514';
  END IF;
  IF v_pl + 1 < en.arrived THEN
    RAISE EXCEPTION 'exos_update_guest: % of this party already arrived', en.arrived USING ERRCODE = '23514';
  END IF;
  v_d := v_pl - en.plus_ones;
  IF v_d > 0 AND l.cap IS NOT NULL AND public._exos_guest_list_heads(l.id) + v_d > l.cap THEN
    RAISE EXCEPTION 'exos_update_guest: the list is full' USING ERRCODE = '23514';
  END IF;
  IF l.counts_toward_capacity AND v_d <> 0 THEN
    PERFORM public._exos_guest_capacity(l.event_id, v_d);
  END IF;
  UPDATE public.exos_guest_list_entries
     SET guest_name = left(btrim(p_guest_name), 80),
         email = nullif(lower(btrim(coalesce(p_email, ''))), ''),
         phone = nullif(btrim(coalesce(p_phone, '')), ''),
         plus_ones = v_pl, note = nullif(btrim(coalesce(p_note, '')), '')
   WHERE id = en.id;
END $$;
REVOKE ALL ON FUNCTION public.exos_update_guest(uuid, text, text, text, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_update_guest(uuid, text, text, text, integer, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_remove_guest(p_entry_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE en public.exos_guest_list_entries%ROWTYPE; v_counts boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_remove_guest: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO en FROM public.exos_guest_list_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND OR NOT public._exos_guest_list_can_edit(en.list_id) THEN
    RAISE EXCEPTION 'exos_remove_guest: not allowed' USING ERRCODE = '42501';
  END IF;
  IF en.arrived > 0 THEN
    RAISE EXCEPTION 'exos_remove_guest: this guest already arrived' USING ERRCODE = '23514';
  END IF;
  SELECT counts_toward_capacity INTO v_counts FROM public.exos_guest_lists WHERE id = en.list_id;
  IF v_counts THEN
    PERFORM public._exos_guest_capacity(en.event_id, -(1 + en.plus_ones));
  END IF;
  DELETE FROM public.exos_guest_list_entries WHERE id = en.id;
END $$;
REVOKE ALL ON FUNCTION public.exos_remove_guest(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_remove_guest(uuid) TO authenticated, service_role;

-- B2. Promoter portal (token = exos_promoters.kit_token, like exos_promoter_kit)

-- The promoter's own lists for upcoming published events, with their names.
CREATE OR REPLACE FUNCTION public.exos_promoter_guest_lists(p_token uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'list_id', l.id, 'name', l.name, 'cap', l.cap, 'max_plus_ones', l.max_plus_ones,
           'open', (l.status = 'open' AND (l.closes_at IS NULL OR l.closes_at > now())),
           'closes_at', l.closes_at,
           'event_id', e.id, 'event_name', e.name, 'starts_at', e.starts_at,
           'heads', public._exos_guest_list_heads(l.id),
           'entries', coalesce((
             SELECT jsonb_agg(jsonb_build_object(
                      'id', g.id, 'guest_name', g.guest_name, 'plus_ones', g.plus_ones,
                      'arrived', g.arrived) ORDER BY g.guest_name)
               FROM public.exos_guest_list_entries g WHERE g.list_id = l.id), '[]'::jsonb))
           ORDER BY e.starts_at NULLS LAST, l.name), '[]'::jsonb)
    FROM public.exos_promoters p
    JOIN public.exos_guest_lists l ON l.promoter_id = p.id AND l.org_id = p.org_id
    JOIN public.exos_events e ON e.id = l.event_id
   WHERE p.kit_token = p_token AND p.status = 'active'
     AND e.status = 'published'
     AND (e.starts_at IS NULL OR coalesce(e.ends_at, e.starts_at + interval '12 hours') > now());
$$;
REVOKE ALL ON FUNCTION public.exos_promoter_guest_lists(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_promoter_guest_lists(uuid) TO anon, authenticated, service_role;

-- Resolve (token, list) to the promoter when the list is theirs and open.
CREATE OR REPLACE FUNCTION public._exos_promoter_list(p_token uuid, p_list_id uuid)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_pid uuid; l public.exos_guest_lists%ROWTYPE; e public.exos_events%ROWTYPE;
BEGIN
  SELECT id INTO v_pid FROM public.exos_promoters WHERE kit_token = p_token AND status = 'active';
  IF v_pid IS NULL THEN
    RAISE EXCEPTION 'exos: this promoter link isn''t active' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO l FROM public.exos_guest_lists WHERE id = p_list_id;
  IF NOT FOUND OR l.promoter_id IS DISTINCT FROM v_pid THEN
    RAISE EXCEPTION 'exos: that list isn''t yours' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO e FROM public.exos_events WHERE id = l.event_id;
  IF l.status <> 'open' OR (l.closes_at IS NOT NULL AND l.closes_at <= now())
     OR e.status <> 'published'
     OR (e.starts_at IS NOT NULL AND coalesce(e.ends_at, e.starts_at + interval '12 hours') <= now()) THEN
    RAISE EXCEPTION 'exos: this list is closed' USING ERRCODE = '23514';
  END IF;
  RETURN v_pid;
END $$;
REVOKE ALL ON FUNCTION public._exos_promoter_list(uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_promoter_add_guest(
  p_token uuid, p_list_id uuid, p_guest_name text, p_plus_ones integer DEFAULT 0,
  p_email text DEFAULT NULL, p_phone text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_pid uuid := public._exos_promoter_list(p_token, p_list_id);
BEGIN
  RETURN public._exos_guest_insert(p_list_id, p_guest_name, p_email, p_phone, p_plus_ones, NULL, auth.uid(), v_pid);
END $$;
REVOKE ALL ON FUNCTION public.exos_promoter_add_guest(uuid, uuid, text, integer, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_promoter_add_guest(uuid, uuid, text, integer, text, text) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.exos_promoter_remove_guest(p_token uuid, p_entry_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE en public.exos_guest_list_entries%ROWTYPE; v_counts boolean;
BEGIN
  SELECT * INTO en FROM public.exos_guest_list_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos: guest not found' USING ERRCODE = '42501';
  END IF;
  PERFORM public._exos_promoter_list(p_token, en.list_id);
  IF en.arrived > 0 THEN
    RAISE EXCEPTION 'exos: this guest already arrived' USING ERRCODE = '23514';
  END IF;
  SELECT counts_toward_capacity INTO v_counts FROM public.exos_guest_lists WHERE id = en.list_id;
  IF v_counts THEN
    PERFORM public._exos_guest_capacity(en.event_id, -(1 + en.plus_ones));
  END IF;
  DELETE FROM public.exos_guest_list_entries WHERE id = en.id;
END $$;
REVOKE ALL ON FUNCTION public.exos_promoter_remove_guest(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exos_promoter_remove_guest(uuid, uuid) TO anon, authenticated, service_role;

-- B3. Door ------------------------------------------------------------------

-- Check in p_count people of a guest-list party (door roles). Partial
-- arrivals add up; never more than 1 + plus_ones. A repeated client_ref
-- (offline replay) returns the earlier result instead of counting twice.
CREATE OR REPLACE FUNCTION public.exos_guest_check_in(
  p_entry_id uuid, p_count integer, p_event_id uuid, p_client_ref uuid DEFAULT NULL,
  p_source text DEFAULT 'online')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  en      public.exos_guest_list_entries%ROWTYPE;
  v_left  int;
  v_open  timestamptz;
  v_test  boolean;
  v_evst  text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_guest_check_in: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO en FROM public.exos_guest_list_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not-found');
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(en.org_id, ARRAY['owner', 'manager', 'scanner'])) THEN
    RAISE EXCEPTION 'exos_guest_check_in: not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_event_id IS NULL OR en.event_id <> p_event_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'wrong-event');
  END IF;
  IF p_client_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.exos_guest_list_checkins WHERE client_ref = p_client_ref) THEN
    RETURN jsonb_build_object('ok', true, 'reason', 'duplicate', 'arrived', en.arrived, 'party', en.plus_ones + 1);
  END IF;
  SELECT e.status, coalesce(e.doors_at, e.starts_at),
         (coalesce(e.checkin_test_mode, false) AND e.checkin_test_until IS NOT NULL AND now() < e.checkin_test_until)
    INTO v_evst, v_open, v_test
    FROM public.exos_events e WHERE e.id = en.event_id;
  IF v_evst = 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'event-cancelled');
  END IF;
  IF v_open IS NOT NULL AND now() < v_open THEN
    IF v_test THEN
      RETURN jsonb_build_object('ok', true, 'reason', 'test-scan', 'test', true,
                                'arrived', en.arrived, 'party', en.plus_ones + 1);
    END IF;
    RETURN jsonb_build_object('ok', false, 'reason', 'doors-not-open', 'opens_at', v_open);
  END IF;
  v_left := en.plus_ones + 1 - en.arrived;
  IF coalesce(p_count, 0) < 1 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad-count');
  END IF;
  IF p_count > v_left THEN
    RETURN jsonb_build_object('ok', false, 'reason', CASE WHEN v_left = 0 THEN 'used' ELSE 'over' END,
                              'remaining', v_left, 'arrived', en.arrived, 'party', en.plus_ones + 1);
  END IF;
  UPDATE public.exos_guest_list_entries
     SET arrived = arrived + p_count, arrived_at = coalesce(arrived_at, now())
   WHERE id = en.id;
  INSERT INTO public.exos_guest_list_checkins (entry_id, event_id, org_id, count, client_ref, source, scanned_by)
  VALUES (en.id, en.event_id, en.org_id, p_count, p_client_ref,
          CASE WHEN p_source = 'offline-sync' THEN 'offline-sync' ELSE 'online' END, auth.uid());
  RETURN jsonb_build_object('ok', true, 'reason', 'checked-in',
                            'arrived', en.arrived + p_count, 'party', en.plus_ones + 1);
END $$;
REVOKE ALL ON FUNCTION public.exos_guest_check_in(uuid, integer, uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_guest_check_in(uuid, integer, uuid, uuid, text) TO authenticated, service_role;

-- The door's offline download (owner / manager / scanner): table labels for
-- ticket ids, every list with its counts, every guest (names only — no
-- email / phone for the door).
CREATE OR REPLACE FUNCTION public.exos_event_door_extras(p_event_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_event_door_extras: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR NOT (public.exos_is_admin()
                           OR public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'scanner'])) THEN
    RAISE EXCEPTION 'exos_event_door_extras: not authorized for this event' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object(
    'tables', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'booking_id', b.id, 'label', b.label, 'tier_name', t.name,
               'section_label', t.section_label, 'party_size', b.party_size,
               'min_spend_cents', t.min_spend_cents, 'ticket_ids', to_jsonb(b.ticket_ids))
             ORDER BY b.label NULLS LAST, b.created_at)
        FROM public.exos_table_bookings b
        LEFT JOIN public.exos_ticket_tiers t ON t.id = b.tier_id
       WHERE b.event_id = p_event_id AND b.status = 'active'), '[]'::jsonb),
    'lists', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', l.id, 'name', l.name, 'cap', l.cap, 'status', l.status,
               'promoter', p.name) ORDER BY l.name)
        FROM public.exos_guest_lists l
        LEFT JOIN public.exos_promoters p ON p.id = l.promoter_id
       WHERE l.event_id = p_event_id), '[]'::jsonb),
    'guests', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', g.id, 'list_id', g.list_id, 'guest_name', g.guest_name,
               'plus_ones', g.plus_ones, 'arrived', g.arrived, 'arrived_at', g.arrived_at,
               'note', g.note) ORDER BY g.guest_name)
        FROM public.exos_guest_list_entries g
       WHERE g.event_id = p_event_id), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.exos_event_door_extras(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_event_door_extras(uuid) TO authenticated, service_role;

-- ROLLBACK (manual): re-create the seven patched functions from their source
-- migrations; DROP the new functions, triggers and tables; DROP the four tier
-- columns (after converting any table tiers back).
