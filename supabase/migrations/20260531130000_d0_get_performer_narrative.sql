-- Migration 20260531130000 · lane:D0-authored → A1-apply · writes:get_performer_narrative · reads:performer_wikipedia,sporting_rivalries · pre:(main HEAD) · auth:PENDING — D0-authored, NOT YET APPLIED; awaiting A1 review + apply (bot_chat flagged)
--
-- ⚠ D0 HAS NO APPLY AUTHORITY (BOT_HIERARCHY §6 / PROJECT_BIBLE §1+§6). Authored by D0
--   for the Performer page NARRATIVE block (Wikipedia bio + rivalries). A1 reviews + applies.
--   Timestamp is provisional — A1 may bump on apply.
--
-- WHY: performer_wikipedia + sporting_rivalries are service-role-walled (RLS policy
--   `admin_only` USING false → no authenticated row access; the table-level SELECT grant is
--   moot). The FE (Path-C, @s4kent.com JWT) therefore cannot read either. This SECDEF wrapper
--   exposes the narrative read-only behind the same email gate every sibling RPC uses.
--
-- KEYING (schema-verified 2026-05-31):
--   performer_wikipedia.tevo_performer_id (bigint) → latest non-rejected row (description/extract/url/image).
--   sporting_rivalries.{team_a_performer_id,team_b_performer_id} (bigint) → rows touching this performer;
--     opponent = the side that isn't p_performer_id (name from team_a/team_b text).
--
-- PATTERN: SECDEF + @s4kent.com email gate + REVOKE PUBLIC + GRANT anon/authenticated + STABLE +
--   SET search_path — identical to get_broker_performer_page (the page's ESPN RPC). Read-only.

CREATE OR REPLACE FUNCTION public.get_performer_narrative(
  p_performer_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email  text;
  v_wiki   jsonb;
  v_rivals jsonb;
BEGIN
  -- ---------- auth gate (mirrors get_broker_performer_page) ----------
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- ---------- Wikipedia: latest non-rejected match ----------
  SELECT to_jsonb(w) INTO v_wiki FROM (
    SELECT performer_name, wiki_title, wiki_url, description, extract, image_url,
           match_confidence, last_refreshed_at
    FROM public.performer_wikipedia
    WHERE tevo_performer_id = p_performer_id
      AND coalesce(is_rejected, false) = false
    ORDER BY last_refreshed_at DESC NULLS LAST
    LIMIT 1
  ) w;

  -- ---------- Rivalries: any pair touching this performer ----------
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.is_branded DESC NULLS LAST, r.rivalry_name), '[]'::jsonb)
  INTO v_rivals FROM (
    SELECT
      rivalry_name, league, rivalry_intensity, is_branded, wikipedia_url, notes,
      CASE WHEN team_a_performer_id = p_performer_id THEN team_b ELSE team_a END AS opponent_name,
      CASE WHEN team_a_performer_id = p_performer_id THEN team_b_performer_id ELSE team_a_performer_id END AS opponent_performer_id
    FROM public.sporting_rivalries
    WHERE team_a_performer_id = p_performer_id OR team_b_performer_id = p_performer_id
  ) r;

  RETURN jsonb_build_object(
    'tevo_performer_id', p_performer_id,
    'hidden',       (v_wiki IS NULL AND (v_rivals IS NULL OR v_rivals = '[]'::jsonb)),
    'generated_at', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'wiki',         v_wiki,
    'rivalries',    coalesce(v_rivals, '[]'::jsonb)
  );
END $func$;

REVOKE ALL ON FUNCTION public.get_performer_narrative(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_performer_narrative(bigint) TO anon, authenticated;

COMMENT ON FUNCTION public.get_performer_narrative(bigint) IS
  'D0 Performer page — NARRATIVE block. Wikipedia bio (performer_wikipedia, latest non-rejected) + rivalries (sporting_rivalries, pairs touching this performer; opponent = the other side). Both source tables are service-role-walled (RLS admin_only USING false); this SECDEF wrapper exposes them read-only. Email-gated @s4kent.com, STABLE. D0-authored; A1 applies.';
