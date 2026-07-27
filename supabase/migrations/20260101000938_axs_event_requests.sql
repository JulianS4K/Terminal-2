-- Operator-supplied AXS-primary events (2026-06-10) to track/pull.
-- These arrived as performer/venue/date with NO axs.com event URL, and the drain
-- pulls by URL — so they're captured here as requests (the "AXS pull wishlist"),
-- linked to the canonical venue (tevo_venue_id via axs_venues) and, where we can,
-- to a tevo_event_id and an existing axs_events pull row. Rows still needing an
-- AXS event URL show axs_event_id IS NULL → not yet pullable.

create table if not exists public.axs_event_requests (
  id            bigint generated always as identity primary key,
  performer     text not null,
  venue_name    text not null,
  event_date_text text,
  event_date    date,
  primary_market text default 'AXS',
  tevo_venue_id bigint,     -- from axs_venues peg
  tevo_event_id bigint,     -- canonical, resolved by venue+date+name
  axs_event_id  text,       -- set once a URL is known / matched to axs_events
  status        text default 'needs_url',
  created_at    timestamptz not null default now()
);
alter table public.axs_event_requests enable row level security;

insert into public.axs_event_requests (performer, venue_name, event_date_text) values
('Lenny Pearce','Red Rocks Amphitheatre','Sun Jun 14, 2026 - 10:15 AM'),
('KALEO','Red Rocks Amphitheatre','Tue Jul 14, 2026 - 7:30 PM'),
('The String Cheese Incident','Red Rocks Amphitheatre','Fri Jul 17, 2026 - 6:00 PM'),
('The String Cheese Incident','Red Rocks Amphitheatre','Sat Jul 18, 2026 - 7:00 PM'),
('Parker McCollum','Red Rocks Amphitheatre','Wed Jul 29, 2026 - 7:30 PM'),
('Tori Amos','Red Rocks Amphitheatre','Thu Aug 20, 2026 - 8:00 PM'),
('Reggae on the Rocks 2026','Red Rocks Amphitheatre','Sat Aug 22, 2026 - 3:00 PM'),
('Joe Bonamassa','Red Rocks Amphitheatre','Sun Aug 23, 2026 - 7:00 PM'),
('Maná','Red Rocks Amphitheatre','Fri Sep 04, 2026 - 8:30 PM'),
('Maná','Red Rocks Amphitheatre','Sat Sep 05, 2026 - 8:30 PM'),
('Five Finger Death Punch','Red Rocks Amphitheatre','Tue Sep 8, 2026 - 6:45 PM'),
('Morgan Wallen','Soldier Field','Fri Jun 19, 2026 - 5:30 PM'),
('Morgan Wallen','Clemson Memorial Stadium','Fri Jun 26, 2026 - 5:30 PM'),
('Morgan Wallen','Clemson Memorial Stadium','Sat Jun 27, 2026 - 5:30 PM'),
('Morgan Wallen','Michigan Stadium','Fri Jul 24, 2026 - 5:30 PM'),
('Matt Rife','Red Rocks Amphitheatre','Sun Oct 18, 2026 - 7:00 PM'),
('Grupo Frontera','Bert Ogden Arena','Fri Jul 17, 2026 - 8:00 PM'),
('Grupo Frontera','Toyota Center','Thu Jul 23, 2026 - 8:00 PM'),
('Grupo Frontera','Michelob ULTRA Arena','Sat Aug 1, 2026 - 8:00 PM'),
('Grupo Frontera','Red Rocks Amphitheatre','Fri Aug 21, 2026 - 7:30 PM'),
('Benson Boone','MVP Arena','Thu Jul 16, 2026 - 8:00 PM'),
('Benson Boone','Crypto.com Arena','Mon Aug 10, 2026 - 8:00 PM'),
('Benson Boone','Crypto.com Arena','Tue Aug 11, 2026 - 8:00 PM'),
('Benson Boone','T-Mobile Arena','Fri Aug 14, 2026 - 8:00 PM'),
('Benson Boone','Pechanga Arena','Sat Aug 15, 2026 - 8:00 PM'),
('Benson Boone','Smoothie King Center','Sun Aug 23, 2026 - 8:00 PM'),
('Benson Boone','VyStar Veterans Memorial Arena','Tue Aug 25, 2026 - 8:00 PM'),
('Benson Boone','T-Mobile Center','Mon Aug 31, 2026 - 8:00 PM'),
('MAMAMOO','Crypto.com Arena','Tue Aug 25, 2026 - 7:00 PM'),
('Disney Descendants, ZOMBIES & Camp Rock','Crypto.com Arena','Mon Sep 28, 2026 - 7:00 PM'),
('Kacey Musgraves','Crypto.com Arena','Sun Oct 18, 2026 - 7:30 PM'),
('The Black Crowes & Whiskey Myers','Forest Hills Stadium at West Side Tennis Club','Sat Jun 13, 2026 - 5:30 PM'),
('Wilco','Forest Hills Stadium at West Side Tennis Club','Sat Jun 20, 2026 - 6:00 PM'),
('Paul Simon','Forest Hills Stadium at West Side Tennis Club','Thu Jul 9, 2026 - 7:00 PM'),
('Sarah McLachlan','Forest Hills Stadium at West Side Tennis Club','Sat Jul 11, 2026 - 7:00 PM'),
('Zeds Dead','Forest Hills Stadium at West Side Tennis Club','Sat Jul 18, 2026 - 6:00 PM'),
('CAAMP','Forest Hills Stadium at West Side Tennis Club','Thu Jul 23, 2026 - 6:00 PM'),
('Jon Batiste','Forest Hills Stadium at West Side Tennis Club','Sat Aug 15, 2026 - 6:30 PM'),
('Zac Brown Band','Forest Hills Stadium at West Side Tennis Club','Thu Aug 27, 2026 - 6:30 PM'),
('Zac Brown Band','Forest Hills Stadium at West Side Tennis Club','Fri Aug 28, 2026 - 6:30 PM'),
('Dermot Kennedy','Forest Hills Stadium at West Side Tennis Club','Tue Sep 29, 2026 - 7:00 PM'),
('Nate Smith','Ryman Auditorium','Wed Jun 17, 2026 - 7:30 PM'),
('Nate Smith','Ryman Auditorium','Thu Jun 18, 2026 - 7:30 PM'),
('Andrew Peterson','Ryman Auditorium','Fri Jun 19, 2026 - 7:00 PM'),
('Ray LaMontagne','Ryman Auditorium','Fri Sep 04, 2026 - 7:30 PM'),
('Summer Walker','T-Mobile Arena','Fri Jun 26, 2026 - 7:30 PM'),
('Rosalia','T-Mobile Arena','Sat Jun 27, 2026 - 8:30 PM'),
('ENHYPEN','T-Mobile Arena','Sat Aug 1, 2026 - 7:30 PM'),
('Kali Uchis','T-Mobile Arena','Sat Aug 8, 2026 - 7:00 PM'),
('Maná','T-Mobile Arena','Fri Sep 11, 2026 - 9:00 PM'),
('WEEZER: The Gathering','T-Mobile Arena','Fri Oct 23, 2026 - 7:00 PM'),
('Doja Cat','T-Mobile Arena','Sat 31 Oct 2026 - 19:30'),
('Dude Perfect – Squad Games Tour 2026','Target Center','Sun Jul 26, 2026 - 6:00 PM'),
('Kacey Musgraves','Target Center','Tue Sep 22, 2026 - 7:30 PM'),
('Disney Descendants, ZOMBIES & Camp Rock: Worlds Collide Concert Tour','Target Center','Sun Oct 18, 2026 - 7:00 PM'),
('Zac Brown Band','Target Center','Fri Oct 23, 2026 - 7:00 PM'),
('MercyMe','Target Center','Sun Nov 15, 2026 - 7:00 PM'),
('Zach Bryan','The Woodlands','Fri Sep 18, 2026 - 3:00 PM'),
('Zach Bryan','The Woodlands','Sat Sep 19, 2026 - 3:00 PM'),
('WWE Friday Night Smackdown','T-Mobile Center','Fri Jun 19, 2026 - 6:30 PM'),
('Zac Brown Band','T-Mobile Center','Thu Sep 10, 2026 - 7:00 PM'),
('Eric Clapton','T-Mobile Center','Thu Sep 17, 2026 - 7:30 PM'),
('Teddy Swims','T-Mobile Center','Tue Sep 22, 2026 - 7:00 PM'),
('Kacey Musgraves','T-Mobile Center','Wed Sep 23, 2026 - 7:30 PM'),
('Elevation Worship & Steven Furtick','T-Mobile Center','Fri Oct 9, 2026 - 7:00 PM'),
('Disney Descendants, ZOMBIES & Camp Rock: Worlds Collide Concert Tour','T-Mobile Center','Sat Oct 17, 2026 - 7:00 PM'),
('Nate Bargatze','Toyota Center','Thu Jun 18, 2026 - 7:00 PM'),
('Nate Bargatze','Toyota Center','Fri Jun 19, 2026 - 7:00 PM'),
('Journey','Pechanga Arena','Mon Sep 14, 2026 - 7:30 PM'),
('The Red Clay Strays','Pechanga Arena','Wed Sep 16, 2026 - 6:30 PM'),
('Carín León','Pechanga Arena','Thu Sep 24, 2026 - 8:00 PM'),
('SOMBR','Pechanga Arena','Tue Oct 13, 2026 - 7:00 PM'),
('Teddy Swims','Pechanga Arena','Fri Nov 13, 2026 - 7:00 PM'),
('Los Tigres del Norte','Pechanga Arena','Sat Nov 14, 2026 - 8:00 PM'),
('A$AP Rocky','MGM Grand Garden Arena','Fri Jun 26, 2026 - 7:30 PM'),
('Don Toliver','MGM Grand Garden Arena','Fri Jul 3, 2026 - 7:30 PM'),
('NE-YO & AKON','MGM Grand Garden Arena','Fri Aug 14, 2026 - 8:00 PM'),
('Banda MS & Xavi','MGM Grand Garden Arena','Fri Sep 11, 2026 - 8:00 PM'),
('Palomazo Norteño','MGM Grand Garden Arena','Sun Sep 13, 2026 - 8:00 PM'),
('Alejandro Fernández','MGM Grand Garden Arena','Tue Sep 15, 2026 - 9:00 PM'),
('Weird Al Yankovic','MGM Grand Garden Arena','Fri Sep 18, 2026 - 8:00 PM'),
('The Smashing Pumpkins','MGM Grand Garden Arena','Fri Oct 30, 2026 - 8:00 PM'),
('JOURNEY','MGM Grand Garden Arena','Fri Nov 27, 2026 - 7:30 PM');

