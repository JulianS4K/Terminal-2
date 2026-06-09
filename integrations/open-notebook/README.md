# open-notebook integration (POC)

Publishes Terminal-2 event briefs into [open-notebook](https://github.com/lfnovo/open-notebook)
as **sources**, so you get RAG chat, transformations, and podcast generation over
your market data.

## How it works

open-notebook is not a SQL client — it ingests discrete documents into SurrealDB
and embeds them. So this integration is a **publisher**: it renders read-only SQL
(`v_event_listing_trends` + `v_event_why_context`, the same data behind
`get_broker_event_page_v2`) into a markdown brief and POSTs it to `POST /sources`.

```
Supabase (read-only) ──► render markdown ──► POST /sources ──► open-notebook
```

One-directional, read-only on our side. No prod writes, no upstream broker writes
(CLAUDE.md §1/§2).

## Files
- `publish_event.py` — renders + POSTs one event. `--dry-run` to render only.
- `briefs/3346012.md` — sample rendered brief (Spurs @ Knicks, NBA Finals G4),
  generated from live data 2026-06-09 as the first test.

## Run
```bash
export SUPABASE_URL=https://hzrizjeaxlqcxfrtczpq.supabase.co
export SUPABASE_SERVICE_KEY=...        # SELECT/RPC only
export OPEN_NOTEBOOK_URL=http://localhost:5055
export OPEN_NOTEBOOK_NOTEBOOK_ID=...   # e.g. one notebook per team
python publish_event.py 3346012 --dry-run   # preview
python publish_event.py 3346012             # publish
```

## Concept mapping
| open-notebook | Terminal-2 |
|---|---|
| Notebook | per team / league / portfolio |
| Source | rendered event brief |
| Note / chat | Q&A over briefs |
| Podcast | daily audio market brief |

## Next steps
- Point at a self-hosted open-notebook instance (data sovereignty — see CLAUDE.md
  §2 on outbound data) and confirm chat + podcast over the sample brief.
- Promote to a Supabase edge function on a cron (mirrors the existing collector
  pattern) once the single-event POC checks out.
- Backfill cross-source coverage for Finals games (this event is EVO-only in our
  data — likely an unmapped `sg_event_id`).
