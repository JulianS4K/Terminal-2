-- ============================================================================
-- Migration 20260708123000 — Venue capacity seed (feeds zone feature-store fill_rate)
--
-- Lane:     data plane (A1)
-- Touches:  venue_assets (W: capacity for existing rows; INSERT catalog rows for
--           sports/marquee venues missing from venue_assets entirely)
--
-- Operator directive (2026-07-08): "use wiki for capacity where possible if not
--   just google it and add to data, complete filling everything else for coverage."
--
-- Context: venue_assets.capacity was 0% populated, so zone_price_observations.
--   fill_rate (tickets / capacity — a core scarcity factor) was null everywhere.
--   ESPN's venue feed (venue_assets.espn_raw) has no capacity field, so these
--   capacities are seeded from established public figures (venue-name → capacity,
--   sport-appropriate to the primary tenant). Web-page fetch is blocked by the
--   environment network policy in this session, so a few multi-config-arena
--   figures are best-available and can be refined. fill_rate is a ratio that
--   tolerates small capacity error.
--
-- Idempotent: only fills where capacity IS NULL; never overwrites a real value.
-- After applying, rebuild the feature store: SELECT build_zone_price_observations_day(d)
--   over the zone_metrics date range to repopulate fill_rate.
-- ============================================================================

-- (1) capacity for the 111 venues already catalogued in venue_assets
UPDATE venue_assets va SET capacity = v.cap
FROM (VALUES
 -- MLB
 (5725,46537),(488,37755),(414,56000),(1172,41331),(1766,41649),(5724,41922),
 (2877,42792),(2775,40209),(33365,41084),(34920,40300),(200,44494),(431,45517),
 (1913,41700),(110,48405),(1782,41083),(339,50144),(284,42319),(454,41168),
 (767,37903),(15952,37446),(5194,41339),(211,44970),(1916,38747),(738,34830),
 (318,40615),(6333,38544),(1369,47929),(1436,49282),(1605,25025),
 -- NBA
 (896,19812),(1480,19079),(2259,18418),(33422,20332),(2196,18203),(614,19432),
 (499,20478),(17,19800),(1228,16600),(1534,18798),(43,16645),(44,19600),
 (1537,18846),(3123,17794),(33662,17341),(32836,17608),(3535,19077),(1103,16867),
 (2786,18055),(48249,18000),(399,18306),
 -- NHL
 (1219,17809),(1080,17159),(1786,19070),(66,17174),(1278,18680),(1790,18500),
 (7329,18387),(4797,16514),(1811,17954),(39243,17255),(557,18910),(33142,18347),
 (1384,17562),(1367,19289),(32725,17500),(785,18096),(955,18573),(781,17100),
 (1036,21105),
 -- NFL
 (1567,68400),(36209,65000),(5994,80000),(457,74867),(1516,73208),(1010,76125),
 (36,67814),(2199,65000),(2236,64628),(67,76416),(1279,71608),(294,67431),
 (820,81441),(30589,68500),(2542,69596),(5242,67000),(2246,68740),(1266,71008),
 (33372,71000),(7074,82500),(12,69143),(486,67617),(2223,72220),(1797,65515),
 (1284,65890),(34648,70240),(1444,61500),(3995,63400),(32930,66655),(1262,65326),
 -- other arenas already in venue_assets
 (1085,19250),(701,19092),(345,17373),(3316,15225),(34130,18064),(1343,19393),
 (27950,17732),(1097,46847),(1633,20917),(1947,19200),(324,17274),(507,19156)
) AS v(vid,cap)
WHERE va.tevo_venue_id = v.vid AND va.capacity IS NULL;

