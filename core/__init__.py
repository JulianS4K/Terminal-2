"""Shared runtime primitives for the app.py decomposition (BR-CODE-1).

`core/` holds state/config that BOTH app.py and the routers/* packages need.
The import graph is strictly one-directional: app.py / routers -> core, never
the reverse — so core modules must not import app.py (avoids circular imports).

Lane ownership: A1 (shared runtime), per PROJECT_BIBLE §2.5.
"""
