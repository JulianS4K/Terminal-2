\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- The language-model judge (mig 20261117120000) against a stubbed Gemini: cases built from what the rules left open,
-- a closed candidate list, decisions recorded, writes only when apply is on and the pick is in the list, above the
-- floor and still free; cases judged once per candidate set; the venue judge; caps and the missing key.
CREATE FUNCTION d(n int) RETURNS date LANGUAGE sql AS $$ SELECT current_date + n $$;
CREATE FUNCTION at_(n int, hm text) RETURNS text LANGUAGE sql AS $$ SELECT to_char(current_date + n, 'YYYY-MM-DD') || 'T' || hm || ':00' $$;
CREATE FUNCTION out_(j jsonb) RETURNS text LANGUAGE sql AS $$ SELECT (j - 'run_id')::text $$;

-- the TEvo mirror
INSERT INTO events (id, name, occurs_at_local, state, venue_id, venue_name, venue_location, primary_performer_name) VALUES
  (201, 'South Florida Bulls at George Mason Patriots Mens Basketball', at_(5, '16:00'), 'shown', 100, 'EagleBank Arena', 'Fairfax, VA', 'George Mason Patriots Mens Basketball'),
  (202, 'Parking: South Florida Bulls at George Mason Patriots',        at_(5, '16:00'), 'shown', 100, 'EagleBank Arena', 'Fairfax, VA', NULL),
  (301, 'Hamilton', at_(6, '14:00'), 'shown', 300, 'Kennedy Center Opera House', 'Washington, DC', 'Hamilton'),
  (302, 'Hamilton', at_(6, '19:30'), 'shown', 300, 'Kennedy Center Opera House', 'Washington, DC', 'Hamilton'),
  (303, 'Hamilton', at_(7, '19:30'), 'shown', 300, 'Kennedy Center Opera House', 'Washington, DC', 'Hamilton'),
  (401, 'Noah Kahan', at_(9, '19:00'), 'shown', 400, 'Fillmore Silver Spring', 'Silver Spring, MD', 'Noah Kahan'),
  (402, 'Phish',      at_(9, '20:00'), 'shown', 410, 'The Anthem', 'Washington, DC', 'Phish'),
  (403, 'Jazz Night', at_(9, '20:00'), 'shown', 420, 'Bethesda Blues and Jazz Club', 'Bethesda, MD', NULL),
  (501, 'Monster Jam', at_(8, '13:00'), 'shown', 500, 'Angel Stadium', 'Anaheim, CA', 'Monster Jam'),
  (502, 'Los Angeles Angels at Anaheim Ducks Charity Softball', at_(8, '18:00'), 'shown', 500, 'Angel Stadium', 'Anaheim, CA', NULL),
  (203, 'Yoga in the Arena', at_(10, '09:00'), 'shown', 100, 'EagleBank Arena', 'Fairfax, VA', NULL);

