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

## chrome-devtools-mcp + Fastly defenses

The repo's `.mcp.json` ships an opt-in entry for
[`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp).
It launches a real headless Chrome via Puppeteer and exposes
navigation/screenshot/DOM-query tools.

### Broadway.com sits behind Fastly

`www.broadway.com` and `checkout.broadway.com` are fronted by Fastly's
CDN/WAF. That edge layer applies bot-defense signals **before** any
Django origin ever sees the request, including:

- **TLS fingerprint (JA3 / JA4)** — Python `requests` (via `urllib3` +
  OpenSSL) has a distinctive cipher/extension order that Fastly can
  flag as non-browser. Chrome's TLS ClientHello matches the curated
  "real-browser" profiles Fastly's edge whitelists.
- **HTTP/2 frame ordering & SETTINGS** — h2 from `requests` differs
  from Chrome's; Fastly can fingerprint this even when TLS looks fine.
- **Client hints** — `Sec-CH-UA`, `Sec-CH-UA-Mobile`, `Sec-CH-UA-Platform`,
  `Sec-Fetch-*` — present on every real Chrome request, absent on
  `requests` unless we forge them all.
- **Edge-issued cookies / session tokens** — Fastly may set a
  short-TTL cookie on first hit and reject subsequent requests that
  don't echo it. `requests.Session` doesn't replay the JS-set portion.
- **Rate / IP heuristics** — datacenter IP ranges (Render, AWS, GCP)
  get harsher defaults than residential.

The Django inline-payload parsing in `broadway_client.py` is correct
and fast **once you can reach the origin**. The pre-payload challenge
is getting past the Fastly edge.

### Browser-driven simulation flow

Use `chrome-devtools-mcp` from a Claude Code session to drive real
Chrome through the same flow `broadway_client.py` does, and capture
what Fastly returns under different conditions. Useful probes:

1. **Headless vs. headful** — `mcp__chrome-devtools__new_page` opens
   the URL, `list_network_requests` shows whether Fastly returned the
   real payload (HTTP 200 with the inline `var json = {…}.data`) or a
   challenge page (HTTP 403 / 429 / a `set-cookie` ladder).
2. **Verify the inline payload survives the edge** — once a real
   Chrome reaches the origin, `evaluate_script` extracts the embedded
   JSON exactly the way `_extract_inline_payload` would, confirming
   the parser will find what it expects.
3. **Header capture** — `list_network_requests` exposes Fastly
   response headers (`x-served-by`, `x-cache`, `fastly-debug-*`,
   `x-timer`) so we know what edge POPs we're hitting and whether
   we're cache-hit vs. origin-pass.
4. **UA / fingerprint A/B** — `emulate` swaps device + UA combos to
   characterize which patterns get clean 200s vs. which trip a
   challenge. Findings feed `BROADWAY_USER_AGENT` defaults.

### Setup on admin PC

`chrome-devtools-mcp` auto-launches via the `.mcp.json` entry:

```json
"chrome-devtools": {
  "type": "stdio",
  "command": "npx",
  "args": ["-y", "chrome-devtools-mcp@latest"]
}
```

On first invocation, the package's Puppeteer dependency downloads a
known-good Chromium build (~150 MB) into its cache. No manual install
needed if Node ≥ 18 is on PATH. If you already have a system Chrome,
the MCP server prefers it via `puppeteer-core` channel resolution.

**This container's failure mode** (for the record): no Chrome binary
present + Puppeteer download blocked by egress allowlist → MCP errors
with `Could not find Google Chrome executable for channel 'stable'`.
On admin PC neither blocker applies.

### Useful for (general)

- JS-rendered SPAs where the data isn't in the initial HTML (Next.js,
  React Router, hydration-only payloads)
- Bot-detected sites: Fastly (as above), Cloudflare challenges,
  Akamai Bot Manager, PerimeterX, DataDome
- Visual diff / screenshot regression
- Capturing complex multi-step flows (search → results → detail)

### NOT a substitute for the egress allowlist

Browsers don't bypass egress firewalls. Whether the request originates
from `requests` or from headless Chrome, our container's egress proxy
denies on **destination hostname** before the request leaves. If
`*.broadway.com` isn't on the allowlist, neither path works. Fix the
allowlist first; then choose `requests` vs. Chrome based on what
Fastly's edge actually does.

## Fastly-block simulation results (offline)

`tests/test_broadway_client_fastly_simulations.py` mocks
`requests.Session.get` to return canonical Fastly-edge responses and
runs the broadway client against each. Pure-offline; no network, no
LIVE_BROADWAY needed. Pin the current behavior so any future change is
deliberate.

| Fastly response | Client behavior | Verdict |
|---|---|---|
| 403 proxy deny (`Fastly error: unknown domain ...`) | `BroadwayError("... returned 403 ...")` | ✅ Loud failure |
| 403 bot deny (`x-fastly-bot-decision: deny`, `Reference #...`) | `BroadwayError("... returned 403 ...")` | ✅ Loud failure |
| 429 rate-limit (with `Retry-After`) | Retries 3× via backoff, then `BroadwayError("... returned 429 ...")` | ✅ Loud failure |
| 503 origin error | Retries 3× via backoff, then `BroadwayError("... returned 503 ...")` | ✅ Loud failure |
| **200 bot-challenge HTML** (no inline JSON, no anchors) | **Returns empty `SectionsSnapshot`** (`sections=[]`, `show=None`) | ⚠️ **Silent gap** |
| 200 valid origin payload | Parses to full `SectionsSnapshot` | ✅ Control case |

### Silent-empty gap (Fastly bot-challenge 200)

When Fastly returns a 200 with a JS-only challenge page — characteristic
of bot management deflection that doesn't want to admit it deflected —
`fetch_sections` degrades to the bs4 fallback (`_listings_from_html`),
finds zero matching selectors, and returns a populated-looking
`SectionsSnapshot` with `sections=[]` and `show=None`.

Downstream consumers (cron, dashboards, drift alerts) cannot distinguish
this from a legitimately-empty performance (sold out, cancelled,
listings pulled). The same gap exists in `discover_performances` (returns
`[]` not raising).

**Proposed fix** (D3-owned, not in this PR — flag for D3 to land in a
follow-up):

```python
# in fetch_sections, after _extract_inline_payload + fallback:
if status == 200 and payload is None and not listings:
    raise BroadwayParseError(
        f"HTTP 200 but no inline payload and no listings — likely Fastly "
        f"bot challenge or page redesign. URL: {url}"
    )
```

Similar guard in `discover_performances` after the anchor loop: if
zero matches AND the response body length is suspiciously small or
contains known challenge markers, raise.

The simulation tests will then need to be updated to expect the new
exception — `test_fastly_bot_challenge_200_silent_empty` is the
canary that pins the *current* (undesirable) behavior so the fix is
a deliberate signature change, not an accident.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `HTTP 403 ... host_not_allowed` | Egress proxy blocks `*.broadway.com`. Add to allowlist. |
| `HTTP 403` with `set-cookie: bot-detection=...` or a challenge HTML body | Fastly bot defense fired. Drive via `chrome-devtools-mcp` instead of `requests` (real TLS fingerprint + client hints). |
| `HTTP 403` without `host_not_allowed` or a Fastly challenge | Likely Broadway.com origin block. Try a real-browser UA via `BROADWAY_USER_AGENT` env var (`broadway_client.py:231-236`). |
| `HTTP 429` | Rate-limited (Fastly or origin). The client backs off via `Retry-After` (`broadway_client.py:262-269`). Lower pace by passing `pace_s=` to the constructor. |
| `no inline payload found` despite HTTP 200 | Either page structure changed OR Fastly returned a challenge page that has the right status but no `var json = ...`. Run `dump-raw` + inspect; if it's the latter, switch to browser-driven fetch. |
| `no performances discovered` | Show closed, slug typo, or `<a>` markup on the show page changed. Try `python broadway_client.py dump-raw https://www.broadway.com/shows/<slug>/ /tmp/show.html` and inspect. |
| `Could not find Google Chrome executable` (MCP error) | `chrome-devtools-mcp` started but Chrome isn't installed and Puppeteer couldn't download (egress block). Install system Chrome or open allowlist to Puppeteer's CDN. |
