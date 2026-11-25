-- Migration 20261125193000 · level:data-collection · lane:d0 (listings pollers) · writes:listings_poll_league_pins,v_listings_poll_pinned_events,settings · reads:n2s_items,events,listings_poll_pins,performer_espn_team_xref
--
-- ============================================================================
-- Migration 20261125193000 — unpin the league watchlists, pin N2S obligations
--   instead, so cover verification keeps a listing feed
--
-- Lane:     d0 (listings pollers; the N2S surface is a named subset, PROJECT_BIBLE §2.3)
-- Touches:  listings_poll_league_pins (W: enabled=false), settings (W: one new key),
--           v_listings_poll_pinned_events (REPLACE), n2s_items (R), events (R)
-- Pre-reqs: 20261023051000 + 20261023054000 (pinned listing polls),
--           20261124120000 (listing_overlap, the view's other consumer)
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It narrows which
-- events the existing pollers are allowed to read. Every call still goes out
-- through pinned_listings_poll_tick as a GET.
--
-- ── Operator direction ────────────────────────────────────────────────────
-- 2026-11-25, after being shown that pinned_listings_poll_2min polls 6,188
-- events of which 94% have no N2S or CRM tie: "unpin those events, check if
-- this effects n2s, and if no merge if yes fix and merge", choosing "all
-- league pins" when asked for the scope.
--
-- ── IT DOES AFFECT N2S, SO THIS ALSO FIXES IT ─────────────────────────────
-- N2S has its own upstream pull — n2s_pull_events() fires its own EVO
-- /v9/ticket_groups, GoTickets /listings, SeatGeek brokerdata and TD reads —
-- but n2s_mkt_drain() lands those in n2s_evo_current / n2s_gt_current /
-- n2s_sg_current (1-hour TTL), NOT in the snapshot firehoses. And
-- n2s_cover_verify() reads the firehoses: listings_snapshots,
-- gotickets_listings_snapshots, seatgeek_listings_snapshots. So the pre-buy
-- gate's freshness depends on the pinned poller, not on N2S's own pull.
--
-- Measured before the change: 257 events carry a live, non-terminal n2s_items
-- row, and 188 of them (73%) were pinned only by a league pin. Disabling the
-- league pins alone would have pushed n2s_cover_verify to `stale_data` for
-- those 188 — which is the safe answer, not a wrong one (see 20260910150000),
-- but it would have made the gate useless on most live obligations and sent
-- the operator to n2s_pull_all_sources() by hand every time.
--
-- The fix is a third arm on the pin view: an event with any non-terminal
-- n2s_items row is pinned for as long as the obligation is open, on all three
-- markets, with the same collector_cadence bands as any other pin. The set is
-- derived, not configured — it appears when a sale lands and leaves when the
-- obligation closes, so no one has to remember to pin it.
--
-- WHY NOT point n2s_cover_verify at n2s_*_current instead: that is the tidier
-- design (N2S reading what N2S pulled) but it rewrites a pre-purchase money
-- gate to depend on a 1-hour TTL table, and the two differ in what absence
-- means — absence from a firehose capture means delisted, absence from
-- n2s_*_current can also mean "N2S never pulled this event". Left for a
-- separate, tested change; filed as a note in bot_chat.
--
-- CRM IS NOT RESTORED HERE. s4kcs_sub_worklist spans 1,823 events and only 305
-- were pinned; the sub-candidate finder already runs without a feed on 83% of
-- them, so pinning that set would ADD load rather than restore a status quo.
-- Operator asked about N2S. Flagged, not changed.
--
-- ── MEASURED EFFECT (dry-run of this exact view body against prod, 19:2xZ) ──
--   pinned events          6,188 -> 303   (249 n2s:obligation + 54 performer)
--   league pins disabled   MLB 4,125, NHL 962, NBA 947, NFL 100
--   kept                   knicks_home (33) + 10 bd_* college (21)
--   EVO snapshot rows/day  17.4M -> 5.9M   (-66%)
--   GT  snapshot rows/day   6.5M -> 2.2M   (-66%)
--   EVO read demand/day   35,612 -> 17,866
--   GT  read demand/day   28,554 -> 17,690 (actual lower: GT needs a mapped
--                                          gotickets_event, ~58% of events)
-- Read demand falls far less than the event count because the 5-minute le3d
-- band dominates it: 43 of the 249 N2S events are inside 3 days and each of
-- those alone wants 288 reads a day. The row counts are what matter for the
-- 428 GB, and those fall by two thirds.
--
-- N2S COVERAGE GOES UP, NOT DOWN. Live N2S events (non-terminal item, event
-- not yet past): 261. Pinned TODAY: 191. Pinned after this change: 260. The
-- one miss is an event whose n2s_items.event_dt is in the future while
-- events.occurs_at_local is already past — a date disagreement between the two
-- tables, not a polling gap; polling a finished event buys nothing. So the
-- gate is better fed after this than before it.
--
-- The deal scanner, get_broker_event_page_v2/v3, the store, the alerts engine
-- and listing_overlap_tick all narrow to the kept set. That is the point of
-- the change, not a side effect: those surfaces were the 94%.
--
-- REVERSIBLE: `UPDATE listings_poll_league_pins SET enabled = true;` restores
-- the old set within one 2-minute tick. The N2S arm is switched off with
-- settings key `listings_poll_n2s_pin` = 'off'.
-- ============================================================================

BEGIN;

-- 1. the league watchlists stop driving polls. Rows and cadence config are kept
--    so re-enabling is one UPDATE; all four were enabled at the time of writing.
UPDATE public.listings_poll_league_pins SET enabled = false WHERE enabled;

-- 2. the N2S arm's own switch, default on
INSERT INTO public.settings (key, value, updated_at)
VALUES ('listings_poll_n2s_pin', 'on', now())
ON CONFLICT (key) DO NOTHING;

-- 3. the pin view gains a third arm: open N2S obligations
CREATE OR REPLACE VIEW public.v_listings_poll_pinned_events
WITH (security_invoker = true) AS
 SELECT DISTINCT ON (tevo_event_id) tevo_event_id,
    pin_key,
    sources,
    occurs_at,
    hours_to_event,
    sg_owned
   FROM ( SELECT e.id AS tevo_event_id,
            p.pin_key,
            p.sources,
            e.occurs_at_local::timestamp with time zone AS occurs_at,
            EXTRACT(epoch FROM e.occurs_at_local::timestamp with time zone - now()) / 3600.0 AS hours_to_event,
            p.sg_owned_cadence AS sg_owned
           FROM listings_poll_pins p
             JOIN events e ON e.primary_performer_id = p.performer_id AND (p.venue_name IS NULL OR e.venue_name = p.venue_name)
          WHERE p.enabled AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'::text AND e.occurs_at_local::timestamp with time zone > (now() - '03:00:00'::interval) AND COALESCE(e.state, 'shown'::text) <> 'ignored'::text
        UNION ALL
         SELECT e.id,
            'league:'::text || lp.league,
            lp.sources,
            e.occurs_at_local::timestamp with time zone AS occurs_at_local,
            EXTRACT(epoch FROM e.occurs_at_local::timestamp with time zone - now()) / 3600.0 AS "numeric",
            lp.sg_owned_cadence
           FROM listings_poll_league_pins lp
             JOIN performer_espn_team_xref x ON upper(x.espn_league) = lp.league
             JOIN events e ON e.primary_performer_id = x.tevo_performer_id
          WHERE lp.enabled AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'::text AND e.occurs_at_local::timestamp with time zone > (now() - '03:00:00'::interval) AND COALESCE(e.state, 'shown'::text) <> 'ignored'::text
        UNION ALL
         -- an open N2S obligation pins its event on all three markets, so that
         -- n2s_cover_verify() keeps a capture to re-check against (mig 20261125193000).
         -- Derived, not configured: it arrives with the sale and leaves when the
         -- obligation goes terminal. pin_key sorts after every performer pin, so a
         -- performer pin's own sg_owned_cadence still wins the DISTINCT ON.
         SELECT e.id,
            'n2s:obligation'::text,
            ARRAY['evo'::text, 'gt'::text, 'sg'::text],
            e.occurs_at_local::timestamp with time zone AS occurs_at_local,
            EXTRACT(epoch FROM e.occurs_at_local::timestamp with time zone - now()) / 3600.0 AS "numeric",
            false
           FROM events e
          WHERE e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'::text AND e.occurs_at_local::timestamp with time zone > (now() - '03:00:00'::interval) AND COALESCE(e.state, 'shown'::text) <> 'ignored'::text
            AND COALESCE((SELECT s.value FROM public.settings s WHERE s.key = 'listings_poll_n2s_pin'), 'on') <> 'off'
            AND EXISTS (SELECT 1 FROM public.n2s_items i
                         WHERE i.tevo_event_id = e.id AND NOT i.is_terminal)) u
  ORDER BY tevo_event_id, sg_owned DESC, pin_key;

COMMIT;
