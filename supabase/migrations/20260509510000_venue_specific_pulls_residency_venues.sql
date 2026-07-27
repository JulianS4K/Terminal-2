-- ============================================================================
-- Migration 20260509510000 — Venue-specific event pulls (residency venues)
--
-- Why: TEvo's category-based pulls are popularity-sorted, so even with
-- 20 pages × 100 = 2000 events for category=54 (Concerts), niche but
-- high-priority residency venues like Sphere don't surface. Bruce
-- Springsteen at MSG also got missed for the same reason.
--
-- Solution: a parallel pull infrastructure keyed on venue_id. Seed
-- with known residency / high-value venues. Same async pattern
-- (queue + pending + process) as tournament_pull_queue.
--
-- Reuses tournament_category_pending table by storing venue-pulls
-- with negative category_id (= -venue_id) as a sentinel. Process
-- function is unchanged because the row shape is identical.
-- ============================================================================

CREATE TABLE IF NOT EXISTS venue_pulls (
  tevo_venue_id  bigint PRIMARY KEY,
  venue_label    text NOT NULL,
  reason         text,                     -- 'residency_venue' | 'major_arena' | 'broadway_anchor'
  pages_to_pull  int DEFAULT 3,
  enabled        boolean DEFAULT true,
  added_at       timestamptz DEFAULT now()
);

INSERT INTO venue_pulls(tevo_venue_id, venue_label, reason, pages_to_pull) VALUES
  (44984, 'Sphere',                       'residency_venue', 3),
  (896,   'Madison Square Garden',        'major_arena',     5),
  (1262,  'Hard Rock Stadium',            'major_arena',     2)
ON CONFLICT (tevo_venue_id) DO NOTHING;

COMMENT ON TABLE venue_pulls IS
  'Venues we pull individually because category-based pulls (popularity-'
  'sorted) miss them. Sphere / Caesars Palace / Dolby Live / Resorts World '
  'Theatre / BleauLive are residency venues; MSG is dense enough to need '
  'its own venue pull for visibility into Bruce / Phish / Billy Joel runs.';

-- ============================================================================
-- venue_pull_queue — fire signed GETs per venue, paginated
-- ============================================================================

CREATE OR REPLACE FUNCTION venue_pull_queue(p_max_pages int DEFAULT 25)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_token  text := get_app_secret('TEVO_API_TOKEN');
  v_secret text := get_app_secret('TEVO_SECRET');
  r RECORD; v_q text; v_sig text; v_req bigint; v_count int := 0;
BEGIN
  FOR r IN
    SELECT vp.tevo_venue_id, gs.page
    FROM venue_pulls vp
    JOIN LATERAL generate_series(1, vp.pages_to_pull) AS gs(page) ON true
    WHERE vp.enabled
      AND NOT EXISTS (
        SELECT 1 FROM tournament_category_pending p
        WHERE p.category_id = -vp.tevo_venue_id  -- sentinel: negative cat = venue pull
          AND p.page = gs.page
          AND p.fired_at > now() - interval '24 hours'
      )
    ORDER BY vp.tevo_venue_id, gs.page
    LIMIT p_max_pages
  LOOP
    v_q := 'occurs_at.gte=' || to_char(current_date, 'YYYY-MM-DD')
        || '&page=' || r.page
        || '&per_page=100'
        || '&venue_id=' || r.tevo_venue_id;
    v_sig := tevo_sign_get('/v9/events', v_q, v_secret);
    SELECT net.http_get(
      url := 'https://api.ticketevolution.com/v9/events?' || v_q,
      headers := jsonb_build_object('X-Token', v_token, 'X-Signature', v_sig,
        'Accept', 'application/vnd.ticketevolution.api+json; version=9'),
      timeout_milliseconds := 25000) INTO v_req;
    INSERT INTO tournament_category_pending(category_id, page, request_id, fired_at)
    VALUES (-r.tevo_venue_id, r.page, v_req, now());
    v_count := v_count + 1;
    PERFORM pg_sleep(0.4);
  END LOOP;
  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION venue_pull_queue IS
  'Fires signed /v9/events?venue_id=X pulls for each enabled venue in '
  'venue_pulls table. Uses tournament_category_pending with negative '
  'category_id sentinel so the existing tournament_pull_process picks '
  'these up unchanged. Paginated; weekly cron.';

-- ============================================================================
-- Cron: weekly + slightly offset from category pulls
-- ============================================================================

SELECT cron.schedule(
  'venue_pull_queue_weekly',
  '15 4 * * 0',    -- Sundays 04:15 UTC (after category queue 04:00 + process 04:05)
  $$ SELECT venue_pull_queue(25); $$
);
