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
