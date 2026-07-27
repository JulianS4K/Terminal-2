-- Migration 20260531131000 · lane:D0-authored → A1-apply · writes:get_macro_series · reads:macro_indicators · pre:(main HEAD) · auth:PENDING — D0-authored, NOT YET APPLIED; awaiting A1 review + apply (bot_chat flagged)
--
-- ⚠ D0 HAS NO APPLY AUTHORITY (BOT_HIERARCHY §6 / PROJECT_BIBLE §1+§6). Authored by D0
--   for the Performer page MACRO OVERLAY (touring/music variant). A1 reviews + applies.
--   Timestamp is provisional — A1 may bump on apply.
--
-- WHY: macro_indicators is service-role-walled (RLS policy `admin_only` USING false → no
--   authenticated row access). The FE (Path-C) cannot read the FRED series for the consumer-
--   sentiment overlay. This SECDEF wrapper exposes one series read-only, email-gated.
--
-- KEYING (schema-verified 2026-05-31): macro_indicators (series_id text, observation_date date,
--   value numeric, ...). Default series UMCSENT (Univ. Michigan consumer sentiment). Returns the
--   most-recent p_limit observations, oldest→newest for direct charting.
--
-- PATTERN: SECDEF + @s4kent.com email gate + REVOKE PUBLIC + GRANT anon/authenticated + STABLE.
--   p_limit clamped [1,600]. Read-only.

CREATE OR REPLACE FUNCTION public.get_macro_series(
  p_series_id text DEFAULT 'UMCSENT',
  p_limit     int  DEFAULT 60
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_rows  jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.observation_date), '[]'::jsonb)
  INTO v_rows FROM (
    SELECT observation_date, value
    FROM public.macro_indicators
    WHERE series_id = p_series_id
    ORDER BY observation_date DESC
    LIMIT greatest(1, least(coalesce(p_limit, 60), 600))
  ) m;

  RETURN jsonb_build_object(
    'series_id',    p_series_id,
    'generated_at', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'points',       coalesce(v_rows, '[]'::jsonb)
  );
END $func$;

REVOKE ALL ON FUNCTION public.get_macro_series(text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_macro_series(text, int) TO anon, authenticated;

COMMENT ON FUNCTION public.get_macro_series(text, int) IS
  'D0 Performer page — MACRO OVERLAY (music variant). Recent FRED observations for one series (default UMCSENT) from walled macro_indicators (RLS admin_only USING false), oldest→newest. SECDEF, email-gated @s4kent.com, STABLE, p_limit clamped [1,600]. D0-authored; A1 applies.';
