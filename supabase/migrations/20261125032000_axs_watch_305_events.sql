-- AXS watch: 200 -> 305 events, 26 more venues, and wrestling / bull riding / UFC / touring shows let in.
--
-- Operator 2026-11-25: "add events to get to 240k credits monthly", then "Include aew, pbr, wwe, ufc, and touring
-- shows like Disney, and forest hills stadium when it's in season, only axs as primary till our new limit" and
-- "use the crm sales book and seatgeek sales pipelines and vivid, evo, tickpick, and gotickets API to determine axs
-- sales by venue to rank".
--
-- Already applied to prod 2026-11-25 03:19 UTC (as plain statements, on the operator's word; this file is the record
-- and re-running it changes nothing): 105 events added, none retired, 305 watched.
--
-- Why 305: one read is one TicketsData credit and an event is read about once an hour (309 reads an hour for 305
-- events, inside the 316 an hour the reader has at its 75% pace target), so about 222,000 credits a month for the
-- watch, plus about 1,600 for the discovery feed and 600 to 14,000 for the match (its last three months), which is
-- 225,000 to 238,000 of the 250,000 pool.
--
-- What decides the list is unchanged (axs_watch_fill): AXS itself sells the event, it is on sale, its venue is
-- listed in axs_watch_venue, and its title passes the two rules in axs_watch_config. This file changes the data:
--   1. sports_keep_regex: a Sports event was kept only for the listed teams. AEW, PBR, WWE, UFC, Monster Jam, Hot
--      Wheels and Supercross are let in (the operator's list; Disney On Ice and the other family tours are not
--      Sports and always passed), and so are the BNP Paribas Open and the NFR, which the sales ranking put first
--      and eighth (below). The Harlem Globetrotters and Unrivaled stay out by the operator's earlier name rule.
--   2. Venues, ranked by our own sales on upcoming events AXS sells (the CRM book's six marketplaces plus our EVO
--      orders, by event, 2026-11-25): Indian Wells Tennis Garden 1,415 tickets on 22 sessions, then the watched
--      Toyota Center 470, T-Mobile Arena 461, Crypto.com Arena 70 and Red Rocks 54, then Thomas & Mack 18, United
--      Theater 14, Xcite Center 13, Peacock Theater 12, U.S. Bank Stadium 11; and by venue over the 13 months the
--      CRM book holds: U.S. Bank Stadium 993, Paycom Center 883, Sanford Stadium 310, Blue FCU Arena 155.
--      A quota is the venue's guaranteed places, soonest event first. Quota 0 means no guaranteed place: its
--      events take the places nobody else uses, soonest first (the backfill of mig 20261125023030), which is how
--      Forest Hills Stadium comes in as its season nears without holding places all winter.
--   3. Three watched venues' quotas rise so the events rule 1 lets in have a place there.

UPDATE public.axs_watch_config SET target_events = 305, updated_at = now() WHERE target_events = 200;

-- added to whatever the list of kept sports is at the time (prod's differs from the seed: the operator took the
-- Lakers out), once
UPDATE public.axs_watch_config
   SET sports_keep_regex = regexp_replace(sports_keep_regex, '\)$',
         '|\maew\M|all elite wrestling|\mpbr\M|professional bull riders|\mwwe\M|\mufc\M|monster jam|hot wheels|supercross|bnp paribas|\mnfr\M)'),
       updated_at = now()
 WHERE sports_keep_regex !~ 'bnp paribas' AND sports_keep_regex ~ '\)$';

UPDATE public.axs_watch_venue SET quota = 48, note = note || '; 40 -> 48 operator 2026-11-25 (PBR added)', set_at = now()
 WHERE axs_venue_id = 101329 AND quota = 40;
UPDATE public.axs_watch_venue SET quota = 19, note = note || '; 10 -> 19 operator 2026-11-25 (WWE, Disney On Ice, Monster Jam added)', set_at = now()
 WHERE axs_venue_id = 101620 AND quota = 10;
UPDATE public.axs_watch_venue SET quota = 10, note = note || '; 6 -> 10 operator 2026-11-25 (AEW, Hot Wheels added)', set_at = now()
 WHERE axs_venue_id = 101260 AND quota = 6;

INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled, note, set_by) VALUES
  (100995, 'Indian Wells Tennis Garden', 25, true, 'operator 2026-11-25 sales rank: BNP Paribas Open, 1,415 tickets sold on 22 sessions', 'operator'),
  (101390, 'T-Mobile Center', 19, true, 'operator 2026-11-25: Disney On Ice, Monster Jam, concerts', 'operator'),
  (101206, 'Pechanga Arena San Diego', 14, true, 'operator 2026-11-25: Disney On Ice, PBR, Hot Wheels, concerts', 'operator'),
  (101305, 'Thomas & Mack Center', 10, true, 'operator 2026-11-25 sales rank: NFR, Dec 3-12', 'operator'),
  (125519, 'Erie Insurance Arena', 6, true, 'operator 2026-11-25: Disney On Ice', 'operator'),
  (101406, 'Peacock Theater', 6, true, 'operator 2026-11-25 sales rank', 'operator'),
  (121632, 'Paycom Center', 3, true, 'operator 2026-11-25 sales rank: the AXS-sold concerts only', 'operator'),
  (128666, 'U.S. Bank Stadium', 2, true, 'operator 2026-11-25 sales rank: the AXS-sold concerts only', 'operator'),
  (127564, 'Sanford Stadium', 2, true, 'operator 2026-11-25 sales rank: the AXS-sold concerts only', 'operator'),
  (128331, 'Meta APEX', 1, true, 'operator 2026-11-25: UFC', 'operator'),
  (128430, 'Cowtown Coliseum', 0, true, 'operator 2026-11-25: PBR Stockyards Showcase; quota 0 = taken soonest first when the list has room', 'operator'),
  (124944, 'Forest Hills Stadium', 0, true, 'operator 2026-11-25 "when it''s in season"; quota 0 = taken soonest first when the list has room', 'operator'),
  (129307, 'Blue Federal Credit Union Arena', 0, true, 'operator 2026-11-25: Disney On Ice (not on sale yet); quota 0 = when the list has room', 'operator'),
  (101098, 'First Interstate Arena at MetraPark', 0, true, 'operator 2026-11-25: PBR, Hot Wheels; quota 0 = when the list has room', 'operator'),
  (126762, 'Bert Ogden Arena', 0, true, 'operator 2026-11-25: Hot Wheels Monster Trucks; quota 0 = when the list has room', 'operator'),
  (129477, 'Frontwave Arena', 0, true, 'operator 2026-11-25: WWE NXT; quota 0 = when the list has room', 'operator'),
  (100887, 'Denver Coliseum', 0, true, 'operator 2026-11-25: Disney On Ice (not on sale yet); quota 0 = when the list has room', 'operator'),
  (102193, 'Broadmoor World Arena', 0, true, 'operator 2026-11-25: Disney On Ice (not on sale yet); quota 0 = when the list has room', 'operator'),
  (124853, 'The United Theater on Broadway', 0, true, 'operator 2026-11-25 sales rank; quota 0 = when the list has room', 'operator'),
  (126462, 'Xcite Center at Parx Casino', 0, true, 'operator 2026-11-25 sales rank; quota 0 = when the list has room', 'operator'),
  (101764, 'The St. Augustine Amphitheatre', 0, true, 'operator 2026-11-25 sales rank; quota 0 = when the list has room', 'operator'),
  (101207, 'Santa Barbara Bowl', 0, true, 'operator 2026-11-25 sales rank; quota 0 = when the list has room', 'operator'),
  (101824, 'Toyota Arena', 0, true, 'operator 2026-11-25 sales rank; quota 0 = when the list has room', 'operator'),
  (124778, 'Pinnacle Bank Arena', 0, true, 'operator 2026-11-25 sales rank; quota 0 = when the list has room', 'operator'),
  (101007, 'VyStar Veterans Memorial Arena', 0, true, 'operator 2026-11-25 sales rank; quota 0 = when the list has room', 'operator'),
  (125101, 'Desert Diamond Arena', 0, true, 'operator 2026-11-25 sales rank; quota 0 = when the list has room', 'operator')
ON CONFLICT (axs_venue_id) DO NOTHING;
