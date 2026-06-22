-- Operator-supplied AXS venues (2026-06-10) added to axs_venues + pegged to TEvo
-- where our local catalog has them. Clemson/Michigan Stadium/VyStar/The Woodlands
-- aren't in our TEvo catalog (no events there yet) → added unpegged, to peg via
-- live EVO or when an event there is pulled+AQ-mapped.
insert into public.axs_venues (axs_name, tevo_venue_id, matched_name, match_method)
select t.axs_name, t.tevo_venue_id, t.matched_name, 'operator_list'
from (values
  ('Forest Hills Stadium at West Side Tennis Club', 520::bigint, 'Forest Hills Stadium'),
  ('Michelob ULTRA Arena', 3571, 'Michelob ULTRA Arena At Mandalay Bay'),
  ('Pechanga Arena', 8000, 'Pechanga Arena - San Diego'),
  ('Soldier Field', 1444, 'Soldier Field'),
  ('Clemson Memorial Stadium', null, null),
  ('Michigan Stadium', null, null),
  ('VyStar Veterans Memorial Arena', null, null),
  ('The Woodlands', null, null)
) as t(axs_name, tevo_venue_id, matched_name)
where not exists (select 1 from public.axs_venues a where a.axs_name_norm = public.venue_norm(t.axs_name));

update public.axs_venues set tevo_venue_id=2786, matched_name='Toyota Center - TX', match_method='operator_list'
  where axs_name_norm='toyotacenter' and tevo_venue_id is null;
update public.axs_venues set tevo_venue_id=1444, matched_name='Soldier Field', match_method='operator_list'
  where axs_name_norm='soldierfield' and tevo_venue_id is null;
