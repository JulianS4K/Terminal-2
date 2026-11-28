-- Stand-in for what the SeatGeek primary watch (mig 20261128080000) reads besides the ProVenue watch: our SeatGeek
-- catalogue, for the EVO id.
CREATE TABLE public.sg_events_canonical (sg_event_id bigint PRIMARY KEY, sg_event_name text, tevo_event_id bigint);
