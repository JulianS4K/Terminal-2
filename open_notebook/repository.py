"""Repository — thin supabase-py CRUD over the onb_* tables.

Every function takes the live supabase client `db` as its first arg (injected by
the router via get_require_sb()()); this module never imports server.py or holds
global state. Reads/writes go through the PostgREST fluent builder; vector/text
search go through .rpc().
"""
from __future__ import annotations

from typing import Any


def _rows(res) -> list[dict]:
    return res.data or []


def _one(res) -> dict | None:
    data = res.data or []
    return data[0] if data else None


# ---------------------------------------------------------------------------
# Notebooks
# ---------------------------------------------------------------------------

def list_notebooks(db, *, include_archived: bool = False) -> list[dict]:
    q = db.table("onb_notebooks").select("*")
    if not include_archived:
        q = q.eq("archived", False)
    return _rows(q.order("updated_at", desc=True).execute())


def get_notebook(db, notebook_id: str) -> dict | None:
    return _one(db.table("onb_notebooks").select("*").eq("id", notebook_id).limit(1).execute())


def create_notebook(db, *, name: str, description: str | None = None) -> dict:
    return _one(db.table("onb_notebooks").insert(
        {"name": name, "description": description}).execute())


def update_notebook(db, notebook_id: str, patch: dict) -> dict | None:
    allowed = {k: v for k, v in patch.items() if k in ("name", "description", "archived")}
    if not allowed:
        return get_notebook(db, notebook_id)
    return _one(db.table("onb_notebooks").update(allowed).eq("id", notebook_id).execute())


def delete_notebook(db, notebook_id: str) -> None:
    db.table("onb_notebooks").delete().eq("id", notebook_id).execute()


# ---------------------------------------------------------------------------
# Sources + notebook↔source edges
# ---------------------------------------------------------------------------

def list_sources(db, *, notebook_id: str | None = None) -> list[dict]:
    if notebook_id is None:
        return _rows(db.table("onb_sources").select("*").order("created_at", desc=True).execute())
    edges = _rows(db.table("onb_notebook_sources").select("source_id").eq(
        "notebook_id", notebook_id).execute())
    ids = [e["source_id"] for e in edges]
    if not ids:
        return []
    return _rows(db.table("onb_sources").select("*").in_("id", ids).order(
        "created_at", desc=True).execute())


def get_source(db, source_id: str) -> dict | None:
    return _one(db.table("onb_sources").select("*").eq("id", source_id).limit(1).execute())


def create_source(db, *, title: str | None, asset: dict, status: str = "queued",
                  full_text: str | None = None, topics: list[str] | None = None) -> dict:
    return _one(db.table("onb_sources").insert({
        "title": title,
        "asset": asset,
        "status": status,
        "full_text": full_text,
        "topics": topics or [],
    }).execute())


def update_source(db, source_id: str, patch: dict) -> dict | None:
    return _one(db.table("onb_sources").update(patch).eq("id", source_id).execute())


def delete_source(db, source_id: str) -> None:
    db.table("onb_sources").delete().eq("id", source_id).execute()


def link_source(db, notebook_id: str, source_id: str) -> None:
    db.table("onb_notebook_sources").upsert(
        {"notebook_id": notebook_id, "source_id": source_id}).execute()


def unlink_source(db, notebook_id: str, source_id: str) -> None:
    db.table("onb_notebook_sources").delete().eq(
        "notebook_id", notebook_id).eq("source_id", source_id).execute()


# ---------------------------------------------------------------------------
# Source embeddings + insights
# ---------------------------------------------------------------------------

def replace_source_embeddings(db, source_id: str, chunks: list[dict]) -> None:
    """chunks = [{"chunk_order": int, "content": str, "embedding": [float]}]."""
    db.table("onb_source_embeddings").delete().eq("source_id", source_id).execute()
    if not chunks:
        return
    rows = [{"source_id": source_id, **c} for c in chunks]
    db.table("onb_source_embeddings").insert(rows).execute()


def list_insights(db, source_id: str) -> list[dict]:
    return _rows(db.table("onb_source_insights").select(
        "id,source_id,insight_type,content,created_at").eq(
        "source_id", source_id).order("created_at", desc=True).execute())


def add_insight(db, *, source_id: str, insight_type: str, content: str,
                embedding: list[float] | None = None) -> dict:
    return _one(db.table("onb_source_insights").insert({
        "source_id": source_id,
        "insight_type": insight_type,
        "content": content,
        "embedding": embedding,
    }).execute())


# ---------------------------------------------------------------------------
# Notes + notebook↔note edges
# ---------------------------------------------------------------------------

def list_notes(db, *, notebook_id: str | None = None) -> list[dict]:
    if notebook_id is None:
        return _rows(db.table("onb_notes").select(
            "id,title,summary,content,note_type,created_at,updated_at").order(
            "updated_at", desc=True).execute())
    edges = _rows(db.table("onb_notebook_notes").select("note_id").eq(
        "notebook_id", notebook_id).execute())
    ids = [e["note_id"] for e in edges]
    if not ids:
        return []
    return _rows(db.table("onb_notes").select(
        "id,title,summary,content,note_type,created_at,updated_at").in_(
        "id", ids).order("updated_at", desc=True).execute())


def create_note(db, *, title: str | None, content: str | None, summary: str | None = None,
                note_type: str = "human", embedding: list[float] | None = None) -> dict:
    return _one(db.table("onb_notes").insert({
        "title": title, "content": content, "summary": summary,
        "note_type": note_type, "embedding": embedding,
    }).execute())


