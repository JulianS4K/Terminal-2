-- Migration 20260531120000 · lane:D0-authored → A1-apply · writes:get_event_td_pull_health · reads:sg_events_canonical,aq_event_map,ticketsdata_event_xref,td_pull_queue · pre:(main HEAD) · auth:PENDING — D0-authored, NOT YET APPLIED; awaiting A1 review + apply (bot_chat flagged)
--
-- ⚠ D0 HAS NO APPLY AUTHORITY (BOT_HIERARCHY §6 / PROJECT_BIBLE §1+§6). Authored by D0
--   for the TD Markets tab "cron timers & health" panel. A1 reviews + applies. Timestamp
--   is provisional (worktree forks before main's 0530 migs) — A1 may bump on apply.
--
-- WHY: the TD Markets tab needs per-event-per-platform pull timing + health (last pull,
--   pulls today, last status / rows, freshness). That data lives in ticketsdata_event_xref
--   (last_enqueued_at / last_fetched_at / enqueues_today / active) + td_pull_queue
--   (status_code / rows_inserted / fired_at / resolved_at / interval_tag) — BOTH are
--   service-role-walled (RLS `*_service_only`, no authenticated SELECT), so the FE (Path-C)
--   cannot read them. This SECDEF wrapper resolves the TEvo→TD chain and returns the JSON.
--   Cron *cadences* (next-pull schedule) are static + live in cron.* (also FE-unreadable);
--   the FE computes next-enqueue from a hardcoded per-platform schedule, so this RPC returns
--   only the live per-event timing/health.
--
-- KEYING (PROJECT_BIBLE §3a / D0_BIBLE §3h): TD tables are native-keyed; resolve
--   tevo_event_id → sg_events_canonical → aq_event_map.aq_short_event_id → ticketsdata_event_xref.
--   DISTINCT ON (platform) picks the most-recently-fetched xref row per platform (guards the
--   split-aq case). Latest pull per platform via LATERAL over td_pull_queue (fired_at NOT NULL).
--
-- VALIDATION (read-only, 2026-05-31, event 3346011): SH last 19:08 / 200 / 968 rows (2× today),
--   GT 17:24 / 200 / 179, VD 21:10 / 200 / 474, TP 16:26 / 200 / 670, TM 16:38 / 200 / 0
--   (on-sale pending). All active.
--
-- PATTERN: SECDEF + @s4kent.com email gate + REVOKE PUBLIC + GRANT anon/authenticated +
--   STABLE — identical to get_event_chart_extended (mig 20260519150000). Read-only.

CREATE OR REPLACE FUNCTION public.get_event_td_pull_health(
  p_event_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_aq    text[];
  v_plats jsonb;
BEGIN
  -- ---------- auth gate (mirrors v3 / sibling SECDEF RPCs) ----------
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- ---------- resolve TEvo → aq_short_event_id(s) (chain) ----------
  SELECT array_agg(DISTINCT aem.aq_short_event_id)
  INTO v_aq
  FROM public.sg_events_canonical sgc
  JOIN public.aq_event_map aem ON aem.sg_event_id = sgc.sg_event_id
  WHERE sgc.tevo_event_id = p_event_id;

  IF v_aq IS NULL THEN
    RETURN jsonb_build_object('tevo_event_id', p_event_id, 'hidden', true,
                              'reason', 'no_td_mapping', 'platforms', '[]'::jsonb);
  END IF;

  -- ---------- per-platform xref timing + latest pull-queue health ----------
  WITH xref AS (
    SELECT DISTINCT ON (x.platform)
      x.platform, x.active, x.always_on, x.enqueues_today,
      x.last_enqueued_at, x.last_fetched_at, x.event_id
    FROM public.ticketsdata_event_xref x
    WHERE x.aq_short_event_id = ANY(v_aq) AND x.active = true
    ORDER BY x.platform, x.last_fetched_at DESC NULLS LAST
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'platform',         x.platform,
    'active',           x.active,
    'always_on',        x.always_on,
    'enqueues_today',   x.enqueues_today,
    'last_enqueued_at', to_char(x.last_enqueued_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'last_fetched_at',  to_char(x.last_fetched_at  AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'last_status',      q.status_code,
    'last_rows',        q.rows_inserted,
    'last_fired_at',    to_char(q.fired_at    AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'last_resolved_at', to_char(q.resolved_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'last_interval',    q.interval_tag,
    'last_error',       left(coalesce(q.error_msg, ''), 80)
  ) ORDER BY x.platform), '[]'::jsonb)
  INTO v_plats
  FROM xref x
  LEFT JOIN LATERAL (
    SELECT status_code, rows_inserted, fired_at, resolved_at, interval_tag, error_msg
    FROM public.td_pull_queue q2
    WHERE q2.event_id = x.event_id AND q2.platform = x.platform AND q2.fired_at IS NOT NULL
    ORDER BY q2.fired_at DESC
    LIMIT 1
  ) q ON true;

  RETURN jsonb_build_object(
    'tevo_event_id', p_event_id,
    'hidden',        false,
    'generated_at',  to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'platforms',     coalesce(v_plats, '[]'::jsonb)
  );
END $func$;

REVOKE ALL ON FUNCTION public.get_event_td_pull_health(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_td_pull_health(bigint) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_td_pull_health(bigint) IS
  'D0 TD Markets tab — per-event-per-platform TD pull timing + health (cron timers panel). Resolves tevo_event_id → aq_event_map → ticketsdata_event_xref (last_fetched/enqueued, enqueues_today, active) + latest td_pull_queue row (status/rows/latency/interval). Both source tables are service-role-walled; this SECDEF wrapper exposes them read-only. Email-gated @s4kent.com, STABLE. D0-authored; A1 applies.';
