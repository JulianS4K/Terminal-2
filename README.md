# evo terminal

Ticket Evolution market intelligence dashboard. FastAPI + Supabase + Railway, locked to `@s4kent.com` via Google OAuth.

## Architecture

```
Browser  ─► Railway (FastAPI + static HTML)  ─► Supabase (Postgres + Auth)
                      │                                 ▲
                      └─► TEvo API (signed)             │
                                                        │
  ┌─ scheduled (pg_cron) ──► Edge Function ─► Supabase ─┘
  │                               │
  └───────────────────────────── TEvo API
```

- **Local UI (Railway)**: live TEvo search, watchlist CRUD, view collected data
- **Edge Function (Supabase)**: scheduled collector, writes price snapshots
- **Postgres (Supabase)**: watchlist config, time-series snapshots, TEvo creds, views

## Folder layout

```
Terminal/1.0/
├── evo_client.py                      TEvo v9 API client (Python)
├── main.py                            CLI: search events → pick → stats
├── app.py                             FastAPI app w/ Google OAuth gate
├── requirements.txt                   pip deps for Railway
├── Procfile                           Railway start command
├── static/
│   └── index.html                     Single-page UI (5 tabs, auth bootstrap)
└── supabase/
    ├── migrations/
    │   └── 20260423000000_init.sql    Schema + views + seeds
    ├── functions/
    │   └── collect/
    │       └── index.ts               Edge Function: TS port of collector
    └── cron.sql                       pg_cron schedule (not yet applied)
```

## Fresh setup (end-to-end)

### 1. Supabase project

1. Create project at https://supabase.com/dashboard. Note the project ref.
2. Dashboard → SQL Editor → paste `supabase/migrations/20260423000000_init.sql` → Run.
3. Insert real TEvo creds:
   ```sql
   insert into settings (key, value) values
     ('tevo_token',  'YOUR_REAL_TOKEN'),
     ('tevo_secret', 'YOUR_REAL_SECRET')
   on conflict (key) do update set value = excluded.value, updated_at = now();
   ```

### 2. Google OAuth

1. https://console.cloud.google.com → new project.
2. APIs & Services → OAuth consent screen → External → fill required fields.
3. Credentials → Create OAuth client ID → Web application.
4. Authorized redirect URI: `https://<your-project-ref>.supabase.co/auth/v1/callback`
5. Copy the Client ID + Secret.
6. Supabase Dashboard → Authentication → Providers → Google → enable, paste creds, save.
7. Authentication → URL Configuration → Site URL = your Railway URL; Redirect URLs = `https://<railway-url>/**`.

### 3. Edge Function

```powershell
scoop install supabase
supabase login
supabase link --project-ref <your-project-ref>
supabase functions deploy collect --no-verify-jwt
supabase secrets set CRON_SECRET="pick-any-random-string"
```
(TEvo creds come from the `settings` table; no need to set them as secrets.)

### 4. Railway

```powershell
scoop install railway
railway login
railway init
railway up
railway service              # pick the service it created
railway variables --set "SUPABASE_URL=https://<your-project-ref>.supabase.co"
railway variables --set "SUPABASE_SERVICE_ROLE_KEY=<service_role JWT from Dashboard>"
railway variables --set "SUPABASE_ANON_KEY=<anon public JWT from Dashboard>"
railway variables --set "CRON_SECRET=<same value used for Edge Function>"
railway variables --set "ALLOWED_EMAIL_DOMAIN=s4kent.com"
railway domain               # prints the public URL
railway logs                 # confirm startup
```

### 5. Verify

Open the Railway URL. Login screen → sign in with Google (restricted to your domain) → terminal loads.

On the **watchlist** tab, click "run collector now". Wait 60-80s. Refresh runs — should show `ok` with ~138 events, 0 errors.

### 6. (Optional) Schedule automated collection

Only after the manual run works cleanly:

1. Dashboard → Database → Extensions → enable `pg_cron` and `pg_net`.
2. SQL Editor → paste `supabase/cron.sql` with your project ref and CRON_SECRET substituted → Run.

## Credential rotation

**TEvo creds** (no redeploy):
```sql
update settings set value = 'new_token',  updated_at = now() where key = 'tevo_token';
update settings set value = 'new_secret', updated_at = now() where key = 'tevo_secret';
```

**Adding team members**: no code change needed — any `@s4kent.com` Google account can sign in. Change the allowed domain with:
```powershell
railway variables --set "ALLOWED_EMAIL_DOMAIN=new.domain.com"
```

## Useful queries

```sql
-- Current state of every tracked event
select e.name, e.occurs_at_local, s.tickets_count, round(s.retail_price_avg)::int as avg_price
from events e join latest_snapshots s on s.event_id = e.id
order by e.occurs_at_local;

-- Velocity: biggest price swings between last 2 snapshots
select name, occurs_at_local, tickets_delta, avg_delta
from event_velocity
where tickets_delta is not null
order by abs(coalesce(avg_delta, 0)) desc
limit 20;

-- Recent collection runs
select id, started_at, finished_at, events_collected, stats_errors
from runs order by id desc limit 10;
```

## TEvo gotchas

- `event.available_count` is deprecated. Use `get_event_stats()`.
- `event.occurs_at` has a `Z` suffix but is LOCAL time. Use `occurs_at_local`.
- Canonical signing string always includes `?`, even with empty query.
- Rate limit is ~5 req/sec sustained. Collector paces at 3 concurrent × 200ms + retry-on-429.
