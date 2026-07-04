"""Wikipedia enrichment — resolve a performer's article + recent season pages.

For a major-sports team or a Broadway performer we auto-attach the canonical
Wikipedia article (and, for sports, the recent "<year> <team> season" pages) as
URL sources, so a performer notebook carries narrative/context beyond the SQL
digest. Resolution uses the public MediaWiki API (opensearch + search); the
resulting URLs are ingested through the normal URL pipeline (SSRF-guarded fetch),
so nothing here bypasses the ingest guards.

Season titles are *searched*, not string-built, so the league-specific naming
(MLB "2025 New York Yankees season" vs NBA/NHL "2024–25 … season") all resolve
without per-league special-casing.
"""
from __future__ import annotations

from urllib.parse import quote

WIKI_API = "https://en.wikipedia.org/w/api.php"
_UA = "open-notebook/1.0 (Terminal-2 research notebook)"


def _api(params: dict):
    import requests  # noqa: PLC0415 — lazy import by design

    resp = requests.get(WIKI_API, params={**params, "format": "json"},
                        timeout=15, headers={"User-Agent": _UA})
    resp.raise_for_status()
    return resp.json()


def resolve_article_url(name: str) -> str | None:
    """Best-matching main-namespace article URL for a name, or None."""
    name = (name or "").strip()
    if not name:
        return None
    try:
        data = _api({"action": "opensearch", "search": name, "limit": 1, "namespace": 0})
    except Exception:
        return None
    urls = data[3] if isinstance(data, list) and len(data) >= 4 else []
    return urls[0] if urls else None


def _name_token(name: str) -> str:
    """The distinctive trailing token of a team/act name (e.g. 'Yankees')."""
    toks = [t for t in (name or "").split() if t]
    return toks[-1].lower() if toks else ""


def resolve_season_urls(name: str, years: list[int], *, max_urls: int = 2) -> list[str]:
    """Recent "<year> <team> season" article URLs (league-agnostic — we search
    rather than build the title so MLB/NBA/NHL/NFL naming all work)."""
    token = _name_token(name)
    out: list[str] = []
    for y in years:
        if len(out) >= max_urls:
            break
        try:
            data = _api({"action": "query", "list": "search",
                         "srsearch": f"{y} {name} season", "srlimit": 5})
        except Exception:
            continue
        hits = data.get("query", {}).get("search", []) if isinstance(data, dict) else []
        for hit in hits:
            title = hit.get("title") or ""
            tl = title.lower()
            if "season" in tl and (not token or token in tl):
                url = "https://en.wikipedia.org/wiki/" + quote(title.replace(" ", "_"))
                if url not in out:
                    out.append(url)
                break
    return out
