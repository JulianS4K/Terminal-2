-- ============================================================================
-- Migration 20260714270000 — WWE/AEW wrestling scaffold: news subs + promotions
--                            map + roster schema
--
-- Lane:     A1 data plane
-- Touches:  reddit_news_flairs (W: wrestling subs, keyword mode),
--           wrestling_promotions (W: new — promotion/brand → tevo event performer),
--           wrestling_roster (W: new — roster/health schema),
--           get_wrestling_roster (W: new RPC)
-- Pre-reqs: 20260626120030 + 20260714210000 (reddit keyword mode), events (R)
--
-- WHY: operator asked for WWE/AEW roster, health, and appearance status. ESPN does
--   NOT cover scripted wrestling, so there is no roster/injury feed today — only
--   the ticketed EVENTS (WWE Raw / SmackDown / SummerSlam / AEW) exist. This lays:
--     (1) News layer — r/SquaredCircle + r/WWE + r/AEWOfficial into the wire on
--         roster/health/appearance keywords (injury / return / released / signed /
--         advertised / pulled). Immediate, correct coverage of the *news*.
--     (2) wrestling_promotions — maps each promotion+brand to our Tevo event
--         performer (WWE Raw 68327 / SmackDown 51013 / PPV 30584 · AEW 69441) so
--         the weekly events group under a promotion.
--     (3) wrestling_roster + get_wrestling_roster — the roster/health table +
--         read RPC, ready to be populated by a VERIFIED live source (TheSportsDB
--         via pg_net, or the WWE/AEW Wikipedia personnel lists). Seeded EMPTY on
--         purpose — no fabricated 2026 roster. Automated ingestion is the next
--         step once a source is confirmed from prod pg_net.
--
-- Read-only upstream (RULE 2): reddit GET only.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Wrestling news subs — keyword mode (these subs have no clean News flair;
--     the keyword targets exactly the roster/health/appearance signals).
-- ----------------------------------------------------------------------------
INSERT INTO reddit_news_flairs (subreddit, league, flair_query, search_query, enabled, notes)
VALUES
  ('SquaredCircle', 'Wrestling', 'News',
   'injured OR injury OR return OR released OR signed OR debut OR advertised OR "pulled from" OR "medically cleared"',
   true, 'WWE/AEW news hub — roster/health/appearance keyword search. Mig 20260714270000.'),
  ('WWE', 'Wrestling', 'News',
   'injured OR injury OR return OR released OR signed OR advertised OR "pulled from"',
   true, 'WWE sub — roster/health/appearance keyword search. Mig 20260714270000.'),
  ('AEWOfficial', 'Wrestling', 'News',
   'injured OR injury OR return OR released OR signed OR advertised OR "pulled from"',
   true, 'AEW sub — roster/health/appearance keyword search. Mig 20260714270000.')
ON CONFLICT (subreddit) DO UPDATE
  SET search_query = EXCLUDED.search_query, enabled = EXCLUDED.enabled,
      league = EXCLUDED.league, notes = EXCLUDED.notes, updated_at = now();

-- ----------------------------------------------------------------------------
-- (2) Promotion → Tevo event-performer map (from the ticketing events).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wrestling_promotions (
  promotion         text NOT NULL,             -- 'WWE' | 'AEW'
  brand             text NOT NULL,             -- 'Raw' | 'SmackDown' | 'PPV' | 'AEW'
  tevo_performer_id bigint,                    -- the ticketing performer for this brand
  wiki_roster_title text,                      -- Wikipedia personnel-list page (for future ingest)
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (promotion, brand)
);
ALTER TABLE wrestling_promotions ENABLE ROW LEVEL SECURITY;

INSERT INTO wrestling_promotions (promotion, brand, tevo_performer_id, wiki_roster_title, notes) VALUES
  ('WWE', 'Raw',        68327, 'List of WWE personnel', 'WWE Monday Night Raw'),
  ('WWE', 'SmackDown',  51013, 'List of WWE personnel', 'WWE Friday Night SmackDown'),
  ('WWE', 'PPV',        30584, 'List of WWE personnel', 'WWE premium live events (SummerSlam / SNME)'),
  ('AEW', 'AEW',        69441, 'List of All Elite Wrestling personnel', 'AEW Dynamite / PPV')
ON CONFLICT (promotion, brand) DO UPDATE
  SET tevo_performer_id = EXCLUDED.tevo_performer_id, wiki_roster_title = EXCLUDED.wiki_roster_title,
      notes = EXCLUDED.notes;

COMMENT ON TABLE wrestling_promotions IS
  'Maps WWE/AEW promotion+brand to the Tevo event performer + Wikipedia personnel '
  'list. Mig 20260714270000.';

-- ----------------------------------------------------------------------------
-- (3) Roster / health table + read RPC. Populated by a future ingest (empty now
--     — no fabricated roster). status carries the health/appearance flag.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS wrestling_roster (
  wrestler_slug  text PRIMARY KEY,             -- normalized ring name
  ring_name      text NOT NULL,
  promotion      text,                         -- WWE | AEW
  brand          text,                         -- Raw | SmackDown | AEW | NXT | Free agent
  status         text,                         -- 'active' | 'injured' | 'suspended' | 'inactive'
  real_name      text,
  wiki_title     text,
  image_url      text,
  source         text,                         -- 'thesportsdb' | 'wikipedia' | 'manual'
  last_refreshed_at timestamptz,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS wrestling_roster_promo_idx ON wrestling_roster(promotion, brand);
CREATE INDEX IF NOT EXISTS wrestling_roster_status_idx ON wrestling_roster(status);
ALTER TABLE wrestling_roster ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE wrestling_roster IS
  'WWE/AEW roster + health (status) — populated by a verified live source '
  '(TheSportsDB via pg_net or the WWE/AEW Wikipedia personnel lists). Empty until '
  'ingest wired. Mig 20260714270000.';

CREATE OR REPLACE FUNCTION public.get_wrestling_roster(p_promotion text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp' AS $func$
DECLARE v_email text; v_rows jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.promotion, r.brand, r.ring_name), '[]'::jsonb)
  INTO v_rows FROM (
    SELECT ring_name, promotion, brand, status, image_url, wiki_title, last_refreshed_at
    FROM wrestling_roster
    WHERE p_promotion IS NULL OR promotion = p_promotion
  ) r;
  RETURN jsonb_build_object('roster', coalesce(v_rows,'[]'::jsonb));
END $func$;

REVOKE ALL ON FUNCTION public.get_wrestling_roster(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wrestling_roster(text) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_wrestling_roster(text) IS
  'WWE/AEW roster + health status for the terminal. Email-gated. Mig 20260714270000.';
