"""Referral (affiliate) wrapping for outbound marketplace buy links.

The public price pages link out to the marketplaces; this module turns a plain
marketplace URL into that marketplace's referral link when we hold a referral
account there, and returns the URL unchanged when we do not. It builds strings
only — nothing here calls a marketplace (CLAUDE.md rule 2 is untouched).

Programs are configured in one environment variable, ``REFERRAL_PROGRAMS``, a
JSON object keyed by the same marketplace keys ``routers/prices.py`` uses
(``seatgeek``, ``stubhub``, ``vivid``, ``ticketmaster``, ...). The ids in it are
not secrets — they are visible in every link we publish. Three link shapes:

- ``impact`` (SeatGeek, Vivid Seats, Ticketmaster run on impact.com)::

      {"network": "impact", "base": "https://<tracking domain>/c/<account>/<ad>/<campaign>"}

  → ``<base>?u=<encoded destination>&subId1=<sub id>``. ``base`` is the tracking
  link the Impact dashboard shows for the brand, up to the campaign id.

- ``partnerize`` (StubHub North America)::

      {"network": "partnerize", "camref": "<camref>"}

  → ``https://prf.hn/click/camref:<camref>/pubref:<sub id>/destination:<encoded destination>``.

- ``query`` (ids appended to the marketplace's own URL — SeatGeek's partner
  ``aid``, with ``rid`` as the sub id)::

      {"network": "query", "params": {"aid": "12332"}, "sub_param": "rid"}

A destination is wrapped only when it is an https link on one of that
marketplace's own hosts (``MARKETPLACE_HOSTS``): a network rejects a deep link
to a domain the brand has not allowed, and we never want a referral id on a URL
that is not the marketplace's. A malformed entry is dropped, not guessed at, so
a bad value in the environment costs the referral and never the link.
"""
from __future__ import annotations

import json
import os
import re
from typing import Any, Optional
from urllib.parse import parse_qsl, quote, urlencode, urlsplit, urlunsplit

ENV_VAR = "REFERRAL_PROGRAMS"

# Marketplace key → the hosts (and their subdomains) a referral link may point at.
MARKETPLACE_HOSTS: dict[str, tuple[str, ...]] = {
    "seatgeek": ("seatgeek.com",),
    "stubhub": ("stubhub.com",),
    "vivid": ("vividseats.com",),
    "gametime": ("gametime.co",),
    "tickpick": ("tickpick.com",),
    "ticketmaster": ("ticketmaster.com", "livenation.com"),
    "axs": ("axs.com",),
}

PARTNERIZE_CLICK = "https://prf.hn/click"
_IMPACT_BASE = re.compile(r"^https://[a-z0-9.-]+\.[a-z]{2,}/c/\d+/\d+/\d+$")
_TOKEN = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_SUB_UNSAFE = re.compile(r"[^A-Za-z0-9_-]")


def _clean_program(key: str, spec: Any) -> Optional[dict]:
    """One validated program entry, or None when it is not usable."""
    if key not in MARKETPLACE_HOSTS or not isinstance(spec, dict):
        return None
    network = spec.get("network")
    if network == "impact":
        base = str(spec.get("base") or "").strip().rstrip("/")
        return {"network": "impact", "base": base} if _IMPACT_BASE.match(base) else None
    if network == "partnerize":
        camref = str(spec.get("camref") or "").strip()
        return {"network": "partnerize", "camref": camref} if _TOKEN.match(camref) else None
    if network == "query":
        params = spec.get("params")
        if not isinstance(params, dict) or not params:
            return None
        clean = {str(k): str(v) for k, v in params.items()}
        if not all(_TOKEN.match(k) and _TOKEN.match(v) for k, v in clean.items()):
            return None
        sub_param = spec.get("sub_param")
        if sub_param is not None and not _TOKEN.match(str(sub_param)):
            return None
        return {"network": "query", "params": clean, "sub_param": str(sub_param) if sub_param else None}
    return None


def load_programs(raw: Optional[str] = None) -> dict[str, dict]:
    """The usable programs from ``raw`` (default: the environment variable)."""
    text = os.environ.get(ENV_VAR, "") if raw is None else raw
    if not text.strip():
        return {}
    try:
        data = json.loads(text)
    except ValueError:
        return {}
    if not isinstance(data, dict):
        return {}
    out = {}
    for key, spec in data.items():
        prog = _clean_program(str(key), spec)
        if prog:
            out[str(key)] = prog
    return out


def _on_marketplace(key: str, url: str) -> bool:
    parts = urlsplit(url)
    host = (parts.hostname or "").lower()
    return parts.scheme == "https" and any(
        host == h or host.endswith("." + h) for h in MARKETPLACE_HOSTS.get(key, ()))


def clean_sub_id(sub_id: Any) -> Optional[str]:
    """A sub id the networks accept: letters, digits, ``_`` and ``-``, 64 at most."""
    s = _SUB_UNSAFE.sub("", str(sub_id)) if sub_id is not None else ""
    return s[:64] or None


def wrap(key: str, url: str, sub_id: Any = None,
         programs: Optional[dict[str, dict]] = None) -> tuple[str, bool]:
    """``(link, is_referral)`` for a marketplace URL.

    ``sub_id`` names where the click came from (e.g. ``ev3226757``) so a
    network's report can be read per page; it must never carry anything about
    the visitor."""
    progs = load_programs() if programs is None else programs
    prog = progs.get(key)
    if not prog or not _on_marketplace(key, url):
        return url, False
    sub = clean_sub_id(sub_id)
    if prog["network"] == "impact":
        link = f"{prog['base']}?u={quote(url, safe='')}"
        return (f"{link}&subId1={sub}" if sub else link), True
    if prog["network"] == "partnerize":
        pubref = f"/pubref:{sub}" if sub else ""
        return f"{PARTNERIZE_CLICK}/camref:{prog['camref']}{pubref}/destination:{quote(url, safe='')}", True
    parts = urlsplit(url)
    ours = dict(prog["params"])
    if sub and prog["sub_param"]:
        ours[prog["sub_param"]] = sub
    kept = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k not in ours]
    return urlunsplit(parts._replace(query=urlencode(kept + list(ours.items())))), True
