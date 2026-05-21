# Exos

A ticketing platform for live events: organizers create events and tiered
inventory, attendees buy and transfer tickets, organizers check attendees in
at the door (online or offline). React + Vite frontend, an Express dev/serve
layer, Firebase Auth + Firestore for persistence, and Stripe Checkout for
payments.

> **Status:** the app boots and the type-check + production build are clean.
> Stripe-side fulfillment (webhook + server-side ticket creation) and the
> Automatiq distribution-network sync are deferred to a later phase.
> See `firestore.rules` for the security model and known gaps.

## Stack

- **Frontend:** React 19 + Vite, Tailwind, Framer Motion, lucide-react.
- **Server:** Express (TypeScript via tsx), used for the dev SPA and a thin
  API surface that today only fronts Stripe Checkout.
- **Auth + DB:** Firebase Auth, Firestore. Rules in `firestore.rules`.
- **Payments:** Stripe Checkout (deferred-phase work pending — see notes
  in `firestore.rules` and `server.ts`).

## Prerequisites

- Node.js 20+
- A Firebase project (Auth + Firestore enabled)
- A Stripe account (only required when you wire up checkout)

## Setup

1. **Install dependencies**

   ```bash
   npm install
   ```

2. **Provide a Firebase web config** at `firebase-applet-config.json` in
   the project root. The shape is:

   ```json
   {
     "projectId": "...",
     "appId": "...",
     "apiKey": "...",
     "authDomain": "....firebaseapp.com",
     "firestoreDatabaseId": "...",
     "storageBucket": "....firebasestorage.app",
     "messagingSenderId": "...",
     "measurementId": ""
   }
   ```

   The Firebase web `apiKey` is an app identifier, not a secret — security
   is enforced by Firestore Rules + Auth on the project side.

3. **Copy `.env.example` to `.env`** and fill in the Stripe variables (only
   needed when running the checkout endpoints).

4. **Deploy the Firestore rules** from `firestore.rules` to your project:

   ```bash
   firebase deploy --only firestore:rules
   ```

## Run locally

```bash
npm run dev      # Vite middleware + Express on http://localhost:3000
npm run lint     # tsc --noEmit
npm run build    # production bundle to dist/
npm start        # serve the built bundle (NODE_ENV=production)
```

The server reads `PORT` from the environment when set (Cloud Run, Render,
Fly, Heroku, etc. all need this). It also exposes `GET /healthz` for load
balancers.

## Architecture notes

- Routes are lazy-loaded (`src/App.tsx`); the home page is the only eager
  one. `vite.config.ts` puts firebase, stripe, qr, and motion in their own
  chunks so they can be cached independently.
- Toasts are surfaced via `src/context/ToastContext.tsx`; do not use the
  built-in `alert()` for user-visible feedback.
- Errors hitting Firestore should go through `handleFirestoreError` in
  `src/lib/utils.ts` so the auth context is captured.
- The service worker (`public/sw.js`) caches the static shell only —
  it never caches `/api/*`, Firestore, Auth, or Stripe traffic.

## Required Firestore composite indexes

Two queries in this codebase need composite indexes that Firestore
won't auto-generate. The Firebase console will surface a one-click
create link the first time the query runs in production, but
pre-creating them prevents the first reader from seeing an error.

1. **Org storefront events list** — `orgs/{org}/events?orgId==X&status==Y`:
   - Collection: `events`
   - Fields: `orgId` Asc, `status` Asc, `date` Asc

2. **Per-uid transfer lookups** — already in place from the original
   schema, but reconfirm in `firebase deploy` output: `transfers`
   indexed on `senderId` Asc + `status` Asc, and on `receiverEmail`
   Asc + `status` Asc.

Configure via `firestore.indexes.json` and deploy with
`firebase deploy --only firestore:indexes`.

## Production deployment notes

- **HTTPS is mandatory.** Rotating ticket barcodes use the Web Crypto
  API (`crypto.subtle`), which the browser only exposes on secure
  contexts (HTTPS or localhost). Run the SPA over plain HTTP in
  production and every barcode operation fails — buyers can't render
  their QR, organizers can't verify scans. Most managed hosts (Cloud
  Run, Render, Fly, Vercel) terminate TLS for you; just don't bypass
  it.
- The barcode design assumes the server-issued ticket carries a
  per-ticket `barcodeSecret`. Tickets minted in `MyTickets.tsx`
  (post-Stripe-checkout fulfillment) generate one with
  `crypto.randomUUID()` at write time; transfers rotate the secret
  on claim. Tickets without a secret fall through to a "legacy
  unsigned" branch that the organizer's check-in deliberately accepts
  for backwards-compat — the rotation only matters for tickets that
  do carry a secret.
