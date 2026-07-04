"""Per-performer SQL digest — assemble a non-sensitive text blob from the ticket
data plane so a performer can become a notebook source (→ Ask/Chat/Podcast).

Design: rather than a generic "read any allowlisted table" source (which the
service-role client could turn into a secret/PII leak), this is a **purpose-built
digest** that reads a FIXED set of safe sources only. Sensitive tables (settings,
vault, exos_*/barcodes, leads/PII, auth) are never touched — they're structurally
out of reach here, not merely filtered.

Safe sources read (per PROJECT_BIBLE §3/§4 landmine review):
  - entity_performer_map / performer_metadata  → identity + branding
  - events (primary_performer_id + performer_ids)  → upcoming slate
  - latest_event_metrics                        → get-in / price bands / depth
  - get_event_movers_v2 (RPC)                   → 7-day price/inventory movement
  - d0_perf_home_away / _price_stats / _price_weighted  → realized-sales color
  - get_performer_prediction_markets (RPC)      → futures/odds narrative (optional)

Landmines respected: events.occurs_at_local is TEXT (ISO string), so "upcoming"
is a lexicographic string compare; d0_* views are pre-deduped (we never touch the
raw seatgeek_sales_snapshots firehose).
"""
from __future__ import annotations

import datetime as _dt
from typing import Any


def _rows(res) -> list[dict]:
    return getattr(res, "data", None) or []


def _is_upcoming(occ: str | None, now_utc: _dt.datetime) -> bool:
    """occurs_at_local is TEXT "YYYY-MM-DDTHH:MM:SS±HH:MM" (offset varies by venue
    tz). Parse it to a real instant and compare — a lexicographic string compare
    against a UTC wall-clock is WRONG (a several-hour offset flips same-evening
    events). Unparseable → keep (don't silently drop)."""
    if not occ:
        return False
    try:
        dt = _dt.datetime.fromisoformat(occ)
    except ValueError:
        return True
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=_dt.timezone.utc)
    return dt >= now_utc


def _safe(fn, default):
    """Best-effort read — a missing view / RLS / empty result must not abort the
    whole digest (a performer with no owned sales is normal)."""
    try:
        return fn()
    except Exception:
        return default


def resolve_performer(db, *, performer_id: int | None = None, name: str | None = None) -> dict | None:
    """Resolve a performer to {'id', 'name'} by tevo_performer_id or by name."""
    if performer_id is not None:
        row = _safe(lambda: _rows(db.table("entity_performer_map")
                                  .select("tevo_performer_id,tevo_performer_name")
                                  .eq("tevo_performer_id", performer_id).limit(1).execute()), [])
        if row:
            return {"id": row[0]["tevo_performer_id"], "name": row[0].get("tevo_performer_name")}
        # fall back to events (map view may lag ingest)
        ev = _safe(lambda: _rows(db.table("events").select("primary_performer_id,primary_performer_name")
                                 .eq("primary_performer_id", performer_id).limit(1).execute()), [])
        if ev:
            return {"id": performer_id, "name": ev[0].get("primary_performer_name")}
        return {"id": performer_id, "name": None}
    if name:
        row = _safe(lambda: _rows(db.table("entity_performer_map")
                                  .select("tevo_performer_id,tevo_performer_name")
                                  .ilike("tevo_performer_name", f"%{name}%").limit(1).execute()), [])
        if row:
            return {"id": row[0]["tevo_performer_id"], "name": row[0].get("tevo_performer_name")}
        md = _safe(lambda: _rows(db.table("performer_metadata").select("performer_id,name")
                                 .ilike("name", f"%{name}%").limit(1).execute()), [])
        if md:
            return {"id": md[0]["performer_id"], "name": md[0].get("name")}
    return None


