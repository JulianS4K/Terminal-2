-- Migration 20261125170500 · level:data-collection · lane:A1 (data plane: the AXS export feed, routed to this session by the operator) · writes:axs_export_type_override(new table+seed),axs_export_type_force()(new trigger fn),axs_export_event(trg_axs_export_type_force + a one-time relabel of the listed venues' rows) · reads:axs_export_type_override · pre:20261125163500
--
-- TOYOTA CENTER READS AS AXS PRIMARY.
-- Operator 2026-11-25: "force label Toyota Center as AXS primary in tables".
--
-- WHY. TicketsData's `type` says whose ticketing BRAND an event page sits under; `axs_ticketed` says who
-- fulfils it. Toyota Center sells through AXS under two other brands, so of its 56 upcoming AXS-sold events
-- only 4 carry type = 'axs_primary':
--     other_ticketer / ticketer 'nba'           31 events (Rockets)
--     other_ticketer / ticketer 'toyotacenter'  21 events
--     axs_primary    / ticketer NULL             4 events
-- Any query that reaches for the intuitive type = 'axs_primary' therefore drops 52 of 56 (93%) — and Toyota
-- Center is the watch's second-largest quota (48) and the top venue in the 13-month sales book (1,725 tickets
-- over 28 events). It is the ONLY enabled venue with this shape, so the filter does not degrade evenly: it
-- silently zeroes the best-selling venue and raises no error. axs_watch_fill has always been right because it
-- tests axs_ticketed, not type.
--
-- WHY A TRIGGER, NOT AN UPDATE. axs_export_tick's upsert sets `type = EXCLUDED.type` on every pass, so a plain
-- UPDATE is overwritten within a day (sooner if an incremental carries the row). The label is forced at write
-- time instead, so it survives every export pass without the tick needing to know about it.
--
-- WHAT IT DOES. axs_export_type_override lists venues whose AXS-sold events are relabelled, with who set it and
-- why. The trigger forces type only when the row is actually axs_ticketed — an event AXS does not sell keeps
-- its own type. `ticketer` is left alone, so 'nba' / 'toyotacenter' stay visible and nothing is lost.
--
-- WHO SEES THE 52 NEW ROWS. Two objects filter on type = 'axs_primary', both as INCLUSION: v_axs_event_map and
-- axs_market_fallback_match. So Toyota Center's events now enter the AXS->EVO market mapping and the market
-- fallback matcher. That is the intent (we watch them, they should be mapped) and nothing uses the type to
-- exclude work. Mapping is the Terminal mapper session's surface (KANBAN, bot_chat 6851), so this is filed to
-- them as a flag: the input set grew by 52 Toyota Center events, no mapper function or cron was changed.
--
-- rollback: DROP TRIGGER trg_axs_export_type_force ON public.axs_export_event;
--           DROP FUNCTION public.axs_export_type_force();
--           DROP TABLE public.axs_export_type_override;
--           the relabelled rows revert to TicketsData's own type on the next export pass that carries them.

BEGIN;

CREATE TABLE IF NOT EXISTS public.axs_export_type_override (
  venue_id    bigint PRIMARY KEY,
  venue_name  text,
  forced_type text NOT NULL DEFAULT 'axs_primary',
  note        text,
  set_by      text NOT NULL DEFAULT 'operator',
  set_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.axs_export_type_override IS
  'venues whose axs_ticketed events are relabelled in axs_export_event.type, because TicketsData files them under another ticketing brand (mig 20261125170500). ticketer is never changed.';

INSERT INTO public.axs_export_type_override (venue_id, venue_name, note, set_by) VALUES
  (101329, 'Toyota Center',
   'AXS sells under the nba and toyotacenter brands: 52 of 56 upcoming AXS-sold events were not type=axs_primary. Operator 2026-11-25 "force label Toyota Center as AXS primary in tables".',
   'operator')
ON CONFLICT (venue_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.axs_export_type_force()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_forced text;
BEGIN
  -- only an event AXS actually sells is relabelled; one it does not keeps TicketsData's own type
  IF coalesce(NEW.axs_ticketed, false) AND NEW.venue_id IS NOT NULL THEN
    SELECT o.forced_type INTO v_forced
      FROM public.axs_export_type_override o WHERE o.venue_id = NEW.venue_id;
    IF v_forced IS NOT NULL THEN
      NEW.type := v_forced;
    END IF;
  END IF;
  RETURN NEW;
END $function$;

REVOKE ALL ON FUNCTION public.axs_export_type_force() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_axs_export_type_force ON public.axs_export_event;
CREATE TRIGGER trg_axs_export_type_force
  BEFORE INSERT OR UPDATE ON public.axs_export_event
  FOR EACH ROW EXECUTE FUNCTION public.axs_export_type_force();

-- the rows already stored, once: the trigger only fires on writes
UPDATE public.axs_export_event e
   SET type = o.forced_type
  FROM public.axs_export_type_override o
 WHERE e.venue_id = o.venue_id
   AND coalesce(e.axs_ticketed, false)
   AND e.type IS DISTINCT FROM o.forced_type;

COMMIT;
