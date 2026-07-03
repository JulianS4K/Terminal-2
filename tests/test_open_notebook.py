"""Full-coverage tests for the open-notebook subsystem.

Covers open_notebook/* and routers/open_notebook.py to the repo's 100% gate.
House style mirrors tests/test_app_broker_catalog_full.py: fake env BEFORE
importing server, drive server.app via TestClient, monkeypatch server.require_sb
with an in-memory fake Supabase, and stub the AI providers so no network/keys are
needed. Background tasks (ingest / podcast) run synchronously under TestClient, so
POSTing a source / podcast exercises the pipelines end-to-end against the fake DB.
"""
from __future__ import annotations

import datetime as _dt
import os
import sys
import uuid
from pathlib import Path

import pytest

# ---- Env BEFORE importing server ----
os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_API_TOKEN", "test-token")
os.environ.setdefault("TEVO_API_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")
os.environ.setdefault("ANTHROPIC_API_KEY", "sk-ant-test")
os.environ.setdefault("OPENAI_API_KEY", "sk-openai-test")
os.environ.setdefault("ONB_WIKI_SOURCES", "false")  # no network in tests unless opted in

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
from fastapi.testclient import TestClient  # noqa: E402

import server as app_module  # noqa: E402
from open_notebook import ask as onb_ask  # noqa: E402
from open_notebook import chat as onb_chat  # noqa: E402
from open_notebook import config as onb_config  # noqa: E402
from open_notebook import ingest as onb_ingest  # noqa: E402
from open_notebook import performers as onb_performers  # noqa: E402
from open_notebook import podcasts as onb_podcasts  # noqa: E402
from open_notebook import prompts as onb_prompts  # noqa: E402
from open_notebook import providers as onb_providers  # noqa: E402
from open_notebook import repository as repo  # noqa: E402
from open_notebook import search as onb_search  # noqa: E402
from open_notebook import transformations as onb_transforms  # noqa: E402
from open_notebook import wikipedia as onb_wikipedia  # noqa: E402
from open_notebook.providers import ProviderError  # noqa: E402


# ============================================================ Fake Supabase
class _Result:
    def __init__(self, data):
        self.data = data


class _Rpc:
    def __init__(self, data):
        self._data = data

    def execute(self):
        return _Result(self._data)


# Column defaults the real DB applies (DEFAULT clauses) but the fake must model,
# so eq("archived", False) filters behave like production on freshly-inserted rows.
_DEFAULTS = {
    "onb_notebooks": {"archived": False},
}


class _Query:
    def __init__(self, store, table):
        self.store = store
        self.table = table
        self.rows = store.setdefault(table, [])
        self._op = "select"
        self._payload = None
        self._filters = []
        self._order = None
        self._limit = None

    def select(self, *_a, **_k):
        self._op = "select"; return self

    def insert(self, payload, *_a, **_k):
        self._op = "insert"; self._payload = payload; return self

    def upsert(self, payload, *_a, **_k):
        self._op = "upsert"; self._payload = payload; return self

    def update(self, patch, *_a, **_k):
        self._op = "update"; self._payload = patch; return self

    def delete(self, *_a, **_k):
        self._op = "delete"; return self

    def eq(self, col, val):
        self._filters.append(("eq", col, val)); return self

    def in_(self, col, vals):
        self._filters.append(("in", col, list(vals))); return self

    def ilike(self, col, pattern):
        self._filters.append(("ilike", col, pattern.strip("%").lower())); return self

    def contains(self, col, vals):
        self._filters.append(("contains", col, list(vals))); return self

    def filter(self, col, op, val):
        if op == "cs":  # array-contains: "{123}" → membership check
            vals = [v for v in str(val).strip("{}").split(",") if v]
            self._filters.append(("contains_str", col, vals))
        else:
            self._filters.append((op, col, val))
        return self

    def order(self, col, desc=False):
        self._order = (col, desc); return self

    def limit(self, n):
        self._limit = n; return self

    def _match(self, row):
        for op, col, val in self._filters:
            if op == "eq" and row.get(col) != val:
                return False
            if op == "in" and row.get(col) not in val:
                return False
            if op == "ilike":
                v = row.get(col)
                if v is None or val not in str(v).lower():
                    return False
            if op == "contains":
                v = row.get(col) or []
                if not all(x in v for x in val):
                    return False
            if op == "contains_str":
                rv = [str(x) for x in (row.get(col) or [])]
                if not all(x in rv for x in val):
                    return False
        return True

    def execute(self):
        if self._op == "insert":
            payloads = self._payload if isinstance(self._payload, list) else [self._payload]
            out = []
            for p in payloads:
                row = dict(_DEFAULTS.get(self.table, {})); row.update(p)
                row.setdefault("id", str(uuid.uuid4()))
                self.rows.append(row); out.append(row)
            return _Result(out)
        if self._op == "upsert":
            payloads = self._payload if isinstance(self._payload, list) else [self._payload]
            out = []
            for p in payloads:
                existing = next((r for r in self.rows if all(r.get(k) == p.get(k) for k in p)), None)
                if existing is None:
                    row = dict(p); row.setdefault("id", str(uuid.uuid4()))
                    self.rows.append(row); out.append(row)
                else:
                    existing.update(p); out.append(existing)
            return _Result(out)
        if self._op == "update":
            hits = [r for r in self.rows if self._match(r)]
            for r in hits:
                r.update(self._payload)
            return _Result([dict(r) for r in hits])
        if self._op == "delete":
            self.rows[:] = [r for r in self.rows if not self._match(r)]
            return _Result([])
        res = [dict(r) for r in self.rows if self._match(r)]
        if self._order:
            col, desc = self._order
            res.sort(key=lambda r: (r.get(col) is None, r.get(col)), reverse=desc)
        if self._limit is not None:
            res = res[: self._limit]
        return _Result(res)


class _Bucket:
    def __init__(self, fail=False):
        self.fail = fail
        self.uploads = []

    def upload(self, path, data, opts=None):
        if self.fail:
            raise RuntimeError("bucket missing")
        self.uploads.append((path, data, opts))
        return {"path": path}

    def get_public_url(self, path):
        return f"https://fake.storage/{path}"


class _StorageClient:
    def __init__(self, fail=False):
        self._bucket = _Bucket(fail=fail)

    def from_(self, _name):
        return self._bucket


class FakeSB:
    def __init__(self, rpc=None, storage_fail=False):
        self.store = {}
        self._rpc = rpc or {}
        self.rpc_calls = []
        self.storage = _StorageClient(fail=storage_fail)

    def table(self, name):
        return _Query(self.store, name)

    def rpc(self, name, params=None):
        self.rpc_calls.append((name, params or {}))
        return _Rpc(self._rpc.get(name, []))


# ============================================================ Fixtures / helpers
@pytest.fixture
def fake():
    return FakeSB()


@pytest.fixture
def client(monkeypatch, fake):
    monkeypatch.setattr(app_module, "require_sb", lambda: fake)
    return TestClient(app_module.app)


def smart_chat(messages, *, system=None, **_k):
    """Deterministic stand-in for providers.chat that returns shape-appropriate
    output per call site so the JSON-parsing branches are exercised."""
    user = messages[-1]["content"] if messages else ""
    if system and "break a research question" in system:
        return '["query one", "query two"]'
    if "podcast outline" in user:
        return '[{"title": "Segment 1", "points": ["a", "b"]}]'
    if "podcast transcript" in user:
        return '[{"speaker": "Alex", "text": "Hello"}, {"speaker": "Sam", "text": "Hi"}]'
    return "SYNTHESIZED ANSWER"


@pytest.fixture
def stub_providers(monkeypatch):
    monkeypatch.setattr(onb_providers, "chat", smart_chat)
    monkeypatch.setattr(onb_providers, "embed_texts", lambda texts, **_k: [[0.01] * 1536 for _ in texts])
    monkeypatch.setattr(onb_providers, "embed_text", lambda _t, **_k: [0.01] * 1536)
    monkeypatch.setattr(onb_providers, "tts", lambda _t, **_k: b"MP3BYTES")
    monkeypatch.setattr(onb_providers, "transcribe", lambda _b, **_k: "transcribed")

    def _stream(_messages, **_k):
        for delta in ("Hel", "lo"):
            yield delta
    monkeypatch.setattr(onb_providers, "chat_stream", lambda *a, **k: _stream(*a, **k))
    return monkeypatch


def _mk_notebook(client, name="NB"):
    return client.post("/api/notebook/notebooks", json={"name": name, "description": "d"}).json()


# ============================================================ config
def test_config_flag_and_status(monkeypatch):
    monkeypatch.delenv("ONB_ENABLED", raising=False)
    assert onb_config._flag("ONB_ENABLED", True) is True
    monkeypatch.setenv("ONB_ENABLED", "off")
    assert onb_config._flag("ONB_ENABLED", True) is False
    st = onb_config.provider_status()
    assert set(("chat", "embeddings", "tts", "embed_dim")).issubset(st)


