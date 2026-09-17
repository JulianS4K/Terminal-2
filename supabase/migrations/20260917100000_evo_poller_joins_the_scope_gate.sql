-- The EVO listings poller never got the scope gate the GoTickets one has.
--
-- Migs 20260917003300 / 20260917003814 (another session) introduced the policy and the view:
--
--     listings_poll_scope_enabled()      -- a flip-to-widen toggle, currently ON
--     v_listings_poll_scope_events       -- events we hold a position in:
--                                        -- CRM / N2S / SeatGeek orders / GoTickets purchases
--
-- gt_listings_poll_tick reads both. evo_listings_poll_tick does not — it still rotates over every
-- future non-ignored event, which is why the EVO deals leg starved: 3,916 events could produce a
-- deal but only 30 were freshly polled in any 30-minute window, and an addressable event was
-- revisited on average every 38.3 HOURS. The retire tick marks a deal 'stale' long before that,
-- so the feed drained from 1,228 EVO rows on 09-11 to 37 by 09-16 and could not refill.
--
-- This adds the SAME predicate to the EVO side rather than inventing a second scope list. One
-- policy, one view, two pollers: widening later is still a single flip of the policy row.
--
-- Scope in the poll window is 2,744 events against the ~39k EVO was sweeping — a ~14x cut, which
-- turns a 38-hour revisit into minutes.
DO $do$
DECLARE
  v_src text; v_args text; v_cfg text[]; v_set text := ''; v_kv text; v_a text;
BEGIN
  SELECT p.prosrc, pg_get_function_arguments(p.oid), p.proconfig INTO v_src, v_args, v_cfg
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'evo_listings_poll_tick';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'evo_listings_poll_tick not found';
  END IF;
  IF position('listings_poll_scope_enabled' in v_src) > 0 THEN
    RETURN;   -- already gated (possibly by the session that built the policy) — leave it alone
  END IF;

  -- Carry the function's existing SET clauses across verbatim rather than retyping search_path.
  FOREACH v_kv IN ARRAY coalesce(v_cfg, ARRAY[]::text[]) LOOP
    v_set := v_set || format(' SET %I TO %s', split_part(v_kv, '=', 1),
                             substr(v_kv, strpos(v_kv, '=') + 1));
  END LOOP;

  v_a := E'        AND coalesce(e.state, ''shown'') <> ''ignored''\n    ),';
  IF (length(v_src) - length(replace(v_src, v_a, ''))) / length(v_a) <> 1 THEN
    RAISE EXCEPTION 'evo candidate-filter anchor did not match exactly once';
  END IF;

  v_src := replace(v_src, v_a,
    E'        AND coalesce(e.state, ''shown'') <> ''ignored''\n'
    '        -- SCOPE GATE (migs 20260917003300/003814, joined here by 20260917100000): while the\n'
    '        -- policy is enabled, only events we hold a position in (CRM / N2S / SG orders /\n'
    '        -- GT purchases). Same predicate gt_listings_poll_tick uses. Flip the policy to widen.\n'
    '        AND (NOT public.listings_poll_scope_enabled()\n'
    '             OR e.id IN (SELECT tevo_event_id FROM public.v_listings_poll_scope_events))\n'
    '    ),');

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION public.evo_listings_poll_tick(%s) RETURNS integer '
    'LANGUAGE plpgsql SECURITY DEFINER%s AS %s',
    v_args, v_set, quote_literal(v_src));
END
$do$;
