"""RULE 2 enforcement tests.

Asserts the runtime read-only guards in each external-API client are wired
correctly and cannot be silently removed without breaking these tests.

The contract: any non-GET method against TEvo or SeatGeek hosts MUST raise
before a network request is made. This test never makes a real HTTP call.

Run as part of CI. Pair with `python scripts/check_readonly.py` for static
analysis on top of these runtime assertions.
"""
from __future__ import annotations

import importlib
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest


# ---------- evo_client ----------

def test_evo_assert_readonly_raises_on_post():
    from evo_client import _assert_readonly_method, EvoReadOnlyError
    with pytest.raises(EvoReadOnlyError) as exc:
        _assert_readonly_method("POST")
    assert "READ-ONLY violation" in str(exc.value)
    assert "RULE 2" in str(exc.value)


def test_evo_assert_readonly_raises_on_put_patch_delete():
    from evo_client import _assert_readonly_method, EvoReadOnlyError
    for method in ("PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"):
        with pytest.raises(EvoReadOnlyError):
            _assert_readonly_method(method)


def test_evo_assert_readonly_allows_get():
    from evo_client import _assert_readonly_method
    # Both upper- and lower-case variants are accepted — no exception.
    _assert_readonly_method("GET")
    _assert_readonly_method("get")


def test_evo_allowlist_constant_is_get_only():
    from evo_client import ALLOWED_HTTP_METHODS
    assert ALLOWED_HTTP_METHODS == frozenset({"GET"})


# ---------- seatgeek_client ----------

def test_sg_assert_readonly_raises_on_post():
    from seatgeek_client import _assert_readonly_method, SeatGeekError
    with pytest.raises(SeatGeekError) as exc:
        _assert_readonly_method("POST")
    assert "READ-ONLY violation" in str(exc.value)
    assert "RULE 2" in str(exc.value)


def test_sg_assert_readonly_raises_on_put_patch_delete():
    from seatgeek_client import _assert_readonly_method, SeatGeekError
    for method in ("PUT", "PATCH", "DELETE"):
        with pytest.raises(SeatGeekError):
            _assert_readonly_method(method)


def test_sg_assert_readonly_allows_get():
    from seatgeek_client import _assert_readonly_method
    _assert_readonly_method("GET")
    _assert_readonly_method("get")


def test_sg_allowlist_constant_is_get_only():
    from seatgeek_client import ALLOWED_HTTP_METHODS
    assert ALLOWED_HTTP_METHODS == frozenset({"GET"})


# ---------- tickpick_client ----------

def test_tickpick_assert_readonly_raises_on_post():
    from tickpick_client import _assert_readonly_method, TickPickReadOnlyError
    with pytest.raises(TickPickReadOnlyError) as exc:
        _assert_readonly_method("POST")
    assert "READ-ONLY violation" in str(exc.value)


def test_tickpick_assert_readonly_raises_on_put_patch_delete():
    from tickpick_client import _assert_readonly_method, TickPickReadOnlyError
    for method in ("PUT", "PATCH", "DELETE"):
        with pytest.raises(TickPickReadOnlyError):
            _assert_readonly_method(method)


def test_tickpick_assert_readonly_allows_get():
    from tickpick_client import _assert_readonly_method
    _assert_readonly_method("GET")
    _assert_readonly_method("get")


def test_tickpick_allowlist_constant_is_get_only():
    from tickpick_client import ALLOWED_HTTP_METHODS
    assert ALLOWED_HTTP_METHODS == frozenset({"GET"})


# ---------- vivid_client ----------

def test_vivid_assert_readonly_raises_on_post():
    from vivid_client import _assert_readonly_method, VividReadOnlyError
    with pytest.raises(VividReadOnlyError) as exc:
        _assert_readonly_method("POST")
    assert "READ-ONLY violation" in str(exc.value)


def test_vivid_assert_readonly_raises_on_put_patch_delete():
    from vivid_client import _assert_readonly_method, VividReadOnlyError
    for method in ("PUT", "PATCH", "DELETE"):
        with pytest.raises(VividReadOnlyError):
            _assert_readonly_method(method)


