\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
\echo 1 section keys (input -> key):
SELECT s || ' -> ' || coalesce(listing_overlap_section_key(s), '(null)')
  FROM unnest(ARRAY['129','Club 129','C129','VIP111','Vip 111','Section108D','Section 108D','400s Level 428',
                    '101WC','105 WC','Lower Corner 131','Suite A6','A6','B6','Floor E','FLOORE','C-F','Club F',
                    'GA','General Admission','LOGE12','  ','Upper  317']) WITH ORDINALITY AS t(s, o) ORDER BY o;
\echo 2 row keys (input -> key):
SELECT '[' || coalesce(r, 'NULL') || '] -> [' || listing_overlap_row_key(r) || ']'
  FROM unnest(ARRAY['12','012',' 7 ','Row 5','row AA','a','GA','0','00',NULL,'']) WITH ORDINALITY AS t(r, o) ORDER BY o;
\echo 3 pairing (evo prices | gt prices -> evo_idx:gt_idx):
SELECT e::text || ' | ' || g::text || ' -> ' ||
       coalesce((SELECT string_agg(p.evo_idx || ':' || p.gt_idx, ' ' ORDER BY p.evo_idx) FROM listing_overlap_pair(e, g, 0.989, 0.12) p), '(none)')
  FROM (VALUES
    (ARRAY[100]::numeric[],          ARRAY[99]::numeric[]),            -- one each, in band
    (ARRAY[100]::numeric[],          ARRAY[150]::numeric[]),           -- one each, out of band
    (ARRAY[100,200]::numeric[],      ARRAY[198]::numeric[]),           -- the dearer copy is the one on both
    (ARRAY[200]::numeric[],          ARRAY[99,198]::numeric[]),        -- the cheaper GoTickets one is extra
    (ARRAY[100,100,100]::numeric[],  ARRAY[99,99]::numeric[]),         -- identical copies: two pair, one left
    (ARRAY[100,300,500]::numeric[],  ARRAY[98,296,700]::numeric[]),    -- two pair, the last is a gap
    (ARRAY[]::numeric[],             ARRAY[99]::numeric[]),
    (ARRAY[100]::numeric[],          ARRAY[88.9]::numeric[]),          -- just inside the lower edge
    (ARRAY[100]::numeric[],          ARRAY[87]::numeric[])             -- just outside
  ) AS t(e, g);
\echo 4 nobody but the service role may run it:
SELECT p.proname || ' anon=' || has_function_privilege('anon', p.oid, 'EXECUTE')
       || ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
       || ' service_role=' || has_function_privilege('service_role', p.oid, 'EXECUTE')
  FROM pg_proc p
 WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'listing\_overlap%'
   AND p.proname NOT IN ('listing_overlap_section_key', 'listing_overlap_row_key', 'listing_overlap_pair')
 ORDER BY 1;
SELECT c.relname || ' rls=' || c.relrowsecurity || ' anon_select=' || has_table_privilege('anon', c.oid, 'SELECT')
       || ' authenticated_select=' || has_table_privilege('authenticated', c.oid, 'SELECT')
  FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relname LIKE '%listing\_overlap%' AND c.relkind IN ('r','v')
 ORDER BY 1;
\echo 5 schedule:
SELECT name, schedule, command FROM cron.scheduled;