# ============================================================ config endpoint / flag
def test_config_endpoint(client):
    r = client.get("/api/notebook/config")
    assert r.status_code == 200
    assert r.json()["enabled"] is True


def test_disabled_flag_404(client, monkeypatch):
    monkeypatch.setattr(onb_config, "ONB_ENABLED", False)
    assert client.get("/api/notebook/config").status_code == 404
    assert client.get("/api/notebook/notebooks").status_code == 404


# ============================================================ notebooks CRUD
def test_notebook_crud(client):
    assert client.post("/api/notebook/notebooks", json={}).status_code == 400
    nb = _mk_notebook(client)
    nid = nb["id"]
    lst = client.get("/api/notebook/notebooks").json()
    assert any(n["id"] == nid for n in lst["items"])
    assert client.get(f"/api/notebook/notebooks/{nid}").json()["name"] == "NB"
    assert client.get("/api/notebook/notebooks/does-not-exist").status_code == 404
    up = client.put(f"/api/notebook/notebooks/{nid}", json={"name": "NB2", "archived": True})
    assert up.json()["name"] == "NB2"
    assert client.put("/api/notebook/notebooks/nope", json={"name": "x"}).status_code == 404
    # archived excluded by default
    assert all(n["id"] != nid for n in client.get("/api/notebook/notebooks").json()["items"])
    assert any(n["id"] == nid for n in client.get("/api/notebook/notebooks?include_archived=true").json()["items"])
    assert client.delete(f"/api/notebook/notebooks/{nid}").json()["ok"] is True


def test_update_notebook_empty_patch(fake):
    nb = repo.create_notebook(fake, name="x")
    # patch with no allowed keys returns the current row
    same = repo.update_notebook(fake, nb["id"], {"bogus": 1})
    assert same["id"] == nb["id"]


# ============================================================ sources + ingest via router
def test_source_text_ingest_flow(client, stub_providers):
    nb = _mk_notebook(client)
    nid = nb["id"]
    # unknown kind
    assert client.post(f"/api/notebook/notebooks/{nid}/sources", json={"kind": "bad"}).status_code == 400
    # text missing
    assert client.post(f"/api/notebook/notebooks/{nid}/sources", json={"kind": "text", "text": ""}).status_code == 400
    # add to missing notebook
    assert client.post("/api/notebook/notebooks/nope/sources", json={"kind": "text", "text": "hi"}).status_code == 404
    r = client.post(f"/api/notebook/notebooks/{nid}/sources",
                    json={"kind": "text", "text": "The quick brown fox. " * 200, "title": "T"})
    assert r.status_code == 200
    sid = r.json()["source"]["id"]
    # background ingest ran synchronously → status done, embeddings present
    st = client.get(f"/api/notebook/sources/{sid}/status").json()
    assert st["status"] == "done"
    assert client.get(f"/api/notebook/sources/{sid}").json()["full_text"]
    items = client.get(f"/api/notebook/notebooks/{nid}/sources").json()["items"]
    assert any(s["id"] == sid for s in items)
    # retry + delete
    assert client.post(f"/api/notebook/sources/{sid}/retry").json()["job_id"]
    assert client.post("/api/notebook/sources/nope/retry").status_code == 404
    assert client.get("/api/notebook/sources/nope").status_code == 404
    assert client.get("/api/notebook/sources/nope/status").status_code == 404
    assert client.delete(f"/api/notebook/sources/{sid}").json()["ok"] is True


def test_source_url_and_pdf_asset_builders(client, stub_providers, monkeypatch):
    nb = _mk_notebook(client)
    nid = nb["id"]
    # url bad scheme
    assert client.post(f"/api/notebook/notebooks/{nid}/sources", json={"kind": "url", "url": "ftp://x"}).status_code == 400
    # patch requests + SSRF guard for the url ingest
    import requests
    monkeypatch.setattr(onb_ingest, "_assert_public_url", lambda url: None)

    class _Resp:
        text = "<html><head><title>Doc</title></head><body><p>Hello world body text</p><script>x</script></body></html>"
        is_redirect = False
        is_permanent_redirect = False
        headers = {}
        def raise_for_status(self):
            return None
    monkeypatch.setattr(requests, "get", lambda *a, **k: _Resp())
    r = client.post(f"/api/notebook/notebooks/{nid}/sources", json={"kind": "url", "url": "https://ex.com"})
    assert r.status_code == 200
    # pdf missing data
    assert client.post(f"/api/notebook/notebooks/{nid}/sources", json={"kind": "pdf", "data": ""}).status_code == 400
    # pdf with data-URI prefix (parse will fail on junk → source status error, but request ok)
    r2 = client.post(f"/api/notebook/notebooks/{nid}/sources",
                     json={"kind": "pdf", "data": "data:application/pdf;base64,QUJD", "filename": "f.pdf"})
    assert r2.status_code == 200


# ============================================================ insights + transformations
def test_transformations_and_insights(client, fake, stub_providers):
    nb = _mk_notebook(client)
    nid = nb["id"]
    # create transformation (validation)
    assert client.post("/api/notebook/transformations", json={"name": "", "prompt": ""}).status_code == 400
    t = client.post("/api/notebook/transformations",
                    json={"name": "summary", "prompt": "Summarize.", "title": "Summary", "apply_default": True}).json()
    assert client.get("/api/notebook/transformations").json()["items"]
    up = client.put(f"/api/notebook/transformations/{t['id']}", json={"title": "S2"})
    assert up.json()["title"] == "S2"
    assert client.put("/api/notebook/transformations/nope", json={"title": "x"}).status_code == 404
    # a source to run against
    r = client.post(f"/api/notebook/notebooks/{nid}/sources", json={"kind": "text", "text": "body text here"})
    sid = r.json()["source"]["id"]
    # default transformation auto-ran on ingest → at least one insight
    ins = client.get(f"/api/notebook/sources/{sid}/insights").json()["items"]
    assert ins
    # run explicitly
    run = client.post(f"/api/notebook/sources/{sid}/insights", json={"transformation_id": t["id"]})
    assert run.status_code == 200
    assert client.post(f"/api/notebook/sources/{sid}/insights", json={}).status_code == 400
    assert client.post(f"/api/notebook/sources/{sid}/insights", json={"transformation_id": "nope"}).status_code == 404
    assert client.delete(f"/api/notebook/transformations/{t['id']}").json()["ok"] is True


def test_run_transformation_provider_and_value_errors(client, fake, monkeypatch):
    nb = _mk_notebook(client)
    nid = nb["id"]
    # source with no text → ValueError → 400
    src = repo.create_source(fake, title=None, asset={"kind": "text"}, status="done", full_text="")
    repo.link_source(fake, nid, src["id"])
    t = repo.create_transformation(fake, name="s", prompt="p")
    monkeypatch.setattr(onb_providers, "chat", smart_chat)
    r = client.post(f"/api/notebook/sources/{src['id']}/insights", json={"transformation_id": t["id"]})
    assert r.status_code == 400
    # provider error → 503
    src2 = repo.create_source(fake, title=None, asset={"kind": "text"}, status="done", full_text="x")
    def _boom(*a, **k):
        raise ProviderError("no key")
    monkeypatch.setattr(onb_providers, "chat", _boom)
    r2 = client.post(f"/api/notebook/sources/{src2['id']}/insights", json={"transformation_id": t["id"]})
    assert r2.status_code == 503


# ============================================================ notes
def test_notes_crud(client):
    nb = _mk_notebook(client)
    nid = nb["id"]
    note = client.post(f"/api/notebook/notebooks/{nid}/notes", json={"title": "n", "content": "c"}).json()
    assert client.get(f"/api/notebook/notebooks/{nid}/notes").json()["items"]
    up = client.put(f"/api/notebook/notes/{note['id']}", json={"content": "c2"})
    assert up.json()["content"] == "c2"
    assert client.put("/api/notebook/notes/nope", json={"content": "x"}).status_code == 404
    assert client.delete(f"/api/notebook/notes/{note['id']}").json()["ok"] is True


# ============================================================ search + ask
def test_search_endpoints(client, fake, stub_providers):
    fake._rpc["onb_text_search"] = [{"result_kind": "source", "row_id": "1", "content": "hit"}]
    fake._rpc["onb_vector_search"] = [{"result_kind": "source", "row_id": "1", "content": "hit", "similarity": 0.9}]
    assert client.post("/api/notebook/search", json={"query": ""}).status_code == 400
    assert client.post("/api/notebook/search", json={"query": "x", "kind": "bogus"}).status_code == 400
    txt = client.post("/api/notebook/search", json={"query": "x"}).json()
    assert txt["kind"] == "text" and txt["results"]
    vec = client.post("/api/notebook/search", json={"query": "x", "kind": "vector"}).json()
    assert vec["kind"] == "vector"
    # ask
    assert client.post("/api/notebook/search/ask", json={"question": ""}).status_code == 400
    ans = client.post("/api/notebook/search/ask", json={"question": "why?"}).json()
    assert ans["answer"]


