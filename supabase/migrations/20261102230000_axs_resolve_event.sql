-- Migration 20261102230000 · level:data-collection · lane:A1 (AXS ingest) · writes:axs_resolve_event()(new),axs_resolve_aq_event()(new),axs_resolve_gt_event()(new),axs_catalog(tevo_event_id backfill on match),axs_performers(re-queue on miss) · reads:aq_event_map,axs_events,axs_catalog,axs_venue_directory,sg_events_canonical,events,gotickets_event,v_axs_venues · pre:20261102220000
--
-- ============================================================================
-- AXS event id for any event in our feeds (operator 2026-11-02: "assume I have an AQ or GoTickets
-- events feed, how do I get the AXS event id? … build the resolver").
--
-- AXS has no name / venue / date search, so the id comes from what is stored, else from an AXS
-- artist tour. axs_resolve_event(tevo_event_id) tries, first hit wins:
--   1 aq_event_map        aq_event_map.axs_event_id for the event (406 filled on 2026-11-02)
--   2 axs_events          the hand-entered / enrolled pull list (axs_events.tevo_event_id)
--   3 axs_catalog         catalogue row already linked to the event
--   4 catalog_venue_date  catalogue event at the same venue on the same local date — venue matched
--                         through axs_venue_directory (AXS venue id → TEvo venue) or the same
--                         normalised venue name; several shows that day → closest title, flagged.
--                         The match is written back to axs_catalog.tevo_event_id.
--   5 seatgeek_integrated SeatGeek's primary-ticketer field (via the event or its AQ SeatGeek id)
--   otherwise, no id:
--     not_axs_venue        the venue is not in v_axs_venues (no AXS evidence) — likely not AXS-sold
--     queued_artist_crawl  the performer is a known AXS artist: moved to the front of the crawl
--                          (axs_artist_discover, hourly; at most once a day per artist); call
--                          again after the next drain (:57)
--     no_axs_artist        AXS venue, but no AXS artist id for the performer — needs the
--                          TicketsData Event Radar export or one hand-entered URL for the artist
-- Wrappers: axs_resolve_aq_event(aq_short_event_id), axs_resolve_gt_event(gt_event_id) (GoTickets
-- events must be mapped to a TEvo event; unmapped ones return gt_not_mapped).
-- Nothing calls an API: step "queued" only re-prioritises the hourly crawl.
-- Rollback: DROP FUNCTION axs_resolve_gt_event(bigint), axs_resolve_aq_event(text), axs_resolve_event(bigint);
-- ============================================================================

CREATE OR REPLACE FUNCTION public.axs_resolve_event(p_tevo_event_id bigint)
RETURNS TABLE (axs_event_id text, event_url text, method text, detail text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  e        record;
  v_id     text;
  v_url    text;
  v_n      int;
  v_detail text;
  v_norm   text;
BEGIN
  SELECT ev.id, ev.name, ev.venue_id, ev.venue_name, ev.occurs_at_local, ev.primary_performer_name
    INTO e FROM public.events ev WHERE ev.id = p_tevo_event_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT NULL::text, NULL::text, 'unknown_event'::text, 'no such TEvo event'::text; RETURN;
  END IF;

  -- 1. AQ hub
  SELECT m.axs_event_id INTO v_id FROM public.aq_event_map m
   WHERE m.tevo_event_id = p_tevo_event_id AND m.axs_event_id IS NOT NULL LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN QUERY SELECT v_id, coalesce((SELECT a.event_url FROM public.axs_events a WHERE a.axs_event_id = v_id),
                                       'https://www.axs.com/events/' || v_id), 'aq_event_map'::text, NULL::text;
    RETURN;
  END IF;

  -- 2. AXS pull list
  SELECT a.axs_event_id, a.event_url INTO v_id, v_url FROM public.axs_events a
   WHERE a.tevo_event_id = p_tevo_event_id ORDER BY a.active DESC, a.created_at DESC LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN QUERY SELECT v_id, v_url, 'axs_events'::text, NULL::text; RETURN;
  END IF;

  -- 3. catalogue row already linked
  SELECT c.axs_event_id, c.event_url INTO v_id, v_url FROM public.axs_catalog c
   WHERE c.tevo_event_id = p_tevo_event_id LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN QUERY SELECT v_id, v_url, 'axs_catalog'::text, NULL::text; RETURN;
  END IF;

  -- 4. catalogue by venue + local date
  IF e.occurs_at_local ~ '^\d{4}-\d\d-\d\d' THEN
    v_norm := regexp_replace(regexp_replace(lower(e.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g');
    WITH cand AS (
      SELECT c.axs_event_id, c.event_url,
             similarity(lower(coalesce(c.event_name, '')),
                        lower(coalesce(e.primary_performer_name, e.name, ''))) AS sim
        FROM public.axs_catalog c
        LEFT JOIN public.axs_venue_directory d ON d.axs_venue_id = c.axs_venue_id
       WHERE c.event_date = left(e.occurs_at_local, 10)::date
         AND (c.tevo_event_id IS NULL OR c.tevo_event_id = p_tevo_event_id)
         AND (d.tevo_venue_id = e.venue_id
              OR regexp_replace(regexp_replace(lower(c.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g') = v_norm))
    SELECT (SELECT cand.axs_event_id FROM cand ORDER BY sim DESC, cand.axs_event_id LIMIT 1),
           (SELECT cand.event_url FROM cand ORDER BY sim DESC, cand.axs_event_id LIMIT 1),
           (SELECT count(*) FROM cand)
      INTO v_id, v_url, v_n;
    IF v_id IS NOT NULL THEN
      UPDATE public.axs_catalog c SET tevo_event_id = p_tevo_event_id
       WHERE c.axs_event_id = v_id AND c.tevo_event_id IS NULL;
      v_detail := CASE WHEN v_n > 1 THEN v_n || ' AXS events at this venue that day; closest title chosen' END;
      RETURN QUERY SELECT v_id, v_url, 'catalog_venue_date'::text, v_detail; RETURN;
    END IF;
  END IF;

  -- 5. SeatGeek primary-ticketer field
  SELECT substring(g.raw_event_jsonb->'integrated'->>'provider_id' FROM '(\d+)$') INTO v_id
    FROM public.sg_events_canonical g
   WHERE g.raw_event_jsonb->'integrated'->>'provider_name' = 'AXS'
     AND (g.tevo_event_id = p_tevo_event_id
          OR g.sg_event_id IN (SELECT m.sg_event_id FROM public.aq_event_map m
                                WHERE m.tevo_event_id = p_tevo_event_id AND m.sg_event_id IS NOT NULL))
   LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN QUERY SELECT v_id, 'https://www.axs.com/events/' || v_id, 'seatgeek_integrated'::text, NULL::text; RETURN;
  END IF;

  -- no id: is the venue AXS at all?
  IF NOT EXISTS (SELECT 1 FROM public.v_axs_venues v WHERE v.tevo_venue_id = e.venue_id) THEN
    RETURN QUERY SELECT NULL::text, NULL::text, 'not_axs_venue'::text,
                        'venue has no AXS evidence in axs_venue_catalog'::text;
    RETURN;
  END IF;

  -- AXS venue: put the performer at the front of the hourly artist crawl
  UPDATE public.axs_performers p
     SET last_discovered_at = NULL, updated_at = now()
   WHERE public.axs_slugify(p.performer) = public.axs_slugify(e.primary_performer_name)
     AND p.pending_request_id IS NULL
     AND (p.last_discovered_at IS NULL OR p.last_discovered_at < now() - interval '1 day');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n > 0 OR EXISTS (SELECT 1 FROM public.axs_performers p
                         WHERE public.axs_slugify(p.performer) = public.axs_slugify(e.primary_performer_name)) THEN
    RETURN QUERY SELECT NULL::text, NULL::text, 'queued_artist_crawl'::text,
                        format('AXS artist "%s" queued; call again after the next crawl drain (:57)', e.primary_performer_name);
    RETURN;
  END IF;
  RETURN QUERY SELECT NULL::text, NULL::text, 'no_axs_artist'::text,
                      format('AXS venue, but no AXS artist id for "%s": needs the Event Radar export or one hand-entered AXS URL', e.primary_performer_name);
END $$;

CREATE OR REPLACE FUNCTION public.axs_resolve_aq_event(p_aq_short_event_id text)
RETURNS TABLE (axs_event_id text, event_url text, method text, detail text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_tevo bigint;
  v_axs  text;
BEGIN
  SELECT m.tevo_event_id, m.axs_event_id INTO v_tevo, v_axs
    FROM public.aq_event_map m WHERE m.aq_short_event_id = p_aq_short_event_id LIMIT 1;
  IF v_axs IS NOT NULL THEN
    RETURN QUERY SELECT v_axs, 'https://www.axs.com/events/' || v_axs, 'aq_event_map'::text, NULL::text; RETURN;
  END IF;
  IF v_tevo IS NULL THEN
    RETURN QUERY SELECT NULL::text, NULL::text, 'aq_not_mapped'::text, 'AQ event has no TEvo event'::text; RETURN;
  END IF;
  RETURN QUERY SELECT * FROM public.axs_resolve_event(v_tevo);
END $$;

CREATE OR REPLACE FUNCTION public.axs_resolve_gt_event(p_gt_event_id bigint)
RETURNS TABLE (axs_event_id text, event_url text, method text, detail text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_tevo bigint;
BEGIN
  SELECT g.tevo_event_id INTO v_tevo FROM public.gotickets_event g WHERE g.gt_event_id = p_gt_event_id;
  IF v_tevo IS NULL THEN
    RETURN QUERY SELECT NULL::text, NULL::text, 'gt_not_mapped'::text, 'GoTickets event has no TEvo event'::text; RETURN;
  END IF;
  RETURN QUERY SELECT * FROM public.axs_resolve_event(v_tevo);
END $$;

REVOKE ALL ON FUNCTION public.axs_resolve_event(bigint), public.axs_resolve_aq_event(text),
                       public.axs_resolve_gt_event(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_resolve_event(bigint), public.axs_resolve_aq_event(text),
                          public.axs_resolve_gt_event(bigint) TO service_role;