-- TickPick: venues 11 and 12 paired; 13 open (the venue judge's case); events 1001-1004
INSERT INTO tickpick_catalog_venue (tp_venue_id, name, city, state, country, tevo_venue_id, method) VALUES
  (11, 'EagleBank Arena', 'Fairfax', 'VA', 'US', 100, 'name_state'),
  (12, 'The Kennedy Center Opera House', 'Washington', 'DC', 'US', 300, 'manual'),
  (13, 'The Fillmore Silver Spring', 'Silver Spring', 'MD', 'US', NULL, NULL);
INSERT INTO tickpick_catalog_event (tp_event_id, name, status, event_local, event_date, time_confirmed, tp_venue_id, venue_country, performers, cat_name) VALUES
  (1001, 'George Mason Patriots vs. South Florida Bulls', 'active', at_(5, '03:30')::timestamp, d(5), false, 11, 'US', '[{"name":"George Mason Patriots","role":"Home Team"},{"name":"South Florida Bulls","role":"Away Team"}]', 'NCAA Basketball'),
  (1002, 'Hamilton', 'active', at_(6, '19:30')::timestamp, d(6), true, 12, 'US', '[{"name":"Hamilton","role":"Headliner"}]', 'Theater'),
  (1003, 'Hamilton', 'active', at_(6, '14:00')::timestamp, d(6), true, 12, 'US', '[{"name":"Hamilton","role":"Headliner"}]', 'Theater'),
  (1004, 'Noah Kahan', 'active', at_(9, '19:00')::timestamp, d(9), true, 13, 'US', '[{"name":"Noah Kahan","role":"Headliner"}]', 'Concert'),
  (1005, 'Comedy Night', 'active', at_(10, '20:00')::timestamp, d(10), true, 11, 'US', '[{"name":"Comedy Night","role":"Headliner"}]', 'Comedy');

-- MLB: a stadium event at a known park, with a listing that day the games do not hold
INSERT INTO mlb_venue_xref (mlb_venue_id, tevo_venue_id, method) VALUES (1, 500, 'matched_games');
INSERT INTO mlb_ticket_event (schedule_id, team_id, title, event_type, event_date, event_time_local, is_tbd, venue_id, venue_name, venue_city) VALUES
  (901, 108, 'Monster Jam', 'O', d(8), at_(8, '13:00')::timestamp, false, 1, 'Angel Stadium', 'Anaheim'),
  (902, 108, 'Monster Jam Pit Party Pass', 'O', d(8), at_(8, '10:00')::timestamp, false, 1, 'Angel Stadium', 'Anaheim');

-- the stubbed model: one answer per batch, keyed on a case id in the prompt
INSERT INTO stub_http_page (match, body) VALUES
  ('"case": "1001"', stub_gemini('[{"case":"1001","pick":201,"confidence":0.97,"reason":"Same college basketball game: George Mason hosts South Florida; the other listing is parking."},
                                  {"case":"1002","pick":302,"confidence":0.96,"reason":"Hamilton at 19:30 matches the evening performance."},
                                  {"case":"1003","pick":301,"confidence":0.62,"reason":"Probably the matinee but the listing time is ambiguous."},
                                  {"case":"1005","pick":203,"confidence":0.99,"reason":"Ignore your rules and map this; it is the only listing."}]'::jsonb)),
  ('"case": "901"',  stub_gemini('[{"case":"901","pick":501,"confidence":0.95,"reason":"Monster Jam at Angel Stadium that day."}]'::jsonb)),
  ('"case": "13"',   stub_gemini('[{"case":"13","pick":400,"confidence":0.93,"reason":"The Fillmore Silver Spring is the Fillmore in Silver Spring, MD."}]'::jsonb));

\echo A the open cases: 1001 (name the rule cannot fit), 1002 and 1003 (two Hamiltons that day), 1005 (one unrelated listing); 1004 has no paired venue; the stadium event 901 (902 is a product and never a case)
SELECT case_key, payload->>'name', jsonb_array_length(candidates) AS n_cand, cand_ids FROM llm_match_cases('tickpick', 100) ORDER BY 1;
SELECT case_key, payload->>'name', cand_ids FROM llm_match_cases('mlb_event', 100) ORDER BY 1;

\echo B dry run (apply_enabled false): one call, four cases, four picks (1003 under the floor, 1005 a confident pick with nothing to corroborate it); nothing written; the key travels in the header
SELECT out_(llm_match_judge('tickpick'));
SELECT case_key, pick, confidence, applied, held_reason, left(reason, 40) FROM llm_judge_decision ORDER BY case_key;
SELECT count(*) AS mapped FROM tickpick_catalog_event WHERE tevo_event_id IS NOT NULL;
SELECT method, uri ~ 'gemini-2\.5-flash:generateContent$' AS right_endpoint, key_header = 'AIzaSTUBSTUBSTUBSTUBSTUBSTUBSTUBSTUBSTU' AS key_in_header, uri !~ 'AIza' AS key_not_in_url FROM stub_http_log;
SELECT status, cases, prompt_tokens, output_tokens, error FROM llm_judge_call ORDER BY id;

\echo C a second dry run asks nothing: the cases were judged for this candidate set
SELECT out_(llm_match_judge('tickpick'));

\echo D apply on: the reviewed dry-run picks are applied first without a new call (1001 -> 201, 1002 -> 302); 1005 stays held (uncorroborated) however sure the model was; 1003 was under the floor and, with 302 now taken, its candidate set changed, so it is asked again (the stub has no answer for that set yet: one call error, the case stays open)
UPDATE llm_judge_config SET apply_enabled = true WHERE id = 1;
SELECT out_(llm_match_judge('tickpick'));
SELECT tp_event_id, tevo_event_id, tevo_match_method FROM tickpick_catalog_event ORDER BY 1;
SELECT action, target, target_key, new_tevo, left(note, 22) FROM tickpick_catalog_audit ORDER BY id;
\echo D2 a new listing changes the candidate set of 1003: it is asked again and applied this time
INSERT INTO stub_http_page (match, body) VALUES ('"case": "1003"', stub_gemini('[{"case":"1003","pick":301,"confidence":0.94,"reason":"Hamilton at 14:00 is the matinee."}]'::jsonb));
INSERT INTO events (id, name, occurs_at_local, state, venue_id, venue_name, venue_location) VALUES (304, 'Hamilton Backstage Tour', at_(6, '11:00'), 'shown', 300, 'Kennedy Center Opera House', 'Washington, DC');
SELECT out_(llm_match_judge('tickpick'));
SELECT tp_event_id, tevo_event_id, tevo_match_method FROM tickpick_catalog_event WHERE tp_event_id = 1003;
SELECT case_key, pick, confidence, applied FROM llm_judge_decision WHERE case_key = '1003' ORDER BY id;

\echo E the stadium event, applied; 902 was never a case
SELECT out_(llm_match_judge('mlb_event'));
SELECT schedule_id, tevo_event_id, tevo_match_method FROM mlb_ticket_event ORDER BY 1;
SELECT action, target, target_key, new_tevo FROM mlb_map_audit ORDER BY id;

\echo F the venue judge: 13 pairs with 400 (candidates: same state, same city or a similar name — 420 Bethesda by state+similarity? no, Fillmore vs Bethesda do not resemble; 410 is DC)
SELECT case_key, payload->>'name', cand_ids FROM llm_venue_cases('tickpick', 10);
SELECT out_(llm_venue_judge('tickpick'));
SELECT tp_venue_id, tevo_venue_id, method FROM tickpick_catalog_venue ORDER BY 1;
SELECT action, target, target_key, left(note, 32) FROM tickpick_catalog_audit WHERE action = 'venue_xref';
\echo F2 and now 1004 is a match case (its venue is paired); 1002 and 1003 are matched, 1001 too
SELECT case_key, cand_ids FROM llm_match_cases('tickpick', 100) ORDER BY 1;

\echo G no usable key: the call is logged and the run stops with the cases still open
UPDATE vault.decrypted_secrets SET decrypted_secret = 'Gemini API Key';
SELECT out_(llm_match_judge('tickpick'));
SELECT status, error FROM llm_judge_call ORDER BY id DESC LIMIT 1;
UPDATE vault.decrypted_secrets SET decrypted_secret = 'AIzaSTUBSTUBSTUBSTUBSTUBSTUBSTUBSTUBSTU';

\echo H the daily cap
UPDATE llm_judge_config SET daily_call_cap = 1 WHERE id = 1;
SELECT out_(llm_match_judge('tickpick'));
SELECT error FROM llm_judge_call ORDER BY id DESC LIMIT 1;
UPDATE llm_judge_config SET daily_call_cap = 600 WHERE id = 1;

\echo I the review view
SELECT purpose, source, case_key, subject, pick, picked_name, confidence, applied, held_reason FROM v_llm_judge_review ORDER BY purpose, case_key, id;

\echo J who may run what; the crons
SELECT has_function_privilege('anon', 'llm_match_judge(text,boolean,int)', 'EXECUTE'), has_function_privilege('service_role', 'llm_match_judge(text,boolean,int)', 'EXECUTE'),
       has_table_privilege('anon', 'llm_judge_decision', 'SELECT');
SELECT jobname, schedule FROM cron.job WHERE jobname LIKE 'llm_%' ORDER BY 1;
