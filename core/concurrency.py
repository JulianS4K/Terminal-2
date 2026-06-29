"""Fan-out helper: run independent, blocking DB reads concurrently.

The broker analytics handlers (overview, chart-data) issue many independent
supabase round-trips that were previously sequential. Running them through a
bounded thread pool collapses the wall-clock to ~the slowest single call
WITHOUT changing any query — same RPCs, tables, and filters, so results are
byte-identical to the sequential path. supabase-py is httpx-backed and safe for
concurrent reads.

One-directional import rule (server/routers/clients → core) is preserved: this
module imports only the stdlib.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from typing import Callable, Sequence, TypeVar

T = TypeVar("T")


def run_parallel(thunks: Sequence[Callable[[], T]], max_workers: int = 8) -> list[T]:
    """Run each zero-arg thunk concurrently; return results in input order.

    An exception raised by any thunk propagates to the caller (re-raised in
    input order when its result is read), matching the sequential code's
    fail-on-error behaviour. Empty input returns []; a single thunk runs inline
    (no pool spun up).
    """
    if not thunks:
        return []
    if len(thunks) == 1:
        return [thunks[0]()]
    with ThreadPoolExecutor(max_workers=min(max_workers, len(thunks))) as ex:
        futures = [ex.submit(t) for t in thunks]
        return [f.result() for f in futures]
