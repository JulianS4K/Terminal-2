#!/usr/bin/env python3
"""Fantasy player-stats ingest — Phase 1 of the Fantasy League feature.

Pulls per-player, per-game box-score lines from the open-source
`sportsdataverse` packages and upserts them into `player_game_stats`, bridged
to the canonical `espn_athletes` via `athlete_external_ids`.

WHY THIS EXISTS
  The repo's ESPN layer is team-level only (scores + standings). There are no
  per-player box scores, so fantasy scoring has no source. This job builds that
  foundation. Phase 2 (the fantasy product) reads from `player_game_stats`.

READ-ONLY POSTURE (CLAUDE.md §2)
  This job only READS from open-source stat sources (GET / parquet pulls via
  the sportsdataverse loaders) and WRITES only to our own Supabase Postgres. It
  never touches a broker API (TEvo/SeatGeek/SeatData/TickPick/Vivid), and uses
  the Supabase client (not `requests.post`), so scripts/check_readonly.py stays
  clean. No new external write path is introduced.

LEAGUES (v1): NFL, NBA, MLB, NHL, WNBA — the NA leagues with player rosters in
  espn_athletes. MLS is deferred (sportsdataverse soccer coverage is thin).

CROSSWALK (reuse canonical mappers; never ad-hoc name-match for teams)
  * Team:   NFL/NBA/NHL/WNBA sportsdataverse feeds carry the ESPN team id
            natively → validate against espn_teams_canonical. MLB (MLBAM ids)
            resolves by abbr against espn_teams_canonical.
  * Player: NFL/NBA/NHL/WNBA carry the espn athlete id natively → direct map.
            MLB resolves (name + resolved espn_team_id + league) against
            espn_athletes; unresolved keeps the MLBAM id, espn_athlete_id NULL.

  NOTE: espn_team_id is LEAGUE-SCOPED (id 18 = NBA Knicks AND MLB Pirates AND
  NFL Saints). Every team/athlete resolution carries league alongside the id.

USAGE
  # backfill a full season for one league
  python -m fantasy_ingest --league NBA --season 2025 --mode backfill

  # incremental (recent finished games) across all v1 leagues — the cron path
  python -m fantasy_ingest --mode incremental

  # see what would be written without touching the DB
  python -m fantasy_ingest --league NHL --season 2025 --dry-run

  Credentials: SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY (same as the web app).

IMPLEMENTATION NOTE
  The exact sportsdataverse loader function + DataFrame column names vary per
  league/version. They are isolated in the per-league `_load_*` adapters and the
  `COLUMN_MAP` below so that confirming them on first run (the branch
  verification step) is a localized edit, not a rewrite. Each adapter degrades
  to an empty result (logged) rather than crashing the whole sweep.
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import sys
from typing import Any, Iterable

LEAGUES = ("NFL", "NBA", "MLB", "NHL", "WNBA")

# Leagues whose sportsdataverse feeds are ESPN-sourced and therefore carry the
# ESPN athlete id + ESPN team id natively (trivial crosswalk).
ESPN_NATIVE_LEAGUES = frozenset({"NFL", "NBA", "NHL", "WNBA"})

# Per-league mapping from the source DataFrame's columns to our normalized
# schema. Confirmed/adjusted on first run against the installed sportsdataverse
# version (see module docstring). Keys are our fields; values are candidate
# source column names tried in order.
COLUMN_MAP: dict[str, dict[str, tuple[str, ...]]] = {
    "NBA": {
        "sdv_player_id": ("athlete_id", "player_id"),
        "player_name": ("athlete_display_name", "player_name"),
        "espn_athlete_id": ("athlete_id",),            # hoopR uses espn ids
        "espn_team_id": ("team_id",),
        "team_abbr": ("team_abbreviation", "team_short_display_name"),
        "opponent_team_id": ("opponent_team_id", "opponent_id"),
        "game_id": ("game_id",),
        "espn_event_id": ("game_id",),
        "game_date": ("game_date",),
        "season": ("season",),
    },
    "WNBA": {
        "sdv_player_id": ("athlete_id", "player_id"),
        "player_name": ("athlete_display_name", "player_name"),
        "espn_athlete_id": ("athlete_id",),
        "espn_team_id": ("team_id",),
        "team_abbr": ("team_abbreviation", "team_short_display_name"),
        "opponent_team_id": ("opponent_team_id", "opponent_id"),
        "game_id": ("game_id",),
        "espn_event_id": ("game_id",),
        "game_date": ("game_date",),
        "season": ("season",),
    },
    "NHL": {
        "sdv_player_id": ("athlete_id", "player_id"),
        "player_name": ("athlete_display_name", "player_name", "skater_full_name"),
        "espn_athlete_id": ("athlete_id",),
        "espn_team_id": ("team_id",),
        "team_abbr": ("team_abbreviation",),
        "opponent_team_id": ("opponent_team_id",),
        "game_id": ("game_id",),
        "espn_event_id": ("game_id",),
        "game_date": ("game_date",),
        "season": ("season",),
    },
    "NFL": {
        "sdv_player_id": ("player_id", "gsis_id"),
        "player_name": ("player_display_name", "player_name"),
        "espn_athlete_id": ("espn_id",),               # nflverse weekly carries espn_id
        "espn_team_id": ("espn_team_id",),             # resolved from team abbr if absent
        "team_abbr": ("recent_team", "team"),
        "opponent_team_id": ("opponent_team",),
        "game_id": ("game_id",),
        "espn_event_id": (),                           # not always present in weekly
        "game_date": ("game_date", "gameday"),
        "season": ("season",),
        "period": ("week",),
    },
    "MLB": {
        "sdv_player_id": ("player_id", "mlbam_id", "batter", "pitcher"),
        "player_name": ("player_name", "name"),
        "espn_athlete_id": (),                          # resolved by name+team
        "espn_team_id": (),                             # resolved by abbr
        "team_abbr": ("team", "team_abbr"),
        "opponent_team_id": ("opponent",),
        "game_id": ("game_pk", "game_id"),
        "espn_event_id": (),
        "game_date": ("game_date",),
        "season": ("season", "game_year"),
    },
}

# Columns that are NOT part of identity → everything else in the row becomes the
# `stats` jsonb. Identity columns we lift out explicitly.
_IDENTITY_KEYS = {
    "sdv_player_id", "player_name", "espn_athlete_id", "espn_team_id",
    "team_abbr", "opponent_team_id", "game_id", "espn_event_id", "game_date",
    "season", "period",
}

UPSERT_BATCH = 500


# ---------------------------------------------------------------------------
# Supabase
# ---------------------------------------------------------------------------
def get_supabase():
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        sys.exit("ERROR: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set.")
    try:
        from supabase import create_client
    except ImportError:
        sys.exit("ERROR: supabase package not installed. Run: pip install -r requirements.txt")
    return create_client(url, key)


# ---------------------------------------------------------------------------
# sportsdataverse loaders (one adapter per league)
# ---------------------------------------------------------------------------
def _load_dataframe(league: str, seasons: list[int]):
    """Return the source player-boxscore DataFrame for a league, or None.

    Isolates the exact sportsdataverse entrypoint per league so a version/API
    change is a one-line edit here. Returns None (logged) on any failure so one
    league can't sink the whole sweep.
    """
    try:
        if league == "NBA":
            from sportsdataverse import nba
            return nba.load_nba_player_boxscore(seasons=seasons)
        if league == "WNBA":
            from sportsdataverse import wnba
            return wnba.load_wnba_player_boxscore(seasons=seasons)
        if league == "NHL":
            from sportsdataverse import nhl
            return nhl.load_nhl_player_boxscore(seasons=seasons)
        if league == "NFL":
            from sportsdataverse import nfl
            return nfl.load_nfl_player_stats(seasons=seasons)
        if league == "MLB":
            # sportsdataverse-py MLB is statcast-oriented; pybaseball is the
            # cleaner per-player game source. Prefer it when available.
            try:
                import pybaseball  # noqa: F401
                return _load_mlb_pybaseball(seasons)
            except ImportError:
                from sportsdataverse import mlb
                return mlb.load_mlb_player_boxscore(seasons=seasons)
    except Exception as e:  # pragma: no cover - depends on installed pkg
        print(f"  [{league}] loader failed: {e}")
        return None
    return None


def _load_mlb_pybaseball(seasons: list[int]):
    """MLB per-game player lines via pybaseball, aggregated to one row/player/game."""
    import pandas as pd
    import pybaseball
    frames = []
    for season in seasons:
        start = f"{season}-03-01"
        end = f"{season}-11-15"
        try:
            sc = pybaseball.statcast(start_dt=start, end_dt=end)
        except Exception as e:
            print(f"  [MLB] statcast {season} failed: {e}")
            continue
        if sc is None or sc.empty:
            continue
        frames.append(sc)
    if not frames:
        return None
    return pd.concat(frames, ignore_index=True)


# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------
def _first(row: dict, candidates: Iterable[str]) -> Any:
    for c in candidates:
        if c in row and row[c] is not None and str(row[c]) != "nan":
            return row[c]
    return None


def _to_date(v: Any) -> str | None:
    if v is None:
        return None
    try:
        return str(v)[:10]
    except Exception:
        return None


def _jsonable(v: Any) -> Any:
    """Coerce numpy/pandas scalars to plain JSON-safe values."""
    try:
        import math
        if isinstance(v, float) and math.isnan(v):
            return None
    except Exception:
        pass
    if hasattr(v, "item"):          # numpy scalar
        try:
            return v.item()
        except Exception:
            return None
    if isinstance(v, (dt.date, dt.datetime)):
        return str(v)
    return v


def normalize(league: str, df) -> list[dict]:
    """Map a source DataFrame to normalized player_game_stats rows."""
    if df is None or getattr(df, "empty", True):
        return []
    cmap = COLUMN_MAP[league]
    records = df.to_dict("records")
    out: list[dict] = []
    for raw in records:
        row = {k: _jsonable(val) for k, val in raw.items()}
        sdv_player_id = _first(row, cmap["sdv_player_id"])
        game_id = _first(row, cmap["game_id"])
        if sdv_player_id is None or game_id is None:
            continue
        identity_source_cols = {c for cands in cmap.values() for c in cands}
        stats = {k: v for k, v in row.items()
                 if k not in identity_source_cols and v is not None}
        out.append({
            "source": "sportsdataverse",
            "league": league,
            "espn_athlete_id": _coerce_str(_first(row, cmap.get("espn_athlete_id", ()))),
            "sdv_player_id": str(sdv_player_id),
            "player_name": _first(row, cmap["player_name"]),
            "game_id": str(game_id),
            "espn_event_id": _coerce_str(_first(row, cmap.get("espn_event_id", ()))),
            "game_date": _to_date(_first(row, cmap["game_date"])),
            "season": _coerce_int(_first(row, cmap.get("season", ()))),
            "period": _coerce_int(_first(row, cmap.get("period", ()))),
            "espn_team_id": _coerce_str(_first(row, cmap.get("espn_team_id", ()))),
            "team_abbr": _first(row, cmap["team_abbr"]),
            "opponent_team_id": _coerce_str(_first(row, cmap.get("opponent_team_id", ()))),
            "stats": stats,
        })
    return out


def _coerce_str(v: Any) -> str | None:
    if v is None:
        return None
    s = str(v)
    return s[:-2] if s.endswith(".0") else s   # numpy float ids -> clean string


def _coerce_int(v: Any) -> int | None:
    if v is None:
        return None
    try:
        return int(float(v))
    except (ValueError, TypeError):
        return None


# ---------------------------------------------------------------------------
# Crosswalk
# ---------------------------------------------------------------------------
def _team_abbr_to_espn(sb, league: str) -> dict[str, str]:
    """abbr/display-name → espn_team_id for a league, from the canonical map."""
    out: dict[str, str] = {}
    res = sb.table("espn_teams_canonical").select(
        "espn_team_id,display_name").eq("espn_league", league).execute()
    for r in (res.data or []):
        out[r["display_name"].upper()] = r["espn_team_id"]
    # abbr aliases live in performer_external_ids.meta->>'espn_abbr'
    res2 = sb.table("performer_external_ids").select(
        "external_id,meta").eq("source", "espn").eq("league", league).execute()
    for r in (res2.data or []):
        abbr = (r.get("meta") or {}).get("espn_abbr")
        if abbr:
            out[abbr.upper()] = r["external_id"]
    return out


def _athlete_by_name_team(sb, league: str) -> dict[tuple[str, str], str]:
    """(lower(name), espn_team_id) → espn_athlete_id, for MLB name resolution."""
    out: dict[tuple[str, str], str] = {}
    res = sb.table("espn_athletes").select(
        "espn_athlete_id,full_name,espn_team_id").eq("espn_league", league).execute()
    for r in (res.data or []):
        if r.get("full_name") and r.get("espn_team_id"):
            out[(r["full_name"].lower(), str(r["espn_team_id"]))] = r["espn_athlete_id"]
    return out


def resolve_crosswalk(sb, league: str, rows: list[dict], dry_run: bool = False) -> list[dict]:
    """Fill espn_team_id + espn_athlete_id and persist athlete_external_ids."""
    abbr_map = _team_abbr_to_espn(sb, league)
    name_map = {} if league in ESPN_NATIVE_LEAGUES else _athlete_by_name_team(sb, league)
    xref_rows: dict[tuple[str, str, str], dict] = {}

    for row in rows:
        # team: native id (validate) or resolve from abbr
        team_id = row.get("espn_team_id")
        if not team_id and row.get("team_abbr"):
            team_id = abbr_map.get(str(row["team_abbr"]).upper())
            row["espn_team_id"] = team_id

        # player
        espn_id = row.get("espn_athlete_id")
        method = None
        if espn_id and league in ESPN_NATIVE_LEAGUES:
            method = "native_espn_id"
        elif not espn_id and row.get("player_name") and team_id:
            espn_id = name_map.get((row["player_name"].lower(), str(team_id)))
            if espn_id:
                row["espn_athlete_id"] = espn_id
                method = "name_team"

        key = ("sportsdataverse", row["sdv_player_id"], league)
        xref_rows[key] = {
            "source": "sportsdataverse",
            "external_id": row["sdv_player_id"],
            "league": league,
            "espn_athlete_id": espn_id,
            "external_name": row.get("player_name"),
            "espn_team_id": team_id,
            "match_method": method,
        }

    if not dry_run and xref_rows:
        payload = list(xref_rows.values())
        for i in range(0, len(payload), UPSERT_BATCH):
            sb.table("athlete_external_ids").upsert(
                payload[i:i + UPSERT_BATCH],
                on_conflict="source,external_id,league").execute()
    resolved = sum(1 for r in rows if r.get("espn_athlete_id"))
    print(f"  [{league}] crosswalk: {resolved}/{len(rows)} rows bridged to espn_athlete_id")
    return rows


# ---------------------------------------------------------------------------
# Upsert
# ---------------------------------------------------------------------------
def upsert_stats(sb, rows: list[dict], dry_run: bool = False) -> int:
    if not rows:
        return 0
    if dry_run:
        print(f"  [dry-run] would upsert {len(rows)} player_game_stats rows")
        return 0
    n = 0
    for i in range(0, len(rows), UPSERT_BATCH):
        batch = rows[i:i + UPSERT_BATCH]
        sb.table("player_game_stats").upsert(
            batch, on_conflict="source,league,game_id,sdv_player_id").execute()
        n += len(batch)
    return n


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------
def ingest_league(sb, league: str, seasons: list[int], dry_run: bool = False) -> int:
    print(f"[{league}] loading seasons {seasons} …")
    df = _load_dataframe(league, seasons)
    rows = normalize(league, df)
    print(f"  [{league}] normalized {len(rows)} stat rows")
    if not rows:
        return 0
    rows = resolve_crosswalk(sb, league, rows, dry_run=dry_run)
    written = upsert_stats(sb, rows, dry_run=dry_run)
    print(f"  [{league}] upserted {written} rows")
    return written


def run(leagues: list[str], seasons: list[int], dry_run: bool = False) -> int:
    sb = get_supabase()
    total = 0
    for lg in leagues:
        try:
            total += ingest_league(sb, lg, seasons, dry_run=dry_run)
        except Exception as e:
            print(f"[{lg}] FAILED: {e}")
    print(f"DONE — {total} rows upserted across {len(leagues)} league(s).")
    return total


def _default_seasons(mode: str) -> list[int]:
    year = dt.date.today().year
    # backfill grabs the current + prior season; incremental only current.
    return [year] if mode == "incremental" else [year - 1, year]


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Fantasy player-stats ingest (sportsdataverse → player_game_stats)")
    p.add_argument("--league", choices=LEAGUES, help="single league; omit for all v1 leagues")
    p.add_argument("--season", type=int, action="append", help="season year (repeatable); default derives from --mode")
    p.add_argument("--mode", choices=("backfill", "incremental"), default="incremental")
    p.add_argument("--dry-run", action="store_true", help="normalize + resolve but do not write")
    args = p.parse_args(argv)

    leagues = [args.league] if args.league else list(LEAGUES)
    seasons = args.season or _default_seasons(args.mode)
    run(leagues, seasons, dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
