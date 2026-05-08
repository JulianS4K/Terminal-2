-- Code migration. Captured into git on 2026-05-07.
-- Originally applied to prod 2026-05-08 00:39 UTC.
--
-- Resurrect team_xref as a VIEW over performer_external_ids so cowork's RPCs
-- (get_team_context, broker_event_intel, etc) and edge fns (espn-rosters) keep
-- working. PEI remains the canonical source-of-truth; this is a read-only
-- compat shim until cowork migrates their references.
--
-- Audit: code's migration 20 dropped team_xref. Cowork's migrations 12-16, 25-28
-- (originally 18-21) all read team_xref. They'd be broken without this view.

create or replace view team_xref as
select
  performer_id                                 as tevo_performer_id,
  external_name                                as tevo_name,
  external_id                                  as espn_team_id,
  league                                       as espn_league,
  meta->>'espn_slug'                           as espn_slug,
  meta->>'espn_abbr'                           as espn_abbr,
  coalesce(meta->>'espn_display_name',
           external_name)                      as espn_display_name,
  set_at                                       as matched_at,
  meta                                         as meta
from performer_external_ids
where source = 'espn';

comment on view team_xref is
  'COMPAT VIEW (2026-05-07) — backs cowork RPCs that still reference team_xref. Source of truth is performer_external_ids where source=''espn''. Kept until all RPCs migrate.';
