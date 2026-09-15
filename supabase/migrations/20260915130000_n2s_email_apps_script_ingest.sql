-- ============================================================================
-- Migration 20260915130000 — N2S: Gmail label → Supabase ingest path
--
-- Lane:     D7 (N2S obligation-covering, PROJECT_BIBLE §2.3) over A1's ingest
--           plane; companion file scripts/apps_script/n2s_email_sync.gs
-- Touches:  n2s_items (ADD COLUMN email_thread_id, email_label; new unique
--           partial index), n2s_email_items_id_seq (NEW), get_app_secret()
--           allowlist (+APPSCRIPT_N2S_INGEST_SECRET),
--           n2s_items_ingest_from_apps_script() (NEW RPC)
-- Pre-reqs: 20260910030000 (n2s_items), 20260910040000 (n2s_order_key),
--           20260910350000 (current get_app_secret allowlist)
--
-- ── What problem this closes ────────────────────────────────────────────────
-- `n2s_pull_items()` (20260910030000) is Stage 1 of the D7 pipeline
-- (docs/d7_n2s_pipeline.md §1) but it has exactly one source: the CRM's
-- `/api/v1/n2s/items` feed. Some "needs a substitute" notices only ever
-- arrive as an email (ops labels the thread by hand today and works it
-- manually) — those orders never reach `n2s_items` and are therefore
-- invisible to every downstream stage (map/poll/match/queue/surface), the
-- same "invisible obligation" gap 20260910030000 already documented for the
-- CRM's own blind spots (Vivid/TickPick/GoTickets/SeatGeek/EVO order books).
--
-- This migration adds a SECOND Stage-1 ingest path, keyed on a Gmail label
-- instead of a CRM poll. `scripts/apps_script/n2s_email_sync.gs` (companion
-- file, run from a Gmail-bound Apps Script project — TickPick's egress-IP
-- problem, 20260515120000, does not apply here, but Apps Script is still the
-- only thing with read access to the mailbox) searches Gmail for one or more
-- operator-configured labels, extracts what the email states about the
-- order, removes the trigger label once the row is safely in Supabase (so
-- the same thread is never re-sent), and applies a "synced" label instead.
--
-- ── Landing an email-sourced row IS the tag ────────────────────────────────
-- "Tag the order" does not mean writing a flag onto `s4kcs_orders` or any
-- other marketplace order table — those are single-writer (PROJECT_BIBLE
-- §2.4) and owned by A1's ingest, and nothing downstream needs a flag there.
-- `n2s_items` **is** the tag: a row in it means "this order needs a sub",
-- which is exactly what the CRM path already means by inserting one. Once
-- the row lands here every existing D7 stage picks it up unchanged and with
-- no new code: `n2s_map_events()` resolves it to a `tevo_event_id` the same
-- way it resolves a CRM-sourced row (rule 0 / 0b-0e key off
-- `n2s_order_key`/`order_number` against the marketplace order books, which
-- this migration does not touch), cron 598 polls its sources the tick it
-- maps, cron 602 matches/queues/publishes it every minute after that. "Add
-- to the queue, poll as regular, update on every source refresh" is the
-- existing six-stage loop (docs/d7_n2s_pipeline.md §1/§3) — nothing here
-- reimplements it.
--
-- ── The PK-collision problem, and why a sequence in a high namespace ──────
-- `n2s_items.n2s_id` is the CRM's own bigint item id (433 items as of
-- 2026-09-09, ids in the low hundreds/thousands). An email-sourced row has
-- no CRM id, and this pipeline runs unattended — a random/derived id built
-- from a Gmail message id risks eventually colliding with a real future CRM
-- id (PROJECT_BIBLE §0's #1 recurring bug shape: two source id spaces do not
-- align). `n2s_email_items_id_seq` starts at 900,000,000,000, far above any
-- plausible CRM item count, so the two id spaces can never collide by
-- construction rather than by convention. Idempotency does not depend on the
-- id anyway — re-sending the same Gmail thread upserts on `email_thread_id`,
-- a unique partial index that leaves the CRM path's own `n2s_id` PK
-- untouched (`ON CONFLICT (n2s_id)` in 20260910030000's drain still works
-- unmodified).
--
-- ── RULE 2 ──────────────────────────────────────────────────────────────
-- No upstream marketplace or ticket API is touched by this migration or its
-- companion script. Gmail is not a listing source; nothing here creates an
-- order, hold, or price. The one outbound call the Apps Script makes is a
-- POST to our own Supabase project, gated by a shared secret the same way
-- 20260515120000 gates the TickPick Apps Script ingest.
-- ============================================================================

-- ── 1. Where an email-sourced row is keyed ─────────────────────────────────
ALTER TABLE public.n2s_items
  ADD COLUMN IF NOT EXISTS email_thread_id text,
  ADD COLUMN IF NOT EXISTS email_label     text;

