-- Migration 20261009180000 · level:secondary-sales · lane:D7 · writes:n2s_items,n2b_ingest_from_apps_script,n2s_pull_all_sources,n2s_covers · reads:n2s_items,vault(APPSCRIPT_INGEST_SECRET) · pre:20261006193000
--
-- ============================================================================
-- N2B ("Need to Buy"): peddled sales from Gmail ride the N2S pipeline, with
-- no timer and a 4-hour re-price.
--
-- WHAT: every "PEDDLING SALE RECEIVED" email (orders@s4kent.com) that carries
-- the Gmail label Need2Buy/WaitToBuy is a ticket we sold and still have to
-- buy. The Apps Script scripts/apps_script/n2b_sync.gs (runs inside that
-- mailbox) parses each labelled thread and sends the whole labelled set here
-- every few minutes. Each one becomes an n2s_items row so the existing
-- machinery maps the event, pulls TEvo / GoTickets / SeatGeek, and finds a
-- cover exactly as for an N2S order — with these differences (operator,
-- 2026-10-09: "no timer, ping the respective event every 4 hours"):
--
--   * status 'n2b', item_source 'gmail', n2s_id = -(our order number) so it
--     can never collide with a CRM id (CRM ids are positive). alert_at and
--     the timer stay NULL, which n2s_timer_open() already reads as "open" —
--     the row stays live until it is closed, not for 10 minutes.
--   * n2s_pull_all_sources re-pulls an N2B row's event every 4 hours instead
--     of every 2 minutes, and sweeps N2S rows first so a backlog of N2B rows
--     never delays a timed N2S order. (An event an N2S order is also on is
--     refreshed by that order anyway; the N2B row just reads the fresh pull.)
--   * n2s_covers allocates listings to N2S orders before N2B ones: an N2S
--     buyer is waiting on a 15-minute clock, an N2B one is not.
--
-- LIFECYCLE (all inside n2b_ingest_from_apps_script):
--   * label present           -> 'n2b' (open; reopened if it had been closed)
--   * script flags cancelled  -> 'n2b_cancelled', terminal (sticky)
--   * label removed: absent from a full sync and not seen for 30 minutes
--                             -> 'n2b_closed', terminal, fail_reason 'label removed'
--   * event more than a day past -> 'n2b_closed', fail_reason 'event passed'
-- CRM rows (item_source <> 'gmail') are never touched by this function.
--
-- AUTH: same pattern as tickpick_orders_ingest_from_apps_script — callable
-- with the anon key (Apps Script has no service role), gated on the vault
-- secret APPSCRIPT_INGEST_SECRET (already set; shared with the TickPick sync).
-- Writes our own table only; nothing upstream is called from here.
-- ============================================================================

