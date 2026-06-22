"""Render webhook receiver + GitHub Actions bridge.

Python port that unifies two Render examples, adapted to live inside the
unified FastAPI service (`app.py`) instead of as a standalone Node service:

  * render-examples/webhook-receiver
    (https://github.com/render-examples/webhook-receiver) — the generic
    Standard-Webhooks receiver skeleton: verify the signature, then dispatch
    over event type (`deploy_started`, `deploy_ended`, `database_available`,
    `key_value_available`, …), enriching each from the Render API.
  * render-examples/webhook-github-action
    (https://github.com/render-examples/webhook-github-action) — the
    specialization that, on a successful `deploy_ended`, triggers a GitHub
    Actions workflow via the workflow_dispatch API.

Here the receiver IS the generic dispatcher (`handle_webhook`), and the
GitHub-Action trigger is the registered `deploy_ended` handler. The route is
mounted at POST /webhooks/render; this module holds the pure logic so it can
be unit-tested without a running server or live network (see
tests/test_render_webhook.py).

Flow:
  1. Render fires a webhook, signed per the Standard Webhooks spec
     (https://www.standardwebhooks.com) — the same scheme both upstream
     examples verify via the `standardwebhooks` npm package.
  2. We verify the signature against RENDER_WEBHOOK_SECRET, reject replay
     (timestamp outside tolerance), and ACK 200 fast.
  3. Async: dispatch on `type`. For `deploy_ended` → confirm the deploy
     SUCCEEDED (Render API event lookup, or the payload's own `data.status`
     when no API key is configured), confirm the service points at our GitHub
     repo, then trigger the GitHub Actions workflow. Other types are enriched
     from the Render API and logged.

Env vars (all optional — the route degrades to "verify + log" if unset):
  RENDER_WEBHOOK_SECRET   Standard Webhooks signing secret (`whsec_...`).
                          REQUIRED for signature verification; without it the
                          route fails closed (401) — never accepts unsigned.
  RENDER_API_KEY          Render API token; enables the authoritative deploy
                          status + repo-match check. Falls back to the webhook
                          payload's `data.status` when unset.
  GITHUB_API_TOKEN        PAT (or fine-grained token) with `actions:write` on
                          the target repo. REQUIRED to dispatch the workflow.
  GITHUB_OWNER_NAME       Repo owner/org (e.g. "s4kent").
  GITHUB_REPO_NAME        Repo name (e.g. "terminal-2").
  GITHUB_WORKFLOW_ID      Workflow file to dispatch (default "post-deploy.yml").
  GITHUB_WORKFLOW_REF     Git ref to run the workflow on (default: the service's
                          deploy branch from Render, else "main").
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import os
import time

import requests

log = logging.getLogger("render_webhook")

# Render event `details.status` == 2 means the deploy went live (succeeded).
# Mirrors the `event.details.status != 2` gate in the upstream app.ts.
RENDER_DEPLOY_STATUS_LIVE = 2

# Replay window: reject webhooks whose timestamp is more than this many seconds
# from now. Matches the Standard Webhooks library default (5 minutes).
WEBHOOK_TOLERANCE_SECONDS = 5 * 60

RENDER_API_URL = os.environ.get("RENDER_API_URL", "https://api.render.com/v1")
GITHUB_API_URL = os.environ.get("GITHUB_API_URL", "https://api.github.com")


class WebhookVerificationError(Exception):
    """Raised when a webhook signature/timestamp fails verification."""


# ---------------------------------------------------------------------------
# Standard Webhooks signature verification
# ---------------------------------------------------------------------------
# A Standard Webhooks signature is HMAC-SHA256 over the byte string
# `{id}.{timestamp}.{body}`, base64-encoded, prefixed with the version tag
# `v1,`. The signing secret is `whsec_<base64>`; the bytes after the prefix are
# base64-decoded to form the HMAC key. The `webhook-signature` header may carry
# several space-delimited signatures (e.g. during a secret rotation); the
# webhook is valid if ANY of them matches.

def _secret_bytes(secret: str) -> bytes:
    """Decode a `whsec_`-prefixed Standard Webhooks secret into HMAC key bytes."""
    if secret.startswith("whsec_"):
        secret = secret[len("whsec_"):]
    return base64.b64decode(secret)


def sign_payload(secret: str, msg_id: str, timestamp: str, body: bytes) -> str:
    """Compute the `v1,<base64>` signature for a payload. Pure; used by tests."""
    signed_content = msg_id.encode() + b"." + str(timestamp).encode() + b"." + body
    digest = hmac.new(_secret_bytes(secret), signed_content, hashlib.sha256).digest()
    return "v1," + base64.b64encode(digest).decode()


def verify_signature(
    secret: str,
    body: bytes,
    headers: dict[str, str],
    *,
    now: float | None = None,
    tolerance_seconds: int = WEBHOOK_TOLERANCE_SECONDS,
) -> None:
    """Verify a Standard Webhooks request. Raises WebhookVerificationError on
    any failure; returns None on success.

    `headers` is matched case-insensitively (HTTP header names are not
    case-sensitive, and ASGI servers may normalize them).
    """
    if not secret:
        raise WebhookVerificationError("no signing secret configured")

    h = {k.lower(): v for k, v in headers.items()}
    msg_id = h.get("webhook-id", "")
    timestamp = h.get("webhook-timestamp", "")
    sig_header = h.get("webhook-signature", "")
    if not (msg_id and timestamp and sig_header):
        raise WebhookVerificationError("missing webhook-id/timestamp/signature headers")

    # Replay protection — reject stale or future-dated timestamps.
    try:
        ts = int(timestamp)
    except ValueError as e:
        raise WebhookVerificationError("invalid webhook-timestamp") from e
    current = time.time() if now is None else now
    if ts < current - tolerance_seconds:
        raise WebhookVerificationError("webhook timestamp too old")
    if ts > current + tolerance_seconds:
        raise WebhookVerificationError("webhook timestamp too new")

    expected = sign_payload(secret, msg_id, timestamp, body)
    expected_b64 = expected.split(",", 1)[1]

    # The header is a space-delimited list of `version,signature` pairs.
    for part in sig_header.split():
        version, _, value = part.partition(",")
        if version != "v1":
            continue
        if hmac.compare_digest(value, expected_b64):
            return
    raise WebhookVerificationError("no matching signature")


# ---------------------------------------------------------------------------
# Render API enrichment (best-effort; only used when RENDER_API_KEY is set)
# ---------------------------------------------------------------------------

def _render_get(path: str, api_key: str) -> dict | None:
    try:
        r = requests.get(
            f"{RENDER_API_URL}{path}",
            headers={"Accept": "application/json", "Authorization": f"Bearer {api_key}"},
            timeout=15,
        )
        if r.status_code != 200:
            log.warning("render API GET %s -> %s", path, r.status_code)
            return None
        return r.json()
    except requests.RequestException as e:
        log.warning("render API GET %s failed: %s", path, e)
        return None


def deploy_succeeded(payload: dict, api_key: str | None) -> bool:
    """Did this `deploy_ended` event represent a successful deploy?

    Prefers the authoritative Render API event lookup (the upstream behavior);
    falls back to the webhook payload's own `data.status` when no API key is
    configured. Fails closed (False) if neither source confirms success.
    """
    data = payload.get("data") or {}
    if api_key and data.get("id"):
        event = _render_get(f"/events/{data['id']}", api_key)
        if event is None:
            return False
        return (event.get("details") or {}).get("status") == RENDER_DEPLOY_STATUS_LIVE
    # No API key: trust the payload's status field if present.
    return data.get("status") == "succeeded"


def service_targets_repo(service_id: str, owner: str, repo: str, api_key: str | None) -> tuple[bool, str | None]:
    """Confirm the deployed service points at our GitHub repo, and return its
    deploy branch. When no API key is configured we can't check — return
    (True, None) and let the caller fall back to the configured ref.
    """
    if not api_key:
        return True, None
    service = _render_get(f"/services/{service_id}", api_key)
    if service is None:
        return False, None
    repo_url = service.get("repo") or ""
    return (f"{owner}/{repo}" in repo_url), service.get("branch")


# ---------------------------------------------------------------------------
# GitHub workflow_dispatch trigger
# ---------------------------------------------------------------------------

def dispatch_github_workflow(
    *,
    owner: str,
    repo: str,
    workflow_id: str,
    ref: str,
    token: str,
    inputs: dict[str, str] | None = None,
) -> bool:
    """Trigger a workflow_dispatch run. Returns True on the GitHub 204 ACK."""
    url = f"{GITHUB_API_URL}/repos/{owner}/{repo}/actions/workflows/{workflow_id}/dispatches"
    try:
        r = requests.post(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {token}",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            json={"ref": ref, "inputs": inputs or {}},
            timeout=15,
        )
    except requests.RequestException as e:
        log.error("github workflow_dispatch failed: %s", e)
        return False
    if r.status_code == 204:
        log.info("dispatched %s on %s@%s", workflow_id, f"{owner}/{repo}", ref)
        return True
    log.error("github workflow_dispatch -> %s: %s", r.status_code, r.text[:300])
    return False


# ---------------------------------------------------------------------------
# Orchestration — called from app.py's BackgroundTasks after a verified 200 ACK
# ---------------------------------------------------------------------------
# Maps a webhook event type to the Render API resource path that enriches it
# (mirrors webhook-receiver's fetchServiceInfo / fetchPostgresInfo / etc.).
# `{sid}` is filled with the payload's data.serviceId.
_ENRICH_PATH = {
    "deploy_started": "/services/{sid}",
    "server_failed": "/services/{sid}",
    "server_available": "/services/{sid}",
    "database_available": "/postgres/{sid}",
    "key_value_available": "/key-value/{sid}",
}


def handle_webhook(payload: dict, cfg: dict | None = None) -> str:
    """Generic Render-webhook dispatcher (the webhook-receiver pattern).

    Routes `deploy_ended` to the GitHub-Actions trigger; enriches+logs every
    other known type from the Render API; logs unknown types. Returns a short
    status string (handy for logging/tests). Never raises — it runs in a
    background task where exceptions would be swallowed anyway.
    """
    c = cfg or load_config()
    ptype = payload.get("type")

    if ptype == "deploy_ended":
        return handle_deploy_ended(payload, c)

    return describe_event(payload, c)


def describe_event(payload: dict, cfg: dict) -> str:
    """Best-effort enrich + summarize a non-deploy_ended event. Enrichment
    requires RENDER_API_KEY; without it we just report type + serviceId."""
    ptype = payload.get("type")
    data = payload.get("data") or {}
    sid = data.get("serviceId", "")
    path_tmpl = _ENRICH_PATH.get(ptype)

    if path_tmpl and cfg.get("render_api_key"):
        resource = _render_get(path_tmpl.format(sid=sid), cfg["render_api_key"])
        if resource and resource.get("name"):
            return f"{ptype}: {resource['name']} ({sid})"
    return f"{ptype}: {sid}" if ptype else "ignored: missing type"


def handle_deploy_ended(payload: dict, cfg: dict | None = None) -> str:
    """Process a verified `deploy_ended` webhook. Returns a short status string
    describing the outcome (also useful for logging/testing). Never raises —
    runs in a background task where exceptions would be swallowed anyway.
    """
    c = cfg or load_config()
    ptype = payload.get("type")
    data = payload.get("data") or {}
    service_id = data.get("serviceId", "")

    if ptype != "deploy_ended":
        return f"ignored: type={ptype}"

    if not deploy_succeeded(payload, c["render_api_key"]):
        return f"skipped: deploy not successful (service={service_id})"

    if not (c["github_token"] and c["github_owner"] and c["github_repo"]):
        return "skipped: GitHub dispatch not configured"

    ok_repo, branch = service_targets_repo(
        service_id, c["github_owner"], c["github_repo"], c["render_api_key"]
    )
    if not ok_repo:
        return f"skipped: service {service_id} does not target {c['github_owner']}/{c['github_repo']}"

    ref = c["github_ref"] or branch or "main"
    dispatched = dispatch_github_workflow(
        owner=c["github_owner"],
        repo=c["github_repo"],
        workflow_id=c["github_workflow_id"],
        ref=ref,
        token=c["github_token"],
        inputs={"serviceID": service_id},
    )
    return "dispatched" if dispatched else "error: dispatch failed"


def load_config() -> dict:
    """Read bridge config from the environment (evaluated per-request so env
    changes don't require a restart in tests)."""
    return {
        "webhook_secret": os.environ.get("RENDER_WEBHOOK_SECRET", ""),
        "render_api_key": os.environ.get("RENDER_API_KEY") or None,
        "github_token": os.environ.get("GITHUB_API_TOKEN", ""),
        # Defaults point at this repo so the bridge is correctly aimed even
        # before the GITHUB_OWNER_NAME/GITHUB_REPO_NAME env vars are set.
        "github_owner": os.environ.get("GITHUB_OWNER_NAME") or "JulianS4K",
        "github_repo": os.environ.get("GITHUB_REPO_NAME") or "Terminal-2",
        "github_workflow_id": os.environ.get("GITHUB_WORKFLOW_ID", "post-deploy.yml"),
        "github_ref": os.environ.get("GITHUB_WORKFLOW_REF") or None,
    }
