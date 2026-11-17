-- ============================================================================
-- Migration 20260910370000 — N2S: the integration manual and the error-code
--                            registry, served FROM the database
--
-- Lane:     D7 (n2s obligation-covering) over A1's DB plane
-- Level:    additive — two new reference tables, RLS + authenticated-read.
--           No existing object is altered. No data is mutated.
-- Touches:  n2s_error_code (NEW), n2s_integration_doc (NEW), n2s_manual() (NEW)
-- Pre-reqs: 20260910360000 (n2s_profitable_cover — what the docs describe)
--
-- Upstream: no API call at all. RULE 2 untouched.
--
-- Operator direction 2026-09-10: "write the d7 docs and add to supabase so
-- external can get instructions and step by step instructions on how this
-- system works and create and provide error codes so we can track."
--
-- ── WHY THE DOCS LIVE IN THE DATABASE AND NOT ONLY IN THE REPO ────────────
-- The consumer of this feed is EXTERNAL. They have a project URL and a key;
-- they do not have this repository and never will. A manual in docs/ is
-- therefore invisible to exactly the audience it is written for. So the same
-- content is seeded here, reachable with the credentials they already hold:
--
--   select * from n2s_integration_doc order by step_no;
--   select * from n2s_error_code order by sort_order;
--
-- `docs/d7_n2s_pipeline.md` remains the lane manual for US. These tables are
-- the contract for THEM. Where they overlap, THIS is the source of truth for
-- the integration surface, because it is the copy the integrator can actually
-- read — and it cannot drift out of sync with a schema it lives inside.
--
-- ── ⚠ ERROR CODES ARE A PROMISE, NOT LABELS ───────────────────────────────
-- A code is STABLE. Once issued it is never re-pointed at a different
-- meaning, because a consumer will have written `if code == 'N2S-S103'`
-- against it. To change what a code means, RETIRE it (set retired_at, leave
-- the row in place so the lookup still resolves) and issue a new one. Do NOT
-- edit `meaning` on a live row beyond clarifying wording.
--
-- ── ⚠ AUTHENTICATED, NOT ANON — DELIBERATE ────────────────────────────────
-- These two tables carry no order data, so a case could be made for anon
-- read. It is deliberately NOT made: they describe the schema, the columns
-- and the access model of a feed that DOES carry order numbers, prices and
-- buy links, and the whole N2S surface grants `authenticated` only. A reader
-- who cannot authenticate cannot use the feed either, so anon access would
-- buy nothing and widen the surface. If the operator later wants the manual
-- public, that is a one-line GRANT + policy on these two tables ALONE and
-- must never be extended to n2s_profitable_cover.
-- ============================================================================

-- ── 1. the error-code registry ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.n2s_error_code (
  code        text PRIMARY KEY,
  category    text NOT NULL,          -- ingest | mapping | source | cover | push | access
  severity    text NOT NULL,          -- info | warn | error
  title       text NOT NULL,
  meaning     text NOT NULL,          -- what the system observed
  emitted_by  text NOT NULL,          -- which stage/object raises it (where to look)
  what_to_do  text NOT NULL,          -- the action, or explicitly "none — expected"
  sort_order  integer NOT NULL,
  retired_at  timestamptz             -- set to retire a code; never delete the row
);

COMMENT ON TABLE public.n2s_error_code IS
  'Stable N2S error/status codes. A code is a PROMISE to external consumers: '
  'never re-point one at a new meaning — retire it (set retired_at, keep the '
  'row so lookups still resolve) and issue a new code instead.';

