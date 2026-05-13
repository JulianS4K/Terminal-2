"""D2 Orders Dashboard — unified view of all 4 broker order surfaces.

Standalone FastAPI app that fans out to evo / seatgeek / tickpick / vivid
read-only clients and renders a single merged orders table, with a
separate SeatData analytics tab.

Deploy target: Render (D1-owned workspace; D2 builds, D1 provisions).
See d2_dashboard/DEPLOY.md.
"""
