\pset format unaligned
\pset tuples_only on
UPDATE manual_sub_buy_config SET enabled = true, per_order_cap_usd = 750, daily_cap_usd = 4000, tax_quote = true WHERE id;
SELECT manual_sub_buy_request('Vivid','A1',1,111,2,100,105,'ev','sub finder auto (key crm)','n');
SELECT j->'row'->>'max_total_usd' AS ceil_auto, j->'cfg'->>'tax_quote' AS tq,
       manual_sub_buy_record((j->'row'->>'buy_id')::bigint, (j->'row'->>'lease_token')::uuid,
         '{"state":"stopped","reasons":["total_above_ceiling"],"quote_tax_usd":21.5,"quote_total_usd":221.5}')
FROM manual_sub_buy_claim() j;
SELECT state, reasons, quote_tax_usd, quote_total_usd, max_total_usd FROM manual_sub_buy WHERE sale_order_number='A1';
SELECT manual_sub_buy_request('Vivid','A2',1,112,2,100,105,'ev','crm api key crm','n');
SELECT coalesce(j->'row'->>'max_total_usd','none') AS ceil_crm FROM manual_sub_buy_claim() j;
UPDATE manual_sub_buy SET state='cancelled' WHERE sale_order_number='A2';
SELECT manual_sub_buy_request('GoTickets','A3',1,113,2,100,105,'ev','sub finder auto (gotickets offer accepted, key crm)','n');
SELECT coalesce(j->'row'->>'max_total_usd','none') AS ceil_gt FROM manual_sub_buy_claim() j;
UPDATE manual_sub_buy SET state='cancelled' WHERE sale_order_number='A3';
SELECT manual_sub_buy_request('Vivid','A4',1,114,2,100,NULL,'ev','sub finder auto (key crm)','n');
SELECT coalesce(j->'row'->>'max_total_usd','none') AS ceil_nosale FROM manual_sub_buy_claim() j;
