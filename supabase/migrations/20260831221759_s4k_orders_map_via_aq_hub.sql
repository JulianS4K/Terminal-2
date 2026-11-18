-- Migration 20260831221759 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "s4k_orders_map_via_aq_hub" (version 20260831221759) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- v3: aq_event_map (the AQ hub, PROJECT_BIBLE §0) becomes the PRIMARY mapper,
-- and resolutions are written back into it so the fuzzy match is done once.
--
-- The hub is the curated cross-source registry: 9,666 rows carrying
-- event_name/venue_name/event_date alongside tevo_event_id and per-marketplace
-- ids (sh/sg/vivid/tm/sd/axs). 5,789 rows carry a tevo_event_id; 3,877 do not.
--
-- HUB LOOKUP IS NAME-GUARDED, and that is not optional. A venue+date-only probe
-- against the hub produced 5 bad links on the first try: S4K's "NHL Preseason:
-- Rangers vs. Islanders" at Madison Square Garden on 2026-09-22 resolved to
-- "Madison Square Garden Tour Experience" -- the hub holds the tour, not the
-- game, at that venue and date. Multi-event venues make venue+date a non-key,
-- exactly as it was for the direct-events tier. Tier 0 therefore requires the
-- same >=0.6 token overlap the name tier uses.
--
-- Tier order, strongest first; each only fills rows still NULL, so a stronger
-- tier is never overwritten by a weaker one:
--   tier 0  hub: canonical venue + date + name overlap    conf 0.95
--   tier 1  events: canonical venue + equal local date    conf 0.90
--   tier 2  events: name overlap + equal local date       conf 0.75
CREATE OR REPLACE FUNCTION public.s4k_orders_map_events(p_max integer DEFAULT 5000)
RETURNS TABLE(tier text, mapped integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE n0 int := 0; n1 int := 0; n2 int := 0; nb int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 's4k_orders_map_events: caller % not authorized', current_user;
  END IF;

  -- ── Tier 0: the AQ hub, name-guarded ─────────────────────────────────────
  WITH cand AS (
    SELECT o.source, o.order_id, min(a.tevo_event_id) AS ev, count(DISTINCT a.tevo_event_id) AS n
      FROM public.s4k_marketplace_orders o
      JOIN public.aq_event_map a
        ON a.tevo_event_id IS NOT NULL
       AND lower(regexp_replace(coalesce(a.venue_name,''), '[^a-z0-9]+','','gi'))
         = lower(regexp_replace(coalesce(o.venue_name,''), '[^a-z0-9]+','','gi'))
       AND a.event_date::date = o.event_date
       AND (SELECT count(*) FROM unnest(string_to_array(
                   lower(regexp_replace(coalesce(o.event_name,''), '[^a-z0-9 ]+',' ','gi')), ' ')) t(tok)
             WHERE length(t.tok) >= 4
               AND lower(coalesce(a.event_name,'')) LIKE '%' || t.tok || '%')::numeric
           / nullif((SELECT count(*) FROM unnest(string_to_array(
                   lower(regexp_replace(coalesce(o.event_name,''), '[^a-z0-9 ]+',' ','gi')), ' ')) t2(tok)
             WHERE length(t2.tok) >= 4), 0) >= 0.6
     WHERE o.tevo_event_id IS NULL
       AND coalesce(o.venue_name,'') <> ''
       AND coalesce(o.event_name,'') <> ''
       AND o.event_date IS NOT NULL
     GROUP BY o.source, o.order_id
     LIMIT p_max
  )
  UPDATE public.s4k_marketplace_orders o
     SET tevo_event_id = c.ev, map_method = 'aq_hub_v3',
         map_confidence = 0.95, mapped_at = now()
    FROM cand c
   WHERE o.source = c.source AND o.order_id = c.order_id
     AND o.tevo_event_id IS NULL AND c.n = 1;
  GET DIAGNOSTICS n0 = ROW_COUNT;
  tier := 'aq_hub'; mapped := n0; RETURN NEXT;

  -- ── Tier 1: direct events, canonical venue + equal local date ────────────
  WITH cand AS (
    SELECT o.source, o.order_id, min(e.id) AS ev, count(*) AS n
      FROM public.s4k_marketplace_orders o
      JOIN public.events e
        ON lower(regexp_replace(coalesce(e.venue_name,''), '[^a-z0-9]+','','gi'))
         = lower(regexp_replace(coalesce(o.venue_name,''), '[^a-z0-9]+','','gi'))
       AND e.occurs_at_local IS NOT NULL
       AND left(e.occurs_at_local, 10) = to_char(o.event_date, 'YYYY-MM-DD')
     WHERE o.tevo_event_id IS NULL
       AND coalesce(o.venue_name,'') <> ''
       AND o.event_date IS NOT NULL
     GROUP BY o.source, o.order_id
     LIMIT p_max
  )
  UPDATE public.s4k_marketplace_orders o
     SET tevo_event_id = c.ev, map_method = 'venue_date_v2',
         map_confidence = 0.90, mapped_at = now()
    FROM cand c
   WHERE o.source = c.source AND o.order_id = c.order_id
     AND o.tevo_event_id IS NULL AND c.n = 1;
  GET DIAGNOSTICS n1 = ROW_COUNT;
  tier := 'venue_date'; mapped := n1; RETURN NEXT;

  -- ── Tier 2: direct events, name overlap + equal local date ───────────────
  WITH toks AS (
    SELECT o.source, o.order_id, o.event_date, array_agg(DISTINCT t.tok) AS s4k_toks
      FROM public.s4k_marketplace_orders o,
           unnest(string_to_array(
             lower(regexp_replace(coalesce(o.event_name,''), '[^a-z0-9 ]+',' ','gi')), ' ')) t(tok)
     WHERE o.tevo_event_id IS NULL AND o.event_date IS NOT NULL
       AND coalesce(o.event_name,'') <> '' AND length(t.tok) >= 4
     GROUP BY o.source, o.order_id, o.event_date
     LIMIT p_max
  ), cand AS (
    SELECT k.source, k.order_id, min(e.id) AS ev, count(*) AS n
      FROM toks k
      JOIN public.events e
        ON e.occurs_at_local IS NOT NULL
       AND left(e.occurs_at_local, 10) = to_char(k.event_date, 'YYYY-MM-DD')
       AND (SELECT count(*) FROM unnest(k.s4k_toks) x(tok)
             WHERE lower(coalesce(e.name,'')) LIKE '%' || x.tok || '%')::numeric
           / nullif(array_length(k.s4k_toks, 1), 0) >= 0.6
     GROUP BY k.source, k.order_id
  )
  UPDATE public.s4k_marketplace_orders o
     SET tevo_event_id = c.ev, map_method = 'name_date_v2',
         map_confidence = 0.75, mapped_at = now()
    FROM cand c
   WHERE o.source = c.source AND o.order_id = c.order_id
     AND o.tevo_event_id IS NULL AND c.n = 1;
  GET DIAGNOSTICS n2 = ROW_COUNT;
  tier := 'name_date'; mapped := n2; RETURN NEXT;

  -- ── Write-back: fill the hub's OWN gaps so this is done once ─────────────
  -- Additive only: never overwrites an existing hub tevo_event_id, and only
  -- writes where the S4K side agrees on a single event under the same
  -- name-guarded rule. This is a write to a shared cross-lane surface
  -- (AQ hub) made under explicit operator direction.
  WITH cand AS (
    SELECT a.id AS aq_id, min(o.tevo_event_id) AS ev, count(DISTINCT o.tevo_event_id) AS n
      FROM public.aq_event_map a
      JOIN public.s4k_marketplace_orders o
        ON lower(regexp_replace(coalesce(a.venue_name,''), '[^a-z0-9]+','','gi'))
         = lower(regexp_replace(coalesce(o.venue_name,''), '[^a-z0-9]+','','gi'))
       AND a.event_date::date = o.event_date
       AND (SELECT count(*) FROM unnest(string_to_array(
                   lower(regexp_replace(coalesce(o.event_name,''), '[^a-z0-9 ]+',' ','gi')), ' ')) t(tok)
             WHERE length(t.tok) >= 4
               AND lower(coalesce(a.event_name,'')) LIKE '%' || t.tok || '%')::numeric
           / nullif((SELECT count(*) FROM unnest(string_to_array(
                   lower(regexp_replace(coalesce(o.event_name,''), '[^a-z0-9 ]+',' ','gi')), ' ')) t2(tok)
             WHERE length(t2.tok) >= 4), 0) >= 0.6
     WHERE a.tevo_event_id IS NULL
       AND o.tevo_event_id IS NOT NULL
       AND coalesce(a.venue_name,'') <> ''
       AND coalesce(o.event_name,'') <> ''
     GROUP BY a.id
  )
  UPDATE public.aq_event_map a
     SET tevo_event_id = c.ev
    FROM cand c
   WHERE a.id = c.aq_id AND a.tevo_event_id IS NULL AND c.n = 1;
  GET DIAGNOSTICS nb = ROW_COUNT;
  tier := 'hub_writeback'; mapped := nb; RETURN NEXT;
END $function$;

REVOKE ALL ON FUNCTION public.s4k_orders_map_events(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4k_orders_map_events(integer) TO service_role;
;
