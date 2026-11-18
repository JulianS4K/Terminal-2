-- Migration 20261006201127 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "listings_poll_scope_view_revert_owned" (version 20261006201127) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

CREATE OR REPLACE VIEW public.v_listings_poll_scope_events AS
 WITH RECURSIVE pol AS (
         SELECT listings_poll_scope_policy.sources
           FROM listings_poll_scope_policy
          WHERE listings_poll_scope_policy.key = 'default'::text
        ), sg_pub AS (
         SELECT min(s.tevo_event_id) AS id
           FROM seatgeek_sales_snapshots s
          WHERE s.tevo_event_id IS NOT NULL
        UNION ALL
         SELECT ( SELECT min(s.tevo_event_id) AS min
                   FROM seatgeek_sales_snapshots s
                  WHERE s.tevo_event_id > sg_pub.id) AS min
           FROM sg_pub
          WHERE sg_pub.id IS NOT NULL
        )
 SELECT o.tevo_event_id
   FROM s4kcs_orders o,
    pol
  WHERE o.tevo_event_id IS NOT NULL AND ('s4kcs_orders'::text = ANY (pol.sources))
UNION
 SELECT n.tevo_event_id
   FROM n2s_items n,
    pol
  WHERE n.tevo_event_id IS NOT NULL AND ('n2s_items'::text = ANY (pol.sources))
UNION
 SELECT s.tevo_event_id
   FROM seatgeek_orders s,
    pol
  WHERE s.tevo_event_id IS NOT NULL AND ('seatgeek_orders'::text = ANY (pol.sources))
UNION
 SELECT p.tevo_event_id
   FROM gotickets_purchases p,
    pol
  WHERE p.tevo_event_id IS NOT NULL AND ('gotickets_purchases'::text = ANY (pol.sources))
UNION
 SELECT sg_pub.id AS tevo_event_id
   FROM sg_pub,
    pol
  WHERE sg_pub.id IS NOT NULL AND ('seatgeek_sales_snapshots'::text = ANY (pol.sources));
;
