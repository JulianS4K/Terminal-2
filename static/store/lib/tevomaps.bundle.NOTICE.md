# tevomaps.bundle.js — vendored third-party library

**What:** Ticket Evolution Seatmaps client — interactive venue seat-map renderer.
**File:** `tevomaps.bundle.js` (prebuilt UMD browser bundle, global `Tevomaps`).
**Used by:** `static/terminal/event.js` → Seat Map tab (`Tevomaps.SeatmapFactory`).

## Provenance (do not hand-edit the bundle — re-vendor to update)

| | |
|---|---|
| Package | `@ticketevolution/seatmaps-client` |
| Version | `5.0.0` |
| Source  | npm registry tarball (`registry.npmjs.org`), file `dist/bundle.js` |
| Format  | UMD, self-contained — React + ReactDOM are bundled in (no external React) |
| Size    | 617194 bytes |
| sha256  | `33a1f5e2485b5f3ef25ec1c007a9d53b7a1dccd307db7c98486efac3aae465d4` |

## To update

```sh
npm pack @ticketevolution/seatmaps-client@<version>   # or curl the registry tarball
tar -xzf ticketevolution-seatmaps-client-<version>.tgz
cp package/dist/bundle.js static/terminal/lib/tevomaps.bundle.js
sha256sum static/terminal/lib/tevomaps.bundle.js      # refresh the hash above
```

## License note

The npm package is published `"license": "UNLICENSED"` (proprietary, Ticket Evolution, Inc.).
It is Ticket Evolution's official integration client, published for their API partners.
Our right to embed it derives from the S4Kent ↔ Ticket Evolution broker relationship
(brokerage_id 1768), not from an open-source grant. Vendored at operator direction
(2026-06-02). See CLAUDE.md §2 (upstream APIs are read-only — this bundle only fetches
public venue map assets from `maps.ticketevolution.com`; it performs no order/write calls).

## Runtime notes

- Fetches `https://maps.ticketevolution.com/{venueId}/{configurationId}/map.svg` + `manifest.json`
  at render time. `event.html`'s CSP `connect-src` must allow `https://maps.ticketevolution.com`.
- `venueId` ← `events.venue_id`, `configurationId` ← `events.configuration_id`.
- `ticketGroups` ← `{tevo_section_name: section, retail_price}` from the EVO listings RPC.