def _upcoming_events(db, pid: int) -> list[dict]:
    now_utc = _dt.datetime.now(_dt.timezone.utc)
    cols = "id,name,occurs_at_local,venue_name,venue_location,primary_performer_name,state,performer_ids"
    primary = _safe(lambda: _rows(db.table("events").select(cols).eq("primary_performer_id", pid).execute()), [])
    # postgrest .contains() str-joins the value with no int coercion (raises on
    # int); use an explicit `cs.{<id>}` array-literal filter so secondary-performer
    # (e.g. away-game) events are included, not silently dropped.
    also = _safe(lambda: _rows(db.table("events").select(cols)
                               .filter("performer_ids", "cs", "{%d}" % pid).execute()), [])
    seen, out = set(), []
    for e in [*primary, *also]:
        eid = e.get("id")
        if eid in seen:
            continue
        seen.add(eid)
        if not _is_upcoming(e.get("occurs_at_local"), now_utc):
            continue
        if (e.get("state") or "") in ("past", "ignored"):
            continue
        out.append(e)
    out.sort(key=lambda e: e.get("occurs_at_local") or "")
    return out


def _price_by_event(db, event_ids: list[int]) -> dict[int, dict]:
    if not event_ids:
        return {}
    cols = "event_id,getin_price,retail_median,retail_min,retail_p90,tickets_count,owned_share,price_dispersion"
    rows = _safe(lambda: _rows(db.table("latest_event_metrics").select(cols)
                               .in_("event_id", event_ids).execute()), [])
    return {r["event_id"]: r for r in rows}


def _movement_by_event(db, event_ids: list[int]) -> dict[int, dict]:
    if not event_ids:
        return {}
    rows = _safe(lambda: _rows(db.rpc("get_event_movers_v2",
                                      {"p_source": "merged", "p_window_days": 7,
                                       "p_category": None, "p_limit": 200}).execute()), [])
    idset = set(event_ids)
    return {r["event_id"]: r for r in rows if r.get("event_id") in idset}


# d0_perf_* views are aggregate realized-sales, but their columns aren't fixed —
# a future column (e.g. cost-basis / owned-margin) must NOT auto-flow into the
# digest text (embedded + shown in the UI). Emit only allowlisted aggregate
# columns and hard-drop anything matching a sensitive token. Fail-safe: an
# unrecognized column is omitted, not leaked.
_D0_SAFE_TOKENS = ("rev", "median", "mean", "price", "count", "tix", "events",
                   "home", "away", "avg", "min", "max", "p25", "p50", "p75", "p90",
                   "section", "weighted", "visiting", "share")
_D0_DENY_TOKENS = ("cost", "margin", "basis", "profit", "fee", "buyer",
                   "email", "phone", "name", "secret", "owner")


def _digest_kv(row: dict) -> str:
    bits = []
    for k, v in row.items():
        kl = k.lower()
        if kl == "performer_id":
            continue
        if any(d in kl for d in _D0_DENY_TOKENS):
            continue
        if not any(s in kl for s in _D0_SAFE_TOKENS):
            continue
        bits.append(f"{k}={v}")
    return ", ".join(bits[:10])


def _fmt_price(v) -> str:
    try:
        return f"${float(v):,.0f}"
    except (TypeError, ValueError):
        return "n/a"


# ---------------------------------------------------------------------------
# Enrichment sections — each reads a fixed, non-sensitive Supabase source and
# returns markdown lines (or [] when there's nothing). All best-effort (_safe):
# a missing view / empty result never aborts the digest. Sports sections are
# gated on an ESPN team id; the rest apply to any performer where data exists.
# ---------------------------------------------------------------------------

def _espn_ids(db, performer_id: int, info: dict) -> tuple:
    """(espn_team_id, espn_league) from entity_performer_map, else the xref."""
    team, league = info.get("espn_team_id"), info.get("espn_league")
    if team:
        return team, league
    xref = _safe(lambda: _rows(db.table("performer_espn_team_xref")
                               .select("espn_team_id,espn_league")
                               .eq("tevo_performer_id", performer_id).limit(1).execute()), [])
    if xref:
        return xref[0].get("espn_team_id"), xref[0].get("espn_league") or league
    return None, league


