-- Migration 20261027160000 · level:secondary-sales · lane:D7 · writes:gmail_relay_msgs,gmail_relay_book,gmail_relay_actions,gmail_relay_sync,gmail_relay_parse_sale · reads:n2s_items,vault(APPSCRIPT_INGEST_SECRET) · pre:20261009180000
--
-- ============================================================================
-- Gmail relay, phase 1: N2B / PED decisions move from Apps Script to Supabase.
-- ============================================================================
--
-- WHY (operator 2026-10-27: "transfer computing to supa but keep simple one off
-- tasks in scripts"). The orders mailbox hit Apps Script's daily GmailApp quota
-- ("Service invoked too many times for one day: premium gmail") because two
-- scripts re-read every Need2Buy thread every 5-10 minutes. Now the script
-- (S4K_GmailRelay.gs, s4k-terminal2) only relays: it lists ids through the
-- Gmail API advanced service, sends each new email here ONCE, and applies the
-- label changes this function hands back. Every decision is made here.
--
-- ONE RPC: gmail_relay_sync(p_secret, p_payload) -> jsonb. Each call:
--   1. stores new messages (parsed: sale / step / cancel),
--   2. records acks for label actions the script applied,
--   3. replaces the Need2Buy book (thread ids currently carrying the label),
--   4. feeds the book to n2b_ingest_from_apps_script (same N2B rows as before),
--   5. queues label actions:
--        bought        a book sale whose Order # + Site Order # has a
--                      "[SUCCESS] [Step 2-8/x]" email: add bought, drop the
--                      need2Buy + triage labels, mark read (+ the email read).
--                      Operator: Step 2+ success = invoiced out = bought.
--        event-passed  a book sale whose event is 24h+ past: drop the labels.
--   6. answers with what it still needs: message ids it has not seen
--      (want_msgs), book threads it has no sale email for (want_threads), and
--      Gmail searches for Step 2+ emails of unconfirmed open sales (searches).
-- The script loops until nothing is wanted. Payload/response shapes are in the
-- COMMENT on gmail_relay_sync.
--
-- Read-only on every marketplace API. Gmail is changed only by the script,
-- only with the actions listed above.
-- ============================================================================

-- 1. storage -----------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.gmail_relay_msgs (
  msg_id       text PRIMARY KEY,
  thread_id    text NOT NULL,
  internal_at  timestamptz,
  subject      text,
  body         text,
  labels       text[] NOT NULL DEFAULT '{}',
  kind         text NOT NULL,          -- sale | step | cancel | other
  order_no     bigint,
  site_order   text,
  step         int,
  sale         jsonb,                  -- parsed sale (kind = sale)
  received_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS gmail_relay_msgs_thread_idx ON public.gmail_relay_msgs (thread_id);
CREATE INDEX IF NOT EXISTS gmail_relay_msgs_order_idx  ON public.gmail_relay_msgs (order_no, kind);

CREATE TABLE IF NOT EXISTS public.gmail_relay_book (
  thread_id          text PRIMARY KEY,
  cancelled          boolean NOT NULL DEFAULT false,
  seen_at            timestamptz NOT NULL DEFAULT now(),
  confirm_checked_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.gmail_relay_actions (
  id          bigserial PRIMARY KEY,
  thread_id   text NOT NULL,
  reason      text NOT NULL,           -- bought | confirm-read | event-passed
  order_no    bigint,
  add_labels  text[] NOT NULL DEFAULT '{}',
  rm_labels   text[] NOT NULL DEFAULT '{}',
  mark_read   boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  sent_at     timestamptz,
  done_at     timestamptz,
  error       text
);
-- one open action per thread + reason
CREATE UNIQUE INDEX IF NOT EXISTS gmail_relay_actions_open_uq
  ON public.gmail_relay_actions (thread_id, reason) WHERE done_at IS NULL;

ALTER TABLE public.gmail_relay_msgs    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gmail_relay_book    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gmail_relay_actions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.gmail_relay_msgs, public.gmail_relay_book, public.gmail_relay_actions
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.gmail_relay_actions_id_seq FROM PUBLIC, anon, authenticated;

-- 2. sale parser (same fields and patterns as n2b_sync.gs n2bParseBody_) -------

CREATE OR REPLACE FUNCTION public.gmail_relay_parse_sale(p_subject text, p_body text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  t   text := regexp_replace(regexp_replace(coalesce(p_body, ''), '[|\t\r\n]+', ' ', 'g'), '\s+', ' ', 'g');
  pos text;
  ed  text;
  ev  text;
BEGIN
  pos := substring(t from 'Order #\s*(\d+)');
  IF pos IS NULL THEN pos := substring(coalesce(p_subject, '') from 'RECEIVED\s+(\d+)'); END IF;
  IF pos IS NULL THEN RETURN NULL; END IF;
  ed := substring(t from 'Event Date\s+(\d{1,2}/\d{1,2}/\d{4}\s+\d{1,2}:\d{2}\s*[AP]M)');
  ev := substring(t from ' Event\s+(?!Date\y)(.+?)\s+Venue\s');
  IF ev IS NULL THEN ev := substring(coalesce(p_subject, '') from '\|\s*(.+?)/[0-9a-fA-F-]{36}\s*$'); END IF;
  RETURN jsonb_build_object(
    'pos_order',  pos,
    'site',       coalesce(btrim(substring(t from ' Site\s+(.+?)\s+Site Order #')), ''),
    'site_order', coalesce(substring(t from 'Site Order #\s*(\S+)'), ''),
    'event_name', coalesce(btrim(ev), ''),
    'event_dt',   coalesce(to_char(to_timestamp(ed, 'MM/DD/YYYY HH12:MI AM'), 'YYYY-MM-DD"T"HH24:MI:SS'), ''),
    'venue',      coalesce(btrim(substring(t from ' Venue\s+(.+?)\s+Section\s')), ''),
    'section',    coalesce(btrim(substring(t from ' Section\s+(.+?)\s+Row\s')), ''),
    'row',        coalesce(btrim(substring(t from ' Row\s+(.+?)\s+Seats\s')), ''),
    'seats',      coalesce(btrim(substring(t from ' Seats\s+(.*?)\s*Qty\s')), ''),
    'qty',        coalesce(substring(t from ' Qty\s+(\d+)'), ''),
    'price_each', coalesce(replace(substring(t from 'Price Per\s+\$?([\d,]+(?:\.\d+)?)'), ',', ''), ''),
    'total',      coalesce(replace(substring(t from ' Total\s+\$?([\d,]+(?:\.\d+)?)'), ',', ''), ''));
END;
$function$;

-- 3. the sync RPC ---------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.gmail_relay_sync(p_secret text, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_expected  text := public.get_app_secret('APPSCRIPT_INGEST_SECRET');
  -- need2Buy labels (any of them puts a sale in the book) and triage labels;
  -- both are dropped together, as the lifecycle script's markBoughtV3_ did.
  c_drop      text[] := ARRAY['Need2Buy/WaitToBuy', 'need2Buy', 'A_Today', 'A_Tomorrow', 'A_Soon'];
  v_has_book  boolean := jsonb_typeof(p_payload->'book') = 'array';
  v_complete  boolean := coalesce((p_payload->>'book_complete')::boolean, false);
  v_want_thr  text[];
  v_want_msg  text[];
  v_items     jsonb;
  v_n2b       jsonb;
  v_searches  jsonb := '[]'::jsonb;
  v_actions   jsonb;
  v_stored    int := 0;
BEGIN
  IF v_expected IS NULL OR v_expected = '' THEN
    RAISE EXCEPTION 'APPSCRIPT_INGEST_SECRET unset in vault' USING ERRCODE = '42501';
  END IF;
  IF p_secret IS NULL OR p_secret <> v_expected THEN
    RAISE EXCEPTION 'unauthorized: shared secret mismatch' USING ERRCODE = '42501';
  END IF;
  IF jsonb_array_length(coalesce(p_payload->'messages', '[]')) > 500 THEN
    RAISE EXCEPTION 'too many messages in one call (max 500)' USING ERRCODE = '22023';
  END IF;

  -- 1. store new messages, classified once
  WITH m AS (
    -- DISTINCT ON: a message can arrive twice in one call (asked for by id and
    -- again as part of a thread)
    SELECT DISTINCT ON (x->>'id') x->>'id' AS id, x->>'thread_id' AS tid,
           to_timestamp(nullif(x->>'internal_ms', '')::bigint / 1000.0) AS at,
           coalesce(x->>'subject', '') AS subj, left(coalesce(x->>'body', ''), 20000) AS body,
           coalesce(ARRAY(SELECT jsonb_array_elements_text(x->'labels')), '{}') AS labels
      FROM jsonb_array_elements(coalesce(p_payload->'messages', '[]')) x
     WHERE x->>'id' IS NOT NULL AND x->>'thread_id' IS NOT NULL
  ), c AS (
    SELECT m.*,
           CASE WHEN subj ~* 'PEDDLING SALE RECEIVED' AND subj !~* 'cancel' THEN 'sale'
                WHEN subj ~* '\[SUCCESS\]\s*\[Step [2-8]/\d+\]'             THEN 'step'
                WHEN subj ~* 'cancel'                                       THEN 'cancel'
                ELSE 'other' END AS kind
      FROM m
  )
  INSERT INTO public.gmail_relay_msgs AS g
         (msg_id, thread_id, internal_at, subject, body, labels, kind, order_no, site_order, step, sale)
  SELECT id, tid, at, subj, body, labels, kind,
         CASE kind
           WHEN 'sale' THEN nullif(public.gmail_relay_parse_sale(subj, body)->>'pos_order', '')::bigint
           WHEN 'step' THEN substring(subj from 'Order #(\d+)')::bigint
           ELSE substring(subj from '(?:RECEIVED|Order #)\s*(\d+)')::bigint END,
         CASE kind
           WHEN 'sale' THEN nullif(public.gmail_relay_parse_sale(subj, body)->>'site_order', '')
           WHEN 'step' THEN substring(body from 'Site Order#:\s*([A-Za-z0-9\-]+)') END,
         CASE WHEN kind = 'step' THEN substring(subj from '\[Step ([2-8])/')::int END,
         CASE WHEN kind = 'sale' THEN public.gmail_relay_parse_sale(subj, body) END
    FROM c
  ON CONFLICT (msg_id) DO UPDATE SET labels = EXCLUDED.labels;
  GET DIAGNOSTICS v_stored = ROW_COUNT;

  -- 2. acks for applied label actions
  UPDATE public.gmail_relay_actions a
     SET done_at = CASE WHEN coalesce((k->>'ok')::boolean, false) THEN now() END,
         -- a failed action keeps its sent_at, so it is retried 5 minutes on
         error   = CASE WHEN coalesce((k->>'ok')::boolean, false) THEN NULL ELSE left(k->>'error', 500) END
    FROM jsonb_array_elements(coalesce(p_payload->'acks', '[]')) k
   WHERE a.id = (k->>'id')::bigint AND a.done_at IS NULL;

  -- 3. the book: thread ids currently carrying a need2Buy label
  IF v_has_book THEN
    INSERT INTO public.gmail_relay_book AS b (thread_id, cancelled, seen_at)
    SELECT t, t IN (SELECT jsonb_array_elements_text(coalesce(p_payload->'cancelled', '[]'))), now()
      FROM jsonb_array_elements_text(p_payload->'book') t
    ON CONFLICT (thread_id) DO UPDATE SET cancelled = EXCLUDED.cancelled, seen_at = now();
    IF v_complete THEN
      DELETE FROM public.gmail_relay_book b
       WHERE NOT b.thread_id IN (SELECT jsonb_array_elements_text(p_payload->'book'));
    END IF;
  END IF;

  -- 4. what we still need from Gmail
  SELECT coalesce(array_agg(b.thread_id), '{}') INTO v_want_thr
    FROM (SELECT b.thread_id FROM public.gmail_relay_book b
           WHERE NOT EXISTS (SELECT 1 FROM public.gmail_relay_msgs g
                              WHERE g.thread_id = b.thread_id AND g.kind = 'sale')
           ORDER BY b.thread_id LIMIT 50) b;
  SELECT coalesce(array_agg(c), '{}') INTO v_want_msg
    FROM (SELECT c FROM jsonb_array_elements_text(coalesce(p_payload->'candidates', '[]')) c
           WHERE NOT EXISTS (SELECT 1 FROM public.gmail_relay_msgs g WHERE g.msg_id = c)
           LIMIT 100) w;

  -- 5. N2B rows: the book's sales, cancelled when the thread is
  IF v_has_book THEN
    SELECT coalesce(jsonb_agg(s.sale || jsonb_build_object(
             'sale_at', s.internal_at, 'thread_id', s.thread_id, 'cancelled', s.cancelled)), '[]')
      INTO v_items
      FROM (SELECT DISTINCT ON (g.order_no) g.sale, g.internal_at, g.thread_id,
                   (bk.cancelled OR EXISTS (SELECT 1 FROM public.gmail_relay_msgs x
                                             WHERE x.thread_id = g.thread_id AND x.kind = 'cancel')) AS cancelled
              FROM public.gmail_relay_book bk
              JOIN public.gmail_relay_msgs g ON g.thread_id = bk.thread_id AND g.kind = 'sale'
             WHERE g.sale IS NOT NULL
             ORDER BY g.order_no, g.internal_at) s;
    -- full sync only when every book thread's sale is known; otherwise a
    -- missing parse would close an open sale
    v_n2b := public.n2b_ingest_from_apps_script(
               v_items, v_expected, v_complete AND cardinality(v_want_thr) = 0);
  END IF;

  -- 6. label actions. The book in this payload was listed before the script
  --    applied the last batch, so an action done in the last 15 minutes is not
  --    queued again for the same thread + reason.
  -- bought: Step 2-8 SUCCESS for the same Order # + Site Order #
  WITH hit AS (
    SELECT DISTINCT ON (s.thread_id) s.thread_id, s.order_no, st.thread_id AS step_thread
      FROM public.gmail_relay_book bk
      JOIN public.gmail_relay_msgs s  ON s.thread_id = bk.thread_id AND s.kind = 'sale'
      JOIN public.gmail_relay_msgs st ON st.kind = 'step' AND st.order_no = s.order_no
                                     AND lower(st.site_order) = lower(s.site_order)
  ), cand AS (
    SELECT thread_id, 'bought' AS reason, order_no, ARRAY['bought'] AS add_l, c_drop AS rm_l FROM hit
    UNION
    SELECT step_thread, 'confirm-read', order_no, '{}'::text[], '{}'::text[] FROM hit
  )
  INSERT INTO public.gmail_relay_actions (thread_id, reason, order_no, add_labels, rm_labels, mark_read)
  SELECT c.thread_id, c.reason, c.order_no, c.add_l, c.rm_l, true
    FROM cand c
   WHERE NOT EXISTS (SELECT 1 FROM public.gmail_relay_actions a
                      WHERE a.thread_id = c.thread_id AND a.reason = c.reason
                        AND a.done_at > now() - interval '15 minutes')
  ON CONFLICT DO NOTHING;

  -- event passed: 24h+ after the event (venue-local time, read as ET)
  INSERT INTO public.gmail_relay_actions (thread_id, reason, order_no, rm_labels)
  SELECT s.thread_id, 'event-passed', s.order_no, c_drop
    FROM public.gmail_relay_book bk
    JOIN public.gmail_relay_msgs s ON s.thread_id = bk.thread_id AND s.kind = 'sale'
   WHERE nullif(s.sale->>'event_dt', '')::timestamp < (now() AT TIME ZONE 'America/New_York') - interval '1 day'
     AND NOT EXISTS (SELECT 1 FROM public.gmail_relay_actions a
                      WHERE a.thread_id = s.thread_id AND a.reason = 'event-passed'
                        AND a.done_at > now() - interval '15 minutes')
  ON CONFLICT DO NOTHING;

  -- 7. Gmail searches for Step 2+ emails of open book sales not yet confirmed,
  --    each sale at most every 5 minutes, 20 site order #s per search
  WITH due AS (
    SELECT bk.thread_id, s.site_order
      FROM public.gmail_relay_book bk
      JOIN public.gmail_relay_msgs s ON s.thread_id = bk.thread_id AND s.kind = 'sale'
     WHERE s.site_order IS NOT NULL
       AND (bk.confirm_checked_at IS NULL OR bk.confirm_checked_at < now() - interval '5 minutes')
       AND NOT EXISTS (SELECT 1 FROM public.gmail_relay_msgs st
                        WHERE st.kind = 'step' AND st.order_no = s.order_no
                          AND lower(st.site_order) = lower(s.site_order))
     ORDER BY bk.confirm_checked_at NULLS FIRST
     LIMIT 100
  ), mark AS (
    UPDATE public.gmail_relay_book b SET confirm_checked_at = now()
      FROM due WHERE b.thread_id = due.thread_id
    RETURNING due.site_order
  ), grp AS (
    SELECT (row_number() OVER (ORDER BY site_order) - 1) / 20 AS g, site_order
      FROM (SELECT DISTINCT site_order FROM mark) d
  )
  SELECT coalesce(jsonb_agg(q), '[]') INTO v_searches
    FROM (SELECT 'from:orders@s4kent.com subject:SUCCESS subject:Step ('
                 || string_agg('"' || replace(site_order, '"', '') || '"', ' OR ') || ')' AS q
            FROM grp GROUP BY g) z;

  -- 8. hand out open actions (re-sent if unacked after 5 minutes)
  WITH out AS (
    UPDATE public.gmail_relay_actions a SET sent_at = now()
     WHERE a.done_at IS NULL AND (a.sent_at IS NULL OR a.sent_at < now() - interval '5 minutes')
       AND a.id IN (SELECT id FROM public.gmail_relay_actions
                     WHERE done_at IS NULL ORDER BY id LIMIT 100)
    RETURNING a.id, a.thread_id, a.reason, a.order_no, a.add_labels, a.rm_labels, a.mark_read
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'thread_id', thread_id, 'reason', reason, 'order_no', order_no,
           'add', to_jsonb(add_labels), 'remove', to_jsonb(rm_labels), 'read', mark_read)), '[]')
    INTO v_actions FROM out;

  RETURN jsonb_build_object(
    'want_msgs', to_jsonb(v_want_msg),
    'want_threads', to_jsonb(v_want_thr),
    'searches', v_searches,
    'actions', v_actions,
    'n2b', v_n2b,
    'book', (SELECT count(*) FROM public.gmail_relay_book));
END;
$function$;

REVOKE ALL ON FUNCTION public.gmail_relay_sync(text, jsonb) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.gmail_relay_sync(text, jsonb) TO anon, service_role;
REVOKE ALL ON FUNCTION public.gmail_relay_parse_sale(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gmail_relay_parse_sale(text, text) TO service_role;

COMMENT ON FUNCTION public.gmail_relay_sync(text, jsonb) IS
  'Gmail relay (S4K_GmailRelay.gs). Secret-gated on APPSCRIPT_INGEST_SECRET. '
  'payload: {book:[thread ids with a need2Buy label], book_complete:bool, cancelled:[book thread ids with a cancel label], '
  'candidates:[recent message ids], messages:[{id,thread_id,internal_ms,subject,body,labels:[names]}], acks:[{id,ok,error}]}. '
  'returns: {want_msgs, want_threads, searches:[gmail queries], actions:[{id,thread_id,reason,add,remove,read}], n2b, book}. '
  'Decides N2B rows (via n2b_ingest_from_apps_script) and the bought / event-passed label changes (20261027160000).';
