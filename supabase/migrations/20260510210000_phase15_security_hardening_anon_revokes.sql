-- Migration 20260510210000 · level:secondary-sales · lane:canonical · writes:revokes(audit_cross_source_health,v_event_sales_combined) · reads:- · pre:20260510120500,20260510190000

-- Security hardening per A1 review of #51:
-- - audit_cross_source_health() RPC returns drift/orphan/coverage tallies → reconnaissance surface, revoke anon
-- - v_event_sales_combined joins EVO+SG sales (src/qty/price/order_state/is_ours) → pricing intelligence, revoke anon
-- Applied live ahead of merge; this migration ensures CI redeploy reconvenes the state.

REVOKE EXECUTE ON FUNCTION audit_cross_source_health() FROM anon;
REVOKE ALL ON v_event_sales_combined FROM anon;
