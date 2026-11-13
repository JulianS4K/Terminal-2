-- Migration 20261113230000 · level:secondary-sales · lane:D0 · writes:sub_finder_load_native · reads:n2s_sg_current,sg_events_canonical · pre:20261113220000
--
-- SUB FINDER: every SeatGeek cover carries a link.
--
-- Operator 2026-11-13: "fix sg link". 43 of 49 SeatGeek covers on live lookups reached the CRM
-- with link = null. The link was built only when BOTH sg_events_canonical.sg_url and the
-- listing's display_id were known; either one missing dropped it.
--
--   event page   sg_events_canonical.sg_url when we hold it, else SeatGeek's own redirect by
--                event id, https://seatgeek.com/e/events/<sg_event_id> (the same fallback
--                get_event_source_links has used since 20260603180000).
--   listing      '#listing=<display_id>' is appended when the listing has a display id;
--                without one the link opens the event page.
-- So a SeatGeek cover has a link whenever the listing row has its sg_event_id, which it
-- always should. Nothing else about the cover changes.
--
-- sub_finder_load_native is patched in place; the patch fails loudly if the text it replaces
-- is not there exactly once, and does nothing on a second run.
--
-- rollback: re-apply sub_finder_load_native from 20261113220000.

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.sub_finder_load_native(uuid, interval)'::regprocedure);
  v_old text := $o$         CASE WHEN sg.sg_url IS NOT NULL AND x.display_id IS NOT NULL
              THEN sg.sg_url || '#listing=' || x.display_id END, NULL,$o$;
  v_new text := $n$         coalesce(nullif(sg.sg_url, ''), 'https://seatgeek.com/e/events/' || x.sg_event_id)
           || CASE WHEN x.display_id IS NOT NULL THEN '#listing=' || x.display_id ELSE '' END, NULL,   -- 20261113230000$n$;
BEGIN
  IF position('seatgeek.com/e/events/' IN v_def) > 0 THEN RETURN; END IF;      -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_load_native: the SeatGeek link expression was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;
