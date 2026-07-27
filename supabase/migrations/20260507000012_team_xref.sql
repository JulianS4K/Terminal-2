-- Retro migration for team_xref (created via MCP on 2026-05-07 by claude code session).
-- Maps TEvo performer ↔ ESPN team for the espn / espn-collect Edge Functions.
-- 38 rows seeded inline (NBA + MLB + MLS + 1 misc — exact-name matches).

create table if not exists team_xref (
  tevo_performer_id  bigint primary key,
  tevo_name          text not null,
  espn_team_id       text not null,
  espn_league        text not null check (espn_league in ('NBA','MLB','NFL','NHL','MLS','NCAAF','NCAAM')),
  espn_slug          text not null,
  espn_abbr          text,
  espn_display_name  text,
  matched_at         timestamptz not null default now(),
  meta               jsonb
);
alter table team_xref enable row level security;
create index if not exists idx_team_xref_espn on team_xref (espn_league, espn_team_id);

insert into team_xref (tevo_performer_id, tevo_name, espn_team_id, espn_league, espn_slug, espn_abbr) values
  (15533,'New York Yankees','10','MLB','baseball/mlb','NYY'),
  (16314,'Orlando Magic','19','NBA','basketball/nba','ORL'),
  (16318,'Houston Rockets','10','NBA','basketball/nba','HOU'),
  (16323,'Minnesota Timberwolves','16','NBA','basketball/nba','MIN'),
  (16308,'Detroit Pistons','8','NBA','basketball/nba','DET'),
  (16328,'Los Angeles Lakers','13','NBA','basketball/nba','LAL'),
  (16322,'Denver Nuggets','7','NBA','basketball/nba','DEN'),
  (16321,'San Antonio Spurs','24','NBA','basketball/nba','SA'),
  (16307,'Cleveland Cavaliers','5','NBA','basketball/nba','CLE'),
  (16303,'New York Knicks','18','NBA','basketball/nba','NY'),
  (16324,'Portland Trail Blazers','22','NBA','basketball/nba','POR'),
  (16311,'Atlanta Hawks','1','NBA','basketball/nba','ATL'),
  (16316,'Oklahoma City Thunder','25','NBA','basketball/nba','OKC'),
  (16305,'Toronto Raptors','28','NBA','basketball/nba','TOR'),
  (16304,'Philadelphia 76ers','20','NBA','basketball/nba','PHI'),
  (16301,'Boston Celtics','2','NBA','basketball/nba','BOS'),
  (16329,'Phoenix Suns','21','NBA','basketball/nba','PHX'),
  (45324,'New York City FC','17606','MLS','soccer/usa.1','NYC'),
  (15535,'Toronto Blue Jays','14','MLB','baseball/mlb','TOR'),
  (16425,'Baltimore Orioles','1','MLB','baseball/mlb','BAL'),
  (15532,'Boston Red Sox','2','MLB','baseball/mlb','BOS'),
  (15534,'Tampa Bay Rays','30','MLB','baseball/mlb','TB'),
  (15536,'Chicago White Sox','4','MLB','baseball/mlb','CHW'),
  (15547,'New York Mets','21','MLB','baseball/mlb','NYM'),
  (15548,'Philadelphia Phillies','22','MLB','baseball/mlb','PHI'),
  (15559,'San Diego Padres','25','MLB','baseball/mlb','SD'),
  (15537,'Cleveland Guardians','5','MLB','baseball/mlb','CLE'),
  (15550,'Chicago Cubs','16','MLB','baseball/mlb','CHC'),
  (15542,'Athletics','11','MLB','baseball/mlb','ATH'),
  (15541,'Los Angeles Angels','3','MLB','baseball/mlb','LAA'),
  (15538,'Detroit Tigers','6','MLB','baseball/mlb','DET'),
  (15544,'Texas Rangers','13','MLB','baseball/mlb','TEX'),
  (15540,'Minnesota Twins','9','MLB','baseball/mlb','MIN'),
  (15553,'Milwaukee Brewers','8','MLB','baseball/mlb','MIL'),
  (15556,'Arizona Diamondbacks','29','MLB','baseball/mlb','ARI'),
  (15552,'Houston Astros','18','MLB','baseball/mlb','HOU'),
  (15549,'Washington Nationals','20','MLB','baseball/mlb','WSH'),
  (15539,'Kansas City Royals','7','MLB','baseball/mlb','KC')
on conflict (tevo_performer_id) do nothing;

-- NOTE: cowork's migration 20260507000008_performer_external_ids may supersede this table.
-- Keep this for now; merge into performer_external_ids in a follow-up if cowork agrees.
comment on table team_xref is 'Created out-of-band by claude code 2026-05-07. Possibly redundant with performer_external_ids — review.';