def _sec_wikipedia(db, performer_id: int) -> list[str]:
    row = _safe(lambda: _rows(db.table("performer_wikipedia")
                              .select("extract,description,is_rejected")
                              .eq("tevo_performer_id", performer_id).limit(1).execute()), [])
    if not row or row[0].get("is_rejected"):
        return []
    text = (row[0].get("extract") or row[0].get("description") or "").strip()
    return ["## Overview (Wikipedia)", text[:1500], ""] if text else []


def _sec_team_form(db, team_id) -> list[str]:
    if not team_id:
        return []
    row = _safe(lambda: _rows(db.table("v_espn_team_state")
                              .select("record_summary,standing_summary,streak,games_back,playoff_seed")
                              .eq("espn_team_id", team_id).limit(1).execute()), [])
    if not row:
        return []
    r = row[0]
    bits = [r.get("record_summary"), r.get("standing_summary")]
    if r.get("streak"):
        bits.append(f"streak {r['streak']}")
    if r.get("games_back") not in (None, ""):
        bits.append(f"GB {r['games_back']}")
    line = " · ".join(str(b) for b in bits if b)
    return ["## Team form", f"- {line}", ""] if line else []


def _sec_recent_results(db, performer_id: int, n: int = 8) -> list[str]:
    rows = _safe(lambda: _rows(db.table("v_team_recent_results")
                               .select("captured_at,result,team_score,opp_score,is_home")
                               .eq("tevo_performer_id", performer_id)
                               .order("captured_at", desc=True).limit(n).execute()), [])
    if not rows:
        return []
    out = ["## Recent results"]
    for r in rows:
        loc = "home" if r.get("is_home") else "away"
        score = (f" {r.get('team_score')}-{r.get('opp_score')}"
                 if r.get("team_score") is not None else "")
        out.append(f"- {r.get('result') or '?'}{score} ({loc})")
    out.append("")
    return out


def _sec_injuries(db, team_id, n: int = 15) -> list[str]:
    if not team_id:
        return []
    rows = _safe(lambda: _rows(db.table("v_espn_injuries_current")
                               .select("athlete_name,position,status,injury_type")
                               .eq("espn_team_id", team_id).limit(n).execute()), [])
    if not rows:
        return []
    out = ["## Injuries"]
    for r in rows:
        typ = f", {r['injury_type']}" if r.get("injury_type") else ""
        out.append(f"- {r.get('athlete_name', '')} ({r.get('position', '')}) — {r.get('status', '')}{typ}")
    out.append("")
    return out


def _sec_roster(db, performer_id: int, n: int = 12) -> list[str]:
    rows = _safe(lambda: _rows(db.table("v_team_roster_full")
                               .select("full_name,position_abbr").eq("tevo_performer_id", performer_id)
                               .limit(n).execute()), [])
    if not rows:
        return []
    names = ", ".join(f"{r.get('full_name', '')} ({r.get('position_abbr', '')})" for r in rows)
    return ["## Roster (sample)", names, ""]


def _sec_schedule(db, performer_id: int, n: int = 15) -> list[str]:
    rows = _safe(lambda: _rows(db.table("v_team_schedule_30d")
                               .select("occurs_at,home_or_away,opp_performer_name,is_rivalry")
                               .eq("tevo_performer_id", performer_id)
                               .order("occurs_at", desc=False).limit(n).execute()), [])
    if not rows:
        return []
    out = ["## Next 30 days"]
    for r in rows:
        riv = " (rivalry)" if r.get("is_rivalry") else ""
        out.append(f"- {str(r.get('occurs_at', ''))[:16]} {r.get('home_or_away') or ''} "
                   f"{r.get('opp_performer_name') or ''}{riv}".rstrip())
    out.append("")
    return out


def _sec_news(db, team_id, n: int = 8) -> list[str]:
    if not team_id:
        return []
    rows = _safe(lambda: _rows(db.table("espn_news").select("headline,published_at")
                               .eq("espn_team_id", team_id)
                               .order("published_at", desc=True).limit(n).execute()), [])
    if not rows:
        return []
    out = ["## Recent news"]
    for r in rows:
        out.append(f"- {str(r.get('published_at', ''))[:10]} — {r.get('headline', '')}")
    out.append("")
    return out