- The HMAC verifier (`src/lib/barcode.ts`) tolerates a 2-bucket
  window (~60–90s) of clock skew between the buyer's phone and the
  organizer's scanner. NTP-synced devices drift sub-second; manually
  set clocks more than ~90s off will fail verification with a clear
  "code expired" message asking the attendee to refresh their ticket.

## Granting platform admin access

Admin powers (read-everything, edit any organizer's event, free any slug,
mark tickets used for support) are gated by a Firebase Auth custom
claim — `request.auth.token.admin == true`. Custom claims are signed by
Firebase and unforgeable from the client; only the Admin SDK (which
needs the project's service-account key) can set them.

To grant the role to a user:

```js
// One-off Node script. Requires the service account JSON and
// `firebase-admin` installed.
const admin = require('firebase-admin');
admin.initializeApp({
  credential: admin.credential.cert(require('./service-account.json')),
});
admin.auth().setCustomUserClaims('USER_UID', { admin: true });
```

Replace `USER_UID` with the target user's Firebase Auth uid (visible in
the Firebase console). Removing the role is the same call with
`{ admin: false }` (or `{}`).

A user picks up the new claim on their next ID-token refresh — the SPA
calls `refreshClaims()` from `AuthContext` to force this without a
sign-out/sign-in cycle.

**Scope of admin powers** (intentional):

- Read every event, ticket, transfer, sub-collection counter, user
  profile, slug, and audit log.
- Edit, cancel, or delete any event (organizer-equivalent writes).
- Free or rename any slug.
- Mark any ticket as used (e.g., for support cases).
- Soft-edit user profiles (displayName/photoURL) — useful for content
  moderation.

**Scope of admin powers** (intentionally NOT granted):

- Mint tickets directly. The ticket-create rule still requires a
  `stripeSessionId` on every doc. Even an admin can't bypass payment.
- Claim transfers on a receiver's behalf — that's tied to the
  receiver's auth-token email address.
- Mutate the `checkIns` audit log. It stays append-only for everyone.

If you need to do something an admin claim doesn't cover (e.g., a
manual ticket grant for a comp), do it server-side via the Admin SDK
where the rules don't apply.

## Buyer profiles (planned, private only)

Buyer profiles are a planned feature — the data model and UI are not
yet built. The design is locked to **private only** to keep the scope
small:

- A buyer's profile is readable by the buyer themselves and platform
  admins. There is no public toggle, no "make my profile public"
  setting, no opt-in to discoverability. If a future product call
  needs a public buyer profile (e.g., "follow other attendees"),
  it will be a deliberate new feature, not a flag added to the
  existing model.
- Sensitive PII (phone numbers, addresses) lives in a private
  sub-collection (`users/{uid}/private/contact`) with rules that
  refuse reads from anyone except the owner and admins.
- The minimal display fields (`displayName`, `photoURL`) currently
  on the public `users/{uid}` doc continue to power "ticket bought
  by" labels for organizers and admins. When buyer profiles land,
  this surface stays the same — what changes is that everything
  beyond name + avatar moves into the private sub-collection.
- Order history will live on a new `orders/{orderId}` parent doc that
  groups tickets bought together, enabling refund flows in the Stripe
  phase 2 work.

The privacy posture is deliberately stricter than hi.events', which
lets organizers see attendee email/phone for any sold ticket. We'll
surface that information to organizers only through scoped support
flows (e.g., a "contact attendee" CTA that goes through the mail
queue rather than exposing the address).

## Security

`firestore.rules` is the source of truth for what clients can read and
write. The remaining gap that needs server-side help to fully close:

1. **Free-ticket minting.** The create-ticket rule requires a
   `stripeSessionId` field but cannot verify the Stripe session itself.
   The fix is to move ticket creation behind a Cloud Function triggered by
   the `checkout.session.completed` Stripe webhook.

The capacity / promo-code / audit-log paths use Firestore's native
`FieldValue.increment()` plus strict-monotonic rule checks
(`incoming.value > existing.value` and `incoming.value <= cap`). Firestore
serializes increment ops at the document level, so two concurrent buyers
for the last seat will see the second writer's rule re-evaluate against
the post-first-commit state and reject. The 100-simulation harness in
`outputs/sim.ts` exercises this race directly. So while a Cloud Function
+ transaction would be cleaner, it isn't a launch-blocker for events at
~hundreds-of-attendees scale.

Until the Stripe webhook lands, do not run real money through this
codebase.
