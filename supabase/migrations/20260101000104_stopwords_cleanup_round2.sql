-- Cowork migration. Captured into git by code (auditor) on 2026-05-08.
-- Originally applied to prod 2026-05-08 02:13 UTC.

INSERT INTO chat_stopwords (word) VALUES
  ('listings'),('events'),('pm'),('am'),('here'),('ticket'),('many'),('up'),
  ('https'),('www'),('com'),('mobile'),('arena'),('sec'),('ea'),
  ('these'),('there'),('those'),('we'),('our'),('you'),('your'),
  ('the'),('and'),('an'),('to'),('of'),('in'),('is'),('it'),
  ('for'),('on'),('at'),('with'),('from'),('by'),('as'),('be'),
  ('that'),('this'),('how'),('which'),
  ('would'),('like'),('any'),
  ('vs'),('via'),('per'),('about')
ON CONFLICT DO NOTHING;
