-- Migration 20261026204742 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "inbox_n2b_board_view" (version 20261026204742) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

CREATE TABLE IF NOT EXISTS public.inbox_n2b_view_key (
  key_sha256 text PRIMARY KEY,
  label      text,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);
ALTER TABLE public.inbox_n2b_view_key ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inbox_n2b_view_key FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.inbox_n2b_board_view(p_view_key text, p_pull boolean DEFAULT false,
                                                       p_per_order integer DEFAULT 3)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp' AS $$
DECLARE v_pull jsonb;
BEGIN
  IF p_view_key IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.inbox_n2b_view_key k
        WHERE k.revoked_at IS NULL
          AND k.key_sha256 = encode(extensions.digest(p_view_key, 'sha256'), 'hex')) THEN
    RAISE EXCEPTION 'unauthorized: bad view key' USING ERRCODE = '42501';
  END IF;
  IF p_pull THEN v_pull := public.inbox_n2b_pull(interval '2 minutes'); END IF;
  RETURN public.inbox_n2b_board(public.get_app_secret('APPSCRIPT_INGEST_SECRET'),
                                LEAST(GREATEST(COALESCE(p_per_order, 3), 1), 10))
         || jsonb_strip_nulls(jsonb_build_object('pull', v_pull));
END $$;
REVOKE ALL ON FUNCTION public.inbox_n2b_board_view(text, boolean, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.inbox_n2b_board_view(text, boolean, integer) TO anon, authenticated, service_role;

INSERT INTO public.inbox_n2b_view_key(key_sha256, label)
VALUES ('ece0345166cdcacde623a703d2aa48a7d2feadbb62431d0cbb6630360804e527', 'terminal')
ON CONFLICT DO NOTHING;
;
