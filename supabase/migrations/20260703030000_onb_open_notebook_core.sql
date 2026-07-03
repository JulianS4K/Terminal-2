-- ============================================================================
-- Migration 20260703030000 — open-notebook core schema (onb_* tables)
--
-- Lane:     operator-directed cross-cutting build (port of lfnovo/open-notebook)
-- Touches:  vector extension (W: CREATE EXTENSION),
--           onb_notebooks, onb_sources, onb_source_embeddings, onb_source_insights,
--           onb_notes, onb_notebook_sources, onb_notebook_notes, onb_transformations,
--           onb_chat_sessions, onb_chat_messages, onb_episode_profiles,
--           onb_speaker_profiles, onb_episodes, onb_jobs (W: CREATE TABLE + indexes),
--           onb_vector_search(), onb_text_search() (W: CREATE FUNCTION),
--           trg_set_updated_at() (R: reuse existing BEFORE-UPDATE trigger fn)
-- Pre-reqs: 20260512100000 (trg_set_updated_at, unaccent), pg_trgm (mig 20260509190000)
--
-- WHY: implements the open-notebook subsystem on the existing Supabase Postgres.
--   Upstream uses SurrealDB (inline vectors + BM25 FTS + graph edges); we adapt to
--   pgvector (embeddings), tsvector/pg_trgm (text search), and join tables (edges).
--   All objects are `onb_`-prefixed and live in `public` so the shared service-role
--   supabase-py client (`sb`) reaches them with no schema-exposure config. This
--   subsystem never MUTATES the ticket data plane; the per-performer digest
--   (open_notebook/performers.py) only READS a fixed set of safe, non-sensitive sources.
--
-- NOTE: embedding dim 1536 = OpenAI text-embedding-3-small. If the default
--   embedding model changes dimension, the vector columns + HNSW indexes must be
--   rebuilt (a follow-up migration), since pgvector fixes dimension at DDL time.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS vector;