def test_vivid_assert_readonly_allows_get():
    from vivid_client import _assert_readonly_method
    _assert_readonly_method("GET")
    _assert_readonly_method("get")


def test_vivid_allowlist_constant_is_get_only():
    from vivid_client import ALLOWED_HTTP_METHODS
    assert ALLOWED_HTTP_METHODS == frozenset({"GET"})


# ---------- axs_client ----------

def test_axs_assert_readonly_raises_on_post():
    from axs_client import _assert_readonly_method, AXSReadOnlyError
    with pytest.raises(AXSReadOnlyError) as exc:
        _assert_readonly_method("POST")
    assert "READ-ONLY violation" in str(exc.value)
    assert "RULE 2" in str(exc.value)


def test_axs_assert_readonly_raises_on_put_patch_delete():
    from axs_client import _assert_readonly_method, AXSReadOnlyError
    for method in ("PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"):
        with pytest.raises(AXSReadOnlyError):
            _assert_readonly_method(method)


def test_axs_assert_readonly_allows_get():
    from axs_client import _assert_readonly_method
    _assert_readonly_method("GET")
    _assert_readonly_method("get")


def test_axs_allowlist_constant_is_get_only():
    from axs_client import ALLOWED_HTTP_METHODS
    assert ALLOWED_HTTP_METHODS == frozenset({"GET"})


def test_axs_venue_norm_matches_axs_venues_generated_column():
    # venue_norm must mirror axs_venues.axs_name_norm so the peg lookup is a
    # plain equality (lower -> strip leading 'the ' -> drop non-[a-z0-9]).
    from axs_client import venue_norm
    assert venue_norm("The HALL at Live!") == "hallatlive"
    assert venue_norm("Crypto.com Arena") == "cryptocomarena"
    assert venue_norm("Red Rocks Amphitheatre") == "redrocksamphitheatre"


# ---------- seatdata_client ----------
#
# SeatData is the one client with a sanctioned POST — and it is path-scoped:
# only /v0.4/events/event-request-add may ever receive it (CLAUDE.md §2).

def test_seatdata_assert_readonly_raises_on_put_patch_delete():
    from seatdata_client import _assert_readonly_method, SeatDataError
    for method in ("PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"):
        with pytest.raises(SeatDataError):
            _assert_readonly_method(method)


def test_seatdata_assert_readonly_allows_get_any_path():
    from seatdata_client import _assert_readonly_method
    _assert_readonly_method("GET")
    _assert_readonly_method("get", "v1/events/search")


def test_seatdata_post_allowed_only_for_event_request_add():
    from seatdata_client import _assert_readonly_method
    # Sanctioned path passes regardless of leading-slash spelling.
    _assert_readonly_method("POST", "v0.4/events/event-request-add")
    _assert_readonly_method("POST", "/v0.4/events/event-request-add")


def test_seatdata_post_to_any_other_path_raises():
    from seatdata_client import _assert_readonly_method, SeatDataError
    for path in (
        "v0.1.1/listings/get",
        "v0.3/salesdata/get",
        "v9/orders",
        "v0.4/events/event-request-add/../../orders",
        "",
        None,
    ):
        with pytest.raises(SeatDataError) as exc:
            _assert_readonly_method("POST", path)
        assert "READ-ONLY violation" in str(exc.value)


def test_seatdata_allowlist_and_sanctioned_paths_constants():
    from seatdata_client import ALLOWED_HTTP_METHODS, SANCTIONED_POST_PATHS
    assert ALLOWED_HTTP_METHODS == frozenset({"GET", "POST"})
    assert SANCTIONED_POST_PATHS == frozenset({"v0.4/events/event-request-add"})


# ---------- gotickets_client ----------

def test_gotickets_assert_readonly_raises_on_post():
    from gotickets_client import _assert_readonly_method, GoTicketsReadOnlyError
    with pytest.raises(GoTicketsReadOnlyError) as exc:
        _assert_readonly_method("POST")
    assert "READ-ONLY violation" in str(exc.value)


def test_gotickets_assert_readonly_raises_on_put_patch_delete():
    from gotickets_client import _assert_readonly_method, GoTicketsReadOnlyError
    for method in ("PUT", "PATCH", "DELETE"):
        with pytest.raises(GoTicketsReadOnlyError):
            _assert_readonly_method(method)


