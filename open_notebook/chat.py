"""Chat — context-stuffing over a notebook (NOT retrieval).

Mirrors upstream open_notebook/graphs/chat.py: the whole assembled notebook
context (sources, insights, notes) is injected into the system prompt; there is
no per-turn vector search (that's ask.py). Context is budget-capped so a large
notebook doesn't blow the model's window.
"""
from __future__ import annotations

from typing import Iterator

from . import prompts, providers, repository as repo

# Rough char budget for stuffed context (~ a few thousand tokens).
CONTEXT_CHAR_BUDGET = 24000
PER_SOURCE_CHARS = 4000


def build_context(db, notebook_id: str) -> str:
    parts: list[str] = []
    used = 0

    sources = repo.list_sources(db, notebook_id=notebook_id)
    for s in sources:
        if used >= CONTEXT_CHAR_BUDGET:
            break
        body = (s.get("full_text") or "").strip()
        if not body:
            continue
        snippet = body[:PER_SOURCE_CHARS]
        block = f"## SOURCE: {s.get('title') or 'untitled'}\n{snippet}"
        parts.append(block)
        used += len(block)
        for ins in repo.list_insights(db, s["id"]):
            if used >= CONTEXT_CHAR_BUDGET:
                break
            ib = f"### INSIGHT ({ins.get('insight_type')}): {ins.get('content')}"
            parts.append(ib)
            used += len(ib)

    for n in repo.list_notes(db, notebook_id=notebook_id):
        if used >= CONTEXT_CHAR_BUDGET:
            break
        nb = f"## NOTE: {n.get('title') or ''}\n{n.get('content') or ''}"
        parts.append(nb)
        used += len(nb)

    return "\n\n".join(parts)


def _history(db, session_id: str) -> list[dict]:
    msgs = repo.list_chat_messages(db, session_id)
    return [{"role": m["role"], "content": m["content"]} for m in msgs
            if m.get("role") in ("user", "assistant")]


def stream_reply(db, *, session_id: str, notebook_id: str, user_message: str) -> Iterator[str]:
    """Persist the user turn, stream the assistant reply, persist it at the end.
    Yields text deltas."""
    repo.add_chat_message(db, session_id=session_id, role="user", content=user_message)
    context = build_context(db, notebook_id)
    system = prompts.chat_system_with_context(context)
    messages = _history(db, session_id)

    # Obtain the provider stream eagerly so a missing-key/unavailable ProviderError
    # surfaces here (→ 503 before streaming starts) rather than mid-SSE.
    stream = providers.chat_stream(messages, system=system, max_tokens=2048)
    collected: list[str] = []

    def _gen() -> Iterator[str]:
        for delta in stream:
            collected.append(delta)
            yield delta
        repo.add_chat_message(db, session_id=session_id, role="assistant",
                              content="".join(collected))

    return _gen()


def reply(db, *, session_id: str, notebook_id: str, user_message: str) -> str:
    """Non-streaming variant (used by tests / clients that don't want SSE)."""
    repo.add_chat_message(db, session_id=session_id, role="user", content=user_message)
    context = build_context(db, notebook_id)
    system = prompts.chat_system_with_context(context)
    messages = _history(db, session_id)
    answer = providers.chat(messages, system=system, max_tokens=2048)
    repo.add_chat_message(db, session_id=session_id, role="assistant", content=answer)
    return answer
