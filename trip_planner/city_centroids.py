"""City-centroid gazetteer — coarse fallback coordinates for events whose venue has no
precise geocode in `venue_assets`.

EVO/TEvo gives every event a reliable `events.venue_location` "City, ST" string, but the
lat/lon the planner needs lives in our separately-geocoded `venue_assets`, which has gaps
(ungeocoded venues, and some mis-citied rows). Without a fallback those shows get NULL coords
and the planner silently drops them.

This maps "City, ST" -> an approximate city centroid so the show still routes (a few km of
imprecision is negligible against inter-city legs of hundreds of km). It is a static,
offline table — no external geocoding call. Coordinates are well-known city centroids;
coverage targets North American arena/stadium touring markets. Misses fall through to a
reported drop rather than a silent one.
"""
from __future__ import annotations

# keyed by normalized "city, st" (lowercased) -> (lat, lon)
CITY_CENTROIDS: dict[str, tuple[float, float]] = {
    # --- New York metro ---
    "new york, ny": (40.7128, -74.0060), "brooklyn, ny": (40.6782, -73.9442),
    "bronx, ny": (40.8448, -73.8648), "queens, ny": (40.7282, -73.7949),
    "newark, nj": (40.7357, -74.1724), "east rutherford, nj": (40.8128, -74.0764),
    "uniondale, ny": (40.7006, -73.5907), "elmont, ny": (40.7007, -73.7037),
    # --- California ---
    "los angeles, ca": (34.0522, -118.2437), "inglewood, ca": (33.9617, -118.3531),
    "anaheim, ca": (33.8366, -117.9143), "san diego, ca": (32.7157, -117.1611),
    "san francisco, ca": (37.7749, -122.4194), "oakland, ca": (37.8044, -122.2712),
    "san jose, ca": (37.3382, -121.8863), "sacramento, ca": (38.5816, -121.4944),
    "fresno, ca": (36.7378, -119.7871),
    # --- Northeast / Mid-Atlantic ---
    "boston, ma": (42.3601, -71.0589), "foxborough, ma": (42.0909, -71.2643),
    "philadelphia, pa": (39.9526, -75.1652), "pittsburgh, pa": (40.4406, -79.9959),
    "hershey, pa": (40.2859, -76.6502), "washington, dc": (38.9072, -77.0369),
    "baltimore, md": (39.2904, -76.6122), "hartford, ct": (41.7637, -72.6851),
    "uncasville, ct": (41.4368, -72.0901), "providence, ri": (41.8240, -71.4128),
    "buffalo, ny": (42.8864, -78.8784), "rochester, ny": (43.1566, -77.6088),
    "albany, ny": (42.6526, -73.7562), "syracuse, ny": (43.0481, -76.1474),
    "camden, nj": (39.9259, -75.1196),
    # --- Southeast ---
    "atlanta, ga": (33.7490, -84.3880), "miami, fl": (25.7617, -80.1918),
    "sunrise, fl": (26.1224, -80.2570), "orlando, fl": (28.5383, -81.3792),
    "tampa, fl": (27.9506, -82.4572), "jacksonville, fl": (30.3322, -81.6557),
    "charlotte, nc": (35.2271, -80.8431), "raleigh, nc": (35.7796, -78.6382),
    "greensboro, nc": (36.0726, -79.7920), "columbia, sc": (34.0007, -81.0348),
    "nashville, tn": (36.1627, -86.7816), "memphis, tn": (35.1495, -90.0490),
    "knoxville, tn": (35.9606, -83.9207), "new orleans, la": (29.9511, -90.0715),
    "birmingham, al": (33.5186, -86.8104), "richmond, va": (37.5407, -77.4360),
    "virginia beach, va": (36.8529, -75.9780), "louisville, ky": (38.2527, -85.7585),
    # --- Midwest ---
    "chicago, il": (41.8781, -87.6298), "detroit, mi": (42.3314, -83.0458),
    "grand rapids, mi": (42.9634, -85.6681), "cleveland, oh": (41.4993, -81.6944),
    "columbus, oh": (39.9612, -82.9988), "cincinnati, oh": (39.1031, -84.5120),
    "indianapolis, in": (39.7684, -86.1581), "milwaukee, wi": (43.0389, -87.9065),
    "green bay, wi": (44.5133, -88.0133), "minneapolis, mn": (44.9778, -93.2650),
    "st. paul, mn": (44.9537, -93.0900), "kansas city, mo": (39.0997, -94.5786),
    "st. louis, mo": (38.6270, -90.1994), "omaha, ne": (41.2565, -95.9345),
    "des moines, ia": (41.5868, -93.6250), "wichita, ks": (37.6872, -97.3301),
    # --- South Central / Texas ---
    "dallas, tx": (32.7767, -96.7970), "arlington, tx": (32.7357, -97.1081),
    "fort worth, tx": (32.7555, -97.3308), "houston, tx": (29.7604, -95.3698),
    "austin, tx": (30.2672, -97.7431), "san antonio, tx": (29.4241, -98.4936),
    "el paso, tx": (31.7619, -106.4850), "oklahoma city, ok": (35.4676, -97.5164),
    "tulsa, ok": (36.1540, -95.9928),
    # --- Mountain / West ---
    "denver, co": (39.7392, -104.9903), "phoenix, az": (33.4484, -112.0740),
    "glendale, az": (33.5387, -112.1860), "tucson, az": (32.2226, -110.9747),
    "albuquerque, nm": (35.0844, -106.6504), "las vegas, nv": (36.1699, -115.1398),
    "paradise, nv": (36.0972, -115.1467), "salt lake city, ut": (40.7608, -111.8910),
    "boise, id": (43.6150, -116.2023),
    # --- Pacific Northwest ---
    "seattle, wa": (47.6062, -122.3321), "tacoma, wa": (47.2529, -122.4443),
    "portland, or": (45.5152, -122.6784), "honolulu, hi": (21.3069, -157.8583),
    # --- Canada ---
    "toronto, on": (43.6532, -79.3832), "montreal, qc": (45.5017, -73.5673),
    "vancouver, bc": (49.2827, -123.1207), "ottawa, on": (45.4215, -75.6972),
    "calgary, ab": (51.0447, -114.0719), "edmonton, ab": (53.5461, -113.4938),
    "winnipeg, mb": (49.8951, -97.1384), "quebec city, qc": (46.8139, -71.2080),
    "hamilton, on": (43.2557, -79.8711),
}


def centroid_for(location_text: str | None) -> tuple[float, float] | None:
    """Resolve an EVO 'City, ST' string to an approximate city centroid, or None.

    Tolerant of casing/whitespace and a trailing country token (e.g. 'Brooklyn, NY, USA').
    """
    if not location_text:
        return None
    norm = " ".join(str(location_text).split()).lower().strip()
    if norm in CITY_CENTROIDS:
        return CITY_CENTROIDS[norm]
    # tolerate a trailing country segment: keep the first "city, st"
    parts = [p.strip() for p in norm.split(",")]
    if len(parts) >= 2:
        key = f"{parts[0]}, {parts[1]}"
        return CITY_CENTROIDS.get(key)
    return None
