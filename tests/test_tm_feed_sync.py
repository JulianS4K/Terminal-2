"""core/tm_feed_sync.py: one run of the Ticketmaster Discovery Feed load."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from core import tm_feed_sync as s  # noqa: E402

US = {"country": "US", "file_at": "2026-11-22T01:22:12Z", "uri": "https://s3/us.csv.gz", "md5": "abc", "num_events": 5}
CA = {"country": "CA", "file_at": "2026-11-22T01:11:24Z", "uri": "https://s3/ca.csv.gz", "md5": None, "num_events": 1}


class _Client:
    def __init__(self, counts, fail_on=None):
        self.counts, self.fail_on, self.downloads, self.paths = counts, fail_on, [], []

    def download(self, uri, path, md5):
        self.downloads.append((uri, md5))
        self.paths.append(path)
        Path(path).write_bytes(b"gz")
        return 2

    def rows(self, path):
        country = "US" if "US" in Path(path).name else "CA"
        if country == self.fail_on:
            raise RuntimeError("bad file")
        yield from ({"id": f"{country}{i}"} for i in range(self.counts[country]))


class _Rpc:
    def __init__(self, plan):
        self.plan, self.calls = plan, []

    def __call__(self, name, params):
        self.calls.append((name, params))
        if name == "tm_feed_check":
            return self.plan
        if name == "tm_feed_loaded":
            return {"ok": True, "seen": params["p_rows_sent"]}
        return None


def test_a_run_with_no_new_file_is_idle(tmp_path):
    rpc = _Rpc({"files": [], "skipped": "a file is being loaded"})
    client = _Client({})
    assert s.run(rpc, client, str(tmp_path)) == {"action": "idle", "skipped": "a file is being loaded"}
    assert s.run(_Rpc(None), client, str(tmp_path)) == {"action": "idle", "skipped": None}
    assert client.downloads == [] and [c[0] for c in rpc.calls] == ["tm_feed_check"]


def test_a_run_loads_each_leased_file_in_batches_and_removes_it(tmp_path, monkeypatch):
    monkeypatch.setattr(s, "BATCH", 2)
    rpc, client = _Rpc({"files": [US, CA]}), _Client({"US": 5, "CA": 2})
    out = s.run(rpc, client, str(tmp_path))
    assert out == {"action": "loaded", "files": [
        {"country": "US", "file_at": US["file_at"], "bytes": 2, "rows": 5, "ok": True, "seen": 5},
        {"country": "CA", "file_at": CA["file_at"], "bytes": 2, "rows": 2, "ok": True, "seen": 2}]}
    assert client.downloads == [(US["uri"], "abc"), (CA["uri"], None)]
    loads = [p for n, p in rpc.calls if n == "tm_feed_load"]
    assert [len(p["p_rows"]) for p in loads] == [2, 2, 1, 2]                # 5 rows in twos, then CA's exact batch
    assert {(p["p_country"], p["p_file_at"]) for p in loads} == {("US", US["file_at"]), ("CA", CA["file_at"])}
    assert [p for n, p in rpc.calls if n == "tm_feed_loaded"] == [
        {"p_country": "US", "p_file_at": US["file_at"], "p_rows_sent": 5},
        {"p_country": "CA", "p_file_at": CA["file_at"], "p_rows_sent": 2}]
    assert not any(Path(p).exists() for p in client.paths)                   # the downloads are gone


def test_a_failed_file_is_removed_and_the_error_is_raised(tmp_path):
    rpc, client = _Rpc({"files": [US]}), _Client({"US": 5}, fail_on="US")
    with pytest.raises(RuntimeError, match="bad file"):
        s.run(rpc, client, str(tmp_path))
    assert not Path(client.paths[0]).exists()
    assert not any(n == "tm_feed_loaded" for n, _ in rpc.calls)              # never reported as loaded


def test_a_download_that_never_wrote_a_file_leaves_nothing_to_remove(tmp_path):
    class _NoFile(_Client):
        def download(self, uri, path, md5):
            self.paths.append(path)
            raise RuntimeError("http 403")
    rpc, client = _Rpc({"files": [US, CA]}), _NoFile({})
    with pytest.raises(RuntimeError, match="http 403"):
        s.run(rpc, client, str(tmp_path))
    assert len(client.paths) == 1 and not Path(client.paths[0]).exists()     # stopped at the first file