-- 1. intake ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.n2b_ingest_from_apps_script(
  p_items jsonb, p_shared_secret text, p_full_sync boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_expected text := public.get_app_secret('APPSCRIPT_INGEST_SECRET');
  v_ids bigint[];
  v_new int := 0; v_upd int := 0; v_closed int := 0; v_total int;
BEGIN
  IF v_expected IS NULL OR v_expected = '' THEN
    RAISE EXCEPTION 'APPSCRIPT_INGEST_SECRET unset in vault' USING ERRCODE = '42501';
  END IF;
  IF p_shared_secret IS NULL OR p_shared_secret <> v_expected THEN
    RAISE EXCEPTION 'unauthorized: shared secret mismatch' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'p_items must be a JSON array' USING ERRCODE = '22P02';
  END IF;
  v_total := jsonb_array_length(p_items);
  IF v_total > 2000 THEN
    RAISE EXCEPTION 'p_items too large (% > 2000)', v_total USING ERRCODE = '22023';
  END IF;

  WITH src AS (
    SELECT it,
           -((it->>'pos_order')::bigint)                         AS nid,
           NULLIF(btrim(it->>'site'), '')                        AS site,
           NULLIF(btrim(it->>'site_order'), '')                  AS site_order,
           NULLIF(it->>'event_dt', '')::timestamp                AS event_dt,
           COALESCE((it->>'cancelled')::boolean, false)          AS cancelled
      FROM jsonb_array_elements(p_items) AS it
     WHERE it->>'pos_order' ~ '^[0-9]{1,15}$'
  ),
  s AS (
    SELECT src.*,
           CASE WHEN cancelled THEN 'n2b_cancelled'
                WHEN event_dt < (now() AT TIME ZONE 'America/New_York') - interval '1 day' THEN 'n2b_closed'
                ELSE 'n2b' END AS st
      FROM src
  ),
  up AS (
    INSERT INTO public.n2s_items AS t (
      n2s_id, order_number, marketplace, s4k_source,
      status, status_label, is_terminal, item_source, fail_reason,
      event_name, venue, event_dt, section, "row", seats, qty,
      price_per_ticket, grand_total, alert_at, timer_expires_at, timer_expired,
      resolved_at, n2s_created_at, n2s_updated_at, pulled_at, last_seen_at, raw)
    SELECT
      s.nid,
      -- the marketplace's order id; n2s_order_key is generated from it (EVO's
      -- <invoice>-<order> composite yields the order part), same as CRM rows
      COALESCE(s.site_order, s.it->>'pos_order'),
      s.site,
      CASE s.site WHEN 'Ticket Evolution' THEN 'EVO' WHEN 'Stubhub 2.0' THEN 'StubHub'
                  WHEN 'Go Tickets' THEN 'GoTickets' ELSE s.site END,
      s.st,
      CASE s.st WHEN 'n2b' THEN 'N2B' WHEN 'n2b_cancelled' THEN 'N2B cancelled' ELSE 'N2B closed' END,
      s.st <> 'n2b', 'gmail',
      CASE s.st WHEN 'n2b_cancelled' THEN 'cancelled' WHEN 'n2b_closed' THEN 'event passed' END,
      NULLIF(btrim(s.it->>'event_name'), ''), NULLIF(btrim(s.it->>'venue'), ''), s.event_dt,
      NULLIF(btrim(s.it->>'section'), ''), NULLIF(btrim(s.it->>'row'), ''),
      NULLIF(btrim(s.it->>'seats'), ''),
      NULLIF(s.it->>'qty', '')::integer,
      NULLIF(s.it->>'price_each', '')::numeric, NULLIF(s.it->>'total', '')::numeric,
      NULL, NULL, false,
      CASE WHEN s.st <> 'n2b' THEN now() END,
      COALESCE(NULLIF(s.it->>'sale_at', '')::timestamptz, now()), now(), now(), now(),
      s.it
    FROM s
    ON CONFLICT (n2s_id) DO UPDATE SET
      order_number   = EXCLUDED.order_number,
      marketplace    = EXCLUDED.marketplace,
      s4k_source     = EXCLUDED.s4k_source,
      -- cancelled is sticky; anything else follows the label
      status         = CASE WHEN t.status = 'n2b_cancelled' THEN t.status ELSE EXCLUDED.status END,
      status_label   = CASE WHEN t.status = 'n2b_cancelled' THEN t.status_label ELSE EXCLUDED.status_label END,
      is_terminal    = CASE WHEN t.status = 'n2b_cancelled' THEN true ELSE EXCLUDED.is_terminal END,
      fail_reason    = CASE WHEN t.status = 'n2b_cancelled' THEN t.fail_reason ELSE EXCLUDED.fail_reason END,
      resolved_at    = CASE WHEN t.status = 'n2b_cancelled' THEN t.resolved_at
                            WHEN EXCLUDED.status = 'n2b' THEN NULL
                            ELSE COALESCE(t.resolved_at, now()) END,
      event_name     = EXCLUDED.event_name,
      venue          = EXCLUDED.venue,
      event_dt       = EXCLUDED.event_dt,
      section        = EXCLUDED.section,
      "row"          = EXCLUDED."row",
      seats          = EXCLUDED.seats,
      qty            = EXCLUDED.qty,
      price_per_ticket = EXCLUDED.price_per_ticket,
      grand_total    = EXCLUDED.grand_total,
      -- an edited event invalidates the mapping; let the mappers redo it
      tevo_event_id  = CASE WHEN (t.event_name, t.venue, t.event_dt)
                                 IS DISTINCT FROM (EXCLUDED.event_name, EXCLUDED.venue, EXCLUDED.event_dt)
                            THEN NULL ELSE t.tevo_event_id END,
      mapped_via     = CASE WHEN (t.event_name, t.venue, t.event_dt)
                                 IS DISTINCT FROM (EXCLUDED.event_name, EXCLUDED.venue, EXCLUDED.event_dt)
                            THEN NULL ELSE t.mapped_via END,
      n2s_updated_at = now(),
      last_seen_at   = now(),
      raw            = EXCLUDED.raw
    WHERE t.item_source = 'gmail'
    RETURNING t.n2s_id, (xmax = 0) AS is_new
  )
  SELECT array_agg(n2s_id), count(*) FILTER (WHERE is_new), count(*) FILTER (WHERE NOT is_new)
    INTO v_ids, v_new, v_upd
    FROM up;

  -- label removed: only on a FULL sync (the script saw every labelled thread),
  -- and only after 30 minutes unseen, so one short or failed run closes nothing.
  IF p_full_sync THEN
    UPDATE public.n2s_items n
       SET status = 'n2b_closed', status_label = 'N2B closed', is_terminal = true,
           fail_reason = 'label removed', resolved_at = now(), n2s_updated_at = now()
     WHERE n.item_source = 'gmail' AND n.status = 'n2b'
       AND NOT (n.n2s_id = ANY(COALESCE(v_ids, ARRAY[]::bigint[])))
       AND n.last_seen_at < now() - interval '30 minutes';
    GET DIAGNOSTICS v_closed = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'received', v_total, 'inserted', COALESCE(v_new, 0), 'updated', COALESCE(v_upd, 0),
    'skipped', v_total - COALESCE(v_new, 0) - COALESCE(v_upd, 0), 'closed', v_closed,
    'open', (SELECT count(*) FROM public.n2s_items WHERE item_source = 'gmail' AND status = 'n2b'));
