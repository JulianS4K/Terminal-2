-- Stand-ins for what mig 20261114000000 reads from the data lane (A1): the other ids on the
-- event map, the SeatGeek catalogue's event link, the TicketsData credit guard and ledger, and
-- the event map's own guarded write (recorded here, not applied).
ALTER TABLE public.aq_event_map ADD COLUMN IF NOT EXISTS sg_event_id bigint, ADD COLUMN IF NOT EXISTS vivid_event_id bigint;
ALTER TABLE public.sg_events_canonical ADD COLUMN IF NOT EXISTS tevo_event_id bigint;
CREATE TABLE IF NOT EXISTS public.td_stub (id boolean PRIMARY KEY DEFAULT true, budget_ok boolean NOT NULL DEFAULT true, reports_ok boolean NOT NULL DEFAULT true);
INSERT INTO public.td_stub DEFAULT VALUES ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION public.td_budget_ok() RETURNS boolean LANGUAGE sql AS $$ SELECT budget_ok FROM public.td_stub $$;
CREATE OR REPLACE FUNCTION public.td_reports_budget_ok() RETURNS boolean LANGUAGE sql AS $$ SELECT reports_ok FROM public.td_stub $$;
CREATE TABLE IF NOT EXISTS public.td_charged (n serial, credits integer, tevo_event_id bigint, endpoint text, quota_remaining integer, reports integer, reports_remaining integer);
CREATE OR REPLACE FUNCTION public.td_charge_credit(p_n integer, p_event_id bigint, p_platform text, p_endpoint text, p_status_code integer,
                                                   p_quota_remaining integer, p_reports integer, p_reports_remaining integer)
 RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.td_charged (credits, tevo_event_id, endpoint, quota_remaining, reports, reports_remaining)
  VALUES (p_n, p_event_id, p_endpoint, p_quota_remaining, p_reports, p_reports_remaining) $$;
CREATE TABLE IF NOT EXISTS public.mapper_told (n serial, source text, source_event_id bigint, tevo_event_id bigint, local_date date);
CREATE OR REPLACE FUNCTION public.event_mapper_apply(p_source text, p_source_event_id bigint, p_tevo bigint, p_name text, p_venue_name text,
                                                     p_local_date date, p_score numeric DEFAULT NULL, p_performer text DEFAULT NULL,
                                                     p_source_venue_id bigint DEFAULT NULL)
 RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  IF p_source_event_id = 6666 THEN RAISE EXCEPTION 'the map refused'; END IF;
  INSERT INTO public.mapper_told (source, source_event_id, tevo_event_id, local_date) VALUES (p_source, p_source_event_id, p_tevo, p_local_date);
  RETURN 'hub_' || p_source || ';';
END $$;
