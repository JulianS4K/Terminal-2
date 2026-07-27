-- Migration 20260512100000 · level:supervisor · lane:canonical · writes:unaccent,trg_set_updated_at · reads:- · pre:-

CREATE EXTENSION IF NOT EXISTS unaccent;

CREATE OR REPLACE FUNCTION trg_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION trg_set_updated_at() IS
  'Per MIGRATION_CONVENTIONS.md §10: BEFORE UPDATE trigger that auto-bumps updated_at. Used across new-table migrations.';
