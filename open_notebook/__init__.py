"""open-notebook subsystem — a self-hosted NotebookLM-style research tool.

Port of lfnovo/open-notebook adapted to Terminal-2's stack: Supabase Postgres
(pgvector for embeddings, tsvector/pg_trgm for text search, join tables for the
graph edges) instead of SurrealDB; Anthropic for chat/transform/RAG synthesis and
OpenAI for embeddings/TTS/STT instead of the Esperanto 18-provider matrix.

All DB objects are `onb_`-prefixed and live in `public` (see migration
20260703030000). This package is imported one-directionally by
routers/open_notebook.py; it never imports from server.py.
"""
