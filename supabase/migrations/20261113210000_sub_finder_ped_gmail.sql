-- Migration 20261113210000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_n2b_item,sub_finder_n2b_intake,sub_finder_refresh · reads:n2s_items,sub_finder_n2b_seen · pre:20261113190000
--
-- SUB FINDER: report on the PED Need2Buy orders from Gmail too.
--
-- Operator 2026-11-13: "Report on the ped ones from Gmail also".
--
-- A peddled sale we still have to buy sits in n2s_items as item_source 'gmail', status 'n2b',
-- for as long as its Gmail thread carries the Need2Buy/WaitToBuy label (mig 20261009180000).
-- The need2buy intake (20261113160000) deliberately left that book out. From now on, with
-- sub_finder_config.n2b_gmail_enabled on, those rows are handed to the sub finder exactly like
-- a CRM-feed item labelled need2buy, so the CRM reads their covers, gate and flags through the
-- same API.
--
--   sub_finder_n2b_item(item_source, status, status_label, raw)
--                     one rule for "this open n2s_items row is a need2buy item": a CRM-feed row
--                     with the need2buy label, or (switch on) a Gmail row with status 'n2b'.
--                     Used by the intake and by the close rule, so they cannot disagree.
--   lifetime          the same as any need2buy lookup: until the label goes (the Gmail row
--                     closes: closed_reason 'label_removed'), the marketplace reports the sale
--                     over, or the event passes.
--   REPORT ONLY       nothing is bought automatically for these: sub_finder_autobuy already
--                     treats every Gmail row in the N2S book as auto_buy_note 'n2s_order'
--                     (unchanged here). The CRM's own buy / offer calls work as for any order.
--   decisions         sub_finder_feed_decisions reads CRM-feed rows only (unchanged): a Gmail
--                     row carries no decision fields.
--
-- Off until n2b_gmail_enabled is true. sub_finder_refresh is patched in place; the patch fails
-- loudly if the text it edits is not there exactly once, and does nothing on a second run.
--
-- rollback: UPDATE sub_finder_config SET n2b_gmail_enabled = false WHERE id = true;
--           (full: re-apply sub_finder_n2b_intake + the refresh close rule from 20261113190000;
--           ALTER TABLE public.sub_finder_config DROP COLUMN n2b_gmail_enabled.)

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS n2b_gmail_enabled boolean NOT NULL DEFAULT false;   -- Gmail PED Need2Buy rows are handed over too

CREATE OR REPLACE FUNCTION public.sub_finder_n2b_item(p_source text, p_status text, p_status_label text, p_raw jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN p_source = 'gmail'
      THEN p_status = 'n2b' AND coalesce((SELECT c.n2b_gmail_enabled FROM public.sub_finder_config c), false)
    ELSE public.sub_finder_need2buy(p_status, p_status_label, p_raw)
  END
$$;
REVOKE ALL ON FUNCTION public.sub_finder_n2b_item(text, text, text, jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.sub_finder_n2b_intake()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c     public.sub_finder_config;
  r     record;
  v_out jsonb;
  v_lbl text;
  v_n   integer := 0;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT (c.enabled AND c.n2b_intake_enabled) OR c.n2b_key_id IS NULL OR NOT (c.n2b_key_id = ANY (c.key_ids)) THEN
    RETURN 0;
  END IF;
  -- the label went (or the item closed): forget it, so labelling it again hands it over again
  DELETE FROM public.sub_finder_n2b_seen s
   WHERE NOT EXISTS (SELECT 1 FROM public.n2s_items n
                      WHERE n.n2s_id = s.n2s_id AND NOT coalesce(n.is_terminal, false)
                        AND public.sub_finder_n2b_item(n.item_source, n.status, n.status_label, n.raw));
  SELECT k.label INTO v_lbl FROM public.mcp_api_keys k WHERE k.id = c.n2b_key_id;
  FOR r IN
    SELECT n.n2s_id, n.order_number, n.marketplace, n.raw->>'seller_notes' AS notes
      FROM public.n2s_items n
     WHERE NOT coalesce(n.is_terminal, false)
       AND public.sub_finder_n2b_item(n.item_source, n.status, n.status_label, n.raw)
       AND n.order_number ~ '^[A-Za-z0-9._-]{1,64}$'
       AND NOT EXISTS (SELECT 1 FROM public.sub_finder_n2b_seen s WHERE s.n2s_id = n.n2s_id)
     ORDER BY n.n2s_updated_at NULLS LAST, n.n2s_id LIMIT c.n2b_batch
  LOOP
    BEGIN
      v_out := public.sub_finder_submit(
        c.n2b_key_id, coalesce(v_lbl, 'crm need2buy'),
        jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
          'order_number', r.order_number, 'site', r.marketplace,
          'notes', left(nullif(btrim(r.notes), ''), 500)))),
        'need2buy:' || r.n2s_id || ':' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'));   -- never a replay: sub_finder_n2b_seen is the once-only guard
    EXCEPTION WHEN OTHERS THEN
      v_out := jsonb_build_object('error', left(SQLERRM, 200));      -- one bad item never stops the rest
    END;
    -- these lookups live as long as the label does (or until the marketplace says the sale is over)
    UPDATE public.sub_finder_order SET via_need2buy = true
     WHERE job_id = (v_out->>'job_id')::uuid AND order_number = r.order_number;
    INSERT INTO public.sub_finder_n2b_seen (n2s_id, order_number, job_id, result)
    VALUES (r.n2s_id, r.order_number, (v_out->>'job_id')::uuid, coalesce(v_out->>'error', v_out->>'status'))
    ON CONFLICT (n2s_id) DO NOTHING;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END
$$;

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.sub_finder_refresh()'::regprocedure);
  v_old text := $o$                   AND n.item_source IS DISTINCT FROM 'gmail' AND NOT coalesce(n.is_terminal, false)
                   AND public.sub_finder_need2buy(n.status, n.status_label, n.raw))
            THEN 'label_removed'$o$;
  v_new text := $n$                   AND NOT coalesce(n.is_terminal, false)
                   AND public.sub_finder_n2b_item(n.item_source, n.status, n.status_label, n.raw))
            THEN 'label_removed'$n$;
BEGIN
  IF position('sub_finder_n2b_item' IN v_def) > 0 THEN RETURN; END IF;        -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_refresh: the text to patch was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;
