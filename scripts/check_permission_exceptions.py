#!/usr/bin/env python3
"""Permission-exceptions ledger gate (PROJECT_BIBLE §2.2).

The only home for a permission deviation from the §2.1 principals is
`.github/permission-exceptions.yml`, and every entry carries a `review_by` date.
This gate FAILS the build when an entry is malformed or its `review_by` has
passed — so an exception cannot silently become permanent. It is either renewed
(deliberately, by re-approving and bumping the date) or it turns the build red
and is removed. A review date only means something if a machine reads it.

Exit codes:
  0  clean   — ledger empty, or every entry well-formed and unexpired
  1  violation — an expired or malformed entry (CI should fail the PR)
  2  config error — file missing / unparseable / bad top-level shape

Usage:
  python scripts/check_permission_exceptions.py [path-to-yaml]
  (default path: .github/permission-exceptions.yml at the repo root)
"""
from __future__ import annotations

import datetime
import pathlib
import sys

REQUIRED = ("id", "grants", "to", "rationale", "granted", "review_by")
PRINCIPALS = ("Applier", "Auditor", "Builder")
WARN_WINDOW_DAYS = 14


def _config_error(msg: str) -> "int":
    print(f"ERROR (config): {msg}", file=sys.stderr)
    return 2


def _as_date(value):
    """Return a date for a YAML date or an ISO string, else None."""
    if isinstance(value, datetime.date):
        return value
    try:
        return datetime.date.fromisoformat(str(value))
    except ValueError:
        return None


def main(argv) -> int:
    repo_root = pathlib.Path(__file__).resolve().parents[1]
    path = (
        pathlib.Path(argv[1])
        if len(argv) > 1
        else repo_root / ".github" / "permission-exceptions.yml"
    )

    if not path.exists():
        return _config_error(f"{path} not found")

    try:
        import yaml
    except ImportError:
        return _config_error("PyYAML not available (pip install pyyaml)")

    try:
        # ValueError too: PyYAML raises it at load time for an impossible native
        # date (e.g. 2026-13-40 matches the timestamp pattern, then fails to
        # construct) — catch it here rather than let it escape as a traceback.
        data = yaml.safe_load(path.read_text()) or {}
    except (yaml.YAMLError, ValueError) as exc:
        return _config_error(f"could not parse {path}: {exc}")

    if not isinstance(data, dict) or "exceptions" not in data:
        return _config_error(
            "top-level `exceptions:` key required (use `exceptions: []` when none)"
        )

    entries = data["exceptions"] or []
    if not isinstance(entries, list):
        return _config_error("`exceptions` must be a list")

    if not entries:
        print("✅ permission-exceptions ledger is empty — no deviations from §2.1.")
        return 0

    today = datetime.date.today()
    errors: list[str] = []
    warnings: list[str] = []
    seen_ids: set[str] = set()

    for i, entry in enumerate(entries):
        tag = f"entry #{i + 1}"
        if not isinstance(entry, dict):
            errors.append(f"{tag}: must be a mapping")
            continue

        eid = entry.get("id")
        tag = f"exception '{eid}'" if eid else tag

        for key in REQUIRED:
            if entry.get(key) in (None, ""):
                errors.append(f"{tag}: missing required field `{key}`")

        if eid:
            if eid in seen_ids:
                errors.append(f"{tag}: duplicate id")
            seen_ids.add(eid)

        grants = entry.get("grants")
        if grants and grants not in PRINCIPALS:
            errors.append(f"{tag}: grants='{grants}' not one of {PRINCIPALS}")

        for field in ("granted", "review_by"):
            val = entry.get(field)
            if val in (None, ""):
                continue  # already reported as missing
            if _as_date(val) is None:
                errors.append(f"{tag}: `{field}`='{val}' is not a YYYY-MM-DD date")

        review_by = _as_date(entry.get("review_by"))
        if review_by is not None:
            if review_by < today:
                errors.append(
                    f"{tag}: EXPIRED — review_by {review_by} < today {today}. "
                    f"Renew (re-approve and bump the date) or delete the entry."
                )
            elif (review_by - today).days <= WARN_WINDOW_DAYS:
                warnings.append(
                    f"{tag}: review_by {review_by} is within {WARN_WINDOW_DAYS} "
                    f"days — review soon."
                )

    for warning in warnings:
        print(f"::warning::{warning}")

    if errors:
        print("❌ permission-exceptions ledger has violations:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print(
        f"✅ {len(entries)} permission exception(s) — all well-formed and unexpired."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