def test_gotickets_assert_readonly_allows_get():
    from gotickets_client import _assert_readonly_method
    _assert_readonly_method("GET")
    _assert_readonly_method("get")


def test_gotickets_allowlist_constant_is_get_only():
    from gotickets_client import ALLOWED_HTTP_METHODS
    assert ALLOWED_HTTP_METHODS == frozenset({"GET"})


# ---------- ticketsdata_client ----------

def test_ticketsdata_assert_readonly_raises_on_post():
    from ticketsdata_client import _assert_readonly_method, TicketsDataReadOnlyError
    with pytest.raises(TicketsDataReadOnlyError) as exc:
        _assert_readonly_method("POST")
    assert "READ-ONLY violation" in str(exc.value)


def test_ticketsdata_assert_readonly_raises_on_put_patch_delete():
    from ticketsdata_client import _assert_readonly_method, TicketsDataReadOnlyError
    for method in ("PUT", "PATCH", "DELETE"):
        with pytest.raises(TicketsDataReadOnlyError):
            _assert_readonly_method(method)


def test_ticketsdata_assert_readonly_allows_get():
    from ticketsdata_client import _assert_readonly_method
    _assert_readonly_method("GET")
    _assert_readonly_method("get")


def test_ticketsdata_allowlist_constant_is_get_only():
    from ticketsdata_client import ALLOWED_HTTP_METHODS
    assert ALLOWED_HTTP_METHODS == frozenset({"GET"})


# ---------- broadway_client ----------

def test_broadway_assert_readonly_raises_on_post():
    from broadway_client import _assert_readonly_method, BroadwayError
    with pytest.raises(BroadwayError) as exc:
        _assert_readonly_method("POST")
    assert "READ-ONLY violation" in str(exc.value)


def test_broadway_assert_readonly_raises_on_put_patch_delete():
    from broadway_client import _assert_readonly_method, BroadwayError
    for method in ("PUT", "PATCH", "DELETE"):
        with pytest.raises(BroadwayError):
            _assert_readonly_method(method)


def test_broadway_assert_readonly_allows_get():
    from broadway_client import _assert_readonly_method
    _assert_readonly_method("GET")
    _assert_readonly_method("get")


def test_broadway_allowlist_constant_is_get_only():
    from broadway_client import ALLOWED_HTTP_METHODS
    assert ALLOWED_HTTP_METHODS == frozenset({"GET"})


# ---------- bandsintown_client ----------

def test_bandsintown_assert_readonly_raises_on_post():
    from bandsintown_client import _assert_readonly_method, BandsInTownReadOnlyError
    with pytest.raises(BandsInTownReadOnlyError) as exc:
        _assert_readonly_method("POST")
    assert "READ-ONLY violation" in str(exc.value)
    assert "RULE 2" in str(exc.value)


def test_bandsintown_assert_readonly_raises_on_put_patch_delete():
    from bandsintown_client import _assert_readonly_method, BandsInTownReadOnlyError
    for method in ("PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"):
        with pytest.raises(BandsInTownReadOnlyError):
            _assert_readonly_method(method)


def test_bandsintown_assert_readonly_allows_get():
    from bandsintown_client import _assert_readonly_method
    _assert_readonly_method("GET")
    _assert_readonly_method("get")


def test_bandsintown_allowlist_constant_is_get_only():
    from bandsintown_client import ALLOWED_HTTP_METHODS
    assert ALLOWED_HTTP_METHODS == frozenset({"GET"})


# ---------- s4kcs_client ----------

def test_s4kcs_assert_readonly_raises_on_post():
    from s4kcs_client import _assert_readonly_method, S4KCSReadOnlyError
    with pytest.raises(S4KCSReadOnlyError) as exc:
        _assert_readonly_method("POST")
    assert "READ-ONLY violation" in str(exc.value)
    assert "RULE 2" in str(exc.value)


def test_s4kcs_assert_readonly_raises_on_put_patch_delete():
    from s4kcs_client import _assert_readonly_method, S4KCSReadOnlyError
    for method in ("PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"):
        with pytest.raises(S4KCSReadOnlyError):
            _assert_readonly_method(method)


