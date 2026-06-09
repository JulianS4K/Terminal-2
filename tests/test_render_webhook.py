"""Unit tests for the Render deploy-webhook → GitHub Actions bridge.

Pure — no network, no running server. The signature tests pin the Standard
Webhooks scheme against the project's own published known-answer vector, so a
future refactor that silently breaks verification (and would make the receiver
reject every real webhook) fails CI instead.

Run:
  py -m pytest tests/test_render_webhook.py -v
"""
from __future__ import annotations

import pytest

import render_webhook as rw

# Known-answer vector from the Standard Webhooks spec / reference libraries.
# https://github.com/standard-webhooks/standard-webhooks
# Public test vector, NOT a real credential — annotated so secret-scan ignores it.
KAT_SECRET = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"  # gitleaks:allow
KAT_ID = "msg_p5jXN8AQM9LWM0D4loKWxJek"
KAT_TIMESTAMP = "1614265330"
KAT_BODY = b'{"test": 2432232314}'
KAT_SIGNATURE = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="


def _headers(sig=KAT_SIGNATURE, msg_id=KAT_ID, ts=KAT_TIMESTAMP):
    return {
        "webhook-id": msg_id,
        "webhook-timestamp": ts,
        "webhook-signature": sig,
    }


# --- sign_payload: known-answer test -----------------------------------------

def test_sign_payload_matches_known_answer():
    assert rw.sign_payload(KAT_SECRET, KAT_ID, KAT_TIMESTAMP, KAT_BODY) == KAT_SIGNATURE


def test_sign_payload_accepts_unprefixed_secret():
    # Secrets with the whsec_ prefix stripped must hash identically.
    assert rw.sign_payload(
        KAT_SECRET[len("whsec_"):], KAT_ID, KAT_TIMESTAMP, KAT_BODY
    ) == KAT_SIGNATURE


# --- verify_signature: accept path -------------------------------------------

def test_verify_accepts_valid_signature():
    # `now` pinned to the vector's timestamp so the replay window passes.
    rw.verify_signature(KAT_SECRET, KAT_BODY, _headers(), now=float(KAT_TIMESTAMP))


def test_verify_is_header_case_insensitive():
    headers = {
        "Webhook-Id": KAT_ID,
        "Webhook-Timestamp": KAT_TIMESTAMP,
        "Webhook-Signature": KAT_SIGNATURE,
    }
    rw.verify_signature(KAT_SECRET, KAT_BODY, headers, now=float(KAT_TIMESTAMP))


def test_verify_accepts_when_one_of_several_sigs_matches():
    # Header may carry multiple space-delimited sigs during secret rotation.
    multi = f"v1,aGVsbG8= {KAT_SIGNATURE}"
    rw.verify_signature(KAT_SECRET, KAT_BODY, _headers(sig=multi), now=float(KAT_TIMESTAMP))


# --- verify_signature: reject paths ------------------------------------------

def test_verify_rejects_tampered_body():
    with pytest.raises(rw.WebhookVerificationError):
        rw.verify_signature(KAT_SECRET, KAT_BODY + b" ", _headers(), now=float(KAT_TIMESTAMP))


def test_verify_rejects_wrong_secret():
    other = "whsec_" + rw.base64.b64encode(b"not-the-right-secret").decode()
    with pytest.raises(rw.WebhookVerificationError):
        rw.verify_signature(other, KAT_BODY, _headers(), now=float(KAT_TIMESTAMP))


def test_verify_rejects_empty_secret():
    with pytest.raises(rw.WebhookVerificationError):
        rw.verify_signature("", KAT_BODY, _headers(), now=float(KAT_TIMESTAMP))


def test_verify_rejects_missing_headers():
    with pytest.raises(rw.WebhookVerificationError):
        rw.verify_signature(KAT_SECRET, KAT_BODY, {}, now=float(KAT_TIMESTAMP))


def test_verify_rejects_stale_timestamp():
    # Same valid signature, but evaluated far in the future → replay window.
    future = float(KAT_TIMESTAMP) + rw.WEBHOOK_TOLERANCE_SECONDS + 60
    with pytest.raises(rw.WebhookVerificationError):
        rw.verify_signature(KAT_SECRET, KAT_BODY, _headers(), now=future)


