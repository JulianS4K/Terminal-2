"""Storefront share-link API — create / resolve / revoke / list.

app.py decomposition slice (BR-CODE-1): the four `/api/store/share*` JSON
routes lifted verbatim out of app.py behind unchanged paths. Behavior,
validation, ownership enforcement (audit S1/S2/S4), and the event-end expiry
cap are identical to the prior inline handlers.

Dependency injection uses FastAPI `Depends` (coding-recommendation #2) rather
than lambda-getter module-global monkeypatch seams:
  - `sb_dep` -> a dependency returning the live Supabase client. Tests inject a
    fake via `app.dependency_overrides[server.get_sb_dep]` — the native seam,
    so the test no longer shapes the production wiring by patching a global.
  - `resolve_event_dep` -> a dependency returning `_resolve_event_with_filters`.
`require_auth` is passed straight through (already a FastAPI dependency). The
pure filter/serialization helpers come from core.helpers directly.

Request bodies are Pydantic models (coding-recommendation #1) — validation,
422 field errors, declarative bounds, and OpenAPI for free.

The HTML page route `/s/{share_id}` stays in app.py — it serves the storefront
shell, not JSON.
"""
from __future__ import annotations

import logging
import secrets
from datetime import datetime, timedelta, timezone
from typing import Callable

from fastapi import APIRouter, Depends, HTTPException

from core.helpers import normalize_filters, share_to_dict
from routers.models import ShareCreateRequest

_log = logging.getLogger("app")


