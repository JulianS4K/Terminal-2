-- Migration 20261117120000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:llm_judge_config(new),llm_judge_call(new),llm_judge_decision(new),llm_clean()(new),llm_pick_corroborated()(new),llm_judge_call()(new),llm_match_cases()(new),llm_match_apply()(new),llm_match_judge()(new),llm_venue_cases()(new),llm_venue_apply()(new),llm_venue_judge()(new),v_llm_judge_review(new view),tickpick_catalog_map() fn (venue judge source),vivid_catalog_map() fn (venue judge source),tickpick_catalog_event/vivid_catalog_event/mlb_ticket_event(tevo_event_id fill-only — DML, apply gated),tickpick_catalog_venue/vivid_catalog_venue(tevo_venue_id fill-only — DML, apply gated),cron:llm_judge_hourly(new),cron:llm_venue_judge_daily(new) · reads:events,vault.decrypted_secrets(GEMINI_API_KEY),tickpick_catalog_*,vivid_catalog_*,mlb_ticket_event,mlb_ticket_game,mlb_venue_xref · pre:20261117110000
--
-- MAPPING PROGRAM — A LANGUAGE MODEL JUDGES WHAT THE RULES LEAVE OPEN.
--
-- Operator 2026-11-17: a Gemini API key "for processing power", to be spent on (1) the matches the rules cannot
-- decide, (2) the long tail of venues name + state cannot pair, (3) the MLB stadium events. What the rules leave:
-- 4,236 TickPick catalogue events at a paired venue with an EVO event on the day whose name the name rule cannot
-- fit ("George Mason Patriots vs. South Florida Bulls" / "South Florida Bulls at George Mason Patriots Mens
-- Basketball") or that two listings fit (978); 1,229 TickPick venues with upcoming events and no TEvo pairing;
-- 101 stadium events at a known park with an EVO event that day; Vivid's share once its mapper has run.
--
-- HOW IT IS KEPT SAFE. The model never sees a free choice: every case comes with the closed list of candidates the
-- rules already narrowed to (the EVO events at that venue on that day; the TEvo venues in that state), and a pick
-- outside the list, under the confidence floor (0.90), or on a candidate another row has since claimed is recorded
-- but never applied. Every call is logged (llm_judge_call: tokens, latency, status) and every answer is kept with
-- its reason (llm_judge_decision), so a wrong pick is traceable to the exact prompt and answer. Writes are the
-- same fill-only writes the mappers make (tevo_event_id with method 'llm_judge', audited in the source's own
-- audit table); the hourly mappers then verify them like any other match (day moved, event gone) and do the hub
-- and order fills. llm_judge_config.apply_enabled starts FALSE: the crons run as dry runs — decisions recorded,
-- nothing written — until the operator has read v_llm_judge_review and flips it. Caps: batch_size cases a call,
-- max_calls_per_run calls a run, daily_call_cap calls a day; the key is read from the vault at call time
-- (secret_name, default GEMINI_API_KEY) and sent in the x-goog-api-key header, never in a URL or a log.
--
-- Hardened after the automated security review of the first cut (same day): catalogue text is cleaned before it
-- enters a prompt; product listings are not candidates for non-product rows; the answer is parsed strictly and a
-- malformed one is an abstention, never an abort; and a pick is written only when something the model cannot fake
-- corroborates it (a shared word, the same start minute, the same city) — otherwise it is recorded and held. This
-- file is safe to run over the first cut (same signatures, the one new column added IF NOT EXISTS).
--
-- RULE 2: Gemini is not a listing source; the only upstream calls are inference requests to
-- generativelanguage.googleapis.com. Nothing is sent to any marketplace. The catalogue mappers gain one venue
-- source ('llm_judge', after name + state, before learned-from-matches), bodies otherwise mig 20261117110000's.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ───────────────────────── 1. configuration, call log, decisions ─────────────────────────
CREATE TABLE IF NOT EXISTS public.llm_judge_config (
  id                 int PRIMARY KEY CHECK (id = 1),
  enabled            boolean NOT NULL DEFAULT true,      -- call the model at all
  apply_enabled      boolean NOT NULL DEFAULT false,     -- write accepted decisions (FALSE = dry run: decisions recorded only)
  model              text NOT NULL DEFAULT 'gemini-2.5-flash',
  secret_name        text NOT NULL DEFAULT 'GEMINI_API_KEY',
  batch_size         int NOT NULL DEFAULT 40 CHECK (batch_size BETWEEN 1 AND 200),
  max_calls_per_run  int NOT NULL DEFAULT 8 CHECK (max_calls_per_run BETWEEN 1 AND 100),
  daily_call_cap     int NOT NULL DEFAULT 600,
  min_confidence     numeric NOT NULL DEFAULT 0.90 CHECK (min_confidence BETWEEN 0 AND 1),
  horizon_days       int NOT NULL DEFAULT 180,
  updated_at         timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.llm_judge_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
COMMENT ON TABLE public.llm_judge_config IS
  'The language-model judge (mig 20261117120000): model, vault secret name, batch and call caps, confidence floor. apply_enabled=false is a dry run — decisions recorded in llm_judge_decision, nothing written to the catalogues.';

CREATE TABLE IF NOT EXISTS public.llm_judge_call (
  id             bigserial PRIMARY KEY,
  at             timestamptz NOT NULL DEFAULT now(),
  purpose        text NOT NULL,          -- match | venue
  source         text NOT NULL,          -- tickpick | vivid | mlb_event
  model          text,
  status         int,                    -- HTTP status; NULL when the call was not made
  latency_ms     int,
  cases          int,
  prompt_tokens  int,
  output_tokens  int,
  error          text
);
CREATE INDEX IF NOT EXISTS llm_judge_call_at_idx ON public.llm_judge_call (at);

CREATE TABLE IF NOT EXISTS public.llm_judge_decision (
  id          bigserial PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  purpose     text NOT NULL,             -- match | venue
  source      text NOT NULL,             -- tickpick | vivid | mlb_event
  case_key    text NOT NULL,             -- the catalogue row's own id as text
  cand_hash   text NOT NULL,             -- md5 of the candidate ids: a case is judged once per candidate set
  payload     jsonb NOT NULL,            -- what the model saw about the catalogue row
  candidates  jsonb NOT NULL,            -- the closed list it chose from
  pick        text,                      -- the candidate id it chose, NULL = abstained
  confidence  numeric,
  reason      text,
  call_id     bigint REFERENCES public.llm_judge_call (id),
  applied     boolean NOT NULL DEFAULT false,
  applied_at  timestamptz,
  held_reason text,                      -- why an accepted-looking pick was not written: under_floor | uncorroborated | claimed | dry_run
  UNIQUE (purpose, source, case_key, cand_hash)
);
ALTER TABLE public.llm_judge_decision ADD COLUMN IF NOT EXISTS held_reason text;   -- the first cut of this file (applied 2026-11-17 19:4xZ) had no held_reason
CREATE INDEX IF NOT EXISTS llm_judge_decision_at_idx ON public.llm_judge_decision (at);
CREATE INDEX IF NOT EXISTS llm_judge_decision_open_idx ON public.llm_judge_decision (purpose, source) WHERE NOT applied;
COMMENT ON TABLE public.llm_judge_decision IS
  'One row per case the model judged (mig 20261117120000): what it saw, what it picked, how sure, why; applied says whether the pick was written. Review through v_llm_judge_review.';

ALTER TABLE public.llm_judge_config   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.llm_judge_call     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.llm_judge_decision ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.llm_judge_config, public.llm_judge_call, public.llm_judge_decision FROM anon, authenticated;
GRANT SELECT ON public.llm_judge_config, public.llm_judge_call, public.llm_judge_decision TO service_role;
GRANT UPDATE ON public.llm_judge_config TO service_role;

-- ───────────────────────── 1b. what goes into a prompt, and what may come out of one ─────────────────────────
-- Catalogue names are text other companies wrote: they go into the prompt stripped of control characters and cut to
-- 200 characters, and nothing the model says is enough on its own — an applied pick must also be corroborated by a
-- signal the model cannot fake: a shared word (4+ letters) between the catalogue row and the candidate, or the same
-- start minute, or (venues) the same city. A pick without that is recorded and held (held_reason), never written.
CREATE OR REPLACE FUNCTION public.llm_clean(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT left(trim(regexp_replace(regexp_replace(coalesce(p, ''), '[[:cntrl:]]+', ' ', 'g'), '\s+', ' ', 'g')), 200)
$function$;

CREATE OR REPLACE FUNCTION public.llm_pick_corroborated(p_purpose text, p_payload jsonb, p_cand jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  WITH a AS (
    SELECT lower(coalesce(p_payload->>'name', '') || ' ' || coalesce((SELECT string_agg(x#>>'{}', ' ') FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_payload->'performers') = 'array' THEN p_payload->'performers' ELSE '[]'::jsonb END) x), '')) AS t),
  b AS (
    SELECT lower(coalesce(p_cand->>'name', '') || ' ' || coalesce(p_cand->>'performer', '') || ' ' || coalesce(p_cand->>'location', '')) AS t)
  SELECT EXISTS (
           SELECT 1 FROM a, b, regexp_split_to_table(a.t, '[^a-z0-9]+') w
            WHERE length(w) >= 4 AND w NOT IN ('with', 'from', 'live', 'tour', 'show', 'night', 'game', 'party', 'event', 'events', 'club', 'stadium', 'arena', 'center', 'centre', 'theatre', 'theater', 'hall', 'park', 'field', 'presents', 'featuring', 'special', 'guest', 'tickets', 'ticket', 'concert', 'series', 'music', 'festival', 'the')
              AND w = ANY (regexp_split_to_array(b.t, '[^a-z0-9]+')))
      OR (p_purpose = 'match' AND p_payload->>'start_local' IS NOT NULL AND p_cand->>'start_local' IS NOT NULL
          AND left(p_payload->>'start_local', 16) = left(p_cand->>'start_local', 16))
      OR (p_purpose = 'venue' AND coalesce(p_payload->>'city', '') <> ''
          AND lower(trim(p_payload->>'city')) = lower(trim(split_part(coalesce(p_cand->>'location', ''), ',', 1))))
$function$;
REVOKE ALL ON FUNCTION public.llm_clean(text), public.llm_pick_corroborated(text, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.llm_clean(text), public.llm_pick_corroborated(text, jsonb, jsonb) TO service_role;

-- ───────────────────────── 2. one call to the model ─────────────────────────
-- Returns the parsed JSON the model answered (an array of decisions), or NULL when the call was not made or
-- failed; every outcome is a row in llm_judge_call. The key goes in the x-goog-api-key header.
CREATE OR REPLACE FUNCTION public.llm_judge_call(p_purpose text, p_source text, p_system text, p_user text, p_cases int)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  cfg      public.llm_judge_config;
  v_key    text;
  v_body   text;
  v_resp   extensions.http_response;
  v_t0     timestamptz := clock_timestamp();
  v_json   jsonb;
  v_text   text;
  v_out    jsonb;
  v_call   bigint;
  v_today  int;
BEGIN
  SELECT * INTO cfg FROM public.llm_judge_config WHERE id = 1;
  IF cfg.id IS NULL OR NOT cfg.enabled THEN
    INSERT INTO public.llm_judge_call (purpose, source, model, cases, error) VALUES (p_purpose, p_source, cfg.model, p_cases, 'disabled') RETURNING id INTO v_call;
    RETURN NULL;
  END IF;
  SELECT count(*) INTO v_today FROM public.llm_judge_call WHERE at > now() - interval '24 hours' AND status IS NOT NULL;
  IF v_today >= cfg.daily_call_cap THEN
    INSERT INTO public.llm_judge_call (purpose, source, model, cases, error) VALUES (p_purpose, p_source, cfg.model, p_cases, 'daily cap ' || cfg.daily_call_cap) RETURNING id INTO v_call;
    RETURN NULL;
  END IF;
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = cfg.secret_name LIMIT 1;
  IF v_key IS NULL OR v_key !~ '^[0-9A-Za-z_-]{20,}$' THEN
    INSERT INTO public.llm_judge_call (purpose, source, model, cases, error) VALUES (p_purpose, p_source, cfg.model, p_cases, 'no usable key in vault.' || cfg.secret_name) RETURNING id INTO v_call;
    RETURN NULL;
  END IF;

  v_body := jsonb_build_object(
    'systemInstruction', jsonb_build_object('parts', jsonb_build_array(jsonb_build_object('text', p_system))),
    'contents', jsonb_build_array(jsonb_build_object('role', 'user', 'parts', jsonb_build_array(jsonb_build_object('text', p_user)))),
    'generationConfig', jsonb_build_object('temperature', 0, 'responseMimeType', 'application/json', 'maxOutputTokens', 8192,
                                           'thinkingConfig', jsonb_build_object('thinkingBudget', 0)))::text;
  BEGIN
    PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '120000');
  EXCEPTION WHEN undefined_function THEN NULL;
  END;
  BEGIN
    v_resp := extensions.http((
      'POST',
      'https://generativelanguage.googleapis.com/v1beta/models/' || cfg.model || ':generateContent',
      ARRAY[extensions.http_header('x-goog-api-key', v_key), extensions.http_header('Content-Type', 'application/json')],
      'application/json',
      v_body)::extensions.http_request);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.llm_judge_call (purpose, source, model, cases, latency_ms, error)
    VALUES (p_purpose, p_source, cfg.model, p_cases, (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int, 'http: ' || SQLERRM) RETURNING id INTO v_call;
    RETURN NULL;
  END;

  v_json := public.safe_jsonb(v_resp.content);
  v_text := v_json->'candidates'->0->'content'->'parts'->0->>'text';
  v_text := regexp_replace(regexp_replace(coalesce(v_text, ''), '^\s*```(json)?\s*', ''), '\s*```\s*$', '');
  v_out  := public.safe_jsonb(v_text);
  IF v_out IS NOT NULL AND jsonb_typeof(v_out) = 'object' THEN
    v_out := coalesce(v_out->'decisions', v_out->'results', v_out->'cases', v_out->'answers');
  END IF;
  INSERT INTO public.llm_judge_call (purpose, source, model, status, latency_ms, cases, prompt_tokens, output_tokens, error)
  VALUES (p_purpose, p_source, cfg.model, v_resp.status, (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int, p_cases,
          (v_json->'usageMetadata'->>'promptTokenCount')::int, (v_json->'usageMetadata'->>'candidatesTokenCount')::int,
          CASE WHEN v_resp.status <> 200 THEN left(coalesce(v_json->'error'->>'message', v_resp.content), 500)
               WHEN v_out IS NULL OR jsonb_typeof(v_out) <> 'array' THEN 'unparseable answer: ' || left(coalesce(v_text, v_resp.content), 300) END)
  RETURNING id INTO v_call;
  IF v_resp.status <> 200 OR v_out IS NULL OR jsonb_typeof(v_out) <> 'array' THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('call_id', v_call, 'decisions', v_out);
END $function$;

-- ───────────────────────── 3. the match judge ─────────────────────────
-- The cases a source leaves open: an unmatched catalogue row at a paired venue, with the EVO events of that venue
-- on its local day as the closed candidate list (claimed ones left out), not yet judged for this candidate set.
CREATE OR REPLACE FUNCTION public.llm_match_cases(p_source text, p_limit int, p_include_judged boolean DEFAULT false)
 RETURNS TABLE(case_key text, payload jsonb, candidates jsonb, cand_ids bigint[], cand_hash text)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_h int := (SELECT horizon_days FROM public.llm_judge_config WHERE id = 1);
BEGIN
  IF p_source = 'tickpick' THEN
    RETURN QUERY
    WITH c AS (
      SELECT x.tp_event_id, x.name, x.performers, x.event_local, x.time_confirmed, x.event_date,
             nullif(concat_ws(' / ', x.cat_parent, x.cat_child, x.cat_grandchild), '') AS cat_name,
             v.name AS venue, v.city, v.state, v.tevo_venue_id
        FROM public.tickpick_catalog_event x
        JOIN public.tickpick_catalog_venue v ON v.tp_venue_id = x.tp_venue_id AND v.tevo_venue_id IS NOT NULL
       WHERE x.tevo_event_id IS NULL AND x.date_confirmed AND x.status IS DISTINCT FROM 'canceled' AND x.merged_into IS NULL
         AND x.event_date BETWEEN current_date AND current_date + coalesce(v_h, 180)
         AND coalesce(x.venue_country, 'US') IN ('US', 'CA', 'MX')),
    k AS (
      SELECT c.*, (SELECT jsonb_agg(jsonb_build_object('id', e.id, 'name', public.llm_clean(e.name), 'performer', public.llm_clean(e.primary_performer_name), 'start_local', e.occurs_at_local) ORDER BY e.occurs_at_local, e.id)
                     FROM public.events e
                    WHERE e.venue_id = c.tevo_venue_id AND left(e.occurs_at_local, 10) = to_char(c.event_date, 'YYYY-MM-DD')
                      AND e.state IS DISTINCT FROM 'ignored'
                      AND (lower(e.name) !~ '(parking|tailgate|package|shuttle|hospitality|\\mvip\\M)' OR lower(c.name) ~ '(parking|tailgate|package|shuttle|hospitality|\\mvip\\M)')   -- a product listing only for a product row
                      AND NOT EXISTS (SELECT 1 FROM public.tickpick_catalog_event o WHERE o.tevo_event_id = e.id)) AS cands
        FROM c)
    SELECT k.tp_event_id::text,
           jsonb_strip_nulls(jsonb_build_object('name', public.llm_clean(k.name), 'performers', (SELECT jsonb_agg(public.llm_clean(p->>'name')) FROM jsonb_array_elements(coalesce(k.performers, '[]'::jsonb)) p),
                                                'start_local', k.event_local, 'time_confirmed', k.time_confirmed, 'category', public.llm_clean(k.cat_name),
                                                'venue', public.llm_clean(k.venue), 'city', public.llm_clean(k.city), 'state', public.llm_clean(k.state))),
           k.cands,
           (SELECT array_agg((x->>'id')::bigint ORDER BY (x->>'id')::bigint) FROM jsonb_array_elements(k.cands) x),
           md5((SELECT string_agg(x->>'id', ',' ORDER BY (x->>'id')::bigint) FROM jsonb_array_elements(k.cands) x))
      FROM k
     WHERE k.cands IS NOT NULL
       AND (p_include_judged OR NOT EXISTS (SELECT 1 FROM public.llm_judge_decision d
                        WHERE d.purpose = 'match' AND d.source = 'tickpick' AND d.case_key = k.tp_event_id::text
                          AND d.cand_hash = md5((SELECT string_agg(x->>'id', ',' ORDER BY (x->>'id')::bigint) FROM jsonb_array_elements(k.cands) x))))
     ORDER BY k.event_date, k.tp_event_id
     LIMIT p_limit;
  ELSIF p_source = 'vivid' THEN
    RETURN QUERY
    WITH c AS (
      SELECT x.vivid_event_id, x.name, x.performers, x.event_local, x.time_known, x.event_date, x.category, x.event_type,
             v.name AS venue, v.city, v.state, v.tevo_venue_id
        FROM public.vivid_catalog_event x
        JOIN public.vivid_catalog_venue v ON v.vivid_venue_id = x.vivid_venue_id AND v.tevo_venue_id IS NOT NULL
       WHERE x.tevo_event_id IS NULL
         AND x.event_date BETWEEN current_date AND current_date + coalesce(v_h, 180)
         AND coalesce(x.venue_country, 'US') IN ('US', 'CA', 'MX')),
    k AS (
      SELECT c.*, (SELECT jsonb_agg(jsonb_build_object('id', e.id, 'name', public.llm_clean(e.name), 'performer', public.llm_clean(e.primary_performer_name), 'start_local', e.occurs_at_local) ORDER BY e.occurs_at_local, e.id)
                     FROM public.events e
                    WHERE e.venue_id = c.tevo_venue_id AND left(e.occurs_at_local, 10) = to_char(c.event_date, 'YYYY-MM-DD')
                      AND e.state IS DISTINCT FROM 'ignored'
                      AND (lower(e.name) !~ '(parking|tailgate|package|shuttle|hospitality|\\mvip\\M)' OR lower(c.name) ~ '(parking|tailgate|package|shuttle|hospitality|\\mvip\\M)')
                      AND NOT EXISTS (SELECT 1 FROM public.vivid_catalog_event o WHERE o.tevo_event_id = e.id)) AS cands
        FROM c)
    SELECT k.vivid_event_id::text,
           jsonb_strip_nulls(jsonb_build_object('name', public.llm_clean(k.name), 'performers', (SELECT jsonb_agg(public.llm_clean(coalesce(p->>'name', p#>>'{}'))) FROM jsonb_array_elements(coalesce(k.performers, '[]'::jsonb)) p),
                                                'start_local', CASE WHEN k.time_known THEN k.event_local END, 'time_confirmed', k.time_known,
                                                'category', public.llm_clean(k.category), 'type', public.llm_clean(k.event_type), 'venue', public.llm_clean(k.venue), 'city', public.llm_clean(k.city), 'state', public.llm_clean(k.state))),
           k.cands,
           (SELECT array_agg((x->>'id')::bigint ORDER BY (x->>'id')::bigint) FROM jsonb_array_elements(k.cands) x),
           md5((SELECT string_agg(x->>'id', ',' ORDER BY (x->>'id')::bigint) FROM jsonb_array_elements(k.cands) x))
      FROM k
     WHERE k.cands IS NOT NULL
       AND (p_include_judged OR NOT EXISTS (SELECT 1 FROM public.llm_judge_decision d
                        WHERE d.purpose = 'match' AND d.source = 'vivid' AND d.case_key = k.vivid_event_id::text
                          AND d.cand_hash = md5((SELECT string_agg(x->>'id', ',' ORDER BY (x->>'id')::bigint) FROM jsonb_array_elements(k.cands) x))))
     ORDER BY k.event_date, k.vivid_event_id
     LIMIT p_limit;
  ELSIF p_source = 'mlb_event' THEN
    RETURN QUERY
    WITH c AS (
      SELECT x.schedule_id, x.title, x.descr, x.event_type, x.event_time_local, x.is_tbd, x.event_date, x.venue_name, x.venue_city, xr.tevo_venue_id
        FROM public.mlb_ticket_event x
        JOIN public.mlb_venue_xref xr ON xr.mlb_venue_id = x.venue_id AND xr.tevo_venue_id IS NOT NULL
       WHERE x.tevo_event_id IS NULL AND x.removed_at IS NULL
         AND x.event_date BETWEEN current_date AND current_date + coalesce(v_h, 180)
         AND x.title !~* '(package|hospitality|suites?\M|parking|pre-?game|post-?game|pickup|membership|party|\mpass(es)?\M)'),
    k AS (
      SELECT c.*, (SELECT jsonb_agg(jsonb_build_object('id', e.id, 'name', public.llm_clean(e.name), 'performer', public.llm_clean(e.primary_performer_name), 'start_local', e.occurs_at_local) ORDER BY e.occurs_at_local, e.id)
                     FROM public.events e
                    WHERE e.venue_id = c.tevo_venue_id AND left(e.occurs_at_local, 10) = c.event_date::text
                      AND e.state IS DISTINCT FROM 'ignored'
                      AND lower(e.name) !~ '(parking|tailgate|package|shuttle|hospitality|\\mvip\\M)'
                      AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game g WHERE g.tevo_event_id = e.id)
                      AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_event o WHERE o.tevo_event_id = e.id)) AS cands
        FROM c)
    SELECT k.schedule_id::text,
           jsonb_strip_nulls(jsonb_build_object('name', public.llm_clean(k.title), 'description', public.llm_clean(k.descr), 'type', public.llm_clean(k.event_type),
                                                'start_local', CASE WHEN NOT coalesce(k.is_tbd, false) THEN k.event_time_local::text END,
                                                'venue', public.llm_clean(k.venue_name), 'city', public.llm_clean(k.venue_city), 'note', 'a non-game event sold by an MLB club at its ballpark')),
           k.cands,
           (SELECT array_agg((x->>'id')::bigint ORDER BY (x->>'id')::bigint) FROM jsonb_array_elements(k.cands) x),
           md5((SELECT string_agg(x->>'id', ',' ORDER BY (x->>'id')::bigint) FROM jsonb_array_elements(k.cands) x))
      FROM k
     WHERE k.cands IS NOT NULL
       AND (p_include_judged OR NOT EXISTS (SELECT 1 FROM public.llm_judge_decision d
                        WHERE d.purpose = 'match' AND d.source = 'mlb_event' AND d.case_key = k.schedule_id::text
                          AND d.cand_hash = md5((SELECT string_agg(x->>'id', ',' ORDER BY (x->>'id')::bigint) FROM jsonb_array_elements(k.cands) x))))
     ORDER BY k.event_date, k.schedule_id
     LIMIT p_limit;
  ELSE
    RAISE EXCEPTION 'llm_match_cases: unknown source %', p_source;
  END IF;
END $function$;

-- Write one accepted match (fill-only, the candidate still free), audited in the source's own audit table.
CREATE OR REPLACE FUNCTION public.llm_match_apply(p_source text, p_case text, p_hash text, p_pick bigint, p_conf numeric, p_reason text, p_run uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_ok boolean := false; v_note text := format('llm_judge %s: %s', p_conf, left(coalesce(p_reason, ''), 200));
BEGIN
  IF p_source = 'tickpick' THEN
    UPDATE public.tickpick_catalog_event c
       SET tevo_event_id = p_pick, tevo_match_method = 'llm_judge', tevo_matched_at = now()
     WHERE c.tp_event_id = p_case::bigint AND c.tevo_event_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.tickpick_catalog_event o WHERE o.tevo_event_id = p_pick);
    v_ok := FOUND;
    IF v_ok THEN
      INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, new_tevo, note)
      VALUES (p_run, p_case::bigint, 'match', 'tickpick_catalog_event', p_case, p_pick, v_note);
    END IF;
  ELSIF p_source = 'vivid' THEN
    UPDATE public.vivid_catalog_event c
       SET tevo_event_id = p_pick, tevo_match_method = 'llm_judge', tevo_matched_at = now()
     WHERE c.vivid_event_id = p_case::bigint AND c.tevo_event_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.vivid_catalog_event o WHERE o.tevo_event_id = p_pick);
    v_ok := FOUND;
    IF v_ok THEN
      INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo, note)
      VALUES (p_run, p_case::bigint, 'match', 'vivid_catalog_event', p_case, p_pick, v_note);
    END IF;
  ELSIF p_source = 'mlb_event' THEN
    UPDATE public.mlb_ticket_event v
       SET tevo_event_id = p_pick, tevo_match_method = 'llm_judge', tevo_matched_at = now(), changed_at = now()
     WHERE v.schedule_id = p_case::bigint AND v.tevo_event_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game g WHERE g.tevo_event_id = p_pick)
       AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_event o WHERE o.tevo_event_id = p_pick);
    v_ok := FOUND;
    IF v_ok THEN
      INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, new_tevo, note)
      VALUES (p_run, p_case::bigint, 'event_match', 'mlb_ticket_event', p_case, p_pick, v_note);
    END IF;
  ELSE
    RAISE EXCEPTION 'llm_match_apply: unknown source %', p_source;
  END IF;
  IF v_ok THEN
    UPDATE public.llm_judge_decision d SET applied = true, applied_at = now()
     WHERE d.purpose = 'match' AND d.source = p_source AND d.case_key = p_case AND d.cand_hash = p_hash AND NOT d.applied;
    UPDATE public.llm_judge_decision d SET held_reason = NULL WHERE d.purpose = 'match' AND d.source = p_source AND d.case_key = p_case AND d.cand_hash = p_hash AND d.applied;
  END IF;
  RETURN v_ok;
END $function$;

-- Judge a source's open cases in batches; p_apply NULL = llm_judge_config.apply_enabled. A pick is applied only when
-- it is one of the case's candidates, at or above the confidence floor, and the candidate is still free. With apply
-- on, decisions recorded earlier (a dry run) whose case is still open with the same candidates are applied first,
-- without a new call — so a reviewed dry run becomes the first live run.
CREATE OR REPLACE FUNCTION public.llm_match_judge(p_source text, p_apply boolean DEFAULT NULL, p_max_calls int DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  cfg        public.llm_judge_config;
  v_apply    boolean;
  v_calls    int := 0;
  v_cases    int := 0;
  v_picked   int := 0;
  v_applied  int := 0;
  v_replayed int := 0;
  v_abst     int := 0;
  v_err      int := 0;
  v_run      uuid := gen_random_uuid();
  v_ans      jsonb;
  v_sys      text;
  r          record;
  d          jsonb;
  v_pick     bigint;
  v_conf     numeric;
  v_hold     text;
  v_n        int;
BEGIN
  SELECT * INTO cfg FROM public.llm_judge_config WHERE id = 1;
  v_apply := coalesce(p_apply, cfg.apply_enabled, false);
  v_sys := 'You map ticket-marketplace catalogue events to the matching event in our master event list (EVO). '
        || 'For each case you get one catalogue event (name, performers, local start, venue) and the EVO events listed at the same venue on the same local day. '
        || 'Pick the EVO event that is the same performance: the same show, concert, game or session, on that day, at that venue. '
        || 'Rules: a parking pass, shuttle, VIP or hospitality package, pre-party or meet-and-greet is not the event (unless the catalogue event is one too). '
        || 'Two performances on one day (a matinee and an evening show, a doubleheader) are different events: use the start times when both sides have one, and abstain when they conflict or the catalogue time is unknown and more than one candidate could be it. '
        || 'A different opponent, a different artist, a tribute act or a different session of a tournament is a different event. '
        || 'When no candidate is the same performance, or two could be, abstain with pick null. '
        || 'Answer with a JSON array only, exactly one object per case, in this shape: '
        || '[{"case": "<case id as given>", "pick": <EVO id number or null>, "confidence": <number 0 to 1>, "reason": "<one short sentence>"}].';

  -- 0. replay: what an earlier run decided about a case that is still open with the same candidates
  IF v_apply THEN
    FOR r IN SELECT c.case_key, c.cand_hash, dd.pick, dd.confidence, dd.reason
               FROM public.llm_match_cases(p_source, 100000, true) c
               JOIN public.llm_judge_decision dd ON dd.purpose = 'match' AND dd.source = p_source AND dd.case_key = c.case_key AND dd.cand_hash = c.cand_hash
              WHERE NOT dd.applied AND dd.pick IS NOT NULL AND dd.confidence >= cfg.min_confidence
                AND dd.pick::bigint = ANY (c.cand_ids)
                AND public.llm_pick_corroborated('match', dd.payload, (SELECT x FROM jsonb_array_elements(dd.candidates) x WHERE x->>'id' = dd.pick LIMIT 1)) LOOP
      IF public.llm_match_apply(p_source, r.case_key, r.cand_hash, r.pick::bigint, r.confidence, r.reason, v_run) THEN v_replayed := v_replayed + 1; END IF;
    END LOOP;
  END IF;

  DROP TABLE IF EXISTS _lj_batch;
  CREATE TEMP TABLE _lj_batch (case_key text PRIMARY KEY, payload jsonb, candidates jsonb, cand_ids bigint[], cand_hash text) ON COMMIT DROP;

  WHILE v_calls < coalesce(p_max_calls, cfg.max_calls_per_run, 1) LOOP
    TRUNCATE _lj_batch;
    INSERT INTO _lj_batch SELECT * FROM public.llm_match_cases(p_source, cfg.batch_size);
    EXIT WHEN NOT EXISTS (SELECT 1 FROM _lj_batch);
    SELECT count(*) INTO v_n FROM _lj_batch;
    v_cases := v_cases + v_n;
    v_calls := v_calls + 1;

    v_ans := public.llm_judge_call('match', p_source, v_sys,
               (SELECT jsonb_build_object('cases', jsonb_agg(jsonb_build_object('case', b.case_key, 'event', b.payload, 'candidates', b.candidates) ORDER BY b.case_key))::text FROM _lj_batch b),
               v_n);
    IF v_ans IS NULL THEN
      v_err := v_err + 1;
      EXIT;   -- the cases stay open for the next run; a missing key or a spent cap would loop, so this run stops here
    END IF;

    -- record every answer; a case the model skipped, or answered unreadably, is recorded as an abstention so it is not re-asked for the same candidates
    FOR r IN SELECT b.*, (SELECT x FROM jsonb_array_elements(v_ans->'decisions') x WHERE x->>'case' = b.case_key LIMIT 1) AS ans FROM _lj_batch b LOOP
      d := r.ans; v_pick := NULL; v_conf := NULL; v_hold := NULL;
      BEGIN
        v_pick := CASE WHEN d IS NOT NULL AND (d->>'pick') ~ '^\d{1,18}$' THEN (d->>'pick')::bigint END;
        v_conf := CASE WHEN d IS NOT NULL AND (d->>'confidence') ~ '^(0(\.\d{1,6})?|1(\.0{1,6})?|\.\d{1,6})$' THEN (d->>'confidence')::numeric END;
      EXCEPTION WHEN OTHERS THEN v_pick := NULL; v_conf := NULL;
      END;
      IF v_pick IS NOT NULL AND NOT (v_pick = ANY (r.cand_ids)) THEN v_pick := NULL; v_conf := 0; END IF;   -- outside the list: an abstention
      IF v_pick IS NOT NULL THEN
        v_hold := CASE WHEN v_conf IS NULL OR v_conf < cfg.min_confidence THEN 'under_floor'
                       WHEN NOT public.llm_pick_corroborated('match', r.payload, (SELECT x FROM jsonb_array_elements(r.candidates) x WHERE (x->>'id')::bigint = v_pick LIMIT 1)) THEN 'uncorroborated'
                       WHEN NOT v_apply THEN 'dry_run' END;
      END IF;
      INSERT INTO public.llm_judge_decision (purpose, source, case_key, cand_hash, payload, candidates, pick, confidence, reason, call_id, held_reason)
      VALUES ('match', p_source, r.case_key, r.cand_hash, r.payload, r.candidates, v_pick::text, v_conf,
              left(coalesce(d->>'reason', CASE WHEN d IS NULL THEN 'no answer for this case' END), 500), (v_ans->>'call_id')::bigint, v_hold)
      ON CONFLICT (purpose, source, case_key, cand_hash) DO UPDATE
        SET at = now(), pick = EXCLUDED.pick, confidence = EXCLUDED.confidence, reason = EXCLUDED.reason, call_id = EXCLUDED.call_id, held_reason = EXCLUDED.held_reason;
      IF v_pick IS NULL THEN v_abst := v_abst + 1; CONTINUE; END IF;
      v_picked := v_picked + 1;
      IF v_hold IS NULL THEN
        IF public.llm_match_apply(p_source, r.case_key, r.cand_hash, v_pick, v_conf, d->>'reason', v_run) THEN v_applied := v_applied + 1;
        ELSE UPDATE public.llm_judge_decision SET held_reason = 'claimed' WHERE purpose = 'match' AND source = p_source AND case_key = r.case_key AND cand_hash = r.cand_hash; END IF;
      END IF;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('run_id', v_run, 'source', p_source, 'applied_mode', v_apply, 'calls', v_calls, 'cases', v_cases,
                            'picked', v_picked, 'abstained', v_abst, 'applied', v_applied, 'replayed', v_replayed, 'call_errors', v_err,
                            'open_cases', (SELECT count(*) FROM public.llm_match_cases(p_source, 100000)));
END $function$;

-- ───────────────────────── 4. the venue judge ─────────────────────────
-- A catalogue venue name + state could not pair, with upcoming events: the TEvo venues in its state that share its
-- city or resemble its name (pg_trgm), at most ten, as the closed list.
CREATE OR REPLACE FUNCTION public.llm_venue_cases(p_source text, p_limit int, p_include_judged boolean DEFAULT false)
 RETURNS TABLE(case_key text, payload jsonb, candidates jsonb, cand_ids bigint[], cand_hash text)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_h int := (SELECT horizon_days FROM public.llm_judge_config WHERE id = 1);
BEGIN
  IF p_source NOT IN ('tickpick', 'vivid') THEN RAISE EXCEPTION 'llm_venue_cases: unknown source %', p_source; END IF;
  RETURN QUERY EXECUTE format($q$
    WITH tv AS (                                         -- TEvo venues with upcoming events: name, city, state
      SELECT e.venue_id, min(e.venue_name) AS name, min(e.venue_location) AS loc,
             lower(trim(split_part(min(e.venue_location), ',', 1))) AS city,
             upper(trim(regexp_replace(min(e.venue_location), '^.*,\s*', ''))) AS st
        FROM public.events e
       WHERE e.occurs_at_local >= to_char(now(), 'YYYY-MM-DD') AND e.venue_id IS NOT NULL AND e.venue_location LIKE '%%,%%'
       GROUP BY e.venue_id),
    cv AS (                                              -- the catalogue venues left open, with upcoming events
      SELECT v.%1$I AS vid, v.name, v.city, v.state, v.country, count(*) AS upcoming
        FROM public.%2$I v JOIN public.%3$I x ON x.%1$I = v.%1$I
       WHERE v.tevo_venue_id IS NULL AND coalesce(v.country, 'US') IN ('US', 'CA', 'MX') AND coalesce(v.state, '') <> ''
         AND x.event_date BETWEEN current_date AND current_date + %4$s
       GROUP BY v.%1$I, v.name, v.city, v.state, v.country),
    k AS (
      SELECT cv.*, (SELECT jsonb_agg(jsonb_build_object('id', t.venue_id, 'name', public.llm_clean(t.name), 'location', public.llm_clean(t.loc)) ORDER BY t.sim DESC, t.venue_id)
                      FROM (SELECT tv.*, similarity(lower(tv.name), lower(cv.name)) AS sim FROM tv
                             WHERE tv.st = upper(trim(cv.state))
                               AND (tv.city = lower(trim(coalesce(cv.city, ''))) OR similarity(lower(tv.name), lower(cv.name)) >= 0.35)
                             ORDER BY similarity(lower(tv.name), lower(cv.name)) DESC, tv.venue_id LIMIT 10) t) AS cands
        FROM cv)
    SELECT k.vid::text,
           jsonb_strip_nulls(jsonb_build_object('name', public.llm_clean(k.name), 'city', public.llm_clean(k.city), 'state', public.llm_clean(k.state), 'country', public.llm_clean(k.country), 'upcoming_events', k.upcoming)),
           k.cands,
           (SELECT array_agg((x->>'id')::bigint ORDER BY (x->>'id')::bigint) FROM jsonb_array_elements(k.cands) x),
           md5((SELECT string_agg(x->>'id', ',' ORDER BY (x->>'id')::bigint) FROM jsonb_array_elements(k.cands) x))
      FROM k
     WHERE k.cands IS NOT NULL
       AND (%7$L::boolean OR NOT EXISTS (SELECT 1 FROM public.llm_judge_decision d
                        WHERE d.purpose = 'venue' AND d.source = %5$L AND d.case_key = k.vid::text
                          AND d.cand_hash = md5((SELECT string_agg(x->>'id', ',' ORDER BY (x->>'id')::bigint) FROM jsonb_array_elements(k.cands) x))))
     ORDER BY k.upcoming DESC, k.vid
     LIMIT %6$s$q$,
    CASE p_source WHEN 'tickpick' THEN 'tp_venue_id' ELSE 'vivid_venue_id' END,
    CASE p_source WHEN 'tickpick' THEN 'tickpick_catalog_venue' ELSE 'vivid_catalog_venue' END,
    CASE p_source WHEN 'tickpick' THEN 'tickpick_catalog_event' ELSE 'vivid_catalog_event' END,
    coalesce(v_h, 180), p_source, p_limit, p_include_judged);
END $function$;

CREATE OR REPLACE FUNCTION public.llm_venue_apply(p_source text, p_case text, p_hash text, p_pick bigint, p_conf numeric, p_reason text, p_run uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_ok boolean := false; v_note text := format('tevo_venue %s via llm_judge %s: %s', p_pick, p_conf, left(coalesce(p_reason, ''), 200));
BEGIN
  IF p_source = 'tickpick' THEN
    UPDATE public.tickpick_catalog_venue v SET tevo_venue_id = p_pick, method = 'llm_judge', derived_at = now()
     WHERE v.tp_venue_id = p_case::bigint AND v.tevo_venue_id IS NULL;
    v_ok := FOUND;
    IF v_ok THEN INSERT INTO public.tickpick_catalog_audit (run_id, action, target, target_key, note) VALUES (p_run, 'venue_xref', 'tickpick_catalog_venue', p_case, v_note); END IF;
  ELSIF p_source = 'vivid' THEN
    UPDATE public.vivid_catalog_venue v SET tevo_venue_id = p_pick, method = 'llm_judge', derived_at = now()
     WHERE v.vivid_venue_id = p_case::bigint AND v.tevo_venue_id IS NULL;
    v_ok := FOUND;
    IF v_ok THEN INSERT INTO public.vivid_catalog_audit (run_id, action, target, target_key, note) VALUES (p_run, 'venue_xref', 'vivid_catalog_venue', p_case, v_note); END IF;
  ELSE
    RAISE EXCEPTION 'llm_venue_apply: unknown source %', p_source;
  END IF;
  IF v_ok THEN
    UPDATE public.llm_judge_decision d SET applied = true, applied_at = now()
     WHERE d.purpose = 'venue' AND d.source = p_source AND d.case_key = p_case AND d.cand_hash = p_hash AND NOT d.applied;
    UPDATE public.llm_judge_decision d SET held_reason = NULL WHERE d.purpose = 'venue' AND d.source = p_source AND d.case_key = p_case AND d.cand_hash = p_hash AND d.applied;
  END IF;
  RETURN v_ok;
END $function$;

CREATE OR REPLACE FUNCTION public.llm_venue_judge(p_source text, p_apply boolean DEFAULT NULL, p_max_calls int DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  cfg        public.llm_judge_config;
  v_apply    boolean;
  v_calls    int := 0;
  v_cases    int := 0;
  v_picked   int := 0;
  v_applied  int := 0;
  v_replayed int := 0;
  v_abst     int := 0;
  v_err      int := 0;
  v_run      uuid := gen_random_uuid();
  v_ans      jsonb;
  v_sys      text;
  r          record;
  d          jsonb;
  v_pick     bigint;
  v_conf     numeric;
  v_hold     text;
  v_n        int;
BEGIN
  IF p_source NOT IN ('tickpick', 'vivid') THEN RAISE EXCEPTION 'llm_venue_judge: unknown source %', p_source; END IF;
  SELECT * INTO cfg FROM public.llm_judge_config WHERE id = 1;
  v_apply := coalesce(p_apply, cfg.apply_enabled, false);
  v_sys := 'You pair venues from a ticket-marketplace catalogue with the same venue in our master venue list. '
        || 'For each case you get one catalogue venue (name, city, state) and candidate master venues in the same state. '
        || 'Pick the candidate that is the same physical venue: sponsor renames and spelling variants count as the same venue; '
        || 'a different room, hall or stage inside the same complex is a different venue when the list has it as its own entry; '
        || 'a different venue in the same city is not a match. When no candidate is the same venue, or two could be, abstain with pick null. '
        || 'Answer with a JSON array only, exactly one object per case, in this shape: '
        || '[{"case": "<case id as given>", "pick": <master venue id number or null>, "confidence": <number 0 to 1>, "reason": "<one short sentence>"}].';

  IF v_apply THEN
    FOR r IN SELECT c.case_key, c.cand_hash, dd.pick, dd.confidence, dd.reason
               FROM public.llm_venue_cases(p_source, 100000, true) c
               JOIN public.llm_judge_decision dd ON dd.purpose = 'venue' AND dd.source = p_source AND dd.case_key = c.case_key AND dd.cand_hash = c.cand_hash
              WHERE NOT dd.applied AND dd.pick IS NOT NULL AND dd.confidence >= cfg.min_confidence
                AND dd.pick::bigint = ANY (c.cand_ids)
                AND public.llm_pick_corroborated('venue', dd.payload, (SELECT x FROM jsonb_array_elements(dd.candidates) x WHERE x->>'id' = dd.pick LIMIT 1)) LOOP
      IF public.llm_venue_apply(p_source, r.case_key, r.cand_hash, r.pick::bigint, r.confidence, r.reason, v_run) THEN v_replayed := v_replayed + 1; END IF;
    END LOOP;
  END IF;

  DROP TABLE IF EXISTS _lv_batch;
  CREATE TEMP TABLE _lv_batch (case_key text PRIMARY KEY, payload jsonb, candidates jsonb, cand_ids bigint[], cand_hash text) ON COMMIT DROP;

  WHILE v_calls < coalesce(p_max_calls, cfg.max_calls_per_run, 1) LOOP
    TRUNCATE _lv_batch;
    INSERT INTO _lv_batch SELECT * FROM public.llm_venue_cases(p_source, cfg.batch_size);
    EXIT WHEN NOT EXISTS (SELECT 1 FROM _lv_batch);
    SELECT count(*) INTO v_n FROM _lv_batch;
    v_cases := v_cases + v_n;
    v_calls := v_calls + 1;
    v_ans := public.llm_judge_call('venue', p_source, v_sys,
               (SELECT jsonb_build_object('cases', jsonb_agg(jsonb_build_object('case', b.case_key, 'venue', b.payload, 'candidates', b.candidates) ORDER BY b.case_key))::text FROM _lv_batch b),
               v_n);
    IF v_ans IS NULL THEN v_err := v_err + 1; EXIT; END IF;

    FOR r IN SELECT b.*, (SELECT x FROM jsonb_array_elements(v_ans->'decisions') x WHERE x->>'case' = b.case_key LIMIT 1) AS ans FROM _lv_batch b LOOP
      d := r.ans; v_pick := NULL; v_conf := NULL; v_hold := NULL;
      BEGIN
        v_pick := CASE WHEN d IS NOT NULL AND (d->>'pick') ~ '^\d{1,18}$' THEN (d->>'pick')::bigint END;
        v_conf := CASE WHEN d IS NOT NULL AND (d->>'confidence') ~ '^(0(\.\d{1,6})?|1(\.0{1,6})?|\.\d{1,6})$' THEN (d->>'confidence')::numeric END;
      EXCEPTION WHEN OTHERS THEN v_pick := NULL; v_conf := NULL;
      END;
      IF v_pick IS NOT NULL AND NOT (v_pick = ANY (r.cand_ids)) THEN v_pick := NULL; v_conf := 0; END IF;
      IF v_pick IS NOT NULL THEN
        v_hold := CASE WHEN v_conf IS NULL OR v_conf < cfg.min_confidence THEN 'under_floor'
                       WHEN NOT public.llm_pick_corroborated('venue', r.payload, (SELECT x FROM jsonb_array_elements(r.candidates) x WHERE (x->>'id')::bigint = v_pick LIMIT 1)) THEN 'uncorroborated'
                       WHEN NOT v_apply THEN 'dry_run' END;
      END IF;
      INSERT INTO public.llm_judge_decision (purpose, source, case_key, cand_hash, payload, candidates, pick, confidence, reason, call_id, held_reason)
      VALUES ('venue', p_source, r.case_key, r.cand_hash, r.payload, r.candidates, v_pick::text, v_conf,
              left(coalesce(d->>'reason', CASE WHEN d IS NULL THEN 'no answer for this case' END), 500), (v_ans->>'call_id')::bigint, v_hold)
      ON CONFLICT (purpose, source, case_key, cand_hash) DO UPDATE
        SET at = now(), pick = EXCLUDED.pick, confidence = EXCLUDED.confidence, reason = EXCLUDED.reason, call_id = EXCLUDED.call_id, held_reason = EXCLUDED.held_reason;
      IF v_pick IS NULL THEN v_abst := v_abst + 1; CONTINUE; END IF;
      v_picked := v_picked + 1;
      IF v_hold IS NULL THEN
        IF public.llm_venue_apply(p_source, r.case_key, r.cand_hash, v_pick, v_conf, d->>'reason', v_run) THEN v_applied := v_applied + 1;
        ELSE UPDATE public.llm_judge_decision SET held_reason = 'claimed' WHERE purpose = 'venue' AND source = p_source AND case_key = r.case_key AND cand_hash = r.cand_hash; END IF;
      END IF;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('run_id', v_run, 'source', p_source, 'applied_mode', v_apply, 'calls', v_calls, 'cases', v_cases,
                            'picked', v_picked, 'abstained', v_abst, 'applied', v_applied, 'replayed', v_replayed, 'call_errors', v_err,
                            'open_cases', (SELECT count(*) FROM public.llm_venue_cases(p_source, 100000)));
END $function$;

-- what the operator reads before flipping apply_enabled
DROP VIEW IF EXISTS public.v_llm_judge_review;
CREATE VIEW public.v_llm_judge_review AS
SELECT d.id, d.at, d.purpose, d.source, d.case_key,
       coalesce(d.payload->>'name', '') AS subject,
       d.payload->>'start_local' AS start_local,
       coalesce(d.payload->>'venue', d.payload->>'city') AS venue,
       d.pick, d.confidence, d.reason, d.applied, d.held_reason,
       (SELECT x->>'name' FROM jsonb_array_elements(d.candidates) x WHERE x->>'id' = d.pick LIMIT 1) AS picked_name,
       (SELECT x->>'start_local' FROM jsonb_array_elements(d.candidates) x WHERE x->>'id' = d.pick LIMIT 1) AS picked_start,
       jsonb_array_length(d.candidates) AS n_candidates,
       d.candidates
  FROM public.llm_judge_decision d;
REVOKE ALL ON public.v_llm_judge_review FROM anon, authenticated;
GRANT SELECT ON public.v_llm_judge_review TO service_role;

REVOKE ALL ON FUNCTION public.llm_judge_call(text, text, text, text, int), public.llm_match_cases(text, int, boolean), public.llm_match_apply(text, text, text, bigint, numeric, text, uuid),
               public.llm_match_judge(text, boolean, int), public.llm_venue_cases(text, int, boolean), public.llm_venue_apply(text, text, text, bigint, numeric, text, uuid),
               public.llm_venue_judge(text, boolean, int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.llm_judge_call(text, text, text, text, int), public.llm_match_cases(text, int, boolean), public.llm_match_apply(text, text, text, bigint, numeric, text, uuid),
                          public.llm_match_judge(text, boolean, int), public.llm_venue_cases(text, int, boolean), public.llm_venue_apply(text, text, text, bigint, numeric, text, uuid),
                          public.llm_venue_judge(text, boolean, int)
  TO service_role;

-- ───────────────────────── 5. the catalogue mappers take the venue judge's pairings ─────────────────────────
CREATE OR REPLACE FUNCTION public.tickpick_catalog_map(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_out jsonb := '{}'::jsonb;
  v_n   int;
BEGIN
  -- 0. candidates: upcoming, dated, at venues in the US, Canada or Mexico (mig 20261117080000)
  DROP TABLE IF EXISTS _tc_cand;
  CREATE TEMP TABLE _tc_cand ON COMMIT DROP AS
  SELECT c.tp_event_id, c.name, c.performers, c.tp_venue_id, c.event_date, c.event_utc, c.time_confirmed,
         c.tevo_event_id AS cur_tevo, c.tevo_match_method AS cur_method
    FROM public.tickpick_catalog_event c
   WHERE c.status IS DISTINCT FROM 'canceled' AND c.merged_into IS NULL AND c.date_confirmed
     AND c.event_date BETWEEN current_date - 1 AND current_date + 400
     AND coalesce(c.venue_country, 'US') IN ('US', 'CA', 'MX');
  CREATE INDEX ON _tc_cand (tp_event_id);
  v_out := v_out || jsonb_build_object('candidates', (SELECT count(*) FROM _tc_cand));

  -- 1. verify the matched: still that event, on that day?
  DROP TABLE IF EXISTS _tc_drop;
  CREATE TEMP TABLE _tc_drop ON COMMIT DROP AS
  SELECT x.tp_event_id, x.cur_tevo, x.cur_method,
         CASE WHEN e.id IS NULL THEN 'event_gone'
              WHEN e.state = 'ignored' THEN 'event_ignored'
              ELSE 'day_moved' END AS why
    FROM _tc_cand x
    LEFT JOIN public.events e ON e.id = x.cur_tevo
   WHERE x.cur_tevo IS NOT NULL
     AND (e.id IS NULL OR e.state = 'ignored' OR left(e.occurs_at_local, 10) IS DISTINCT FROM to_char(x.event_date, 'YYYY-MM-DD'));
  v_out := v_out || jsonb_build_object('dropped', (SELECT count(*) FROM _tc_drop));
  IF p_apply THEN
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, old_tevo, note)
    SELECT v_run, d.tp_event_id, 'drop', 'tickpick_catalog_event', d.tp_event_id::text, d.cur_tevo, d.why || ' (' || coalesce(d.cur_method, '?') || ')' FROM _tc_drop d;
    UPDATE public.tickpick_catalog_event c SET tevo_event_id = NULL, tevo_match_method = NULL, tevo_matched_at = NULL
      FROM _tc_drop d WHERE d.tp_event_id = c.tp_event_id;
  END IF;
  UPDATE _tc_cand x SET cur_tevo = NULL, cur_method = NULL FROM _tc_drop d WHERE d.tp_event_id = x.tp_event_id;

  DROP TABLE IF EXISTS _tc_pick;
  CREATE TEMP TABLE _tc_pick (tp_event_id bigint PRIMARY KEY, tevo_event_id bigint NOT NULL, method text NOT NULL) ON COMMIT DROP;

  -- 2. identity: the hub's tp_event_id; our own orders already mapped — same local day AND the name still fits
  INSERT INTO _tc_pick (tp_event_id, tevo_event_id, method)
  SELECT DISTINCT ON (x.tp_event_id) x.tp_event_id, a.tevo_event_id, 'hub_identity'
    FROM _tc_cand x
    JOIN public.aq_event_map a ON a.tp_event_id = x.tp_event_id AND a.tevo_event_id IS NOT NULL
    JOIN public.events e ON e.id = a.tevo_event_id AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
   ORDER BY x.tp_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at DESC NULLS LAST
  ON CONFLICT DO NOTHING;
  INSERT INTO _tc_pick (tp_event_id, tevo_event_id, method)
  SELECT x.tp_event_id, o.tevo, 'order_identity'
    FROM _tc_cand x
    JOIN (SELECT (o.raw->'event'->>'event_id')::bigint AS tp, o.tevo_event_id AS tevo, count(*) AS n
            FROM public.tickpick_orders o
           WHERE o.tevo_event_id IS NOT NULL AND (o.raw->'event'->>'event_id') ~ '^\d+$'
           GROUP BY 1, 2) o ON o.tp = x.tp_event_id
    JOIN public.events e ON e.id = o.tevo AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
     AND NOT EXISTS (SELECT 1 FROM public.tickpick_orders o2
                      WHERE (o2.raw->'event'->>'event_id') ~ '^\d+$' AND (o2.raw->'event'->>'event_id')::bigint = x.tp_event_id
                        AND o2.tevo_event_id IS NOT NULL AND o2.tevo_event_id <> o.tevo)
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object('identity', (SELECT count(*) FROM _tc_pick));

  -- 3. venues: manual -> aq_venue_map -> cross_source (unanimous) -> name + state (mig 20261117080000) -> venue judge (mig 20261117120000) -> learned
  DROP TABLE IF EXISTS _cat_tv;
  CREATE TEMP TABLE _cat_tv ON COMMIT DROP AS SELECT * FROM public.catalog_tevo_venues_by_name();
  CREATE INDEX ON _cat_tv (nm, st);
  DROP TABLE IF EXISTS _tc_venue;
  CREATE TEMP TABLE _tc_venue ON COMMIT DROP AS
  WITH known AS (
    SELECT v.tp_venue_id, v.tevo_venue_id, 'manual' AS method, 1 AS pri
      FROM public.tickpick_catalog_venue v WHERE v.method = 'manual' AND v.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT m.tickpick_venue_id, m.tevo_venue_id, 'aq_venue_map', 2
      FROM public.aq_venue_map m WHERE m.tickpick_venue_id IS NOT NULL AND m.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT c.tickpick_venue_id, min(c.tevo_venue_id), 'cross_source', 3
      FROM public.cross_source_venue_map c
     WHERE c.tickpick_venue_id IS NOT NULL AND c.tevo_venue_id IS NOT NULL
     GROUP BY c.tickpick_venue_id HAVING count(DISTINCT c.tevo_venue_id) = 1
    UNION ALL
    SELECT v.tp_venue_id, t.tevo_venue_id, 'name_state', 4
      FROM public.tickpick_catalog_venue v
      JOIN _cat_tv t ON t.nm = lower(trim(v.name)) AND t.st = upper(trim(v.state))
     WHERE coalesce(v.country, 'US') IN ('US', 'CA', 'MX') AND coalesce(v.state, '') <> ''
    UNION ALL
    SELECT v.tp_venue_id, v.tevo_venue_id, 'llm_judge', 5          -- mig 20261117120000: the venue judge's pairing, kept as set
      FROM public.tickpick_catalog_venue v WHERE v.method = 'llm_judge' AND v.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT s.tp_venue_id, s.tv, 'matched_events', 6
      FROM (SELECT x.tp_venue_id, e.venue_id AS tv, count(*) AS n,
                   row_number() OVER (PARTITION BY x.tp_venue_id ORDER BY count(*) DESC, e.venue_id) AS rn
              FROM _tc_cand x
              LEFT JOIN _tc_pick p ON p.tp_event_id = x.tp_event_id
              JOIN public.events e ON e.id = coalesce(p.tevo_event_id, x.cur_tevo)
             WHERE x.tp_venue_id IS NOT NULL AND e.venue_id IS NOT NULL
             GROUP BY x.tp_venue_id, e.venue_id) s
     WHERE s.rn = 1
  )
  SELECT DISTINCT ON (k.tp_venue_id) k.tp_venue_id, k.tevo_venue_id, k.method
    FROM known k ORDER BY k.tp_venue_id, k.pri;
  CREATE INDEX ON _tc_venue (tp_venue_id);
  v_out := v_out || jsonb_build_object('venues_resolved', (SELECT count(*) FROM _tc_venue),
                                       'venues_by_method', (SELECT coalesce(jsonb_object_agg(method, n), '{}'::jsonb) FROM (SELECT method, count(*) n FROM _tc_venue GROUP BY 1) s));

  -- 4a. the EVO events the fits can see, once: upcoming, not ignored, indexed by venue and local day
  --     (mig 20261117090000: joining public.events by venue + left(occurs_at_local, 10) made the planner walk every
  --      event of the day and filter the venue afterwards — 377k rows thrown away for 757 pairs on a 60-day window)
  DROP TABLE IF EXISTS _cat_ev;
  CREATE TEMP TABLE _cat_ev ON COMMIT DROP AS
  SELECT e.id, e.venue_id, left(e.occurs_at_local, 10) AS day, e.name, e.primary_performer_name, e.occurs_at_local
    FROM public.events e
   WHERE e.occurs_at_local >= to_char(now() - interval '2 days', 'YYYY-MM-DD')
     AND e.state IS DISTINCT FROM 'ignored' AND e.venue_id IS NOT NULL;
  CREATE INDEX ON _cat_ev (venue_id, day);
  ANALYZE _cat_ev;

  -- 4. venue + local day (+ name, + time)
  DROP TABLE IF EXISTS _tc_fit;
  CREATE TEMP TABLE _tc_fit ON COMMIT DROP AS
  SELECT x.tp_event_id, e.id AS tevo_event_id, x.time_confirmed,
         (x.time_confirmed AND x.event_utc IS NOT NULL
          AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - x.event_utc)) <= 60) AS same_minute
    FROM _tc_cand x
    JOIN _tc_venue v ON v.tp_venue_id = x.tp_venue_id
    JOIN _cat_ev e ON e.venue_id = v.tevo_venue_id AND e.day = to_char(x.event_date, 'YYYY-MM-DD')
   WHERE x.cur_tevo IS NULL
     AND NOT EXISTS (SELECT 1 FROM _tc_pick p WHERE p.tp_event_id = x.tp_event_id)
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name);
  DROP TABLE IF EXISTS _tc_claimed;
  CREATE TEMP TABLE _tc_claimed ON COMMIT DROP AS
  SELECT x.cur_tevo AS tevo_event_id FROM _tc_cand x WHERE x.cur_tevo IS NOT NULL
  UNION
  SELECT p.tevo_event_id FROM _tc_pick p
  UNION
  SELECT c.tevo_event_id FROM public.tickpick_catalog_event c
   WHERE c.tevo_event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM _tc_drop d WHERE d.tp_event_id = c.tp_event_id);
  WITH per AS (
    SELECT f.tp_event_id,
           count(*) AS n_fit,
           min(f.tevo_event_id) AS one_fit,
           count(*) FILTER (WHERE f.same_minute) AS n_minute,
           min(f.tevo_event_id) FILTER (WHERE f.same_minute) AS one_minute
      FROM _tc_fit f
     WHERE NOT EXISTS (SELECT 1 FROM _tc_claimed c WHERE c.tevo_event_id = f.tevo_event_id)
     GROUP BY f.tp_event_id
  ),
  pick AS (
    SELECT p.tp_event_id,
           CASE WHEN p.n_fit = 1 THEN p.one_fit WHEN p.n_minute = 1 THEN p.one_minute END AS tevo_event_id,
           CASE WHEN p.n_fit = 1 THEN 'venue_day_name' WHEN p.n_minute = 1 THEN 'venue_time_name' END AS method
      FROM per p
  ),
  uniq AS (
    SELECT p.* FROM pick p
     WHERE p.tevo_event_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pick q WHERE q.tevo_event_id = p.tevo_event_id AND q.tp_event_id <> p.tp_event_id)
  )
  INSERT INTO _tc_pick (tp_event_id, tevo_event_id, method)
  SELECT u.tp_event_id, u.tevo_event_id, u.method FROM uniq u
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object(
    'picked', (SELECT count(*) FROM _tc_pick),
    'by_method', (SELECT coalesce(jsonb_object_agg(m, n), '{}'::jsonb) FROM (SELECT method m, count(*) n FROM _tc_pick GROUP BY 1) s),
    'ambiguous', (SELECT count(DISTINCT f.tp_event_id) FROM _tc_fit f WHERE NOT EXISTS (SELECT 1 FROM _tc_pick p WHERE p.tp_event_id = f.tp_event_id)),
    'unmatched', (SELECT count(*) FROM _tc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _tc_pick p WHERE p.tp_event_id = x.tp_event_id)),
    'no_venue', (SELECT count(*) FROM _tc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _tc_venue v WHERE v.tp_venue_id = x.tp_venue_id)));

  IF p_apply THEN
    UPDATE public.tickpick_catalog_event c
       SET tevo_event_id = p.tevo_event_id, tevo_match_method = p.method, tevo_matched_at = now()
      FROM _tc_pick p WHERE p.tp_event_id = c.tp_event_id;
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, new_tevo, note)
    SELECT v_run, p.tp_event_id, 'match', 'tickpick_catalog_event', p.tp_event_id::text, p.tevo_event_id, p.method FROM _tc_pick p;

    WITH cnt AS (
      SELECT c.tp_venue_id, count(*) AS n
        FROM public.tickpick_catalog_event c JOIN public.events e ON e.id = c.tevo_event_id
        JOIN _tc_venue v ON v.tp_venue_id = c.tp_venue_id AND v.tevo_venue_id = e.venue_id
       GROUP BY c.tp_venue_id
    ),
    u AS (
      INSERT INTO public.tickpick_catalog_venue AS v (tp_venue_id, tevo_venue_id, method, events, derived_at)
      SELECT t.tp_venue_id, t.tevo_venue_id, t.method, coalesce(cnt.n, 0), now()
        FROM _tc_venue t LEFT JOIN cnt ON cnt.tp_venue_id = t.tp_venue_id
      ON CONFLICT (tp_venue_id) DO UPDATE
        SET tevo_venue_id = EXCLUDED.tevo_venue_id, method = EXCLUDED.method, events = EXCLUDED.events, derived_at = now()
        WHERE coalesce(v.method, '') NOT IN ('manual', 'llm_judge')
          AND (v.tevo_venue_id IS DISTINCT FROM EXCLUDED.tevo_venue_id OR v.method IS DISTINCT FROM EXCLUDED.method
               OR v.events IS DISTINCT FROM EXCLUDED.events)
      RETURNING v.tp_venue_id, v.tevo_venue_id, v.method, v.events)
    INSERT INTO public.tickpick_catalog_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_xref', 'tickpick_catalog_venue', u.tp_venue_id::text, format('tevo_venue %s via %s (%s events)', u.tevo_venue_id, u.method, u.events) FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venues_written', v_n);

    -- 5. hub: the TickPick id on the hub rows of matched EVO events (fill-only; one TickPick id per EVO event)
    WITH tp AS (
      SELECT c.tevo_event_id, min(c.tp_event_id) AS tp_event_id
        FROM public.tickpick_catalog_event c
       WHERE c.tevo_event_id IS NOT NULL AND c.event_date >= current_date - 1
       GROUP BY c.tevo_event_id HAVING count(*) = 1
    ),
    tgt AS (   -- mig 20261117110000: a hub row another transaction holds is skipped, not waited for
      SELECT a.aq_short_event_id, tp.tp_event_id, tp.tevo_event_id
        FROM public.aq_event_map a JOIN tp ON tp.tevo_event_id = a.tevo_event_id
       WHERE a.tp_event_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.tp_event_id = tp.tp_event_id AND o.tevo_event_id IS DISTINCT FROM tp.tevo_event_id)
       FOR UPDATE OF a SKIP LOCKED
    ),
    u AS (
      UPDATE public.aq_event_map a SET tp_event_id = t.tp_event_id
        FROM tgt t
       WHERE a.aq_short_event_id = t.aq_short_event_id
       RETURNING a.aq_short_event_id, a.tevo_event_id, t.tp_event_id)
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, new_tevo)
    SELECT v_run, u.tp_event_id, 'hub_tp', 'aq_event_map', u.aq_short_event_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('hub_tp_filled', v_n);

    -- 6. orders: by id, fill-only; disagreements audited, never re-pointed
    WITH u AS (
      UPDATE public.tickpick_orders o
         SET tevo_event_id = c.tevo_event_id, matched_via = 'tp_catalog_id', match_confidence = 1.0, matched_at = now()
        FROM public.tickpick_catalog_event c
       WHERE o.tevo_event_id IS NULL AND o.event_date >= now() - interval '1 day' AND (o.raw->'event'->>'event_id') ~ '^\d+$'
         AND c.tp_event_id = (o.raw->'event'->>'event_id')::bigint AND c.tevo_event_id IS NOT NULL
       RETURNING o.tp_order_id, c.tp_event_id, c.tevo_event_id)
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, new_tevo)
    SELECT v_run, u.tp_event_id, 'order_tevo', 'tickpick_orders', u.tp_order_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_filled', v_n);
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, old_tevo, new_tevo, note)
    SELECT v_run, c.tp_event_id, 'order_disagree', 'tickpick_orders', o.tp_order_id, o.tevo_event_id, c.tevo_event_id, coalesce(o.matched_via, '?')
      FROM public.tickpick_orders o
      JOIN public.tickpick_catalog_event c ON (o.raw->'event'->>'event_id') ~ '^\d+$' AND c.tp_event_id = (o.raw->'event'->>'event_id')::bigint
     WHERE o.tevo_event_id IS NOT NULL AND c.tevo_event_id IS NOT NULL AND o.tevo_event_id <> c.tevo_event_id
       AND o.event_date >= now() - interval '1 day'
       AND NOT EXISTS (SELECT 1 FROM public.tickpick_catalog_audit a
                        WHERE a.action = 'order_disagree' AND a.target_key = o.tp_order_id AND a.new_tevo = c.tevo_event_id);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_disagree_new', v_n);

    -- 7. the venue xref: aq_venue_map.tickpick_venue_id (UNIQUE), fill-only, once two matched events corroborate the pairing
    WITH tgt AS (   -- mig 20261117110000: skip locked rows here too
      SELECT m.venue_short_id, m.tevo_venue_id, v.tp_venue_id
        FROM public.aq_venue_map m JOIN public.tickpick_catalog_venue v ON v.tevo_venue_id = m.tevo_venue_id
       WHERE m.tickpick_venue_id IS NULL AND v.tevo_venue_id IS NOT NULL
         AND (v.method = 'manual' OR coalesce(v.events, 0) >= 2)
         AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map o WHERE o.tickpick_venue_id = v.tp_venue_id)
         AND NOT EXISTS (SELECT 1 FROM public.tickpick_catalog_venue w WHERE w.tevo_venue_id = v.tevo_venue_id AND w.tp_venue_id <> v.tp_venue_id)
       FOR UPDATE OF m SKIP LOCKED
    ),
    u AS (
      UPDATE public.aq_venue_map m SET tickpick_venue_id = t.tp_venue_id
        FROM tgt t WHERE m.venue_short_id = t.venue_short_id
       RETURNING m.venue_short_id, m.tevo_venue_id, t.tp_venue_id)
    INSERT INTO public.tickpick_catalog_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_map', 'aq_venue_map', u.venue_short_id, 'tickpick_venue ' || u.tp_venue_id || ' on tevo_venue ' || u.tevo_venue_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venue_map_filled', v_n);
  END IF;

  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply) || v_out;