def test_search_and_ask_provider_errors(client, monkeypatch):
    def _boom(*a, **k):
        raise ProviderError("no key")
    monkeypatch.setattr(onb_providers, "embed_text", _boom)
    # vector search still needs embeddings → 503
    assert client.post("/api/notebook/search", json={"query": "x", "kind": "vector"}).status_code == 503
    # ask only 503s when CHAT (Anthropic) is unavailable — missing embeddings falls
    # back to text search, not an error.
    monkeypatch.setattr(onb_providers, "chat", _boom)
    assert client.post("/api/notebook/search/ask", json={"question": "q"}).status_code == 503


# ============================================================ chat
def test_chat_stream_and_nonstream(client, stub_providers):
    nb = _mk_notebook(client)
    nid = nb["id"]
    # seed a source so build_context has material
    client.post(f"/api/notebook/notebooks/{nid}/sources", json={"kind": "text", "text": "context body"})
    s = client.post(f"/api/notebook/notebooks/{nid}/chat/sessions", json={"title": "s"}).json()
    sid = s["id"]
    # non-stream
    r = client.post(f"/api/notebook/chat/sessions/{sid}/messages?stream=false", json={"message": "hi"})
    assert r.status_code == 200 and r.json()["answer"]
    # message required
    assert client.post(f"/api/notebook/chat/sessions/{sid}/messages?stream=false", json={"message": ""}).status_code == 400
    # bad session
    assert client.post("/api/notebook/chat/sessions/nope/messages", json={"message": "hi"}).status_code == 404
    # stream
    with client.stream("POST", f"/api/notebook/chat/sessions/{sid}/messages", json={"message": "yo"}) as resp:
        body = "".join(chunk for chunk in resp.iter_text())
    assert "delta" in body and "done" in body
    assert client.get(f"/api/notebook/chat/sessions/{sid}/messages").json()["items"]
    assert client.get(f"/api/notebook/notebooks/{nid}/chat/sessions").json()["items"]


def test_chat_provider_errors(client, monkeypatch):
    nb = _mk_notebook(client)
    nid = nb["id"]
    s = client.post(f"/api/notebook/notebooks/{nid}/chat/sessions", json={}).json()
    sid = s["id"]

    def _boom(*a, **k):
        raise ProviderError("no key")
    monkeypatch.setattr(onb_providers, "chat", _boom)
    assert client.post(f"/api/notebook/chat/sessions/{sid}/messages?stream=false", json={"message": "hi"}).status_code == 503
    monkeypatch.setattr(onb_providers, "chat_stream", _boom)
    assert client.post(f"/api/notebook/chat/sessions/{sid}/messages", json={"message": "hi"}).status_code == 503


def test_chat_stream_midstream_error(client, monkeypatch):
    nb = _mk_notebook(client)
    nid = nb["id"]
    s = client.post(f"/api/notebook/notebooks/{nid}/chat/sessions", json={}).json()
    sid = s["id"]

    def _stream(*a, **k):
        yield "part"
        raise ProviderError("mid")
    monkeypatch.setattr(onb_providers, "chat_stream", lambda *a, **k: _stream())
    with client.stream("POST", f"/api/notebook/chat/sessions/{sid}/messages", json={"message": "yo"}) as resp:
        body = "".join(chunk for chunk in resp.iter_text())
    assert "error" in body


# ============================================================ podcasts
def test_podcast_flow(client, fake, stub_providers):
    nb = _mk_notebook(client)
    nid = nb["id"]
    # no material → 400
    assert client.post(f"/api/notebook/notebooks/{nid}/podcasts", json={}).status_code == 400
    assert client.post("/api/notebook/notebooks/nope/podcasts", json={"content": "x"}).status_code == 404
    # seed a source
    client.post(f"/api/notebook/notebooks/{nid}/sources", json={"kind": "text", "text": "podcast source body"})
    # profiles
    assert client.post("/api/notebook/episode-profiles", json={}).status_code == 400
    client.post("/api/notebook/episode-profiles", json={"name": "ep", "num_segments": 3})
    assert client.get("/api/notebook/episode-profiles").json()["items"]
    assert client.post("/api/notebook/speaker-profiles", json={}).status_code == 400
    client.post("/api/notebook/speaker-profiles", json={"name": "sp", "speakers": [{"name": "Alex"}]})
    assert client.get("/api/notebook/speaker-profiles").json()["items"]
    # generate
    r = client.post(f"/api/notebook/notebooks/{nid}/podcasts", json={
        "name": "Ep1", "briefing": "brief",
        "episode_profile": {"num_segments": 2},
        "speaker_profile": {"speakers": [{"name": "Alex"}, {"name": "Sam", "voice_id": "nova"}]},
    })
    assert r.status_code == 200
    eid = r.json()["episode"]["id"]
    ep = client.get(f"/api/notebook/episodes/{eid}").json()
    assert ep["status"] == "done" and ep["audio_url"]
    assert client.get("/api/notebook/episodes").json()["items"]
    assert client.get("/api/notebook/episodes/nope").status_code == 404
    # job endpoint
    jid = r.json()["job_id"]
    assert client.get(f"/api/notebook/jobs/{jid}").json()["status"] == "done"
    assert client.get("/api/notebook/jobs/nope").status_code == 404
    assert client.delete(f"/api/notebook/episodes/{eid}").json()["ok"] is True


def test_podcast_error_paths(fake, monkeypatch):
    # episode not found
    with pytest.raises(ValueError):
        onb_podcasts.generate_episode(fake, "missing")
    # transcript empty → error status recorded
    monkeypatch.setattr(onb_providers, "chat", lambda *a, **k: "not json")
    ep = repo.create_episode(fake, {"name": "e", "episode_profile": {}, "speaker_profile": {}, "content": "c", "status": "queued"})
    job = repo.create_job(fake, kind="podcast", ref_id=ep["id"])
    with pytest.raises(Exception):
        onb_podcasts.generate_episode(fake, ep["id"], job_id=job["id"])
    assert repo.get_episode(fake, ep["id"])["status"] == "error"
    assert repo.get_job(fake, job["id"])["status"] == "error"


def test_podcast_upload_failure(monkeypatch):
    fake = FakeSB(storage_fail=True)
    monkeypatch.setattr(onb_providers, "chat", smart_chat)
    monkeypatch.setattr(onb_providers, "tts", lambda _t, **_k: b"MP3")
    ep = repo.create_episode(fake, {"name": "e", "episode_profile": {"num_segments": 1},
                                    "speaker_profile": {"speakers": [{"name": "Alex"}]}, "content": "c", "status": "queued"})
    with pytest.raises(RuntimeError):
        onb_podcasts.generate_episode(fake, ep["id"])
    assert repo.get_episode(fake, ep["id"])["status"] == "error"


def test_podcast_transcript_only_without_tts(fake, monkeypatch):
    """No TTS provider (Claude-key-only) → episode succeeds as transcript-only
    instead of erroring: status 'done', no audio_url, informational note, and
    the transcript is persisted."""
    monkeypatch.setattr(onb_providers, "chat", smart_chat)
    monkeypatch.setattr(onb_providers, "tts",
                        lambda *a, **k: (_ for _ in ()).throw(ProviderError("no tts")))
    # with job_id → the job is also marked done
    ep = repo.create_episode(fake, {"name": "e", "episode_profile": {"num_segments": 1},
                                    "speaker_profile": {"speakers": [{"name": "Alex"}]},
                                    "content": "c", "status": "queued"})
    job = repo.create_job(fake, kind="podcast", ref_id=ep["id"])
    out = onb_podcasts.generate_episode(fake, ep["id"], job_id=job["id"])
    assert out["status"] == "done" and out.get("audio_url") is None
    assert "Audio skipped" in (out.get("error") or "")
    assert repo.get_job(fake, job["id"])["status"] == "done"
    assert repo.get_episode(fake, ep["id"])["transcript"]
    # without job_id → still transcript-only done (covers the no-job branch)
    ep2 = repo.create_episode(fake, {"name": "e2", "episode_profile": {"num_segments": 1},
                                     "speaker_profile": {"speakers": [{"name": "Alex"}]},
                                     "content": "c", "status": "queued"})
    out2 = onb_podcasts.generate_episode(fake, ep2["id"])
    assert out2["status"] == "done" and out2.get("audio_url") is None


def test_build_podcast_content_budget(fake):
    nb = repo.create_notebook(fake, name="n")
    empty = repo.create_source(fake, title="empty", asset={}, status="done", full_text="")
    repo.link_source(fake, nb["id"], empty["id"])  # exercises the "no body → continue" branch
    for i in range(3):
        s = repo.create_source(fake, title=f"s{i}", asset={}, status="done", full_text="z" * 9000)
        repo.link_source(fake, nb["id"], s["id"])
    out = onb_podcasts.build_podcast_content(fake, nb["id"], char_budget=10000)
    assert out and len(out) < 30000


