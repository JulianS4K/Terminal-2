"""routers/feed_xmap.py: the same event's id on every marketplace, added to each event feed
(operator 2026-11-22: "include the cross maps in all event mapping you push out, marketplace id")."""
from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from routers import feed_xmap  # noqa: E402


class _Data:
    def __init__(self, data):
        self.data = data

    def execute(self):
        return self


class _Fails:
    def execute(self):
        raise RuntimeError("canceling statement due to statement timeout")


class FakeDB:
    def __init__(self, data=None, fail=0):
        self.data, self.calls, self.fail = data, [], fail      # fail: how many calls fail first

    def rpc(self, name, args):
        self.calls.append((name, args))
        if self.fail > 0:
            self.fail -= 1
            return _Fails()
        if callable(self.data):
            return _Data(self.data(args["p_ids"]))
        return _Data(self.data)


def test_columns_leave_out_the_ones_a_feed_already_serves():
    assert feed_xmap.columns() == feed_xmap.ALL and len(feed_xmap.ALL) == 9
    assert "axs_event_id" not in feed_xmap.columns("axs_event_id")
    assert feed_xmap.columns("ticketmaster_event_id", "xmap_tevo_event_id") == feed_xmap.ALL[2:]


def test_add_reads_one_page_in_one_call_and_never_changes_the_rows_given():
    rows = [{"axs_event_id": 42, "name": "A"}, {"axs_event_id": 7, "name": "B"}, {"axs_event_id": 42, "name": "A again"},
            {"axs_event_id": None, "name": "no id"}]
    db = FakeDB([{"source_id": "42", "xmap_tevo_event_id": 3000001, "seatgeek_event_id": 18000001, "vivid_event_id": None}])
    cols = ("xmap_tevo_event_id", "seatgeek_event_id", "vivid_event_id")
    out = feed_xmap.add(db, rows, "axs", "axs_event_id", cols)
    assert db.calls == [("feed_market_ids", {"p_source": "axs", "p_ids": ["42", "7"]})]    # each id once, as text
    assert out[0] == {"axs_event_id": 42, "name": "A", "xmap_tevo_event_id": 3000001, "seatgeek_event_id": 18000001,
                      "vivid_event_id": None}
    assert out[2]["xmap_tevo_event_id"] == 3000001                         # the same event twice on a page
    assert out[1] == {"axs_event_id": 7, "name": "B", **dict.fromkeys(cols)}      # no pairing held
    assert out[3] == {"axs_event_id": None, "name": "no id", **dict.fromkeys(cols)}
    assert rows[0] == {"axs_event_id": 42, "name": "A"}                    # the caller's rows are not changed


def test_add_asks_nothing_for_an_empty_page_or_a_page_without_ids():
    db = FakeDB()
    assert feed_xmap.add(db, [], "tevo", "tevo_event_id", ("axs_event_id",)) == []
    assert feed_xmap.add(db, [{"tevo_event_id": None}], "tevo", "tevo_event_id", ("axs_event_id",)) == [
        {"tevo_event_id": None, "axs_event_id": None}]
    assert db.calls == []
    # an answer with no rows is not an error
    assert feed_xmap.add(FakeDB(None), [{"tevo_event_id": 5}], "tevo", "tevo_event_id", ("axs_event_id",)) == [
        {"tevo_event_id": 5, "axs_event_id": None}]


def test_a_big_page_is_asked_in_chunks_and_a_failed_chunk_once_more():
    """Measured on prod 2026-11-22: one call for 5,000 ids ran past the 8-second limit on a first read."""
    import pytest

    rows = [{"axs_event_id": n} for n in range(1, 1202)]                 # 1,201 ids: three calls
    db = FakeDB(lambda ids: [{"source_id": i, "vivid_event_id": int(i) + 7000000} for i in ids])
    out = feed_xmap.add(db, rows, "axs", "axs_event_id", ("vivid_event_id",))
    assert [len(a["p_ids"]) for _, a in db.calls] == [500, 500, 201] and feed_xmap.CHUNK == 500
    assert all(r["vivid_event_id"] == r["axs_event_id"] + 7000000 for r in out) and len(out) == 1201
    # the first read of a chunk fails: it is sent once more, and the page is whole
    db = FakeDB([{"source_id": "5", "vivid_event_id": 9}], fail=1)
    assert feed_xmap.add(db, [{"axs_event_id": 5}], "axs", "axs_event_id", ("vivid_event_id",)) == [
        {"axs_event_id": 5, "vivid_event_id": 9}]
    assert len(db.calls) == 2 and db.calls[0] == db.calls[1]
    # it fails twice: the error reaches the caller, which answers 502; no third try
    db = FakeDB(fail=2)
    with pytest.raises(RuntimeError):
        feed_xmap.add(db, [{"axs_event_id": 5}], "axs", "axs_event_id", ("vivid_event_id",))
    assert len(db.calls) == 2
