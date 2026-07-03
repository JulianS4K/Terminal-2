"""open-notebook config — env-derived constants (mirrors core/config.py style).

Everything is read via os.environ.get at import. No .env auto-loading (the
platform provides env). Provider keys are optional: the subsystem degrades
gracefully with a clear "provider key missing" error when a key is absent
(see providers.py), so the app boots and CRUD works without any AI keys.
"""
from __future__ import annotations

import os


def _flag(name: str, default: bool = False) -> bool:
    v = os.environ.get(name)
    if v is None:
        return default
    return v.strip().lower() in ("1", "true", "yes", "on")


# Feature flag — mount + serve the subsystem. On by default; set ONB_ENABLED=false
# to hard-disable (the router returns 404s / the nav tab can be hidden).
ONB_ENABLED = _flag("ONB_ENABLED", True)

# Provider keys (optional). Chat/transform/RAG use Anthropic; embeddings/TTS/STT
# use OpenAI. Read lazily in providers.py too, but surfaced here for the
# config/status endpoint.
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")

# Supabase — lets chat/transform/RAG reach the platform's SHARED Anthropic key
# via the `notebook-llm` edge function when no per-service ANTHROPIC_API_KEY is
# set (same proxy pattern as routers/retail_chat.py). These are the platform's
# existing env vars; the Python service already has them in prod.
SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY", "")

# Model defaults (overridable per env).
ONB_CHAT_MODEL = os.environ.get("ONB_CHAT_MODEL", "claude-opus-4-8")
ONB_EMBED_MODEL = os.environ.get("ONB_EMBED_MODEL", "text-embedding-3-small")
ONB_EMBED_DIM = int(os.environ.get("ONB_EMBED_DIM", "1536"))
ONB_STT_MODEL = os.environ.get("ONB_STT_MODEL", "whisper-1")
ONB_TTS_MODEL = os.environ.get("ONB_TTS_MODEL", "tts-1")
# Model used on the edge-function fallback path (the shared platform key).
# Defaults to the model the retail `chat` edge function is proven to run on that
# key; ONB_CHAT_MODEL is used on the direct-key path where entitlement is known.
ONB_EDGE_CHAT_MODEL = os.environ.get("ONB_EDGE_CHAT_MODEL", "claude-haiku-4-5-20251001")

# Chunking (matches upstream defaults).
ONB_CHUNK_SIZE = int(os.environ.get("ONB_CHUNK_SIZE", "1500"))
ONB_CHUNK_OVERLAP = int(os.environ.get("ONB_CHUNK_OVERLAP", "150"))

# Supabase Storage bucket for generated podcast audio.
ONB_AUDIO_BUCKET = os.environ.get("ONB_AUDIO_BUCKET", "onb-audio")

# Auto-attach Wikipedia sources (performer article + recent season pages for
# sports) when a performer notebook is created. On by default.
ONB_WIKI_SOURCES = _flag("ONB_WIKI_SOURCES", True)


def edge_chat_available() -> bool:
    """Chat/transform/RAG can be served via the `notebook-llm` edge function
    (the shared platform Anthropic key) even with no per-service key set."""
    return bool(SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY)


def provider_status() -> dict:
    """Which capabilities are configured (no secrets leaked — booleans only)."""
    edge = edge_chat_available()
    return {
        "chat": bool(ANTHROPIC_API_KEY) or edge,
        "chat_transport": "anthropic" if ANTHROPIC_API_KEY else ("edge" if edge else "none"),
        "embeddings": bool(OPENAI_API_KEY),
        "transcription": bool(OPENAI_API_KEY),
        "tts": bool(OPENAI_API_KEY),
        "chat_model": ONB_CHAT_MODEL if ANTHROPIC_API_KEY else (ONB_EDGE_CHAT_MODEL if edge else ONB_CHAT_MODEL),
        "embed_model": ONB_EMBED_MODEL,
        "embed_dim": ONB_EMBED_DIM,
    }
