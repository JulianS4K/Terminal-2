-- Migration 20260703013500 · level:standard · lane:broadway (D3) · pre:20260703013000
--
-- Seed for the cast-run overlay (20260703013000_broadway_cast_run_pipeline).
--
-- Part A — broadway_show_ref: the full NY Broadway slate we currently track in
-- public.events (~32 shows across ~34 houses, discovered 2026-07-03). Resolution
-- is VENUE-ANCHORED: each Broadway house runs one show at a time, so the venue
-- pattern resolves the show reliably even though the source spells titles many
-- ways ("Wicked" vs "Wicked\t"; "SIX: The Musical" / "Six the Musical" / "SIX -
-- The Musical"). event_name_pattern is left NULL (resolve by venue alone) except
-- where a house has more than one distinct show in our data — Barrymore carries
-- a stale 2010 "Elling" one-off alongside Joe Turner, so that row keeps a name
-- guard. NY Broadway only (off-Broadway, concert houses, West End, and touring
-- productions are deliberately excluded). Price coverage is thin today (only Oh
-- Mary / Lyceum + The Lost Boys / Palace have snapshots) — enumerating the slate
-- now means the engine lights up per show automatically as A1's snapshot
-- coverage grows. Add a show here when we start tracking it.
--
-- Part B — broadway_cast_run: the fully-verified Mary Todd Lincoln timeline for
-- Oh, Mary! (10 stints across 7 billed stars — the "seven stars" the trade
-- press cites). Cross-checked across Playbill, BroadwayWorld, New York Theatre
-- Guide, Broadway.com, Variety. Multi-stint performers (Cole Escola, Tituss
-- Burgess, Jinkx Monsoon) get one row per engagement. Genuinely-uncertain
-- boundaries are left NULL with a note + reduced confidence rather than
-- invented. Known unverified gaps (Sep 27–Oct 14 2025; Feb 1–Apr 28 2026) are
-- likely dark/standby periods, not an 8th billed star.
--
-- Other shows' cast runs are added to this table as the curated feed grows —
-- this seed intentionally does the one show we can verify end-to-end.
--
-- RULE 1: authored file only; apply is Applier-gated (A1). Idempotent (ON
-- CONFLICT upserts) so re-apply is safe.

-- ============================================================================
-- Part A · broadway_show_ref — the tracked slate
-- ============================================================================

-- venue_name_pattern is the anchor; event_name_pattern stays NULL (venue-only)
-- except Barrymore, which needs a name guard to exclude the stale 2010 Elling.
INSERT INTO public.broadway_show_ref
  (show_slug, title, venue_name_pattern, event_name_pattern, city) VALUES
  ('oh-mary',              'Oh, Mary!',                                    '%Lyceum%',            NULL,           'New York'),
  ('chicago',              'Chicago: The Musical',                         '%Ambassador%',        NULL,           'New York'),
  ('joe-turner',           'Joe Turner''s Come and Gone',                  '%Barrymore%',         '%joe turner%', 'New York'),
  ('maybe-happy-ending',   'Maybe Happy Ending',                           '%Belasco%',           NULL,           'New York'),
  ('the-outsiders',        'The Outsiders',                                '%Bernard B. Jacobs%', NULL,           'New York'),
  ('proof',                'Proof',                                        '%Booth%',             NULL,           'New York'),
  ('cats-jellicle-ball',   'Cats: The Jellicle Ball',                      '%Broadhurst%',        NULL,           'New York'),
  ('great-gatsby',         'The Great Gatsby',                             '%Broadway Theatre%',  NULL,           'New York'),
  ('book-of-mormon',       'The Book of Mormon',                           '%Neill%',             NULL,           'New York'),
  ('buena-vista',          'Buena Vista Social Club',                      '%Schoenfeld%',        NULL,           'New York'),
  ('wicked',               'Wicked',                                       '%Gershwin%',          NULL,           'New York'),
  ('becky-shaw',           'Becky Shaw',                                   '%Helen Hayes%',       NULL,           'New York'),
  ('operation-mincemeat',  'Operation Mincemeat',                          '%John Golden%',       NULL,           'New York'),
  ('six',                  'SIX: The Musical',                             '%Lena Horne%',        NULL,           'New York'),
  ('two-strangers',        'Two Strangers (Carry a Cake Across New York)', '%Longacre%',          NULL,           'New York'),
  ('death-becomes-her',    'Death Becomes Her',                            '%Lunt%',              NULL,           'New York'),
  ('cursed-child',         'Harry Potter and the Cursed Child',            '%Lyric%',             NULL,           'New York'),
  ('stranger-things',      'Stranger Things: The First Shadow',            '%Marquis%',           NULL,           'New York'),
  ('every-brilliant-thing','Every Brilliant Thing',                        '%Hudson%',            NULL,           'New York'),
  ('lion-king',            'The Lion King',                                '%Minskoff%',          NULL,           'New York'),
  ('giant',                'Giant',                                        '%Music Box%',         NULL,           'New York'),
  ('schmigadoon',          'Schmigadoon!',                                 '%Nederlander%',       NULL,           'New York'),
  ('mj',                   'MJ: The Musical',                              '%Neil Simon%',        NULL,           'New York'),
  ('lost-boys',            'The Lost Boys',                                '%Palace%',            NULL,           'New York'),
  ('hamilton',             'Hamilton',                                     '%Richard Rodgers%',   NULL,           'New York'),
  ('the-balusters',        'The Balusters',                                '%Samuel J. Friedman%',NULL,           'New York'),
  ('and-juliet',           '& Juliet',                                     '%Sondheim%',          NULL,           'New York'),
  ('fallen-angels',        'Fallen Angels',                                '%Todd Haimes%',       NULL,           'New York'),
  ('dog-day-afternoon',    'Dog Day Afternoon',                            '%August Wilson%',     NULL,           'New York'),
  ('ragtime',              'Ragtime',                                      '%Vivian Beaumont%',   NULL,           'New York'),
  ('hadestown',            'Hadestown',                                    '%Walter Kerr%',       NULL,           'New York'),
  ('death-of-a-salesman',  'Death of a Salesman',                          '%Winter Garden%',     NULL,           'New York')
ON CONFLICT (show_slug) DO UPDATE
  SET title              = EXCLUDED.title,
      venue_name_pattern = EXCLUDED.venue_name_pattern,
      event_name_pattern = EXCLUDED.event_name_pattern,
      city               = EXCLUDED.city,
      last_seen_at       = now();

-- ============================================================================
-- Part B · broadway_cast_run — Oh, Mary! (role: Mary Todd Lincoln)
-- ============================================================================

INSERT INTO public.broadway_cast_run
  (show_slug, role, performer_name, engagement_seq, run_start, run_end,
   is_open, is_final_confirmed, source_name, source_url, confidence, note) VALUES
  ('oh-mary','Mary Todd Lincoln','Cole Escola',     1, DATE '2024-07-11', NULL,
     false, false, 'Playbill', 'https://playbill.com/', 0.60,
     'Opening run from 7/11/24; paused late 2024 during the Betty Gilpin cover — exact pause date unverified.'),
  ('oh-mary','Mary Todd Lincoln','Betty Gilpin',    1, NULL, DATE '2025-03-16',
     false, false, 'BroadwayWorld', 'https://www.broadwayworld.com/shows/Oh,-Mary!-334953/replacement-cast', 0.65,
     'Covered during the Escola hiatus through 3/16/25; start (~Dec 2024) unverified.'),
  ('oh-mary','Mary Todd Lincoln','Tituss Burgess',  1, DATE '2025-03-18', DATE '2025-04-06',
     false, true, 'New York Theatre Guide', 'https://www.newyorktheatreguide.com/theatre-news/news/tituss-burgess-to-return-to-oh-mary-broadway-cast-cole-escola-sets-departure', 0.85,
     'First 3-week engagement, 3/18–4/6/25.'),
  ('oh-mary','Mary Todd Lincoln','Cole Escola',     2, DATE '2025-04-08', DATE '2025-06-21',
     false, true, 'Variety', 'https://variety.com/2025/theater/news/oh-mary-cole-escola-return-april-tickets-1236319577/', 0.90,
     'Return engagement; final performance 6/21/25 (TickPick closing-night bar).'),
  ('oh-mary','Mary Todd Lincoln','Tituss Burgess',  2, DATE '2025-06-23', DATE '2025-08-02',
     false, true, 'Playbill', 'https://playbill.com/article/oh-mother-tituss-burgess-returns-to-oh-mary-on-broadway-june-23', 0.90,
     'Encore 6-week engagement; final 8/2/25 (TickPick closing-night bar).'),
  ('oh-mary','Mary Todd Lincoln','Jinkx Monsoon',   1, DATE '2025-08-04', DATE '2025-09-27',
     false, true, 'BroadwayWorld', 'https://www.broadwayworld.com/shows/Oh,-Mary!-334953/replacement-cast', 0.80,
     'First 8-week engagement, 8/4–9/27/25.'),
  ('oh-mary','Mary Todd Lincoln','Jane Krakowski',  1, DATE '2025-10-14', DATE '2026-01-04',
     false, true, 'New York Theatre Guide', 'https://www.newyorktheatreguide.com/', 0.80,
     'Announced 10/14–12/7/25, extended to final 1/4/26 (TickPick closing-night bar).'),
  ('oh-mary','Mary Todd Lincoln','Jinkx Monsoon',   2, DATE '2026-01-08', DATE '2026-02-01',
     false, true, 'Playbill', 'https://playbill.com/article/jinkx-monsoon-will-return-to-broadways-oh-mary-in-2026', 0.85,
     'Return; 30-performance run, final 2/1/26 (TickPick closing-night bar).'),
  ('oh-mary','Mary Todd Lincoln','Maya Rudolph',    1, DATE '2026-04-28', DATE '2026-07-05',
     false, true, 'Broadway.com', 'https://www.broadway.com/buzz/206816/maya-rudolph-will-star-as-mary-todd-lincoln-in-oh-mary-on-broadway/', 0.95,
     'Final performance 7/5/26 (TickPick closing-night bar). Overlaps our snapshot window — first show with live get-in coverage.'),
  ('oh-mary','Mary Todd Lincoln','Meg Stalter',     1, DATE '2026-07-06', DATE '2026-09-12',
     false, true, 'New York Theatre Guide', 'https://www.newyorktheatreguide.com/theatre-news/news/meg-stalter-to-make-broadway-debut-in-oh-mary-this-summer', 0.90,
     'Broadway debut; announced run 7/6–9/12/26.')
ON CONFLICT (show_slug, role, performer_name, engagement_seq) DO UPDATE
  SET run_start          = EXCLUDED.run_start,
      run_end            = EXCLUDED.run_end,
      is_open            = EXCLUDED.is_open,
      is_final_confirmed = EXCLUDED.is_final_confirmed,
      source_name        = EXCLUDED.source_name,
      source_url         = EXCLUDED.source_url,
      confidence         = EXCLUDED.confidence,
      note               = EXCLUDED.note,
      last_seen_at       = now();

-- ============================================================================
-- DONE.
-- ============================================================================
