-- FIFA / international soccer aliases for the chatbot.
-- WC 2026 is in USA/Canada/Mexico this summer — huge volume expected.
-- Performer IDs left null; chat fn falls through to TEvo search using display_name.

INSERT INTO chat_aliases (alias_norm, alias_kind, display_name, league) VALUES
  -- Tournaments
  ('world cup','tournament','FIFA World Cup','FIFA'),
  ('wc26','tournament','FIFA World Cup 2026','FIFA'),
  ('wc 2026','tournament','FIFA World Cup 2026','FIFA'),
  ('fifa world cup','tournament','FIFA World Cup','FIFA'),
  ('copa america','tournament','Copa America','FIFA'),
  ('euros','tournament','UEFA European Championship','FIFA'),
  ('uefa euros','tournament','UEFA European Championship','FIFA'),
  ('champions league','tournament','UEFA Champions League','FIFA'),
  ('ucl','tournament','UEFA Champions League','FIFA'),
  ('gold cup','tournament','CONCACAF Gold Cup','FIFA'),
  ('club world cup','tournament','FIFA Club World Cup','FIFA'),
  -- National teams (top tier — most-searched)
  ('usmnt','performer','USA Men','FIFA'),
  ('uswnt','performer','USA Women','FIFA'),
  ('usa soccer','performer','USA','FIFA'),
  ('mexico','performer','Mexico','FIFA'),
  ('canada','performer','Canada','FIFA'),
  ('brazil','performer','Brazil','FIFA'),
  ('argentina','performer','Argentina','FIFA'),
  ('france','performer','France','FIFA'),
  ('england','performer','England','FIFA'),
  ('spain','performer','Spain','FIFA'),
  ('germany','performer','Germany','FIFA'),
  ('italy','performer','Italy','FIFA'),
  ('portugal','performer','Portugal','FIFA'),
  ('netherlands','performer','Netherlands','FIFA'),
  ('belgium','performer','Belgium','FIFA'),
  ('uruguay','performer','Uruguay','FIFA'),
  ('colombia','performer','Colombia','FIFA'),
  ('croatia','performer','Croatia','FIFA'),
  ('japan','performer','Japan','FIFA'),
  ('south korea','performer','South Korea','FIFA'),
  ('morocco','performer','Morocco','FIFA'),
  ('senegal','performer','Senegal','FIFA'),
  ('australia','performer','Australia','FIFA')
ON CONFLICT DO NOTHING;
