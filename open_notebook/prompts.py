"""Prompt templates (plain strings — no Jinja dependency).

Mirrors upstream's prompts/{chat,ask,podcast,source_chat} intent. Kept as
functions so callers assemble context explicitly and the templates stay
greppable.
"""
from __future__ import annotations


CHAT_SYSTEM = (
    "You are a helpful research assistant embedded in a notebook. Answer using the "
    "provided notebook context (sources, insights, and notes) when relevant, and say "
    "when the context does not cover the question rather than inventing facts. Be concise "
    "and cite source titles inline when you use them."
)


def chat_system_with_context(context: str) -> str:
    if not context.strip():
        return CHAT_SYSTEM + "\n\nThe notebook currently has no sources or notes."
    return (
        CHAT_SYSTEM
        + "\n\n=== NOTEBOOK CONTEXT ===\n"
        + context
        + "\n=== END CONTEXT ==="
    )


# ask / RAG — decompose a question into focused search queries.
ASK_DECOMPOSE_SYSTEM = (
    "You break a research question into up to {max_queries} focused search queries that, "
    "together, would retrieve the evidence needed to answer it. Return ONLY a JSON array of "
    "strings (the queries), no prose. Fewer, sharper queries are better than many vague ones."
)


def ask_decompose_user(question: str) -> str:
    return f"Question:\n{question}\n\nReturn the JSON array of search queries."


ASK_SYNTHESIZE_SYSTEM = (
    "You answer a research question using ONLY the retrieved passages provided. Synthesize a "
    "clear, well-structured answer and cite the passages you rely on by their [n] index. If the "
    "passages do not contain the answer, say so plainly."
)


def ask_synthesize_user(question: str, passages: list[str]) -> str:
    numbered = "\n\n".join(f"[{i + 1}] {p}" for i, p in enumerate(passages))
    return f"Question:\n{question}\n\nRetrieved passages:\n{numbered}\n\nWrite the answer with [n] citations."


# transformation — run a named prompt over a source's text.
def transformation_user(source_text: str, instruction: str) -> str:
    return (
        f"{instruction}\n\n=== SOURCE TEXT ===\n{source_text}\n=== END SOURCE TEXT ==="
    )


# podcast — outline then transcript.
def podcast_outline_user(briefing: str, content: str, num_segments: int) -> str:
    return (
        f"Create a podcast outline of {num_segments} segments based on the briefing and content. "
        f"Return a JSON array of {num_segments} objects, each {{\"title\": str, \"points\": [str]}}.\n\n"
        f"Briefing:\n{briefing}\n\nContent:\n{content}"
    )


def podcast_transcript_user(outline_json: str, speakers: list[str], briefing: str) -> str:
    names = ", ".join(speakers) if speakers else "Host"
    return (
        f"Write a natural multi-speaker podcast transcript for speakers: {names}. "
        f"Return a JSON array of turns, each {{\"speaker\": str, \"text\": str}}. Keep turns "
        f"conversational and grounded in the outline. Do not include stage directions.\n\n"
        f"Briefing:\n{briefing}\n\nOutline (JSON):\n{outline_json}"
    )
