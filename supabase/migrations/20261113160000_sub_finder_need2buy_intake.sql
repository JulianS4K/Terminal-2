-- Migration 20261113160000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_n2b_seen,sub_finder_need2buy,sub_finder_n2b_intake,sub_finder_refresh,sub_finder_autobuy · reads:n2s_items · pre:20261113140000
--
-- SUB FINDER: the CRM's "need2buy" label starts a lookup. No call from the CRM, no new poller.
--
-- Operator 2026-11-13: "Tell the CRM in the docs to use n2s feed but label it as need2buy that
-- label triggers this path that way we don't need multiple pollers".
--
-- We already read the CRM's Need-to-Sub feed (GET crm.s4kcs.com/api/v1/n2s/items) every 30
-- seconds into n2s_items. From now on an item in that feed that the CRM labels need2buy is
-- handed to the sub finder by the refresh job that already runs every minute:
--
--   the label         sub_finder_need2buy(status, status_label, raw): the item's `status`,
--                     `status_label` or `label_status`, letters and digits only, lower case, is
--                     'need2buy' (also 'needtobuy' / 'n2b'). CRM feed rows only: our own
--                     Gmail-labelled N2B rows (item_source 'gmail') are a different book and
--                     are NOT picked up here.
--   sub_finder_n2b_intake()
--                     for each labelled, open item not handed over yet: one sub_finder_submit
--                     under the key in sub_finder_config.n2b_key_id (order number + marketplace;
--                     the CRM's seller_notes become the order's notes). Remembered in
--                     sub_finder_n2b_seen so an item is handed over once per labelling: if the
--                     label goes and comes back, it is handed over again. At most n2b_batch
--                     (20) a round. Off until n2b_intake_enabled is true and n2b_key_id is set.
--   sub_finder_refresh
--                     calls the intake first, and keeps watching a labelled order: it used to
--                     close anything in the N2S book whose status was not n2s / n2b.
--   sub_finder_autobuy
--                     a labelled order takes the whole sub finder path, automatic buy
--                     included. Every other order in the N2S book is still left to the N2S
--                     pipeline ('n2s_order').
--
-- The CRM reads the answer as before (GET /api/v1/subs/orders/{n}, or the sync feed): its
-- API has no write surface, so nothing is written back to it.
--
-- sub_finder_refresh and sub_finder_autobuy are patched in place; each patch fails loudly if
-- a line it edits is not there exactly once, and does nothing on a second run.
--
-- rollback: UPDATE sub_finder_config SET n2b_intake_enabled = false;
--           re-apply sub_finder_refresh from 20261113120000 and sub_finder_autobuy from 20261113130000;
--           DROP FUNCTION public.sub_finder_n2b_intake(), public.sub_finder_need2buy(text, text, jsonb);
--           DROP TABLE public.sub_finder_n2b_seen;
--           ALTER TABLE public.sub_finder_config DROP COLUMN n2b_intake_enabled, DROP COLUMN n2b_key_id, DROP COLUMN n2b_batch;

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS n2b_intake_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS n2b_key_id         bigint,                      -- the key the lookups are filed under
  ADD COLUMN IF NOT EXISTS n2b_batch          integer NOT NULL DEFAULT 20 CHECK (n2b_batch BETWEEN 1 AND 200);

CREATE TABLE IF NOT EXISTS public.sub_finder_n2b_seen (
  n2s_id       bigint PRIMARY KEY,                 -- n2s_items.n2s_id
  order_number text,
  job_id       uuid,
  result       text,                               -- the submit's status, or its error
  handed_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.sub_finder_n2b_seen ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sub_finder_n2b_seen FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.sub_finder_n2b_seen IS
  'CRM N2S-feed items labelled need2buy that were handed to the sub finder (20261113160000). One row while the '
  'label is on; removed when the label goes, so a re-labelled item is handed over again.';

CREATE OR REPLACE FUNCTION public.sub_finder_need2buy(p_status text, p_status_label text, p_raw jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path = public, pg_temp
AS $$
  SELECT coalesce(bool_or(lower(regexp_replace(v, '[^A-Za-z0-9]', '', 'g')) IN ('need2buy', 'needtobuy', 'n2b')), false)
    FROM unnest(ARRAY[p_status, p_status_label, p_raw->>'label_status']) v;
$$;
REVOKE ALL ON FUNCTION public.sub_finder_need2buy(text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_need2buy(text, text, jsonb) TO service_role;

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
    INSERT INTO public.sub_finder_n2b_seen (n2s_id, order_number, job_id, result)
    VALUES (r.n2s_id, r.order_number, (v_out->>'job_id')::uuid, coalesce(v_out->>'error', v_out->>'status'))
    ON CONFLICT (n2s_id) DO NOTHING;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END
$$;
REVOKE ALL ON FUNCTION public.sub_finder_n2b_intake() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_n2b_intake() TO service_role;

-- the refresh job: take in the labelled items first, and keep watching a labelled order
DO $patch$
DECLARE
  v_def  text := pg_get_functiondef('public.sub_finder_refresh()'::regprocedure);
  v_old1 text := $o$IF NOT public.cron_try_lock('sub_finder_refresh') THEN RETURN jsonb_build_object('skipped', 'overlap'); END IF;$o$;
  v_new1 text := $n$IF NOT public.cron_try_lock('sub_finder_refresh') THEN RETURN jsonb_build_object('skipped', 'overlap'); END IF;

  -- 0. CRM N2S-feed items labelled need2buy start their lookups here (20261113160000)
  PERFORM public.sub_finder_n2b_intake();$n$;
  v_old2 text := $o$AND NOT coalesce(n.is_terminal, false) AND n.status IN ('n2s', 'n2b'))$o$;
  v_new2 text := $n$AND NOT coalesce(n.is_terminal, false)
                   AND (n.status IN ('n2s', 'n2b') OR public.sub_finder_need2buy(n.status, n.status_label, n.raw)))$n$;
BEGIN
  IF position('sub_finder_n2b_intake' IN v_def) > 0 THEN RETURN; END IF;      -- already patched
  IF (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     OR (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_refresh: the lines to patch were not each found exactly once';
  END IF;
  EXECUTE replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
END
$patch$;

-- the automatic buy: a need2buy order is the sub finder's, every other N2S-book order is not
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.sub_finder_autobuy(uuid)'::regprocedure);
  v_old text := $o$WHERE n.order_number = o.order_number OR n.n2s_order_key = o.order_number)$o$;
  v_new text := $n$WHERE (n.order_number = o.order_number OR n.n2s_order_key = o.order_number)
                   AND NOT (n.item_source IS DISTINCT FROM 'gmail'
                            AND public.sub_finder_need2buy(n.status, n.status_label, n.raw)))$n$;
BEGIN
  IF position('sub_finder_need2buy' IN v_def) > 0 THEN RETURN; END IF;        -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_autobuy: the line to patch was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;