END $function$;

CREATE OR REPLACE FUNCTION public.vivid_catalog_map(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_out jsonb := '{}'::jsonb;
  v_n   int;
BEGIN
  -- one writer of vivid_catalog_event at a time: the minute tick (vivid_catalog_tick) skips its minute while this runs
  PERFORM pg_advisory_xact_lock(hashtext('vivid_catalog'));

  -- 0. candidates: upcoming, local day known, at venues in the US, Canada or Mexico (mig 20261117080000)
  DROP TABLE IF EXISTS _vc_cand;
  CREATE TEMP TABLE _vc_cand ON COMMIT DROP AS
  SELECT c.vivid_event_id, c.name, c.performers, c.vivid_venue_id, c.event_date, c.time_known,
         CASE WHEN c.time_known AND c.timezone IS NOT NULL AND c.timezone IN (SELECT name FROM pg_timezone_names)
              THEN c.event_local AT TIME ZONE c.timezone END AS event_utc,
         c.tevo_event_id AS cur_tevo, c.tevo_match_method AS cur_method
    FROM public.vivid_catalog_event c
   WHERE c.event_date BETWEEN current_date - 1 AND current_date + 400
     AND coalesce(c.venue_country, 'US') IN ('US', 'CA', 'MX');
  CREATE INDEX ON _vc_cand (vivid_event_id);
  v_out := v_out || jsonb_build_object('candidates', (SELECT count(*) FROM _vc_cand));

  -- 1. verify the matched
  DROP TABLE IF EXISTS _vc_drop;
  CREATE TEMP TABLE _vc_drop ON COMMIT DROP AS
  SELECT x.vivid_event_id, x.cur_tevo, x.cur_method,
         CASE WHEN e.id IS NULL THEN 'event_gone' WHEN e.state = 'ignored' THEN 'event_ignored' ELSE 'day_moved' END AS why
    FROM _vc_cand x LEFT JOIN public.events e ON e.id = x.cur_tevo
   WHERE x.cur_tevo IS NOT NULL
     AND (e.id IS NULL OR e.state = 'ignored' OR left(e.occurs_at_local, 10) IS DISTINCT FROM to_char(x.event_date, 'YYYY-MM-DD'));
  v_out := v_out || jsonb_build_object('dropped', (SELECT count(*) FROM _vc_drop));
  IF p_apply THEN
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, old_tevo, note)
    SELECT v_run, d.vivid_event_id, 'drop', 'vivid_catalog_event', d.vivid_event_id::text, d.cur_tevo, d.why || ' (' || coalesce(d.cur_method, '?') || ')' FROM _vc_drop d;
    UPDATE public.vivid_catalog_event c SET tevo_event_id = NULL, tevo_match_method = NULL, tevo_matched_at = NULL
      FROM _vc_drop d WHERE d.vivid_event_id = c.vivid_event_id;
  END IF;
  UPDATE _vc_cand x SET cur_tevo = NULL, cur_method = NULL FROM _vc_drop d WHERE d.vivid_event_id = x.vivid_event_id;

  DROP TABLE IF EXISTS _vc_pick;
  CREATE TEMP TABLE _vc_pick (vivid_event_id bigint PRIMARY KEY, tevo_event_id bigint NOT NULL, method text NOT NULL) ON COMMIT DROP;

  -- 2. identity: the hub's vivid_event_id; our Vivid orders already mapped — same local day AND the name still fits
  INSERT INTO _vc_pick (vivid_event_id, tevo_event_id, method)
  SELECT DISTINCT ON (x.vivid_event_id) x.vivid_event_id, a.tevo_event_id, 'hub_identity'
    FROM _vc_cand x
    JOIN public.aq_event_map a ON a.vivid_event_id = x.vivid_event_id AND a.tevo_event_id IS NOT NULL
    JOIN public.events e ON e.id = a.tevo_event_id AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
   ORDER BY x.vivid_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at DESC NULLS LAST
  ON CONFLICT DO NOTHING;
  INSERT INTO _vc_pick (vivid_event_id, tevo_event_id, method)
  SELECT x.vivid_event_id, o.tevo, 'order_identity'
    FROM _vc_cand x
    JOIN (SELECT (o.raw->>'productionId')::bigint AS pid, o.tevo_event_id AS tevo
            FROM public.vivid_orders o
           WHERE o.tevo_event_id IS NOT NULL AND (o.raw->>'productionId') ~ '^\d+$'
           GROUP BY 1, 2) o ON o.pid = x.vivid_event_id
    JOIN public.events e ON e.id = o.tevo AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
     AND NOT EXISTS (SELECT 1 FROM public.vivid_orders o2
                      WHERE (o2.raw->>'productionId') ~ '^\d+$' AND (o2.raw->>'productionId')::bigint = x.vivid_event_id
                        AND o2.tevo_event_id IS NOT NULL AND o2.tevo_event_id <> o.tevo)
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object('identity', (SELECT count(*) FROM _vc_pick));

  -- 3. venues: manual -> name + state (mig 20261117080000) -> venue judge (mig 20261117120000) -> learned from matches
  DROP TABLE IF EXISTS _cat_tv;
  CREATE TEMP TABLE _cat_tv ON COMMIT DROP AS SELECT * FROM public.catalog_tevo_venues_by_name();
  CREATE INDEX ON _cat_tv (nm, st);
  DROP TABLE IF EXISTS _vc_venue;
  CREATE TEMP TABLE _vc_venue ON COMMIT DROP AS
  WITH known AS (
    SELECT v.vivid_venue_id, v.tevo_venue_id, 'manual' AS method, 1 AS pri
      FROM public.vivid_catalog_venue v WHERE v.method = 'manual' AND v.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT v.vivid_venue_id, t.tevo_venue_id, 'name_state', 2
      FROM public.vivid_catalog_venue v
      JOIN _cat_tv t ON t.nm = lower(trim(v.name)) AND t.st = upper(trim(v.state))
     WHERE coalesce(v.country, 'US') IN ('US', 'CA', 'MX') AND coalesce(v.state, '') <> ''
    UNION ALL
    SELECT v.vivid_venue_id, v.tevo_venue_id, 'llm_judge', 3       -- mig 20261117120000: the venue judge's pairing, kept as set
      FROM public.vivid_catalog_venue v WHERE v.method = 'llm_judge' AND v.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT s.vivid_venue_id, s.tv, 'matched_events', 4
      FROM (SELECT x.vivid_venue_id, e.venue_id AS tv, count(*) AS n,
                   row_number() OVER (PARTITION BY x.vivid_venue_id ORDER BY count(*) DESC, e.venue_id) AS rn
              FROM _vc_cand x
              LEFT JOIN _vc_pick p ON p.vivid_event_id = x.vivid_event_id
              JOIN public.events e ON e.id = coalesce(p.tevo_event_id, x.cur_tevo)
             WHERE x.vivid_venue_id IS NOT NULL AND e.venue_id IS NOT NULL
             GROUP BY x.vivid_venue_id, e.venue_id) s
     WHERE s.rn = 1
  )
  SELECT DISTINCT ON (k.vivid_venue_id) k.vivid_venue_id, k.tevo_venue_id, k.method FROM known k ORDER BY k.vivid_venue_id, k.pri;
  CREATE INDEX ON _vc_venue (vivid_venue_id);
  v_out := v_out || jsonb_build_object('venues_resolved', (SELECT count(*) FROM _vc_venue),
                                       'venues_by_method', (SELECT coalesce(jsonb_object_agg(method, n), '{}'::jsonb) FROM (SELECT method, count(*) n FROM _vc_venue GROUP BY 1) s));

  -- 4a. the EVO events the fits can see, once: upcoming, not ignored, indexed by venue and local day
  --     (mig 20261117090000: joining public.events by venue + left(occurs_at_local, 10) made the planner walk every
  --      event of the day and filter the venue afterwards — 377k rows thrown away for 757 pairs on a 60-day window)
  DROP TABLE IF EXISTS _cat_ev;
  CREATE TEMP TABLE _cat_ev ON COMMIT DROP AS
  SELECT e.id, e.venue_id, left(e.occurs_at_local, 10) AS day, e.name, e.primary_performer_name, e.occurs_at_local
    FROM public.events e
   WHERE e.occurs_at_local >= to_char(now() - interval '2 days', 'YYYY-MM-DD')
     AND e.state IS DISTINCT FROM 'ignored' AND e.venue_id IS NOT NULL;
  CREATE INDEX ON _cat_ev (venue_id, day);
  ANALYZE _cat_ev;

  -- 4. venue + local day (+ name, + minute)
  DROP TABLE IF EXISTS _vc_fit;
  CREATE TEMP TABLE _vc_fit ON COMMIT DROP AS
  SELECT x.vivid_event_id, e.id AS tevo_event_id,
         (x.event_utc IS NOT NULL AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - x.event_utc)) <= 60) AS same_minute
    FROM _vc_cand x
    JOIN _vc_venue v ON v.vivid_venue_id = x.vivid_venue_id
    JOIN _cat_ev e ON e.venue_id = v.tevo_venue_id AND e.day = to_char(x.event_date, 'YYYY-MM-DD')
   WHERE x.cur_tevo IS NULL
     AND NOT EXISTS (SELECT 1 FROM _vc_pick p WHERE p.vivid_event_id = x.vivid_event_id)
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name);
  DROP TABLE IF EXISTS _vc_claimed;
  CREATE TEMP TABLE _vc_claimed ON COMMIT DROP AS
  SELECT x.cur_tevo AS tevo_event_id FROM _vc_cand x WHERE x.cur_tevo IS NOT NULL
  UNION SELECT p.tevo_event_id FROM _vc_pick p
  UNION SELECT c.tevo_event_id FROM public.vivid_catalog_event c
         WHERE c.tevo_event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM _vc_drop d WHERE d.vivid_event_id = c.vivid_event_id);
  WITH per AS (
    SELECT f.vivid_event_id, count(*) AS n_fit, min(f.tevo_event_id) AS one_fit,
           count(*) FILTER (WHERE f.same_minute) AS n_minute, min(f.tevo_event_id) FILTER (WHERE f.same_minute) AS one_minute
      FROM _vc_fit f
     WHERE NOT EXISTS (SELECT 1 FROM _vc_claimed c WHERE c.tevo_event_id = f.tevo_event_id)
     GROUP BY f.vivid_event_id),
  pick AS (
    SELECT p.vivid_event_id,
           CASE WHEN p.n_fit = 1 THEN p.one_fit WHEN p.n_minute = 1 THEN p.one_minute END AS tevo_event_id,
           CASE WHEN p.n_fit = 1 THEN 'venue_day_name' WHEN p.n_minute = 1 THEN 'venue_time_name' END AS method
      FROM per p),
  uniq AS (
    SELECT p.* FROM pick p
     WHERE p.tevo_event_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pick q WHERE q.tevo_event_id = p.tevo_event_id AND q.vivid_event_id <> p.vivid_event_id))
  INSERT INTO _vc_pick (vivid_event_id, tevo_event_id, method)
  SELECT u.vivid_event_id, u.tevo_event_id, u.method FROM uniq u
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object(
    'picked', (SELECT count(*) FROM _vc_pick),
    'by_method', (SELECT coalesce(jsonb_object_agg(m, n), '{}'::jsonb) FROM (SELECT method m, count(*) n FROM _vc_pick GROUP BY 1) s),
    'ambiguous', (SELECT count(DISTINCT f.vivid_event_id) FROM _vc_fit f WHERE NOT EXISTS (SELECT 1 FROM _vc_pick p WHERE p.vivid_event_id = f.vivid_event_id)),
    'unmatched', (SELECT count(*) FROM _vc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _vc_pick p WHERE p.vivid_event_id = x.vivid_event_id)),
    'no_venue', (SELECT count(*) FROM _vc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _vc_venue v WHERE v.vivid_venue_id = x.vivid_venue_id)));

  IF p_apply THEN
    UPDATE public.vivid_catalog_event c
       SET tevo_event_id = p.tevo_event_id, tevo_match_method = p.method, tevo_matched_at = now()
      FROM _vc_pick p WHERE p.vivid_event_id = c.vivid_event_id;
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo, note)
    SELECT v_run, p.vivid_event_id, 'match', 'vivid_catalog_event', p.vivid_event_id::text, p.tevo_event_id, p.method FROM _vc_pick p;

    WITH cnt AS (
      SELECT c.vivid_venue_id, count(*) AS n
        FROM public.vivid_catalog_event c JOIN public.events e ON e.id = c.tevo_event_id
        JOIN _vc_venue v ON v.vivid_venue_id = c.vivid_venue_id AND v.tevo_venue_id = e.venue_id
       GROUP BY c.vivid_venue_id),
    u AS (
      INSERT INTO public.vivid_catalog_venue AS v (vivid_venue_id, tevo_venue_id, method, events, derived_at)
      SELECT t.vivid_venue_id, t.tevo_venue_id, t.method, coalesce(cnt.n, 0), now()
        FROM _vc_venue t LEFT JOIN cnt ON cnt.vivid_venue_id = t.vivid_venue_id
      ON CONFLICT (vivid_venue_id) DO UPDATE
        SET tevo_venue_id = EXCLUDED.tevo_venue_id, method = EXCLUDED.method, events = EXCLUDED.events, derived_at = now()
        WHERE coalesce(v.method, '') NOT IN ('manual', 'llm_judge')
          AND (v.tevo_venue_id IS DISTINCT FROM EXCLUDED.tevo_venue_id OR v.method IS DISTINCT FROM EXCLUDED.method OR v.events IS DISTINCT FROM EXCLUDED.events)
      RETURNING v.vivid_venue_id, v.tevo_venue_id, v.method, v.events)
    INSERT INTO public.vivid_catalog_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_xref', 'vivid_catalog_venue', u.vivid_venue_id::text, format('tevo_venue %s via %s (%s events)', u.tevo_venue_id, u.method, u.events) FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venues_written', v_n);

    -- 5. hub: vivid_event_id on the matched events' rows (fill-only; one Vivid id per EVO event)
    WITH vv AS (
      SELECT c.tevo_event_id, min(c.vivid_event_id) AS vivid_event_id
        FROM public.vivid_catalog_event c
       WHERE c.tevo_event_id IS NOT NULL AND c.event_date >= current_date - 1
       GROUP BY c.tevo_event_id HAVING count(*) = 1),
    tgt AS (   -- mig 20261117110000: a hub row another transaction holds is skipped, not waited for
      SELECT a.aq_short_event_id, vv.vivid_event_id, vv.tevo_event_id
        FROM public.aq_event_map a JOIN vv ON vv.tevo_event_id = a.tevo_event_id
       WHERE a.vivid_event_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.vivid_event_id = vv.vivid_event_id AND o.tevo_event_id IS DISTINCT FROM vv.tevo_event_id)
       FOR UPDATE OF a SKIP LOCKED
    ),
    u AS (
      UPDATE public.aq_event_map a SET vivid_event_id = t.vivid_event_id
        FROM tgt t
       WHERE a.aq_short_event_id = t.aq_short_event_id
       RETURNING a.aq_short_event_id, a.tevo_event_id, t.vivid_event_id)
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo)
    SELECT v_run, u.vivid_event_id, 'hub_vivid', 'aq_event_map', u.aq_short_event_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('hub_vivid_filled', v_n);

    -- 6. orders: by productionId, fill-only; disagreements audited, never re-pointed
    WITH u AS (
      UPDATE public.vivid_orders o
         SET tevo_event_id = c.tevo_event_id
        FROM public.vivid_catalog_event c
       WHERE o.tevo_event_id IS NULL AND o.event_date >= now() - interval '1 day' AND (o.raw->>'productionId') ~ '^\d+$'
         AND c.vivid_event_id = (o.raw->>'productionId')::bigint AND c.tevo_event_id IS NOT NULL
       RETURNING o.vivid_order_id, c.vivid_event_id, c.tevo_event_id)
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo, note)
    SELECT v_run, u.vivid_event_id, 'order_tevo', 'vivid_orders', u.vivid_order_id, u.tevo_event_id, 'vivid_catalog_id' FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_filled', v_n);
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, old_tevo, new_tevo)
    SELECT v_run, c.vivid_event_id, 'order_disagree', 'vivid_orders', o.vivid_order_id, o.tevo_event_id, c.tevo_event_id
      FROM public.vivid_orders o
      JOIN public.vivid_catalog_event c ON (o.raw->>'productionId') ~ '^\d+$' AND c.vivid_event_id = (o.raw->>'productionId')::bigint
     WHERE o.tevo_event_id IS NOT NULL AND c.tevo_event_id IS NOT NULL AND o.tevo_event_id <> c.tevo_event_id
       AND o.event_date >= now() - interval '1 day'
       AND NOT EXISTS (SELECT 1 FROM public.vivid_catalog_audit a
                        WHERE a.action = 'order_disagree' AND a.target_key = o.vivid_order_id AND a.new_tevo = c.tevo_event_id);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_disagree_new', v_n);
  END IF;

  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply) || v_out;
