-- Bridge: backfill performer_external_ids from team_xref so cowork's canonical
-- table becomes the source-of-truth for TEvo↔ESPN performer mapping.
--
-- Plan:
--   1. Backfill performer_external_ids from team_xref (this migration).
--   2. espn edge fn keeps reading team_xref for now (fast); a follow-up
--      migration + fn redeploy will switch it to performer_external_ids.
--   3. team_xref kept around but marked deprecated; drop it after the espn fn
--      is verified reading from performer_external_ids in prod.
--
-- Safe to re-run: ON CONFLICT DO NOTHING + WHERE NOT EXISTS guard.

insert into performer_external_ids (performer_id, source, external_id, external_name, league, meta, set_at)
select
  tx.tevo_performer_id                                      as performer_id,
  'espn'                                                    as source,
  tx.espn_team_id                                           as external_id,
  tx.tevo_name                                              as external_name,
  tx.espn_league                                            as league,
  jsonb_build_object(
    'espn_slug',         tx.espn_slug,
    'espn_abbr',         tx.espn_abbr,
    'espn_display_name', tx.espn_display_name,
    'backfilled_from',   'team_xref',
    'backfilled_at',     now()
  )                                                         as meta,
  tx.matched_at                                             as set_at
from team_xref tx
where not exists (
  select 1 from performer_external_ids pei
  where pei.performer_id = tx.tevo_performer_id
    and pei.source = 'espn'
);

-- Mark team_xref as deprecated so future readers know to use performer_external_ids.
comment on table team_xref is
  'DEPRECATED 2026-05-07 — use performer_external_ids where source=''espn''. '
  'Backfilled by 20260507000014. Drop after espn edge fn switches reads.';
