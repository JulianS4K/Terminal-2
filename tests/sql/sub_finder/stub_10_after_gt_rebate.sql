DROP FUNCTION n2s_pull_events(bigint[], interval);
ALTER TABLE n2s_mkt_pull ALTER mkt_event_id TYPE bigint USING mkt_event_id::bigint;