def test_podcast_empty_turn_and_extract_json(fake, monkeypatch):
    # _extract_json: brackets present but invalid → falls through to default
    assert onb_podcasts._extract_json("[bad]", default=["d"]) == ["d"]
    assert onb_podcasts._extract_json("{bad}", default={"d": 1}) == {"d": 1}

    def _chat(messages, **k):
        user = messages[-1]["content"]
        if "podcast outline" in user:
            return '[{"title": "s", "points": ["p"]}]'
        return '[{"speaker": "Alex", "text": "hi"}, {"speaker": "Sam", "text": ""}]'
    monkeypatch.setattr(onb_providers, "chat", _chat)
    monkeypatch.setattr(onb_providers, "tts", lambda _t, **_k: b"MP3")
    ep = repo.create_episode(fake, {"name": "e", "episode_profile": {"num_segments": 1},
                                    "speaker_profile": {}, "content": "c", "status": "queued"})
    out = onb_podcasts.generate_episode(fake, ep["id"])  # empty-text turn is skipped
    assert out["status"] == "done"


# ============================================================ ingest unit
def test_extract_text_variants(monkeypatch):
    assert onb_ingest.extract_text({"kind": "text", "text": " hi ", "title": "T"}) == ("hi", "T")
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest.extract_text({"kind": "video"})
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest.extract_text({"kind": "mystery"})


def _resp(text="<html><title>Ti</title><body><p>Some text here</p></body></html>",
          redirect=False, location=None):
    class _R:
        is_redirect = redirect
        is_permanent_redirect = False
        headers = {"Location": location} if location is not None else {}
        def __init__(self):
            self.text = text
        def raise_for_status(self):
            return None
    return _R()


def test_assert_public_url(monkeypatch):
    import socket
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._assert_public_url("ftp://x")           # bad scheme
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._assert_public_url("http://")            # no host
    # resolve failure
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: (_ for _ in ()).throw(OSError("dns")))
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._assert_public_url("https://x.com")
    # private IP → refuse
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: [(2, 1, 6, "", ("169.254.169.254", 0))])
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._assert_public_url("http://metadata")
    # public IP → ok
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: [(2, 1, 6, "", ("93.184.216.34", 0))])
    onb_ingest._assert_public_url("https://x.com")


def test_extract_url(monkeypatch):
    import requests
    monkeypatch.setattr(onb_ingest, "_assert_public_url", lambda url: None)  # skip DNS in unit test

    # a redirect hop then a 200
    calls = {"n": 0}
    def _get(url, **k):
        calls["n"] += 1
        if calls["n"] == 1:
            return _resp(redirect=True, location="https://x.com/final")
        return _resp()
    monkeypatch.setattr(requests, "get", _get)
    text, title = onb_ingest._extract_url("https://x.com")
    assert "Some text" in text and title == "Ti"

    # redirect with no Location → break, body is empty → "no extractable text"
    monkeypatch.setattr(requests, "get",
                        lambda *a, **k: _resp(redirect=True, location=None, text="<html><body></body></html>"))
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._extract_url("https://x.com")

    # too many redirects
    monkeypatch.setattr(requests, "get", lambda *a, **k: _resp(redirect=True, location="https://x.com/loop"))
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._extract_url("https://x.com")

    # fetch raises
    monkeypatch.setattr(requests, "get", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("net")))
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._extract_url("https://x.com")

    # empty body
    monkeypatch.setattr(requests, "get", lambda *a, **k: _resp(text="<html><body></body></html>"))
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._extract_url("https://x.com")

    # non-2xx → raise_for_status raises → IngestError
    class _Bad:
        is_redirect = False
        is_permanent_redirect = False
        headers = {}
        text = ""
        def raise_for_status(self):
            raise RuntimeError("404")
    monkeypatch.setattr(requests, "get", lambda *a, **k: _Bad())
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._extract_url("https://x.com")

    # SSRF guard rejection propagates
    monkeypatch.setattr(onb_ingest, "_assert_public_url",
                        lambda url: (_ for _ in ()).throw(onb_ingest.IngestError("private")))
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._extract_url("https://x.com")


def test_extract_pdf(monkeypatch):
    import pypdf
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._extract_pdf({})

    class _Page:
        def __init__(self, t):
            self._t = t
        def extract_text(self):
            return self._t

    class _Reader:
        def __init__(self, _buf):
            self.pages = [_Page("Page one text"), _Page("")]
    monkeypatch.setattr(pypdf, "PdfReader", _Reader)
    import base64
    txt = onb_ingest._extract_pdf({"data": base64.b64encode(b"%PDF-1.4 fake").decode()})
    assert "Page one" in txt

    class _EmptyReader:
        def __init__(self, _buf):
            self.pages = [_Page("")]
    monkeypatch.setattr(pypdf, "PdfReader", _EmptyReader)
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._extract_pdf({"data": base64.b64encode(b"x").decode()})

    class _BadReader:
        def __init__(self, _buf):
            raise ValueError("bad pdf")
    monkeypatch.setattr(pypdf, "PdfReader", _BadReader)
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._extract_pdf({"data": base64.b64encode(b"x").decode()})


def test_chunk_text():
    assert onb_ingest.chunk_text("") == []
    assert onb_ingest.chunk_text("short") == ["short"]
    big = "para one.\n\n" + ("word " * 1000) + "\n\nlast sentence. more."
    chunks = onb_ingest.chunk_text(big, size=200, overlap=20)
    assert len(chunks) > 1


def test_ingest_source_missing_and_error(fake, monkeypatch, stub_providers):
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest.ingest_source(fake, "missing")
    # extraction error recorded on source + job
    src = repo.create_source(fake, title=None, asset={"kind": "video"}, status="queued")
    job = repo.create_job(fake, kind="ingest", ref_id=src["id"])
    with pytest.raises(Exception):
        onb_ingest.ingest_source(fake, src["id"], job_id=job["id"])
    assert repo.get_source(fake, src["id"])["status"] == "error"
    assert repo.get_job(fake, job["id"])["status"] == "error"


def test_ingest_source_skip_flags_and_raise_without_job(fake, monkeypatch):
    # embed=False + run_transformations=False → both skip branches
    src = repo.create_source(fake, title=None, asset={"kind": "text", "text": "hi body"}, status="queued")
    out = onb_ingest.ingest_source(fake, src["id"], embed=False, run_transformations=False)
    assert out["status"] == "done"
    assert not fake.store.get("onb_source_embeddings")
    # error path with NO job_id (covers the `if job_id` false branch in except)
    bad = repo.create_source(fake, title=None, asset={"kind": "video"}, status="queued")
    with pytest.raises(Exception):
        onb_ingest.ingest_source(fake, bad["id"])
    assert repo.get_source(fake, bad["id"])["status"] == "error"


def test_decompose_question_already_present(fake, monkeypatch):
    monkeypatch.setattr(onb_providers, "chat", lambda *a, **k: '["myq"]')
    # question already in the decomposed list → append branch skipped
    assert onb_ask._decompose("myq") == ["myq"]


def test_ingest_embeddings_best_effort(fake, monkeypatch):
    # a missing embeddings provider must NOT fail the source — text still saved,
    # status stays "done" (vector search just won't include it).
    src = repo.create_source(fake, title=None, asset={"kind": "text", "text": "hello body"}, status="queued")

    def _boom(texts, **k):
        raise ProviderError("no openai key")
    monkeypatch.setattr(onb_providers, "embed_texts", _boom)
    out = onb_ingest.ingest_source(fake, src["id"])
    assert out["status"] == "done"
    assert not fake.store.get("onb_source_embeddings")


def test_ingest_default_transform_error_paths(fake, monkeypatch):
    src = repo.create_source(fake, title=None, asset={"kind": "text", "text": "hello body"}, status="queued")
    monkeypatch.setattr(onb_providers, "embed_texts", lambda texts, **k: [[0.0] * 1536 for _ in texts])
    # default transform that raises a generic error → continue (swallowed)
    repo.create_transformation(fake, name="t1", prompt="p", apply_default=True)

    def _boom(db, **k):
        raise RuntimeError("x")
    monkeypatch.setattr(onb_transforms, "run_transformation", _boom)
    out = onb_ingest.ingest_source(fake, src["id"])
    assert out["status"] == "done"
    # default transform that raises ProviderError → break
    def _prov(db, **k):
        raise ProviderError("no key")
    monkeypatch.setattr(onb_transforms, "run_transformation", _prov)
    src2 = repo.create_source(fake, title=None, asset={"kind": "text", "text": "hello body"}, status="queued")
    onb_ingest.ingest_source(fake, src2["id"])
    # no embed path
    src3 = repo.create_source(fake, title=None, asset={"kind": "text", "text": ""}, status="queued")
    onb_ingest._embed_source(fake, src3["id"], "")  # empty chunks → no-op


