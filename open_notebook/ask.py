"""Ask / RAG — decompose → parallel vector search → synthesize with citations.

Mirrors upstream open_notebook/graphs/ask.py: an LLM breaks the question into up
to N focused queries; each runs a vector search; the retrieved passages are
de-duplicated and synthesized into a cited answer. This is the real retrieval
path (distinct from chat, which stuffs full notebook context — see chat.py).
"""
from __future__ import annotations

import json
from concurrent.futures import ThreadPoolExecutor

from . import prompts, providers, repository as repo

MAX_QUERIES = 5


def _decompose(question: str, max_queries: int = MAX_QUERIES) -> list[str]:
    system = prompts.ASK_DECOMPOSE_SYSTEM.format(max_queries=max_queries)
    raw = providers.chat(
        [{"role": "user", "content": prompts.ask_decompose_user(question)}],
        system=system, max_tokens=400, temperature=0.0,
    ).strip()
    queries = _parse_json_array(raw)
    # Always include the original question as a fallback query.
    if question not in queries:
        queries.append(question)
    return queries[:max_queries]


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


def ask(db, *, question: str, notebook_id: str | None = None,
        per_query: int = 8, min_similarity: float = 0.1) -> dict:
    """Return {"question", "queries", "answer", "passages": [{index, kind, source_id, content, similarity}]}."""
    question = (question or "").strip()
    if not question:
        return {"question": question, "queries": [], "answer": "", "passages": []}

    queries = _decompose(question)

    def _one(q: str) -> list[dict]:
        emb = providers.embed_text(q)
        return repo.vector_search(db, query_embedding=emb, match_count=per_query,
                                  min_similarity=min_similarity, notebook_id=notebook_id)

    with ThreadPoolExecutor(max_workers=min(4, len(queries) or 1)) as ex:
        result_lists = list(ex.map(_one, queries))

    # De-dupe passages by row_id, keep best similarity, cap for the synthesis prompt.
    best: dict[str, dict] = {}
    for hits in result_lists:
        for h in hits:
            rid = h.get("row_id")
            if rid is None:
                continue
            if rid not in best or (h.get("similarity") or 0) > (best[rid].get("similarity") or 0):
                best[rid] = h
    passages = sorted(best.values(), key=lambda h: h.get("similarity") or 0, reverse=True)[:12]

    if not passages:
        return {"question": question, "queries": queries,
                "answer": "No relevant passages were found in this notebook.", "passages": []}

    texts = [p.get("content") or "" for p in passages]
    answer = providers.chat(
        [{"role": "user", "content": prompts.ask_synthesize_user(question, texts)}],
        system=prompts.ASK_SYNTHESIZE_SYSTEM, max_tokens=1500, temperature=0.2,
    ).strip()

    return {
        "question": question,
        "queries": queries,
        "answer": answer,
        "passages": [
            {"index": i + 1, "kind": p.get("result_kind"), "source_id": p.get("source_id"),
             "similarity": p.get("similarity"), "content": p.get("content")}
            for i, p in enumerate(passages)
        ],
    }
