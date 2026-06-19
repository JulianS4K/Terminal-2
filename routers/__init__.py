"""Per-surface route packages extracted from the app.py monolith (BR-CODE-1).

The strangler-pattern decomposition: route groups move here as `APIRouter`
modules and are `include_router`'d back into `app.py`, behind unchanged paths.
Shared app state (config constants, db/client, auth dep) is passed IN via a
factory function rather than imported from `app.py` — that keeps the import
graph one-directional (`app.py` -> `routers/*`, never the reverse) and avoids
circular imports.

Lane ownership: `routers/` is part of the shared API surface
(BOT_HIERARCHY §5.5b) — A1 owns the file/package; per-surface route blocks are
lane-owned (D0 broker, D1 store) as they migrate.
"""
