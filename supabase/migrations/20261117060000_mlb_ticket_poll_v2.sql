-- Migration 20261117060000 · level:data-collection · lane:A1 (data plane — MLB schedule) · writes:mlb_ticket_config(new),mlb_ticket_change(new),mlb_ticket_promotion(new),mlb_ticket_event(new),mlb_ticket_game(+removed_at),mlb_ticket_tick(),mlb_ticket_match_events()(new),mlb_ticket_alert_tick()(new),v_mlb_schedule_feed,v_mlb_ticket_changes(new),v_mlb_stadium_events(new),cron:mlb_ticket_alert_hourly · reads:net._http_response,events,n2s_autobuy_config,vault.decrypted_secrets · pre:20261116230000
--
-- MLB ticketing poller v2 (operator 2026-11-17: "build something that goes in and polls the site
-- for updates" → faster refresh, change log + alerts, promotions & giveaways, ticket prices;
-- "include non_games where it's a concert or live event").
--
-- WHAT THE SOURCE RETURNS (checked 2026-11-17, all 30 MLB clubs, 2027): per club, its home games
-- (teams, times, venue, status, the single-game ticket link + on-sale window) — already collected
-- since 20261116190000 — plus two things the collector dropped:
--   * promotion[] per game: 320 offers on 259 games (Ticket Offer 74, Day of Game Highlight 64,
--     Theme Days 33, Fireworks/Drone 24, Giveaways: apparel 21, bobblehead 16, hat 10, misc 12 …),
--     each with offer_id, offer_name, description, presented_by, distribution, links, image.
--   * non_game[]: 2,212 stadium events — mostly ballpark tours (type B), but type O / A carry the
--     live events: concerts (Noah Kahan), Monster Jam, Supercross, rodeo, the All-Star Home Run
--     Derby. These have no ticket link in the feed; they are matched to their EVO event instead.
--   * No prices: no price field on any game or offer for any club (mlb.com fills its "Starting at"
--     label only once single-game sales open). Prices are therefore not collected here.
--
-- WHAT CHANGES
--   * Cadence: MLB clubs re-read every 2 h (was 11 h), minor league clubs every 4 h
--     (mlb_ticket_config). A tick now lands every finished read and fires up to 3 due ones.
--   * Change log mlb_ticket_change: every add / change / removal of a game (link went live,
--     link changed, date, time, venue, status, on-sale date set or moved, dropped from the
--     schedule), new promotions and new stadium events, with old → new values. `notable` marks what
--     the digest sends (a club's first load and plain "game added" rows are not notable).
--   * Games no longer in a club's schedule are marked removed_at (logged), not deleted.
--   * mlb_ticket_promotion: every offer per game (kept current; removed_at when it disappears).
--   * mlb_ticket_event: the concerts / live events (non_game types O and A, without parking,
--     tours, rentals, VIP / batting-practice extras), matched to an EVO event at the same venue on
--     the same day when exactly one exists.
--   * Alerts: mlb_ticket_alert_tick() (cron hourly at :17) e-mails one digest of the notable
--     changes not yet sent, through the Resend key and the N2S alert recipients
--     (n2s_autobuy_config) unless mlb_ticket_config.alert_email_to is set. Switch:
--     mlb_ticket_config.alerts_enabled.
--   * Feed: v_mlb_schedule_feed adds `removed` and `promotions` at the end; new views
--     v_mlb_ticket_changes and v_mlb_stadium_events (served by the sub finder API).
-- Read-only toward MLB (the same public GET); the only POST is our own alert e-mail (Resend).

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE TABLE IF NOT EXISTS public.mlb_ticket_config (
  id               boolean PRIMARY KEY DEFAULT true CHECK (id),
  mlb_refresh      interval NOT NULL DEFAULT interval '2 hours',
  milb_refresh     interval NOT NULL DEFAULT interval '4 hours',
  fires_per_tick   integer  NOT NULL DEFAULT 3 CHECK (fires_per_tick BETWEEN 1 AND 10),
  alerts_enabled   boolean  NOT NULL DEFAULT true,
  alert_email_to   text[],
  updated_at       timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.mlb_ticket_config DEFAULT VALUES ON CONFLICT DO NOTHING;

ALTER TABLE public.mlb_ticket_game ADD COLUMN IF NOT EXISTS removed_at timestamptz;

CREATE TABLE IF NOT EXISTS public.mlb_ticket_change (
  id           bigserial PRIMARY KEY,
  entity       text NOT NULL CHECK (entity IN ('game', 'event', 'promotion')),
  schedule_id  bigint NOT NULL,
  kind         text NOT NULL,
  old_value    text,
  new_value    text,
  notable      boolean NOT NULL DEFAULT false,
  detected_at  timestamptz NOT NULL DEFAULT now(),
  alerted_at   timestamptz
);
CREATE INDEX IF NOT EXISTS mlb_ticket_change_detected_idx ON public.mlb_ticket_change (detected_at);
CREATE INDEX IF NOT EXISTS mlb_ticket_change_unalerted_idx ON public.mlb_ticket_change (detected_at)
  WHERE notable AND alerted_at IS NULL;
CREATE INDEX IF NOT EXISTS mlb_ticket_change_sched_idx ON public.mlb_ticket_change (schedule_id);

CREATE TABLE IF NOT EXISTS public.mlb_ticket_promotion (
  schedule_id      bigint NOT NULL,
  offer_id         text   NOT NULL,
  offer_type       text,
  promotion_types  text,
  offer_name       text,
  description      text,
  presented_by     text,
  distribution     text,
  link_url         text,
  info_url         text,
  image_url        text,
  first_seen_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at     timestamptz NOT NULL DEFAULT now(),
  removed_at       timestamptz,
  PRIMARY KEY (schedule_id, offer_id)
);

CREATE TABLE IF NOT EXISTS public.mlb_ticket_event (
  schedule_id        bigint PRIMARY KEY,
  team_id            integer,
  sport_id           integer,
  season             integer,
  event_type         text,
  title              text,
  descr              text,
  event_date         date,
  event_time_local   timestamp,
  time_zone_local    text,
  event_time_utc     timestamptz,
  is_tbd             boolean,
  multi_day          boolean,
  venue_id           integer,
  venue_name         text,
  venue_city         text,
  venue_postal_code  text,
  ticket_link_raw    text,
  ticket_url         text,
  tevo_event_id      bigint,
  tevo_match_method  text,
  tevo_matched_at    timestamptz,
  raw                jsonb,
  first_seen_at      timestamptz NOT NULL DEFAULT now(),
  last_seen_at       timestamptz NOT NULL DEFAULT now(),
  changed_at         timestamptz NOT NULL DEFAULT now(),
  removed_at         timestamptz
);
CREATE INDEX IF NOT EXISTS mlb_ticket_event_date_idx ON public.mlb_ticket_event (event_date);

ALTER TABLE public.mlb_ticket_config    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mlb_ticket_change    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mlb_ticket_promotion ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mlb_ticket_event     ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mlb_ticket_config, public.mlb_ticket_change, public.mlb_ticket_promotion,
              public.mlb_ticket_event FROM anon, authenticated;
GRANT SELECT ON public.mlb_ticket_config, public.mlb_ticket_change, public.mlb_ticket_promotion,
                public.mlb_ticket_event TO service_role;

-- change log for games: every insert / field change on mlb_ticket_game
CREATE OR REPLACE FUNCTION public.mlb_ticket_game_log()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE c record;
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO mlb_ticket_change (entity, schedule_id, kind, new_value, notable)
    VALUES ('game', NEW.schedule_id, 'added', NEW.game_date::text, false);
    RETURN NEW;
  END IF;
  FOR c IN
    SELECT * FROM (VALUES
      (CASE WHEN OLD.ticket_url IS NULL AND NEW.ticket_url IS NOT NULL THEN 'link_live'
            WHEN OLD.ticket_url IS NOT NULL AND NEW.ticket_url IS NULL THEN 'link_removed'
            WHEN OLD.ticket_url <> NEW.ticket_url THEN 'link_changed' END,
       OLD.ticket_url, NEW.ticket_url),
      (CASE WHEN OLD.game_date IS DISTINCT FROM NEW.game_date THEN 'date_changed' END,
       OLD.game_date::text, NEW.game_date::text),
      (CASE WHEN OLD.game_date IS NOT DISTINCT FROM NEW.game_date
             AND (OLD.game_time_local, OLD.is_tbd) IS DISTINCT FROM (NEW.game_time_local, NEW.is_tbd)
            THEN 'time_changed' END,
       CASE WHEN OLD.is_tbd THEN 'TBD' ELSE OLD.game_time_local::text END,
       CASE WHEN NEW.is_tbd THEN 'TBD' ELSE NEW.game_time_local::text END),
      (CASE WHEN OLD.venue_id IS DISTINCT FROM NEW.venue_id THEN 'venue_changed' END,
       OLD.venue_name, NEW.venue_name),
      (CASE WHEN OLD.status IS DISTINCT FROM NEW.status THEN 'status_changed' END,
       OLD.status, NEW.status),
      (CASE WHEN OLD.on_sale_start IS NULL AND NEW.on_sale_start IS NOT NULL THEN 'on_sale_set'
            WHEN OLD.on_sale_start IS DISTINCT FROM NEW.on_sale_start THEN 'on_sale_changed' END,
       OLD.on_sale_start::text, NEW.on_sale_start::text),
      (CASE WHEN OLD.removed_at IS NULL AND NEW.removed_at IS NOT NULL THEN 'removed'
            WHEN OLD.removed_at IS NOT NULL AND NEW.removed_at IS NULL THEN 'restored' END,
       NULL, NULL)
    ) v(kind, o, n) WHERE v.kind IS NOT NULL
  LOOP
    -- a status flip on game day is the game being played (scheduled → in progress → final), not news;
    -- on a future game it is a postponement / cancellation
    INSERT INTO mlb_ticket_change (entity, schedule_id, kind, old_value, new_value, notable)
    VALUES ('game', NEW.schedule_id, c.kind, c.o, c.n,
            c.kind <> 'status_changed' OR NEW.game_date > current_date);
  END LOOP;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS mlb_ticket_game_log ON public.mlb_ticket_game;
CREATE TRIGGER mlb_ticket_game_log AFTER INSERT OR UPDATE ON public.mlb_ticket_game
  FOR EACH ROW EXECUTE FUNCTION public.mlb_ticket_game_log();

-- change log for stadium events
CREATE OR REPLACE FUNCTION public.mlb_ticket_event_log()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO mlb_ticket_change (entity, schedule_id, kind, new_value, notable)
    VALUES ('event', NEW.schedule_id, 'event_added', NEW.title || ' · ' || NEW.event_date,
            -- a club's first load is not news
            EXISTS (SELECT 1 FROM mlb_ticket_event x WHERE x.team_id = NEW.team_id AND x.schedule_id <> NEW.schedule_id
                       AND x.first_seen_at < now() - interval '1 minute'));
    RETURN NEW;
  END IF;
  IF OLD.event_date IS DISTINCT FROM NEW.event_date OR OLD.event_time_local IS DISTINCT FROM NEW.event_time_local THEN
    INSERT INTO mlb_ticket_change (entity, schedule_id, kind, old_value, new_value, notable)
    VALUES ('event', NEW.schedule_id, 'event_moved', OLD.event_time_local::text, NEW.event_time_local::text, true);
  END IF;
  IF OLD.removed_at IS NULL AND NEW.removed_at IS NOT NULL THEN
    INSERT INTO mlb_ticket_change (entity, schedule_id, kind, old_value, notable)
    VALUES ('event', NEW.schedule_id, 'event_removed', NEW.title, true);
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS mlb_ticket_event_log ON public.mlb_ticket_event;
CREATE TRIGGER mlb_ticket_event_log AFTER INSERT OR UPDATE ON public.mlb_ticket_event
  FOR EACH ROW EXECUTE FUNCTION public.mlb_ticket_event_log();

-- EVO event for each stadium event: the one EVO event at that ballpark on that local day
CREATE OR REPLACE FUNCTION public.mlb_ticket_match_events(p_team integer DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_n integer;
BEGIN
  WITH todo AS (
    SELECT ev.schedule_id, ev.event_date,
           btrim(lower(regexp_replace(ev.venue_name,
             '\s*\m(stadium|park|field|ballpark|ball park|center|centre|grounds)\M.*$', '', 'i'))) AS vkey
      FROM mlb_ticket_event ev
     WHERE ev.tevo_event_id IS NULL AND ev.removed_at IS NULL AND ev.event_date >= current_date
       AND coalesce(ev.venue_name, '') <> ''
       AND (p_team IS NULL OR ev.team_id = p_team)),
  cand AS (
    SELECT t.schedule_id, e.id, count(*) OVER (PARTITION BY t.schedule_id) AS n
      FROM todo t
      JOIN events e ON left(e.occurs_at_local, 10) = t.event_date::text
                   AND t.vkey <> '' AND strpos(lower(e.venue_name), t.vkey) > 0
                   AND coalesce(e.state, 'shown') <> 'ignored')
  UPDATE mlb_ticket_event ev
     SET tevo_event_id = c.id, tevo_match_method = 'venue_date', tevo_matched_at = now(), changed_at = now()
    FROM cand c
   WHERE c.schedule_id = ev.schedule_id AND c.n = 1
     AND NOT EXISTS (SELECT 1 FROM mlb_ticket_game g WHERE g.tevo_event_id = c.id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION public.mlb_ticket_tick()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $function$
DECLARE
  cfg       public.mlb_ticket_config;
  s         public.mlb_ticket_sync;
  r         record;
  j         jsonb;
  v_rows    int;
  v_err     text;
  v_sport   int;
  v_prior   boolean;
  v_landed  int := 0;
  v_errors  int := 0;
  v_waiting int := 0;
  v_fired   int := 0;
  v_now     timestamp := now() AT TIME ZONE 'America/New_York';
  v_year    int := extract(year FROM v_now)::int;
  v_seasons int[];
BEGIN
  SELECT * INTO cfg FROM public.mlb_ticket_config;
  -- seasons that still have games: this one until 31 October, and the next
  v_seasons := CASE WHEN extract(month FROM v_now) >= 11 THEN ARRAY[v_year + 1] ELSE ARRAY[v_year, v_year + 1] END;
  INSERT INTO public.mlb_ticket_sync (team_id, season)
  SELECT t.team_id, y FROM public.mlb_ticket_team t CROSS JOIN unnest(v_seasons) y
   WHERE t.active
  ON CONFLICT DO NOTHING;

  -- 1. land every read whose answer is back
  FOR s IN SELECT * FROM public.mlb_ticket_sync WHERE pending_request_id IS NOT NULL
            ORDER BY pending_since FOR UPDATE SKIP LOCKED
  LOOP
    SELECT x.status_code, x.content INTO r FROM net._http_response x WHERE x.id = s.pending_request_id;
    IF NOT FOUND THEN
      IF s.pending_since > now() - interval '3 minutes' THEN
        v_waiting := v_waiting + 1;
        CONTINUE;
      END IF;
      r := NULL;
    END IF;
    j := CASE WHEN r IS NOT NULL THEN public.safe_jsonb(r.content) END;
    IF r IS NULL OR r.status_code IS DISTINCT FROM 200 OR j->'events' IS NULL OR j->'events' ? 'error' THEN
      v_err := format('http %s %s', coalesce(r.status_code::text, 'lost'), left(coalesce(r.content, ''), 200));
      UPDATE public.mlb_ticket_sync
         SET pending_request_id = NULL, tries = tries + 1, last_error = v_err, last_error_at = now()
       WHERE team_id = s.team_id AND season = s.season;
      v_errors := v_errors + 1;
      CONTINUE;
    END IF;

    SELECT sport_id INTO v_sport FROM public.mlb_ticket_team WHERE team_id = s.team_id;

    -- 1a. games
    WITH items AS (
      SELECT g FROM jsonb_array_elements(
               CASE jsonb_typeof(j->'events'->'game') WHEN 'array' THEN j->'events'->'game'
                    WHEN 'object' THEN jsonb_build_array(j->'events'->'game') ELSE '[]'::jsonb END) g
       WHERE (g->>'schedule_id') ~ '^\d+$'),
    links AS (
      SELECT i.g,
             (SELECT tl FROM jsonb_array_elements(CASE jsonb_typeof(i.g->'ticket_link') WHEN 'array' THEN i.g->'ticket_link'
                                               WHEN 'object' THEN jsonb_build_array(i.g->'ticket_link') ELSE '[]'::jsonb END) tl
               WHERE coalesce(tl->>'tlink', '') <> ''
               ORDER BY (public.mlb_ticket_direct_url(tl->>'tlink') IS NOT NULL) DESC,
                        (upper(coalesce(tl->>'ticket_category', '')) = 'TICKETS') DESC LIMIT 1) AS tl
        FROM items i),
    parsed AS (
      SELECT l.g, l.tl, l.tl->>'tlink' AS raw_link,
             (l.g->>'tbd_flag') = 'Y' AS tbd,
             CASE WHEN l.g->>'game_date' ~ '^\d{4}-\d\d-\d\d$' THEN (l.g->>'game_date')::date END AS gdate,
             CASE WHEN l.g->>'game_time_local' ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN (l.g->>'game_time_local')::timestamp END AS tlocal,
             CASE WHEN l.g->>'game_time' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                  THEN to_timestamp(l.g->>'game_time', 'YYYYMMDD HH12:MI:SS AM')::timestamp AT TIME ZONE 'UTC' END AS tutc
        FROM links l)
    INSERT INTO public.mlb_ticket_game AS t (
      schedule_id, mlb_game_id, season, sport_id, game_type, game_type_name, game_date, game_time_local, time_zone_local,
      game_time_utc, is_tbd, game_number, if_necessary, status, descr, home_team_id, home_name, home_abbrev,
      away_team_id, away_name, away_abbrev, venue_id, venue_name, venue_city, venue_postal_code,
      ticket_link_raw, ticket_url, ticket_url_kind, on_sale_start, on_sale_end, raw, last_seen_at, changed_at)
    SELECT (p.g->>'schedule_id')::bigint, p.g->>'game_id',
           coalesce(extract(year FROM p.gdate)::int, s.season), coalesce(v_sport, 1),
           p.g->>'game_type', p.g->>'gt_name_short',
           p.gdate, p.tlocal, p.g->>'time_zone_local', p.tutc, p.tbd,
           CASE WHEN p.g->>'game_number' ~ '^\d+$' THEN (p.g->>'game_number')::int END,
           (p.g->>'if_necessary') = 'Y', p.g->>'status', nullif(p.g->>'descr', ''),
           CASE WHEN p.g->>'home_team_id' ~ '^\d+$' THEN (p.g->>'home_team_id')::int END,
           p.g->>'home_name_full', p.g->>'home_name_abbrev',
           CASE WHEN p.g->>'away_team_id' ~ '^\d+$' THEN (p.g->>'away_team_id')::int END,
           p.g->>'away_name_full', p.g->>'away_name_abbrev',
           CASE WHEN p.g->>'venue_id' ~ '^\d+$' THEN (p.g->>'venue_id')::int END,
           p.g->>'venue_name', p.g->>'venue_city', p.g->>'venue_postal_code',
           p.raw_link, public.mlb_ticket_direct_url(p.raw_link),
           CASE WHEN p.raw_link IS NULL THEN NULL
                WHEN public.mlb_ticket_direct_url(p.raw_link) IS NOT NULL THEN 'direct' ELSE 'redirect' END,
           CASE WHEN p.tl->>'on_sale_start_date' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                THEN to_timestamp(p.tl->>'on_sale_start_date', 'YYYYMMDD HH12:MI:SS AM')::timestamp END,
           CASE WHEN p.tl->>'on_sale_end_date' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                THEN to_timestamp(p.tl->>'on_sale_end_date', 'YYYYMMDD HH12:MI:SS AM')::timestamp END,
           p.g - 'promotion', now(), now()
      FROM parsed p
    ON CONFLICT (schedule_id) DO UPDATE SET
      mlb_game_id = EXCLUDED.mlb_game_id, season = EXCLUDED.season, sport_id = EXCLUDED.sport_id,
      game_type = EXCLUDED.game_type,
      game_type_name = EXCLUDED.game_type_name, game_date = EXCLUDED.game_date,
      game_time_local = EXCLUDED.game_time_local, time_zone_local = EXCLUDED.time_zone_local,
      game_time_utc = EXCLUDED.game_time_utc, is_tbd = EXCLUDED.is_tbd, game_number = EXCLUDED.game_number,
      if_necessary = EXCLUDED.if_necessary, status = EXCLUDED.status, descr = EXCLUDED.descr,
      home_team_id = EXCLUDED.home_team_id, home_name = EXCLUDED.home_name, home_abbrev = EXCLUDED.home_abbrev,
      away_team_id = EXCLUDED.away_team_id, away_name = EXCLUDED.away_name, away_abbrev = EXCLUDED.away_abbrev,
      venue_id = EXCLUDED.venue_id, venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city,
      venue_postal_code = EXCLUDED.venue_postal_code,
      ticket_link_raw = EXCLUDED.ticket_link_raw, ticket_url = EXCLUDED.ticket_url, ticket_url_kind = EXCLUDED.ticket_url_kind,
      on_sale_start = EXCLUDED.on_sale_start, on_sale_end = EXCLUDED.on_sale_end, raw = EXCLUDED.raw,
      last_seen_at = now(), removed_at = NULL,
      changed_at = CASE WHEN (t.game_date, t.game_time_local, t.game_time_utc, t.is_tbd, t.game_number, t.status,
                              t.home_team_id, t.away_team_id, t.venue_id, t.ticket_url, t.on_sale_start, t.game_type)
                             IS DISTINCT FROM
                             (EXCLUDED.game_date, EXCLUDED.game_time_local, EXCLUDED.game_time_utc, EXCLUDED.is_tbd,
                              EXCLUDED.game_number, EXCLUDED.status, EXCLUDED.home_team_id, EXCLUDED.away_team_id,
                              EXCLUDED.venue_id, EXCLUDED.ticket_url, EXCLUDED.on_sale_start, EXCLUDED.game_type)
                             OR t.removed_at IS NOT NULL
                        THEN now() ELSE t.changed_at END,
      tevo_event_id     = CASE WHEN t.game_date IS DISTINCT FROM EXCLUDED.game_date THEN NULL ELSE t.tevo_event_id END,
      tevo_matched_at   = CASE WHEN t.game_date IS DISTINCT FROM EXCLUDED.game_date THEN NULL ELSE t.tevo_matched_at END,
      tevo_match_method = CASE WHEN t.game_date IS DISTINCT FROM EXCLUDED.game_date THEN NULL ELSE t.tevo_match_method END;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows > 0 THEN
      -- games of this club and season the schedule no longer lists
      UPDATE public.mlb_ticket_game g SET removed_at = now(), changed_at = now()
       WHERE g.home_team_id = s.team_id AND g.season = s.season AND g.removed_at IS NULL
         AND g.last_seen_at < now() AND g.game_date >= current_date;

      -- 1b. promotions (a club's first load is not news)
      v_prior := EXISTS (SELECT 1 FROM public.mlb_ticket_promotion p JOIN public.mlb_ticket_game g USING (schedule_id)
                          WHERE g.home_team_id = s.team_id);
      WITH promos AS (
        SELECT (g->>'schedule_id')::bigint AS sid, pr
          FROM jsonb_array_elements(
                 CASE jsonb_typeof(j->'events'->'game') WHEN 'array' THEN j->'events'->'game'
                      WHEN 'object' THEN jsonb_build_array(j->'events'->'game') ELSE '[]'::jsonb END) g,
               jsonb_array_elements(CASE jsonb_typeof(g->'promotion') WHEN 'array' THEN g->'promotion'
                                         WHEN 'object' THEN jsonb_build_array(g->'promotion') ELSE '[]'::jsonb END) pr
         WHERE (g->>'schedule_id') ~ '^\d+$' AND coalesce(pr->>'offer_id', '') <> ''),
      up AS (
        INSERT INTO public.mlb_ticket_promotion AS t (
          schedule_id, offer_id, offer_type, promotion_types, offer_name, description, presented_by,
          distribution, link_url, info_url, image_url)
        SELECT DISTINCT ON (sid, pr->>'offer_id')
               sid, pr->>'offer_id', nullif(pr->>'offer_type', ''), nullif(pr->>'promotion_types', ''),
               nullif(pr->>'offer_name', ''), nullif(pr->>'description', ''), nullif(pr->>'presented_by', ''),
               nullif(pr->>'distribution', ''), nullif(pr->>'tlink', ''), nullif(pr->>'alt_page_url', ''),
               nullif(nullif(pr->>'image_url', ''), 'undefined')
          FROM promos
        ON CONFLICT (schedule_id, offer_id) DO UPDATE SET
          offer_type = EXCLUDED.offer_type, promotion_types = EXCLUDED.promotion_types,
          offer_name = EXCLUDED.offer_name, description = EXCLUDED.description,
          presented_by = EXCLUDED.presented_by, distribution = EXCLUDED.distribution,
          link_url = EXCLUDED.link_url, info_url = EXCLUDED.info_url, image_url = EXCLUDED.image_url,
          last_seen_at = now(), removed_at = NULL
        RETURNING t.schedule_id, t.offer_type, t.offer_name, (xmax = 0) AS inserted)
      INSERT INTO public.mlb_ticket_change (entity, schedule_id, kind, new_value, notable)
      SELECT 'promotion', up.schedule_id, 'promo_added',
             coalesce(up.offer_type || ': ', '') || coalesce(up.offer_name, ''),
             v_prior AND up.offer_type IN ('Giveaway', 'Theme Days')
        FROM up WHERE up.inserted;

      UPDATE public.mlb_ticket_promotion p SET removed_at = now()
        FROM public.mlb_ticket_game g
       WHERE g.schedule_id = p.schedule_id AND g.home_team_id = s.team_id AND g.season = s.season
         AND p.removed_at IS NULL AND p.last_seen_at < now();
    END IF;

    -- 1c. stadium live events: non_game types O and A, without parking / tours / rentals / extras
    WITH ng AS (
      SELECT x FROM jsonb_array_elements(
               CASE jsonb_typeof(j->'events'->'non_game') WHEN 'array' THEN j->'events'->'non_game'
                    WHEN 'object' THEN jsonb_build_array(j->'events'->'non_game') ELSE '[]'::jsonb END) x
       WHERE (x->>'schedule_id') ~ '^\d+$'
         AND x->>'event_type' IN ('O', 'A')
         AND coalesce(x->>'title', '') !~* '\m(parking|tours?|rentals?|wheelchair|batting practice|gameday experience|vip day|premium seating|tbd at tbd|clinic|camp)\M'),
    p AS (
      SELECT x,
             (SELECT tl->>'tlink' FROM jsonb_array_elements(CASE jsonb_typeof(x->'ticket_link') WHEN 'array' THEN x->'ticket_link'
                                       WHEN 'object' THEN jsonb_build_array(x->'ticket_link') ELSE '[]'::jsonb END) tl
               WHERE coalesce(tl->>'tlink', '') <> '' LIMIT 1) AS raw_link,
             CASE WHEN x->>'event_time_local' ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN (x->>'event_time_local')::timestamp END AS tlocal,
             CASE WHEN x->>'event_time' ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN (x->>'event_time')::timestamp AT TIME ZONE 'UTC' END AS tutc
        FROM ng)
    INSERT INTO public.mlb_ticket_event AS t (
      schedule_id, team_id, sport_id, season, event_type, title, descr, event_date, event_time_local,
      time_zone_local, event_time_utc, is_tbd, multi_day, venue_id, venue_name, venue_city, venue_postal_code,
      ticket_link_raw, ticket_url, raw, last_seen_at, changed_at)
    SELECT (p.x->>'schedule_id')::bigint, s.team_id, coalesce(v_sport, 1), coalesce(extract(year FROM p.tlocal)::int, s.season),
           p.x->>'event_type', nullif(p.x->>'title', ''), nullif(p.x->>'descr', ''), p.tlocal::date, p.tlocal,
           p.x->>'time_zone_local', p.tutc, (p.x->>'tbd_flag') = 'Y', (p.x->>'multi_day_switch') = 'Y',
           CASE WHEN p.x->>'venue_id' ~ '^\d+$' THEN (p.x->>'venue_id')::int END,
           p.x->>'venue_name', p.x->>'venue_city', p.x->>'venue_postal_code',
           p.raw_link, public.mlb_ticket_direct_url(p.raw_link), p.x, now(), now()
      FROM p
    ON CONFLICT (schedule_id) DO UPDATE SET
      event_type = EXCLUDED.event_type, title = EXCLUDED.title, descr = EXCLUDED.descr,
      event_date = EXCLUDED.event_date, event_time_local = EXCLUDED.event_time_local,
      time_zone_local = EXCLUDED.time_zone_local, event_time_utc = EXCLUDED.event_time_utc,
      is_tbd = EXCLUDED.is_tbd, multi_day = EXCLUDED.multi_day, venue_id = EXCLUDED.venue_id,
      venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city, venue_postal_code = EXCLUDED.venue_postal_code,
      ticket_link_raw = EXCLUDED.ticket_link_raw, ticket_url = EXCLUDED.ticket_url, raw = EXCLUDED.raw,
      last_seen_at = now(), removed_at = NULL,
      changed_at = CASE WHEN (t.event_date, t.event_time_local, t.title, t.ticket_url, t.venue_id)
                             IS DISTINCT FROM (EXCLUDED.event_date, EXCLUDED.event_time_local, EXCLUDED.title,
                                               EXCLUDED.ticket_url, EXCLUDED.venue_id)
                        THEN now() ELSE t.changed_at END,
      tevo_event_id = CASE WHEN t.event_date IS DISTINCT FROM EXCLUDED.event_date THEN NULL ELSE t.tevo_event_id END;

    IF v_rows > 0 THEN
      UPDATE public.mlb_ticket_event ev SET removed_at = now(), changed_at = now()
       WHERE ev.team_id = s.team_id AND ev.season = s.season AND ev.removed_at IS NULL
         AND ev.last_seen_at < now() AND ev.event_date >= current_date;
    END IF;

    UPDATE public.mlb_ticket_sync
       SET pending_request_id = NULL, tries = 0, last_ok_at = now(), last_games = v_rows, last_error = NULL
     WHERE team_id = s.team_id AND season = s.season;
    PERFORM public.mlb_ticket_match(NULL, s.team_id);
    PERFORM public.mlb_ticket_match_events(s.team_id);
    v_landed := v_landed + 1;
  END LOOP;

  -- once an hour: every upcoming game and stadium event, for EVO / SeatGeek events created since
  IF extract(minute FROM now()) = 30 THEN
    PERFORM public.mlb_ticket_match(NULL, NULL);
    PERFORM public.mlb_ticket_match_events(NULL);
  END IF;

  -- 2. fire the due reads: MLB clubs every mlb_refresh, minor league clubs every milb_refresh
  FOR s IN
    SELECT y.* FROM public.mlb_ticket_sync y JOIN public.mlb_ticket_team t USING (team_id)
     WHERE y.season = ANY (v_seasons) AND y.pending_request_id IS NULL
       AND (y.last_ok_at IS NULL
            OR y.last_ok_at < now() - CASE WHEN t.sport_id = 1 THEN cfg.mlb_refresh ELSE cfg.milb_refresh END)
       AND (y.last_error_at IS NULL OR y.last_error_at < now() - interval '30 minutes' OR y.last_ok_at > y.last_error_at)
     ORDER BY y.last_ok_at NULLS FIRST, (t.sport_id <> 1), y.team_id, y.season
     LIMIT coalesce(cfg.fires_per_tick, 3)
     FOR UPDATE OF y SKIP LOCKED
  LOOP
    PERFORM public.mlb_ticket_fire(s.team_id, s.season);
    v_fired := v_fired + 1;
  END LOOP;

  RETURN jsonb_build_object('landed', v_landed, 'errors', v_errors, 'waiting', v_waiting, 'fired', v_fired);
END $function$;

-- one e-mail digest of the notable changes not yet sent
CREATE OR REPLACE FUNCTION public.mlb_ticket_alert_tick()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  cfg    public.mlb_ticket_config;
  v_to   text[];
  v_from text;
  rk     text;
  v_ids  bigint[];
  v_text text;
  v_n    integer;
  resp   extensions.http_response;
  addr   text;
BEGIN
  SELECT * INTO cfg FROM public.mlb_ticket_config;
  IF NOT coalesce(cfg.alerts_enabled, false) THEN RETURN 0; END IF;
  SELECT coalesce(cfg.alert_email_to, a.email_to), a.email_from INTO v_to, v_from FROM public.n2s_autobuy_config a;
  SELECT max(decrypted_secret) FILTER (WHERE name = 'RESEND_API_KEY') INTO rk FROM vault.decrypted_secrets;
  IF rk IS NULL OR v_from IS NULL OR coalesce(cardinality(v_to), 0) = 0 THEN RETURN 0; END IF;

  SELECT array_agg(id ORDER BY detected_at), count(*) INTO v_ids, v_n
    FROM public.mlb_ticket_change WHERE notable AND alerted_at IS NULL;
  IF coalesce(v_n, 0) = 0 THEN RETURN 0; END IF;

  SELECT string_agg(line, E'\n' ORDER BY ord) INTO v_text FROM (
    SELECT row_number() OVER (ORDER BY c.kind, c.detected_at) AS ord,
           '• ' || replace(c.kind, '_', ' ') || ' — ' ||
           coalesce(g.away_abbrev || ' at ' || g.home_abbrev || ' ' || g.game_date,
                    ev.title || ' · ' || ev.venue_name || ' ' || ev.event_date,
                    'schedule ' || c.schedule_id) ||
           CASE WHEN c.old_value IS NOT NULL OR c.new_value IS NOT NULL
                THEN ': ' || coalesce(c.old_value, '—') || ' → ' || coalesce(c.new_value, '—') ELSE '' END AS line
      FROM public.mlb_ticket_change c
      LEFT JOIN public.mlb_ticket_game g ON c.entity IN ('game', 'promotion') AND g.schedule_id = c.schedule_id
      LEFT JOIN public.mlb_ticket_event ev ON c.entity = 'event' AND ev.schedule_id = c.schedule_id
     WHERE c.id = ANY (v_ids)
     ORDER BY c.kind, c.detected_at LIMIT 80) x;
  IF v_n > 80 THEN v_text := v_text || E'\n… and ' || (v_n - 80) || ' more (GET /api/v1/subs/mlb/changes).'; END IF;

  PERFORM set_config('http.timeout_msec', '5000', true);
  FOREACH addr IN ARRAY v_to LOOP
    BEGIN
      resp := extensions.http(('POST', 'https://api.resend.com/emails',
                ARRAY[extensions.http_header('Authorization', 'Bearer ' || rk)], 'application/json',
                jsonb_build_object('from', v_from, 'to', jsonb_build_array(addr),
                                   'subject', 'MLB tickets: ' || v_n || ' update' || CASE WHEN v_n = 1 THEN '' ELSE 's' END,
                                   'text', v_text)::text)::extensions.http_request);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END LOOP;
  UPDATE public.mlb_ticket_change SET alerted_at = now() WHERE id = ANY (v_ids);
  RETURN v_n;
END $$;

CREATE OR REPLACE VIEW public.v_mlb_schedule_feed
WITH (security_invoker = true) AS
WITH hub AS (   -- one hub row per TEvo event of a feed game, curated first; read once, hash-joined
  SELECT DISTINCT ON (a.tevo_event_id)
         a.tevo_event_id, a.aq_short_event_id, a.sg_event_id, a.sh_event_id, a.vivid_event_id,
         a.tm_event_id, a.gotickets_event_id
    FROM public.aq_event_map a
   WHERE a.tevo_event_id IN (SELECT m.tevo_event_id FROM public.mlb_ticket_game m
                              WHERE m.tevo_event_id IS NOT NULL AND m.game_date >= current_date - 1)
   ORDER BY a.tevo_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at NULLS LAST)
SELECT g.schedule_id                                         AS mlb_schedule_id,
       g.mlb_game_id,
       g.season,
       CASE g.game_type WHEN 'R' THEN 'regular' WHEN 'S' THEN 'spring' WHEN 'E' THEN 'exhibition'
                        WHEN 'F' THEN 'wild_card' WHEN 'D' THEN 'division_series'
                        WHEN 'L' THEN 'league_championship' WHEN 'W' THEN 'world_series'
                        ELSE lower(coalesce(g.game_type_name, g.game_type)) END AS game_type,
       g.game_date,
       CASE WHEN g.is_tbd THEN NULL ELSE g.game_time_local END AS start_local,
       g.time_zone_local                                     AS time_zone,
       CASE WHEN g.is_tbd THEN NULL ELSE g.game_time_utc END AS start_utc,
       g.is_tbd                                              AS time_tbd,
       g.game_number                                         AS doubleheader_game,
       g.if_necessary,
       g.status,
       g.descr                                               AS description,
       g.home_team_id, g.home_name, g.home_abbrev,
       g.away_team_id, g.away_name, g.away_abbrev,
       g.venue_id, g.venue_name, g.venue_city, g.venue_postal_code,
       g.ticket_url,
       CASE WHEN g.ticket_url IS NOT NULL THEN g.on_sale_start END AS on_sale_start_et,
       g.tevo_event_id,
       g.tevo_match_method,
       e.occurs_at_local                                     AS tevo_start_local,
       CASE WHEN g.tevo_event_id IS NULL THEN NULL
            WHEN e.occurs_at_local ~ 'T00:00(:00)?$' THEN 'evo_date_only'
            WHEN g.is_tbd THEN 'mlb_tbd'
            WHEN left(e.occurs_at_local, 16) = to_char(g.game_time_local, 'YYYY-MM-DD"T"HH24:MI') THEN 'same'
            ELSE 'differs' END                               AS tevo_time_check,
       hub.aq_short_event_id,
       coalesce(g.sg_event_id, hub.sg_event_id)              AS sg_event_id,
       hub.sh_event_id, hub.vivid_event_id, hub.tm_event_id, hub.gotickets_event_id,
       CASE WHEN g.tevo_event_id IS NOT NULL THEN '/terminal/event.html?event=' || g.tevo_event_id END AS terminal_path,
       g.changed_at,
       g.last_seen_at,
       sg.sg_url,
       CASE WHEN g.sg_event_id IS NOT NULL THEN g.sg_match_method
            WHEN hub.sg_event_id IS NOT NULL THEN 'hub' END  AS sg_match_method,
       g.sport_id,
       CASE g.sport_id WHEN 1 THEN 'mlb' WHEN 11 THEN 'aaa' WHEN 12 THEN 'aa'
                       WHEN 13 THEN 'high_a' WHEN 14 THEN 'single_a' END AS level,
       ht.league_name,
       ht.parent_org_name                                    AS parent_org,
       g.removed_at IS NOT NULL                              AS removed,
       pr.promotions
  FROM public.mlb_ticket_game g
  LEFT JOIN public.mlb_ticket_team ht ON ht.team_id = g.home_team_id
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'offer_id', p.offer_id, 'type', p.offer_type, 'kind', p.promotion_types, 'name', p.offer_name,
             'description', p.description, 'presented_by', p.presented_by, 'distribution', p.distribution,
             'link_url', p.link_url, 'info_url', p.info_url, 'image_url', p.image_url))
             ORDER BY p.offer_type, p.offer_name) AS promotions
      FROM public.mlb_ticket_promotion p
     WHERE p.schedule_id = g.schedule_id AND p.removed_at IS NULL) pr ON true
  LEFT JOIN public.events e ON e.id = g.tevo_event_id
  LEFT JOIN hub ON hub.tevo_event_id = g.tevo_event_id
  LEFT JOIN public.sg_events_canonical sg ON sg.sg_event_id = coalesce(g.sg_event_id, hub.sg_event_id)
 WHERE g.game_date >= current_date - 1;


CREATE OR REPLACE VIEW public.v_mlb_ticket_changes
WITH (security_invoker = true) AS
SELECT c.id AS change_id, c.entity, c.schedule_id AS mlb_schedule_id, c.kind, c.old_value, c.new_value,
       c.notable, c.detected_at,
       coalesce(g.season, ev.season)                               AS season,
       coalesce(g.game_date, ev.event_date)                        AS date,
       g.home_abbrev, g.away_abbrev, coalesce(g.home_team_id, ev.team_id) AS home_team_id,
       ev.title                                                    AS event_title,
       coalesce(g.venue_name, ev.venue_name)                       AS venue_name,
       CASE coalesce(g.sport_id, ev.sport_id) WHEN 1 THEN 'mlb' WHEN 11 THEN 'aaa' WHEN 12 THEN 'aa'
            WHEN 13 THEN 'high_a' WHEN 14 THEN 'single_a' END AS level,
       g.ticket_url, coalesce(g.tevo_event_id, ev.tevo_event_id)  AS tevo_event_id
  FROM public.mlb_ticket_change c
  LEFT JOIN public.mlb_ticket_game g ON c.entity IN ('game', 'promotion') AND g.schedule_id = c.schedule_id
  LEFT JOIN public.mlb_ticket_event ev ON c.entity = 'event' AND ev.schedule_id = c.schedule_id;

CREATE OR REPLACE VIEW public.v_mlb_stadium_events
WITH (security_invoker = true) AS
SELECT ev.schedule_id AS mlb_schedule_id, ev.season, ev.event_type, ev.title, ev.descr AS description,
       ev.event_date, CASE WHEN ev.is_tbd THEN NULL ELSE ev.event_time_local END AS start_local,
       ev.time_zone_local AS time_zone, CASE WHEN ev.is_tbd THEN NULL ELSE ev.event_time_utc END AS start_utc,
       ev.is_tbd AS time_tbd, ev.multi_day, ev.team_id AS home_team_id, t.abbrev AS home_abbrev,
       t.full_name AS home_name,
       CASE ev.sport_id WHEN 1 THEN 'mlb' WHEN 11 THEN 'aaa' WHEN 12 THEN 'aa'
            WHEN 13 THEN 'high_a' WHEN 14 THEN 'single_a' END AS level,
       ev.venue_id, ev.venue_name, ev.venue_city, ev.venue_postal_code, ev.ticket_url,
       ev.tevo_event_id, ev.tevo_match_method, e.name AS tevo_event_name,
       CASE WHEN ev.tevo_event_id IS NOT NULL THEN '/terminal/event.html?event=' || ev.tevo_event_id END AS terminal_path,
       ev.removed_at IS NOT NULL AS removed, ev.changed_at, ev.last_seen_at
  FROM public.mlb_ticket_event ev
  LEFT JOIN public.mlb_ticket_team t ON t.team_id = ev.team_id
  LEFT JOIN public.events e ON e.id = ev.tevo_event_id
 WHERE ev.event_date >= current_date - 1;

REVOKE ALL ON FUNCTION public.mlb_ticket_tick(), public.mlb_ticket_alert_tick(), public.mlb_ticket_match_events(integer),
                       public.mlb_ticket_game_log(), public.mlb_ticket_event_log()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mlb_ticket_tick(), public.mlb_ticket_alert_tick(), public.mlb_ticket_match_events(integer)
  TO service_role;
REVOKE ALL ON public.v_mlb_schedule_feed, public.v_mlb_ticket_changes, public.v_mlb_stadium_events
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_mlb_schedule_feed, public.v_mlb_ticket_changes, public.v_mlb_stadium_events TO service_role;

DO $$ BEGIN
  PERFORM cron.unschedule('mlb_ticket_alert_hourly') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'mlb_ticket_alert_hourly');
  PERFORM cron.schedule('mlb_ticket_alert_hourly', '17 * * * *', 'SELECT public.mlb_ticket_alert_tick();');
END $$;

COMMIT;

-- VERIFY (after ~1 h):
--   SELECT * FROM mlb_ticket_config;
--   SELECT t.sport_id, max(s.last_ok_at), min(s.last_ok_at) FROM mlb_ticket_sync s JOIN mlb_ticket_team t USING (team_id) GROUP BY 1;
--   SELECT entity, kind, notable, count(*) FROM mlb_ticket_change GROUP BY 1,2,3;
--   SELECT offer_type, count(*) FROM mlb_ticket_promotion GROUP BY 1;
--   SELECT title, event_date, venue_name, tevo_event_id FROM v_mlb_stadium_events ORDER BY event_date;
-- ROLLBACK: re-apply 20261116230000's mlb_ticket_tick and v_mlb_schedule_feed; DROP TRIGGER mlb_ticket_game_log,
--   mlb_ticket_event_log; SELECT cron.unschedule('mlb_ticket_alert_hourly'); DROP the new views, functions and tables.