END $function$;

-- ───────────────────────── 6. crons ─────────────────────────
-- hourly at :50 (after the catalogue mappers at :41/:43 and the hub fills at :45): the open match cases of each
-- source, up to max_calls_per_run calls each; daily at 06:05: the venue long tail. Both honour apply_enabled.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'llm_judge_hourly') THEN PERFORM cron.unschedule('llm_judge_hourly'); END IF;
  PERFORM cron.schedule('llm_judge_hourly', '50 * * * *',
    $j$BEGIN; SET LOCAL statement_timeout = '280s'; SELECT public.llm_match_judge('tickpick'); SELECT public.llm_match_judge('vivid'); SELECT public.llm_match_judge('mlb_event'); COMMIT;$j$);
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'llm_venue_judge_daily') THEN PERFORM cron.unschedule('llm_venue_judge_daily'); END IF;
  PERFORM cron.schedule('llm_venue_judge_daily', '5 6 * * *',
    $j$BEGIN; SET LOCAL statement_timeout = '280s'; SELECT public.llm_venue_judge('tickpick'); SELECT public.llm_venue_judge('vivid'); COMMIT;$j$);
END
$cron$;

COMMIT;

-- VERIFY (dry run first — apply_enabled is false):
--   SELECT public.llm_match_judge('tickpick', false, 1);            -- one call, decisions recorded, nothing written
--   SELECT * FROM v_llm_judge_review ORDER BY at DESC LIMIT 40;     -- read the picks and reasons
--   SELECT status, count(*), avg(latency_ms), sum(prompt_tokens), sum(output_tokens) FROM llm_judge_call GROUP BY 1;
--   UPDATE llm_judge_config SET apply_enabled = true WHERE id = 1;  -- operator: when the review holds up
--   SELECT tevo_match_method, count(*) FROM tickpick_catalog_event WHERE tevo_event_id IS NOT NULL GROUP BY 1;
