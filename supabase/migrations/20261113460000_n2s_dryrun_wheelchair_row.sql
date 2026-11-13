-- Migration 20261113460000 · level:secondary-sales · lane:D0 · writes:n2s_dryrun_extra_reasons · reads:n2s_cover_queue,n2s_gt_order_dryrun · pre:20261113450000
--
-- N2S AUTO-BUYER: a wheelchair row is never bought automatically.
--
-- Operator 2026-11-13, to the sub finder session: "add the wc rule to n2s too" (after "Yes add
-- those 2 for CRM to review before autobuying, wc row and single-double letter and vice
-- versa", which 20261113450000 did for the sub finder). The function is lane D7's; the
-- operator routed this change here.
--
-- n2s_dryrun_extra_reasons() already skips a single-letter row against a double-letter one
-- (row_letter_mismatch, 20261104170000). "WC" is two letters, so a sold WC row against a
-- single-letter sub was already skipped by that rule, under that name. Not skipped until now:
-- a WC row against a double-letter row (sold WC, sub AA), and any pair where the wheelchair
-- row is not written as exactly two letters.
--
-- New skip reason `wheelchair_row`: exactly one of the sold row and the sub row is a wheelchair
-- row (WC, wheelchair, accessible, ADA, handicap; public.sub_finder_row_is_wheelchair, the
-- same test the sub finder uses). Like-for-like (WC against WC) is not skipped. Both capture
-- functions call this one, so the dry run and, through it, the live auto-buyer pick it up
-- without being re-created. Nothing is sent to any market.
--
-- One anchor, guarded by production's md5 (the function is another lane's: MIGRATION_CONVENTIONS 6a).
--
-- rollback: re-create n2s_dryrun_extra_reasons() from 20261104170000.

DO $do$
DECLARE
  d text := pg_get_functiondef('public.n2s_dryrun_extra_reasons(bigint, text, text, text, text, timestamptz)'::regprocedure);
  a text := $a$    v := array_append(v, 'row_letter_mismatch');
  END IF;
  RETURN v;$a$;
BEGIN
  IF position('wheelchair_row' IN d) > 0 THEN RETURN; END IF;        -- already applied
  IF md5(d) <> '32e24dd7b35e2ea5c0d31cb6ebcc59bb' THEN
    RAISE EXCEPTION 'n2s_dryrun_extra_reasons drifted from 20261104170000: re-derive this migration with lane D7';
  END IF;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN
    RAISE EXCEPTION 'n2s_dryrun_extra_reasons: the anchor was not found exactly once';
  END IF;
  EXECUTE replace(d, a, $n$    v := array_append(v, 'row_letter_mismatch');
  END IF;
  -- 20261113460000: exactly one of the two rows is a wheelchair row (WC, ADA, accessible ...)
  IF public.sub_finder_row_is_wheelchair(r_sold) <> public.sub_finder_row_is_wheelchair(r_sub) THEN
    v := array_append(v, 'wheelchair_row');
  END IF;
  RETURN v;$n$);
END
$do$;
