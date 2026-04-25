"""Collect TEvo event + stats snapshots for a watchlist of performers and venues.

Usage:
    $env:TEVO_TOKEN  = "..."
    $env:TEVO_SECRET = "..."
    py collect.py

Reads watchlist.json, writes to snapshots.db (SQLite).
Each run INSERTs a new snapshots row per event, giving you a time series.
Run it manually now; put it on a schedule later (Task Scheduler / cron).
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from evo_client import EvoClient

ROOT = Path(__file__).parent
DB_PATH = ROOT / "snapshots.db"
WATCHLIST_PATH = ROOT / "watchlist.json"
PACING_SECONDS = 0.15  # sleep between API calls to be polite

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id                     INTEGER PRIMARY KEY,
    name                   TEXT,
    occurs_at_local        TEXT,
    state                  TEXT,
    venue_id               INTEGER,
    venue_name             TEXT,
    venue_location         TEXT,
    primary_performer_id   INTEGER,
    primary_performer_name TEXT,
    performer_ids_json     TEXT,
    last_seen              TIMESTAMP
);

CREATE TABLE IF NOT EXISTS snapshots (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id            INTEGER NOT NULL,
    captured_at         TIMESTAMP NOT NULL,
    ticket_groups_count INTEGER,
    tickets_count       INTEGER,
    retail_price_min    REAL,
    retail_price_avg    REAL,
    retail_price_max    REAL,
    retail_price_sum    REAL,
    wholesale_price_avg REAL,
    wholesale_price_sum REAL,
    FOREIGN KEY(event_id) REFERENCES events(id)
);
CREATE INDEX IF NOT EXISTS idx_snap_event_time ON snapshots(event_id, captured_at DESC);

CREATE TABLE IF NOT EXISTS watch_sources (
    event_id     INTEGER NOT NULL,
    source_type  TEXT    NOT NULL,   -- 'performer' or 'venue'
    source_id    INTEGER NOT NULL,
    source_label TEXT,
    first_seen   TIMESTAMP NOT NULL,
    PRIMARY KEY (event_id, source_type, source_id)
);

CREATE TABLE IF NOT EXISTS runs (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at       TIMESTAMP NOT NULL,
    finished_at      TIMESTAMP,
    events_collected INTEGER,
    stats_errors     INTEGER
);
"""


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def get_client() -> EvoClient:
    token = os.environ.get("TEVO_TOKEN")
    secret = os.environ.get("TEVO_SECRET")
    if not token or not secret:
        sys.exit("Set TEVO_TOKEN and TEVO_SECRET environment variables.")
    sandbox = os.environ.get("TEVO_SANDBOX", "false").lower() == "true"
    return EvoClient(token, secret, sandbox=sandbox)


def primary_performer(ev: dict) -> tuple[int | None, str | None]:
    for perf in ev.get("performances") or []:
        if perf.get("primary"):
            p = perf.get("performer") or {}
            return p.get("id"), p.get("name")
    return None, None


def all_performer_ids(ev: dict) -> list[int]:
    ids = []
    for perf in ev.get("performances") or []:
        p = perf.get("performer") or {}
        if p.get("id") is not None:
            ids.append(p["id"])
    return ids


def upsert_event(db: sqlite3.Connection, ev: dict, captured_at: str) -> None:
    pid, pname = primary_performer(ev)
    venue = ev.get("venue") or {}
    db.execute(
        """
        INSERT INTO events (
            id, name, occurs_at_local, state,
            venue_id, venue_name, venue_location,
            primary_performer_id, primary_performer_name,
            performer_ids_json, last_seen
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name=excluded.name,
            occurs_at_local=excluded.occurs_at_local,
            state=excluded.state,
            venue_id=excluded.venue_id,
            venue_name=excluded.venue_name,
            venue_location=excluded.venue_location,
            primary_performer_id=excluded.primary_performer_id,
            primary_performer_name=excluded.primary_performer_name,
            performer_ids_json=excluded.performer_ids_json,
            last_seen=excluded.last_seen
        """,
        (
            ev["id"], ev.get("name"), ev.get("occurs_at_local"), ev.get("state"),
            venue.get("id"), venue.get("name"), venue.get("location"),
            pid, pname, json.dumps(all_performer_ids(ev)), captured_at,
        ),
    )


def record_source(db, event_id, src_type, src_id, label, captured_at) -> None:
    db.execute(
        """
        INSERT OR IGNORE INTO watch_sources
            (event_id, source_type, source_id, source_label, first_seen)
        VALUES (?, ?, ?, ?, ?)
        """,
        (event_id, src_type, src_id, label, captured_at),
    )