-- (2) sports + marquee venues absent from venue_assets — insert catalog rows w/ capacity
INSERT INTO venue_assets (tevo_venue_id, venue_name, capacity, source) VALUES
 (2061,'Mohegan Sun Arena - CT',9323,'manual_capacity_seed'),
 (2575,'Sutter Health Park',14014,'manual_capacity_seed'),
 (5867,'America First Field',20213,'manual_capacity_seed'),
 (48292,'Inter&Co Stadium',25500,'manual_capacity_seed'),
 (42979,'Snapdragon Stadium',35000,'manual_capacity_seed'),
 (19292,'Shell Energy Stadium',22039,'manual_capacity_seed'),
 (3571,'Michelob ULTRA Arena At Mandalay Bay',12000,'manual_capacity_seed'),
 (33676,'BMO Stadium',22000,'manual_capacity_seed'),
 (33655,'Audi Field',20000,'manual_capacity_seed'),
 (33572,'Wintrust Arena',10387,'manual_capacity_seed'),
 (33974,'CareFirst Arena',4200,'manual_capacity_seed'),
 (32076,'PayPal Park',18000,'manual_capacity_seed'),
 (34957,'Gateway Center Arena at College Park',3500,'manual_capacity_seed'),
 (7236,'Subaru Park',18500,'manual_capacity_seed'),
 (18876,'College Park Center',7000,'manual_capacity_seed'),
 (42114,'GEODIS Park',30000,'manual_capacity_seed'),
 (34053,'Allianz Field',19400,'manual_capacity_seed'),
 (39210,'TQL Stadium',26000,'manual_capacity_seed'),
 (6958,'Stade Saputo',19619,'manual_capacity_seed'),
 (2804,'Coca-Cola Coliseum',8140,'manual_capacity_seed'),
 (63463,'Miami Freedom Park & Soccer Village',25000,'manual_capacity_seed'),
 (63741,'ScottsMiracle-Gro Field',20371,'manual_capacity_seed'),
 (33999,'Las Vegas Ballpark',10000,'manual_capacity_seed'),
 (39212,'Q2 Stadium',20738,'manual_capacity_seed'),
 (2788,'Providence Park',25218,'manual_capacity_seed'),
 (7722,'Sporting Park',18467,'manual_capacity_seed'),
 (2566,'Dignity Health Sports Park - Stadium',27000,'manual_capacity_seed'),
 (3640,'Toyota Stadium',20500,'manual_capacity_seed'),
 (859,'Chase Stadium',21550,'manual_capacity_seed'),
 (3892,'SeatGeek Stadium',20000,'manual_capacity_seed'),
 (640,'PeoplesBank Arena',15635,'manual_capacity_seed'),
 (33409,'Exploria Stadium',25500,'manual_capacity_seed'),
 (39838,'FirstBank Amphitheater',7500,'manual_capacity_seed'),
 (44984,'Sphere',17600,'manual_capacity_seed'),
 (1290,'Red Rocks Amphitheatre',9525,'manual_capacity_seed'),
 (1366,'Ryman Auditorium',2362,'manual_capacity_seed'),
 (38485,'Moody Center ATX',15000,'manual_capacity_seed'),
 (103,'CFG Bank Arena',14000,'manual_capacity_seed'),
 (33,'Allstate Arena',18500,'manual_capacity_seed'),
 (4603,'T-Mobile Center',18972,'manual_capacity_seed'),
 (1188,'Hollywood Pantages Theatre - CA',2703,'manual_capacity_seed'),
 (1563,'Thomas & Mack Center',18776,'manual_capacity_seed'),
 (2518,'BC Place Stadium',54500,'manual_capacity_seed'),
 (520,'Forest Hills Stadium',14000,'manual_capacity_seed'),
 (7054,'Sports Illustrated Stadium',25000,'manual_capacity_seed'),
 (667,'Hollywood Bowl',17500,'manual_capacity_seed'),
 (603,'Greek Theatre - Los Angeles',5900,'manual_capacity_seed'),
 (602,'Kia Forum',17505,'manual_capacity_seed'),
 (2839,'Save Mart Center',16182,'manual_capacity_seed'),
 (8000,'Pechanga Arena - San Diego',12920,'manual_capacity_seed'),
 (996,'MGM Grand Garden Arena',17000,'manual_capacity_seed'),
 (5118,'BOK Center',19199,'manual_capacity_seed'),
 (33705,'Tottenham Hotspur Stadium',62850,'manual_capacity_seed'),
 (1342,'Rose Bowl Stadium - Pasadena',88565,'manual_capacity_seed'),
 (2058,'Autzen Stadium',54000,'manual_capacity_seed'),
 (1304,'Rice-Eccles Stadium',51444,'manual_capacity_seed'),
 (5827,'Maracana Stadium',78838,'manual_capacity_seed'),
 (6512,'Allianz Arena',75000,'manual_capacity_seed'),
 (10667,'Stade de France',80698,'manual_capacity_seed'),
 (2289,'Tom Benson Hall of Fame Stadium',23000,'manual_capacity_seed'),
 (1275,'Radio City Music Hall',6015,'manual_capacity_seed'),
 (123,'Beacon Theatre - NY',2894,'manual_capacity_seed'),
 (276,'The Chicago Theatre',3600,'manual_capacity_seed'),
 (1618,'Xfinity Center - MA',19900,'manual_capacity_seed'),
 (984,'Merriweather Post Pavilion',19319,'manual_capacity_seed'),
 (1113,'Jiffy Lube Live',25262,'manual_capacity_seed'),
 (1218,'MVP Arena',17500,'manual_capacity_seed'),
 (2172,'DCU Center',14800,'manual_capacity_seed'),
 (30074,'Pinnacle Bank Arena',15500,'manual_capacity_seed'),
 (617,'Gas South Arena',13000,'manual_capacity_seed'),
 (1663,'Van Andel Arena',12000,'manual_capacity_seed'),
 (3238,'Agganis Arena',7200,'manual_capacity_seed'),
 (426,'Maverik Center',12000,'manual_capacity_seed')
ON CONFLICT (tevo_venue_id) DO UPDATE
  SET capacity = EXCLUDED.capacity
  WHERE venue_assets.capacity IS NULL;
