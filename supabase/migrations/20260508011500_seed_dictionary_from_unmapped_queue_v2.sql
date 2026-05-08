-- Cowork migration. Captured into git by code (auditor) on 2026-05-08.
-- Originally applied to prod 2026-05-08 01:43 UTC.
--
-- Expand chat_aliases CHECK to allow new slot kinds + seed chat dictionary
-- from the unmapped review queue.

ALTER TABLE chat_aliases DROP CONSTRAINT IF EXISTS chat_aliases_alias_kind_check;
ALTER TABLE chat_aliases ADD CONSTRAINT chat_aliases_alias_kind_check
  CHECK (alias_kind = ANY (ARRAY[
    'performer'::text, 'venue'::text, 'city'::text, 'zone'::text,
    'league'::text, 'tournament'::text,
    'date'::text, 'selection'::text, 'navigate'::text,
    'budget_basis'::text, 'price_op'::text, 'sort'::text
  ]));

-- DATE keywords
INSERT INTO chat_aliases (alias_norm, alias_kind, display_name, source) VALUES
  ('tonight','date','tonight','corpus_seed'), ('today','date','today','corpus_seed'),
  ('tomorrow','date','tomorrow','corpus_seed'), ('yesterday','date','yesterday','corpus_seed'),
  ('weekend','date','this weekend','corpus_seed'), ('this weekend','date','this weekend','corpus_seed'),
  ('next weekend','date','next weekend','corpus_seed'), ('this week','date','this week','corpus_seed'),
  ('next week','date','next week','corpus_seed'), ('this month','date','this month','corpus_seed'),
  ('next month','date','next month','corpus_seed'),
  ('mon','date','Monday','corpus_seed'),('monday','date','Monday','corpus_seed'),
  ('tue','date','Tuesday','corpus_seed'),('tues','date','Tuesday','corpus_seed'),('tuesday','date','Tuesday','corpus_seed'),
  ('wed','date','Wednesday','corpus_seed'),('wednesday','date','Wednesday','corpus_seed'),
  ('thu','date','Thursday','corpus_seed'),('thur','date','Thursday','corpus_seed'),('thurs','date','Thursday','corpus_seed'),('thursday','date','Thursday','corpus_seed'),
  ('fri','date','Friday','corpus_seed'),('friday','date','Friday','corpus_seed'),
  ('sat','date','Saturday','corpus_seed'),('saturday','date','Saturday','corpus_seed'),
  ('sun','date','Sunday','corpus_seed'),('sunday','date','Sunday','corpus_seed')
ON CONFLICT DO NOTHING;

-- ZONE aliases
INSERT INTO chat_aliases (alias_norm, alias_kind, display_name, source) VALUES
  ('lowers','zone','Lower (100s)','corpus_seed'), ('lower','zone','Lower (100s)','corpus_seed'),
  ('lower bowl','zone','Lower (100s)','corpus_seed'), ('lwr','zone','Lower (100s)','corpus_seed'),
  ('100s','zone','Lower (100s)','corpus_seed'), ('100 level','zone','Lower (100s)','corpus_seed'),
  ('100lvl','zone','Lower (100s)','corpus_seed'), ('upper','zone','Upper (300s)','corpus_seed'),
  ('uppers','zone','Upper (300s)','corpus_seed'), ('nosebleeds','zone','Upper (500s+)','corpus_seed'),
  ('nosebleed','zone','Upper (500s+)','corpus_seed'), ('300s','zone','Upper (300s)','corpus_seed'),
  ('400s','zone','Upper (400s)','corpus_seed'), ('500s','zone','Upper (500s+)','corpus_seed'),
  ('200s','zone','Club (200s)','corpus_seed'), ('clubs','zone','Club (200s)','corpus_seed'),
  ('club level','zone','Club (200s)','corpus_seed'), ('court','zone','Floor / Pit / GA','corpus_seed'),
  ('courtsides','zone','Floor / Pit / GA','corpus_seed'), ('hardwood','zone','Floor / Pit / GA','corpus_seed'),
  ('floor seats','zone','Floor / Pit / GA','corpus_seed'), ('general admission','zone','Floor / Pit / GA','corpus_seed'),
  ('sro','zone','Floor / Pit / GA','corpus_seed'), ('standing','zone','Floor / Pit / GA','corpus_seed'),
  ('balcony','zone','Balcony','corpus_seed'), ('lawn','zone','Lawn / Terrace','corpus_seed'),
  ('terrace','zone','Lawn / Terrace','corpus_seed'), ('hospitality','zone','Premium / VIP','corpus_seed'),
  ('suite','zone','Premium / VIP','corpus_seed')
ON CONFLICT DO NOTHING;

-- SELECTION / NAVIGATION
INSERT INTO chat_aliases (alias_norm, alias_kind, display_name, source) VALUES
  ('both','selection','both','corpus_seed'), ('all','selection','all','corpus_seed'),
  ('first','selection','first','corpus_seed'), ('second','selection','second','corpus_seed'),
  ('third','selection','third','corpus_seed'), ('last','selection','last','corpus_seed'),
  ('back','navigate','back','corpus_seed'), ('previous','navigate','back','corpus_seed'),
  ('start over','navigate','restart','corpus_seed'), ('cancel','navigate','cancel','corpus_seed'),
  ('different event','navigate','restart','corpus_seed'), ('new search','navigate','restart','corpus_seed')
ON CONFLICT DO NOTHING;

-- BUDGET basis + PRICE op + SORT
INSERT INTO chat_aliases (alias_norm, alias_kind, display_name, source) VALUES
  ('each','budget_basis','per_seat','corpus_seed'), ('apiece','budget_basis','per_seat','corpus_seed'),
  ('per seat','budget_basis','per_seat','corpus_seed'), ('per ticket','budget_basis','per_seat','corpus_seed'),
  ('total','budget_basis','total','corpus_seed'), ('all in','budget_basis','total','corpus_seed'),
  ('altogether','budget_basis','total','corpus_seed'),
  ('under','price_op','lte','corpus_seed'), ('below','price_op','lte','corpus_seed'),
  ('above','price_op','gte','corpus_seed'), ('over','price_op','gte','corpus_seed'),
  ('cheapest','sort','price_asc','corpus_seed'), ('best','sort','best_seat','corpus_seed'),
  ('upgrade','sort','upgrade','corpus_seed'), ('better','sort','upgrade','corpus_seed'),
  ('closer','sort','upgrade','corpus_seed')
ON CONFLICT DO NOTHING;

INSERT INTO chat_stopwords (word) VALUES
  ('tickets'),('seats'),('section'),('sections'),('row'),('rows'),
  ('quantity'),('qty'),('check'),('please'),('hi'),('hello'),('hey'),('help'),
  ('thanks'),('thank'),('test'),('s4k'),('something'),('me'),('need'),
  ('want'),('looking'),('available'),('some'),('zones'),('options')
ON CONFLICT DO NOTHING;

COMMENT ON COLUMN chat_aliases.alias_kind IS
  'Slot type: league|performer|venue|city|zone|tournament|date|selection|navigate|budget_basis|price_op|sort';