# ============================================================ ask / chat / search unit
def test_ask_no_passages(fake, monkeypatch):
    monkeypatch.setattr(onb_providers, "chat", smart_chat)
    monkeypatch.setattr(onb_providers, "embed_text", lambda _t, **_k: [0.0] * 1536)
    out = onb_ask.ask(fake, question="q", notebook_id=None)
    assert out["passages"] == [] and "No relevant" in out["answer"]
    assert onb_ask.ask(fake, question="")["queries"] == []


def test_ask_with_passages(fake, monkeypatch):
    monkeypatch.setattr(onb_providers, "chat", smart_chat)
    monkeypatch.setattr(onb_providers, "embed_text", lambda _t, **_k: [0.0] * 1536)
    fake._rpc["onb_vector_search"] = [
        {"result_kind": "source", "row_id": "a", "source_id": "s", "content": "alpha", "similarity": 0.9},
        {"result_kind": "source", "row_id": "a", "source_id": "s", "content": "alpha", "similarity": 0.5},
        {"result_kind": "note", "row_id": None, "content": "skip-none", "similarity": 0.4},
    ]
    out = onb_ask.ask(fake, question="why", notebook_id="nb")
    assert out["answer"] and out["passages"]


def test_ask_text_fallback(fake, monkeypatch):
    # no embeddings provider → Ask falls back to Postgres full-text search, Claude answers
    monkeypatch.setattr(onb_providers, "chat", smart_chat)

    def _boom(*a, **k):
        raise ProviderError("no openai key")
    monkeypatch.setattr(onb_providers, "embed_text", _boom)
    fake._rpc["onb_text_search"] = [
        {"result_kind": "source", "row_id": "s1", "source_id": "s1", "content": "alpha", "rank": 0.5}]
    out = onb_ask.ask(fake, question="why", notebook_id="nb")
    assert out["mode"] == "text"
    assert out["answer"] and out["passages"]
    assert out["passages"][0]["score"] == 0.5


def test_parse_json_array_bad():
    assert onb_ask._parse_json_array("not json") == []
    assert onb_ask._parse_json_array("[a]") == []  # brackets present, invalid JSON → except branch


def test_chat_build_context_and_reply(fake, monkeypatch):
    nb = repo.create_notebook(fake, name="n")
    s = repo.create_source(fake, title="S", asset={}, status="done", full_text="body text")
    repo.link_source(fake, nb["id"], s["id"])
    repo.add_insight(fake, source_id=s["id"], insight_type="sum", content="insight body")
    note = repo.create_note(fake, title="N", content="note body")
    repo.link_note(fake, nb["id"], note["id"])
    ctx = onb_chat.build_context(fake, nb["id"])
    assert "SOURCE" in ctx and "INSIGHT" in ctx and "NOTE" in ctx
    monkeypatch.setattr(onb_providers, "chat", smart_chat)
    sess = repo.create_chat_session(fake, notebook_id=nb["id"])
    ans = onb_chat.reply(fake, session_id=sess["id"], notebook_id=nb["id"], user_message="hi")
    assert ans


def test_chat_context_empty(fake):
    nb = repo.create_notebook(fake, name="n")
    assert onb_chat.build_context(fake, nb["id"]) == ""
    # empty context branch in prompt
    assert "no sources" in onb_prompts.chat_system_with_context("")


def test_chat_context_budget_breaks(fake, monkeypatch):
    monkeypatch.setattr(onb_chat, "CONTEXT_CHAR_BUDGET", 50)
    monkeypatch.setattr(onb_chat, "PER_SOURCE_CHARS", 40)
    nb = repo.create_notebook(fake, name="n")
    # empty source FIRST (→ "no body → continue"), then two full sources (one with an
    # insight) to exhaust the budget, then a note (→ notes-budget break).
    s0 = repo.create_source(fake, title="C", asset={}, status="done", full_text="")
    repo.link_source(fake, nb["id"], s0["id"])
    s1 = repo.create_source(fake, title="A", asset={}, status="done", full_text="X" * 200)
    repo.link_source(fake, nb["id"], s1["id"])
    repo.add_insight(fake, source_id=s1["id"], insight_type="k", content="insight")
    s2 = repo.create_source(fake, title="B", asset={}, status="done", full_text="Y" * 200)
    repo.link_source(fake, nb["id"], s2["id"])
    note = repo.create_note(fake, title="N", content="note")
    repo.link_note(fake, nb["id"], note["id"])
    ctx = onb_chat.build_context(fake, nb["id"])
    assert "SOURCE" in ctx  # at least one source made it in before the budget tripped


def test_search_unit(fake, monkeypatch):
    assert onb_search.search(fake, query="")["results"] == []
    fake._rpc["onb_text_search"] = [{"row_id": "1"}]
    assert onb_search.search(fake, query="x", kind="text")["results"]
    monkeypatch.setattr(onb_providers, "embed_text", lambda _t, **_k: [0.0] * 1536)
    fake._rpc["onb_vector_search"] = [{"row_id": "1"}]
    assert onb_search.search(fake, query="x", kind="vector")["results"]


# ============================================================ providers unit
def test_providers_missing_keys(monkeypatch):
    monkeypatch.setattr(onb_config, "ANTHROPIC_API_KEY", "")
    # No per-service key AND no edge fallback → chat/transform truly unavailable.
    monkeypatch.setattr(onb_config, "SUPABASE_SERVICE_ROLE_KEY", "")
    with pytest.raises(ProviderError):
        onb_providers.chat([{"role": "user", "content": "hi"}])
    with pytest.raises(ProviderError):
        onb_providers.chat_stream([{"role": "user", "content": "hi"}])
    monkeypatch.setattr(onb_config, "OPENAI_API_KEY", "")
    with pytest.raises(ProviderError):
        onb_providers.embed_texts(["a"])
    with pytest.raises(ProviderError):
        onb_providers.transcribe(b"x")
    with pytest.raises(ProviderError):
        onb_providers.tts("hi")
    assert onb_providers.embed_texts([]) == []


def test_providers_with_fake_clients(monkeypatch):
    monkeypatch.setattr(onb_config, "ANTHROPIC_API_KEY", "k")
    monkeypatch.setattr(onb_config, "OPENAI_API_KEY", "k")

    class _Block:
        type = "text"; text = "hello"

    class _Msg:
        content = [_Block(), type("O", (), {"type": "tool"})()]

    class _Stream:
        text_stream = ["a", "b"]
        def __enter__(self):
            return self
        def __exit__(self, *a):
            return False

    class _Messages:
        def create(self, **k):
            return _Msg()
        def stream(self, **k):
            return _Stream()

    class _Anthropic:
        def __init__(self, **k):
            self.messages = _Messages()
    monkeypatch.setattr(onb_providers, "_anthropic_client", lambda: _Anthropic())
    assert onb_providers.chat([{"role": "user", "content": "hi"}], system="s") == "hello"
    assert list(onb_providers.chat_stream([{"role": "user", "content": "hi"}], system="s")) == ["a", "b"]

    class _EmbItem:
        embedding = [0.1] * 1536

    class _EmbResp:
        data = [_EmbItem()]

    class _Embeddings:
        def create(self, **k):
            return _EmbResp()

    class _Speech:
        def create(self, **k):
            return type("S", (), {"read": lambda self: b"MP3"})()

    class _Transcriptions:
        def create(self, **k):
            return type("T", (), {"text": "hi"})()

    class _Audio:
        speech = _Speech()
        transcriptions = _Transcriptions()

    class _OpenAI:
        def __init__(self, **k):
            self.embeddings = _Embeddings()
            self.audio = _Audio()
    monkeypatch.setattr(onb_providers, "_openai_client", lambda: _OpenAI())
    assert onb_providers.embed_text("hi") == [0.1] * 1536
    assert onb_providers.tts("hi") == b"MP3"
    assert onb_providers.transcribe(b"x", filename="a.mp3") == "hi"


def test_providers_upstream_failures(monkeypatch):
    monkeypatch.setattr(onb_config, "ANTHROPIC_API_KEY", "k")
    monkeypatch.setattr(onb_config, "OPENAI_API_KEY", "k")

    class _BadMessages:
        def create(self, **k):
            raise RuntimeError("boom")
        def stream(self, **k):
            raise RuntimeError("boom")

    class _BadAnthropic:
        messages = _BadMessages()
    monkeypatch.setattr(onb_providers, "_anthropic_client", lambda: _BadAnthropic())
    with pytest.raises(ProviderError):
        onb_providers.chat([{"role": "user", "content": "hi"}])
    with pytest.raises(ProviderError):
        list(onb_providers.chat_stream([{"role": "user", "content": "hi"}]))

    class _BadOpenAI:
        class embeddings:
            @staticmethod
            def create(**k):
                raise RuntimeError("boom")

        class audio:
            class speech:
                @staticmethod
                def create(**k):
                    raise RuntimeError("boom")

            class transcriptions:
                @staticmethod
                def create(**k):
                    raise RuntimeError("boom")
    monkeypatch.setattr(onb_providers, "_openai_client", lambda: _BadOpenAI())
    with pytest.raises(ProviderError):
        onb_providers.embed_texts(["a"])
    with pytest.raises(ProviderError):
        onb_providers.tts("hi")
    with pytest.raises(ProviderError):
        onb_providers.transcribe(b"x")


