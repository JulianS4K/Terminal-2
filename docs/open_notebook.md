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
  absent keys degrade gracefully. **Claude has no embeddings endpoint**, so with only
  a Claude key the subsystem still works end-to-end: ingest saves + text-indexes
  sources (embedding is best-effort), **Ask** falls back to Postgres full-text retrieval
  (Claude still writes the answer), and **Chat** uses context-stuffing. OpenAI adds vector
  search, TTS podcasts, and audio transcription on top.
- **Claude without a per-service key** — if `ANTHROPIC_API_KEY` is unset but Supabase
  is configured (`SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY`, which the Python service
  already has), chat/transform/RAG route through the `notebook-llm` Supabase **edge
  function**, which reuses the platform's shared Anthropic key (the same secret the retail
  `chat` function uses — `settings.anthropic_api_key`, env `ANTHROPIC_API_KEY`/`LLM_API_KEY`).
  Same proxy pattern as `routers/retail_chat.py`: the trusted FastAPI service calls it with
  the service-role bearer (the edge function rejects any other caller). The edge path is
  non-streaming (the SSE endpoint emits one chunk) and defaults to `ONB_EDGE_CHAT_MODEL`
  (`claude-haiku-4-5-20251001`); the direct-key path uses `ONB_CHAT_MODEL`. `provider_status()`
  reports `chat_transport` = `anthropic` | `edge` | `none`.
- **Backend** — `open_notebook/` package (config, providers, repository, ingest,
  transformations, search, ask, chat, podcasts, prompts), fronted by
  `routers/open_notebook.py` (`/api/notebook/*`) mounted in `server.py`. Ingest and
  podcast generation run as FastAPI background jobs tracked in `onb_jobs`.
- **Frontend** — the **NOTEBOOK** tab in the terminal
  (`static/terminal/notebook.{html,js}`, wired into `nav.js`), plain HTML/JS.

## Per-performer SQL sources
A **performer** source kind (`open_notebook/performers.py`) assembles a
non-sensitive digest for one performer from the ticket data plane — identity
(`entity_performer_map`), upcoming events (`events`), price snapshots
(`latest_event_metrics`), 7-day movement (`get_event_movers_v2`), realized-sales
color (`d0_perf_*`), and optional futures (`get_performer_prediction_markets`).
It reads a **fixed set of safe sources only** — secrets (`settings`/vault),
barcodes (`exos_*`), and PII (`leads`, buyer data) are never touched. One call —
`POST /api/notebook/performers/notebook {"name": "New York Yankees"}` (or
`{"performer_id": N}`) — resolves the performer, creates a notebook, ingests the
digest, and it's ready for Ask/Chat/Podcast. The terminal's **+ Performer** button
does this (defaults to New York Yankees). Landmines respected:
`events.occurs_at_local` is TEXT (string compare for "upcoming"); `d0_*` views are
pre-deduped so the raw sales firehose is never read.

## Config / env
- `ONB_ENABLED` (default `true`) — feature flag; `false` makes `/api/notebook/*` 404.
- `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` — optional; enable the AI features.
- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY` — when
  `ANTHROPIC_API_KEY` is unset, these route chat/transform/RAG through the
  `notebook-llm` edge function (shared platform key). `ONB_EDGE_CHAT_MODEL`
  (default `claude-haiku-4-5-20251001`) is the model used on that path.
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

## Graceful degradation without OpenAI
The subsystem is fully usable on a Claude key alone. Where OpenAI would add a
capability, the feature degrades instead of failing: **Ask** falls back to
full-text retrieval (no embeddings), and **podcast** generation produces the
outline + transcript with Claude and finishes the episode as **transcript-only**
(`status='done'`, `audio_url` null, an informational note in `error`) when no TTS
provider (`OPENAI_API_KEY`) is configured — the script is written and shown in the
NOTEBOOK tab; only the narration audio is skipped. Set `OPENAI_API_KEY` to add
vector search, TTS narration, and audio transcription.

## Deferred (stubbed with clear errors)
Video / office / YouTube extraction and the multi-provider matrix — a `video`/
`office`/`youtube` source records an explicit error status rather than silently
dropping. See `open_notebook/ingest.py:EXTRACT_UNSUPPORTED`.