def _sec_reddit(db, performer_id: int, n: int = 8) -> list[str]:
    pulse = _safe(lambda: _rows(db.table("v_performer_reddit_pulse")
                                .select("posts_24h,posts_7d,score_24h,comments_24h")
                                .eq("tevo_performer_id", performer_id).limit(1).execute()), [])
    posts = _safe(lambda: _rows(db.table("v_reddit_important_recent")
                                .select("title,subreddit,created_utc").eq("tevo_performer_id", performer_id)
                                .order("created_utc", desc=True).limit(n).execute()), [])
    if not pulse and not posts:
        return []
    out = ["## Reddit / fan buzz"]
    if pulse:
        p = pulse[0]
        out.append(f"- Activity: {p.get('posts_24h', 0)} posts/24h, {p.get('posts_7d', 0)}/7d, "
                   f"score {p.get('score_24h', 0)}, {p.get('comments_24h', 0)} comments")
    for r in posts:
        out.append(f"- r/{r.get('subreddit', '')}: {r.get('title', '')}")
    out.append("")
    return out


def _sec_weather(db, events: list[dict], n: int = 5) -> list[str]:
    out: list[str] = []
    for e in events[:n]:
        row = _safe(lambda e=e: _rows(db.table("v_event_weather_with_fallback")
                    .select("is_indoor,temp_f,precip_pct,wind_mph,weather_summary")
                    .eq("tevo_event_id", e["id"]).limit(1).execute()), [])
        if not row:
            continue
        r = row[0]
        if r.get("is_indoor"):
            desc = "indoor"
        else:
            bits = []
            if r.get("temp_f") is not None:
                bits.append(f"{round(float(r['temp_f']))}°F")
            if r.get("weather_summary"):
                bits.append(str(r["weather_summary"]))
            if r.get("precip_pct") is not None:
                bits.append(f"{round(float(r['precip_pct']))}% precip")
            if r.get("wind_mph") is not None:
                bits.append(f"{round(float(r['wind_mph']))}mph wind")
            desc = ", ".join(bits)
        if desc:
            out.append(f"- {e.get('name', '')}: {desc}")
    return ["## Game-day weather"] + out + [""] if out else []


def _sec_sentiment(db, events: list[dict], n: int = 5) -> list[str]:
    out: list[str] = []
    for e in events[:n]:
        row = _safe(lambda e=e: _rows(db.table("event_sentiment")
                    .select("sentiment_index,tix_per_hour,captured_at")
                    .eq("event_id", e["id"]).order("captured_at", desc=True).limit(1).execute()), [])
        if not row:
            continue
        r = row[0]
        bits = []
        if r.get("sentiment_index") is not None:
            bits.append(f"idx {float(r['sentiment_index']):+.2f}")
        if r.get("tix_per_hour") is not None:
            bits.append(f"{float(r['tix_per_hour']):.1f} tix/hr")
        if bits:
            out.append(f"- {e.get('name', '')}: " + ", ".join(bits))
    return ["## Demand velocity"] + out + [""] if out else []


def _sec_hot_sections(db, performer_id: int, n: int = 5) -> list[str]:
    rows = _safe(lambda: _rows(db.table("d0_perf_top5_sections")
                               .select("section,tickets,revenue,rank_by_revenue")
                               .eq("performer_id", performer_id)
                               .order("rank_by_revenue", desc=False).limit(n).execute()), [])
    if not rows:
        return []
    out = ["## Hot sections (realized sales)"]
    for r in rows:
        out.append(f"- {r.get('section', '')}: {r.get('tickets', '?')} tix, {_fmt_price(r.get('revenue'))}")
    out.append("")
    return out