def test_real_provider_client_constructors(monkeypatch):
    """Exercise the real _anthropic_client / _openai_client bodies (SDKs installed)."""
    monkeypatch.setattr(onb_config, "ANTHROPIC_API_KEY", "k")
    monkeypatch.setattr(onb_config, "OPENAI_API_KEY", "k")
    assert onb_providers._anthropic_client() is not None
    assert onb_providers._openai_client() is not None


# ---- edge-function chat fallback (shared platform Anthropic key) ----
class _FakeEdgeResp:
    def __init__(self, status_code, payload, *, raises_json=False):
        self.status_code = status_code
        self._payload = payload
        self._raises_json = raises_json

    def json(self):
        if self._raises_json:
            raise ValueError("bad json")
        return self._payload


def test_edge_chat_available_and_status(monkeypatch):
    monkeypatch.setattr(onb_config, "SUPABASE_URL", "http://sb")
    monkeypatch.setattr(onb_config, "SUPABASE_SERVICE_ROLE_KEY", "svc")

    # anthropic key present → transport 'anthropic', direct-key model
    monkeypatch.setattr(onb_config, "ANTHROPIC_API_KEY", "k")
    assert onb_config.edge_chat_available() is True
    st = onb_config.provider_status()
    assert st["chat"] is True and st["chat_transport"] == "anthropic"
    assert st["chat_model"] == onb_config.ONB_CHAT_MODEL

    # no per-service key but edge available → transport 'edge', edge model
    monkeypatch.setattr(onb_config, "ANTHROPIC_API_KEY", "")
    st = onb_config.provider_status()
    assert st["chat"] is True and st["chat_transport"] == "edge"
    assert st["chat_model"] == onb_config.ONB_EDGE_CHAT_MODEL

    # neither key nor edge → transport 'none', chat unavailable
    monkeypatch.setattr(onb_config, "SUPABASE_SERVICE_ROLE_KEY", "")
    assert onb_config.edge_chat_available() is False
    st = onb_config.provider_status()
    assert st["chat"] is False and st["chat_transport"] == "none"
    assert st["chat_model"] == onb_config.ONB_CHAT_MODEL


def test_edge_chat_success_routes_from_chat(monkeypatch):
    import requests
    monkeypatch.setattr(onb_config, "ANTHROPIC_API_KEY", "")
    monkeypatch.setattr(onb_config, "SUPABASE_URL", "http://sb/")  # trailing slash trimmed
    monkeypatch.setattr(onb_config, "SUPABASE_SERVICE_ROLE_KEY", "svc")
    monkeypatch.setattr(onb_config, "SUPABASE_ANON_KEY", "anon")
    captured = {}

    def _post(url, headers=None, json=None, timeout=None):
        captured.update(url=url, headers=headers, json=json)
        return _FakeEdgeResp(200, {"text": "edge-answer"})
    monkeypatch.setattr(requests, "post", _post)

    assert onb_providers.chat([{"role": "user", "content": "hi"}], system="s") == "edge-answer"
    assert captured["url"] == "http://sb/functions/v1/notebook-llm"
    assert captured["headers"]["Authorization"] == "Bearer svc"
    assert captured["headers"]["apikey"] == "anon"
    assert captured["json"]["model"] == onb_config.ONB_EDGE_CHAT_MODEL
    assert captured["json"]["system"] == "s"
    # streaming path emits the whole completion as a single chunk
    assert list(onb_providers.chat_stream([{"role": "user", "content": "hi"}])) == ["edge-answer"]


def test_edge_chat_apikey_and_model_fallbacks(monkeypatch):
    import requests
    monkeypatch.setattr(onb_config, "ANTHROPIC_API_KEY", "")
    monkeypatch.setattr(onb_config, "SUPABASE_URL", "http://sb")
    monkeypatch.setattr(onb_config, "SUPABASE_SERVICE_ROLE_KEY", "svc")
    monkeypatch.setattr(onb_config, "SUPABASE_ANON_KEY", "")  # no anon → apikey = service role
    captured = {}

    def _post(url, headers=None, json=None, timeout=None):
        captured.update(headers=headers, json=json)
        return _FakeEdgeResp(200, {"text": "ok"})
    monkeypatch.setattr(requests, "post", _post)

    # explicit model honored; no system → key omitted from payload
    assert onb_providers.chat([{"role": "user", "content": "hi"}], model="claude-x") == "ok"
    assert captured["headers"]["apikey"] == "svc"
    assert captured["json"]["model"] == "claude-x"
    assert "system" not in captured["json"]


def test_edge_chat_error_and_empty_paths(monkeypatch):
    import requests
    monkeypatch.setattr(onb_config, "ANTHROPIC_API_KEY", "")
    monkeypatch.setattr(onb_config, "SUPABASE_URL", "http://sb")
    monkeypatch.setattr(onb_config, "SUPABASE_SERVICE_ROLE_KEY", "svc")
    msg = [{"role": "user", "content": "hi"}]

    monkeypatch.setattr(requests, "post", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("refused")))
    with pytest.raises(ProviderError):
        onb_providers.chat(msg)

    monkeypatch.setattr(requests, "post", lambda *a, **k: _FakeEdgeResp(200, None, raises_json=True))
    with pytest.raises(ProviderError):
        onb_providers.chat(msg)

    monkeypatch.setattr(requests, "post", lambda *a, **k: _FakeEdgeResp(503, {"error": "nope"}))
    with pytest.raises(ProviderError):
        onb_providers.chat(msg)

    monkeypatch.setattr(requests, "post", lambda *a, **k: _FakeEdgeResp(500, "plain"))  # non-dict error body
    with pytest.raises(ProviderError):
        onb_providers.chat(msg)

    monkeypatch.setattr(requests, "post", lambda *a, **k: _FakeEdgeResp(200, {}))  # dict, no text → ""
    assert onb_providers.chat(msg) == ""

    monkeypatch.setattr(requests, "post", lambda *a, **k: _FakeEdgeResp(200, ["x"]))  # non-dict body → ""
    assert onb_providers.chat(msg) == ""


# ============================================================ repository extras
def test_repository_listing_branches(fake):
    # list with no notebook filter
    repo.create_source(fake, title="s", asset={}, status="done")
    assert isinstance(repo.list_sources(fake), list)
    assert repo.list_sources(fake, notebook_id="none-nb") == []
    repo.create_note(fake, title="n", content="c")
    assert isinstance(repo.list_notes(fake), list)
    assert repo.list_notes(fake, notebook_id="none-nb") == []
    # transformation update with no allowed keys
    t = repo.create_transformation(fake, name="t", prompt="p")
    assert repo.update_transformation(fake, t["id"], {"bogus": 1})["id"] == t["id"]
    # note update allowed filter
    note = repo.create_note(fake, title="a", content="b")
    assert repo.update_note(fake, note["id"], {"content": "c", "bogus": 1})["content"] == "c"
    # note update with only disallowed keys → returns current row (empty-patch guard)
    assert repo.update_note(fake, note["id"], {"bogus": 1})["id"] == note["id"]
    # unlink source
    nb = repo.create_notebook(fake, name="nb")
    s = repo.create_source(fake, title="x", asset={}, status="done")
    repo.link_source(fake, nb["id"], s["id"])
    assert repo.list_sources(fake, notebook_id=nb["id"])
    repo.unlink_source(fake, nb["id"], s["id"])
    assert repo.list_sources(fake, notebook_id=nb["id"]) == []


def test_replace_source_embeddings(fake):
    src = repo.create_source(fake, title="s", asset={}, status="done")
    repo.replace_source_embeddings(fake, src["id"], [])  # empty → early return
    repo.replace_source_embeddings(fake, src["id"], [
        {"chunk_order": 0, "content": "c", "embedding": [0.0] * 1536}])
    assert fake.store.get("onb_source_embeddings")


def test_transformation_embed_provider_error(fake, monkeypatch):
    src = repo.create_source(fake, title="s", asset={}, status="done", full_text="body text")
    t = repo.create_transformation(fake, name="sum", prompt="Summarize.")
    monkeypatch.setattr(onb_providers, "chat", smart_chat)

    def _boom(*a, **k):
        raise ProviderError("no embed key")
    monkeypatch.setattr(onb_providers, "embed_text", _boom)
    insight = onb_transforms.run_transformation(fake, source_id=src["id"], transformation=t)
    assert insight["content"]  # stored even though embedding failed