def update_note(db, note_id: str, patch: dict) -> dict | None:
    allowed = {k: v for k, v in patch.items()
               if k in ("title", "content", "summary", "note_type", "embedding")}
    return _one(db.table("onb_notes").update(allowed).eq("id", note_id).execute())


def delete_note(db, note_id: str) -> None:
    db.table("onb_notes").delete().eq("id", note_id).execute()


def link_note(db, notebook_id: str, note_id: str) -> None:
    db.table("onb_notebook_notes").upsert(
        {"notebook_id": notebook_id, "note_id": note_id}).execute()


# ---------------------------------------------------------------------------
# Transformations
# ---------------------------------------------------------------------------

def list_transformations(db) -> list[dict]:
    return _rows(db.table("onb_transformations").select("*").order("name").execute())


def get_transformation(db, tid: str) -> dict | None:
    return _one(db.table("onb_transformations").select("*").eq("id", tid).limit(1).execute())


def create_transformation(db, *, name: str, prompt: str, title: str | None = None,
                          description: str | None = None, apply_default: bool = False) -> dict:
    return _one(db.table("onb_transformations").insert({
        "name": name, "prompt": prompt, "title": title,
        "description": description, "apply_default": apply_default,
    }).execute())


def update_transformation(db, tid: str, patch: dict) -> dict | None:
    allowed = {k: v for k, v in patch.items()
               if k in ("name", "prompt", "title", "description", "apply_default")}
    return _one(db.table("onb_transformations").update(allowed).eq("id", tid).execute())


def delete_transformation(db, tid: str) -> None:
    db.table("onb_transformations").delete().eq("id", tid).execute()


def default_transformations(db) -> list[dict]:
    return _rows(db.table("onb_transformations").select("*").eq("apply_default", True).execute())


# ---------------------------------------------------------------------------
# Chat sessions + messages
# ---------------------------------------------------------------------------

def list_chat_sessions(db, notebook_id: str) -> list[dict]:
    return _rows(db.table("onb_chat_sessions").select("*").eq(
        "notebook_id", notebook_id).order("updated_at", desc=True).execute())


def create_chat_session(db, *, notebook_id: str, title: str | None = None) -> dict:
    return _one(db.table("onb_chat_sessions").insert(
        {"notebook_id": notebook_id, "title": title}).execute())


def list_chat_messages(db, session_id: str) -> list[dict]:
    return _rows(db.table("onb_chat_messages").select("*").eq(
        "session_id", session_id).order("created_at").execute())


def add_chat_message(db, *, session_id: str, role: str, content: str) -> dict:
    return _one(db.table("onb_chat_messages").insert(
        {"session_id": session_id, "role": role, "content": content}).execute())


# ---------------------------------------------------------------------------
# Episodes + podcast profiles
# ---------------------------------------------------------------------------

def list_episode_profiles(db) -> list[dict]:
    return _rows(db.table("onb_episode_profiles").select("*").order("name").execute())


def list_speaker_profiles(db) -> list[dict]:
    return _rows(db.table("onb_speaker_profiles").select("*").order("name").execute())


def create_episode_profile(db, payload: dict) -> dict:
    return _one(db.table("onb_episode_profiles").insert(payload).execute())


def create_speaker_profile(db, payload: dict) -> dict:
    return _one(db.table("onb_speaker_profiles").insert(payload).execute())


def list_episodes(db) -> list[dict]:
    return _rows(db.table("onb_episodes").select(
        "id,notebook_id,name,status,audio_url,error,created_at,updated_at").order(
        "created_at", desc=True).execute())


def get_episode(db, episode_id: str) -> dict | None:
    return _one(db.table("onb_episodes").select("*").eq("id", episode_id).limit(1).execute())


def create_episode(db, payload: dict) -> dict:
    return _one(db.table("onb_episodes").insert(payload).execute())


def update_episode(db, episode_id: str, patch: dict) -> dict | None:
    return _one(db.table("onb_episodes").update(patch).eq("id", episode_id).execute())


def delete_episode(db, episode_id: str) -> None:
    db.table("onb_episodes").delete().eq("id", episode_id).execute()


# ---------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------

def create_job(db, *, kind: str, ref_id: str | None) -> dict:
    return _one(db.table("onb_jobs").insert(
        {"kind": kind, "ref_id": ref_id, "status": "queued"}).execute())


def update_job(db, job_id: str, patch: dict) -> dict | None:
    return _one(db.table("onb_jobs").update(patch).eq("id", job_id).execute())


def get_job(db, job_id: str) -> dict | None:
    return _one(db.table("onb_jobs").select("*").eq("id", job_id).limit(1).execute())


# ---------------------------------------------------------------------------
# Search RPCs
# ---------------------------------------------------------------------------

def vector_search(db, *, query_embedding: list[float], match_count: int = 10,
                  min_similarity: float = 0.0, notebook_id: str | None = None) -> list[dict]:
    res = db.rpc("onb_vector_search", {
        "p_query_embedding": query_embedding,
        "p_match_count": match_count,
        "p_min_similarity": min_similarity,
        "p_notebook": notebook_id,
    }).execute()
    return res.data or []


def text_search(db, *, q: str, match_count: int = 20, notebook_id: str | None = None) -> list[dict]:
    res = db.rpc("onb_text_search", {
        "p_q": q,
        "p_match_count": match_count,
        "p_notebook": notebook_id,
    }).execute()
    return res.data or []
