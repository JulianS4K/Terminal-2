# open-notebook subsystem

**Doc version:** v1.0.0 (2026-07-03)

On-demand reference for the open-notebook subsystem — an operator-directed port of
[lfnovo/open-notebook](https://github.com/lfnovo/open-notebook) (a self-hosted
NotebookLM-style research tool) adapted to the Terminal-2 stack. Self-contained;
does **not** touch the ticket data plane or any `*_client.py` read-only guard.

## What it does
Create **notebooks**, add **sources** (text / URL / PDF), which are extracted,
chunked, and embedded; run **transformations** (reusable prompts → insights);
**search** sources (full-text + vector); **ask** questions with RAG (decompose →
parallel vector search → cited synthesis); **chat** grounded in the whole notebook
context; and generate multi-speaker **podcasts** (outline → transcript → TTS).

## Architecture
- **Storage** — Supabase Postgres, `onb_*` tables in `public` (migration
  `20260703030000_onb_open_notebook_core.sql`). pgvector for embeddings,
  tsvector/pg_trgm for text search, join tables (`onb_notebook_sources`,
  `onb_notebook_notes`) for the graph edges. Two RPCs: `onb_vector_search`,
  `onb_text_search`.
- **Providers** — Anthropic for chat / transformations / RAG synthesis; OpenAI for
  embeddings / TTS / STT. Key-gated and lazily imported (`open_notebook/providers.py`);
  absent keys degrade gracefully.
- **Backend** — `open_notebook/` package (config, providers, repository, ingest,
  transformations, search, ask, chat, podcasts, prompts), fronted by
  `routers/open_notebook.py` (`/api/notebook/*`) mounted in `server.py`. Ingest and
  podcast generation run as FastAPI background jobs tracked in `onb_jobs`.
- **Frontend** — the **NOTEBOOK** tab in the terminal
  (`static/terminal/notebook.{html,js}`, wired into `nav.js`), plain HTML/JS.

## Config / env
- `ONB_ENABLED` (default `true`) — feature flag; `false` makes `/api/notebook/*` 404.
- `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` — optional; enable the AI features.
- `ONB_CHAT_MODEL`, `ONB_EMBED_MODEL` (dim `ONB_EMBED_DIM`, default 1536),
  `ONB_STT_MODEL`, `ONB_TTS_MODEL`, `ONB_CHUNK_SIZE`/`ONB_CHUNK_OVERLAP`,
  `ONB_AUDIO_BUCKET` (default `onb-audio`, a public Supabase Storage bucket for
  podcast audio).

## Deploy notes
- Deps: `openai`, `pypdf` (both lazily imported).
- The migration must be applied (preview branch for dev; prod apply stays
  centralized on A1). pgvector embedding dim is fixed at DDL time — changing the
  embedding model's dimension requires a follow-up migration.
- Podcast audio needs a **public** Storage bucket named per `ONB_AUDIO_BUCKET`.

## Deferred (stubbed with clear errors)
Video / office / YouTube extraction and the multi-provider matrix — a `video`/
`office`/`youtube` source records an explicit error status rather than silently
dropping. See `open_notebook/ingest.py:EXTRACT_UNSUPPORTED`.
