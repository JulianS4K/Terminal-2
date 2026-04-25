# ============================================================
# Add this block to app.py, near the other protected routes.
# It exposes time-series data for the event detail chart.
# ============================================================

from datetime import datetime, timedelta, timezone


@app.get("/api/events/{event_id}/series")
def event_series(
    event_id: int,
    days: int = 30,
    _=Depends(require_auth),
):
    """Return time-series metrics for one event.

    Query params:
        days: lookback window in days (default 30)

    Response shape:
        {
          "event_id": 12345,
          "series": [
            {
              "t": "2026-04-23T14:00:00Z",
              "tickets_count": 1990, "groups_count": 626,
              "retail_min": 39.0, "retail_median": 420.0, "retail_mean": 945.12,
              "retail_p25": 180.0, "retail_p75": 1200.0, "retail_p90": 2500.0,
              "retail_max": 9245.0, "wholesale_median": 315.0, "wholesale_mean": 720.0,
              "getin_price": 78.0, "top5_concentration": 0.62, "bid_ask_proxy": 0.22
            },
            ...
          ]
        }
    """
    db = require_sb()
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    resp = (
        db.table("event_metrics")
        .select(
            "captured_at,"
            "tickets_count,groups_count,sections_count,"
            "retail_min,retail_p25,retail_median,retail_mean,retail_p75,retail_p90,retail_max,"
            "wholesale_median,wholesale_mean,"
            "getin_price,top5_concentration,bid_ask_proxy"
        )
        .eq("event_id", event_id)
        .gte("captured_at", since)
        .order("captured_at")
        .execute()
    )
    series = [{"t": r["captured_at"], **{k: v for k, v in r.items() if k != "captured_at"}}
              for r in (resp.data or [])]
    return {"event_id": event_id, "days": days, "series": series}


@app.get("/api/events/{event_id}/sections/series")
def event_section_series(
    event_id: int,
    days: int = 30,
    _=Depends(require_auth),
):
    """Section-level time series for one event. One series per section.

    Response shape:
        {
          "event_id": 12345,
          "sections": [
            {
              "section": "100",
              "is_ancillary": false,
              "points": [
                {"t": "...", "tickets_count": 42, "retail_median": 520.0, ...},
                ...
              ]
            },
            ...
          ]
        }
    """
    db = require_sb()
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    resp = (
        db.table("section_metrics")
        .select("*")
        .eq("event_id", event_id)
        .gte("captured_at", since)
        .order("captured_at")
        .execute()
    )
    by_section: dict[str, dict] = {}
    for r in (resp.data or []):
        key = r["section"]
        if key not in by_section:
            by_section[key] = {
                "section": key,
                "is_ancillary": r.get("is_ancillary", False),
                "points": [],
            }
        by_section[key]["points"].append({
            "t": r["captured_at"],
            "tickets_count": r.get("tickets_count"),
            "groups_count": r.get("groups_count"),
            "retail_min": r.get("retail_min"),
            "retail_median": r.get("retail_median"),
            "retail_mean": r.get("retail_mean"),
            "retail_max": r.get("retail_max"),
        })
    return {
        "event_id": event_id,
        "days": days,
        "sections": sorted(by_section.values(), key=lambda s: s["section"]),
    }
