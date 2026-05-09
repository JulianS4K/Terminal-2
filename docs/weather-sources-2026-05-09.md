# Free weather data sources for the broker terminal (2026-05-09)

> **Goal**: integrate weather data so the terminal can flag outdoor sports / amphitheater concerts where a forecast cold-snap or thunderstorm is about to move pricing. All-free options first; commercial fallbacks listed for completeness.

---

## TL;DR — recommended stack

| Use case | Source | Why |
|---|---|---|
| **Forecast** (next 16 days, hourly) | **Open-Meteo** | No API key, no rate limit on small volumes, global coverage, hourly precision. Best free forecast option. |
| **Official US data** (verification + outlook) | **NOAA NWS** (`api.weather.gov`) | Government source, free, US-only. Use to cross-check Open-Meteo for high-stakes events. |
| **Historical** (backtesting weather impact on sales) | **Open-Meteo Historical** OR **Visual Crossing** (1k records/day free tier) | Open-Meteo offers free historical too — same API. |
| **Real-time observations** | **NOAA Stations** (via NWS API) or **METAR** | Confirm what's actually happening right now at the venue. |

For our use case (outdoor venue forecast + outdoor venue historical for backtesting), **Open-Meteo + NOAA NWS** covers everything for $0. Visual Crossing only if we want a redundant historical archive with a UI.

---

## 1. Open-Meteo (open-meteo.com) — primary recommendation

| Property | Detail |
|---|---|
| Cost | **Free** for non-commercial use (10,000 requests/day soft limit) |
| API key | **None required** |
| Coverage | Global, 1km grid |
| Forecast horizon | 16 days hourly, 7 days minutely |
| Historical | 1940–present (free) via separate endpoint |
| Rate limit | None published; ~10k req/day per IP soft cap |
| Auth | None |

**Endpoint pattern:**
```
GET https://api.open-meteo.com/v1/forecast?latitude=40.75&longitude=-73.99
    &hourly=temperature_2m,precipitation,wind_speed_10m,weather_code
    &daily=precipitation_sum,temperature_2m_max,temperature_2m_min
    &timezone=America/New_York&forecast_days=16
```

Response is JSON, ~5KB per call for 16 days × hourly resolution. Drop directly into `pg_net.http_get` — no auth headers needed.

**Why this beats the alternatives**:
- No API key = no vault entry, no rotation pain
- Single call returns 16-day forecast (NOAA needs 2 calls + zone resolution)
- Includes `weather_code` (WMO standard) which maps cleanly to "rain/snow/clear" buckets
- Wind speed + direction useful for outdoor stadiums where wind affects baseball/golf
- Historical archive on the same API

**Fields useful for ticket pricing**:
- `temperature_2m` (°C, hourly): cold snap detection for outdoor concerts/baseball
- `precipitation` (mm, hourly): rain risk at game time
- `precipitation_probability` (%, hourly): more useful than amount for forecast risk
- `wind_speed_10m` + `wind_gusts_10m`: stadium concerts canceling threshold
- `weather_code`: WMO numeric code, easy to bucket

---

## 2. NOAA NWS API (api.weather.gov) — official US verification

| Property | Detail |
|---|---|
| Cost | **Free**, no rate limit published for reasonable use |
| API key | **None** — User-Agent header required |
| Coverage | US only (50 states + territories) |
| Forecast horizon | 7 days hourly, 14 days twice-daily |
| Historical | Limited (call NCEI for >7-day archive) |
| Auth | `User-Agent` header with contact email |

**Endpoint pattern (2-step lookup)**:
```
GET https://api.weather.gov/points/40.75,-73.99
  → returns gridId + gridX + gridY for your lat/lon
GET https://api.weather.gov/gridpoints/OKX/33,37/forecast/hourly
  → 156-hour forecast
```

**Why it's worth keeping as a secondary**:
- Government source — useful when an event is high-stakes and we want second-source confirmation
- Better severe-weather alerts than Open-Meteo (NWS issues the official watches/warnings)
- Same User-Agent etiquette as Wikipedia (we already do this for the wiki cron)

**Why not primary**: 2-step lookup, US-only, requires zone resolution per venue (cache the gridId once per venue), forecast horizon shorter than Open-Meteo.

---

## 3. Other free options (assessed but not recommended)

| Source | Free tier | Why not primary |
|---|---|---|
| OpenWeatherMap | 1,000 calls/day, 60/min | Hourly forecast paywalled to $40/mo tier |
| WeatherAPI.com | 1M calls/month | API key required, less generous on hourly horizon |
| Tomorrow.io | 500 calls/day | Tightest of the bunch |
| Visual Crossing | 1,000 records/day | Best free **historical** archive — solid backup for backtesting |
| MET Norway (api.met.no) | Free, UA required | Better outside US; redundant for US sports |
| AccuWeather | Limited free tier | Aggressive pricing once you hit limits |

For our use case (forecast for ~50 outdoor venues × ~daily refresh = 50-200 calls/day), Open-Meteo's 10K/day soft limit is overkill. We'd never approach the cap.

