"""Ask / RAG — decompose → retrieve → synthesize with citations.

Mirrors upstream open_notebook/graphs/ask.py: an LLM (Claude) breaks the question
into up to N focused queries; each retrieves passages; the retrieved passages are
de-duplicated and synthesized into a cited answer. This is the real retrieval
path (distinct from chat, which stuffs full notebook context — see chat.py).

Retrieval is provider-adaptive: it uses pgvector when an embeddings provider
(OpenAI) is configured, and falls back to Postgres full-text search (no provider
needed) otherwise — so the whole feature works with only ANTHROPIC_API_KEY set.
Anthropic has no embeddings endpoint, so Claude never produces the vectors; it
only decomposes the question and writes the final answer.
"""
from __future__ import annotations

import json
from concurrent.futures import ThreadPoolExecutor

from . import config, prompts, providers, repository as repo
from .providers import ProviderError

MAX_QUERIES = 5


def _decompose(question: str, max_queries: int = MAX_QUERIES) -> list[str]:
    system = prompts.ASK_DECOMPOSE_SYSTEM.format(max_queries=max_queries)
    raw = providers.chat(
        [{"role": "user", "content": prompts.ask_decompose_user(question)}],
        system=system, max_tokens=400, temperature=0.0,
    ).strip()
    queries = _parse_json_array(raw)
    # Always include the original question as a fallback query — and keep it after
    # the cap (appending then slicing to max_queries could drop it when the LLM
    # already returned max_queries distinct queries).
    if question in queries:
        queries.remove(question)
    return queries[: max_queries - 1] + [question]


def _parse_json_array(raw: str) -> list[str]:
    # tolerate code fences / stray prose around the JSON array
    start, end = raw.find("["), raw.rfind("]")
    if start != -1 and end != -1 and end > start:
        try:
            arr = json.loads(raw[start:end + 1])
            return [str(x) for x in arr if str(x).strip()]
        except Exception:
            pass
    return []


def _normalize(rows: list[dict]) -> list[dict]:
    """Flatten a vector- or text-search row into a common passage shape.
    Vector rows carry `similarity`; text rows carry `rank` — either becomes `score`."""
    out = []
    for r in rows:
        out.append({
            "row_id": r.get("row_id"),
            "source_id": r.get("source_id"),
            "content": r.get("content"),
            "kind": r.get("result_kind"),
            "score": r.get("similarity") if r.get("similarity") is not None else r.get("rank"),
        })
    return out


def ask(db, *, question: str, notebook_id: str | None = None,
        per_query: int = 8, min_similarity: float = 0.1) -> dict:
    """Return {"question", "queries", "mode", "answer", "passages": [...]}."""
    question = (question or "").strip()
    if not question:
        return {"question": question, "queries": [], "mode": "text", "answer": "", "passages": []}

    queries = _decompose(question)  # Claude — raises ProviderError if chat is unavailable

    # Probe once: use pgvector if embeddings are available, else fall back to
    # full-text search (which needs no provider).
    mode = "vector"
    try:
        providers.embed_text(question)
    except ProviderError:
        mode = "text"

    def _one(q: str) -> list[dict]:
        if mode == "vector":
            emb = providers.embed_text(q)
            return _normalize(repo.vector_search(
                db, query_embedding=emb, match_count=per_query,
                min_similarity=min_similarity, notebook_id=notebook_id))
        return _normalize(repo.text_search(
            db, q=q, match_count=per_query, notebook_id=notebook_id))

    with ThreadPoolExecutor(max_workers=min(4, len(queries) or 1)) as ex:
        result_lists = list(ex.map(_one, queries))

    # De-dupe passages by row_id, keep the best-scoring, cap for the synthesis prompt.
    best: dict[str, dict] = {}
    for hits in result_lists:
        for h in hits:
            rid = h.get("row_id")
            if rid is None:
                continue
            if rid not in best or (h.get("score") or 0) > (best[rid].get("score") or 0):
                best[rid] = h
    passages = sorted(best.values(), key=lambda h: h.get("score") or 0, reverse=True)[:12]

    if not passages:
        return {"question": question, "queries": queries, "mode": mode,
                "answer": "No relevant passages were found in this notebook.", "passages": []}

    texts = [p.get("content") or "" for p in passages]
    answer = providers.chat(
        [{"role": "user", "content": prompts.ask_synthesize_user(question, texts)}],
        system=prompts.ASK_SYNTHESIZE_SYSTEM, max_tokens=config.ONB_ASK_SYNTH_TOKENS, temperature=0.2,
    ).strip()

    return {
        "question": question,
        "queries": queries,
        "mode": mode,
        "answer": answer,
        "passages": [
            {"index": i + 1, "kind": p.get("kind"), "source_id": p.get("source_id"),
             "score": p.get("score"), "content": p.get("content")}
            for i, p in enumerate(passages)
        ],
    }
