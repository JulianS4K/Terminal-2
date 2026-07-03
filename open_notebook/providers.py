"""Provider wrappers — thin, key-gated, lazily-imported.

Chat / transformations / RAG synthesis → Anthropic (already a repo dep).
Embeddings / speech-to-text / text-to-speech → OpenAI.

Design goals:
  - Import-safe: the heavy SDKs are imported *inside* the functions so this
    module (and the whole app) loads even if a lib is absent on a given host.
  - Fail loud but clean: a missing key raises ProviderError with a plain message
    the router turns into a 503 ("provider key missing"), never a 500 stacktrace.
  - No 18-provider matrix — the pragmatic core the operator chose. New providers
    slot in behind these same function signatures later.
"""
from __future__ import annotations

from typing import Iterable, Iterator

from . import config


class ProviderError(RuntimeError):
    """A provider call could not be made (missing key / SDK) or failed upstream."""


# ---------------------------------------------------------------------------
# Anthropic — chat / transform / synthesis
# ---------------------------------------------------------------------------

def _anthropic_client():
    if not config.ANTHROPIC_API_KEY:
        raise ProviderError("ANTHROPIC_API_KEY not configured — chat/transform disabled")
    try:
        import anthropic  # noqa: PLC0415 — lazy import by design
    except Exception as e:  # pragma: no cover - dependency missing
        raise ProviderError(f"anthropic SDK unavailable: {e}") from e
    return anthropic.Anthropic(api_key=config.ANTHROPIC_API_KEY)


def chat(
    messages: list[dict],
    *,
    system: str | None = None,
    model: str | None = None,
    max_tokens: int = 2048,
    temperature: float = 0.4,
) -> str:
    """Non-streaming completion. messages = [{"role": "user"|"assistant", "content": str}]."""
    client = _anthropic_client()
    kwargs = {
        "model": model or config.ONB_CHAT_MODEL,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "messages": messages,
    }
    if system:
        kwargs["system"] = system
    try:
        resp = client.messages.create(**kwargs)
    except Exception as e:
        raise ProviderError(f"anthropic chat failed: {e}") from e
    return "".join(
        block.text for block in resp.content if getattr(block, "type", None) == "text"
    )


def chat_stream(
    messages: list[dict],
    *,
    system: str | None = None,
    model: str | None = None,
    max_tokens: int = 2048,
    temperature: float = 0.4,
) -> Iterator[str]:
    """Streaming completion — yields text deltas. Raises ProviderError before the
    first yield if the provider is unavailable."""
    client = _anthropic_client()
    kwargs = {
        "model": model or config.ONB_CHAT_MODEL,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "messages": messages,
    }
    if system:
        kwargs["system"] = system

    def _gen() -> Iterator[str]:
        try:
            with client.messages.stream(**kwargs) as stream:
                for text in stream.text_stream:
                    yield text
        except Exception as e:
            raise ProviderError(f"anthropic stream failed: {e}") from e

    return _gen()


# ---------------------------------------------------------------------------
# OpenAI — embeddings / STT / TTS
# ---------------------------------------------------------------------------

def _openai_client():
    if not config.OPENAI_API_KEY:
        raise ProviderError("OPENAI_API_KEY not configured — embeddings/audio disabled")
    try:
        from openai import OpenAI  # noqa: PLC0415 — lazy import by design
    except Exception as e:  # pragma: no cover - dependency missing
        raise ProviderError(f"openai SDK unavailable: {e}") from e
    return OpenAI(api_key=config.OPENAI_API_KEY)


def embed_texts(texts: Iterable[str], *, model: str | None = None) -> list[list[float]]:
    """Embed a batch of texts → list of float vectors (dim = ONB_EMBED_DIM)."""
    items = [t if t else " " for t in texts]
    if not items:
        return []
    client = _openai_client()
    try:
        resp = client.embeddings.create(model=model or config.ONB_EMBED_MODEL, input=items)
    except Exception as e:
        raise ProviderError(f"openai embeddings failed: {e}") from e
    return [d.embedding for d in resp.data]


def embed_text(text: str, *, model: str | None = None) -> list[float]:
    """Embed a single text → one float vector."""
    out = embed_texts([text], model=model)
    return out[0] if out else []


def transcribe(audio_bytes: bytes, *, filename: str = "audio.mp3", model: str | None = None) -> str:
    """Speech-to-text for an uploaded audio file."""
    import io  # noqa: PLC0415

    client = _openai_client()
    buf = io.BytesIO(audio_bytes)
    buf.name = filename
    try:
        resp = client.audio.transcriptions.create(model=model or config.ONB_STT_MODEL, file=buf)
    except Exception as e:
        raise ProviderError(f"openai transcription failed: {e}") from e
    return getattr(resp, "text", "") or ""


def tts(text: str, *, voice: str = "alloy", model: str | None = None) -> bytes:
    """Text-to-speech → mp3 bytes for one speaker turn."""
    client = _openai_client()
    try:
        resp = client.audio.speech.create(
            model=model or config.ONB_TTS_MODEL, voice=voice, input=text, response_format="mp3"
        )
        return resp.read()
    except Exception as e:
        raise ProviderError(f"openai tts failed: {e}") from e
