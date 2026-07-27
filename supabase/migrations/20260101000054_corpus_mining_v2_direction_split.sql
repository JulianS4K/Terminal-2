-- Cowork migration. Captured into git by code (auditor) on 2026-05-08.
-- Originally applied to prod 2026-05-08 01:40 UTC.
--
-- v2 corpus mining: split by direction (in/out), feed unmapped tokens into a
-- review queue, expose round-trip integrity check (every distinct token surfaced
-- in OUT must have at least one IN alias mapping to it).
--
-- Powers v28 (checkout-wizard FSM) + #45 (Groq swap) — the dictionary is the
-- moat that lets the cheap LLM only do final phrasing.

CREATE TABLE IF NOT EXISTS chat_term_freq_in (
  term         text NOT NULL,
  occurrences  bigint NOT NULL DEFAULT 0,
  first_seen   timestamptz NOT NULL DEFAULT now(),
  last_seen    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (term)
);

CREATE TABLE IF NOT EXISTS chat_term_freq_out (
  term         text NOT NULL,
  occurrences  bigint NOT NULL DEFAULT 0,
  first_seen   timestamptz NOT NULL DEFAULT now(),
  last_seen    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (term)
);

CREATE INDEX IF NOT EXISTS chat_term_freq_in_occ_idx  ON chat_term_freq_in  (occurrences DESC);
CREATE INDEX IF NOT EXISTS chat_term_freq_out_occ_idx ON chat_term_freq_out (occurrences DESC);

CREATE OR REPLACE FUNCTION tokenize_chat_text(p_text text)
RETURNS TABLE(term text)
LANGUAGE sql IMMUTABLE AS $$
  WITH norm AS (
    SELECT lower(regexp_replace(coalesce(p_text,''), '[^a-z0-9$\s]', ' ', 'gi')) AS s
  ),
  toks AS (
    SELECT trim(t) AS term
    FROM norm, regexp_split_to_table(norm.s, '\s+') AS t
  )
  SELECT term FROM toks
  WHERE length(term) >= 2
    AND term NOT IN (SELECT word FROM chat_stopwords);
$$;

CREATE OR REPLACE FUNCTION refresh_chat_term_freq_split(p_lookback_hours int DEFAULT 168)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_in_added  int := 0;
  v_out_added int := 0;
  v_window timestamptz := now() - (p_lookback_hours || ' hours')::interval;
BEGIN
  WITH incoming AS (
    SELECT t.term, count(*) AS n, max(bm.created_at) AS last_seen, min(bm.created_at) AS first_seen
    FROM bot_messages bm,
         LATERAL tokenize_chat_text(bm.body) AS t(term)
    WHERE bm.direction = 'in' AND bm.channel IN ('web','sms','whatsapp')
      AND bm.created_at >= v_window AND t.term IS NOT NULL
    GROUP BY t.term
  ),
  upsert AS (
    INSERT INTO chat_term_freq_in (term, occurrences, first_seen, last_seen)
    SELECT term, n, first_seen, last_seen FROM incoming
    ON CONFLICT (term) DO UPDATE
      SET occurrences = chat_term_freq_in.occurrences + EXCLUDED.occurrences,
          last_seen   = GREATEST(chat_term_freq_in.last_seen, EXCLUDED.last_seen)
    RETURNING 1
  )
  SELECT count(*) INTO v_in_added FROM upsert;

  WITH outgoing AS (
    SELECT t.term, count(*) AS n, max(bm.created_at) AS last_seen, min(bm.created_at) AS first_seen
    FROM bot_messages bm,
         LATERAL tokenize_chat_text(bm.body) AS t(term)
    WHERE bm.direction = 'out' AND bm.channel IN ('web','sms','whatsapp')
      AND bm.created_at >= v_window AND t.term IS NOT NULL
    GROUP BY t.term
  ),
  upsert AS (
    INSERT INTO chat_term_freq_out (term, occurrences, first_seen, last_seen)
    SELECT term, n, first_seen, last_seen FROM outgoing
    ON CONFLICT (term) DO UPDATE
      SET occurrences = chat_term_freq_out.occurrences + EXCLUDED.occurrences,
          last_seen   = GREATEST(chat_term_freq_out.last_seen, EXCLUDED.last_seen)
    RETURNING 1
  )
  SELECT count(*) INTO v_out_added FROM upsert;

  RETURN jsonb_build_object('in_terms_touched', v_in_added, 'out_terms_touched', v_out_added,
                            'lookback_hours', p_lookback_hours, 'ran_at', now());
END
$fn$;

CREATE OR REPLACE VIEW v_unmapped_incoming_tokens AS
SELECT f.term, f.occurrences, f.first_seen, f.last_seen,
  CASE
    WHEN f.term ~ '^\d+$' AND length(f.term) <= 3 THEN 'maybe_qty_or_section'
    WHEN f.term ~ '^\$?\d+(k|K)?$' THEN 'maybe_price'
    WHEN f.term ~ '^\d{4}$' THEN 'maybe_year_or_section'
    ELSE 'unknown'
  END AS suspected_slot
FROM chat_term_freq_in f
WHERE f.term NOT IN (SELECT alias_norm FROM chat_aliases)
  AND f.term NOT IN (SELECT term FROM chat_glossary_known)
  AND f.term NOT IN (SELECT word FROM chat_stopwords)
  AND f.occurrences >= 1
ORDER BY f.occurrences DESC;

CREATE OR REPLACE VIEW v_outgoing_terms_without_incoming_alias AS
SELECT fo.term AS bot_term, fo.occurrences AS times_bot_said,
  (SELECT count(*) FROM chat_aliases a WHERE lower(a.display_name) LIKE '%' || fo.term || '%') AS aliases_referencing_term,
  fo.last_seen
FROM chat_term_freq_out fo
WHERE fo.term NOT IN (SELECT alias_norm FROM chat_aliases)
  AND fo.term NOT IN (SELECT term FROM chat_glossary_known)
  AND fo.term NOT IN (SELECT word FROM chat_stopwords)
  AND fo.occurrences >= 2
ORDER BY fo.occurrences DESC;

SELECT cron.unschedule('refresh-chat-term-freq-split-hourly')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='refresh-chat-term-freq-split-hourly');
SELECT cron.schedule('refresh-chat-term-freq-split-hourly', '15 * * * *',
  $$ SELECT refresh_chat_term_freq_split(168); $$);

COMMENT ON FUNCTION refresh_chat_term_freq_split IS 'Splits incoming (user) vs outgoing (bot) token frequencies. Powers v28 dictionary feedback loop.';
COMMENT ON VIEW v_unmapped_incoming_tokens IS 'Review queue: tokens users typed that we have no slot mapping for.';
COMMENT ON VIEW v_outgoing_terms_without_incoming_alias IS 'Round-trip integrity: tokens bot says that no incoming alias resolves to.';