-- ── 2. the step-by-step integration manual ─────────────────────────────────
CREATE TABLE IF NOT EXISTS public.n2s_integration_doc (
  slug        text PRIMARY KEY,
  step_no     integer NOT NULL,
  title       text NOT NULL,
  body        text NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.n2s_integration_doc IS
  'Step-by-step N2S integration manual, served from the database because the '
  'audience is external and has no access to the repo. Read in order: '
  'select * from n2s_integration_doc order by step_no.';

-- ── 3. security: same posture as n2s_profitable_cover ─────────────────────
ALTER TABLE public.n2s_error_code       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n2s_integration_doc  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS n2s_error_code_read ON public.n2s_error_code;
CREATE POLICY n2s_error_code_read ON public.n2s_error_code
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS n2s_integration_doc_read ON public.n2s_integration_doc;
CREATE POLICY n2s_integration_doc_read ON public.n2s_integration_doc
  FOR SELECT TO authenticated USING (true);

REVOKE ALL ON public.n2s_error_code      FROM PUBLIC, anon;
REVOKE ALL ON public.n2s_integration_doc FROM PUBLIC, anon;
GRANT SELECT ON public.n2s_error_code      TO authenticated;
GRANT SELECT ON public.n2s_integration_doc TO authenticated;

-- ── 4. seed the codes ──────────────────────────────────────────────────────
-- Grounded in what the pipeline ACTUALLY emits (the v_n2s_orders
-- no_cover_reason CASE, n2s_td_drain's return flags, n2s_cover_push.error_msg,
-- and PostgREST/RLS behaviour), not in a plausible-looking taxonomy.
INSERT INTO public.n2s_error_code
  (code, category, severity, title, meaning, emitted_by, what_to_do, sort_order)
VALUES
 ('N2S-C000','cover','info','Cover found',
  'A matching listing was found and priced for this obligation.',
  'n2s_cover_queue / v_n2s_orders.has_cover',
  'None — this is the success case.',10),

 ('N2S-C100','cover','info','No match',
  'Sources WERE polled for this event; nothing matched the section, row and quantity owed.',
  'v_n2s_orders.no_cover_reason = ''no_match''',
  'None — expected. The obligation stays open and is re-checked every minute as listings change.',20),

 ('N2S-C200','cover','warn','Cover found but not profitable',
  'A cover exists, but buying it costs at least what we sold for (cover_cost >= 0).',
  'n2s_cover_queue.cover_cost',
  'Visible in the internal panel; deliberately EXCLUDED from n2s_profitable_cover. A buyer decision, not a fault.',30),

 ('N2S-M100','mapping','error','Obligation is unmapped',
  'The order has no tevo_event_id, so there is no event to poll listings against.',
  'v_n2s_orders.no_cover_reason = ''unmapped''',
  'This obligation can never be covered while unmapped. Resolve the event in the AQ mapper.',40),

 ('N2S-M101','mapping','error','Event mapped but not catalogued',
  'The obligation carries a tevo_event_id that does not exist in public.events.',
  'v_n2s_orders.no_cover_reason = ''event_not_catalogued''',
  'Ingest the event. Do NOT work around it by polling anyway: evo_listings_poll_state.event_id has an FK to events.id, so the poll raises 23503 and, because map+pull share one transaction, the mapping rolls back with it.',50),

 ('N2S-S100','source','info','Awaiting source pull',
  'Mapped, but the four marketplaces have not been polled for this event yet.',
  'v_n2s_orders.no_cover_reason = ''awaiting_source_pull''',
  'Transient — clears within a tick. If it persists across many minutes the poller is stuck; check cron 598.',60),

 ('N2S-S101','source','info','TEvo skipped an uncatalogued event',
  'The TEvo arm declined to poll an event absent from public.events.',
  'n2s_pull_events() -> evo_skipped_unknown',
  'None — this is the guard working. Its companion is N2S-M101; fix that and this clears.',70),

 ('N2S-S102','source','warn','TicketsData vendor quota exhausted',
  'TicketsData answered 403 quota_exhausted. This is the VENDOR allowance, not our own cap.',
  'td_pull_queue.error_msg = ''quota_exhausted''',
  'Backs off automatically. Recurring = the account allowance is genuinely spent; see N2S-S103.',80),

 ('N2S-S103','source','warn','TicketsData fell back to the shared account',
  'The N2S-specific TicketsData credentials are unseeded, so this lane drew on the SHARED vendor account.',
  'n2s_td_drain() -> using_shared_account = true',
  'Seed TICKETSDATA_N2S_USERNAME and TICKETSDATA_N2S_PASSWORD in the Supabase dashboard Vault (NOT via execute_sql — a value passed that way lands in the Postgres query log). Until then this lane takes quota the venue sweep and watchlist polling depend on.',90),

 ('N2S-S104','source','info','Daily cap reached',
  'Our own 500/day N2S cap on TicketsData was hit; further pulls skipped until reset.',
  'n2s_td_drain() -> remaining_today = 0',
  'None — lane safety working as designed. While the shared-account fallback (N2S-S103) is active this cap is the ONLY thing protecting the shared quota, so do not raise it casually.',100),

 ('N2S-I100','ingest','error','CRM unreachable',
  'The S4K CRM N2S endpoint did not answer, or answered non-200.',
  'n2s_pull_items()',
  'The order book stops advancing — no new obligations appear at all. Check the endpoint before assuming there is simply no work.',110),

 ('N2S-I101','ingest','error','CRM rejected our key',
  'The CRM refused the N2S API key (scope n2s:read).',
  'n2s_pull_items()',
  'The key is invalid, revoked or rotated. Re-seed it in the Vault.',120),

 ('N2S-I102','ingest','error','Upsert batch aborted on a duplicate key',
  'The CRM feed repeated a (source, id) pair INSIDE a single payload, aborting the whole batch.',
  'n2s_pull_items() upsert',
  'Deduplicate within the batch before upserting. Note this is intermittent by nature: a clean manual run proves nothing.',130),

 ('N2S-I103','ingest','error','Typed-field cast failure',
  'The CRM feed shipped the string "None" or an empty string in a typed date or price field.',
  'n2s_pull_items() cast',
  'A bare cast aborts the ENTIRE batch, not the one row. Coerce "None"/empty to NULL before casting.',140),

 ('N2S-P000','push','info','Webhook delivered',
  'The receiver accepted the profitable-cover payload (2xx).',
  'n2s_cover_push.status_code',
  'None.',150),

 ('N2S-P100','push','info','No webhook configured — outbox inert',
  'No N2S_COVER_WEBHOOK_URL secret is set, so the push drain does nothing.',
  'n2s_cover_push_drain()',
  'None — this is the CURRENT INTENDED STATE. The Supabase table + Realtime feed is the delivery path; the webhook is a complementary option, not a dependency.',160),

 ('N2S-P101','push','error','Receiver returned 4xx',
  'The configured receiver rejected the payload.',
  'n2s_cover_push.status_code',
  'Check the receiver token and the payload shape it expects.',170),

 ('N2S-P102','push','error','Receiver returned 5xx',
  'The configured receiver failed server-side.',
  'n2s_cover_push.status_code',
  'Receiver-side; the row is retried. Persistent 5xx means the receiver is down.',180),

 ('N2S-P103','push','error','No response before timeout',
  'The request was fired but never resolved within the timeout.',
  'n2s_cover_push.resolved_at IS NULL past the timeout',
  'Check receiver reachability from the database network path.',190),

 ('N2S-P104','push','error','Blocked by the RULE-2 host guard',
  'The configured webhook URL points at a listing-source host, and the drain refused to send.',
  'n2s_cover_push_drain() host guard',
  'HARD STOP, never a config nit. RULE 2 forbids this project influencing a listing source; a webhook aimed at one would be an outbound write to a marketplace. Point the webhook at your own receiver.',200),

 ('N2S-A100','access','error','401 — missing or invalid apikey',
  'The request carried no apikey header, or one the project does not recognise.',
  'PostgREST / Supabase gateway',
  'Send the project PUBLISHABLE (anon) key as the apikey header. Never the service_role key — it bypasses RLS on every table in the project.',210),

 ('N2S-A101','access','error','Permission denied (42501)',
  'Reading as the anon role. The N2S feed grants SELECT to `authenticated` only.',
  'RLS policy on n2s_profitable_cover',
  'Sign in as a real Supabase Auth user and send that user JWT as the Authorization: Bearer header, in addition to the apikey header.',220),

 ('N2S-A102','access','warn','200 OK but an empty array',
  'The request succeeded and RLS filtered every row. This is NOT proof there are no profitable covers.',
  'RLS policy on n2s_profitable_cover',
  'Confirm the Authorization header carries a signed-in user JWT, not the bare anon key. An anon read is shaped exactly like a genuine empty result — that ambiguity is the single most common integration mistake here.',230),

 ('N2S-A103','access','warn','Realtime subscribes but never fires',
  'The websocket connected, but no change events arrive.',
  'Supabase Realtime',
  'The same RLS rule applies to the socket as to a REST read (see N2S-A102). Also confirm the table is in the supabase_realtime publication. Note a genuinely quiet minute emits NOTHING by design — the sync is a diff, so silence is a valid state, not a fault.',240)
ON CONFLICT (code) DO UPDATE SET
  category   = EXCLUDED.category,   severity   = EXCLUDED.severity,
  title      = EXCLUDED.title,      meaning    = EXCLUDED.meaning,
  emitted_by = EXCLUDED.emitted_by, what_to_do = EXCLUDED.what_to_do,
  sort_order = EXCLUDED.sort_order;

-- ── 5. seed the step-by-step manual ────────────────────────────────────────
INSERT INTO public.n2s_integration_doc (slug, step_no, title, body) VALUES
 ('overview', 1, 'What this feed is',
  'We sell tickets we do not physically hold. When such an order lands it becomes an OBLIGATION: we owe the buyer seats and must buy replacements before the delivery timer expires. This pipeline watches four marketplaces every minute, matches available listings against each obligation, prices the cover, and publishes the subset where buying the cover STILL MAKES MONEY.

You are consuming that subset: public.n2s_profitable_cover. One row = one open obligation with a profitable cover available RIGHT NOW. Rows appear, change and disappear as live marketplace inventory moves.

The pipeline never buys anything and never writes to a marketplace. It surfaces a buy link; a human clicks it.'),
 ('credentials', 2, 'Credentials — read this before anything else',
  'You need exactly two things: the project URL, and the PUBLISHABLE (anon) API key.

You will ALSO need a Supabase Auth user (email + password) in this project, because the feed grants SELECT to the `authenticated` role only. Ask the operator to create one for you; do not expect the anon key alone to return rows.

*** NEVER ASK FOR, AND NEVER ACCEPT, THE service_role KEY. *** It bypasses row-level security on every table in the project, not just this feed. Handing it to an integrator hands over the entire database. If anyone offers it to you, decline and ask for an Auth user instead.'),
 ('read-current-state', 3, 'Step 1 — read what is profitable right now',
  'A plain REST read answers "what should I be acting on this second":

  GET {PROJECT_URL}/rest/v1/n2s_profitable_cover?select=*&order=profit.desc
  apikey: {PUBLISHABLE_KEY}
  Authorization: Bearer {USER_ACCESS_TOKEN}

Both headers are required. With only the apikey you are the anon role and will get an empty array — which looks identical to "nothing is profitable". See error code N2S-A102; this is the most common integration mistake with this feed.

This is also your RECOVERY path: if your subscriber disconnects, re-read this endpoint to resync rather than trying to replay missed events.'),
 ('subscribe-realtime', 4, 'Step 2 — subscribe for live changes',
  'Subscribe to postgres_changes on schema `public`, table `n2s_profitable_cover`, events INSERT, UPDATE and DELETE. Using supabase-js:

  const supabase = createClient(PROJECT_URL, PUBLISHABLE_KEY)
  await supabase.auth.signInWithPassword({ email, password })
  supabase.channel(''n2s'')
    .on(''postgres_changes'',
        { event: ''*'', schema: ''public'', table: ''n2s_profitable_cover'' },
        payload => handle(payload))
    .subscribe()

Sign in BEFORE subscribing — the same RLS rule applies to the websocket as to a REST read, so an unauthenticated socket connects successfully and then never fires (error code N2S-A103).'),
 ('interpret-events', 5, 'Step 3 — what each event means',
  'INSERT — a new profitable cover appeared. Act on it: this is the whole point of the feed. These are time-sensitive; live inventory moves.

UPDATE — an existing cover changed (usually price, therefore profit, or a different listing became the best option). Re-read the row; do not assume your cached copy is still correct.

DELETE — the cover is GONE: someone bought it, it stopped being profitable, or the obligation was resolved. UN-FLAG IT on your side. The event carries the FULL old row (the table is set to REPLICA IDENTITY FULL specifically so you can tell which order went away), so you never have to guess from the id alone.

SILENCE IS A VALID STATE. The sync writes only genuine differences, so a minute with no change emits nothing at all. Do not treat quiet as a broken connection — that is exactly what makes an event meaningful when one does arrive.'),
 ('columns', 6, 'The columns, and which ones a buyer actually needs',
  'To ACT on a row you need six columns:

  order_number   — the marketplace order we owe
  order_key      — the CRM order reference; use THIS to pull the order up in the CRM in real time. It is not always the same string as order_number.
  sub_section    — section of the replacement seats to buy
  sub_row        — row of the replacement seats
  sub_qty        — HOW MANY TO BUY (see the warning below)
  buy_url        — deep link to the exact listing on the source marketplace

*** sub_qty IS NOT ALWAYS sold_qty. *** When a lot one seat larger than the obligation is cheaper in total than an exact match, the pipeline selects it deliberately and we absorb the spare seat. In that case sub_qty = sold_qty + 1. BUY sub_qty. Buying sold_qty instead will fail, because that lot is only sellable whole — which is precisely why it was cheap.

Context columns: marketplace, event_name, event_date, venue, tevo_event_id, sold_section, sold_row, sold_qty, sold_price_each, sub_source, sub_listing_id, sub_lot_size, sub_price_each, sub_total, first_seen_at, updated_at.

profit = (sold_price_each x sold_qty) - sub_total, in USD. Every row in this table has profit > 0; unprofitable covers are filtered out before you ever see them (error code N2S-C200).'),
 ('error-codes', 7, 'Step 4 — error codes, and how to track them',
  'Every failure mode this pipeline can show you has a STABLE code:

  select code, category, severity, title, meaning, what_to_do
    from n2s_error_code where retired_at is null order by sort_order;

Log the CODE, not the message text — messages get reworded, codes do not. A code is never re-pointed at a new meaning; if the meaning changes, the old code is retired (retired_at set, row kept so your lookups still resolve) and a new code is issued.

The codes you will hit as an integrator are the N2S-A1xx family (access). Start there when a read returns nothing. The N2S-C/M/S/I/P families describe internal pipeline state and are given so that "there are no covers today" is an answer you can INVESTIGATE rather than merely accept.'),
 ('troubleshooting', 8, 'Troubleshooting, in the order to check',
  '1. Empty array, 200 OK -> you are almost certainly the anon role. N2S-A102. Send the user JWT in Authorization, not just the apikey. Verify by reading n2s_integration_doc: if THAT is also empty, it is authentication, not data.

2. 401 -> the apikey header is missing or wrong. N2S-A100.

3. permission denied / 42501 -> anon has no grant on this table by design. N2S-A101.

4. Socket connects, nothing arrives -> sign in before subscribing. N2S-A103. Then confirm with a REST read that rows exist at all; if the REST read returns rows and the socket stays silent, the subscription is the problem, not the data.

5. Rows exist but far fewer than expected -> that is real. Only PROFITABLE covers reach this table, and only obligations that are mapped, catalogued and polled can produce one. Ask the operator to check N2S-M100 / N2S-M101 / N2S-S100 counts.

6. A buy_url 404s or the listing is gone -> live inventory moved. Expect a DELETE event shortly. This is normal, not a data-quality fault.'),
 ('guarantees', 9, 'What is guaranteed, and what is not',
  'GUARANTEED:
  - Every row present has profit > 0 at the time it was last synced.
  - Codes in n2s_error_code are stable and never re-pointed.
  - A DELETE event carries the full previous row.
  - Column ADDITIONS may happen; select the columns you need by name rather than relying on position or on select=*.

NOT GUARANTEED:
  - That a listing is still purchasable when you click it. Marketplace inventory is live and we do not hold it. There is no reservation.
  - Ordering. Always sort explicitly.
  - Delivery of every intermediate state. If you disconnect, RE-READ the table (step 1) rather than attempting to replay events.
  - Any write path. This feed is READ-ONLY to you. There is no endpoint here that buys, holds or reserves anything, and none will be added.')
ON CONFLICT (slug) DO UPDATE SET
  step_no = EXCLUDED.step_no, title = EXCLUDED.title,
  body    = EXCLUDED.body,    updated_at = now();

-- ── 6. one-call convenience for a fresh integrator ─────────────────────────
-- SECURITY INVOKER on purpose: RLS applies exactly as it does to a direct
-- read, so this cannot become a side door around the authenticated-only rule.
CREATE OR REPLACE FUNCTION public.n2s_manual()
RETURNS TABLE(step_no integer, title text, body text)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
  SELECT d.step_no, d.title, d.body
    FROM public.n2s_integration_doc d
   ORDER BY d.step_no
$function$;

COMMENT ON FUNCTION public.n2s_manual() IS
  'The N2S integration manual in order — one RPC for a fresh integrator: '
  'select * from n2s_manual(). SECURITY INVOKER so RLS still applies.';

REVOKE ALL ON FUNCTION public.n2s_manual() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_manual() TO authenticated;
