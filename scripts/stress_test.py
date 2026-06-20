#!/usr/bin/env python3
"""Storefront latency-under-load harness.

Closed-loop async load generator for the retail storefront (or any HTTP
target). Ramps concurrency across a set of GET endpoints and reports
p50/p90/p95/p99/max latency, throughput, and a status-code histogram
(429s broken out so the per-IP rate limiter is visible).

Design notes
------------
* Read-only by construction — issues GET/HEAD only. It never posts to
  /api/store/reserve, /share, or any write/mutation surface, so it cannot
  trip the listing-source lockdown (CLAUDE.md rule 2) or create spam.
* Closed-loop (N persistent workers, each firing the next request as soon
  as the previous returns) rather than open-loop, so a single source can't
  pretend to be a botnet — it measures how the box behaves under N
  concurrent in-flight requests, which is what we actually want for p99.
* The default target is a LOCAL uvicorn run. Pointing it at a shared/live
  service amplifies cost on TEvo-direct endpoints (/api/store/events,
  /reserve) and can degrade a service others use — do that deliberately,
  within the per-IP rate limit, and never against an endpoint that fans
  out to a paid upstream.

Usage
-----
    python scripts/stress_test.py \
        --base-url http://127.0.0.1:8011 \
        --endpoints /healthz,/store,/store/event/1 \
        --concurrency 1,4,16,64 \
        --duration 5

Each concurrency level runs for --duration seconds against each endpoint.
"""
from __future__ import annotations

import argparse
import asyncio
import statistics
import sys
import time
from collections import Counter
from dataclasses import dataclass, field

try:
    import httpx
except ImportError:  # pragma: no cover - dependency hint
    sys.exit("httpx is required: pip install httpx")


@dataclass
class Result:
    latencies_ms: list[float] = field(default_factory=list)
    statuses: Counter = field(default_factory=Counter)
    errors: int = 0

    def merge(self, other: "Result") -> None:
        self.latencies_ms.extend(other.latencies_ms)
        self.statuses.update(other.statuses)
        self.errors += other.errors


def _pct(values: list[float], q: float) -> float:
    """Nearest-rank percentile. q in [0, 100]."""
    if not values:
        return 0.0
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round((q / 100.0) * (len(s) - 1)))))
    return s[k]


async def _worker(
    client: httpx.AsyncClient,
    url: str,
    method: str,
    deadline: float,
    out: Result,
) -> None:
    while time.monotonic() < deadline:
        t0 = time.perf_counter()
        try:
            r = await client.request(method, url)
            dt = (time.perf_counter() - t0) * 1000.0
            out.latencies_ms.append(dt)
            out.statuses[r.status_code] += 1
        except Exception:  # noqa: BLE001 - a connection error is just a failed sample
            out.errors += 1


async def _run_level(
    base_url: str, path: str, method: str, concurrency: int, duration: float
) -> Result:
    agg = Result()
    deadline = time.monotonic() + duration
    limits = httpx.Limits(max_connections=concurrency, max_keepalive_connections=concurrency)
    async with httpx.AsyncClient(base_url=base_url, limits=limits, timeout=30.0) as client:
        workers = [Result() for _ in range(concurrency)]
        await asyncio.gather(
            *(_worker(client, path, method, deadline, w) for w in workers)
        )
        for w in workers:
            agg.merge(w)
    return agg


def _format_row(path: str, concurrency: int, dur: float, r: Result) -> str:
    n = len(r.latencies_ms)
    rps = n / dur if dur else 0.0
    ok = sum(v for k, v in r.statuses.items() if 200 <= k < 400)
    rl = r.statuses.get(429, 0)
    err5 = sum(v for k, v in r.statuses.items() if k >= 500)
    lat = r.latencies_ms
    mean = statistics.fmean(lat) if lat else 0.0
    return (
        f"{path:<26} c={concurrency:<4} "
        f"req={n:<6} rps={rps:8.1f} "
        f"2xx/3xx={ok:<6} 429={rl:<5} 5xx={err5:<4} err={r.errors:<4} "
        f"| mean={mean:7.1f} p50={_pct(lat,50):7.1f} p90={_pct(lat,90):7.1f} "
        f"p95={_pct(lat,95):7.1f} p99={_pct(lat,99):7.1f} max={_pct(lat,100):7.1f} (ms)"
    )


async def main_async(args: argparse.Namespace) -> int:
    paths = [p.strip() for p in args.endpoints.split(",") if p.strip()]
    levels = [int(c) for c in str(args.concurrency).split(",") if c.strip()]
    print(f"# target   : {args.base_url}")
    print(f"# method   : {args.method}")
    print(f"# duration : {args.duration}s per (endpoint x concurrency)")
    print(f"# levels   : {levels}")
    print(f"# endpoints: {paths}")
    print("#" + "-" * 118)
    worst_p99 = 0.0
    for path in paths:
        for c in levels:
            r = await _run_level(args.base_url, path, args.method, c, args.duration)
            print(_format_row(path, c, args.duration, r))
            worst_p99 = max(worst_p99, _pct(r.latencies_ms, 99))
        print("#" + "-" * 118)
    print(f"# worst p99 across run: {worst_p99:.1f} ms")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base-url", default="http://127.0.0.1:8011")
    ap.add_argument("--endpoints", default="/healthz",
                    help="comma-separated paths to hit")
    ap.add_argument("--concurrency", default="1,4,16,64",
                    help="comma-separated concurrency levels (closed-loop workers)")
    ap.add_argument("--duration", type=float, default=5.0,
                    help="seconds per (endpoint x concurrency) cell")
    ap.add_argument("--method", default="GET", choices=["GET", "HEAD"],
                    help="HTTP method — read-only only, by design")
    args = ap.parse_args()
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    raise SystemExit(main())
