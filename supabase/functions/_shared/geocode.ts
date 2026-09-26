// Geocoding helpers shared by the exos-geocode edge function and the EXP SPA.
// No imports, so Deno and vitest can both load it.
//
// venueQuery() is also what the SPA uses for its "Directions" link, so the
// address a buyer is routed to is the one the server geocoded.

export interface VenueAddress {
  street?: string;
  city?: string;
  region?: string;
  country?: string;
  postal?: string;
}

// What to search for: the venue name plus whatever address parts exist, or
// null when there's nothing mappable (TBA, online, blank).
export function venueQuery(
  location: string | undefined | null,
  address?: VenueAddress | null,
  extra?: string | null,
): string | null {
  const name = (location ?? "").trim();
  const parts = [address?.street, address?.city, address?.region, address?.postal, address?.country]
    .map((p) => (typeof p === "string" ? p : "").trim())
    .filter(Boolean);
  const more = (extra ?? "").trim();
  if (more && more.toLowerCase() !== name.toLowerCase() && parts.length === 0) parts.push(more);
  if (parts.length === 0 && (!name || /^(tba|tbd|online|virtual|secret location)$/i.test(name))) return null;
  return [name, ...parts].filter(Boolean).join(", ").replace(/\s+/g, " ").slice(0, 300);
}

const GEOCODE = "https://maps.googleapis.com/maps/api/geocode/json";

export function buildGeocodeUrl(
  q: { address: string } | { placeId: string },
  key: string,
  region = "us",
): string {
  const u = new URL(GEOCODE);
  if ("placeId" in q) u.searchParams.set("place_id", q.placeId);
  else {
    u.searchParams.set("address", q.address);
    u.searchParams.set("region", region);
  }
  u.searchParams.set("key", key);
  return u.toString();
}

export type GeocodeResult =
  | { status: "ok"; lat: number; lng: number; placeId: string; formattedAddress: string }
  | { status: "zero_results" }
  | { status: "error"; error: string };

// Parse a Geocoding API JSON body. Takes the first result, as Google ranks it.
export function parseGeocodeResponse(body: unknown): GeocodeResult {
  const b = body as {
    status?: string;
    error_message?: string;
    results?: { place_id?: string; formatted_address?: string; geometry?: { location?: { lat?: number; lng?: number } } }[];
  } | null;
  if (!b || typeof b.status !== "string") return { status: "error", error: "malformed response" };
  if (b.status === "ZERO_RESULTS") return { status: "zero_results" };
  if (b.status !== "OK") return { status: "error", error: `${b.status}${b.error_message ? `: ${b.error_message}` : ""}`.slice(0, 500) };
  const r = b.results?.[0];
  const lat = r?.geometry?.location?.lat;
  const lng = r?.geometry?.location?.lng;
  if (typeof lat !== "number" || typeof lng !== "number" || !Number.isFinite(lat) || !Number.isFinite(lng) ||
      lat < -90 || lat > 90 || lng < -180 || lng > 180 || typeof r?.place_id !== "string") {
    return { status: "error", error: "result missing coordinates" };
  }
  return { status: "ok", lat, lng, placeId: r.place_id.slice(0, 512), formattedAddress: (r.formatted_address ?? "").slice(0, 500) };
}