CREATE UNIQUE INDEX IF NOT EXISTS n2s_items_email_thread_idx
  ON public.n2s_items (email_thread_id) WHERE email_thread_id IS NOT NULL;

COMMENT ON COLUMN public.n2s_items.email_thread_id IS
  'Gmail thread id for a row ingested via n2s_items_ingest_from_apps_script '
  '(NULL for CRM-sourced rows). Unique where set — the upsert key for the '
  'email path, independent of n2s_id.';

COMMENT ON COLUMN public.n2s_items.email_label IS
  'The Gmail label that triggered ingest (e.g. "N2S/Vivid"). Diagnostic only '
  '— marketplace normalization happens once, in the ingest RPC, not read '
  'from this column downstream.';

-- ── 2. A synthetic id namespace that can never collide with a real CRM id ──
CREATE SEQUENCE IF NOT EXISTS public.n2s_email_items_id_seq
  START WITH 900000000000 INCREMENT BY 1;

-- ── 3. Extend get_app_secret — additive only, every existing name retained ─
-- Same control as every prior extension of this allowlist (20260910350000
-- immediately precedes this one): the current_user assert is untouched, one
-- name is appended, nothing removed or relaxed.
CREATE OR REPLACE FUNCTION public.get_app_secret(p_name text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'vault'
AS $function$
DECLARE v_value text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'get_app_secret: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;
  IF p_name NOT IN (
    'SEATDATA_API_KEY','TEVO_API_TOKEN','TEVO_SECRET','SEATGEEK_API_TOKEN',
    'TICKPICK_API_TOKEN','VIVID_API_TOKEN','APPSCRIPT_INGEST_SECRET',
    'TICKETSDATA_USERNAME','TICKETSDATA_PASSWORD','TWITTERAPI_IO_KEY',
    'WA_GATEWAY_URL','WA_GATEWAY_KEY',
    'crm.s4kcs.com',
    'crm.s4kcs.com/n2s',
    'TICKETSDATA_N2S_USERNAME','TICKETSDATA_N2S_PASSWORD',
    'N2S_COVER_WEBHOOK_URL','N2S_COVER_WEBHOOK_TOKEN',
    -- Shared secret checked inside n2s_items_ingest_from_apps_script(). Gates
    -- the Gmail-label ingest RPC the same way APPSCRIPT_INGEST_SECRET gates
    -- the TickPick Apps Script path (20260515120000). Not a marketplace
    -- credential — the operator's own Apps Script project holds the other
    -- half. See 20260915130000.
    'APPSCRIPT_N2S_INGEST_SECRET'
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $function$;

-- ── 4. The ingest RPC ───────────────────────────────────────────────────────
-- Apps Script POSTs an array of {email_thread_id, order_number, marketplace,
-- event_name, venue, event_dt, section, row, seats, qty, price_per_ticket,
-- grand_total, notes}; every field but email_thread_id/order_number is
-- best-effort (email templates vary and the script may not find them all —
-- see the .gs file). Same shape of function as
-- tickpick_orders_ingest_from_apps_script (20260515120000): SECURITY
-- DEFINER, anon-callable, gated entirely by the shared secret.
CREATE OR REPLACE FUNCTION public.n2s_items_ingest_from_apps_script(
  p_items         jsonb,
  p_shared_secret text
)
RETURNS TABLE(inserted integer, updated integer, skipped integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_temp'
AS $$
DECLARE
  v_expected_secret text;
  v_total            int;
  v_inserted         int := 0;
  v_updated          int := 0;
  v_skipped          int := 0;
BEGIN
  v_expected_secret := public.get_app_secret('APPSCRIPT_N2S_INGEST_SECRET');
  IF v_expected_secret IS NULL OR v_expected_secret = '' THEN
    RAISE EXCEPTION 'APPSCRIPT_N2S_INGEST_SECRET unset in vault' USING ERRCODE = '42501';
  END IF;
  IF p_shared_secret IS NULL OR p_shared_secret <> v_expected_secret THEN
    RAISE EXCEPTION 'unauthorized: shared secret mismatch' USING ERRCODE = '42501';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'p_items must be a JSON array' USING ERRCODE = '22P02';
  END IF;

  v_total := jsonb_array_length(p_items);
  IF v_total = 0 THEN
    RETURN QUERY SELECT 0, 0, 0;
    RETURN;
  END IF;

  WITH src AS (
    SELECT o FROM jsonb_array_elements(p_items) AS o
  ),
  norm AS (
    -- Marketplace spelling normalised to the same strings the CRM drain
    -- writes (v_sub_orders.source) so n2s_order_key's EVO split and every
    -- downstream marketplace comparison see one vocabulary regardless of
    -- ingest path. Case-insensitive: a Gmail label or subject line will not
    -- reliably match the CRM feed's exact casing.
    SELECT
      o,
      CASE lower(btrim(COALESCE(o->>'marketplace', '')))
        WHEN 'stubhub'           THEN 'StubHub'
        WHEN 'stubhub 2.0'       THEN 'StubHub'
        WHEN 'gotickets'         THEN 'GoTickets'
        WHEN 'go tickets'        THEN 'GoTickets'
        WHEN 'ticket evolution'  THEN 'EVO'
        WHEN 'ticketevolution'   THEN 'EVO'
        WHEN 'evo'               THEN 'EVO'
        WHEN 'vivid'             THEN 'Vivid Seats'
        WHEN 'vividseats'        THEN 'Vivid Seats'
        WHEN 'vivid seats'       THEN 'Vivid Seats'
        WHEN 'tickpick'          THEN 'TickPick'
        WHEN 'seatgeek'          THEN 'SeatGeek'
        WHEN 'gametime'          THEN 'Gametime'
        ELSE NULLIF(btrim(o->>'marketplace'), '')
      END AS s4k_source
    FROM src
  ),
  upserted AS (
    INSERT INTO public.n2s_items AS t (
      n2s_id, order_number, marketplace, s4k_source, status, status_label,
      is_terminal, item_source, event_name, venue, event_dt,
      section, "row", seats, qty, price_per_ticket, grand_total,
      email_thread_id, email_label, pulled_at, last_seen_at, raw
    )
    SELECT
      nextval('public.n2s_email_items_id_seq'),
      o->>'order_number',
      o->>'marketplace',              -- verbatim, as the email/label spelled it
      s4k_source,                     -- normalised, per above
      'n2s',
      'Needs Sub (email)',
      false,                          -- email carries no terminal-status signal
      'email_apps_script',
      o->>'event_name',
      o->>'venue',
      NULLIF(o->>'event_dt','')::timestamp,   -- LOCAL wall clock, no zone (§3)
      o->>'section',
      o->>'row',
      o->>'seats',
      NULLIF(o->>'qty','')::integer,
      NULLIF(o->>'price_per_ticket','')::numeric,
      NULLIF(o->>'grand_total','')::numeric,
      o->>'email_thread_id',
      o->>'email_label',
      now(), now(), o
    FROM norm
    WHERE COALESCE(o->>'email_thread_id','') <> ''
      AND COALESCE(o->>'order_number','')    <> ''
    ON CONFLICT (email_thread_id) WHERE email_thread_id IS NOT NULL DO UPDATE SET
      order_number     = EXCLUDED.order_number,
      marketplace      = EXCLUDED.marketplace,
      s4k_source       = EXCLUDED.s4k_source,
      event_name       = EXCLUDED.event_name,
      venue            = EXCLUDED.venue,
      event_dt         = EXCLUDED.event_dt,
      section          = EXCLUDED.section,
      "row"            = EXCLUDED."row",
      seats            = EXCLUDED.seats,
      qty              = EXCLUDED.qty,
      price_per_ticket = EXCLUDED.price_per_ticket,
      grand_total      = EXCLUDED.grand_total,
      email_label      = EXCLUDED.email_label,
      last_seen_at     = now(),
      raw              = EXCLUDED.raw
    RETURNING (xmax = 0) AS is_new
  )
  SELECT
    count(*) FILTER (WHERE is_new)     ::int,
    count(*) FILTER (WHERE NOT is_new) ::int
  INTO v_inserted, v_updated
  FROM upserted;

  v_skipped := v_total - v_inserted - v_updated;

  RETURN QUERY SELECT v_inserted, v_updated, v_skipped;
END;
$$;

REVOKE ALL ON FUNCTION public.n2s_items_ingest_from_apps_script(jsonb, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.n2s_items_ingest_from_apps_script(jsonb, text) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.n2s_items_ingest_from_apps_script(jsonb, text) IS
  'Apps Script → Supabase ingest path for Gmail-label-sourced N2S obligations '
  '(scripts/apps_script/n2s_email_sync.gs). Anon-callable but gated by vault '
  'secret APPSCRIPT_N2S_INGEST_SECRET (must be passed as p_shared_secret). '
  'UPSERTs the JSONB array into n2s_items keyed on email_thread_id, with a '
  'synthetic n2s_id from n2s_email_items_id_seq (900,000,000,000+) so it can '
  'never collide with a real CRM item id. Returns (inserted, updated, '
  'skipped). Landing a row here is itself the "tag" — n2s_map_events() and '
  'the rest of the six-stage D7 pipeline treat it identically to a '
  'CRM-sourced row; see docs/d7_n2s_pipeline.md.';
