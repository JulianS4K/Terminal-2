-- Three tour products at the Opry House leave the watch and the feed.
--
-- Operator, 2026-11-27: "always exclude, Opry Backstage Tour, VIP Daytime Tour, Women of
-- Country Tour events". These are the operator's own exclusions, the same list that already
-- carries Lakers home games, the Vegas Vanguards, Olivia Rodrigo, the Crypto.com VIP tours
-- and the Ryman tours; exclude_regex is absolute and drops a title from the watch AND the
-- feed, at every venue, keep_all included.
--
-- The titles were read from the export rather than typed from the request, which mattered:
-- the operator's POS lists the third one as "Women Of Country", but AXS titles it "Women of
-- Country Tour", so a literal "women of country tour" is what actually bites (axs_event_id
-- 1527865 confirmed). Current counts, all at Opry House, all upcoming and not gone:
--   Opry Backstage Tour    29
--   Women of Country Tour  29
--   VIP Daytime Tour       21
--
-- The tokens are the full titles, deliberately not a bare "backstage tour": that shorter
-- pattern would also take "National Landmark Backstage Tour" at The Auditorium (20 events),
-- "Ryman Guided Backstage Tour" and a Cirque Musica pre-show, none of which was asked for.
-- Verified before applying -- the three named titles match, and Grand Ole Opry, Opry Country
-- Christmas, Grand Ole Opry: Opry at the Ryman and the Auditorium tour all still pass.
-- "Ryman VIP Tour" and "Ryman Guided Backstage Tour" were already excluded by ^ryman .*\mtour.
--
-- EFFECT: all 79 are currently CATALOGUE rows (watch = false, published as not_polled) and
-- none is watched, so this removes 79 not_polled rows from the feed, frees no polling place
-- and changes no credit spend. It takes effect at the next axs_watch_fill (03:20Z daily);
-- axs_catalogue_fill applies the same rule, so they leave the catalogue too.

DO $surgery$
DECLARE
  v_old text; v_new text;
  v_tail CONSTANT text := '|^ryman .*\mtour)';
  v_add  CONSTANT text := '|opry backstage tour|vip daytime tour|women of country tour)';
BEGIN
  SELECT exclude_regex INTO v_old FROM public.axs_watch_config;
  IF v_old IS NULL THEN
    RAISE EXCEPTION 'axs_watch_config.exclude_regex is null -- refusing to guess at it';
  END IF;
  IF right(v_old, length(v_tail)) <> v_tail THEN
    RAISE EXCEPTION 'exclude_regex does not end in the expected Ryman-tour token; it reads %', v_old;
  END IF;
  IF v_old ~ 'opry backstage tour' THEN
    RAISE NOTICE 'already excluded; nothing to do';
    RETURN;
  END IF;

  -- the regex is one alternation group, so the new tokens go inside its closing paren
  v_new := left(v_old, length(v_old) - 1) || v_add;

  UPDATE public.axs_watch_config SET exclude_regex = v_new;

  -- read back: the three named titles are excluded, and the neighbours the operator did NOT
  -- name are not. A regex that matches nothing is the failure mode worth guarding here.
  SELECT exclude_regex INTO v_old FROM public.axs_watch_config;
  IF NOT ('Opry Backstage Tour' ~* v_old AND 'VIP Daytime Tour' ~* v_old
          AND 'Women of Country Tour' ~* v_old) THEN
    RAISE EXCEPTION 'read-back: one of the three named titles is not excluded by %', v_old;
  END IF;
  IF 'Grand Ole Opry' ~* v_old OR 'Opry Country Christmas' ~* v_old
     OR 'Grand Ole Opry: Opry at the Ryman' ~* v_old
     OR 'National Landmark Backstage Tour' ~* v_old THEN
    RAISE EXCEPTION 'read-back: the new pattern over-reaches onto a title that was not named: %', v_old;
  END IF;
END $surgery$;
