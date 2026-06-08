# Vendored engine attribution

The `gigtrip/` package in this directory (`model.py`, `distance.py`, `optimizer.py`) is
vendored **verbatim** from the open-source project **axiom-orion/gigtrip**, licensed under
the **MIT License**. Only the optimization engine is vendored; the upstream project's
Bandsintown client and Streamlit UI are intentionally not included — this spike feeds the
optimizer our own canonical event data (`public.v_event_base`) instead.

Upstream: https://github.com/axiom-orion/gigtrip  ·  License: MIT

This is an exploratory spike (D1 store / per-performer trip planning). It is not wired into
any served route. See `README.md` in this directory.