def test_verify_rejects_future_timestamp():
    past = float(KAT_TIMESTAMP) - rw.WEBHOOK_TOLERANCE_SECONDS - 60
    with pytest.raises(rw.WebhookVerificationError):
        rw.verify_signature(KAT_SECRET, KAT_BODY, _headers(), now=past)


def test_verify_ignores_non_v1_versions():
    with pytest.raises(rw.WebhookVerificationError):
        rw.verify_signature(
            KAT_SECRET, KAT_BODY, _headers(sig="v2,whatever"), now=float(KAT_TIMESTAMP)
        )


# --- deploy_succeeded: payload-status fallback (no API key) -------------------

def test_deploy_succeeded_payload_fallback_true():
    payload = {"type": "deploy_ended", "data": {"id": "evt-1", "status": "succeeded"}}
    assert rw.deploy_succeeded(payload, api_key=None) is True


@pytest.mark.parametrize("status", ["failed", "canceled", None])
def test_deploy_succeeded_payload_fallback_false(status):
    payload = {"type": "deploy_ended", "data": {"id": "evt-1", "status": status}}
    assert rw.deploy_succeeded(payload, api_key=None) is False


# --- handle_deploy_ended: orchestration gates (no network) -------------------

BASE_CFG = {
    "webhook_secret": KAT_SECRET,
    "render_api_key": None,
    "github_token": "ghp_test",
    "github_owner": "s4kent",
    "github_repo": "terminal-2",
    "github_workflow_id": "post-deploy.yml",
    "github_ref": "main",
}


def test_handle_ignores_non_deploy_event():
    out = rw.handle_deploy_ended({"type": "server_failed", "data": {}}, dict(BASE_CFG))
    assert out.startswith("ignored")


def test_handle_skips_unsuccessful_deploy():
    payload = {"type": "deploy_ended", "data": {"serviceId": "srv-x", "status": "failed"}}
    out = rw.handle_deploy_ended(payload, dict(BASE_CFG))
    assert out.startswith("skipped")


def test_handle_skips_when_github_not_configured():
    cfg = dict(BASE_CFG, github_token="")
    payload = {"type": "deploy_ended", "data": {"serviceId": "srv-x", "status": "succeeded"}}
    out = rw.handle_deploy_ended(payload, cfg)
    assert "GitHub dispatch not configured" in out


def test_handle_dispatches_on_success(monkeypatch):
    captured = {}

    def fake_dispatch(**kwargs):
        captured.update(kwargs)
        return True

    monkeypatch.setattr(rw, "dispatch_github_workflow", fake_dispatch)
    payload = {"type": "deploy_ended", "data": {"serviceId": "srv-abc", "status": "succeeded"}}
    out = rw.handle_deploy_ended(payload, dict(BASE_CFG))
    assert out == "dispatched"
    assert captured["owner"] == "s4kent"
    assert captured["repo"] == "terminal-2"
    assert captured["workflow_id"] == "post-deploy.yml"
    assert captured["ref"] == "main"
    assert captured["inputs"] == {"serviceID": "srv-abc"}


# --- handle_webhook: generic dispatcher (webhook-receiver pattern) -----------

def test_handle_webhook_routes_deploy_ended_to_github(monkeypatch):
    monkeypatch.setattr(rw, "dispatch_github_workflow", lambda **kw: True)
    payload = {"type": "deploy_ended", "data": {"serviceId": "srv-abc", "status": "succeeded"}}
    assert rw.handle_webhook(payload, dict(BASE_CFG)) == "dispatched"


def test_handle_webhook_describes_other_events_without_api_key():
    # No RENDER_API_KEY → no network; just summarizes type + serviceId.
    payload = {"type": "database_available", "data": {"serviceId": "dpg-xyz"}}
    out = rw.handle_webhook(payload, dict(BASE_CFG))
    assert out == "database_available: dpg-xyz"


def test_handle_webhook_enriches_with_api_key(monkeypatch):
    monkeypatch.setattr(rw, "_render_get", lambda path, key: {"name": "my-db"} if "/postgres/" in path else None)
    cfg = dict(BASE_CFG, render_api_key="rnd_test")
    payload = {"type": "database_available", "data": {"serviceId": "dpg-xyz"}}
    out = rw.handle_webhook(payload, cfg)
    assert out == "database_available: my-db (dpg-xyz)"


def test_handle_webhook_handles_missing_type():
    assert rw.handle_webhook({"data": {}}, dict(BASE_CFG)).startswith("ignored")
