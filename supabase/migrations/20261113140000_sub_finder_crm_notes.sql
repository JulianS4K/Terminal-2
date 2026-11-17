-- Migration 20261113140000 · level:secondary-sales · lane:D0 · writes:sub_finder_order,sub_finder_set_notes,sub_finder_submit,sub_finder_order_json · reads:none · pre:20261113130000
--
-- SUB FINDER: a notes field the CRM can write.
--
-- Operator 2026-11-13: "add notes field so it can add notes and add that to docs".
--
--   sub_finder_order.crm_notes / crm_notes_at   free text from the CRM, at most 500 characters.
--   set it      with the alert: `notes` on the order (POST /jobs, POST /orders/{n}/needs-sub);
--               or at any time: POST /orders/{n}/notes {"notes": "..."} -> sub_finder_set_notes.
--               An empty value clears it. It goes on the newest lookup of that order for the key.
--   read it     every order object carries `notes` and `notes_at`. Writing a note moves the
--               order's updated_at, so the order returns in the sync feed.
--   carried     a new lookup of the same order (a re-alert) keeps the last note unless it
--               brings its own.
-- The note is ours to store and show: nothing reads it to decide a match, a buy or an offer.
--
-- sub_finder_submit and sub_finder_order_json are patched in place; each patch fails loudly
-- if a line it edits is not there exactly once, and does nothing on a second run.
--
-- rollback: re-apply sub_finder_submit from 20261113120000 and sub_finder_order_json from 20261113120000;
--           DROP FUNCTION public.sub_finder_set_notes(bigint, text, text);
--           ALTER TABLE public.sub_finder_order DROP COLUMN crm_notes, DROP COLUMN crm_notes_at;

ALTER TABLE public.sub_finder_order
  ADD COLUMN IF NOT EXISTS crm_notes    text CHECK (crm_notes IS NULL OR length(crm_notes) <= 500),
  ADD COLUMN IF NOT EXISTS crm_notes_at timestamptz;

CREATE OR REPLACE FUNCTION public.sub_finder_set_notes(p_key_id bigint, p_order_number text, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c      public.sub_finder_config;
  v_note text := left(nullif(btrim(coalesce(p_notes, '')), ''), 500);
  r      record;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT c.enabled OR NOT (p_key_id = ANY (c.key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not use the sub finder');
  END IF;
  -- the newest lookup of this order for this key: the watched one first
  SELECT o.job_id, o.idx INTO r FROM public.sub_finder_order o
   WHERE o.key_id = p_key_id AND o.order_number = p_order_number
   ORDER BY o.watching DESC, o.updated_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'not_found', 'detail', 'no lookup holds this order; alert us first');
  END IF;
  UPDATE public.sub_finder_order
     SET crm_notes = v_note, crm_notes_at = now(), updated_at = now()
   WHERE job_id = r.job_id AND idx = r.idx;
  RETURN jsonb_build_object('order_number', p_order_number, 'job_id', r.job_id, 'notes', v_note,
                            'notes_at', to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
END
$$;
REVOKE ALL ON FUNCTION public.sub_finder_set_notes(bigint, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_set_notes(bigint, text, text) TO service_role;

-- the alert may carry `notes`; a re-alert keeps the last note unless it brings its own
DO $patch$
DECLARE
  v_def  text := pg_get_functiondef('public.sub_finder_submit(bigint, text, jsonb, text)'::regprocedure);
  v_old1 text := $o$coalesce(nullif(btrim(o.j->>'venue'), ''), m.venue)               AS venue,$o$;
  v_new1 text := $n$coalesce(nullif(btrim(o.j->>'venue'), ''), m.venue)               AS venue,
         coalesce(left(nullif(btrim(o.j->>'notes'), ''), 500),
                  (SELECT p.crm_notes FROM public.sub_finder_order p
                    WHERE p.key_id = p_key_id AND p.order_number = btrim(o.j->>'order_number')
                      AND p.crm_notes IS NOT NULL
                    ORDER BY p.updated_at DESC LIMIT 1))                     AS crm_notes,$n$;
  v_old2 text := $o$event_date, venue, section, seat_row, qty, sold_ea, state, order_source)$o$;
  v_new2 text := $n$event_date, venue, section, seat_row, qty, sold_ea, state, order_source,
                                       crm_notes, crm_notes_at)$n$;
  v_old3 text := $o$coalesce(i.book, 'request')$o$;
  v_new3 text := $n$coalesce(i.book, 'request'), i.crm_notes, CASE WHEN i.crm_notes IS NOT NULL THEN now() END$n$;
BEGIN
  IF position('crm_notes' IN v_def) > 0 THEN RETURN; END IF;                  -- already patched
  IF (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     OR (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1
     OR (length(v_def) - length(replace(v_def, v_old3, ''))) / length(v_old3) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_submit: the lines to patch were not each found exactly once';
  END IF;
  EXECUTE replace(replace(replace(v_def, v_old1, v_new1), v_old2, v_new2), v_old3, v_new3);
END
$patch$;

-- every order object shows the note
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.sub_finder_order_json(public.sub_finder_order)'::regprocedure);
  v_old text := $o$'order_source', o.order_source, 'state', o.state,$o$;
  v_new text := $n$'order_source', o.order_source, 'state', o.state,
    -- free text the CRM wrote on this order (POST /orders/{n}/notes, or `notes` with the alert)
    'notes', o.crm_notes,
    'notes_at', to_char(o.crm_notes_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),$n$;
BEGIN
  IF position('crm_notes' IN v_def) > 0 THEN RETURN; END IF;                  -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_order_json: the line to patch was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;
