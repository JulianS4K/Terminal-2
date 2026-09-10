-- ============================================================================
-- Migration 20260910520000 — expose cover_gate/cover_label/zones on v_n2s_orders
--
-- Lane: D7 · Pre-reqs: 20260910510000
-- Last link in the chain: the gate cascade produced the label, 20260910510000
-- carried it into n2s_cover_queue, and this makes it visible to the panel and
-- the API.
--
-- ⚠ CREATE OR REPLACE VIEW can only APPEND columns (PROJECT_BIBLE §3), which is
-- exactly what this does — four new columns at the end, nothing reordered or
-- retyped. Applied by rewriting the stored definition so the rest of the body
-- cannot drift, with an assertion that the anchor was found.
-- ============================================================================

DO $do$
DECLARE d text; v text;
BEGIN
  v := pg_get_viewdef('public.v_n2s_orders'::regclass, true);

  IF position('n.n2s_order_key' in v) = 0 THEN
    RAISE EXCEPTION 'anchor n.n2s_order_key not found in v_n2s_orders — body changed?';
  END IF;
  IF position('c.cover_label' in v) > 0 THEN
    RAISE NOTICE 'cover_label already present; nothing to do';
    RETURN;
  END IF;

  v := replace(v,
       E'n.n2s_order_key\n   FROM n2s_items n',
       E'n.n2s_order_key,\n    c.cover_gate,\n    c.cover_label,\n    c.order_zone,\n    c.sub_zone\n   FROM n2s_items n');

  IF position('c.cover_label' in v) = 0 THEN
    RAISE EXCEPTION 'append did not apply — FROM clause shape changed?';
  END IF;

  d := 'CREATE OR REPLACE VIEW public.v_n2s_orders AS ' || v;
  EXECUTE d;
END $do$;

COMMENT ON VIEW public.v_n2s_orders IS
  'Every open N2S obligation with its allocated cover LEFT JOINed on — deliberately not just the covered rows, because an uncovered obligation is the work, not missing data. Carries cover_gate (1-6, stable — filter on this) and cover_label from the gate cascade: "offer subs" in a label means the buyer is being MOVED and must accept before purchase.';
