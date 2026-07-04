"""Prompt templates (plain strings — no Jinja dependency).

Mirrors upstream's prompts/{chat,ask,podcast,source_chat} intent. Kept as
functions so callers assemble context explicitly and the templates stay
greppable.
"""
from __future__ import annotations


# The house lens: every notebook in this system is read from a ticket-broker
# pricing desk. Prompts share this framing so chat / ask / podcast / insights all
# weight toward secondary-market price + demand, while still factoring everything.
MARKET_LENS = (
    "You are a pricing analyst on a live ticket-brokerage desk. Read everything in service of "
    "one question: what happens to this event's SECONDARY-MARKET price and demand — get-in, "
    "retail median, sell-through speed, inventory depth, volatility — and where is the broker's "
    "edge (hold · list · reprice · blow out). Weight hard market signals highest (live prices, "
    "movers, realized sales, demand velocity/sentiment, futures, inventory). Treat every other "
    "factor — team form, injuries, schedule, weather, fan buzz, news, macro — as a demand driver "
    "and ALWAYS tie it back to its expected price impact: direction (up/down), rough magnitude, "
    "and how soon. Be specific and quantitative where the data allows, and flag when a factor is "
    "just noise. Ground everything in the provided context; never invent numbers."
)


CHAT_SYSTEM = (
    MARKET_LENS
    + " Answer using the provided notebook context (sources, insights, and notes); if it does "
    "not cover the question, say so rather than inventing. Be concise and cite source titles "
    "inline when you use them."
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
    "together, would retrieve the evidence needed to answer it — for a ticket-broker pricing "
    "desk. Bias the queries toward price, demand, inventory, and the drivers that move them. "
    "Return ONLY a JSON array of strings (the queries), no prose. Fewer, sharper queries are "
    "better than many vague ones."
)


def ask_decompose_user(question: str) -> str:
    return f"Question:\n{question}\n\nReturn the JSON array of search queries."


ASK_SYNTHESIZE_SYSTEM = (
    MARKET_LENS
    + " Answer the question using ONLY the retrieved passages provided. Synthesize a clear, "
    "well-structured answer that lands on the price/demand implication, and cite the passages "
    "you rely on by their [n] index. If the passages do not contain the answer, say so plainly."
)


def ask_synthesize_user(question: str, passages: list[str]) -> str:
    numbered = "\n\n".join(f"[{i + 1}] {p}" for i, p in enumerate(passages))
    return f"Question:\n{question}\n\nRetrieved passages:\n{numbered}\n\nWrite the answer with [n] citations."


# transformation — run a named prompt over a source's text.
def transformation_user(source_text: str, instruction: str) -> str:
    return (
        f"{instruction}\n\n=== SOURCE TEXT ===\n{source_text}\n=== END SOURCE TEXT ==="
    )


# podcast — outline then transcript. Framed as a ticket-broker market preview.
def podcast_outline_user(briefing: str, content: str, num_segments: int) -> str:
    return (
        f"Create a podcast outline of {num_segments} segments — a ticket-broker MARKET PREVIEW. "
        f"Lead with the price/demand read (get-in, retail median, sell-through, where the value/edge "
        f"is), then cover the drivers moving it (form, injuries, schedule, weather, fan buzz, news, "
        f"futures, macro), always tied to their price impact. "
        f"Return a JSON array of {num_segments} objects, each {{\"title\": str, \"points\": [str]}}.\n\n"
        f"Briefing:\n{briefing}\n\nContent:\n{content}"
    )


def podcast_transcript_user(outline_json: str, speakers: list[str], briefing: str) -> str:
    names = ", ".join(speakers) if speakers else "Host"
    return (
        f"Write a natural multi-speaker podcast transcript for speakers: {names} — sharp ticket-market "
        f"analysts talking secondary-market pricing, demand, and where the broker edge is. "
        f"Return a JSON array of turns, each {{\"speaker\": str, \"text\": str}}. Keep turns "
        f"conversational and grounded in the outline; connect each driver back to price. Do not "
        f"include stage directions.\n\n"
        f"Briefing:\n{briefing}\n\nOutline (JSON):\n{outline_json}"
    )