def test_run_podcast_background_failure(client, monkeypatch):
    nb = _mk_notebook(client)
    nid = nb["id"]

    def _boom(*a, **k):
        raise RuntimeError("gen failed")
    monkeypatch.setattr(onb_podcasts, "generate_episode", _boom)
    # background task swallows the error; the request still returns 200
    r = client.post(f"/api/notebook/notebooks/{nid}/podcasts", json={"content": "material"})
    assert r.status_code == 200


# ============================================================ performer SQL sources
@pytest.fixture
def perf_db():
    db = FakeSB()
    db.store["entity_performer_map"] = [{
        "tevo_performer_id": 100, "tevo_performer_name": "New York Yankees",
        "genre": None, "top_category_name": "Sports", "what_event_type": "sports",
        "espn_team_id": "nyy", "espn_league": "MLB",
    }]
    db.store["performer_metadata"] = [{"performer_id": 300, "name": "Metadata Only Band"}]
    db.store["events"] = [
        {"id": 1, "name": "Yankees vs Sox", "occurs_at_local": "2099-09-01T19:00:00-04:00",
         "venue_name": "Yankee Stadium", "venue_location": "Bronx", "primary_performer_id": 100,
         "primary_performer_name": "New York Yankees", "state": "active", "performer_ids": [100, 200]},
        {"id": 2, "name": "Old game", "occurs_at_local": "2000-01-01T19:00:00-04:00",
         "primary_performer_id": 100, "state": "past", "performer_ids": [100]},
        {"id": 3, "name": "Ignored", "occurs_at_local": "2099-09-02T19:00:00-04:00",
         "primary_performer_id": 100, "state": "ignored", "performer_ids": [100]},
        {"id": 4, "name": "Via array only", "occurs_at_local": "2099-10-01T19:00:00-04:00",
         "primary_performer_id": 999, "state": "active", "performer_ids": [100]},
    ]
    db.store["latest_event_metrics"] = [
        {"event_id": 1, "getin_price": 50, "retail_median": 120, "retail_min": 40,
         "retail_p90": 300, "tickets_count": 500, "owned_share": 0.1, "price_dispersion": 0.3},
    ]
    db.store["d0_perf_home_away"] = [{"performer_id": 100, "home_rev": 1000, "away_rev": 500}]
    db.store["d0_perf_price_stats"] = [{"performer_id": 100, "median": 120, "mean": 130}]
    db._rpc["get_event_movers_v2"] = [{"event_id": 1, "price_delta_pct": 5.2, "tix_delta": -10}]
    db._rpc["get_performer_prediction_markets"] = {"futures": [
        {"title": "Win World Series", "source": "kalshi", "last_price": 0.2}]}
    return db


def test_resolve_performer(perf_db):
    assert onb_performers.resolve_performer(perf_db, name="New York Yankees")["id"] == 100
    assert onb_performers.resolve_performer(perf_db, performer_id=100)["name"] == "New York Yankees"
    # id not in map → falls back to events
    assert onb_performers.resolve_performer(perf_db, performer_id=999)["id"] == 999
    # id not found anywhere → {id, name None}
    r = onb_performers.resolve_performer(perf_db, performer_id=555)
    assert r["id"] == 555 and r["name"] is None
    # name only in performer_metadata (not map)
    assert onb_performers.resolve_performer(perf_db, name="Metadata Only")["id"] == 300
    # name not found anywhere
    assert onb_performers.resolve_performer(perf_db, name="Nonexistent Act") is None
    # no args
    assert onb_performers.resolve_performer(perf_db) is None


def test_build_performer_digest(perf_db):
    name, text = onb_performers.build_performer_digest(perf_db, 100)
    assert name == "New York Yankees"
    assert "Upcoming events (2)" in text          # past + ignored excluded, array-only included
    assert "Yankee Stadium" in text
    assert "get-in $50" in text and "7d +5.2%" in text
    assert "Realized-sales snapshot" in text
    assert "Futures" in text and "World Series" in text


def test_build_performer_digest_sparse():
    db = FakeSB()  # no data for this performer
    name, text = onb_performers.build_performer_digest(db, 42, performer_name="Nobody")
    assert name == "Nobody"
    assert "No upcoming events" in text


def test_digest_realized_sales_partial():
    # home/away present, price-stats absent
    db1 = FakeSB()
    db1.store["d0_perf_home_away"] = [{"performer_id": 7, "home_rev": 10}]
    _, t1 = onb_performers.build_performer_digest(db1, 7, performer_name="A")
    assert "Home/away" in t1 and "Price stats" not in t1
    # price-stats present, home/away absent
    db2 = FakeSB()
    db2.store["d0_perf_price_stats"] = [{"performer_id": 8, "median": 5}]
    _, t2 = onb_performers.build_performer_digest(db2, 8, performer_name="B")
    assert "Price stats" in t2 and "Home/away" not in t2


def test_performer_helpers():
    assert onb_performers._fmt_price(50) == "$50"
    assert onb_performers._fmt_price("bad") == "n/a"
    assert onb_performers._safe(lambda: 1 / 0, "fallback") == "fallback"
    # _is_upcoming: tz-aware future kept, past dropped, naive attached-UTC, unparseable kept
    future = "2099-01-01T12:00:00-05:00"
    past = "2000-01-01T12:00:00-05:00"
    now = _dt.datetime.now(_dt.timezone.utc)
    assert onb_performers._is_upcoming(future, now) is True
    assert onb_performers._is_upcoming(past, now) is False
    assert onb_performers._is_upcoming("2099-01-01T12:00:00", now) is True  # naive → UTC
    assert onb_performers._is_upcoming("not-a-date", now) is True           # unparseable → keep
    assert onb_performers._is_upcoming(None, now) is False


def test_digest_kv_allow_deny():
    # allowed aggregate columns emitted; sensitive/unknown columns dropped
    row = {"performer_id": 1, "home_rev": 100, "owned_margin": 42,
           "cost_basis": 9, "internal_flag": "x", "median_price": 50}
    out = onb_performers._digest_kv(row)
    assert "home_rev=100" in out and "median_price=50" in out
    assert "margin" not in out and "cost_basis" not in out and "internal_flag" not in out


def test_extract_performer(perf_db, monkeypatch):
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._extract_performer({"performer_id": 100}, None)  # no db
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._extract_performer({}, perf_db)  # no performer_id
    text, title = onb_ingest._extract_performer({"performer_id": 100}, perf_db)
    assert title == "New York Yankees" and text
    # resolve by name (default UI path)
    text2, title2 = onb_ingest._extract_performer({"performer_name": "New York Yankees"}, perf_db)
    assert title2 == "New York Yankees" and text2
    # name that resolves to nothing → IngestError
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._extract_performer({"performer_name": "Nonexistent Act"}, perf_db)
    # empty digest → IngestError
    monkeypatch.setattr(onb_performers, "build_performer_digest", lambda *a, **k: ("N", ""))
    with pytest.raises(onb_ingest.IngestError):
        onb_ingest._extract_performer({"performer_id": 100}, perf_db)


def test_performer_routes(monkeypatch, perf_db, stub_providers):
    monkeypatch.setattr(app_module, "require_sb", lambda: perf_db)
    # deterministically exercise the Wikipedia-disabled path (the flag is read at
    # config import, so env import-order can't be relied on across the full suite)
    monkeypatch.setattr(onb_config, "ONB_WIKI_SOURCES", False)
    c = TestClient(app_module.app)
    # resolve
    assert c.post("/api/notebook/performers/resolve", json={"name": "New York Yankees"}).json()["id"] == 100
    assert c.post("/api/notebook/performers/resolve", json={"name": "Nope Act"}).status_code == 404
    # one-call performer notebook — background ingest builds the digest
    r = c.post("/api/notebook/performers/notebook", json={"name": "New York Yankees"})
    assert r.status_code == 200
    body = r.json()
    assert body["performer"]["id"] == 100
    sid = body["source"]["id"]
    assert c.get(f"/api/notebook/sources/{sid}/status").json()["status"] == "done"
    assert c.post("/api/notebook/performers/notebook", json={"name": "Nope"}).status_code == 404
    # direct performer source on an existing notebook (asset builder branch)
    nid = body["notebook"]["id"]
    assert c.post(f"/api/notebook/notebooks/{nid}/sources", json={"kind": "performer"}).status_code == 400
    assert c.post(f"/api/notebook/notebooks/{nid}/sources",
                  json={"kind": "performer", "performer_id": 100}).status_code == 200


# ============================================================ wikipedia enrich
def test_wikipedia_resolve_article_url(monkeypatch):
    # empty name → None (no API call)
    assert onb_wikipedia.resolve_article_url("  ") is None
    # opensearch success → first url
    monkeypatch.setattr(onb_wikipedia, "_api",
                        lambda p: ["NYY", ["New York Yankees"], [""],
                                   ["https://en.wikipedia.org/wiki/New_York_Yankees"]])
    assert onb_wikipedia.resolve_article_url("Yankees").endswith("New_York_Yankees")
    # opensearch returns no urls → None
    monkeypatch.setattr(onb_wikipedia, "_api", lambda p: ["x", [], [], []])
    assert onb_wikipedia.resolve_article_url("x") is None
    # malformed (not a 4-tuple) → None
    monkeypatch.setattr(onb_wikipedia, "_api", lambda p: {"weird": 1})
    assert onb_wikipedia.resolve_article_url("x") is None
    # API raises → None
    def _boom(_p):
        raise RuntimeError("net")
    monkeypatch.setattr(onb_wikipedia, "_api", _boom)
    assert onb_wikipedia.resolve_article_url("x") is None


