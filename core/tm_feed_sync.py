"""Load Ticketmaster's Discovery Feed into the database (operator 2026-11-22: "Redesign tm polling
using this new data so we don't waste tokens").

One run:
  1. `tm_feed_check()` asks Ticketmaster which feed files exist (one call, made in the database
     where the key lives) and leases, per country (US, CA), the newest file if we have not loaded
     it. Most runs end here: the files are rebuilt about once a day.
  2. For each leased file: download it (tm_feed_client, no key), send its rows in batches to
     `tm_feed_load()`, then `tm_feed_loaded()` with the count. The database writes only rows that
     are new or changed and refuses a file whose count does not match the file list.
  3. The hourly `tm_discovery_tick()` then brings `tm_discovery_event` up to date (`tm_feed_apply()`).

This module makes no upstream call itself (RULE 2): the file list is a GET in SQL, the download is a
GET in tm_feed_client.py. Mig 20261122030530.
"""
from __future__ import annotations

import contextlib
import os
from typing import Any, Callable

Rpc = Callable[[str, dict], Any]
BATCH = 1000


def _send(rpc: Rpc, file: dict, batch: list) -> int:
    rpc("tm_feed_load", {"p_country": file["country"], "p_file_at": file["file_at"], "p_rows": batch})
    return len(batch)


def run(rpc: Rpc, client: Any, workdir: str) -> dict:
    """One run; returns what it did. An error in a file is raised to the caller: the lease on that
    file runs out by itself and the next run takes it again, three times at most."""
    plan = rpc("tm_feed_check", {}) or {}
    files = plan.get("files") or []
    if not files:
        return {"action": "idle", "skipped": plan.get("skipped")}
    done = []
    for file in files:
        path = os.path.join(workdir, f"tm_feed_{file['country']}.csv.gz")
        try:
            size = client.download(file["uri"], path, file.get("md5"))
            sent, batch = 0, []
            for row in client.rows(path):
                batch.append(row)
                if len(batch) >= BATCH:
                    sent += _send(rpc, file, batch)
                    batch = []
            if batch:
                sent += _send(rpc, file, batch)
            checked = rpc("tm_feed_loaded", {"p_country": file["country"], "p_file_at": file["file_at"],
                                             "p_rows_sent": sent}) or {}
            done.append({"country": file["country"], "file_at": file["file_at"], "bytes": size, "rows": sent, **checked})
        finally:
            with contextlib.suppress(FileNotFoundError):      # a download that failed wrote no file
                os.remove(path)
    return {"action": "loaded", "files": done}