END;
$function$;

REVOKE ALL ON FUNCTION public.n2b_ingest_from_apps_script(jsonb, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.n2b_ingest_from_apps_script(jsonb, text, boolean) TO anon, service_role;

COMMENT ON FUNCTION public.n2b_ingest_from_apps_script(jsonb, text, boolean) IS
  'N2B intake from scripts/apps_script/n2b_sync.gs: Gmail "PEDDLING SALE RECEIVED" threads labelled Need2Buy/WaitToBuy become n2s_items rows (status n2b, item_source gmail, n2s_id = -order, no timer). Cancelled -> n2b_cancelled (sticky); absent from a full sync for 30 min -> n2b_closed. Secret-gated on APPSCRIPT_INGEST_SECRET (20261009180000).';

-- 2. pull cadence + allocation order --------------------------------------------
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  -- n2s_pull_all_sources: N2B events every 4 h, N2S rows swept first
  v_def := pg_get_functiondef('public.n2s_pull_all_sources(integer, interval, interval, boolean, integer)'::regprocedure);
  IF md5(v_def) <> '0c918445868f3cc0f9dacd30aa824662' THEN
    RAISE EXCEPTION 'n2s_pull_all_sources changed since this migration was written (md5 %)', md5(v_def);
  END IF;
  v_new := replace(v_def,
$a$       AND i.sources_pulled_at < now() - p_sweep_after
$a$,
$b$       -- mig 20261009180000: N2B (no timer) re-prices every 4 hours
       AND i.sources_pulled_at < now() - CASE WHEN i.status = 'n2b' THEN interval '4 hours'
                                              ELSE p_sweep_after END
$b$);
  v_new := replace(v_new,
$a$     ORDER BY i.sources_pulled_at ASC
     LIMIT p_max$a$,
$b$     ORDER BY (i.status = 'n2b'), i.sources_pulled_at ASC
     LIMIT p_max$b$);
  IF v_new NOT LIKE '%interval ''4 hours''%' OR v_new NOT LIKE '%ORDER BY (i.status = ''n2b''), i.sources_pulled_at ASC%' THEN
    RAISE EXCEPTION 'n2s_pull_all_sources: anchors not found';
  END IF;
  EXECUTE v_new;

  -- n2s_covers: N2S orders claim listings before N2B ones
  v_def := pg_get_functiondef('public.n2s_covers(bigint[], interval, integer, text[])'::regprocedure);
  IF md5(v_def) <> '2db759fe6ceb7404e2af924fa01b4381' THEN
    RAISE EXCEPTION 'n2s_covers changed since this migration was written (md5 %)', md5(v_def);
  END IF;
  v_new := replace(v_def,
$a$     ORDER BY c.cover_gate, c.cover_cost, c.n2s_id, c.sub_source, c.sub_listing_id$a$,
$b$     ORDER BY (c.n2s_status = 'n2b'), c.cover_gate, c.cover_cost, c.n2s_id, c.sub_source, c.sub_listing_id$b$);
  IF v_new = v_def THEN RAISE EXCEPTION 'n2s_covers: anchor not found'; END IF;
  EXECUTE v_new;
END $mig$;

-- rollback:
--   re-create n2s_pull_all_sources without the 'mig 20261009180000' CASE and with
--   ORDER BY i.sources_pulled_at ASC; re-create n2s_covers without the leading
--   (c.n2s_status = 'n2b') sort key; DROP FUNCTION
--   public.n2b_ingest_from_apps_script(jsonb, text, boolean); then
--   UPDATE n2s_items SET is_terminal = true WHERE item_source = 'gmail' (or DELETE them).
