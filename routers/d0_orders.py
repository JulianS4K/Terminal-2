"""D0 orders-dashboard router (ex-D2, merged into D0 on 2026-07-02).

The orders dashboard is a **D0 sub-surface** — the former D2 lane was folded into
D0 (`PROJECT_BIBLE §2.3`). This module is the D0-owned entry point for its
`/api/d2/*` API: `server.py` mounts the router from **here** instead of reaching
into the ex-D2 `d2_dashboard` package directly, so the orders dashboard is a
first-class D0 `routers/*` module like `broker`/`store`/etc.

Consolidation status (see `docs/archive/2026-07-10-code-storage-blueprint.md` §4
step 1): this is slice 1 — the ownership *seam*. The route bodies + shared
helpers still live in `d2_dashboard/main.py` (the standalone-service
implementation, **retirement-bound** — see `render-d2-dashboard.yaml`). Migrating
those bodies into `core/` and dropping the standalone app is a follow-up slice,
mirroring the BR-CODE-1 routers-first decomposition. Route paths stay `/api/d2/*`
unchanged, so the D0 terminal Orders tab keeps working **same-origin** — no
cross-origin cutover.
"""
from fastapi import APIRouter


def build_d0_orders_router() -> APIRouter:
    """Return the orders-dashboard APIRouter for the D0 shell to `include_router`.

    Imports the assembled router from the (retirement-bound) `d2_dashboard`
    implementation. Kept lazy so importing this module never triggers the
    dashboard's bootstrap unless the shell actually mounts it.
    """
    from d2_dashboard.main import router as orders_router  # impl (retirement-bound)
    return orders_router
