"""Source ingestion — extract → chunk → embed → store, plus default transforms.

Mirrors upstream open_notebook/graphs/source.py intent, minus content-core: we
handle text, URL (requests + beautifulsoup4, both already deps), and PDF (pypdf).
Video/office/YouTube extraction is deferred (see EXTRACT_UNSUPPORTED) — the source
is stored with an error status and a clear message rather than silently dropped.
"""
from __future__ import annotations

from typing import Any

from . import config, providers, repository as repo

# Deferred extraction kinds — stored as an explicit error, not a silent no-op.
EXTRACT_UNSUPPORTED = ("video", "office", "youtube")


class IngestError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

def extract_text(asset: dict) -> tuple[str, str | None]:
    """Return (full_text, derived_title). Raises IngestError on failure."""
    kind = (asset.get("kind") or "").lower()
    if kind == "text":
        return (asset.get("text") or "").strip(), asset.get("title")
    if kind == "url":
        return _extract_url(asset["url"])
    if kind == "pdf":
        return _extract_pdf(asset), asset.get("title")
    if kind in EXTRACT_UNSUPPORTED:
        raise IngestError(f"extraction for '{kind}' sources is not supported yet")
    raise IngestError(f"unknown source kind: {kind!r}")


def _extract_url(url: str) -> tuple[str, str | None]:
    import requests  # noqa: PLC0415
    from bs4 import BeautifulSoup  # noqa: PLC0415

    if not (url.startswith("http://") or url.startswith("https://")):
        raise IngestError("URL must be http(s)")
    try:
        resp = requests.get(url, timeout=20, headers={"User-Agent": "open-notebook/1.0"})
        resp.raise_for_status()
    except Exception as e:
        raise IngestError(f"fetch failed: {e}") from e
    soup = BeautifulSoup(resp.text, "html.parser")
    for tag in soup(["script", "style", "noscript", "nav", "footer", "header"]):
        tag.decompose()
    title = (soup.title.string.strip() if soup.title and soup.title.string else None)
    text = "\n".join(line.strip() for line in soup.get_text("\n").splitlines() if line.strip())
    if not text:
        raise IngestError("no extractable text at URL")
    return text, title


def _extract_pdf(asset: dict) -> str:
    """asset carries base64 'data' (data-URI stripped by the router) for the PDF."""
    import base64  # noqa: PLC0415
    import io  # noqa: PLC0415

    b64 = asset.get("data")
    if not b64:
        raise IngestError("no PDF data provided")
    try:
        from pypdf import PdfReader  # noqa: PLC0415
    except Exception as e:  # pragma: no cover - dependency missing
        raise IngestError(f"pypdf unavailable: {e}") from e
    try:
        raw = base64.b64decode(b64)
        reader = PdfReader(io.BytesIO(raw))
        text = "\n\n".join((page.extract_text() or "") for page in reader.pages)
    except Exception as e:
        raise IngestError(f"PDF parse failed: {e}") from e
    text = text.strip()
    if not text:
        raise IngestError("no extractable text in PDF (scanned image?)")
    return text


# ---------------------------------------------------------------------------
# Chunking
# ---------------------------------------------------------------------------

def chunk_text(text: str, *, size: int | None = None, overlap: int | None = None) -> list[str]:
    """Character-based chunker with overlap. Splits on paragraph boundaries where
    possible, then hard-wraps oversized paragraphs."""
    size = size or config.ONB_CHUNK_SIZE
    overlap = overlap or config.ONB_CHUNK_OVERLAP
    text = text.strip()
    if not text:
        return []
    if len(text) <= size:
        return [text]
    chunks: list[str] = []
    start = 0
    n = len(text)
    while start < n:  # pragma: no branch - always exits via the `end >= n` break below
        end = min(start + size, n)
        # try to break on a paragraph/sentence boundary within the window
        if end < n:
            window = text[start:end]
            for sep in ("\n\n", "\n", ". "):
                idx = window.rfind(sep)
                if idx > size * 0.5:
                    end = start + idx + len(sep)
                    break
        chunks.append(text[start:end].strip())
        if end >= n:
            break
        start = max(end - overlap, start + 1)
    return [c for c in chunks if c]


# ---------------------------------------------------------------------------
# Ingest pipeline
# ---------------------------------------------------------------------------

def ingest_source(db, source_id: str, *, embed: bool = True,
                  run_transformations: bool = True, job_id: str | None = None) -> dict:
    """Run the full pipeline for an already-created source row. Idempotent-ish:
    re-running replaces embeddings. Updates source.status and the job row."""
    src = repo.get_source(db, source_id)
    if not src:
        raise IngestError("source not found")
    if job_id:
        repo.update_job(db, job_id, {"status": "processing"})
    repo.update_source(db, source_id, {"status": "processing", "error": None})
    try:
        full_text, derived_title = extract_text(src.get("asset") or {})
        patch: dict[str, Any] = {"full_text": full_text, "status": "done"}
        if derived_title and not src.get("title"):
            patch["title"] = derived_title
        repo.update_source(db, source_id, patch)

        if embed:
            _embed_source(db, source_id, full_text)
        if run_transformations:
            _apply_default_transformations(db, source_id, full_text)

        if job_id:
            repo.update_job(db, job_id, {"status": "done"})
        return repo.get_source(db, source_id) or {}
    except Exception as e:
        msg = str(e)
        repo.update_source(db, source_id, {"status": "error", "error": msg})
        if job_id:
            repo.update_job(db, job_id, {"status": "error", "error": msg})
        raise


def _embed_source(db, source_id: str, full_text: str) -> None:
    chunks = chunk_text(full_text)
    if not chunks:
        return
    vectors = providers.embed_texts(chunks)
    rows = [
        {"chunk_order": i, "content": c, "embedding": v}
        for i, (c, v) in enumerate(zip(chunks, vectors))
    ]
    repo.replace_source_embeddings(db, source_id, rows)


def _apply_default_transformations(db, source_id: str, full_text: str) -> None:
    """Best-effort: default transformations enrich the source with insights. A
    provider outage here must not fail the whole ingest — the text + embeddings
    are already saved."""
    from . import transformations  # noqa: PLC0415 — avoid import cycle at module load

    for t in repo.default_transformations(db):
        try:
            transformations.run_transformation(db, source_id=source_id,
                                                transformation=t, source_text=full_text)
        except providers.ProviderError:
            break  # no chat provider — skip all, quietly
        except Exception:
            continue  # a single bad transform shouldn't abort the rest
