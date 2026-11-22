"""tm_feed_client.py: the download of one Ticketmaster Discovery Feed file and the reading of its
rows (operator 2026-11-22: "Redesign tm polling using this new data so we don't waste tokens")."""
from __future__ import annotations

import csv
import gzip
import hashlib
import io
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

import tm_feed_client as c  # noqa: E402

URI = ("https://s3.amazonaws.com/prd141.dcfd.prod1.us-east-1.tmaws-feeds/20261122/"
       "EVENTS_RAW-US-6e37fcc4-8349-4f1d-9c8f-2b8395102dcb-2026-11-22_012211.csv.gz")


class _Resp:
    def __init__(self, status=200, chunks=(b"abc", b"def")):
        self.status_code, self.chunks = status, chunks

    def __enter__(self):
        return self

    def __exit__(self, *_a):
        return False

    def iter_content(self, _size):
        yield from self.chunks


class _Session:
    def __init__(self, resp):
        self.resp, self.calls = resp, []

    def get(self, uri, **kw):
        self.calls.append((uri, kw))
        return self.resp


def test_download_writes_the_file_and_checks_the_checksum(tmp_path):
    dest = tmp_path / "f.gz"
    http = _Session(_Resp())
    assert c.download(URI, str(dest), hashlib.md5(b"abcdef").hexdigest().upper(), session=http) == 6
    assert dest.read_bytes() == b"abcdef"
    uri, kw = http.calls[0]
    assert uri == URI and kw["stream"] is True and kw["allow_redirects"] is False     # a redirect is not followed
    assert c.download(URI, str(dest), None, session=_Session(_Resp())) == 6             # no checksum given
    with pytest.raises(c.TmFeedError, match="checksum"):
        c.download(URI, str(dest), "0" * 32, session=_Session(_Resp()))


def test_download_refuses_any_other_address_and_a_bad_answer(tmp_path, monkeypatch):
    dest = str(tmp_path / "f.gz")
    for bad in ("https://evil.example/x.tmaws-feeds/20261122/EVENTS_RAW-US-6e37fcc4-8349-4f1d-9c8f-2b8395102dcb-2026-11-22_012211.csv.gz",
                URI.replace("EVENTS_RAW-US", "EVENTS_RAW-GB"), URI.replace("https://", "http://"), URI + "?x=1", "", None):
        http = _Session(_Resp())
        with pytest.raises(c.TmFeedError, match="not a Ticketmaster feed file address"):
            c.download(bad, dest, session=http)
        assert http.calls == []                                   # nothing was requested
    with pytest.raises(c.TmFeedError, match="http 403"):
        c.download(URI, dest, session=_Session(_Resp(status=403)))
    monkeypatch.setattr(c, "MAX_BYTES", 4)
    with pytest.raises(c.TmFeedError, match="larger than expected"):
        c.download(URI, dest, session=_Session(_Resp()))


def test_download_uses_requests_when_no_session_is_given(tmp_path, monkeypatch):
    seen = []

    def _get(uri, **kw):
        seen.append(uri)
        return _Resp(chunks=(b"x",))
    monkeypatch.setattr(c.requests, "get", _get)
    assert c.download(URI, str(tmp_path / "f.gz")) == 1 and seen == [URI]


def _feed(tmp_path, head, records):
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(head)
    for rec in records:
        w.writerow(rec)
    path = tmp_path / "feed.csv.gz"
    with gzip.open(path, "wt", encoding="utf-8", newline="") as f:
        f.write(buf.getvalue())
    return str(path)


def test_rows_keeps_our_columns_under_short_keys(tmp_path):
    head = list(dict.fromkeys(c.COLUMNS.values())) + ["PRESALE_NAME", "EVENT_IMAGE_URL", "PRESALE_NAME"]
    pos = {name: i for i, name in enumerate(head)}

    def rec(**kw):
        out = [""] * len(head)
        for k, v in kw.items():
            out[pos[k]] = v
        return out
    path = _feed(tmp_path, head, [
        rec(EVENT_ID="vv1", EVENT_NAME="Cavaliers vs. HEAT", EVENT_STATUS="onsale", SOURCE="ticketmaster",
            OFFICIAL_SELLER="true", TRANSACTABLE="false", HOT_EVENT="", EVENT_IMAGE_URL="https://img/x.jpg",
            ATTRACTION_NAME="Cavaliers|HEAT", EVENT_START_LOCAL_DATE="2026-11-29", EVENT_START_LOCAL_TIME="18:00"),
        rec(EVENT_ID="", EVENT_NAME="no id"),                     # left out
        ["short", "row"],                                         # left out: not the header's width
        rec(EVENT_ID="Z7r9j2", SOURCE="tmr", OFFICIAL_SELLER="FALSE"),
    ])
    got = list(c.rows(path))
    assert [r["id"] for r in got] == ["vv1", "Z7r9j2"]
    first = got[0]
    assert set(first) == set(c.COLUMNS) and "EVENT_IMAGE_URL" not in c.COLUMNS.values()    # images are not read
    assert (first["name"], first["st"], first["src"], first["ld"], first["lt"]) == ("Cavaliers vs. HEAT", "onsale", "ticketmaster", "2026-11-29", "18:00")
    assert (first["off"], first["tx"], first["hot"]) == (True, False, None) and first["aname"] == "Cavaliers|HEAT"
    assert got[1]["off"] is False and got[1]["src"] == "tmr"


def test_rows_refuses_a_file_without_our_columns(tmp_path):
    with pytest.raises(c.TmFeedError, match="missing columns: .*EVENT_ID"):
        list(c.rows(_feed(tmp_path, ["EVENT_NAME"], [["x"]])))
    with pytest.raises(c.TmFeedError, match="missing columns"):
        list(c.rows(_feed(tmp_path, [], [])))                     # an empty file
