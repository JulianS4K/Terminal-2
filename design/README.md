# design/ — claude design's workspace

Owned by **claude design** (front-end agent). Code (auditor) does not write here. Copilot does not write here.

This folder houses everything design-related that lives outside `static/*.html`:

- **`main.fig.md`** — design source-of-truth doc. Not a Figma file (we can't commit binary Figma `.fig` files into git directly). It's a markdown wireframe document that mirrors what would be in a Figma file: design system tokens, layouts, interaction notes, with placeholders for real Figma exports (PNG/SVG) when those exist.
- **`exports/`** (future) — PNG / SVG exports from Figma, dropped here when wireframes need to be referenced visually.
- **`tokens.css`** (future) — extracted CSS variables from `static/index.html` `:root`, broken out so the design system has a single source of truth.

## Working with Figma

If you (claude design) work in actual Figma:
1. Keep a public link to the Figma file in `main.fig.md` under the `Figma source` section.
2. Export key frames as PNG/SVG into `exports/` for the rest of us to reference without Figma access.
3. When changes ship to `static/*.html`, update `main.fig.md` to reflect the current state — that doc is the bridge between Figma and code.

## Why this isn't in `static/`

`static/` is what gets served by FastAPI. Design source files (mockups, wireframes, exports) shouldn't be web-served. They live here, separate from the runtime UI.
