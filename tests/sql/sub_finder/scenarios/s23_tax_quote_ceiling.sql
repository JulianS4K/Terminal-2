\pset format unaligned
\pset tuples_only on
UPDATE manual_sub_buy_config SET enabled = true, per_order_cap_usd = 750, daily_cap_usd = 4000, tax_quote_test = true WHERE id;
SELECT manual_sub_buy_request('Vivid','B1',1,111,2,100,105,'ev','operator','n');
\echo first claim: test flag on; raw answer stored
SELECT j->'cfg'->>'tax_quote', j->'cfg'->>'tax_quote_test',
       manual_sub_buy_record((j->'row'->>'buy_id')::bigint, (j->'row'->>'lease_token')::uuid, '{"state":"buying","quote_raw":{"ok":true,"response":{"tax_signature":"s","wholesale":{"tax":5.5}}}}'),
       manual_sub_buy_record((j->'row'->>'buy_id')::bigint, (j->'row'->>'lease_token')::uuid, '{"state":"bought","buy_order_id":"9"}')
FROM manual_sub_buy_claim() j;
SELECT state, quote_raw->'response'->'wholesale'->>'tax' FROM manual_sub_buy WHERE sale_order_number='B1';
\echo second claim: an answer is on file, so no more test quotes
SELECT manual_sub_buy_request('Vivid','B2',1,112,2,100,105,'ev','operator','n');
SELECT j->'cfg'->>'tax_quote', j->'cfg'->>'tax_quote_test' FROM manual_sub_buy_claim() j;
