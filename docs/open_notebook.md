# open-notebook subsystem

**Doc version:** v1.4.0 (2026-07-04)

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

## Analytical lens — broker pricing desk
The subsystem reads every performer/event from a **ticket-broker pricing** point of
view: the through-line is secondary-market price + demand (get-in, retail median,
sell-through, volatility) and where the broker edge is (hold · list · reprice · blow
out). Hard market signals are weighted highest; every other factor (form, injuries,
weather, buzz, news, macro, futures) is treated as a demand driver tied back to its
price impact. This lens lives in `open_notebook/prompts.py` (`MARKET_LENS`, woven into
chat / ask-synthesis / podcast prompts) and in the digest ordering — the digest leads
with a market/pricing block and a lens preamble, then lists the context inputs.

## Per-performer SQL sources
A **performer** source kind (`open_notebook/performers.py`) assembles a rich,
non-sensitive digest for one performer from the ticket data plane. It reads a
**fixed set of safe sources only** — secrets (`settings`/vault), barcodes
(`exos_*`), and PII (`leads`, buyer data) are never touched. Every section is
best-effort (`_safe`): a missing view or empty result is skipped, never fatal.
Sources folded in (all already ingested by the platform — no external API calls):

- **Identity / meta** — `entity_performer_map`; ESPN team id via `performer_espn_team_xref`.
- **Overview** — `performer_wikipedia` (curated extract).
- **Sports (gated on an ESPN team id)** — team form/standings/streak (`v_espn_team_state`),
  recent results (`v_team_recent_results`), injuries (`v_espn_injuries_current`),
  roster (`v_team_roster_full`), 30-day schedule + rivalry (`v_team_schedule_30d`),
  headlines (`espn_news`).
- **Events + pricing** — upcoming slate (`events`), price snapshots
  (`latest_event_metrics`), 7-day movement (`get_event_movers_v2`), realized-sales
  color (`d0_perf_*`) + hot sections (`d0_perf_top5_sections`).
- **Primary vs secondary (broker edge)** — per event, AXS **primary** (face) get-in
  vs best secondary + precomputed flip margin/signal (`v_event_primary_vs_secondary`),
  and a SeatGeek cross-market secondary read (`seatgeek_event_metrics`). (Ticketmaster
  face-value has no standalone priced table — it flows via SeatData's `sd_tm_event_id`;
  AXS is the live primary feed.)
- **Per-event context** — game-day weather w/ climatology fallback
  (`v_event_weather_with_fallback`), demand velocity (`event_sentiment`).
- **Buzz / markets / macro** — Reddit pulse + notable posts (`v_performer_reddit_pulse`,
  `v_reddit_important_recent`), prediction-market futures / Kalshi
  (`get_performer_prediction_markets`), and a macro backdrop (`v_macro_indicators_latest`, FRED).

Podcast content budgets (`build_podcast_content`) are generous (40k total / 12k per
source) so the full digest reaches the outline/transcript stages instead of being
truncated to a snapshot. One call —
`POST /api/notebook/performers/notebook {"name": "New York Yankees"}` (or
`{"performer_id": N}`) — resolves the performer, creates a notebook, ingests the
digest, and it's ready for Ask/Chat/Podcast. The terminal's **+ Performer** button
does this (defaults to New York Yankees).

**Wikipedia auto-enrichment** (`open_notebook/wikipedia.py`, flag `ONB_WIKI_SOURCES`,
on by default): on performer-notebook creation, a background task attaches the
performer's canonical Wikipedia article as a URL source, and — for a **major-sports**
team (`entity_performer_map.espn_league` present) — the recent `<year> <team> season`
pages too. Scope is major sports + Broadway (category names theatre/musical); other
categories attach nothing (avoids wrong-match articles). Season titles are *searched*
via the MediaWiki API (not string-built), so MLB "2025 New York Yankees season" and
NBA/NHL "2024–25 … season" naming both resolve without per-league code. Broadway names
("Hamilton") are disambiguated to the `(musical)` article first. The resolved URLs
ingest through the normal SSRF-guarded URL pipeline; enrichment is best-effort and
never blocks notebook creation. Landmines respected:
`events.occurs_at_local` is TEXT (string compare for "upcoming"); `d0_*` views are
pre-deduped so the raw sales firehose is never read.

## Config / env
- `ONB_ENABLED` (default `true`) — feature flag; `false` makes `/api/notebook/*` 404.
- `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` — optional; enable the AI features.
- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY` — when
  `ANTHROPIC_API_KEY` is unset, these route chat/transform/RAG through the
  `notebook-llm` edge function (shared platform key). `ONB_EDGE_CHAT_MODEL`
  (default `claude-haiku-4-5-20251001`) is the model used on that path.
- `ONB_WIKI_SOURCES` (default `true`) — auto-attach Wikipedia sources on
  performer-notebook creation (see *Per-performer SQL sources*).
- `ONB_CHAT_MODEL`, `ONB_EMBED_MODEL` (dim `ONB_EMBED_DIM`, default 1536),
  `ONB_STT_MODEL`, `ONB_TTS_MODEL`, `ONB_CHUNK_SIZE`/`ONB_CHUNK_OVERLAP`,
  `ONB_AUDIO_BUCKET` (default `onb-audio`, a public Supabase Storage bucket for
  podcast audio).

## Deploy notes
- Deps: `openai`, `pypdf` (both lazily imported).
- The migration must be applied (preview branch for dev; prod apply is per-task
  by any session under operator direction — no A1 gate). pgvector embedding dim is fixed at DDL time — changing the
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
