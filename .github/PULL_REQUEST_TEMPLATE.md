<!-- Fill every field. Admin blocks PRs missing fields. See README.md +
     MIGRATION_CONVENTIONS.md (shipping rules + checklist). -->

**Level**: <!-- admin | security | supervisor | primary-sales | secondary-sales | data-collection -->
**Lane**: <!-- e.g. "Terminal Front End", or A1 / B1 / C1 / D0 / D1 / D2 / D3 -->
**Branch**: <!-- claude/<lane>-<slug>, per MIGRATION_CONVENTIONS §11.2 -->

## Pre-PR checklist (MIGRATION_CONVENTIONS)
- [ ] Rebased / merged with `origin/main` immediately before opening
- [ ] `bash scripts/check_sync.sh` prints SYNCED
- [ ] Migration slot reserved in `bot_chat` (Careful track DDL only)
- [ ] Migration header line present + accurate
- [ ] SECURITY DEFINER fns include REVOKE PUBLIC + GRANT service_role + current_user body-assert (if any added)
- [ ] New cron jobs avoid `:02 / :05 / :07` minute marks (saturated clusters)
- [ ] PR title format: `<type>(<lane>): <short imperative>`
- [ ] **Bible updated** *if* this PR adds a catalogued resource (new service/secret/table/view/RPC/cron/edge-fn or a new column landmine) — `RESOURCES_BIBLE` / `PROJECT_BIBLE §3·§4`. Routine changes: leave unchecked, no doc needed.

## What
<!-- 1-3 bullets -->

## Migrations
<!-- list filenames, one per line. Each must have the single-line header:
     -- Migration <ts> · level:<X> · lane:<Y> · writes:<a,b> · reads:<c> · pre:<...> -->

## Tables touched
<!-- table_a (W), table_b (R) — must match migration header -->

## Cross-lane writes
<!-- files outside your lane; "none" if none. If non-none, link the bot_chat
     ack from the affected lane. -->

## Pre-reqs
<!-- vault secrets, prior migrations, external services -->

## Already applied to prod
<!-- Idempotent + reversible migrations may be applied via MCP before PR open
     (MIGRATION_CONVENTIONS §11.1). If so, state: "Applied via MCP at <timestamp UTC>;
     this PR is the idempotent codification. Re-apply is a no-op." Otherwise
     delete this section. -->

## Test plan
<!-- - [ ] applied to preview branch <id>, no errors
     - [ ] smoke query: …
     - [ ] If apply-before-PR: re-apply against current prod state is a no-op -->