def test_wikipedia_api_real_body(monkeypatch):
    """Exercise the real _api body (requests.get + raise_for_status + json)."""
    import requests
    captured = {}

    class _Resp:
        def raise_for_status(self):
            captured["raised"] = True
        def json(self):
            return ["ok"]
    monkeypatch.setattr(requests, "get", lambda url, **k: (captured.update(url=url, kw=k), _Resp())[1])
    assert onb_wikipedia._api({"action": "opensearch", "search": "x"}) == ["ok"]
    assert captured["url"] == onb_wikipedia.WIKI_API
    assert captured["kw"]["params"]["format"] == "json"


def test_wikipedia_resolve_season_urls(monkeypatch):
    def _season_hits(titles):
        return {"query": {"search": [{"title": t} for t in titles]}}

    # year-keyed responses: 2026 has a matching season page, 2025 a different one
    responses = {
        2026: _season_hits(["Alexander Hamilton", "2026 New York Yankees season"]),  # 1st skipped (no 'season')
        2025: _season_hits(["2025 New York Yankees season"]),
    }
    def _api(p):
        y = int(str(p["srsearch"]).split()[0])
        return responses[y]
    monkeypatch.setattr(onb_wikipedia, "_api", _api)
    urls = onb_wikipedia.resolve_season_urls("New York Yankees", [2026, 2025], max_urls=2)
    assert len(urls) == 2 and all("season" in u for u in urls)

    # max_urls cap short-circuits the 2nd year (covers the len>=max break)
    urls1 = onb_wikipedia.resolve_season_urls("New York Yankees", [2026, 2025], max_urls=1)
    assert len(urls1) == 1

    # dedup: both years resolve to the same title → one url
    monkeypatch.setattr(onb_wikipedia, "_api",
                        lambda p: _season_hits(["2026 New York Yankees season"]))
    assert len(onb_wikipedia.resolve_season_urls("New York Yankees", [2026, 2025], max_urls=2)) == 1

    # API error on a year → continue (no urls); non-dict payload → no hits
    monkeypatch.setattr(onb_wikipedia, "_api",
                        lambda p: (_ for _ in ()).throw(RuntimeError("net")))
    assert onb_wikipedia.resolve_season_urls("X", [2026], max_urls=2) == []
    monkeypatch.setattr(onb_wikipedia, "_api", lambda p: ["not", "a", "dict"])
    assert onb_wikipedia.resolve_season_urls("X", [2026], max_urls=2) == []

    # empty name → token empty → 'not token' branch still matches a 'season' title
    monkeypatch.setattr(onb_wikipedia, "_api", lambda p: _season_hits(["Some season page"]))
    assert onb_wikipedia.resolve_season_urls("", [2026], max_urls=1) == [
        "https://en.wikipedia.org/wiki/Some_season_page"]


def test_performer_wikipedia_urls(perf_db, monkeypatch):
    monkeypatch.setattr(onb_wikipedia, "resolve_article_url",
                        lambda n: f"https://en.wikipedia.org/wiki/{n.replace(' ', '_')}")
    monkeypatch.setattr(onb_wikipedia, "resolve_season_urls",
                        lambda n, years, **k: ["https://en.wikipedia.org/wiki/2026_New_York_Yankees_season"])
    # no name → []
    assert onb_performers.performer_wikipedia_urls(perf_db, 100, "") == []
    # sports (espn_league=MLB) → main article + season page
    urls = onb_performers.performer_wikipedia_urls(perf_db, 100, "New York Yankees")
    assert any("New_York_Yankees" in u and "season" not in u for u in urls)
    assert any("season" in u for u in urls)
    # sports with no main article resolvable → season page only (covers `if main` False)
    monkeypatch.setattr(onb_wikipedia, "resolve_article_url", lambda n: None)
    only_season = onb_performers.performer_wikipedia_urls(perf_db, 100, "New York Yankees")
    assert only_season and all("season" in u for u in only_season)
    # a season url that duplicates the main article is deduped (covers `u not in urls` False)
    dup = "https://en.wikipedia.org/wiki/New_York_Yankees"
    monkeypatch.setattr(onb_wikipedia, "resolve_article_url", lambda n: dup)
    monkeypatch.setattr(onb_wikipedia, "resolve_season_urls", lambda n, years, **k: [dup])
    assert onb_performers.performer_wikipedia_urls(perf_db, 100, "New York Yankees") == [dup]


def test_performer_wikipedia_urls_broadway_and_other(monkeypatch):
    db = FakeSB()
    db.store["entity_performer_map"] = [
        {"tevo_performer_id": 200, "tevo_performer_name": "Hamilton",
         "espn_league": None, "top_category_name": "Theater", "what_event_type": "theater", "genre": None},
        {"tevo_performer_id": 300, "tevo_performer_name": "Some Band",
         "espn_league": None, "top_category_name": "Concerts", "what_event_type": "concert", "genre": "Rock"},
    ]
    # Broadway → disambiguated "(musical)" article, no season pages
    seen = []
    def _resolve(n):
        seen.append(n)
        return "https://en.wikipedia.org/wiki/Hamilton_(musical)" if "(musical)" in n else None
    monkeypatch.setattr(onb_wikipedia, "resolve_article_url", _resolve)
    urls = onb_performers.performer_wikipedia_urls(db, 200, "Hamilton")
    assert urls == ["https://en.wikipedia.org/wiki/Hamilton_(musical)"]
    assert any("(musical)" in s for s in seen)
    # non-sports / non-broadway → nothing attached
    assert onb_performers.performer_wikipedia_urls(db, 300, "Some Band") == []


def test_add_wikipedia_sources(fake, monkeypatch):
    nb = repo.create_notebook(fake, name="nb")
    # two urls, ingest stubbed (no network)
    monkeypatch.setattr(onb_performers, "performer_wikipedia_urls",
                        lambda db, pid, name: ["https://en.wikipedia.org/wiki/A",
                                               "https://en.wikipedia.org/wiki/B"])
    ingested = []
    monkeypatch.setattr(onb_ingest, "ingest_source",
                        lambda db, sid, **k: ingested.append(sid))
    added = onb_performers.add_wikipedia_sources(fake, nb["id"], 100, "New York Yankees")
    assert len(added) == 2 and len(ingested) == 2
    assert len(repo.list_sources(fake, notebook_id=nb["id"])) == 2

    # resolution raises → returns [] (best-effort)
    monkeypatch.setattr(onb_performers, "performer_wikipedia_urls",
                        lambda *a, **k: (_ for _ in ()).throw(RuntimeError("net")))
    assert onb_performers.add_wikipedia_sources(fake, nb["id"], 100, "X") == []

    # one url fails to ingest → the other still succeeds (covers inner except)
    monkeypatch.setattr(onb_performers, "performer_wikipedia_urls",
                        lambda db, pid, name: ["https://en.wikipedia.org/wiki/C",
                                               "https://en.wikipedia.org/wiki/D"])
    calls = {"n": 0}
    def _flaky(db, sid, **k):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("fetch failed")
    monkeypatch.setattr(onb_ingest, "ingest_source", _flaky)
    assert len(onb_performers.add_wikipedia_sources(fake, nb["id"], 100, "X")) == 1


def test_performer_notebook_triggers_wikipedia(monkeypatch, perf_db, stub_providers):
    monkeypatch.setattr(app_module, "require_sb", lambda: perf_db)
    monkeypatch.setattr(onb_config, "ONB_WIKI_SOURCES", True)
    seen = {}
    monkeypatch.setattr(onb_performers, "add_wikipedia_sources",
                        lambda db, nid, pid, name: seen.update(nid=nid, pid=pid, name=name))
    c = TestClient(app_module.app)
    r = c.post("/api/notebook/performers/notebook", json={"name": "New York Yankees"})
    assert r.status_code == 200
    assert seen["pid"] == 100 and seen["name"] == "New York Yankees"


def test_prompts_helpers():
    assert onb_prompts.transformation_user("text", "do it")
    assert onb_prompts.podcast_outline_user("b", "c", 3)
    assert onb_prompts.podcast_transcript_user("[]", [], "b")
    assert onb_prompts.podcast_transcript_user("[]", ["Alex"], "b")
    assert onb_prompts.ask_synthesize_user("q", ["p1", "p2"])
    assert onb_prompts.ask_decompose_user("q")
    assert "no sources" not in onb_prompts.chat_system_with_context("ctx here")
