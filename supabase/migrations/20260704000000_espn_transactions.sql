-- ESPN league transactions pipeline (slice 1 of the "more ESPN pipelines" work).
--
-- Source: site.api.espn.com/apis/site/v2/sports/{sport}/{league}/transactions
--   -> { season, transactions: [{ date, description, team{ id, abbreviation,
--        displayName, ... } }] }  (verified live 2026-07-04: MLB 1973 / NFL 837 /
--        NBA 186 rows; e.g. "Phillies: Sent RHP Brad Keller on a rehab assignment").
--
-- ESPN transaction rows carry no stable id, so we dedup on a synthetic
-- txn_key = sha256(league|team_id|date|description). Append-only + change-tolerant:
-- the ingest upserts with onConflict=txn_key, ignoreDuplicates (identical to the
-- espn_news pattern) so re-polling the same window is a no-op after the first pass.
--
-- Ingested by the espn-league-collect edge function (?scope=transactions).
-- Surfaced on the terminal performer (team) page via get_broker_performer_page.

create table if not exists espn_transactions (
  id                 bigserial primary key,
  txn_key            text unique not null,
  espn_league        text not null,
  espn_team_id       text,
  team_abbr          text,
  team_display_name  text,
  txn_date           timestamptz,
  description        text,
  first_seen_at      timestamptz not null default now(),
  meta               jsonb
);
alter table espn_transactions enable row level security;
create index if not exists idx_espn_txn_team_date   on espn_transactions (espn_team_id, txn_date desc);
create index if not exists idx_espn_txn_league_date on espn_transactions (espn_league, txn_date desc);

comment on table espn_transactions is
  'ESPN league transactions (roster moves, signings, IL, rehab, etc). Append-only, deduped on txn_key=sha256(league|team_id|date|description). Written by espn-league-collect ?scope=transactions.';
