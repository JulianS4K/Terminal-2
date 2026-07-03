"""open-notebook subsystem router — /api/notebook/* (port of lfnovo/open-notebook).

Follows the repo factory convention (routers/__init__.py): a build_* factory that
takes getter lambdas for the live server globals, returns an APIRouter with
hardcoded full paths and Depends(require_auth). Delegates all domain logic to the
open_notebook/ package; this file is HTTP glue + background-job wiring only.

Long-running work (source ingest, podcast generation) runs via FastAPI
BackgroundTasks against a freshly-resolved db client, with status tracked in
onb_sources.status / onb_episodes.status / onb_jobs.
"""
from __future__ import annotations

import json
from typing import Callable

from fastapi import APIRouter, BackgroundTasks, Body, Depends, HTTPException
from fastapi.responses import JSONResponse, StreamingResponse

from open_notebook import config as onb_config
from open_notebook import ask as onb_ask
from open_notebook import chat as onb_chat
from open_notebook import ingest as onb_ingest
from open_notebook import podcasts as onb_podcasts
from open_notebook import repository as repo
from open_notebook import search as onb_search
from open_notebook import transformations as onb_transforms
from open_notebook.providers import ProviderError


def build_open_notebook_router(
    get_require_sb: Callable[[], Callable],
    require_auth: Callable,
) -> APIRouter:
    router = APIRouter()

    def _db():
        return get_require_sb()()

    def _enabled():
        if not onb_config.ONB_ENABLED:
            raise HTTPException(404, "open-notebook subsystem disabled (ONB_ENABLED=false)")

    # ---- config / status -------------------------------------------------
    @router.get("/api/notebook/config")
    def onb_get_config(_=Depends(require_auth)):
        _enabled()
        return {"enabled": True, "providers": onb_config.provider_status()}

    # ---- notebooks -------------------------------------------------------
    @router.get("/api/notebook/notebooks")
    def onb_list_notebooks(include_archived: bool = False, _=Depends(require_auth)):
        _enabled()
        return {"items": repo.list_notebooks(_db(), include_archived=include_archived)}

    @router.post("/api/notebook/notebooks")
    def onb_create_notebook(body: dict = Body(...), _=Depends(require_auth)):
        _enabled()
        name = (body.get("name") or "").strip()
        if not name:
            raise HTTPException(400, "name required")
        return repo.create_notebook(_db(), name=name, description=body.get("description"))

    @router.get("/api/notebook/notebooks/{notebook_id}")
    def onb_get_notebook(notebook_id: str, _=Depends(require_auth)):
        _enabled()
        nb = repo.get_notebook(_db(), notebook_id)
        if not nb:
            raise HTTPException(404, "notebook not found")
        return nb

    @router.put("/api/notebook/notebooks/{notebook_id}")
    def onb_update_notebook(notebook_id: str, body: dict = Body(...), _=Depends(require_auth)):
        _enabled()
        nb = repo.update_notebook(_db(), notebook_id, body)
        if not nb:
            raise HTTPException(404, "notebook not found")
        return nb

    @router.delete("/api/notebook/notebooks/{notebook_id}")
    def onb_delete_notebook(notebook_id: str, _=Depends(require_auth)):
        _enabled()
        repo.delete_notebook(_db(), notebook_id)
        return {"ok": True}

    # ---- sources ---------------------------------------------------------
    @router.get("/api/notebook/notebooks/{notebook_id}/sources")
    def onb_list_sources(notebook_id: str, _=Depends(require_auth)):
        _enabled()
        return {"items": repo.list_sources(_db(), notebook_id=notebook_id)}

    @router.post("/api/notebook/notebooks/{notebook_id}/sources")
    def onb_add_source(notebook_id: str, background: BackgroundTasks,
                       body: dict = Body(...), _=Depends(require_auth)):
        _enabled()
        db = _db()
        if not repo.get_notebook(db, notebook_id):
            raise HTTPException(404, "notebook not found")
        asset = _build_asset(body)
        title = body.get("title")
        src = repo.create_source(db, title=title, asset=asset, status="queued")
        repo.link_source(db, notebook_id, src["id"])
        job = repo.create_job(db, kind="ingest", ref_id=src["id"])
        background.add_task(_run_ingest, src["id"], job["id"])
        return {"source": src, "job_id": job["id"]}

    @router.get("/api/notebook/sources/{source_id}")
    def onb_get_source(source_id: str, _=Depends(require_auth)):
        _enabled()
        src = repo.get_source(_db(), source_id)
        if not src:
            raise HTTPException(404, "source not found")
        return src

    @router.get("/api/notebook/sources/{source_id}/status")
    def onb_source_status(source_id: str, _=Depends(require_auth)):
        _enabled()
        src = repo.get_source(_db(), source_id)
        if not src:
            raise HTTPException(404, "source not found")
        return {"id": src["id"], "status": src.get("status"), "error": src.get("error")}

    @router.post("/api/notebook/sources/{source_id}/retry")
    def onb_retry_source(source_id: str, background: BackgroundTasks, _=Depends(require_auth)):
        _enabled()
        db = _db()
        if not repo.get_source(db, source_id):
            raise HTTPException(404, "source not found")
        job = repo.create_job(db, kind="ingest", ref_id=source_id)
        background.add_task(_run_ingest, source_id, job["id"])
        return {"ok": True, "job_id": job["id"]}

    @router.delete("/api/notebook/sources/{source_id}")
    def onb_delete_source(source_id: str, _=Depends(require_auth)):
        _enabled()
        repo.delete_source(_db(), source_id)
        return {"ok": True}

    @router.get("/api/notebook/sources/{source_id}/insights")
    def onb_list_insights(source_id: str, _=Depends(require_auth)):
        _enabled()
        return {"items": repo.list_insights(_db(), source_id)}

    @router.post("/api/notebook/sources/{source_id}/insights")
    def onb_run_transformation(source_id: str, body: dict = Body(...), _=Depends(require_auth)):
        _enabled()
        db = _db()
        tid = body.get("transformation_id")
        if not tid:
            raise HTTPException(400, "transformation_id required")
        t = repo.get_transformation(db, tid)
        if not t:
            raise HTTPException(404, "transformation not found")
        try:
            insight = onb_transforms.run_transformation(db, source_id=source_id, transformation=t)
        except ProviderError as e:
            raise HTTPException(503, str(e))
        except ValueError as e:
            raise HTTPException(400, str(e))
        return insight

    # ---- notes -----------------------------------------------------------
    @router.get("/api/notebook/notebooks/{notebook_id}/notes")
    def onb_list_notes(notebook_id: str, _=Depends(require_auth)):
        _enabled()
        return {"items": repo.list_notes(_db(), notebook_id=notebook_id)}

    @router.post("/api/notebook/notebooks/{notebook_id}/notes")
    def onb_create_note(notebook_id: str, body: dict = Body(...), _=Depends(require_auth)):
        _enabled()
        db = _db()
        note = repo.create_note(db, title=body.get("title"), content=body.get("content"),
                                summary=body.get("summary"),
                                note_type=body.get("note_type") or "human")
        repo.link_note(db, notebook_id, note["id"])
        return note

    @router.put("/api/notebook/notes/{note_id}")
    def onb_update_note(note_id: str, body: dict = Body(...), _=Depends(require_auth)):
        _enabled()
        note = repo.update_note(_db(), note_id, body)
        if not note:
            raise HTTPException(404, "note not found")
        return note

    @router.delete("/api/notebook/notes/{note_id}")
    def onb_delete_note(note_id: str, _=Depends(require_auth)):
        _enabled()
        repo.delete_note(_db(), note_id)
        return {"ok": True}

    # ---- transformations -------------------------------------------------
    @router.get("/api/notebook/transformations")
    def onb_list_transformations(_=Depends(require_auth)):
        _enabled()
        return {"items": repo.list_transformations(_db())}

    @router.post("/api/notebook/transformations")
    def onb_create_transformation(body: dict = Body(...), _=Depends(require_auth)):
        _enabled()
        name = (body.get("name") or "").strip()
        prompt = (body.get("prompt") or "").strip()
        if not name or not prompt:
            raise HTTPException(400, "name and prompt required")
        return repo.create_transformation(
            _db(), name=name, prompt=prompt, title=body.get("title"),
            description=body.get("description"),
            apply_default=bool(body.get("apply_default")))

    @router.put("/api/notebook/transformations/{tid}")
    def onb_update_transformation(tid: str, body: dict = Body(...), _=Depends(require_auth)):
        _enabled()
        t = repo.update_transformation(_db(), tid, body)
        if not t:
            raise HTTPException(404, "transformation not found")
        return t

    @router.delete("/api/notebook/transformations/{tid}")
    def onb_delete_transformation(tid: str, _=Depends(require_auth)):
        _enabled()
        repo.delete_transformation(_db(), tid)
        return {"ok": True}

    # ---- search / ask ----------------------------------------------------
    @router.post("/api/notebook/search")
    def onb_search_route(body: dict = Body(...), _=Depends(require_auth)):
        _enabled()
        query = (body.get("query") or "").strip()
        if not query:
            raise HTTPException(400, "query required")
        kind = body.get("kind") or "text"
        if kind not in ("text", "vector"):
            raise HTTPException(400, "kind must be 'text' or 'vector'")
        try:
            return onb_search.search(
                _db(), query=query, kind=kind, notebook_id=body.get("notebook_id"),
                limit=int(body.get("limit") or 20))
        except ProviderError as e:
            raise HTTPException(503, str(e))

    @router.post("/api/notebook/search/ask")
    def onb_ask_route(body: dict = Body(...), _=Depends(require_auth)):
        _enabled()
        question = (body.get("question") or "").strip()
        if not question:
            raise HTTPException(400, "question required")
        try:
            return onb_ask.ask(_db(), question=question, notebook_id=body.get("notebook_id"))
        except ProviderError as e:
            raise HTTPException(503, str(e))

    # ---- chat ------------------------------------------------------------
    @router.get("/api/notebook/notebooks/{notebook_id}/chat/sessions")
    def onb_list_chat_sessions(notebook_id: str, _=Depends(require_auth)):
        _enabled()
        return {"items": repo.list_chat_sessions(_db(), notebook_id)}

    @router.post("/api/notebook/notebooks/{notebook_id}/chat/sessions")
    def onb_create_chat_session(notebook_id: str, body: dict = Body(default={}), _=Depends(require_auth)):
        _enabled()
        return repo.create_chat_session(_db(), notebook_id=notebook_id, title=(body or {}).get("title"))

    @router.get("/api/notebook/chat/sessions/{session_id}/messages")
    def onb_list_chat_messages(session_id: str, _=Depends(require_auth)):
        _enabled()
        return {"items": repo.list_chat_messages(_db(), session_id)}

    @router.post("/api/notebook/chat/sessions/{session_id}/messages")
    def onb_send_chat(session_id: str, body: dict = Body(...), stream: bool = True,
                      _=Depends(require_auth)):
        _enabled()
        db = _db()
        session = _one_or_404(db.table("onb_chat_sessions").select("*").eq(
            "id", session_id).limit(1).execute(), "chat session not found")
        notebook_id = session["notebook_id"]
        message = (body.get("message") or "").strip()
        if not message:
            raise HTTPException(400, "message required")

        if not stream:
            try:
                answer = onb_chat.reply(db, session_id=session_id, notebook_id=notebook_id,
                                        user_message=message)
            except ProviderError as e:
                raise HTTPException(503, str(e))
            return {"answer": answer}

        try:
            gen = onb_chat.stream_reply(db, session_id=session_id, notebook_id=notebook_id,
                                        user_message=message)
        except ProviderError as e:
            raise HTTPException(503, str(e))

        def _sse():
            try:
                for delta in gen:
                    yield f"data: {json.dumps({'delta': delta})}\n\n"
                yield f"data: {json.dumps({'done': True})}\n\n"
            except ProviderError as e:
                yield f"data: {json.dumps({'error': str(e)})}\n\n"

        return StreamingResponse(_sse(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    # ---- podcasts --------------------------------------------------------
    @router.get("/api/notebook/episode-profiles")
    def onb_list_episode_profiles(_=Depends(require_auth)):
        _enabled()
        return {"items": repo.list_episode_profiles(_db())}

    @router.post("/api/notebook/episode-profiles")
    def onb_create_episode_profile(body: dict = Body(...), _=Depends(require_auth)):
        _enabled()
        if not (body.get("name") or "").strip():
            raise HTTPException(400, "name required")
        return repo.create_episode_profile(_db(), body)

    @router.get("/api/notebook/speaker-profiles")
    def onb_list_speaker_profiles(_=Depends(require_auth)):
        _enabled()
        return {"items": repo.list_speaker_profiles(_db())}

    @router.post("/api/notebook/speaker-profiles")
    def onb_create_speaker_profile(body: dict = Body(...), _=Depends(require_auth)):
        _enabled()
        if not (body.get("name") or "").strip():
            raise HTTPException(400, "name required")
        return repo.create_speaker_profile(_db(), body)

    @router.get("/api/notebook/episodes")
    def onb_list_episodes(_=Depends(require_auth)):
        _enabled()
        return {"items": repo.list_episodes(_db())}

    @router.get("/api/notebook/episodes/{episode_id}")
    def onb_get_episode(episode_id: str, _=Depends(require_auth)):
        _enabled()
        ep = repo.get_episode(_db(), episode_id)
        if not ep:
            raise HTTPException(404, "episode not found")
        return ep

    @router.delete("/api/notebook/episodes/{episode_id}")
    def onb_delete_episode(episode_id: str, _=Depends(require_auth)):
        _enabled()
        repo.delete_episode(_db(), episode_id)
        return {"ok": True}

    @router.post("/api/notebook/notebooks/{notebook_id}/podcasts")
    def onb_generate_podcast(notebook_id: str, background: BackgroundTasks,
                             body: dict = Body(...), _=Depends(require_auth)):
        _enabled()
        db = _db()
        if not repo.get_notebook(db, notebook_id):
            raise HTTPException(404, "notebook not found")
        content = body.get("content") or onb_podcasts.build_podcast_content(db, notebook_id)
        if not content.strip():
            raise HTTPException(400, "notebook has no source material to base a podcast on")
        episode = repo.create_episode(db, {
            "notebook_id": notebook_id,
            "name": body.get("name") or "Untitled episode",
            "briefing": body.get("briefing"),
            "episode_profile": body.get("episode_profile") or {},
            "speaker_profile": body.get("speaker_profile") or {},
            "content": content,
            "status": "queued",
        })
        job = repo.create_job(db, kind="podcast", ref_id=episode["id"])
        background.add_task(_run_podcast, episode["id"], job["id"])
        return {"episode": episode, "job_id": job["id"]}

    # ---- jobs ------------------------------------------------------------
    @router.get("/api/notebook/jobs/{job_id}")
    def onb_get_job(job_id: str, _=Depends(require_auth)):
        _enabled()
        job = repo.get_job(_db(), job_id)
        if not job:
            raise HTTPException(404, "job not found")
        return job

    # ---- background task bodies (resolve a fresh db each run) -------------
    def _run_ingest(source_id: str, job_id: str):
        try:
            onb_ingest.ingest_source(get_require_sb()(), source_id, job_id=job_id)
        except Exception:
            pass  # status already recorded on the source + job rows

    def _run_podcast(episode_id: str, job_id: str):
        try:
            onb_podcasts.generate_episode(get_require_sb()(), episode_id, job_id=job_id)
        except Exception:
            pass  # status already recorded on the episode + job rows

    return router


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _build_asset(body: dict) -> dict:
    """Normalize a create-source body into the stored asset dict.
    Accepts {kind:'text', text}, {kind:'url', url}, or {kind:'pdf', data(base64), filename}."""
    kind = (body.get("kind") or "").lower()
    if kind == "text":
        text = (body.get("text") or "").strip()
        if not text:
            raise HTTPException(400, "text required for a text source")
        return {"kind": "text", "text": text, "title": body.get("title")}
    if kind == "url":
        url = (body.get("url") or "").strip()
        if not (url.startswith("http://") or url.startswith("https://")):
            raise HTTPException(400, "http(s) url required for a url source")
        return {"kind": "url", "url": url}
    if kind == "pdf":
        data = body.get("data") or ""
        if "," in data and data.strip().startswith("data:"):
            data = data.split(",", 1)[1]  # strip a data: URI prefix
        if not data:
            raise HTTPException(400, "base64 data required for a pdf source")
        return {"kind": "pdf", "data": data, "title": body.get("title") or body.get("filename")}
    raise HTTPException(400, "kind must be one of: text, url, pdf")


def _one_or_404(res, msg: str) -> dict:
    data = res.data or []
    if not data:
        raise HTTPException(404, msg)
    return data[0]
