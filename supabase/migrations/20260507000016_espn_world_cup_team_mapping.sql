-- 48 FIFA World Cup national teams: TEvo perf <-> ESPN team
-- 22 from performer_home_venues (cowork seed) + 25 via tevo-perf-find + 1 manual (Türkiye -> Turkey)
-- league = 'World Cup' to align with performer_home_venues label
-- Idempotent via WHERE NOT EXISTS guard. Applied to prod 2026-05-07 via MCP.

with new_rows(performer_id, source, external_id, external_name, league, meta) as (values
  -- from performer_home_venues
  (30983, 'espn', '202',  'Argentina',          'World Cup', '{"espn_slug":"arg","espn_abbr":"ARG","tevo_name":"Argentina National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (49357, 'espn', '474',  'Austria',            'World Cup', '{"espn_slug":"aut","espn_abbr":"AUT","tevo_name":"Austria National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (40896, 'espn', '459',  'Belgium',            'World Cup', '{"espn_slug":"bel","espn_abbr":"BEL","tevo_name":"Belgium National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (26175, 'espn', '205',  'Brazil',             'World Cup', '{"espn_slug":"bra","espn_abbr":"BRA","tevo_name":"Brazil National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (26165, 'espn', '206',  'Canada',             'World Cup', '{"espn_slug":"can","espn_abbr":"CAN","tevo_name":"Canada National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (15950, 'espn', '208',  'Colombia',           'World Cup', '{"espn_slug":"col","espn_abbr":"COL","tevo_name":"Colombia National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (29520, 'espn', '477',  'Croatia',            'World Cup', '{"espn_slug":"cro","espn_abbr":"CRO","tevo_name":"Croatian National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (13697, 'espn', '209',  'Ecuador',            'World Cup', '{"espn_slug":"ecu","espn_abbr":"ECU","tevo_name":"Ecuador National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (13708, 'espn', '448',  'England',            'World Cup', '{"espn_slug":"eng","espn_abbr":"ENG","tevo_name":"England National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (15995, 'espn', '478',  'France',             'World Cup', '{"espn_slug":"fra","espn_abbr":"FRA","tevo_name":"France National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (13795, 'espn', '481',  'Germany',            'World Cup', '{"espn_slug":"ger","espn_abbr":"GER","tevo_name":"Germany National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (21911, 'espn', '627',  'Japan',              'World Cup', '{"espn_slug":"jpn","espn_abbr":"JPN","tevo_name":"Japan National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (30513, 'espn', '203',  'Mexico',             'World Cup', '{"espn_slug":"mex","espn_abbr":"MEX","tevo_name":"Mexico National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (14222, 'espn', '449',  'Netherlands',        'World Cup', '{"espn_slug":"ned","espn_abbr":"NED","tevo_name":"Netherlands National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (31868, 'espn', '2666', 'New Zealand',        'World Cup', '{"espn_slug":"nzl","espn_abbr":"NZL","tevo_name":"New Zealand National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (21918, 'espn', '210',  'Paraguay',           'World Cup', '{"espn_slug":"par","espn_abbr":"PAR","tevo_name":"Paraguay National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (29518, 'espn', '482',  'Portugal',           'World Cup', '{"espn_slug":"por","espn_abbr":"POR","tevo_name":"Portugal National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (14444, 'espn', '580',  'Scotland',           'World Cup', '{"espn_slug":"sco","espn_abbr":"SCO","tevo_name":"Scotland National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (14492, 'espn', '164',  'Spain',              'World Cup', '{"espn_slug":"esp","espn_abbr":"ESP","tevo_name":"Spain National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (40893, 'espn', '475',  'Switzerland',        'World Cup', '{"espn_slug":"sui","espn_abbr":"SUI","tevo_name":"Switzerland National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (39587, 'espn', '212',  'Uruguay',            'World Cup', '{"espn_slug":"uru","espn_abbr":"URU","tevo_name":"Uruguay National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  (30851, 'espn', '660',  'United States',      'World Cup', '{"espn_slug":"usa","espn_abbr":"USA","tevo_name":"USA Mens National Soccer Team","backfilled_from":"home_venues"}'::jsonb),
  -- via tevo-perf-find
  (40897,  'espn', '624',   'Algeria',           'World Cup', '{"espn_slug":"alg","tevo_name":"Algeria National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (15904,  'espn', '628',   'Australia',         'World Cup', '{"espn_slug":"aus","tevo_name":"Australia National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (31723,  'espn', '452',   'Bosnia-Herzegovina','World Cup', '{"espn_slug":"bih","tevo_name":"Bosnia-Herzegovina National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (130134, 'espn', '2597',  'Cape Verde',        'World Cup', '{"espn_slug":"cpv","tevo_name":"Cape Verde National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (127538, 'espn', '2850',  'Congo DR',          'World Cup', '{"espn_slug":"rdc","tevo_name":"Congo DR National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (69402,  'espn', '11678', 'Curacao',           'World Cup', '{"espn_slug":"fifa.curacao","tevo_name":"Curacao National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (133917, 'espn', '450',   'Czechia',           'World Cup', '{"espn_slug":"cze","tevo_name":"Czechia National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (127527, 'espn', '2620',  'Egypt',             'World Cup', '{"espn_slug":"egy","tevo_name":"Egypt National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (40895,  'espn', '4469',  'Ghana',             'World Cup', '{"espn_slug":"gha","tevo_name":"Ghana National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (39384,  'espn', '2654',  'Haiti',             'World Cup', '{"espn_slug":"hai","tevo_name":"Haiti National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (5321,   'espn', '469',   'Iran',              'World Cup', '{"espn_slug":"irn","tevo_name":"Iran National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (133927, 'espn', '4375',  'Iraq',              'World Cup', '{"espn_slug":"irq","tevo_name":"Iraq National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (41610,  'espn', '4789',  'Ivory Coast',       'World Cup', '{"espn_slug":"civ","tevo_name":"Ivory Coast National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (129794, 'espn', '2917',  'Jordan',            'World Cup', '{"espn_slug":"jor","tevo_name":"Jordan National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (82369,  'espn', '2869',  'Morocco',           'World Cup', '{"espn_slug":"mar","tevo_name":"Morocco National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (128410, 'espn', '464',   'Norway',            'World Cup', '{"espn_slug":"nor","tevo_name":"Norway National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (26164,  'espn', '2659',  'Panama',            'World Cup', '{"espn_slug":"pan","tevo_name":"Panama National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (82367,  'espn', '4398',  'Qatar',             'World Cup', '{"espn_slug":"qat","tevo_name":"Qatar National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (82370,  'espn', '655',   'Saudi Arabia',      'World Cup', '{"espn_slug":"ksa","tevo_name":"Saudi Arabia National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (49627,  'espn', '654',   'Senegal',           'World Cup', '{"espn_slug":"sen","tevo_name":"Senegal National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (127531, 'espn', '467',   'South Africa',      'World Cup', '{"espn_slug":"rsa","tevo_name":"South Africa National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (40785,  'espn', '451',   'South Korea',       'World Cup', '{"espn_slug":"kors","tevo_name":"Korea Republic National Soccer Team","backfilled_from":"tevo-perf-find","notes":"TEvo lists as Korea Republic"}'::jsonb),
  (16197,  'espn', '466',   'Sweden',            'World Cup', '{"espn_slug":"swe","tevo_name":"Sweden National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (82368,  'espn', '659',   'Tunisia',           'World Cup', '{"espn_slug":"tun","tevo_name":"Tunisia National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  (92712,  'espn', '2570',  'Uzbekistan',        'World Cup', '{"espn_slug":"uzb","tevo_name":"Uzbekistan National Soccer Team","backfilled_from":"tevo-perf-find"}'::jsonb),
  -- manual (TEvo uses Turkey, ESPN uses Türkiye)
  (16209,  'espn', '465',   'Türkiye',           'World Cup', '{"espn_slug":"tur","tevo_name":"Turkey National Soccer Team","backfilled_from":"manual","notes":"TEvo uses ASCII Turkey"}'::jsonb)
)
insert into performer_external_ids (performer_id, source, external_id, external_name, league, meta, set_at)
select n.performer_id, n.source, n.external_id, n.external_name, n.league,
       n.meta || jsonb_build_object('backfilled_at', now()::text),
       now()
from new_rows n
where not exists (
  select 1 from performer_external_ids pei
  where pei.performer_id = n.performer_id and pei.source = 'espn'
);
