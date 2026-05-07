-- Feedback loop: every chat message + tool trace gets aggregated into a
-- training-grade corpus, an n-gram word pool, and a glossary-candidate surface.

CREATE TABLE IF NOT EXISTS chat_corpus (
  id              bigserial PRIMARY KEY,
  channel         text NOT NULL,
  user_msg_id     bigint REFERENCES bot_messages(id) ON DELETE CASCADE,
  bot_msg_id      bigint REFERENCES bot_messages(id) ON DELETE CASCADE,
  user_text       text NOT NULL,
  bot_text        text NOT NULL,
  tool_trace      jsonb,
  outcome         text NOT NULL CHECK (outcome IN ('success','no_results','error','rate_limited','clarification','off_topic','unknown')),
  tool_calls      integer DEFAULT 0,
  listings_shown  integer DEFAULT 0,
  zones_shown     integer DEFAULT 0,
  events_resolved bigint[],
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_msg_id, bot_msg_id)
);
CREATE INDEX IF NOT EXISTS chat_corpus_outcome_idx ON chat_corpus (outcome, created_at DESC);
CREATE INDEX IF NOT EXISTS chat_corpus_channel_idx ON chat_corpus (channel, created_at DESC);

CREATE TABLE IF NOT EXISTS chat_term_frequency (
  term         text NOT NULL,
  n            integer NOT NULL CHECK (n IN (1,2,3)),
  channel      text NOT NULL,
  occurrences  bigint NOT NULL DEFAULT 0,
  first_seen   timestamptz NOT NULL DEFAULT now(),
  last_seen    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (term, n, channel)
);
CREATE INDEX IF NOT EXISTS chat_term_freq_top_idx ON chat_term_frequency (n, channel, occurrences DESC);

CREATE TABLE IF NOT EXISTS chat_stopwords (word text PRIMARY KEY);
INSERT INTO chat_stopwords(word) VALUES ('a'),('an'),('the'),('and'),('or'),('but'),('is'),('are'),('was'),('were'),
  ('be'),('been'),('being'),('have'),('has'),('had'),('do'),('does'),('did'),('to'),('of'),('in'),('on'),('at'),
  ('for'),('with'),('by'),('from'),('as'),('it'),('its'),('this'),('that'),('these'),('those'),('i'),('you'),('he'),
  ('she'),('we'),('they'),('me'),('us'),('them'),('my'),('your'),('our'),('their'),('what'),('which'),('who'),('when'),
  ('where'),('why'),('how'),('can'),('could'),('would'),('should'),('will'),('shall'),('may'),('might'),('must'),
  ('any'),('all'),('some'),('one'),('two'),('also'),('like'),('just'),('so'),('if'),('not'),('no'),('yes'),
  ('please'),('thanks'),('thank'),('hi'),('hello'),('hey'),('ok'),('okay'),('whats'),('lets'),('im')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS chat_glossary_known (
  term text PRIMARY KEY, meaning text, added_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO chat_glossary_known(term, meaning) VALUES
  ('floor','Floor / Pit / GA'),('floors','Floor / Pit / GA'),('pit','Floor / Pit / GA'),
  ('ga','Floor / Pit / GA'),('wood','Floor / Pit / GA basketball'),('woods','Floor / Pit / GA basketball'),
  ('courtside','Floor / Pit / GA basketball'),('vip','Premium / VIP'),('club','Club (200s)'),
  ('lower','Lower (100s)'),('upper','Upper'),('nosebleeds','Upper'),('cheapest','sort asc'),
  ('cheap','sort asc'),('home','filter home'),('road','filter road'),('away','filter road'),
  ('upgrade','find_better_seats'),('better','find_better_seats'),('closer','find_better_seats'),
  ('all','include_all'),('everything','include_all')
ON CONFLICT DO NOTHING;

-- See refresh_chat_corpus() body in repo. Idempotent on UNIQUE(user_msg_id, bot_msg_id).
-- Aggregator pairs user→bot turns within 5min of same channel/phone, classifies outcome,
-- builds 1/2/3-gram word frequencies, skips stopwords.

CREATE OR REPLACE VIEW chat_glossary_candidates AS
SELECT tf.term, tf.n, tf.channel, tf.occurrences, tf.first_seen, tf.last_seen
FROM chat_term_frequency tf
LEFT JOIN chat_glossary_known g ON g.term = tf.term
WHERE g.term IS NULL AND tf.occurrences >= 2
ORDER BY tf.n, tf.occurrences DESC;

CREATE OR REPLACE VIEW chat_failures AS
SELECT id, channel, user_text, bot_text, outcome, tool_calls, created_at, tool_trace
FROM chat_corpus WHERE outcome IN ('no_results','error','rate_limited')
ORDER BY created_at DESC;

CREATE OR REPLACE VIEW chat_corpus_training AS
SELECT id, channel, user_text, bot_text, tool_trace, listings_shown, zones_shown, events_resolved, created_at
FROM chat_corpus WHERE outcome = 'success' ORDER BY created_at DESC;
