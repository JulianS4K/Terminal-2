# Broadway.com live-testing runbook (2026-05-18)

How to exercise `broadway_client.py` against real `www.broadway.com` and
`checkout.broadway.com` pages. Companion to:
- `docs/concerts-broadway-tours-residencies.md` — schema / detection design
- `tests/test_broadway_client.py` — offline parser tests (always run)
- `tests/test_broadway_client_live.py` — live-network tests (opt-in)
- `scripts/broadway_live_smoke.py` — one-shot smoke script

## Why this isn't run by default

`tests/test_broadway_client.py` covers the parser against a captured
fixture (`tests/fixtures/checkout_sections_six.html`). That's enough to
catch parser regressions on a stable payload shape, but it can't detect
**drift** — if Broadway.com restructures their inline Django payload,
offline tests still pass while production breaks.

The live tests in `tests/test_broadway_client_live.py` fix that, but
they need real outbound HTTPS to `*.broadway.com`, which most managed
environments deny.

## RULE 2 reminder

Every request is `GET`. `BroadwayClient._get` hard-asserts the method
via `_assert_readonly_method` (`broadway_client.py:72-77`,
`broadway_client.py:254`). There is no path that issues
POST/PUT/PATCH/DELETE — verified by `scripts/check_readonly.py` in CI.

## Network requirements

Outbound HTTPS (port 443) to both hosts:

| Host | Why |
|---|---|
| `www.broadway.com` | `discover_performances(slug)` — harvests sections-URL anchors from `/shows/<slug>/` |
| `checkout.broadway.com` | `fetch_sections(...)` — server-rendered Django page with inline-JSON payload |

If your environment uses an egress allowlist proxy (Claude Code on web's
default policy, some corporate networks), add both hosts. The
characteristic failure signature is HTTP 403 with body
`Host not in allowlist` and header `x-deny-reason: host_not_allowed` —
the request never left the container. The live tests skip (not fail) on
that signature so an env misconfiguration doesn't masquerade as a
parser regression.

## Run the tests

```bash
# Default slug: the-25th-annual-putnam-county-spelling-bee
LIVE_BROADWAY=1 pytest tests/test_broadway_client_live.py -v

# Different show
LIVE_BROADWAY=1 BROADWAY_LIVE_SLUG=hamilton \
    pytest tests/test_broadway_client_live.py -v
```

## Run the smoke script

```bash
# Three default long-run shows
python scripts/broadway_live_smoke.py

# Custom set
BROADWAY_SMOKE_SLUGS="hamilton wicked the-lion-king" \
    python scripts/broadway_live_smoke.py
```

Exit 0 only if every slug discovered ≥1 performance AND the first one
parsed cleanly. Useful as a periodic drift canary on an admin PC.

## Refreshing the offline fixture

When Broadway.com restructures the page, the right fix is to recapture
`tests/fixtures/checkout_sections_six.html` (or any other show's
fixture) and update assertions in `tests/test_broadway_client.py`:

```bash
# Capture a fresh page (slug/show_id/event_id from discover output)
python broadway_client.py dump-raw \
    https://checkout.broadway.com/six/12885/<current_event_id>/sections/ \
    tests/fixtures/checkout_sections_six.html

# Sanity-parse the new capture
python broadway_client.py parse-file tests/fixtures/checkout_sections_six.html

# Re-run offline tests to see which assertions need updating
pytest tests/test_broadway_client.py -v
```

`dump-raw` rejects any output path outside the current working directory
(`broadway_client.py:671-675`) so you can't accidentally write outside
the repo.

## chrome-devtools-mcp: when (not) to use it

The repo's `.mcp.json` ships an opt-in entry for
[`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp).
It launches a real headless Chrome via Puppeteer and exposes
navigation/screenshot/DOM-query tools.

**Useful for**:
- JS-rendered SPAs where the data isn't in the initial HTML (Next.js,
  React Router, hydration-only payloads)
- Bot-detected sites with Cloudflare challenges, TLS fingerprinting, or
  canvas-fingerprint walls
- Visual diff / screenshot regression
- Capturing complex multi-step flows (search → results → detail)

**NOT useful for broadway.com**:
- The checkout page is server-rendered Django and inlines the entire
  pricing payload as JSON in a `<script>` block. `requests` + regex is
  strictly faster and simpler than driving a browser — there's nothing
  JavaScript does that we need.
- Egress allowlists block by **destination hostname** before the
  request leaves the container. Whether the request originates from
  `requests` or from headless Chrome doesn't matter — the proxy denies
  on hostname alone. Browsers don't bypass egress firewalls.

If a future scraper target genuinely needs a browser (TickPick's
checkout pages, for example, hydrate via React), `chrome-devtools-mcp`
is wired up — see the entry in `.mcp.json`. On first invocation Chrome
will download (~150 MB); after that it's local.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `HTTP 403 ... host_not_allowed` | Egress proxy blocks `*.broadway.com`. Add to allowlist. |
| `HTTP 403` without `host_not_allowed` | Broadway.com bot detection. Try a real-browser UA via `BROADWAY_USER_AGENT` env var (`broadway_client.py:231-236`). |
| `HTTP 429` | Rate-limited. The client backs off via `Retry-After` (`broadway_client.py:262-269`). Lower pace by passing `pace_s=` to the constructor. |
| `no inline payload found` | Page structure changed. Run `dump-raw` + diff against the fixture; update `_extract_inline_payload` if the assignment shape moved. |
| `no performances discovered` | Show closed, slug typo, or `<a>` markup on the show page changed. Try `python broadway_client.py dump-raw https://www.broadway.com/shows/<slug>/ /tmp/show.html` and inspect. |
