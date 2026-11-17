-- Migration 20261113050000 · level:secondary-sales · lane:D7 · writes:n2s_gt_order_dryrun_capture,n2s_evo_order_dryrun_capture · reads:n2s_items · pre:20261112030000
--
-- N2S dry run (and so the auto-buyer) works Automatiq failed-order alerts only.
--
-- Operator 2026-11-13: N2S is the original flow (Automatiq failed-order alerts, the 10-minute
-- timer, the EVO auto-buy). Orders agents add to the CRM's N2S book by hand ("manual") are the
-- SISTER flow (accepted orders whose tickets have a problem), handled by the sub finder; asked
-- "Should I limit N2S (dry run and auto-buy) to Automatiq items only?" → "Yes".
--
-- Why it matters: the CRM intake takes every N2S-book item, whatever its source. A manual item
-- has no alert and no timer, and n2s_timer_open() reads that as open, so it stays open forever
-- and could reach the dry run and the auto-buyer. Prod on 2026-11-13: 7,343 automatiq items (all
-- with an alert and a timer), 2 manual (no timer), 102 gmail (peddled sales, already excluded
-- by n2s_id > 0).
--
-- What: both dry-run captures gain one condition, n2s_items.item_source = 'automatiq'. The
-- auto-buyer takes its rows only from the dry run (n2s_autobuy_enqueue_trg on
-- n2s_gt_order_dryrun), so nothing else can buy for another source. The cover queue, the subs
-- page and the feed still show every item.
--
-- Guarded: each capture must match the text 20261112030000 leaves (md5 below), and the anchor
-- must occur exactly once.
--
-- rollback: re-create both captures without the item_source line (or re-run 20261112030000 on
--           top of the 20261110070000 bodies).

DO $do$
DECLARE d text; f text; h text;
  v_anchor constant text := 'AND q.n2s_id > 0';
  v_new    constant text := E'AND q.n2s_id > 0\n       -- 20261113050000: Automatiq failed-order alerts only (manual / gmail items are not N2S buys)\n       AND i.item_source = ''automatiq''';
BEGIN
  FOR f, h IN VALUES ('public.n2s_gt_order_dryrun_capture',  '65cd598398501d75500f01be4b6fd385'),
                     ('public.n2s_evo_order_dryrun_capture', '1c471a897d4f2f89ea687f6c8b2d6568') LOOP
    d := pg_get_functiondef(f::regproc);
    IF md5(d) <> h THEN
      RAISE EXCEPTION '% drifted from the text 20261112030000 leaves — re-derive this migration', f;
    END IF;
    IF (length(d) - length(replace(d, v_anchor, ''))) / length(v_anchor) <> 1 THEN
      RAISE EXCEPTION '% anchor not found exactly once — re-derive this migration', f;
    END IF;
    EXECUTE replace(d, v_anchor, v_new);
  END LOOP;
END $do$;
