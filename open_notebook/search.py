"""Search — text (tsquery/pg_trgm) and vector (pgvector cosine) over onb content.

Thin orchestration over the two RPCs (repository.text_search / vector_search).
Vector search embeds the query first (OpenAI); text search needs no provider.
"""
from __future__ import annotations

from . import providers, repository as repo


def search(db, *, query: str, kind: str = "text", notebook_id: str | None = None,
           limit: int = 20, min_similarity: float = 0.1) -> dict:
    """kind = 'text' | 'vector'. Returns {"kind", "query", "results": [...]}."""
    query = (query or "").strip()
    if not query:
        return {"kind": kind, "query": query, "results": []}

    if kind == "vector":
        embedding = providers.embed_text(query)
        results = repo.vector_search(
            db, query_embedding=embedding, match_count=limit,
            min_similarity=min_similarity, notebook_id=notebook_id)
    else:
        results = repo.text_search(db, q=query, match_count=limit, notebook_id=notebook_id)
    return {"kind": kind, "query": query, "results": results}