def insert_snapshot(db, event_id: int, stats: dict, captured_at: str) -> None:
    if not stats:
        return
    db.execute(
        """
        INSERT INTO snapshots (
            event_id, captured_at,
            ticket_groups_count, tickets_count,
            retail_price_min, retail_price_avg, retail_price_max, retail_price_sum,
            wholesale_price_avg, wholesale_price_sum
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            event_id, captured_at,
            stats.get("ticket_groups_count"), stats.get("tickets_count"),
            stats.get("retail_price_min"), stats.get("retail_price_avg"),
            stats.get("retail_price_max"), stats.get("retail_price_sum"),
            stats.get("wholesale_price_avg"), stats.get("wholesale_price_sum"),
        ),
    )


def main() -> None:
    if not WATCHLIST_PATH.exists():
        sys.exit(f"Missing {WATCHLIST_PATH}. Create one — see the template in the repo.")

    cfg = json.loads(WATCHLIST_PATH.read_text(encoding="utf-8"))
    performers = cfg.get("performers", [])
    venues = cfg.get("venues", [])
    if not performers and not venues:
        sys.exit("Watchlist is empty. Add at least one performer or venue.")

    client = get_client()
    db = sqlite3.connect(DB_PATH)
    db.executescript(SCHEMA)

    started_at = now_iso()
    run_cur = db.execute("INSERT INTO runs (started_at) VALUES (?)", (started_at,))
    run_id = run_cur.lastrowid
    db.commit()

    print(f"[{started_at}] collection run {run_id} starting")
    print(f"  watching {len(performers)} performers, {len(venues)} venues")

    # ---------- Phase 1: gather all events, deduped ----------
    by_event: dict[int, dict] = {}
    sources: dict[int, list[tuple[str, int, str]]] = {}

    def add(ev: dict, src_type: str, src_id: int, label: str) -> None:
        eid = ev["id"]
        by_event[eid] = ev
        sources.setdefault(eid, []).append((src_type, src_id, label))

    for p in performers:
        pid = p["id"]
        label = p.get("label") or f"performer {pid}"
        try:
            events = client.search_events_all(
                performer_id=pid,
                only_with_available_tickets=True,
            )
            print(f"    performer {pid:>7} ({label}): {len(events)} events")
            for ev in events:
                add(ev, "performer", pid, label)
            time.sleep(PACING_SECONDS)
        except Exception as e:
            print(f"    performer {pid} ERROR: {e}")

    for v in venues:
        vid = v["id"]
        label = v.get("label") or f"venue {vid}"
        try:
            events = client.search_events_all(
                venue_id=vid,
                only_with_available_tickets=True,
            )
            print(f"    venue     {vid:>7} ({label}): {len(events)} events")
            for ev in events:
                add(ev, "venue", vid, label)
            time.sleep(PACING_SECONDS)
        except Exception as e:
            print(f"    venue {vid} ERROR: {e}")

    total = len(by_event)
    print(f"\n  {total} unique events after dedup")
    if total == 0:
        db.execute(
            "UPDATE runs SET finished_at=?, events_collected=0, stats_errors=0 WHERE id=?",
            (now_iso(), run_id),
        )
        db.commit()
        sys.exit("nothing to snapshot")

    # ---------- Phase 2: stats snapshot per event ----------
    captured_at = now_iso()
    errors = 0

    for i, (eid, ev) in enumerate(by_event.items(), 1):
        upsert_event(db, ev, captured_at)
        for src_type, src_id, label in sources[eid]:
            record_source(db, eid, src_type, src_id, label, captured_at)
        try:
            stats = client.get_event_stats(eid)
            insert_snapshot(db, eid, stats, captured_at)
        except Exception as e:
            errors += 1
            print(f"    stats FAIL event {eid}: {e}")

        if i % 25 == 0:
            db.commit()
            print(f"    {i}/{total} snapshots captured")
        time.sleep(PACING_SECONDS)

    db.commit()
    finished_at = now_iso()
    db.execute(
        "UPDATE runs SET finished_at=?, events_collected=?, stats_errors=? WHERE id=?",
        (finished_at, total, errors, run_id),
    )
    db.commit()
    db.close()

    print(f"\n[{finished_at}] done")
    print(f"  {total} events snapshotted, {errors} stats errors")
    print(f"  database: {DB_PATH}")


if __name__ == "__main__":
    main()
