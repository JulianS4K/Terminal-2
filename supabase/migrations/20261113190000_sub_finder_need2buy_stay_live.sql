-- Migration 20261113190000 · level:secondary-sales · lane:D0 · writes:sub_finder_order,sub_finder_n2b_intake,sub_finder_refresh · reads:n2s_items,sub_finder_n2b_seen · pre:20261113160000
--
-- SUB FINDER: a need2buy lookup ends when the label is removed, or the marketplace says so.
--
-- Operator 2026-11-13: "The ones labeled need2buy, keep them live till order status changes
-- and keep looking for data unless it meets our poll pausing conditions", then "Label removed
-- or order status change is detected via API from marketplace".
--
-- A lookup started from the CRM's need2buy label (sub_finder_order.via_need2buy, set by the
-- intake) is live until one of two things is seen:
--   1. the label is removed: the CRM's feed no longer shows an open item for that order
--      labelled need2buy. That covers a label taken off, changed to anything else (n2s,
--      subbed, no_subs ...), or an item resolved / allocated. closed_reason 'label_removed'.
--      Until now a label changed back to n2s left the lookup open, because the N2S book rule
--      counts n2s as open;
--   2. the order's status changes, read from the marketplace's own order feed (GoTickets,
--      TickPick, Vivid, SeatGeek, EVO: pulled every 5 minutes, checked every 2), with our copy
--      of the CRM's marketplace book for the others: order_cancelled / order_fulfilled /
--      order_rejected. Unchanged.
-- (Also unchanged: the event passing, and a newer lookup of the same order taking over.)
-- While live it is polled and re-matched every round like any watched order, except while a
-- pause condition holds (a GoTickets sub offer waiting on the customer).
--
-- sub_finder_refresh is patched in place; the patch fails loudly if the line it edits is not
-- there exactly once, and does nothing on a second run.
--
-- rollback: re-apply sub_finder_n2b_intake from 20261113160000 and sub_finder_refresh without this line;
--           ALTER TABLE public.sub_finder_order DROP COLUMN via_need2buy;

ALTER TABLE public.sub_finder_order
  ADD COLUMN IF NOT EXISTS via_need2buy boolean NOT NULL DEFAULT false;   -- started from the CRM's need2buy label

UPDATE public.sub_finder_order o SET via_need2buy = true
  FROM public.sub_finder_n2b_seen s
 WHERE o.job_id = s.job_id AND o.order_number = s.order_number AND NOT o.via_need2buy;

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
                        AND n.item_source IS DISTINCT FROM 'gmail'
                        AND public.sub_finder_need2buy(n.status, n.status_label, n.raw));
  SELECT k.label INTO v_lbl FROM public.mcp_api_keys k WHERE k.id = c.n2b_key_id;
  FOR r IN
    SELECT n.n2s_id, n.order_number, n.marketplace, n.raw->>'seller_notes' AS notes
      FROM public.n2s_items n
     WHERE NOT coalesce(n.is_terminal, false) AND n.item_source IS DISTINCT FROM 'gmail'
       AND public.sub_finder_need2buy(n.status, n.status_label, n.raw)
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
  v_old text := $o$WHEN (w.order_source = 'n2s' OR w.in_n2s) AND NOT EXISTS ($o$;
  v_new text := $n$-- a need2buy lookup lives as long as its label: gone, changed or the item finished -> closed
          WHEN w.via_need2buy AND NOT EXISTS (
                 SELECT 1 FROM public.n2s_items n
                 WHERE (n.order_number = w.order_number OR n.n2s_order_key = w.order_number)
                   AND n.item_source IS DISTINCT FROM 'gmail' AND NOT coalesce(n.is_terminal, false)
                   AND public.sub_finder_need2buy(n.status, n.status_label, n.raw))
            THEN 'label_removed'
          WHEN (w.order_source = 'n2s' OR w.in_n2s) AND NOT w.via_need2buy AND NOT EXISTS ($n$;
BEGIN
  IF position('via_need2buy' IN v_def) > 0 THEN RETURN; END IF;               -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_refresh: the line to patch was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;
