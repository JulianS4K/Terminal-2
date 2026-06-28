"""Storefront share-link API — create / resolve / revoke / list.

app.py decomposition slice (BR-CODE-1): the four `/api/store/share*` JSON
routes lifted verbatim out of app.py behind unchanged paths. Behavior,
validation, ownership enforcement (audit S1/S2/S4), and the event-end expiry
cap are identical to the prior inline handlers.

Dependencies stay owned by app.py and are resolved at request time via getters
so the test monkeypatches keep working:
  - `get_require_sb()` -> the live `require_sb` callable (tests patch
    `app.require_sb`).
  - `get_resolve_event()` -> the live `_resolve_event_with_filters` (tests patch
    `app._resolve_event_with_filters`).
`require_auth` is passed straight through. The pure filter/serialization
helpers come from core.helpers directly (no test patches them).

The HTML page route `/s/{share_id}` stays in app.py — it serves the storefront
shell, not JSON.
"""
from __future__ import annotations

import logging
import secrets
from datetime import datetime, timedelta, timezone
from typing import Callable

from fastapi import APIRouter, Body, Depends, HTTPException

from core.helpers import normalize_filters, share_to_dict

_log = logging.getLogger("app")


def build_shares_router(
    get_require_sb: Callable[[], Callable],
    require_auth: Callable,
    get_resolve_event: Callable[[], Callable],
) -> APIRouter:
    router = APIRouter()

    @router.post("/api/store/share")
    def store_share_create(payload: dict = Body(...), user=Depends(require_auth)):
        """Create a revocable share link for one event with saved filters.

        Body:
          event_id: int (required)
          filters: { zones, section, min_price, max_price, min_qty } (optional)
          note: str (optional, ≤ 500 chars)
          expires_in_days: int (optional, 1-365; null = never expires)

        Auth: require_auth (Supabase JWT + allowed-domain email).
        """
        # Validate before touching Supabase so 4xx errors surface the real reason
        # instead of "Supabase not configured" when both are wrong.
        try:
            event_id = int(payload.get("event_id") or 0)
        except (TypeError, ValueError):
            raise HTTPException(400, "event_id must be an integer")
        if not event_id:
            raise HTTPException(400, "event_id is required")

        filters = normalize_filters(payload.get("filters") or {})
        # Persist arrays only if non-empty + numeric values only if set, so the
        # JSON stays compact and equivalent to the URL form.
        persisted: dict = {}
        if filters["section"]: persisted["section"] = filters["section"]
        if filters["zones"]:   persisted["zones"]   = filters["zones"]
        if filters["min_price"] is not None: persisted["min_price"] = filters["min_price"]
        if filters["max_price"] is not None: persisted["max_price"] = filters["max_price"]
        if filters["min_qty"]   is not None: persisted["min_qty"]   = filters["min_qty"]

        note = (payload.get("note") or "").strip() or None
        if note and len(note) > 500:
            raise HTTPException(400, "note too long (max 500 chars)")

        # All validation passed — now we need Supabase to persist.
        db = get_require_sb()()

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
        raw_days = payload.get("expires_in_days")
        user_pick: datetime | None = None
        if raw_days not in (None, "", 0):
            try:
                days = int(raw_days)
            except (TypeError, ValueError):
                raise HTTPException(400, "expires_in_days must be an integer")
            if not (1 <= days <= 365):
                raise HTTPException(400, "expires_in_days must be between 1 and 365")
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
    def store_share_resolve(share_id: str):
        """Public endpoint: resolves a share link to its filtered event payload.
        Bumps view_count on every successful read. 410 if revoked or expired."""
        db = get_require_sb()()
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

        detail = get_resolve_event()(int(row["event_id"]), row.get("filters") or {})

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
    def store_share_revoke(share_id: str, user=Depends(require_auth)):
        """Soft-delete: stamps revoked_at. The row stays so view history survives.
        Idempotent. Ownership filtered by created_by (audit S1); AUTH_DISABLED
        (dev) -> require_auth None -> skip the ownership filter."""
        db = get_require_sb()()
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
    ):
        """List share links, newest first. Filter by event_id when present.
        Ownership filtered by created_by (audit S2); AUTH_DISABLED (dev) skips."""
        db = get_require_sb()()
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