def test_s4kcs_assert_readonly_allows_get():
    from s4kcs_client import _assert_readonly_method
    _assert_readonly_method("GET")
    _assert_readonly_method("get")


def test_s4kcs_allowlist_constant_is_get_only():
    from s4kcs_client import ALLOWED_HTTP_METHODS
    assert ALLOWED_HTTP_METHODS == frozenset({"GET"})


# ---------- audit script catches synthetic violations ----------

REPO_ROOT = Path(__file__).resolve().parent.parent
CHECK_SCRIPT = REPO_ROOT / "scripts" / "check_readonly.py"


def _run_check() -> tuple[int, str]:
    """Run check_readonly.py against the current tree. Returns (rc, output)."""
    result = subprocess.run(
        [sys.executable, str(CHECK_SCRIPT)],
        capture_output=True, text=True, cwd=str(REPO_ROOT),
    )
    return result.returncode, result.stdout + result.stderr


def test_audit_script_passes_clean_tree():
    rc, out = _run_check()
    assert rc == 0, f"check_readonly.py failed on clean tree:\n{out}"
    assert "RULE 2 clean" in out


def test_audit_script_catches_python_post_to_tevo(tmp_path: Path, monkeypatch):
    """Synthesize a violating Python file inside the repo and confirm the
    audit script flags it. Cleans up after itself."""
    bad_file = REPO_ROOT / "_test_synthetic_violation.py"
    bad_file.write_text(
        "import requests\n"
        "# synthetic violation for tests/test_readonly_guards.py\n"
        "requests.post('https://api.ticketevolution.com/v9/orders', json={})\n",
        encoding="utf-8",
    )
    try:
        rc, out = _run_check()
        assert rc == 1, f"audit script should fail on synthetic violation:\n{out}"
        assert "_test_synthetic_violation.py" in out
        assert "api.ticketevolution.com" in out
    finally:
        bad_file.unlink(missing_ok=True)


def test_audit_script_catches_ts_post_to_seatgeek(tmp_path: Path):
    """Synthesize a violating edge function and confirm the script flags it."""
    bad_file = REPO_ROOT / "supabase" / "functions" / "_test_synthetic" / "index.ts"
    bad_file.parent.mkdir(parents=True, exist_ok=True)
    bad_file.write_text(
        '// synthetic violation\n'
        'const SG_HOST = "brokerdata.seatgeek.com";\n'
        'await fetch(`https://${SG_HOST}/listings`, { method: "POST" });\n',
        encoding="utf-8",
    )
    try:
        rc, out = _run_check()
        assert rc == 1, f"audit script should fail on TS violation:\n{out}"
        assert "_test_synthetic" in out
    finally:
        bad_file.unlink(missing_ok=True)
        bad_file.parent.rmdir()


def test_audit_script_catches_method_as_string_request(tmp_path: Path):
    """session.request('POST', ...) must be flagged — the pre-2026-06 scanner
    only matched requests.post(...) and missed the method-as-string spelling."""
    bad_file = REPO_ROOT / "_test_synthetic_request_violation.py"
    bad_file.write_text(
        "import requests\n"
        "# synthetic violation for tests/test_readonly_guards.py\n"
        "s = requests.Session()\n"
        "s.request('POST', 'https://seatdata.io/api/v9/orders', json={})\n",
        encoding="utf-8",
    )
    try:
        rc, out = _run_check()
        assert rc == 1, f"audit script should flag .request('POST', ...):\n{out}"
        assert "_test_synthetic_request_violation.py" in out
    finally:
        bad_file.unlink(missing_ok=True)


def test_audit_script_catches_non_fetch_ts_write(tmp_path: Path):
    """An axios/XHR-style write near a forbidden host must be flagged — the
    pre-2026-06 scanner skipped any method:'POST' without a fetch( nearby."""
    bad_file = REPO_ROOT / "supabase" / "functions" / "_test_synthetic_axios" / "index.ts"
    bad_file.parent.mkdir(parents=True, exist_ok=True)
    bad_file.write_text(
        '// synthetic violation\n'
        'await axios({ url: "https://api.tickpick.com/orders", method: "POST" });\n',
        encoding="utf-8",
    )
    try:
        rc, out = _run_check()
        assert rc == 1, f"audit script should flag non-fetch TS write:\n{out}"
        assert "_test_synthetic_axios" in out
    finally:
        bad_file.unlink(missing_ok=True)
        bad_file.parent.rmdir()