def _sec_macro(db, n: int = 6) -> list[str]:
    rows = _safe(lambda: _rows(db.table("v_macro_indicators_latest")
                               .select("series_id,value,observation_date").limit(n).execute()), [])
    if not rows:
        return []
    out = ["## Macro backdrop"]
    for r in rows:
        out.append(f"- {r.get('series_id', '')}: {r.get('value', '')} "
                   f"(as of {str(r.get('observation_date', ''))[:10]})")
    out.append("")
    return out


def build_performer_digest(db, performer_id: int, *, performer_name: str | None = None) -> tuple[str, str]:
    """Return (title, text) — a rich, non-sensitive markdown digest for one
    performer, assembled from a fixed set of safe Supabase sources (identity,
    Wikipedia, ESPN team form/results/injuries/roster/schedule/news, pricing +
    realized-sales, Reddit buzz, game-day weather, demand sentiment, prediction
    markets, macro backdrop). Sports sections are gated on an ESPN team id."""
    ident = _safe(lambda: _rows(db.table("entity_performer_map")
                                .select("tevo_performer_id,tevo_performer_name,genre,top_category_name,"
                                        "what_event_type,espn_team_id,espn_league")
                                .eq("tevo_performer_id", performer_id).limit(1).execute()), [])
    info = ident[0] if ident else {}
    name = performer_name or info.get("tevo_performer_name") or f"Performer {performer_id}"
    team_id, league = _espn_ids(db, performer_id, info)

    lines: list[str] = [f"# {name}", ""]
    meta_bits = [info.get("top_category_name"), info.get("what_event_type"),
                 info.get("genre"), league]
    meta = " · ".join(str(b) for b in meta_bits if b)
    if meta:
        lines.append(meta)
    lines.append("")

    lines.append("_Lens: secondary-market pricing. Every factor below is a demand / price "
                 "signal — read it for how it moves get-in, retail median, sell-through, "
                 "volatility, and broker edge (hold · list · reprice · blow out)._")
    lines.append("")

    events = _upcoming_events(db, performer_id)
    ids = [e["id"] for e in events]
    prices = _price_by_event(db, ids)
    movers = _movement_by_event(db, ids)

    # ---- Market & pricing (lead — this is what we're pricing) ----
    lines.append(f"## Upcoming events ({len(events)})")
    if not events:
        lines.append("_No upcoming events on record._")
    for e in events[:40]:
        pm = prices.get(e["id"], {})
        mv = movers.get(e["id"], {})
        parts = [e.get("occurs_at_local", "")[:16], e.get("name") or "",
                 e.get("venue_name") or "", e.get("venue_location") or ""]
        head = " · ".join(str(p) for p in parts if p)
        detail = []
        if pm.get("getin_price") is not None:
            detail.append(f"get-in {_fmt_price(pm.get('getin_price'))}")
        if pm.get("retail_median") is not None:
            detail.append(f"median {_fmt_price(pm.get('retail_median'))}")
        if pm.get("tickets_count") is not None:
            detail.append(f"{pm.get('tickets_count')} tix")
        if mv.get("price_delta_pct") is not None:
            detail.append(f"7d {float(mv['price_delta_pct']):+.1f}%")
        lines.append(f"- {head}" + (f" — {', '.join(detail)}" if detail else ""))
    lines.append("")

    lines += _sec_sentiment(db, events)        # demand velocity
    lines += _sec_hot_sections(db, performer_id)

    # Realized-sales color (D0 perf views) — best-effort, may be empty.
    ha = _safe(lambda: _rows(db.table("d0_perf_home_away").select("*")
                             .eq("performer_id", performer_id).limit(1).execute()), [])
    ps = _safe(lambda: _rows(db.table("d0_perf_price_stats").select("*")
                             .eq("performer_id", performer_id).limit(1).execute()), [])
    if ha or ps:
        lines.append("## Realized-sales snapshot")
        if ha:
            lines.append("- Home/away: " + _digest_kv(ha[0]))
        if ps:
            lines.append("- Price stats: " + _digest_kv(ps[0]))
        lines.append("")

    # Prediction-market futures narrative (Kalshi / others), deepened.
    pm_markets = _safe(lambda: db.rpc("get_performer_prediction_markets",
                                      {"p_performer_id": performer_id}).execute(), None)
    futures = (getattr(pm_markets, "data", None) or {}).get("futures") if pm_markets else None
    if futures:
        lines.append("## Futures / prediction markets")
        for f in futures[:15]:
            price = f.get("last_price") or f.get("yes_price") or ""
            vol = f.get("volume")
            tail = f", vol {vol}" if vol else ""
            lines.append(f"- {f.get('title') or f.get('question') or ''} "
                         f"({f.get('source')}: {price}{tail})")
        lines.append("")

    # ---- Demand & context inputs (weigh each against price) ----
    lines += _sec_weather(db, events)
    lines += _sec_team_form(db, team_id)
    lines += _sec_recent_results(db, performer_id)
    lines += _sec_injuries(db, team_id)
    lines += _sec_schedule(db, performer_id)
    lines += _sec_reddit(db, performer_id)
    lines += _sec_news(db, team_id)
    lines += _sec_wikipedia(db, performer_id)
    lines += _sec_roster(db, performer_id)
    lines += _sec_macro(db)

    return name, "\n".join(lines).strip()


