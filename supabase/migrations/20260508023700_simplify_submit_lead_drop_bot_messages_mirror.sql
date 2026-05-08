-- 20260508023700_simplify_submit_lead_drop_bot_messages_mirror.sql
-- Captured from prod (copilot, applied as version 20260508171714).
-- Captured into git 2026-05-08 by code via audit-and-commit.
--
-- Drop the bot_messages mirror — leads has its own table, no need to pollute
-- bot_messages (whose direction CHECK only allows 'in'/'out' anyway).

DROP FUNCTION IF EXISTS submit_lead_public(bigint, bigint, integer, text, numeric, text, text, text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION submit_lead_public(
  p_event_id bigint,
  p_ticket_group_id bigint DEFAULT NULL,
  p_qty integer DEFAULT NULL,
  p_zone text DEFAULT NULL,
  p_max_price numeric DEFAULT NULL,
  p_budget_basis text DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_channel text DEFAULT 'web',
  p_source_url text DEFAULT NULL,
  p_anon_id text DEFAULT NULL
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
  IF p_event_id IS NULL THEN RAISE EXCEPTION 'event_id required'; END IF;
  IF (p_email IS NULL OR length(trim(p_email)) = 0)
     AND (p_phone IS NULL OR length(trim(p_phone)) = 0) THEN
    RAISE EXCEPTION 'email or phone required';
  END IF;
  INSERT INTO leads (
    event_id, ticket_group_id, qty, zone, max_price, budget_basis,
    name, email, phone, notes, channel, source_url, anon_id
  ) VALUES (
    p_event_id, p_ticket_group_id, p_qty, p_zone, p_max_price, p_budget_basis,
    NULLIF(trim(p_name), ''), NULLIF(trim(lower(p_email)), ''), NULLIF(trim(p_phone), ''),
    NULLIF(trim(p_notes), ''),
    coalesce(p_channel, 'web'), NULLIF(trim(p_source_url), ''), NULLIF(trim(p_anon_id), '')
  ) RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
GRANT EXECUTE ON FUNCTION submit_lead_public(bigint, bigint, integer, text, numeric, text, text, text, text, text, text, text, text)
  TO anon, authenticated, service_role;