def test_audit_script_scans_inline_html_scripts(tmp_path: Path):
    """Inline <script> in .html files is scanned — previously a blind spot."""
    bad_file = REPO_ROOT / "_test_synthetic_inline.html"
    bad_file.write_text(
        "<script>\n"
        'fetch("https://brokers.vividseats.com/orders", { method: "POST" });\n'
        "</script>\n",
        encoding="utf-8",
    )
    try:
        rc, out = _run_check()
        assert rc == 1, f"audit script should flag inline HTML script write:\n{out}"
        assert "_test_synthetic_inline.html" in out
    finally:
        bad_file.unlink(missing_ok=True)


def test_audit_script_catches_removed_guard(tmp_path: Path):
    """If someone deletes the runtime guard from a client, the audit fails."""
    client_path = REPO_ROOT / "evo_client.py"
    original = client_path.read_text(encoding="utf-8")
    try:
        # Strip the guard tokens. Re-write a sanitized version that removes
        # ALLOWED_HTTP_METHODS / _assert_readonly_method.
        scrubbed = original.replace("_assert_readonly_method", "_disabled_guard")
        scrubbed = scrubbed.replace("ALLOWED_HTTP_METHODS", "_disabled_constant")
        client_path.write_text(scrubbed, encoding="utf-8")
        rc, out = _run_check()
        assert rc == 1, "audit should fail when guard is removed"
        assert "evo_client.py" in out
    finally:
        client_path.write_text(original, encoding="utf-8")


# ---------- evo_buy_client (operator authorization 2026-11-09: EVO buy + accept only) ----------

def test_evo_buy_client_is_registered_with_a_pinned_path_allowlist():
    chk = _load_check_module()
    assert chk.CLIENT_FILES["evo_buy_client.py"] == frozenset({"GET", "POST"})
    assert chk.SANCTIONED_WRITE_TOKENS["evo_buy_client.py"] in (REPO_ROOT / "evo_buy_client.py").read_text()


def test_evo_buy_guard_refuses_any_other_write():
    from evo_buy_client import _assert_readonly_method, EvoBuyError
    for method, path in (("POST", "/v9/orders/1/reject"), ("POST", "/v9/ticket_groups/1"),
                         ("POST", "/v9/tax_quotes/1"), ("PUT", "/v9/tax_quotes"),
                         ("PUT", "/v9/orders/1"), ("DELETE", "/v9/orders/1"), ("PATCH", "/v9/orders")):
        with pytest.raises(EvoBuyError):
            _assert_readonly_method(method, path)