-- ---------------------------------------------------------------------------
-- Content tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS onb_notebooks (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  description text,
  archived    boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS onb_sources (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title       text,
  -- asset: {"url": "...", "file_path": "...", "kind": "text|url|pdf"}
  asset       jsonb NOT NULL DEFAULT '{}'::jsonb,
  topics      text[] NOT NULL DEFAULT '{}',
  full_text   text,
  -- status: queued | processing | done | error
  status      text NOT NULL DEFAULT 'queued',
  error       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS onb_source_embeddings (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id   uuid NOT NULL REFERENCES onb_sources(id) ON DELETE CASCADE,
  chunk_order int NOT NULL DEFAULT 0,
  content     text NOT NULL,
  embedding   vector(1536),
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS onb_source_insights (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id    uuid NOT NULL REFERENCES onb_sources(id) ON DELETE CASCADE,
  insight_type text NOT NULL,
  content      text NOT NULL,
  embedding    vector(1536),
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS onb_notes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title       text,
  summary     text,
  content     text,
  -- note_type: human | ai
  note_type   text NOT NULL DEFAULT 'human',
  embedding   vector(1536),
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Graph edges (SurrealDB RELATE → join tables)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS onb_notebook_sources (
  notebook_id uuid NOT NULL REFERENCES onb_notebooks(id) ON DELETE CASCADE,
  source_id   uuid NOT NULL REFERENCES onb_sources(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (notebook_id, source_id)
);

CREATE TABLE IF NOT EXISTS onb_notebook_notes (
  notebook_id uuid NOT NULL REFERENCES onb_notebooks(id) ON DELETE CASCADE,
  note_id     uuid NOT NULL REFERENCES onb_notes(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (notebook_id, note_id)
);

-- ---------------------------------------------------------------------------
-- Transformations, chat, podcasts, jobs
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS onb_transformations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  title         text,
  description   text,
  prompt        text NOT NULL,
  apply_default boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS onb_chat_sessions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  notebook_id    uuid REFERENCES onb_notebooks(id) ON DELETE CASCADE,
  title          text,
  model_override text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS onb_chat_messages (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES onb_chat_sessions(id) ON DELETE CASCADE,
  -- role: user | assistant
  role       text NOT NULL,
  content    text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS onb_episode_profiles (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name              text NOT NULL,
  description       text,
  speaker_config    text,
  outline_provider  text,
  outline_model     text,
  transcript_provider text,
  transcript_model  text,
  default_briefing  text,
  num_segments      int NOT NULL DEFAULT 5,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS onb_speaker_profiles (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL,
  description  text,
  tts_provider text,
  tts_model    text,
  -- speakers: [{"name","voice_id","backstory","personality"}]
  speakers     jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS onb_episodes (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  notebook_id     uuid REFERENCES onb_notebooks(id) ON DELETE SET NULL,
  name            text NOT NULL,
  briefing        text,
  episode_profile jsonb,
  speaker_profile jsonb,
  outline         jsonb,
  transcript      jsonb,
  content         text,
  audio_url       text,
  -- status: queued | processing | done | error
  status          text NOT NULL DEFAULT 'queued',
  error           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Async job ledger (replaces upstream surreal-commands `command` records).
CREATE TABLE IF NOT EXISTS onb_jobs (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind       text NOT NULL,          -- ingest | podcast
  ref_id     uuid,                   -- source_id or episode_id
  status     text NOT NULL DEFAULT 'queued',   -- queued | processing | done | error
  error      text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS onb_source_embeddings_source_idx ON onb_source_embeddings (source_id);
CREATE INDEX IF NOT EXISTS onb_source_insights_source_idx   ON onb_source_insights (source_id);
CREATE INDEX IF NOT EXISTS onb_notebook_sources_source_idx  ON onb_notebook_sources (source_id);
CREATE INDEX IF NOT EXISTS onb_notebook_notes_note_idx      ON onb_notebook_notes (note_id);
CREATE INDEX IF NOT EXISTS onb_chat_messages_session_idx    ON onb_chat_messages (session_id, created_at);
CREATE INDEX IF NOT EXISTS onb_jobs_ref_idx                 ON onb_jobs (ref_id);

-- Vector indexes (HNSW, cosine). Safe on empty tables.
CREATE INDEX IF NOT EXISTS onb_source_embeddings_vec_idx
  ON onb_source_embeddings USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS onb_source_insights_vec_idx
  ON onb_source_insights USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS onb_notes_vec_idx
  ON onb_notes USING hnsw (embedding vector_cosine_ops);

-- Trigram indexes for text search / fuzzy title match.
CREATE INDEX IF NOT EXISTS onb_sources_fulltext_trgm ON onb_sources USING gin (full_text gin_trgm_ops);
CREATE INDEX IF NOT EXISTS onb_notes_content_trgm     ON onb_notes   USING gin (content gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- updated_at triggers (reuse the shared trg_set_updated_at() from mig 20260512100000)
-- ---------------------------------------------------------------------------

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'onb_notebooks','onb_sources','onb_notes','onb_transformations',
    'onb_chat_sessions','onb_episode_profiles','onb_speaker_profiles',
    'onb_episodes','onb_jobs'
  ] LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS %I ON %I;', 'set_updated_at_' || t, t);
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();',
      'set_updated_at_' || t, t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Search RPCs (callable via supabase-py .rpc())
-- ---------------------------------------------------------------------------

-- Vector search over source chunks + insights + notes, cosine similarity.
-- p_query_embedding is a 1536-float array (JSON array from the client → vector).
-- p_notebook (nullable) scopes to a notebook via the edge tables.
CREATE OR REPLACE FUNCTION onb_vector_search(
  p_query_embedding vector(1536),
  p_match_count     int DEFAULT 10,
  p_min_similarity  float DEFAULT 0.0,
  p_notebook        uuid DEFAULT NULL
)
RETURNS TABLE (
  result_kind text,
  row_id      uuid,
  source_id   uuid,
  content     text,
  similarity  float
)
LANGUAGE sql STABLE
AS $$
  WITH emb AS (
    SELECT 'source'::text AS result_kind, e.id AS row_id, e.source_id,
           e.content, 1 - (e.embedding <=> p_query_embedding) AS similarity
    FROM onb_source_embeddings e
    WHERE e.embedding IS NOT NULL
      AND (p_notebook IS NULL OR e.source_id IN (
        SELECT source_id FROM onb_notebook_sources WHERE notebook_id = p_notebook))
    UNION ALL
    SELECT 'insight'::text, i.id, i.source_id, i.content,
           1 - (i.embedding <=> p_query_embedding)
    FROM onb_source_insights i
    WHERE i.embedding IS NOT NULL
      AND (p_notebook IS NULL OR i.source_id IN (
        SELECT source_id FROM onb_notebook_sources WHERE notebook_id = p_notebook))
    UNION ALL
    SELECT 'note'::text, n.id, NULL::uuid, n.content,
           1 - (n.embedding <=> p_query_embedding)
    FROM onb_notes n
    WHERE n.embedding IS NOT NULL
      AND (p_notebook IS NULL OR n.id IN (
        SELECT note_id FROM onb_notebook_notes WHERE notebook_id = p_notebook))
  )
  SELECT result_kind, row_id, source_id, content, similarity
  FROM emb
  WHERE similarity >= p_min_similarity
  ORDER BY similarity DESC
  LIMIT p_match_count;
$$;

-- Full-text search over source full_text + insights + notes, ranked.
CREATE OR REPLACE FUNCTION onb_text_search(
  p_q           text,
  p_match_count int DEFAULT 20,
  p_notebook    uuid DEFAULT NULL
)
RETURNS TABLE (
  result_kind text,
  row_id      uuid,
  source_id   uuid,
  title       text,
  content     text,
  rank        float
)
LANGUAGE sql STABLE
AS $$
  WITH q AS (SELECT websearch_to_tsquery('english', p_q) AS tsq)
  SELECT * FROM (
    SELECT 'source'::text AS result_kind, s.id AS row_id, s.id AS source_id,
           s.title, left(coalesce(s.full_text,''), 500) AS content,
           ts_rank(to_tsvector('english', coalesce(s.full_text,'') || ' ' || coalesce(s.title,'')), (SELECT tsq FROM q)) AS rank
    FROM onb_sources s
    WHERE to_tsvector('english', coalesce(s.full_text,'') || ' ' || coalesce(s.title,'')) @@ (SELECT tsq FROM q)
      AND (p_notebook IS NULL OR s.id IN (
        SELECT source_id FROM onb_notebook_sources WHERE notebook_id = p_notebook))
    UNION ALL
    SELECT 'insight'::text, i.id, i.source_id, i.insight_type,
           left(i.content, 500),
           ts_rank(to_tsvector('english', i.content), (SELECT tsq FROM q))
    FROM onb_source_insights i
    WHERE to_tsvector('english', i.content) @@ (SELECT tsq FROM q)
      AND (p_notebook IS NULL OR i.source_id IN (
        SELECT source_id FROM onb_notebook_sources WHERE notebook_id = p_notebook))
    UNION ALL
    SELECT 'note'::text, n.id, NULL::uuid, n.title,
           left(coalesce(n.content,''), 500),
           ts_rank(to_tsvector('english', coalesce(n.content,'') || ' ' || coalesce(n.title,'')), (SELECT tsq FROM q))
    FROM onb_notes n
    WHERE to_tsvector('english', coalesce(n.content,'') || ' ' || coalesce(n.title,'')) @@ (SELECT tsq FROM q)
      AND (p_notebook IS NULL OR n.id IN (
        SELECT note_id FROM onb_notebook_notes WHERE notebook_id = p_notebook))
  ) hits
  ORDER BY rank DESC
  LIMIT p_match_count;
$$;

COMMENT ON FUNCTION onb_vector_search(vector, int, float, uuid) IS
  'open-notebook: cosine vector search over onb_source_embeddings/insights/notes, optionally notebook-scoped.';
COMMENT ON FUNCTION onb_text_search(text, int, uuid) IS
  'open-notebook: websearch tsquery full-text search over onb sources/insights/notes, optionally notebook-scoped.';
