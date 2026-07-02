"""Property-based tests (hypothesis) for the string-manipulation parsers.

Testing-recommendation #4: the functions where adversarial input meets string
manipulation are exactly where hand-written example tests miss the edge cases —
empty segments, unicode, embedded delimiters, wildcard soup. Hypothesis
generates those inputs and asserts *invariants* (properties that must hold for
every input) rather than specific outputs:

  * core.search._escape_ilike        — every PostgREST ILIKE wildcard escaped
  * core.helpers.normalize_filters   — always canonical shape, never raises
  * core.helpers.client_ip_from_xff  — never raises, no stray whitespace
  * EvoClient.decrypt_barcode        — forged/garbage tokens raise ValueError,
                                       never a leaking low-level crypto error

These sit alongside (not instead of) the example-based unit tests: properties
catch the class of bug, examples pin the specific known cases.
"""
from __future__ import annotations

from hypothesis import given, settings
from hypothesis import strategies as st

from core.helpers import client_ip_from_xff, normalize_filters
from core.search import _ILIKE_WILDCARDS, _escape_ilike
from evo_client import EvoClient


# --- _escape_ilike -----------------------------------------------------------

@given(st.text())
def test_escape_ilike_never_raises_and_returns_str(s):
    assert isinstance(_escape_ilike(s), str)


@given(st.text())
def test_escape_ilike_every_wildcard_is_backslash_escaped(s):
    """After escaping, every wildcard char is immediately preceded by a
    backslash — so a user-supplied `%` / `_` / `\\` can never act as a live
    ILIKE metacharacter (the match-everything bug)."""
    out = _escape_ilike(s)
    for i, ch in enumerate(out):
        if ch in _ILIKE_WILDCARDS and ch != "\\":
            assert i > 0 and out[i - 1] == "\\", f"unescaped {ch!r} at {i} in {out!r}"


@given(st.text(alphabet="ab%_\\ ", max_size=12))
def test_escape_ilike_backslash_count_is_conserved(s):
    """Each wildcard occurrence adds exactly one backslash; escaping is total
    (no wildcard left unescaped, none double-counted)."""
    out = _escape_ilike(s)
    added = sum(s.count(w) for w in _ILIKE_WILDCARDS)
    assert out.count("\\") == s.count("\\") + added


# --- normalize_filters -------------------------------------------------------

_json_scalars = st.none() | st.booleans() | st.integers() | st.floats(allow_nan=False, allow_infinity=False) | st.text()
_filter_values = _json_scalars | st.lists(_json_scalars, max_size=5)


@given(st.dictionaries(st.text(max_size=10), _filter_values, max_size=8))
def test_normalize_filters_always_canonical_shape(raw):
    """Whatever junk comes in, out comes exactly the five canonical keys with
    the documented types — the resolver downstream never has to defend."""
    out = normalize_filters(raw)
    assert set(out) == {"section", "zones", "min_price", "max_price", "min_qty"}
    assert isinstance(out["section"], list) and all(isinstance(x, str) for x in out["section"])
    assert isinstance(out["zones"], list) and all(isinstance(x, str) for x in out["zones"])
    assert out["min_price"] is None or isinstance(out["min_price"], float)
    assert out["max_price"] is None or isinstance(out["max_price"], float)
    assert out["min_qty"] is None or isinstance(out["min_qty"], int)


@given(st.one_of(st.none(), st.dictionaries(st.text(max_size=6), _filter_values, max_size=6)))
def test_normalize_filters_never_raises(raw):
    normalize_filters(raw)  # must not raise on None or any dict


# --- client_ip_from_xff ------------------------------------------------------

@given(st.text(), st.one_of(st.none(), st.text(max_size=20)))
def test_client_ip_from_xff_never_raises(xff, fallback):
    client_ip_from_xff(xff, fallback)


@given(st.text(min_size=1).filter(lambda s: s.strip() != ""))
def test_client_ip_from_xff_result_has_no_surrounding_whitespace(xff):
    """A non-empty header always yields a stripped token — no leading/trailing
    whitespace leaks into a rate-limit bucket key."""
    out = client_ip_from_xff(xff, "unknown")
    assert out == out.strip()


@given(st.text(alphabet="abcd.:", min_size=1))
def test_client_ip_from_xff_takes_rightmost_hop(chain_parts):
    """With no commas the whole (trimmed) value is returned; with commas the
    rightmost segment wins — the proxy-appended, unforgeable hop."""
    header = f"1.1.1.1, 2.2.2.2, {chain_parts}"
    assert client_ip_from_xff(header, "x") == chain_parts.strip()


def test_client_ip_from_xff_empty_returns_fallback():
    assert client_ip_from_xff("", "fb") == "fb"
    assert client_ip_from_xff(None, "fb") == "fb"


# --- decrypt_barcode (adversarial forgery) -----------------------------------

_evo = EvoClient("tok", "S" * 40)  # secret ≥ 32 bytes so the Fernet key derives


@settings(max_examples=75)
@given(st.text(max_size=64))
def test_decrypt_barcode_rejects_forged_tokens_as_valueerror(garbage):
    """Any string that isn't a Fernet token we signed must surface as a clean
    ValueError ('invalid or forged...') — never a raw InvalidToken / binascii /
    UnicodeError bubbling out of the crypto layer to a 500."""
    try:
        _evo.decrypt_barcode(garbage)
    except ValueError:
        pass  # expected — forged/garbage token
    else:
        # The only way we reach here is if hypothesis somehow forged a token we
        # signed with an all-"S" secret, which is cryptographically impossible.
        raise AssertionError("garbage token unexpectedly decrypted")