---

## 4. Implementation sketch

Following the SeatGeek + Wikipedia pattern (vault + pg_net + canonical table):

### Schema
```sql
CREATE TABLE weather_observations (
  id          bigserial PRIMARY KEY,
  source_key  text NOT NULL REFERENCES data_sources(source_key),
  tevo_venue_id bigint REFERENCES venue_assets(tevo_venue_id),
  observed_at timestamptz NOT NULL,        -- the forecast/observation timestamp
  fetched_at  timestamptz DEFAULT now(),
  is_forecast boolean,                     -- true=forecast, false=observed
  -- Core fields normalized across sources
  temp_c          numeric,
  precip_mm       numeric,
  precip_pct      numeric,
  wind_speed_kmh  numeric,
  wind_gust_kmh   numeric,
  wmo_code        int,                     -- standardized weather code
  weather_summary text,                    -- 'rain', 'clear', 'thunderstorm', etc.
  raw_jsonb       jsonb
);

CREATE INDEX weather_obs_venue_time_idx
  ON weather_observations(tevo_venue_id, observed_at);
```

### Cron (one plpgsql function, scheduled via pg_cron)
```sql
-- For each outdoor venue with an upcoming event in next 14 days,
-- pull Open-Meteo forecast.
CREATE FUNCTION weather_forecast_tick() RETURNS jsonb AS $$
...iterate venue_assets WHERE is_indoor = false...
   AND has at least one event in next 14 days
   ...pg_net.http_get to open-meteo with venue lat/lon
   ...persist normalized rows to weather_observations
$$;

SELECT cron.schedule('weather_forecast_4h', '0 */4 * * *',
  $$ SELECT weather_forecast_tick(); $$);
```

### Day-trader query examples once wired
```sql
-- "Outdoor games this week with rain risk >50% at game time"
SELECT e.id, e.name, e.venue_name, e.occurs_at_local,
       w.precip_pct, w.weather_summary
FROM events e
JOIN venue_assets va ON va.tevo_venue_id = e.venue_id AND NOT va.is_indoor
JOIN weather_observations w ON w.tevo_venue_id = e.venue_id
  AND w.observed_at = date_trunc('hour', e.occurs_at_local::timestamptz)
WHERE e.occurs_at_local::date BETWEEN current_date AND current_date + 7
  AND w.is_forecast AND w.precip_pct > 50;

-- "Historical: when temp dropped below 50°F at outdoor concerts,
--  did pricing soften within 24h?"
WITH cold_events AS (
  SELECT DISTINCT e.id FROM events e
  JOIN weather_observations w ON w.tevo_venue_id = e.venue_id
    AND w.observed_at BETWEEN e.occurs_at_local::timestamptz - interval '24 hours'
                          AND e.occurs_at_local::timestamptz
  WHERE w.temp_c < 10 AND e.event_type = 'concert'
)
SELECT ... join to event_metrics deltas;
```

---

## 5. Geocoding — prerequisite for any weather integration

Weather APIs need lat/lon. Today `venue_assets` has `city` and `state` but no coordinates. Two options:

1. **Manual seed** for high-volume venues (~50 stadiums + amphitheaters). Cheapest, accurate, one-shot.
2. **Geocode pass** via free Nominatim (OpenStreetMap) — same no-key/UA-required pattern as Wikipedia. ~1 req/sec rate limit. Run once over all 50-200 venues, cache the result.

Recommend a one-time geocode pass via Nominatim. ~5 minutes of work, one INSERT per venue, then the weather cron has stable lat/lon to call against.

---

## 6. Build order (when greenlit)

1. Add `weather` row to `data_sources` (1 INSERT). Already in the registry pattern.
2. Add `latitude` / `longitude` columns to `venue_assets`. Run Nominatim geocode pass.
3. Create `weather_observations` table.
4. Create `weather_forecast_tick()` plpgsql function calling Open-Meteo via pg_net.
5. Schedule via pg_cron (4-hour interval is plenty for 16-day forecast cadence).
6. Add `data_source_field_map` rows for the new entity_kinds.
7. Optional: add NOAA NWS as secondary source for US venues (cross-check on high-stakes events).
8. Optional: backfill historical via Open-Meteo historical archive for top-50 outdoor venues × last 5 years for backtesting.

Estimated effort: half a day for the full integration. Open-Meteo's no-auth design makes it as cheap to wire as Wikipedia was.

---

## 7. RULE 2 compliance

All sources above are GET-only and read-only. Adding `weather` to `data_sources.read_only=true` keeps the declarative contract intact. The plpgsql function uses `pg_net.http_get` (never POST), so the existing audit script catches violations.

---

## 8. Status

Filed by: code · 2026-05-09
Recommendation: **Open-Meteo as primary** (no key, no limits in our range, 16-day forecast, free historical). NOAA NWS as US-only verification layer. Visual Crossing only if we want a redundant historical archive.

Awaiting greenlight + the one-time geocode pass on `venue_assets`.
