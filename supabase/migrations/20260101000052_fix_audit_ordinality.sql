-- Cowork migration. Captured into git by code (auditor) on 2026-05-07.
-- Originally applied to prod as 20260507000025; RENUMBERED to 29 here so the
-- zone-classifier dependency chain stays in order (system_placeholder → canonical
-- → hybrid → chat_audit_findings → fix_audit_ordinality).
--
-- Fix the ORDER BY ordinality DESC bug in audit_chat_message().
-- jsonb_array_elements doesn't expose `ordinality` unless WITH ORDINALITY is
-- declared. Re-declare it via a lateral subquery.

CREATE OR REPLACE FUNCTION audit_chat_message(p_bot_msg_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_bot_msg record;
  v_user_msg record;
  v_trace jsonb;
  v_call jsonb;
  v_input jsonb;
  v_event_id bigint;
  v_zone text;
  v_max_price numeric;
  v_min_qty integer;
  v_include_all boolean;
  v_claim_type text;
  v_s4k_count int := 0;
  v_all_count int := 0;
  v_capture_ts timestamptz;
  v_was_truthful boolean;
  v_severity text;
  v_diff int;
  v_perfid bigint; v_venid bigint;
BEGIN
  SELECT * INTO v_bot_msg FROM bot_messages WHERE id = p_bot_msg_id;
  IF NOT FOUND OR v_bot_msg.direction <> 'out' THEN RETURN jsonb_build_object('skip','not_outbound'); END IF;

  IF v_bot_msg.body ILIKE '%no %tickets%' OR v_bot_msg.body ILIKE '%no listings%' OR v_bot_msg.body ILIKE '%aren''t any%' OR v_bot_msg.body ILIKE '%aren''t showing%' THEN
    v_claim_type := 'no_listings';
  ELSIF v_bot_msg.body ILIKE '%sold out%' OR v_bot_msg.body ILIKE '%just sold%' THEN
    v_claim_type := 'sold_out';
  ELSIF v_bot_msg.body ~* 'no\s+\d+[\- ]?pack' THEN
    v_claim_type := 'no_qty_pack';
  ELSIF v_bot_msg.body ~* 'no\s+(lower|club|upper|courtside|floor|premium|vip)' THEN
    v_claim_type := 'no_zone';
  ELSE
    RETURN jsonb_build_object('skip','no_claim_detected');
  END IF;

  v_trace := v_bot_msg.meta -> 'trace';
  IF v_trace IS NULL OR jsonb_array_length(v_trace) = 0 THEN
    RETURN jsonb_build_object('skip','no_trace');
  END IF;

  -- FIXED: walk the trace newest-first using WITH ORDINALITY in lateral
  FOR v_call IN
    SELECT elem
    FROM jsonb_array_elements(v_trace) WITH ORDINALITY AS t(elem, idx)
    ORDER BY idx DESC
  LOOP
    IF v_call ->> 'tool' = 'find_listings' THEN
      v_input := v_call -> 'input';
      v_event_id := NULLIF(v_input ->> 'event_id', '')::bigint;
      v_zone := v_input ->> 'zone';
      v_max_price := NULLIF(v_input ->> 'max_price', '')::numeric;
      v_min_qty := COALESCE(NULLIF(v_input ->> 'min_qty', '')::int, 1);
      v_include_all := (v_input ->> 'include_all')::boolean;
      EXIT;
    END IF;
  END LOOP;

  IF v_event_id IS NULL THEN
    RETURN jsonb_build_object('skip','no_find_listings_call');
  END IF;

  SELECT max(captured_at) INTO v_capture_ts
  FROM listings_snapshots
  WHERE event_id = v_event_id AND captured_at <= v_bot_msg.created_at;
  IF v_capture_ts IS NULL THEN
    SELECT min(captured_at) INTO v_capture_ts FROM listings_snapshots WHERE event_id = v_event_id;
  END IF;
  IF v_capture_ts IS NULL THEN
    RETURN jsonb_build_object('skip','no_snapshot_for_event');
  END IF;

  SELECT primary_performer_id, venue_id INTO v_perfid, v_venid FROM events WHERE id = v_event_id;

  SELECT count(*) INTO v_s4k_count
  FROM listings_snapshots l
  WHERE l.event_id = v_event_id AND l.captured_at = v_capture_ts
    AND l.is_owned = true AND l.is_ancillary = false
    AND (v_zone IS NULL OR (
      CASE
        WHEN match_performer_zone(v_perfid, v_venid, l.section, l.row) IS NOT NULL
          THEN match_performer_zone(v_perfid, v_venid, l.section, l.row) = v_zone
        ELSE classify_zone_canonical(l.section) = v_zone
      END
    ))
    AND (v_max_price IS NULL OR l.retail_price <= v_max_price)
    AND (v_min_qty IS NULL OR l.quantity >= v_min_qty);

  SELECT count(*) INTO v_all_count
  FROM listings_snapshots l
  WHERE l.event_id = v_event_id AND l.captured_at = v_capture_ts
    AND l.is_ancillary = false
    AND (v_zone IS NULL OR (
      CASE
        WHEN match_performer_zone(v_perfid, v_venid, l.section, l.row) IS NOT NULL
          THEN match_performer_zone(v_perfid, v_venid, l.section, l.row) = v_zone
        ELSE classify_zone_canonical(l.section) = v_zone
      END
    ))
    AND (v_max_price IS NULL OR l.retail_price <= v_max_price)
    AND (v_min_qty IS NULL OR l.quantity >= v_min_qty);

  IF v_include_all THEN
    v_was_truthful := v_all_count = 0;
    v_diff := v_all_count;
  ELSE
    v_was_truthful := v_s4k_count = 0;
    v_diff := v_s4k_count;
  END IF;

  v_severity := CASE
    WHEN v_was_truthful THEN 'truthful'
    WHEN v_diff < 5 THEN 'minor'
    WHEN v_diff < 20 THEN 'major'
    ELSE 'severe'
  END;

  SELECT * INTO v_user_msg
  FROM bot_messages
  WHERE channel = v_bot_msg.channel AND phone = v_bot_msg.phone
    AND direction = 'in' AND created_at <= v_bot_msg.created_at
  ORDER BY created_at DESC LIMIT 1;

  INSERT INTO chat_audit_findings (
    bot_message_id, user_text, bot_text, claim_type,
    event_id, zone, max_price, min_qty, include_all,
    s4k_only_count, all_sources_count, was_truthful, severity, notes
  ) VALUES (
    p_bot_msg_id, v_user_msg.body, v_bot_msg.body, v_claim_type,
    v_event_id, v_zone, v_max_price, v_min_qty, v_include_all,
    v_s4k_count, v_all_count, v_was_truthful, v_severity,
    CASE WHEN v_was_truthful THEN NULL
         ELSE 'Bot claimed no results but ' || v_diff || ' listings actually matched at snapshot ' || v_capture_ts END
  )
  ON CONFLICT (bot_message_id) DO UPDATE SET
    s4k_only_count = EXCLUDED.s4k_only_count,
    all_sources_count = EXCLUDED.all_sources_count,
    was_truthful = EXCLUDED.was_truthful,
    severity = EXCLUDED.severity,
    notes = EXCLUDED.notes,
    audited_at = now();

  RETURN jsonb_build_object(
    'bot_message_id', p_bot_msg_id, 'event_id', v_event_id, 'zone', v_zone,
    's4k_count', v_s4k_count, 'all_count', v_all_count,
    'was_truthful', v_was_truthful, 'severity', v_severity
  );
END
$fn$;
