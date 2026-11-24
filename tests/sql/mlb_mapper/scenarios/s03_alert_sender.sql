\echo MLB alerts go out under their own sender, to their own list, whatever N2S's settings say
SELECT alert_email_from, array_to_string(alert_email_to, ',') AS alert_email_to FROM mlb_ticket_config;
UPDATE n2s_autobuy_config SET email_from = 'N2S Auto-buy <n2s@x.test>', email_to = ARRAY['n2s-only@x.test'] WHERE id;
INSERT INTO mlb_ticket_change (entity, schedule_id, kind, new_value, notable) VALUES ('game', 1, 'link_live', 'https://x.test/1', true);
SELECT 'sent: ' || mlb_ticket_alert_tick();
SELECT body->>'from' AS sender, body->'to'->>0 AS recipient, body->>'subject' AS subject FROM sent_log ORDER BY 2;
SELECT 'still to alert: ' || count(*) FROM mlb_ticket_change WHERE notable AND alerted_at IS NULL;
