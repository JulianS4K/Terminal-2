"""Transformations — run a named prompt over a source's text → an insight.

A transformation is just a stored prompt (onb_transformations). Applying it runs
the prompt over the source's full_text via Anthropic and stores the result as an
onb_source_insight (embedded so it's searchable). apply_default transformations
auto-run on ingest (see ingest._apply_default_transformations).
"""
from __future__ import annotations

from . import prompts, providers, repository as repo


def run_transformation(db, *, source_id: str, transformation: dict,
                       source_text: str | None = None) -> dict:
    """Execute one transformation over a source and persist the insight."""
    if source_text is None:
        src = repo.get_source(db, source_id) or {}
        source_text = src.get("full_text") or ""
    if not source_text.strip():
        raise ValueError("source has no text to transform")

    instruction = transformation.get("prompt") or ""
    user = prompts.transformation_user(source_text, instruction)
    content = providers.chat(
        [{"role": "user", "content": user}],
        max_tokens=1500,
    ).strip()

    embedding = None
    try:
        embedding = providers.embed_text(content)
    except providers.ProviderError:
        embedding = None  # embeddings optional — insight still stored + readable

    insight_type = transformation.get("name") or transformation.get("title") or "insight"
    return repo.add_insight(db, source_id=source_id, insight_type=insight_type,
                            content=content, embedding=embedding)