# ---------------------------------------------------------------------------
# Wikipedia enrichment — auto-attach article + season pages on performer select
# ---------------------------------------------------------------------------

def performer_wikipedia_urls(db, performer_id: int, name: str, *, max_seasons: int = 2) -> list[str]:
    """Wikipedia URLs to auto-attach for a performer: the main article, plus (for
    a sports team) the recent "<year> <team> season" pages. Scoped to major
    sports (espn_league present) and Broadway (category names theatre/musical) —
    other categories return [] so we don't attach a wrong-match article."""
    from . import wikipedia  # noqa: PLC0415 — avoid import cost unless used

    name = (name or "").strip()
    if not name:
        return []
    info = _safe(lambda: _rows(db.table("entity_performer_map")
                               .select("espn_league,top_category_name,what_event_type,genre")
                               .eq("tevo_performer_id", performer_id).limit(1).execute()), [])
    row = info[0] if info else {}
    league = row.get("espn_league")
    blob = " ".join(str(row.get(k) or "") for k in
                    ("top_category_name", "what_event_type", "genre")).lower()
    is_broadway = ("broadway" in blob or "theat" in blob or "musical" in blob)
    if not (league or is_broadway):
        return []

    urls: list[str] = []
    # Broadway names ("Hamilton") are ambiguous — disambiguate to the show first.
    if is_broadway:
        main = wikipedia.resolve_article_url(f"{name} (musical)") or wikipedia.resolve_article_url(name)
    else:
        main = wikipedia.resolve_article_url(name)
    if main:
        urls.append(main)

    if league:  # sports team → attach the recent season pages too
        now_year = _dt.datetime.now(_dt.timezone.utc).year
        for u in wikipedia.resolve_season_urls(name, [now_year, now_year - 1], max_urls=max_seasons):
            if u not in urls:
                urls.append(u)
    return urls


def add_wikipedia_sources(db, notebook_id: str, performer_id: int, name: str) -> list[str]:
    """Resolve + ingest a performer's Wikipedia sources onto an existing notebook.
    Best-effort: any failure is swallowed so enrichment never breaks notebook
    creation. Returns the created source ids."""
    from . import ingest as _ingest, repository as _repo  # noqa: PLC0415

    try:
        urls = performer_wikipedia_urls(db, performer_id, name)
    except Exception:
        return []
    added: list[str] = []
    for url in urls:
        try:
            src = _repo.create_source(db, title=None, asset={"kind": "url", "url": url}, status="queued")
            _repo.link_source(db, notebook_id, src["id"])
            job = _repo.create_job(db, kind="ingest", ref_id=src["id"])
            _ingest.ingest_source(db, src["id"], job_id=job["id"])
            added.append(src["id"])
        except Exception:
            continue
    return added