def _load_check_module():
    spec = importlib.util.spec_from_file_location("check_readonly_under_test", CHECK_SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_audit_catches_a_widened_evo_write_allowlist(tmp_path: Path, monkeypatch):
    chk = _load_check_module()
    text = (REPO_ROOT / "evo_buy_client.py").read_text()
    for name in chk.CLIENT_FILES:
        src = REPO_ROOT / name
        (tmp_path / name).write_text(src.read_text())
    widened = text.replace(r'r"^/v9/tax_quotes$")', r'r"^/v9/tax_quotes$", r"^/v9/orders/\d+/reject$")')
    assert widened != text
    (tmp_path / "evo_buy_client.py").write_text(widened)
    monkeypatch.setattr(chk, "ROOT", tmp_path)
    out = chk.check_guard_tokens()
    assert any("evo_buy_client.py" in v and "EVO_WRITE_PATHS" in v for v in out)


def test_audit_catches_pgsql_http_post_to_a_broker(tmp_path: Path, monkeypatch):
    chk = _load_check_module()
    mig = tmp_path / "supabase" / "migrations"
    mig.mkdir(parents=True)
    (mig / "1_bad.sql").write_text(
        "SELECT extensions.http(('POST', 'https://api.ticketevolution.com/v9/orders', NULL, NULL, '{}'));\n")
    (mig / "2_bad.sql").write_text("SELECT extensions.http_post('https://gotickets.com/rest/pro/api/orders', '{}');\n")
    (mig / "3_ok.sql").write_text("SELECT extensions.http(('POST', 'https://api.resend.com/emails', NULL, NULL, '{}'));\n")
    monkeypatch.setattr(chk, "ROOT", tmp_path)
    out = chk.check_plpgsql_writes()
    assert len(out) == 2 and any("1_bad.sql" in v for v in out) and any("2_bad.sql" in v for v in out)


def test_sale_accept_client_registered_with_pinned_writes():
    chk = _load_check_module()
    assert chk.CLIENT_FILES["sale_accept_client.py"] == frozenset({"GET", "PATCH", "POST"})
    assert chk.SANCTIONED_WRITE_TOKENS["sale_accept_client.py"] in (REPO_ROOT / "sale_accept_client.py").read_text()


def test_gotickets_sub_client_registered_with_its_one_pinned_write():
    chk = _load_check_module()
    assert chk.CLIENT_FILES["gotickets_sub_client.py"] == frozenset({"GET", "POST"})
    assert chk.SANCTIONED_WRITE_TOKENS["gotickets_sub_client.py"] in (REPO_ROOT / "gotickets_sub_client.py").read_text()
    from gotickets_sub_client import GT_SUB_WRITES
    assert GT_SUB_WRITES == (("POST", "sc.gotickets.com", r"^/rest/substitution-requests$"),)


def test_gotickets_buy_client_registered_with_its_one_pinned_write():
    chk = _load_check_module()
    assert chk.CLIENT_FILES["gotickets_buy_client.py"] == frozenset({"GET", "POST"})
    assert chk.SANCTIONED_WRITE_TOKENS["gotickets_buy_client.py"] in (REPO_ROOT / "gotickets_buy_client.py").read_text()
    from gotickets_buy_client import GT_BUY_WRITES
    assert GT_BUY_WRITES == (("POST", "gotickets.com", r"^/rest/pro/api/orders$"),)


def test_sale_accept_guard_refuses_reject_and_other_writes():
    from sale_accept_client import _assert_readonly_method, SaleAcceptError
    for m, u in (("POST", "https://brokers.vividseats.com/webservices/v1/rejectOrder"),
                 ("POST", "https://sc.gotickets.com/rest/sales/1/cannot-retransfer-or-reissue"),
                 ("DELETE", "https://sellerdirect-api.seatgeek.com/order"),
                 ("POST", "https://api.tickpick.com/1.0/orders/1/rejection"),
                 ("POST", "https://api.tickpick.com/1.0/token")):
        with pytest.raises(SaleAcceptError):
            _assert_readonly_method(m, u)


def test_audit_allows_only_the_tickpick_token_login_from_plpgsql(tmp_path: Path, monkeypatch):
    chk = _load_check_module()
    assert chk.SANCTIONED_PLPGSQL_WRITE_URLS == ("https://api.tickpick.com/1.0/token",)
    mig = tmp_path / "supabase" / "migrations"
    mig.mkdir(parents=True)
    (mig / "1_ok.sql").write_text(
        "SELECT extensions.http(('POST', 'https://api.tickpick.com/1.0/token', NULL, 'x', 'grant_type=password'));\n")
    (mig / "2_bad.sql").write_text(
        "SELECT extensions.http(('POST', 'https://api.tickpick.com/1.0/orders/1/confirmation', NULL, NULL, '{}'));\n")
    (mig / "3_bad.sql").write_text(
        "SELECT extensions.http(('POST', 'https://api.tickpick.com/1.0/token', NULL, 'x', ''));\n"
        "SELECT extensions.http(('POST', 'https://api.tickpick.com/1.0/pro/orders', NULL, NULL, '{}'));\n")
    monkeypatch.setattr(chk, "ROOT", tmp_path)
    out = chk.check_plpgsql_writes()
    assert not any("1_ok.sql" in v for v in out)
    assert any("2_bad.sql" in v for v in out) and any("3_bad.sql" in v for v in out)