def build_shares_router(
    sb_dep: Callable,
    require_auth: Callable,
    resolve_event_dep: Callable,
) -> APIRouter:
    router = APIRouter()

    @router.post("/api/store/share")
    def store_share_create(
        body: ShareCreateRequest,
        user=Depends(require_auth),
        db=Depends(sb_dep),
    ):
        """Create a revocable share link for one event with saved filters.

        Body shape + bounds are enforced declaratively by ShareCreateRequest
        (event_id > 0, note ≤ 500 chars, expires_in_days 0..365). A bad body
        returns 422 with field-level errors before any Supabase call.

        Auth: require_auth (Supabase JWT + allowed-domain email).
        """
        event_id = body.event_id
        filters = normalize_filters(body.filters or {})
        # Persist arrays only if non-empty + numeric values only if set, so the
        # JSON stays compact and equivalent to the URL form.
        persisted: dict = {}
        if filters["section"]: persisted["section"] = filters["section"]
        if filters["zones"]:   persisted["zones"]   = filters["zones"]
        if filters["min_price"] is not None: persisted["min_price"] = filters["min_price"]
        if filters["max_price"] is not None: persisted["max_price"] = filters["max_price"]
        if filters["min_qty"]   is not None: persisted["min_qty"]   = filters["min_qty"]

        note = (body.note or "").strip() or None

        # Compute the auto-expiry ceiling: event_start + 1h. Past this point the
        # share is effectively useless (event has started + small buffer for
        # walk-up viewing), so we always cap expires_at here. User-chosen
        # expires_in_days narrows further; null/0/never == "use the cap".
        event_end_ceiling: datetime | None = None
        try:
            ev_row = (
                db.table("events")
                .select("occurs_at_local")
                .eq("id", event_id)
                .limit(1)
                .execute().data
            )
            if ev_row and ev_row[0].get("occurs_at_local"):
                ev_start = datetime.fromisoformat(
                    str(ev_row[0]["occurs_at_local"]).replace("Z", "+00:00")
                )
                # `occurs_at_local` carries the real offset (TZ-qualified ISO),
                # so the resulting datetime is timezone-aware.
                event_end_ceiling = ev_start + timedelta(hours=1)
        except Exception:
            event_end_ceiling = None  # No event row found — fall back to user-only.

        expires_at: str | None = None
        # 0 / None == "no explicit pick, use the event-end cap" (the model bounds
        # a real pick to 1..365 declaratively, so no imperative range check here).
        days = body.expires_in_days or 0
        user_pick: datetime | None = None
        if days:
            user_pick = datetime.now(timezone.utc) + timedelta(days=days)

        # Pick the tighter of (user choice, event-end ceiling). When the event
        # is unknown, fall back to the user choice. When neither is set the
        # share never expires (legacy behavior preserved).
        if user_pick and event_end_ceiling:
            chosen = min(user_pick, event_end_ceiling)
        else:
            chosen = user_pick or event_end_ceiling
        if chosen:
            expires_at = chosen.astimezone(timezone.utc).isoformat()

        # Populate created_by so DELETE + LIST routes can enforce ownership
        # (audit S1/S2). AUTH_DISABLED=true (dev) -> require_auth returns None ->
        # store NULL and the ownership filters in those routes correctly skip.
        created_by = user["id"] if user else None

        # ~12 chars (9 random bytes → 12 url-safe chars) ≈ 72 bits of entropy.
        # Retry once on the astronomically unlikely collision.
        share_id = secrets.token_urlsafe(9)
        row = {
            "id": share_id,
            "event_id": event_id,
            "filters": persisted,
            "note": note,
            "expires_at": expires_at,
            "created_by": created_by,
        }
        try:
            ins = db.table("share_links").insert(row).execute()
        except Exception as e:
            # Pretty much always a primary-key collision; one retry is enough.
            share_id = secrets.token_urlsafe(9)
            row["id"] = share_id
            try:
                ins = db.table("share_links").insert(row).execute()
            except Exception as e2:
                # Sanitized: log full upstream error server-side, return a stable
                # generic string so Supabase exception text doesn't leak (audit S4).
                _log.warning(f"[store_share_create] share insert failed twice for {share_id}: {e2!r}")
                raise HTTPException(500, "could not create share link") from e

        saved = (ins.data or [None])[0] or row
        return share_to_dict(saved)

    @router.get("/api/store/share/{share_id}")
    def store_share_resolve(share_id: str, db=Depends(sb_dep), resolve_event=Depends(resolve_event_dep)):
        """Public endpoint: resolves a share link to its filtered event payload.
        Bumps view_count on every successful read. 410 if revoked or expired."""
        res = (
            db.table("share_links")
            .select("id,event_id,filters,note,created_at,expires_at,revoked_at,view_count,last_viewed_at")
            .eq("id", share_id)
            .limit(1)
            .execute()
        )
        rows = res.data or []
        if not rows:
            raise HTTPException(404, "share link not found")
        row = rows[0]

        if row.get("revoked_at"):
            raise HTTPException(410, "this share link has been revoked")
        expires = row.get("expires_at")
        if expires:
            try:
                if datetime.fromisoformat(str(expires).replace("Z", "+00:00")) <= datetime.now(timezone.utc):
                    raise HTTPException(410, "this share link has expired")
            except ValueError:
                pass  # Bad timestamp shouldn't 500 the recipient

        detail = resolve_event(int(row["event_id"]), row.get("filters") or {})

        # View tracking — best-effort; a tracking failure shouldn't break the page.
        try:
            db.rpc("bump_share_view", {"p_id": share_id}).execute()
        except Exception:
            pass

        return {
            "share": share_to_dict(row),
            **detail,
        }

    @router.delete("/api/store/share/{share_id}")
    def store_share_revoke(share_id: str, user=Depends(require_auth), db=Depends(sb_dep)):
        """Soft-delete: stamps revoked_at. The row stays so view history survives.
        Idempotent. Ownership filtered by created_by (audit S1); AUTH_DISABLED
        (dev) -> require_auth None -> skip the ownership filter."""
        q = (
            db.table("share_links")
            .update({"revoked_at": datetime.now(timezone.utc).isoformat()})
            .eq("id", share_id)
        )
        if user is not None:
            q = q.eq("created_by", user["id"])
        res = q.execute()
        if not (res.data or []):
            # Row missing OR not owned by caller — surface as 404 either way
            # (don't leak existence to a non-owner).
            raise HTTPException(404, "share link not found")
        return {"ok": True, "id": share_id, "revoked_at": (res.data[0] or {}).get("revoked_at")}

    @router.get("/api/store/shares")
    def store_share_list(
        event_id: int | None = None,
        include_inactive: bool = False,
        limit: int = 50,
        user=Depends(require_auth),
        db=Depends(sb_dep),
    ):
        """List share links, newest first. Filter by event_id when present.
        Ownership filtered by created_by (audit S2); AUTH_DISABLED (dev) skips."""
        q = db.table("share_links").select(
            "id,event_id,filters,note,created_at,expires_at,revoked_at,view_count,last_viewed_at"
        ).order("created_at", desc=True).limit(min(max(limit, 1), 200))
        if user is not None:
            q = q.eq("created_by", user["id"])
        if event_id:
            q = q.eq("event_id", event_id)
        if not include_inactive:
            q = q.is_("revoked_at", "null")
        rows = q.execute().data or []
        shares = [share_to_dict(r) for r in rows]
        if not include_inactive:
            # Filter expired in code — the supabase-py builder is fussy about
            # `is null OR > now`. The page is small (≤ 50) so this is fine.
            shares = [s for s in shares if s["active"]]
        return {"count": len(shares), "shares": shares}

    return router
