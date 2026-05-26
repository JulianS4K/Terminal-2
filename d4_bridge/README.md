# Exos Bridge (D4)

Primary ticketing platform for live events: organizers create events and tiered inventory, attendees buy and transfer tickets with rotating HMAC QR barcodes, organizers scan attendees at the door (online + offline with local registry fallback).

> **Status:** Core flows live on Supabase (auth, tickets, transfers, scanner). Stripe checkout and Automatiq distribution are wired but dormant pending credential setup. See `PROJECT_BIBLE.md §10` for open items.

## Stack

- **Frontend:** React 19 + Vite 6, Tailwind, Framer Motion, lucide-react
- **Auth + DB:** Supabase Auth + Supabase Postgres (migrated from Firebase)
- **Payments:** Stripe Checkout (dormant — set `STRIPE_SECRET_KEY` + `STRIPE_WEBHOOK_SECRET` to activate)
- **QR Barcodes:** HMAC-SHA256 rotating codes (60s buckets), verified server-side via `exos_check_in_ticket` RPC
- **Hosted at:** `vibepass-storefront-test.onrender.com/bridge/` (same-origin with FastAPI shell)

## Build

```bash
# Requires d4_bridge/.env.local with VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY
npm install
npm run build          # outputs to d4_bridge/dist/
# Copy dist → static/bridge/ and commit (Render auto-deploys on main push)
```

## Dev

```bash
npm run dev            # Vite HMR at localhost:5173 (hits prod Supabase)
```

## Prerequisites

- Node.js 20+
- Supabase project (URL + anon key in `.env.local`)
- Stripe account (only required for checkout activation)

## Key routes

| Path | Surface |
|---|---|
| `/` | Wallet / ticket list |
| `/events` | Event discovery |
| `/create-event` | Organizer event creation |
| `/ticket/:id` | Ticket detail + QR |
| `/transfer/:id` | Transfer flow |
| `/claim/:token` | Claim transferred ticket |
| `/organizer/check-in/:eventId` | Door scanner (camera + offline) |
| `/admin/org` | Org management |

## Architecture notes

- RLS on all `exos_*` tables — org-scoped by `exos_has_org_role()`; consumer wallet scoped to `owner_id = auth.uid()`
- Offline scanner: downloads registry to localStorage, HMAC-verifies barcodes client-side, queues pending check-ins for replay on reconnect
- Mail: `exos_queue_mail` RPC enqueues transactional mail → `exos-mail-drain` edge function delivers via Resend (dormant — set `RESEND_API_KEY` + `EXOS_MAIL_FROM`)
- See `d4_bridge/src/lib/` for auth, barcode, tickets, datetime, mail utilities