-- parse a date (covers the "Mon DD, YYYY" form; Doja Cat "DD Mon YYYY" handled too)
update public.axs_event_requests
set event_date = coalesce(
  to_date((regexp_match(event_date_text, '([A-Z][a-z]{2}) (\d{1,2}), (\d{4})'))[1] || ' '
        || (regexp_match(event_date_text, '([A-Z][a-z]{2}) (\d{1,2}), (\d{4})'))[2] || ' '
        || (regexp_match(event_date_text, '([A-Z][a-z]{2}) (\d{1,2}), (\d{4})'))[3], 'Mon DD YYYY'),
  to_date((regexp_match(event_date_text, '(\d{1,2}) ([A-Z][a-z]{2}) (\d{4})'))[1] || ' '
        || (regexp_match(event_date_text, '(\d{1,2}) ([A-Z][a-z]{2}) (\d{4})'))[2] || ' '
        || (regexp_match(event_date_text, '(\d{1,2}) ([A-Z][a-z]{2}) (\d{4})'))[3], 'DD Mon YYYY'))
where event_date is null;

-- link venue (via axs_venues peg)
update public.axs_event_requests r
set tevo_venue_id = v.tevo_venue_id
from public.axs_venues v
where v.axs_name_norm = public.venue_norm(r.venue_name) and v.tevo_venue_id is not null;

-- link canonical tevo event: same venue, date within +/-1 day, performer trigram
update public.axs_event_requests r
set tevo_event_id = (
  select ev.id from public.events ev
  where ev.venue_id = r.tevo_venue_id
    and ev.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}T'
    and ev.occurs_at_local::date between r.event_date - 1 and r.event_date + 1
  order by similarity(lower(ev.name), lower(r.performer)) desc
  limit 1)
where r.tevo_venue_id is not null and r.event_date is not null;

-- if that tevo event is already in the AXS pull list, link it (already pullable)
update public.axs_event_requests r
set axs_event_id = e.axs_event_id, status = 'in_pull_list'
from public.axs_events e
where e.tevo_event_id = r.tevo_event_id and r.tevo_event_id is not null;
