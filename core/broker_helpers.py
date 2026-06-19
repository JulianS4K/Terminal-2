"""DB-touching broker helpers shared by app.py + routers/* (BR-CODE-1 helper pass).

Unlike core/helpers.py (pure), these take a live supabase `db` client as their
first argument and issue read-only queries. They hold no module state and import
nothing from app.py (one-directional: app.py/routers -> core, never reverse), so
they're safe to move out of the monolith incrementally. Moved verbatim from app.py.
"""
from __future__ import annotations

import re
from datetime import datetime, timezone

from core.helpers import classify_playoff, _PLAYOFF_SPECIFIC_RE


def bulk_performer_assets(db, performer_ids: list[int]) -> dict[int, dict]:
    """Fetch performer_metadata for many performer_ids at once. Returns map
    {performer_id: {logo_default_url, color_primary, ...}}. Used by event
    overview to attach home + away logos in a single roundtrip."""
    if not performer_ids:
        return {}
    rows = (db.table("performer_metadata")
              .select("performer_id, name, espn_team_id, espn_league, "
                      "color_primary, color_alternate, logo_default_url, logo_dark_url")
              .in_("performer_id", performer_ids)
              .execute()).data or []
    return {int(r["performer_id"]): r for r in rows}


def bulk_event_context(db, event_ids: list[int]) -> dict[int, dict]:
    """Bulk-fetch all six context dimensions a storefront card / detail page
    might surface, in one helper.

    Returns:
      { event_id: { "rivalry":    {...}|None,
                    "mlb_series": {...}|None,
                    "tournament": {...}|None,
                    "weather":    {...}|None,
                    "holiday":    {...}|None,
                    "playoff":    {...}|None } }

    Backing views (audit / context lanes — P1 reads only):
      rivalry      ← v_rivalry_events             (mig 20260509530000)
      mlb_series   ← v_mlb_game_series            (mig 20260509470000)
      tournament   ← v_event_tournament_context   (mig 20260510010000)
      weather      ← v_event_weather_with_fallback (mig 20260509560000)
      holiday      ← v_event_calendar_context     (mig 20260509550000)
      playoff      ← regex on events.name + performer_metadata series tags

    Weather + holiday + playoff rules are applied here, not in the client, so
    the storefront UI doesn't have to know about climatology vs forecast vs
    severity tiers, or playoff naming conventions — it just renders what
    the server hands it.

    Missing views (per-env) degrade gracefully to None for that key.
    """
    if not event_ids:
        return {}

    ids = [int(e) for e in event_ids if e is not None]
    ctx: dict[int, dict] = {
        eid: {"rivalry": None, "mlb_series": None, "tournament": None,
              "weather": None, "holiday": None, "playoff": None}
        for eid in ids
    }

    # Playoff: read event names + series-tag performer membership in one
    # roundtrip. Series tags like "NBA Finals" / "NBA Eastern Conference
    # Semifinals" attach to the event via performer_ids and give us the
    # most specific label; the name regex covers Round 3 / Game 7 events
    # that don't yet have a series-tag attached.
    try:
        ev_rows = (db.table("events").select("id,name,performer_ids")
                     .in_("id", ids).execute().data) or []
        # Collect all unique non-primary performer ids so we can resolve
        # series-tag names in one query.
        candidate_perf_ids: set[int] = set()
        for er in ev_rows:
            for p in (er.get("performer_ids") or []):
                try:
                    candidate_perf_ids.add(int(p))
                except (TypeError, ValueError):
                    pass
        series_tag_by_id: dict[int, str] = {}
        if candidate_perf_ids:
            try:
                pm_rows = (db.table("performer_metadata")
                             .select("performer_id,name")
                             .in_("performer_id", list(candidate_perf_ids))
                             .execute().data) or []
                for pm in pm_rows:
                    nm = (pm.get("name") or "")
                    # Only keep "series tag" performers — leagues + rounds.
                    if _PLAYOFF_SPECIFIC_RE.search(nm) or re.search(
                        r"\b(NBA|NHL|NFL|MLB|MLS|WNBA)\s+(Playoffs?|Postseason|"
                        r"Wild\s+Card|Finals?|Semifinals?|Championship|"
                        r"Conference)\b",
                        nm, re.IGNORECASE,
                    ):
                        series_tag_by_id[int(pm["performer_id"])] = nm
            except Exception:
                series_tag_by_id = {}
        for er in ev_rows:
            eid = int(er.get("id") or 0)
            if eid not in ctx:
                continue
            # Prefer the most-specific series-tag performer if attached.
            tagged: str | None = None
            for p in (er.get("performer_ids") or []):
                try:
                    pid = int(p)
                except (TypeError, ValueError):
                    continue
                name = series_tag_by_id.get(pid)
                if not name:
                    continue
                # Specific (e.g. "NBA Finals") beats generic ("NBA Playoffs").
                if _PLAYOFF_SPECIFIC_RE.search(name):
                    tagged = name
                    break
                if tagged is None:
                    tagged = name
            if tagged:
                # Strip umbrella "Playoffs" / "Postseason" when we have a
                # more specific round-tag handy.
                kind = "specific" if _PLAYOFF_SPECIFIC_RE.search(tagged) else "generic"
                ctx[eid]["playoff"] = {"label": tagged, "kind": kind}
                continue
            # Fall back to regex on the event name.
            ctx[eid]["playoff"] = classify_playoff(er.get("name"))
    except Exception:
        pass

    # Rivalry: v_rivalry_events can emit duplicate rows when both the
    # performer-id and name joins match the same matchup, so dedup at the
    # event id level (first row wins; intensity is the same either way).
    try:
        rows = (db.table("v_rivalry_events")
                  .select("tevo_event_id,rivalry_name,league,is_branded,"
                          "rivalry_intensity,wikipedia_url")
                  .in_("tevo_event_id", ids)
                  .execute()).data or []
        seen: set[int] = set()
        for r in rows:
            eid = int(r["tevo_event_id"])
            if eid in seen or eid not in ctx:
                continue
            seen.add(eid)
            ctx[eid]["rivalry"] = {
                "name": r.get("rivalry_name"),
                "league": r.get("league"),
                "is_branded": bool(r.get("is_branded")),
                "intensity": r.get("rivalry_intensity"),
                "wikipedia_url": r.get("wikipedia_url"),
            }
    except Exception:
        pass

    # MLB series: v_mlb_game_series rows hold the full tevo_event_ids array
    # for the series. Pull every series whose end-date is today or later, then
    # walk the array to attach the series context to each game in the set,
    # adding game_number (1-based position within the series).
    try:
        today_iso = datetime.now(timezone.utc).date().isoformat()
        rows = (db.table("v_mlb_game_series")
                  .select("home_team,away_team,venue_name,series_start,series_end,"
                          "series_span_days,game_count,tevo_event_ids,branded_series_name")
                  .gte("series_end", today_iso)
                  .execute()).data or []
        for r in rows:
            tevo_ids = r.get("tevo_event_ids") or []
            tevo_ids = [int(e) for e in tevo_ids if e is not None]
            for pos, eid in enumerate(tevo_ids, start=1):
                if eid not in ctx:
                    continue
                ctx[eid]["mlb_series"] = {
                    "home_team": r.get("home_team"),
                    "away_team": r.get("away_team"),
                    "venue_name": r.get("venue_name"),
                    "series_start": r.get("series_start"),
                    "series_end": r.get("series_end"),
                    "span_days": r.get("series_span_days"),
                    "game_count": r.get("game_count"),
                    "branded_name": r.get("branded_series_name"),
                    "sibling_event_ids": tevo_ids,
                    "game_number": pos,
                }
    except Exception:
        pass

    # Tournament: one row per TEvo event in v_event_tournament_context (left
    # join on event_xref + espn_tournament_events). Surfaces a multi-day
    # parent so "Round 2 of US Open · Aug 26 – Sep 8" can render.
    try:
        rows = (db.table("v_event_tournament_context")
                  .select("tevo_event_id,tournament_name,tournament_short_name,"
                          "tournament_start,tournament_end,tournament_venue,"
                          "espn_league,circuit_name")
                  .in_("tevo_event_id", ids)
                  .execute()).data or []
        for r in rows:
            eid = int(r["tevo_event_id"])
            if eid not in ctx:
                continue
            ctx[eid]["tournament"] = {
                "name": r.get("tournament_name"),
                "short_name": r.get("tournament_short_name"),
                "start_date": r.get("tournament_start"),
                "end_date": r.get("tournament_end"),
                "venue": r.get("tournament_venue"),
                "league": r.get("espn_league"),
                "circuit_name": r.get("circuit_name"),
            }
    except Exception:
        pass

    # Weather: v_event_weather_with_fallback has fallback-coalesced + raw
    # forecast/climatology columns + NWS alert JSON. Apply display rules
    # server-side so the client just renders what's set:
    #   - indoor + no alert       → None (hide)
    #   - any venue + active NWS  → alert (always shows up to 16d)
    #   - outdoor + ≤7d forecast  → full forecast
    #   - outdoor 8-16d + alert   → alert only
    #   - otherwise               → None
    try:
        rows = (db.table("v_event_weather_with_fallback")
                  .select("tevo_event_id,days_to_event,weather_kind,is_indoor,"
                          "fcst_temp_f,fcst_precip_pct,fcst_precip_in,"
                          "fcst_wind_mph,fcst_gust_mph,fcst_summary,"
                          "weather_alerts")
                  .in_("tevo_event_id", ids)
                  .execute()).data or []
        for r in rows:
            eid = int(r["tevo_event_id"])
            if eid not in ctx:
                continue
            days = r.get("days_to_event")
            if days is None or days > 16 or days < 0:
                continue  # too far out or past
            alerts = r.get("weather_alerts") or []
            kind = r.get("weather_kind") or ""
            is_indoor = bool(r.get("is_indoor"))

            # Slim NWS alerts down to fields the UI actually shows.
            slim_alerts = []
            for a in alerts[:3]:  # cap at 3 — anything more is noise
                slim_alerts.append({
                    "event": a.get("event"),
                    "severity": a.get("severity"),
                    "impact_tier": a.get("impact_tier"),
                    "headline": a.get("headline"),
                    "expires_at": a.get("expires_at"),
                })

            has_alert = bool(slim_alerts)
            show_forecast = (
                not is_indoor
                and kind.startswith("forecast_outdoor")
                and days <= 7
                and r.get("fcst_temp_f") is not None
            )

            if not has_alert and not show_forecast:
                continue  # nothing worth showing

            w: dict = {
                "days_to_event": days,
                "is_indoor": is_indoor,
                "alerts": slim_alerts,
            }
            if show_forecast:
                w["forecast"] = {
                    "temp_f": r.get("fcst_temp_f"),
                    "summary": r.get("fcst_summary"),
                    "precip_pct": r.get("fcst_precip_pct"),
                    "precip_in": r.get("fcst_precip_in"),
                    "wind_mph": r.get("fcst_wind_mph"),
                    "gust_mph": r.get("fcst_gust_mph"),
                }
            ctx[eid]["weather"] = w
    except Exception:
        pass

    # Holiday: v_event_calendar_context returns JSON arrays of holidays
    # on/near the event date + active school breaks, each with precision
    # (national/state/city) and impact (boost/neutral). Pick the single
    # most-relevant pill to show — day-of beats nearby, city beats state
    # beats national, "boost" beats "neutral".
    try:
        rows = (db.table("v_event_calendar_context")
                  .select("tevo_event_id,event_date,is_holiday,"
                          "within_holiday_window,school_break_active,"
                          "holidays_today,holidays_nearby,school_breaks_active")
                  .in_("tevo_event_id", ids)
                  .execute()).data or []

        def _precision_rank(p: str) -> int:
            return {"city": 0, "state": 1, "national": 2}.get(p or "national", 3)

        for r in rows:
            eid = int(r["tevo_event_id"])
            if eid not in ctx:
                continue

            today = r.get("holidays_today") or []
            nearby = r.get("holidays_nearby") or []
            breaks = r.get("school_breaks_active") or []

            best: dict | None = None

            # Day-of holiday: any precision, boost wins over neutral.
            if today:
                today_sorted = sorted(
                    today,
                    key=lambda h: (
                        0 if h.get("impact") == "boost" else 1,
                        _precision_rank(h.get("precision")),
                    ),
                )
                h = today_sorted[0]
                best = {
                    "kind": "day_of",
                    "label": h.get("name"),
                    "impact": h.get("impact"),
                    "precision": h.get("precision"),
                    "date": r.get("event_date"),
                }

            # Nearby (±1 day) — only show if no day-of beat us.
            if best is None and nearby:
                nearby_sorted = sorted(
                    nearby,
                    key=lambda h: (
                        0 if h.get("impact") == "boost" else 1,
                        _precision_rank(h.get("precision")),
                        abs(int(h.get("days_offset") or 0)),
                    ),
                )
                h = nearby_sorted[0]
                offset = int(h.get("days_offset") or 0)
                suffix = " weekend" if abs(offset) == 1 else ""
                best = {
                    "kind": "nearby",
                    "label": (h.get("name") or "") + suffix,
                    "impact": h.get("impact"),
                    "precision": h.get("precision"),
                    "date": h.get("date"),
                    "days_offset": offset,
                }

            # School break — only summer/winter (the only ones that meaningfully
            # boost attendance for weekday games). Otherwise we'd label half
            # the calendar with spring/fall breaks that don't move pricing.
            if best is None and breaks:
                summer_winter = [
                    b for b in breaks
                    if any(k in (b.get("name") or "").lower()
                           for k in ("summer", "winter"))
                ]
                if summer_winter:
                    summer_winter.sort(key=lambda b: _precision_rank(b.get("precision")))
                    b = summer_winter[0]
                    best = {
                        "kind": "school_break",
                        "label": b.get("name"),
                        "impact": "boost",
                        "precision": b.get("precision"),
                        "start_date": b.get("start_date"),
                        "end_date": b.get("end_date"),
                    }

            if best is not None:
                ctx[eid]["holiday"] = best
    except Exception:
        pass

    return ctx
