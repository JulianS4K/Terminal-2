"""Canonical-refresh / auto-track kick — extracted from server.py (BR-CODE-1
core/ pass).

`fire_canonical_refresh` is the fire-and-forget kick to the audit lane's
collect-listings Edge Function so canonical SQL stays as fresh as the storefront
sees. Two paths: tracked event -> dedupe-kick by event_id; untracked event ->
add the primary performer to `watchlist` then kick by watchlist_id (the cron
covers it thereafter). Always non-blocking (daemon thread); failures log, never
raise.

All live collaborators (sb, config, fire_collect) are injected by the server
wrapper so the monkeypatches keep binding. `threading` is the same module object
the server uses, so the test patch (app.threading.Thread -> a sync stub) reaches
the daemon spawn here.
"""
from __future__ import annotations

import logging
import threading

_log = logging.getLogger("core.canonical_refresh")


def fire_canonical_refresh(event_id: int, ev: dict, *, sb, supabase_url, cron_secret, fire_collect) -> None:
    """Fire-and-forget kick to the audit lane's collect-listings Edge Function
    so canonical SQL stays as fresh as the storefront sees.

    Lane note: writes to `watchlist` (audit-lane table) using the same insert
    pattern as the existing `/api/watchlist` POST endpoint — the existing API
    surface, not a parallel writer; the unique (kind, ext_id) constraint keeps
    the table consistent. Always non-blocking; failures are logged, never raised.
    """
    if not (sb is not None and supabase_url and cron_secret):
        return  # Best-effort only; missing config silently no-ops.

    def _go():
        try:
            existing = (
                sb.table("events").select("id").eq("id", event_id).limit(1).execute().data
            )
        except Exception as e:
            _log.warning(f"canonical refresh: events lookup failed for {event_id}: {e}")
            return

        if existing:
            url = (
                f"{supabase_url}/functions/v1/collect-listings"
                f"?event_id={event_id}&min_age_seconds=10"
            )
            fire_collect(url, cron_secret)
            return

        # Auto-track path: this event is brand new to us. Add primary
        # performer to watchlist so the cron picks it up going forward.
        performances = ev.get("performances") or []
        primary = next(
            ((p.get("performer") or {}) for p in performances if p.get("primary")),
            ((performances[0].get("performer") or {}) if performances else {}),
        )
        pid = primary.get("id")
        if not pid:
            _log.info(f"auto-track: event {event_id} has no primary performer; skipping")
            return
        pid = int(pid)
        pname = primary.get("name") or f"performer {pid}"

        watchlist_id: int | None = None
        try:
            ins = sb.table("watchlist").insert(
                {"kind": "performer", "ext_id": pid, "label": pname}
            ).execute()
            row = (ins.data or [None])[0]
            if row:
                watchlist_id = row.get("id")
                _log.info(f"auto-track: added performer {pid} ({pname}) to watchlist as id={watchlist_id}")
        except Exception as e:
            msg = str(e)
            if "duplicate" in msg.lower() or "23505" in msg or "unique" in msg.lower():
                # Already in watchlist — find the existing id so we can scope the kick.
                try:
                    found = (
                        sb.table("watchlist").select("id")
                        .eq("kind", "performer").eq("ext_id", pid)
                        .limit(1).execute().data
                    )
                    if found:
                        watchlist_id = found[0]["id"]
                except Exception as e2:
                    _log.warning(f"auto-track: lookup after dup failed: {e2}")
            else:
                _log.warning(f"auto-track: watchlist insert failed for performer {pid}: {e}")

        if watchlist_id:
            url = f"{supabase_url}/functions/v1/collect-listings?watchlist_id={watchlist_id}"
            fire_collect(url, cron_secret)

    threading.Thread(target=_go, daemon=True).start()
