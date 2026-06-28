"""Tests for core/http_retry.fetch_with_retry — the shared client retry loop.

The per-client retry behavior is also covered through each client's own tests
(e.g. test_evo_client_full.py); this exercises the helper directly, including
the jitter + invalid-Retry-After paths a given client may not hit. BR-CODE-2.
"""
from __future__ import annotations

from core.http_retry import fetch_with_retry

_STATUSES = frozenset({429, 502, 503, 504})


class _Resp:
    def __init__(self, status, headers=None):
        self.status_code = status
        self.ok = status < 400
        self.headers = headers or {}


def _seq(*resps):
    it = iter(resps)
    return lambda: next(it)


def test_returns_first_ok_without_sleeping():
    slept = []
    r = fetch_with_retry(_seq(_Resp(200)), max_retries=4, retry_statuses=_STATUSES,
                         base_backoff=0.5, max_backoff=30, sleep=slept.append)
    assert r.status_code == 200
    assert slept == []


def test_retries_then_succeeds():
    slept = []
    r = fetch_with_retry(_seq(_Resp(503), _Resp(200)), max_retries=4, retry_statuses=_STATUSES,
                         base_backoff=0.5, max_backoff=30, sleep=slept.append)
    assert r.status_code == 200
    assert slept == [0.5]


def test_exhausts_and_returns_last_non_ok():
    slept = []
    r = fetch_with_retry(lambda: _Resp(429), max_retries=4, retry_statuses=_STATUSES,
                         base_backoff=0.5, max_backoff=30, sleep=slept.append)
    assert r.status_code == 429
    assert slept == [0.5, 1.0, 2.0, 4.0]   # capped exponential, 4 retries


def test_non_retryable_returns_immediately():
    slept = []
    r = fetch_with_retry(_seq(_Resp(404)), max_retries=4, retry_statuses=_STATUSES,
                         base_backoff=0.5, max_backoff=30, sleep=slept.append)
    assert r.status_code == 404
    assert slept == []


def test_retry_after_numeric_honored_and_capped():
    slept = []
    fetch_with_retry(_seq(_Resp(429, {"Retry-After": "9999"}), _Resp(200)),
                     max_retries=4, retry_statuses=_STATUSES,
                     base_backoff=0.5, max_backoff=30, sleep=slept.append)
    assert slept == [30.0]   # capped


def test_invalid_retry_after_falls_back_to_exponential():
    slept = []
    fetch_with_retry(_seq(_Resp(429, {"Retry-After": "soon"}), _Resp(200)),
                     max_retries=4, retry_statuses=_STATUSES,
                     base_backoff=0.5, max_backoff=30, sleep=slept.append)
    assert slept == [0.5]    # attempt 0 exponential


def test_jitter_added_and_clamped():
    slept = []
    # jitter returns 100 -> wait 0.5+100 clamped to max_backoff 30.
    fetch_with_retry(_seq(_Resp(429), _Resp(200)),
                     max_retries=4, retry_statuses=_STATUSES,
                     base_backoff=0.5, max_backoff=30, sleep=slept.append,
                     jitter=lambda: 100.0)
    assert slept == [30.0]


def test_empty_retry_range_makes_no_request():
    called = []

    def boom():
        called.append(1)
        return _Resp(200)

    out = fetch_with_retry(boom, max_retries=-1, retry_statuses=_STATUSES,
                           base_backoff=0.5, max_backoff=30, sleep=lambda s: None)
    assert out is None
    assert called == []
