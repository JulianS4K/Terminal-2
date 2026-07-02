# Exos event preflight runbook

**Doc version:** v1.0.0 (2026-07-02)

On-demand operational reference (not a session-start read). Run through this
before a real Exos/Bridge event goes on sale and again on event day. It exists
because the failure modes that hurt a live event are mostly *operational*
(deploy state, Stripe config, doors timing, connectivity), not code bugs — the
code fixes only help once they're deployed and configured correctly.

Ordered by when it bites: **deploy → on-sale → doors → post-event.**

---

## 1. Deploy state — the fixes must actually be live

A green PR on `main` protects nothing until two separate steps happen.

- [ ] **Migrations applied.** The `20260702*` migrations (check-in hardening,
      doors gate + test-window auto-expiry, transfer leak, voucher single-use,
      waitlist IDOR, reconcile cron) are applied to the Supabase project by A1.
      Verify the DB actually has them:
  ```sql
  SELECT name FROM supabase_migrations.schema_migrations
   WHERE name LIKE '20260702%' ORDER BY name;
  ```
- [ ] **Edge functions deployed.** `stripe-webhook`, `exos-checkout`,
      `exos-webhook-drain`, and the new `exos-reconcile-checkouts` are redeployed
      (the payment-gate, add-on clamp, SSRF fix, and reconcile net live in edge
      code, not migrations).
- [ ] **Reconcile cron scheduled + secret present.**
  ```sql
  SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'exos-reconcile-checkouts-15min';
  SELECT (SELECT 1 FROM vault.decrypted_secrets WHERE name='CRON_SECRET') AS cron_secret_present;
  ```

## 2. Stripe / payments

- [ ] **Webhook endpoint + secret.** The `stripe-webhook` endpoint is registered
      in the Stripe dashboard for this account, subscribed to
      `checkout.session.completed` and `account.updated`, and its signing secret
      is set as `STRIPE_WEBHOOK_SECRET`. A wrong/missing secret = every payment
      succeeds but no ticket mints (silent).
- [ ] **Connect onboarding complete for the organizer.** If the org's connected
      account isn't fully onboarded, `transfer_data.destination` checkouts fail
      and buyers can't pay at all.
  ```sql
  SELECT org_id, charges_enabled, payouts_enabled, connected_account_id
    FROM exos_org_stripe WHERE org_id = '<ORG>';
  ```
- [ ] **Async payment methods.** If the Stripe account enables delayed methods
      (ACH/SEPA/Bacs/Boleto), the fixed `stripe-webhook` only mints on a settled
      `payment_status` — confirm the deploy from §1 is live, or keep the account
      to card-only for the on-sale.

## 3. Doors / check-in

- [ ] **`doors_at` is set and correct (timezone!).** The check-in gate refuses
      scans before `coalesce(doors_at, starts_at)`, with **no grace window**. A
      wrong timezone or a doors-vs-start mix-up locks the gate.
  ```sql
  SELECT id, name, status, timezone, starts_at, doors_at,
         checkin_test_mode, checkin_test_until
    FROM exos_events WHERE id = '<EVENT>';
  ```
- [ ] **Test mode is OFF for the real event.** `checkin_test_mode` should be
      false or `checkin_test_until` in the past. Test mode now auto-expires, but
      confirm nothing is holding it open:
  ```sql
  SELECT id, name, checkin_test_until FROM exos_events
   WHERE checkin_test_mode AND checkin_test_until > now();
  ```
      To enable a bounded test window (owner/manager): `SELECT exos_set_checkin_test_window('<EVENT>', 3);`
      (3 hours; capped at 24). Pass `0` to clear.
- [ ] **Gate connectivity.** The scanner is offline-first: the "already scanned"
      lock only holds **online**. On flaky wifi the same ticket can be admitted
      at two lanes, and a transfer after the offline registry synced will reject
      the new owner. Ensure solid connectivity at the gate; sync the registry as
      late as possible; freeze/avoid transfers close to doors.
- [ ] **Clock-skew fallback briefed.** A buyer with a badly-set phone clock fails
      the ~±90s barcode window ("code expired"). Staff recovery is **manual
      ticket-ID entry**, not turning the holder away.

## 4. On-sale watch

- [ ] **Single replica during on-sale.** `d4_bridge/server.ts` uses an in-memory
      per-process rate limiter; scaling out silently removes the limit until a
      Redis-backed limiter lands.
- [ ] **Oversell via bypass vouchers.** `bypass_capacity` vouchers (waitlist
      auto-offers, comps) intentionally skip caps. Watch:
  ```sql
  SELECT id, name, total_tickets, tickets_sold FROM exos_events WHERE id='<EVENT>';
  ```

## 5. Charged-but-no-ticket monitors (during + after sale)

The `exos-reconcile-checkouts` cron handles these automatically every 15 min, but
verify manually around a hot on-sale:

- **Stuck paid-but-pending** (webhook missed — reconcile will retry-mint):
  ```sql
  SELECT session_id, created_at FROM exos_checkout_sessions
   WHERE status='pending' AND created_at < now() - interval '15 min'
   ORDER BY created_at;
  ```
- **Failed-but-charged** (reconcile will auto-refund; these should trend to zero):
  ```sql
  SELECT session_id, failure_reason, created_at FROM exos_checkout_sessions
   WHERE status='failed' ORDER BY created_at DESC LIMIT 50;
  ```
  Rows that reach `status='refunded'` with `(auto-refunded by reconcile)` in
  `failure_reason` were handled.

## 6. Post-event

- **Double-scan reconciliation** (offline lanes admitting the same ticket):
  ```sql
  SELECT ticket_id, count(*) FROM exos_event_checkins
   WHERE event_id='<EVENT>' GROUP BY ticket_id HAVING count(*) > 1;
  ```
- **Confirm no lingering charges:** re-run the §5 queries; nothing should sit in
  `pending` (all should be `fulfilled`/`expired`) or unrefunded `failed`.

---

Known residual (not fixed by code, watch operationally): offline double-entry
under a full network partition can't be prevented without connectivity — the
authoritative `used` flip only happens online. Freeze transfers near doors and
run the §6 reconciliation to catch it.
