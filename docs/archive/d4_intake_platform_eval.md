# D4 Intake-Platform Evaluation — Hi.Events vs pretix

**Date:** 2026-05-20 · **Author:** D4 · **Decision owner:** operator (engineering input here)
**Question (operator):** which is best **for eventual modification — adding features as we go**?
**Companion:** [`d4_bridge_charter.md`](d4_bridge_charter.md) §4.3, §8.1.

> Note: the existing `hi-events` Render service (`srv-d7g0…`) is **not** our fork (operator confirmed) — we stand up new regardless of the pick.

---

## TL;DR

**Recommendation: pretix** — for the stated criterion (long-term extensibility), it wins decisively on two axes:
1. **First-class plugin system** — extend via isolated plugins (Django apps + signals + a registry), so features survive upstream upgrades. Hi.Events has **no plugin layer**; you fork and edit core.
2. **Stack fit** — pretix is **Python/Django**, matching Terminal-2's existing FastAPI + Python order-clients. Same language as our engineers; the Bridge plugin can import/call our distribution code in-process. Hi.Events introduces **PHP/Laravel** into the org.

**The honest tradeoff:** Hi.Events is faster to a *branded prototype* (cleaner React UI, drag-drop page builder, less config) — which is why the Bridge thesis recommended it for the 4–6-week build. If speed-to-first-demo were the criterion, Hi.Events wins. But your question was extensibility, and on that axis pretix is the stronger long-term foundation. Decision below blends both.

---

## Side-by-side

| Factor | **pretix** | **Hi.Events** |
|---|---|---|
| Stack | Python / **Django** (77.8% Py) | **PHP / Laravel 11** + React/TS/Mantine |
| **Extension model** | **Plugin API** — independent Django apps; **Django signals** (`order_placed`, `order_paid`, customer/logging hooks); **registry** for payment providers, ticket renderers; categories FEATURE/PAYMENT/INTEGRATION/CUSTOMIZATION/FORMAT/API; cookiecutter scaffold | **No plugin system.** "Modify the source code to match your needs" → **fork + edit core**. REST API + webhooks (Zapier/Make/CRM) for outside-in integration |
| Add a feature without forking? | **Yes** (plugin) | **No** (core edit / fork) |
| Upstream upgrades after customizing | Clean — plugins are separate packages | Merge-conflict prone — your edits diverge from `develop` |
| REST API / webhooks | Extensive REST API; signals | Full REST API; webhooks |
| Maturity | ~10 yr, 2.4k★, 14.4k commits, "millions of tickets", ISO 27001 (per thesis) | Newer, 3.8k★, 650 forks, v1.9.0-beta (Apr 2026), active |
| Venue check-in hardware | **pretixSCAN / pretixPOS / pretixKIOSK** | QR scanning, multi-entrance |
| Default UX / setup speed | More config; utilitarian default UI | **Cleaner UI, drag-drop builder, faster initial setup** |
| License | AGPL-3.0 + terms; **$0 self-host** | AGPL-3.0 + terms; **$1,000 commercial** + must keep "Powered by Hi.Events" notice |

---

## Why the extension model is the deciding factor for the Bridge

The Bridge's integration seam is "**on sale → normalize inventory → push to distribution rails → capture buyer**," plus a growing list of venue-facing features over time (floor-price console, custom ticket types, venue-specific workflows).

- **pretix:** a single Bridge **plugin** subscribes to the `order_paid` / `order_placed` signals and runs our push logic **in-process, in Python** — directly importing the Terminal-2 distribution modules. New features = new signal receivers / registry entries in the same plugin. Core stays pristine; `git pull` from upstream stays clean.
- **Hi.Events:** two options, both heavier — (a) **webhooks** to a separate D4 service (decoupled and fine for the *core* ingest, but every venue-facing UI feature still means editing the React/Laravel core), or (b) **fork** and carry edits forward against `develop` forever, in a PHP stack no one else here uses.

For "add features as we go," pretix's plugin boundary is the difference between *adding* code and *maintaining a divergent fork*.

---

## Recommendation & how to decide

- **Optimize for long-term build (your stated criterion) → pretix.** Best extensibility, stack-aligned, mature, $0, venue hardware.
- **Optimize for fastest possible first branded demo → Hi.Events.** Cleaner default UI; the thesis's 4–6-week / $1k figures assumed this path.

**My recommendation: pretix**, because the Bridge is a multi-year, feature-accreting product (P1 distribution → P2 aggregate site → P3 financial layer → Automatiq), and the plugin/signal architecture + Python stack-fit compound in our favor on every feature after the first. The one cost — a slower, plainer initial prototype — is a one-time hit against a recurring benefit.

**Open for operator:** the thesis exec-brief already asked Ezra to greenlight **Hi.Events + $1k**. If that approval is in motion for speed/BD reasons, flag the divergence before we commit — this is a business+engineering call, not pure engineering.

---

## Sources

- [pretix — GitHub](https://github.com/pretix/pretix)
- [Creating a plugin — pretix docs](https://docs.pretix.eu/dev/development/api/plugins.html)
- [Plugin & core development — pretix docs](https://docs.pretix.eu/dev/development/index.html)
- [Hi.Events — GitHub](https://github.com/HiEventsDev/hi.events)
- [Hi.Events — Open Source Event Ticketing](https://hi.events/open-source-event-ticketing)
- [Hi.Events — Made with Laravel](https://madewithlaravel.com/hievents)
