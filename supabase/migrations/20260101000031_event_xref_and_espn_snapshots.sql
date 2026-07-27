-- Retro migration for event_xref + ESPN time-series snapshot tables.
-- Created via MCP on 2026-05-07 by claude code session as part of ESPN ingest spike
-- (which duplicates cowork's NEXT item #50 ESPN/odds ingest — needs review).
--
-- All `if not exists` so this is safe to re-apply.

-- ---- event_xref: TEvo event -> ESPN event (populated by espn fn) ------------
create table if not exists event_xref (
  tevo_event_id  bigint primary key references events(id) on delete cascade,
  espn_event_id  text not null,
  espn_league    text not null,
  espn_slug      text not null,
  matched_at     timestamptz not null default now(),
  match_method   text not null,
  meta           jsonb
);
alter table event_xref enable row level security;
create index if not exists idx_event_xref_espn on event_xref (espn_league, espn_event_id);

-- ---- daily team-level snapshots --------------------------------------------
create table if not exists espn_team_snapshots (
  id                  bigserial primary key,
  espn_team_id        text not null,
  espn_league         text not null,
  captured_at         timestamptz not null default now(),
  wins                integer,
  losses              integer,
  ties                integer,
  win_pct             numeric,
  games_back          numeric,
  playoff_seed        integer,
  conference_rank     integer,
  division_rank       integer,
  record_summary      text,
  standing_summary    text,
  streak              text,
  meta                jsonb,
  unique (espn_team_id, espn_league, captured_at)
);
alter table espn_team_snapshots enable row level security;
create index if not exists idx_espn_team_snap on espn_team_snapshots (espn_team_id, captured_at desc);

-- ---- per-injury daily snapshots ---------------------------------------------
create table if not exists espn_injuries_snapshots (
  id                  bigserial primary key,
  espn_team_id        text not null,
  espn_league         text not null,
  captured_at         timestamptz not null default now(),
  athlete_id          text,
  athlete_name        text,
  position            text,
  status              text,
  injury_type         text,
  short_comment       text,
  long_comment        text,
  return_date         timestamptz,
  meta                jsonb
);
alter table espn_injuries_snapshots enable row level security;
create index if not exists idx_espn_inj_team_time on espn_injuries_snapshots (espn_team_id, captured_at desc);
create index if not exists idx_espn_inj_status on espn_injuries_snapshots (status, captured_at desc);

-- ---- append-only news (deduped on espn_article_id) --------------------------
create table if not exists espn_news (
  id                  bigserial primary key,
  espn_article_id     text unique not null,
  espn_team_id        text,
  espn_league         text,
  headline            text,
  description         text,
  published_at        timestamptz,
  url                 text,
  image_url           text,
  type                text,
  first_seen_at       timestamptz not null default now(),
  meta                jsonb
);
alter table espn_news enable row level security;
create index if not exists idx_espn_news_team_pub on espn_news (espn_team_id, published_at desc);
create index if not exists idx_espn_news_league_pub on espn_news (espn_league, published_at desc);

-- ---- per-game daily game snapshots ------------------------------------------
create table if not exists espn_event_snapshots (
  id                  bigserial primary key,
  espn_event_id       text not null,
  espn_league         text not null,
  captured_at         timestamptz not null default now(),
  state               text,
  status_short        text,
  home_team_id        text,
  away_team_id        text,
  home_score          integer,
  away_score          integer,
  odds_provider       text,
  spread              text,
  over_under          numeric,
  home_ml             integer,
  away_ml             integer,
  home_win_prob       numeric,
  attendance          integer,
  meta                jsonb,
  unique (espn_event_id, captured_at)
);
alter table espn_event_snapshots enable row level security;
create index if not exists idx_espn_event_snap on espn_event_snapshots (espn_event_id, captured_at desc);
create index if not exists idx_espn_event_state on espn_event_snapshots (state, captured_at desc);

-- ---- collection runs ledger -------------------------------------------------
create table if not exists espn_runs (
  id                  bigserial primary key,
  started_at          timestamptz not null default now(),
  finished_at         timestamptz,
  teams_processed     integer,
  events_processed    integer,
  injuries_inserted   integer,
  news_inserted       integer,
  team_snaps_inserted integer,
  event_snaps_inserted integer,
  errors              integer,
  log                 text
);
alter table espn_runs enable row level security;
